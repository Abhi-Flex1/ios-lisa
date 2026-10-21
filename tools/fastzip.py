#!/usr/bin/env python3
"""Parallel ranged download of one zip member (e.g. an IPSW DMG).

    fastzip.py URL MEMBER OUTDIR [CONNECTIONS] [CHUNK_MB]

Same idea as remotezip.py, but each 64 MiB range is fetched by its own curl
process in parallel, so a single-throttled CDN connection does not cap the
whole transfer. Chunks are kept in OUTDIR/.fastzip-<member>/ and reused, so an
interrupted download resumes. The zip CRC-32 is verified before the final name
is written.
"""
import concurrent.futures as cf
import os, struct, subprocess, sys, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import remotezip  # noqa: E402


def fetch(url, start, end, path):
    if os.path.exists(path) and os.path.getsize(path) == end - start + 1:
        return path
    tmp = path + '.tmp'
    subprocess.run(['curl', '-sfL', '--retry', '5', '--retry-delay', '1',
                    '--max-time', '600', '-r', f'{start}-{end}',
                    '-o', tmp, url], check=True)
    if os.path.getsize(tmp) != end - start + 1:
        raise RuntimeError(f'bad range {start}-{end}: {os.path.getsize(tmp)} bytes')
    os.replace(tmp, path)
    return path


def main(argv):
    if len(argv) < 4:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    url, member, outdir = argv[1], argv[2], argv[3]
    conns = int(argv[4]) if len(argv) > 4 else 8
    chunk = (int(argv[5]) if len(argv) > 5 else 64) << 20

    entries = [e for e in remotezip.central_dir(url) if e[0] == member]
    if not entries:
        entries = [e for e in remotezip.central_dir(url) if member in e[0]]
    if len(entries) != 1:
        raise SystemExit(f'{member!r}: {len(entries)} matches, need exactly 1')
    name, method, csize, usize, lho, crc = entries[0]
    if method not in (0, 8):
        raise SystemExit(f'{name}: unsupported compression method {method}')

    # Local file header -> payload offset.
    hdr = remotezip.get(url, lho, lho + 29)
    nlen, xlen = struct.unpack_from('<HH', hdr, 26)
    start = lho + 30 + nlen + xlen

    os.makedirs(outdir, exist_ok=True)
    cdir = os.path.join(outdir, '.fastzip-' + os.path.basename(name))
    os.makedirs(cdir, exist_ok=True)
    nchunks = (csize + chunk - 1) // chunk
    jobs = []
    for i in range(nchunks):
        s = start + i * chunk
        e = start + min(csize, (i + 1) * chunk) - 1
        jobs.append((s, e, os.path.join(cdir, f'{i:05d}')))
    print(f'{name}: {csize} bytes in {nchunks} chunks of {chunk >> 20} MiB, '
          f'{conns} connections', flush=True)

    done = 0
    with cf.ThreadPoolExecutor(conns) as ex:
        futs = {ex.submit(fetch, url, *j): j for j in jobs}
        for f in cf.as_completed(futs):
            f.result()
            done += 1
            if done % 8 == 0 or done == len(jobs):
                print(f'{name}: {done * 100 // len(jobs)}% ({done} chunks)', flush=True)

    final = os.path.join(outdir, os.path.basename(name))
    part = final + '.part'
    inflate = zlib.decompressobj(-15) if method == 8 else None
    with open(part, 'wb') as out:
        c = 0
        for _, _, p in jobs:
            with open(p, 'rb') as f:
                while data := f.read(1 << 20):
                    if inflate:
                        data = inflate.decompress(data)
                    if data:
                        c = zlib.crc32(data, c)
                        out.write(data)
        if inflate:
            data = inflate.flush()
            c = zlib.crc32(data, c)
            out.write(data)
    got = os.path.getsize(part)
    assert got == usize, (name, got, usize)
    assert c == crc, f'{name}: CRC-32 {c:08x} != {crc:08x}'
    os.replace(part, final)
    print(f'{name}: {usize} bytes, CRC-32 ok -> {final}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
