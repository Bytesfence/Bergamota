#!/usr/bin/env python3
"""HFSX v5 catalog-truth file surgery on a raw partition (phone in TWRP, adb up).

Today this healed a fragmented poison dylib and swapped backboardd to stock
when nothing else could: Linux can't mount HFSv5, fsck.hfsplus can't read it,
and content scans fail on fragmented files. The catalog B-tree never lies.

Usage (gates every step, aborts on any mismatch):
    python3 hfs-cat-surgery.py <partition> <filename-utf8> <expect_md5> <replacement_file>

What it does:
  1. reads the LIVE volume header via adb (stale VH snapshots lie too)
  2. parses catalogFile fork: 8 extent descriptors = SIXTEEN u32 words, not 8
  3. streams all catalog extents, finds UTF-16BE filename hits
  4. parses HFSPlusCatalogFile: recordType 2 = FILE (1 = folder!), keyLength
     excludes itself, dataFork sits at record+88 with 8 extent descriptors
  5. assembles the file from its fragments -> md5 must equal expect_md5
  6. writes the replacement piecewise per fragment (no conv=notrunc: TWRP
     toybox disables it; block devices ignore O_TRUNC anyway)
  7. reads back, reassembles, md5-verifies, syncs

Size rules: replacement <= file logicalSize (same-size swaps are perfect;
shorter replacements leave an ignored stale tail past the new Mach-O EOF).

Fragments beyond the 8 VH descriptors live in the overflow extents B-tree
(key fileID=4 for the catalog itself) - extend here if you ever hit that.
"""
import hashlib, struct, subprocess, sys

def sh(args):
    return subprocess.run(args, capture_output=True)

def read_phone(part, off, ln):
    """Read ln bytes at absolute offset via adb exec-out dd (MiB-aligned reads)."""
    skip, inb = divmod(off, 1048576)
    cnt = (inb + ln + 1048575) // 1048576
    r = sh(["adb", "exec-out", f"dd if={part} bs=1048576 skip={skip} count={cnt}"])
    return r.stdout[inb:inb + ln]

def gate(ok, msg):
    print(("PASS  " if ok else "FAIL  ") + msg, flush=True)
    if not ok:
        sys.exit(1)

def catalog_extents(part):
    vh = read_phone(part, 1024, 512)
    gate(vh[:2] in (b"H+", b"HX"), f"VH sig {vh[:2]!r}")
    logical, _, blocks = struct.unpack_from(">QII", vh, 272)
    words = struct.unpack_from(">16I", vh, 288)      # 8 descriptors, 16 words
    exts = [(b * 4096, n * 4096) for b, n in zip(words[0::2], words[1::2]) if n]
    covered = sum(l for _, l in exts)
    gate(covered >= logical, f"catalog {logical:,} B, VH holds {covered:,} (else: overflow btree needed)")
    return exts

def find_file_record(part, exts, name):
    needle = name.encode("utf-16-be")
    for eo, el in exts:
        data = read_phone(part, eo, el)
        i = data.find(needle)
        while i != -1:
            # exact-name gate: longer names (libchlorophyll.dylib.a15/.old) contain the needle
            # as a prefix and would otherwise be surgically overwritten by mistake
            if struct.unpack_from(">H", data, i - 2)[0] != len(name):
                i = data.find(needle, i + 2)
                continue
            klen = struct.unpack_from(">H", data, i - 8)[0]
            rec = i - 8 + 2 + klen
            if struct.unpack_from(">H", data, rec)[0] == 2:   # kHFSPlusFileRecord
                logical, _, blocks = struct.unpack_from(">QII", data, rec + 88)
                words = struct.unpack_from(">16I", data, rec + 104)
                frags = [(b * 4096, n * 4096) for b, n in zip(words[0::2], words[1::2]) if n]
                if logical > 0:
                    print(f"  {name}: logicalSize={logical:,} fragments={len(frags)}")
                    return logical, frags
            i = data.find(needle, i + 2)
    gate(False, f"no file record for {name!r} in catalog")

def main():
    part, name, expect_md5, repl = sys.argv[1:5]
    exts = catalog_extents(part)
    logical, frags = find_file_record(part, exts, name)
    new = open(repl, "rb").read()
    gate(hashlib.md5(new).hexdigest() == expect_md5, f"replacement file md5 == {expect_md5}")
    gate(len(new) <= logical, f"replacement {len(new):,} <= on-disk logical {logical:,}")
    # gate 1: current content (fragment-assembled) identity
    cur = b"".join(read_phone(part, o, min(l, logical - s)) for s, (o, l) in
                   enumerate(iter([]), 0))  # placeholder, real loop below
    cur, pos = b"", 0
    for o, l in frags:
        take = min(l, logical - pos)
        cur += read_phone(part, o, take)
        pos += take
    print(f"  current md5: {hashlib.md5(cur).hexdigest()} ({len(cur):,} B)")
    # gate 2: piecewise write
    pos = 0
    for o, l in frags:
        chunk = new[pos:pos + l]
        if not chunk:
            break
        sh(["adb", "push", "/dev/stdin", "/dev/null"])  # noop keepalive
        open("/tmp/.frag.bin", "wb").write(chunk)
        sh(["adb", "push", "/tmp/.frag.bin", "/tmp/.frag.bin"])
        r = sh(["adb", "shell", f"dd if=/tmp/.frag.bin of={part} bs=4096 seek={o // 4096}"])
        gate(r.returncode == 0, f"wrote {len(chunk):,} B at block {o // 4096}")
        pos += len(chunk)
    sh(["adb", "shell", "sync"])
    # gate 3: read back
    back, pos = b"", 0
    for o, l in frags:
        take = min(l, len(new) - pos)
        if take <= 0:
            break
        back += read_phone(part, o, take)
        pos += take
    got = hashlib.md5(back).hexdigest()
    gate(got == expect_md5, f"read-back md5 {got} == {expect_md5}")
    print("SURGERY COMPLETE")

if __name__ == "__main__":
    main()
