#!/usr/bin/env python3
"""Ad-hoc Mach-O code signature page-hash validator (arm64 dylibs).

Walks LC_CODE_SIGNATURE (0x1d) -> SuperBlob 0xfade0cc0 -> CodeDirectory
0xfade0c02 and verifies every code-slot page hash against SHA256 of the
file's pages. Exits non-zero if any page mismatches or structures are
missing. Usage: sigcheck.py FILE [FILE...]
"""
import hashlib
import struct
import sys

PAGE = 4096


def fail(path, msg):
    print(f"{path}: FAIL - {msg}")
    return False


def check(path):
    try:
        data = open(path, "rb").read()
    except OSError as e:
        return fail(path, str(e))
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe":
        return fail(path, "not a little-endian arm64 Mach-O")
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    cs_off = cs_len = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == 0x1D:  # LC_CODE_SIGNATURE
            cs_off, cs_len = struct.unpack_from("<II", data, off + 8)
            break
        off += cmdsize
    if cs_off is None:
        return fail(path, "no LC_CODE_SIGNATURE")
    if data[cs_off:cs_off + 4] != b"\xfa\xde\x0c\xc0":
        return fail(path, "no SuperBlob magic at dataoff")
    count = struct.unpack_from(">I", data, cs_off + 8)[0]
    cd_off = None
    for i in range(count):
        idx = cs_off + 12 + 8 * i
        slot_type, slot_off = struct.unpack_from(">II", data, idx)
        if slot_type == 0:  # CSSLOT_CODEDIRECTORY
            cd_off = cs_off + slot_off
            break
    if cd_off is None:
        return fail(path, "no slot 0 CodeDirectory")
    if data[cd_off:cd_off + 4] != b"\xfa\xde\x0c\x02":
        return fail(path, "no CodeDirectory magic")
    (magic, length, version, flags, hash_off, ident_off, n_special, n_code,
     code_limit) = struct.unpack_from(">9I", data, cd_off)
    hash_size, hash_type = data[cd_off + 36], data[cd_off + 37]
    if hash_type != 2:  # CSHASH_SHA256
        return fail(path, f"hash type {hash_type} != SHA256")
    if hash_size != 32:
        return fail(path, f"hash size {hash_size} != 32")
    npages = (code_limit + PAGE - 1) // PAGE
    bad = 0
    for p in range(npages):
        start = p * PAGE
        chunk = data[start:min(start + PAGE, code_limit)]
        want = data[cd_off + hash_off + p * 32: cd_off + hash_off + p * 32 + 32]
        if hashlib.sha256(chunk).digest() != want:
            bad += 1
    ident = data[cd_off + ident_off: data.index(b"\0", cd_off + ident_off)]
    if bad:
        return fail(path, f"{bad}/{npages} page hashes MISMATCH")
    print(f"{path}: OK - {npages} pages verified, {n_special} special slots, ident {ident.decode(errors='replace')}")
    return True


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: sigcheck.py FILE [FILE...]")
    sys.exit(0 if all(check(p) for p in sys.argv[1:]) else 1)
