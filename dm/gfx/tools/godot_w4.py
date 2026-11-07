"""Precompiled NVN shaders of Godot 4 for consoles (W4 Games): the GLSLC outputs inside a Godot pack's .godot/w4_shaders/*.nvn.w4_shader files.

Unrailed 2: Back on Track (Godot 4.4.1 by W4 Games, SDK 20) compiles no shader at run time and holds none the split can see: its RomFS has one
Godot pack, nx.pck (GDPC format 2), whose 1,138 .nvn.w4_shader files are Godot's shader containers ("GRSC", version 2, format "NVNC"), each
stage's code in it compressed (Godot's Compression, zstd) or stored. Inside the code are GLSLC outputs (magic 0x19866891, the whole output's
length at +0x44), which shader_split.py reads like the outputs captured from glslcCompile (hle_glslc.c).

shader_split.py reads them straight from the RomFS's packs (outputs()), as /<pack>#<container> sources. To look at them on their own, this writes
every whole GLSLC output found to <out>/<FNV-1a 64 of the output>.glslc, the names hle_glslc.c gives captured ones:

    python godot_w4.py <RomFS folder or .pck file> <out folder>         prints what it found per container kind
    python godot_w4.py <RomFS folder or .pck file> --keys k1,k2,...     the shader keys (dm_ctl_sha16) shader_split.py would give them, and which of k1,k2 are among them

zstd needs Python 3.14's compression.zstd or the zstandard / pyzstd package; without one only stored code is found (it says so).
"""
import os
import struct
import sys
import zlib

GLSLC_MAGIC = 0x19866891
ZSTD_MAGIC = b'\x28\xb5\x2f\xfd'


def _zstd():
    """A function decompressing the zstd frame at the start of a buffer (returns the output, or None), or None without a zstd module."""
    try:
        from compression import zstd as cz   # Python 3.14
        def one(b):
            d = cz.ZstdDecompressor(); return d.decompress(b)
        return one
    except ImportError:
        pass
    try:
        import zstandard
        def one(b):
            return zstandard.ZstdDecompressor().decompressobj().decompress(b)
        return one
    except ImportError:
        pass
    try:
        import pyzstd
        def one(b):
            return pyzstd.ZstdDecompressor().decompress(b)
        return one
    except ImportError:
        return None


def pck_files(path):
    """[(path, offset, size)] of a Godot 4 pack (GDPC format 2; format 1 has no file base); offsets are absolute in the file."""
    with open(path, 'rb') as f:
        h = f.read(4 + 4 * 5 + 8 + 16 * 4 + 4)
        if h[:4] != b'GDPC': raise ValueError(f'{path}: not a Godot pack')
        fmt, vmaj, vmin, vpat, flags = struct.unpack_from('<5I', h, 4)
        if fmt >= 2:
            base, = struct.unpack_from('<Q', h, 24); count, = struct.unpack_from('<I', h, 24 + 8 + 64)
        else:
            f.seek(4 + 16 + 64); base = 0; count, = struct.unpack('<I', f.read(4))
            f.seek(4 + 16 + 64 + 4)
        total = os.path.getsize(path); out = []
        for _ in range(count):
            n, = struct.unpack('<I', f.read(4)); name = f.read(n).rstrip(b'\0').decode('utf-8', 'replace')
            ofs, size = struct.unpack('<QQ', f.read(16)); f.read(16)
            if fmt >= 2: f.read(4)   # per-file flags (encryption, removal)
            o = base + ofs if fmt >= 2 and base + ofs + size <= total else ofs
            out.append((name, o, size))
        return out


def glslc_outputs(d):
    """Whole GLSLC outputs in a buffer: [(offset, bytes)]."""
    found, i = [], 0
    mg = struct.pack('<I', GLSLC_MAGIC)
    while True:
        i = d.find(mg, i)
        if i < 0 or i + 0x48 > len(d): return found
        n, = struct.unpack_from('<I', d, i + 0x44)
        if 0x48 <= n <= len(d) - i: found.append((i, d[i:i + n])); i += n
        else: i += 4


def blobs(d, unz):
    """The buffer itself, then every zstd frame and zlib stream in it decompressed (Godot compresses each stage's code on its own)."""
    yield 'stored', d
    i = 0
    while unz:
        i = d.find(ZSTD_MAGIC, i)
        if i < 0: break
        try:
            out = unz(d[i:])
            if out: yield 'zstd', out
        except Exception:
            pass
        i += 4
    for j in range(len(d) - 1):
        if d[j] == 0x78 and d[j + 1] in (0x01, 0x5e, 0x9c, 0xda) and (d[j] << 8 | d[j + 1]) % 31 == 0:
            try:
                out = zlib.decompressobj().decompress(d[j:])
                if len(out) >= 0x48: yield 'zlib', out
            except zlib.error:
                pass


def fnv(b):
    h = 0xcbf29ce484222325
    for c in b: h = ((h ^ c) * 0x100000001b3) & 0xffffffffffffffff
    return h


def packs(src):
    """The Godot packs under a RomFS folder (or the one .pck file named)."""
    if os.path.isfile(src): return [src]
    return sorted(os.path.join(r, f) for r, _, fs in os.walk(src) for f in fs if f.lower().endswith('.pck'))


def outputs(pk, unz, stats=None):
    """(container path, decompression kind, GLSLC output) of every whole output in a pack's .w4_shader containers, each distinct output once."""
    seen = set()
    try: files = pck_files(pk)
    except (ValueError, struct.error) as e:
        print(f'godot_w4: {e}'); return
    with open(pk, 'rb') as f:
        for name, o, size in files:
            if not name.endswith('.w4_shader'): continue
            if stats is not None: stats['containers'] += 1
            f.seek(o); d = f.read(size); got = 0
            for kind, b in blobs(d, unz):
                for _, g in glslc_outputs(b):
                    h = fnv(g)
                    if h in seen: continue
                    seen.add(h); got += 1
                    yield name, kind, g
            if stats is None: continue
            if got: stats['with_outputs'] += 1
            else:
                stats['unread'] += 1
                if stats.get('first_unread') is None: stats['first_unread'] = (name, d[:64])


def extract(src, out):
    paks = packs(src)
    unz = _zstd()
    if not unz: print('godot_w4: no zstd module (Python 3.14, or pip install zstandard): only code stored uncompressed is found')
    os.makedirs(out, exist_ok=True)
    seen, stats = set(), {'containers': 0, 'with_outputs': 0, 'stored': 0, 'zstd': 0, 'zlib': 0, 'unread': 0, 'first_unread': None}
    for pk in paks:
        for name, kind, g in outputs(pk, unz, stats):
            h = fnv(g)
            if h in seen: continue
            seen.add(h); stats[kind] += 1
            p = os.path.join(out, f'{h:016x}.glslc')
            if not os.path.exists(p):
                with open(p + '.tmp', 'wb') as w: w.write(g)
                os.replace(p + '.tmp', p)
    print(f'godot_w4: {stats["containers"]} shader containers in {len(paks)} pack(s); {stats["with_outputs"]} gave GLSLC outputs: '
          f'{len(seen)} distinct ({stats["stored"]} stored, {stats["zstd"]} zstd, {stats["zlib"]} zlib) → {out}')
    if stats['unread']:
        n, head = stats['first_unread']
        print(f'godot_w4: [RED] {stats["unread"]} containers gave no GLSLC output; the first, {n}, starts {head.hex()}')
    return len(seen)


def keys(src, want):
    os.environ.setdefault('DM_GAME', '0100000000010000')   # shader_split.py loads a profile at import; only its GLSLC reader is used here
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import shader_split
    unz = _zstd(); got = {}
    for pk in packs(src):
        for name, _, g in outputs(pk, unz):
            for w, st, c, k in shader_split.glslc_shaders(g, name, need=False): got.setdefault(shader_split.skey(c, k), (st, name))
    print(f'godot_w4: {len(got)} shader keys')
    for k in want: print(f'  {k}: ' + (f'found, stage {got[k][0]}, {got[k][1]}' if k in got else 'NOT found'))
    return all(k in got for k in want)


if __name__ == '__main__':
    if len(sys.argv) == 4 and sys.argv[2] == '--keys': sys.exit(0 if keys(sys.argv[1], [k for k in sys.argv[3].split(',') if k]) else 1)
    if len(sys.argv) != 3: sys.exit(__doc__)
    sys.exit(0 if extract(sys.argv[1], sys.argv[2]) else 1)
