#!/usr/bin/env python3
"""Minimal AOSP boot image packer -- fallback when `mkbootimg` is absent.

Supports v1/v2 (sweet's proven format) and v3/v4 (what Xiaomi's newer ABL
accepts; v4 is what `fastboot boot` needs on topaz/lisa-class firmware).
No vendor ramdisk, no recovery dtbo.  The output is byte-compatible with
AOSP mkbootimg for the same arguments.

  mkbootimg.py --kernel Image --ramdisk rd --dtb lisa.dtb -o boot.img \
      --header_version 2 --base 0 --kernel_offset 0x8000 ...
  mkbootimg.py --kernel Image --ramdisk rd -o boot.img --header_version 4
"""
import argparse
import hashlib
import os
import struct
import sys


def pad(data, page):
    return data + b'\0' * (-len(data) % page)


def os_version(s):
    a, b, c = (int(x) for x in s.split('.'))
    return (a << 25) | (b << 18) | (c << 11)


def os_patch_level(s):
    y, m = s.split('-')
    return ((int(y) - 2000) << 4) | int(m)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--kernel', required=True)
    ap.add_argument('--ramdisk', required=True)
    ap.add_argument('--second', default=None)
    ap.add_argument('--dtb', default=None)
    ap.add_argument('--header_version', type=int, default=2)
    ap.add_argument('--append-dtb', action='store_true',
                    help='concatenate --dtb to the kernel (Qualcomm/v1 style)')
    ap.add_argument('--base', type=lambda x: int(x, 0), default=0)
    ap.add_argument('--kernel_offset', type=lambda x: int(x, 0), default=0x8000)
    ap.add_argument('--ramdisk_offset', type=lambda x: int(x, 0), default=0x1000000)
    ap.add_argument('--second_offset', type=lambda x: int(x, 0), default=0xf00000)
    ap.add_argument('--tags_offset', type=lambda x: int(x, 0), default=0x100)
    ap.add_argument('--dtb_offset', type=lambda x: int(x, 0), default=0x1f00000)
    ap.add_argument('--pagesize', type=int, default=4096)
    ap.add_argument('--os_version', default='17.0.0')
    ap.add_argument('--os_patch_level', default='2035-06')
    ap.add_argument('--cmdline', default='')
    ap.add_argument('--name', default='')
    ap.add_argument('--signature', default=None,
                    help='boot signature blob for header v4 (default: none)')
    ap.add_argument('-o', '--output', required=True)
    a = ap.parse_args()

    if a.header_version not in (1, 2, 3, 4):
        sys.exit('only header_version 1, 2, 3 and 4 are implemented')

    kernel = open(a.kernel, 'rb').read()
    ramdisk = open(a.ramdisk, 'rb').read()
    second = open(a.second, 'rb').read() if a.second else b''
    dtb = open(a.dtb, 'rb').read() if a.dtb else b''
    signature = open(a.signature, 'rb').read() if a.signature else b''
    if a.append_dtb:
        if not dtb:
            sys.exit('--append-dtb needs --dtb')
        kernel = bytearray(kernel) + dtb
        # The arm64 Image header's image_size (offset 16) must cover the
        # appended DTB so ABL copies it.  Only touch real Image headers.
        if kernel[56:60] == b'ARM\x64':
            struct.pack_into('<Q', kernel, 16, len(kernel))
        kernel = bytes(kernel)

    hdr_size = 1648 if a.header_version == 1 else 1660
    page = 4096 if a.header_version >= 3 else a.pagesize

    # AOSP's boot image id: SHA1 over image + size for every component.
    sha = hashlib.sha1()
    for blob in (kernel, ramdisk, second, dtb):
        sha.update(blob)
        sha.update(struct.pack('<I', len(blob)))
    img_id = sha.digest() + b'\0' * 12

    if a.header_version >= 3:
        hv = a.header_version
        hdr_size = 1580 if hv == 3 else 1584
        hdr = struct.pack(
            '<8s4I4I I1536s',
            b'ANDROID!',
            len(kernel), len(ramdisk),
            os_version(a.os_version) | os_patch_level(a.os_patch_level),
            hdr_size,
            0, 0, 0, 0,
            hv,
            a.cmdline.encode()[:1535],
        )
        assert len(hdr) == hdr_size - (4 if hv == 4 else 0), len(hdr)
        if hv == 4:
            hdr += struct.pack('<I', len(signature))
        assert len(hdr) == hdr_size, len(hdr)
        out = bytearray()
        out += pad(hdr, page)
        out += pad(kernel, page)
        out += pad(ramdisk, page)
        if signature:
            out += pad(signature, page)
        with open(a.output, 'wb') as f:
            f.write(out)
        print(f'{a.output}: {len(out)} bytes (header v{hv}, page {page}, '
              f'signature {len(signature)})')
        return

    fmt = '<8s10I16s512s32s1024sIQI'
    vals = [
        b'ANDROID!',
        len(kernel), a.base + a.kernel_offset,
        len(ramdisk), a.base + a.ramdisk_offset,
        len(second), a.base + a.second_offset,
        a.base + a.tags_offset,
        page, a.header_version,
        os_version(a.os_version) | os_patch_level(a.os_patch_level),
        a.name.encode()[:15],
        a.cmdline.encode()[:511],
        img_id,
        b'',                       # extra_cmdline
        0, 0,                      # recovery_dtbo_size, recovery_dtbo_offset
        hdr_size,
    ]
    if a.header_version == 2:
        fmt += 'IQ'
        vals += [len(dtb), a.base + a.dtb_offset]
    hdr = struct.pack(fmt, *vals)
    assert len(hdr) == hdr_size, len(hdr)

    out = bytearray()
    out += pad(hdr, page)
    out += pad(kernel, page)
    out += pad(ramdisk, page)
    if second:
        out += pad(second, page)
    if a.header_version == 2:
        out += pad(dtb, page)

    with open(a.output, 'wb') as f:
        f.write(out)
    print(f'{a.output}: {len(out)} bytes (header v{a.header_version}, page {page}, dtb appended={a.append_dtb})')


if __name__ == '__main__':
    main()
