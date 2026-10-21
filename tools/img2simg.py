#!/usr/bin/env python3
"""Convert a raw filesystem image to an Android sparse image, in Python.

    img2simg.py IN.img OUT.simg [CHUNK_MB]

Needed because macOS has no `img2simg` and a 16 GiB raw flash to `userdata`
is much slower over USB than the FILL/RAW sparse stream fastboot writes.
Format: Android sparse image, v1.0, 4096-byte blocks (see
system/core/libsparse). The layout is the one `fastboot flash -S` expects.
"""
import os, struct, sys, zlib

BLK = 4096
RAW, FILL, DONT_CARE, CRC32 = 0xCAC1, 0xCAC2, 0xCAC3, 0xCAC4


def chunks(path, chunk_bytes):
    """Yield (type, payload, size_bytes) grouping whole blocks."""
    with open(path, 'rb') as f:
        while True:
            data = f.read(chunk_bytes)
            if not data:
                return
            # A short tail is padded with zeros (the image is block-aligned).
            if len(data) % BLK:
                data += b'\0' * (BLK - len(data) % BLK)
            # FILL when the whole run is one repeated block value.
            first = data[:BLK]
            if len(data) >= BLK and data == first * (len(data) // BLK):
                yield FILL, first, len(data)
            elif data.count(0) == len(data):
                yield DONT_CARE, b'', len(data)
            else:
                yield RAW, data, len(data)


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    inp, outp = argv[1], argv[2]
    chunk_mb = int(argv[3]) if len(argv) > 3 else 4
    chunk_bytes = chunk_mb * 1024 * 1024
    size = os.path.getsize(inp)
    if size % BLK:
        raise SystemExit(f'{inp}: size {size} is not a multiple of {BLK}')
    total_blks = size // BLK

    # One counting pass, then the write pass: never hold the image in memory.
    total_chunks = sum(1 for _ in chunks(inp, chunk_bytes))
    with open(outp, 'wb') as f:
        f.write(struct.pack('<IHHHHIIII', 0xED26FF3A, 1, 0, 28, 12,
                            BLK, total_blks, total_chunks, 0))
        n = 0
        for typ, payload, nbytes in chunks(inp, chunk_bytes):
            nblks = nbytes // BLK
            # chunk_sz is a block count; total_sz is bytes *including* the
            # 12-byte header. Swapping them makes fastboot write nonsense.
            if typ == DONT_CARE:
                f.write(struct.pack('<HHII', typ, 0, nblks, 12))
            else:
                f.write(struct.pack('<HHII', typ, 0, nblks, 12 + len(payload)))
                f.write(payload)
            n += 1
    print(f'{inp}: {size} bytes -> {outp}: {os.path.getsize(outp)} bytes, '
          f'{n} chunks, {total_blks} blocks')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
