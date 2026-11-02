#!/usr/bin/env python3
"""addrpath.py BIN RPATH [OUT]: append an LC_RPATH to a thin 64-bit Mach-O,
using the same slack-before-__text technique as addlc.py."""
import struct, sys

src, path = sys.argv[1], sys.argv[2]
out = sys.argv[3] if len(sys.argv) > 3 else src
d = bytearray(open(src, 'rb').read())
magic, cpu, sub, ft, ncmds, scmds, flags, _ = struct.unpack_from('<8I', d, 0)
assert magic == 0xfeedfacf, 'thin 64-bit Mach-O only'
off, lowest = 32, 1 << 62
for i in range(ncmds):
    cmd, sz = struct.unpack_from('<II', d, off)
    if cmd == 0x19:  # LC_SEGMENT_64
        nsects = struct.unpack_from('<I', d, off + 64)[0]
        for s in range(nsects):
            so = off + 72 + s * 80
            soff = struct.unpack_from('<I', d, so + 48)[0]
            if soff:
                lowest = min(lowest, soff)
    off += sz
nm = path.encode() + b'\0'
cmdsz = (12 + len(nm) + 7) & ~7
end = 32 + scmds
assert end + cmdsz <= lowest, 'no slack (%d free, %d needed)' % (lowest - end, cmdsz)
lc = struct.pack('<III', 0x8000001e, cmdsz, 12) + nm
d[end:end + cmdsz] = lc.ljust(cmdsz, b'\0')
struct.pack_into('<II', d, 16, ncmds + 1, scmds + cmdsz)
open(out, 'wb').write(d)
print('added LC_RPATH', path, 'to', out)
