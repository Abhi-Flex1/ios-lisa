#!/usr/bin/env python3
"""Build the root userdata image: SHNGROOT manifest + whole-disk IPSW windows.

    mkuserdata.py OUT.img --window OS=OS.dmg --window SystemOS=SystemOS.dmg
    mkuserdata.py OUT.img --window OS=OS.dmg --window SystemOS=SystemOS.dmg --dry-run

Layout (little endian), from the UniXNU userdata format (BSD-2-Clause-Patent,
docs/guide/userdata.md):

    0x000000  manifest block, 4096 bytes, zero padded to 1 MiB
    0x100000  window 0 (OS), the whole disk image, 1 MiB aligned
    ....      window 1 (SystemOS), likewise

Manifest: "SHNGROOT", u32 version=1, u32 count, u64 image_bytes, then `count`
128-byte entries {char name[32], u64 offset, u64 size, u32 block_size=512,
u32 flags(1=read-only), u8 sha256[32], 40 reserved}; bytes 4064..4095 are the
SHA-256 of bytes 0..4063.  The window size is the DMG's whole-disk size
(`hdiutil imageinfo` Total Bytes), read byte for byte from /dev/rdiskX.

Nothing is flashed; the report prints the command.  The macOS-only DMG
handling mirrors UniXNU's scripts/unixnu/userdata.py.
"""
import hashlib
import json
import os
import plistlib
import re
import struct
import subprocess
import sys

MIB = 1 << 20
CHUNK = 8 * MIB
HEADER = 4096


def image_bytes(dmg):
    info = subprocess.run(['hdiutil', 'imageinfo', '-plist', dmg],
                          capture_output=True, check=True).stdout
    return plistlib.loads(info)['Size Information']['Total Bytes']


def attach(dmg):
    """Attach read-only, unmounted; return the whole-disk device (e.g. /dev/disk9)."""
    out = subprocess.run(['hdiutil', 'attach', '-nomount', '-readonly',
                          '-noverify', '-noautofsck', dmg],
                         capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        m = re.match(r'(/dev/disk\d+)\s', line)
        if m:
            return m.group(1)
    raise SystemExit(f'{dmg}: no disk device in hdiutil output')


def sha256_file(path, limit=None):
    h = hashlib.sha256()
    left = limit
    with open(path, 'rb') as f:
        while left is None or left:
            want = CHUNK if left is None else min(CHUNK, left)
            data = f.read(want)
            if not data:
                break
            h.update(data)
            if left is not None:
                left -= len(data)
    return h.hexdigest()


def main(argv):
    if len(argv) < 4 or '--window' not in argv:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    out = argv[1]
    dry = '--dry-run' in argv
    windows = []
    i = 2
    while i < len(argv):
        if argv[i] == '--window':
            name, dmg = argv[i + 1].split('=', 1)
            windows.append((name, dmg))
            i += 2
        elif argv[i] == '--dry-run':
            i += 1
        else:
            raise SystemExit(f'unexpected argument {argv[i]!r}')
    if not windows:
        raise SystemExit('no --window given')

    sizes = [(name, dmg, image_bytes(dmg)) for name, dmg in windows]
    layout, cursor = [], MIB
    for name, dmg, size in sizes:
        layout.append((name, dmg, cursor, size))
        cursor += (size + MIB - 1) // MIB * MIB
    total = cursor
    print(f'image {total} bytes ({total / 2**30:.2f} GiB), {len(layout)} windows')
    for name, dmg, off, size in layout:
        print(f'  {name:12s} {size:>14,d} bytes at {off:#x}  ({dmg})')
    if dry:
        return 0

    entries = []
    with open(out, 'wb') as target:
        target.truncate(total)
        for name, dmg, off, size in layout:
            device = attach(dmg)
            raw = device.replace('/dev/disk', '/dev/rdisk')
            digest = hashlib.sha256()
            try:
                target.seek(off)
                done = 0
                with open(raw, 'rb', buffering=0) as src:
                    while done < size:
                        want = min(CHUNK, size - done)
                        data = src.read(want)
                        if len(data) != want:
                            raise SystemExit(f'{raw}: short read at {done}')
                        digest.update(data)
                        target.write(data)
                        done += want
            finally:
                subprocess.run(['hdiutil', 'detach', device],
                               capture_output=True)
            entries.append((name, off, size, digest.digest()))
            print(f'  {name}: sha256 {digest.hexdigest()}')

        header = bytearray(HEADER)
        header[0:8] = b'SHNGROOT'
        struct.pack_into('<IIQ', header, 8, 1, len(entries), total)
        for index, (name, off, size, digest) in enumerate(entries):
            struct.pack_into('<32sQQII32s40s', header, 24 + 128 * index,
                             name.encode(), off, size, 512, 1, digest,
                             bytes(40))
        header[4064:4096] = hashlib.sha256(bytes(header[:4064])).digest()
        target.seek(0)
        target.write(header)

    report = {
        'image_bytes': total,
        'image_sha256': sha256_file(out),
        'manifest_sha256': hashlib.sha256(bytes(header)).hexdigest(),
        'windows': [{'name': n, 'offset': o, 'size': s,
                     'sha256': d.hex()} for n, o, s, d in entries],
        'flash_command': f'fastboot flash userdata {out}',
    }
    with open(out + '.json', 'w') as f:
        json.dump(report, f, indent=2)
        f.write('\n')
    print(f'{out}\nflash: {report["flash_command"]}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
