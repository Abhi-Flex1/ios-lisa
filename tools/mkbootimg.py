#!/usr/bin/env python3
"""Minimal AOSP boot image v2 packer -- fallback when `mkbootimg` is absent.

Only the subset shim/build.sh uses is implemented (no v0/v3/v4, no vendor
ramdisk, no recovery dtbo). The output is byte-compatible with mkbootimg for
the same arguments; the geometry comes from the proven ios-sweet command line.

  mkbootimg.py --kernel Image --ramdisk rd --dtb lisa.dtb -o boot.img \
      --header_version 2 --base 0 --kernel_offset 0x8000 ...
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
    ap.add_argument('-o', '--output', required=True)
    a = ap.parse_args()

    if a.header_version != 2:
        sys.exit('only header_version 2 is implemented')

    kernel = open(a.kernel, 'rb').read()
    ramdisk = open(a.ramdisk, 'rb').read()
    second = open(a.second, 'rb').read() if a.second else b''
    dtb = open(a.dtb, 'rb').read() if a.dtb else b''

    hdr_size = 1660
    page = a.pagesize

    # AOSP's boot image id: SHA1 over image + size for every component.
    sha = hashlib.sha1()
    for blob in (kernel, ramdisk, second, dtb):
        sha.update(blob)
        sha.update(struct.pack('<I', len(blob)))
    img_id = sha.digest() + b'\0' * 12

    hdr = struct.pack(
        '<8s10I16s512s32s1024sIQIIQ',
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
        len(dtb), a.base + a.dtb_offset,
    )
    assert len(hdr) == hdr_size, len(hdr)

    out = bytearray()
    out += pad(hdr, page)
    out += pad(kernel, page)
    out += pad(ramdisk, page)
    if second:
        out += pad(second, page)
    out += pad(dtb, page)

    with open(a.output, 'wb') as f:
        f.write(out)
    print(f'{a.output}: {len(out)} bytes (header v2, page {page})')


if __name__ == '__main__':
    main()
