#!/usr/bin/env python3
"""Split a Qualcomm PIL .mbn (ELF32 or ELF64 LE) into .mdt + .bNN."""
import os, struct, sys

src = sys.argv[1]
out_prefix = sys.argv[2] if len(sys.argv) > 2 else os.path.splitext(src)[0]

data = open(src, 'rb').read()
assert data[:4] == b'\x7fELF', 'not an ELF/MBN'
ei_class, ei_data = data[4], data[5]
assert ei_data == 1, 'not little-endian'

if ei_class == 2:   # ELF64
    e_phoff, = struct.unpack_from('<Q', data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from('<HH', data, 0x36)
    assert e_phentsize == 56
    def phdr(i):
        p_type, p_flags, p_off, p_va, p_pa, p_filesz, p_memsz = \
            struct.unpack_from('<IIQQQQQ', data, e_phoff + i * 56)
        return p_type, p_off, p_filesz
else:               # ELF32 (Qualcomm legacy MBN)
    e_phoff, = struct.unpack_from('<I', data, 0x1C)
    e_phentsize, e_phnum = struct.unpack_from('<HH', data, 0x2A)
    assert e_phentsize == 32
    def phdr(i):
        p_type, p_off, p_va, p_pa, p_filesz, p_memsz, p_flags, p_align = \
            struct.unpack_from('<IIIIIIII', data, e_phoff + i * 32)
        return p_type, p_off, p_filesz

segs = [phdr(i) for i in range(e_phnum)]
first_data_end = 0
for i, (p_type, p_off, p_filesz) in enumerate(segs):
    if p_filesz > 0:
        first_data_end = p_off + p_filesz
        break

open(out_prefix + '.mdt', 'wb').write(data[:first_data_end])
print(f'{out_prefix}.mdt: {first_data_end} bytes ({e_phnum} phdrs, class {ei_class})')

for i, (p_type, p_off, p_filesz) in enumerate(segs):
    if i == 0 or p_filesz == 0:
        continue
    name = f'{out_prefix}.b{i:02d}'
    open(name, 'wb').write(data[p_off:p_off + p_filesz])
    print(f'{name}: {p_filesz} bytes')
