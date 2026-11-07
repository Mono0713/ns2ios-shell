#!/usr/bin/env python3
"""NSO modules whose segments are ZBIC-compressed instead of LZ4 → the same module with its segments stored uncompressed.

ZBIC is the zstd variant Nintendo's tools use from system version 22.0.0 (its entropy tables are written with binary
interpolative coding; Atmosphere decodes it). An NSO built that way sets header flag bit 7 (0x80) beside the usual three
"compressed" bits, and each compressed segment starts with the magic "ZBIC" (Super Bunny Man 1.3.0's main, flags 0xbf; its
rtld, sdk and subsdk0 are still LZ4, flags 0x3f). Every tool here reads NSO segments with LZ4, so the packer rewrites such a
module once, right after the extraction: each ZBIC segment decompressed, stored raw (its compressed bit and bit 7 cleared,
compressed size = size), the header's segment hashes kept (they are of the decompressed data and are checked here).

The decoder is the zbic package (https://github.com/kinnay/zbic, built from Atmosphere's zstd; pip install zbic), installed on
first use. Nothing changes for a module without ZBIC segments.

    python nso_zbic.py <ExeFS folder or NSO file>...
"""
import hashlib
import struct
import subprocess
import sys
from pathlib import Path

MAGIC = b'ZBIC'
FLAG_ZBIC = 0x80


def is_zbic(d):
    """an NSO with at least one ZBIC segment"""
    if len(d) < 0x100 or d[:4] != b'NSO0': return False
    flags = struct.unpack_from('<I', d, 0xc)[0]
    segs = [struct.unpack_from('<III', d, 0x10 + i * 0x10) for i in range(3)]
    return bool(flags & FLAG_ZBIC) or any(flags >> i & 1 and d[fo:fo + 4] == MAGIC for i, (fo, _mo, _sz) in enumerate(segs))


def _zbic():
    try:
        import zbic
        return zbic
    except ImportError:
        pass
    print('this module is ZBIC-compressed (system 22 and later): installing the decoder (pip install zbic, once)', flush=True)
    r = subprocess.run([sys.executable, '-m', 'pip', 'install', '--disable-pip-version-check', '--quiet', 'zbic'])
    try:
        import zbic
        return zbic
    except ImportError:
        raise SystemExit('[x] ZBIC-compressed module: the zbic package could not be installed (pip exit %d). '
                         'Install it with:  %s -m pip install zbic' % (r.returncode, sys.executable))


def decompress_nso(d):
    """the NSO bytes with every ZBIC segment stored uncompressed (LZ4 segments are left as they are)"""
    flags = struct.unpack_from('<I', d, 0xc)[0]
    segs = [struct.unpack_from('<III', d, 0x10 + i * 0x10) for i in range(3)]
    csz = list(struct.unpack_from('<III', d, 0x60))
    hdr = bytearray(d[:0x100])
    # keep whatever sits between the header and the first segment (the module name: "GameAssembly\0" at 0x100)
    first = min(fo for fo, _, _ in segs)
    body, pos = bytearray(d[0x100:first]), first
    zb = None
    for i, (fo, mo, sz) in enumerate(segs):
        raw = d[fo:fo + csz[i]]
        if flags >> i & 1 and raw[:4] == MAGIC:
            zb = zb or _zbic()
            raw = zb.decompress(bytes(raw))
            if len(raw) != sz: raise SystemExit('[x] ZBIC segment %d of the module decompressed to %d bytes, the header says %d' % (i, len(raw), sz))
            if flags >> (3 + i) & 1 and hashlib.sha256(raw).digest() != d[0xa0 + 0x20 * i:0xc0 + 0x20 * i]:
                raise SystemExit('[x] ZBIC segment %d of the module does not match its hash in the header' % i)
            flags &= ~(1 << i); csz[i] = sz
        struct.pack_into('<I', hdr, 0x10 + i * 0x10, pos)
        body += raw; pos += len(raw)
    flags &= ~FLAG_ZBIC
    struct.pack_into('<I', hdr, 0xc, flags)
    struct.pack_into('<III', hdr, 0x60, *csz)
    return bytes(hdr + body)


def normalize(path):
    """rewrite one NSO file in place if it has ZBIC segments; True if it did"""
    p = Path(path)
    d = p.read_bytes()
    if not is_zbic(d): return False
    out = decompress_nso(d)
    tmp = p.with_name(p.name + '.unzbic')
    tmp.write_bytes(out)
    tmp.replace(p)
    print('%s: ZBIC segments decompressed (%d → %d bytes)' % (p.name, len(d), len(out)), flush=True)
    return True


def normalize_exefs(folder):
    """every module of an ExeFS folder (files without an extension: main, sdk, subsdk*, rtld); returns the names rewritten"""
    return [f.name for f in sorted(Path(folder).iterdir()) if f.is_file() and '.' not in f.name and normalize(f)]


if __name__ == '__main__':
    for a in sys.argv[1:]:
        (normalize_exefs if Path(a).is_dir() else normalize)(a)
