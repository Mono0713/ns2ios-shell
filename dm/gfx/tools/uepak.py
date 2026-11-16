#!/usr/bin/env python3
# Unreal Engine game files for the shader tools: pak files (version 11, UE 4.26 and later; Octopath Traveler 0 is UE5), shader code archives (.ushaderbytecode version 2) and the job files the Mac host decodes Oodle with
# (DM_OODLE_JOB, dm/host/hle_oodle.c). Octopath Traveler 0 keeps everything in one pak, Octopath_Traveler0/Content/Paks/pakchunk0-Switch.pak (1.5 GB, 159,757 files): its index is AES-256 encrypted,
# its files are stored or Oodle-compressed in blocks. Its two shader code archives are stored, but every shader inside is Oodle-compressed (Mermaid, block header 8C 0A), which no decoder in this
# repository can undo, so the game's own OodleLZ_Decompress decodes them in the Mac host (the NSP script's decode_ue_shaders, for any game with Unreal paks).
# Unreal Engine 4.27 (DRAGON QUEST VII Reimagined) keeps its packages in IoStore containers (.utoc / .ucas) and the rest in pakchunk0-Switch.pak (3,972 files, index not encrypted), among them
#   two stored shader code archives (ShaderArchive-Global-SF_GLSL_SWITCH, 1,764 shaders, and ShaderArchive-DOLL_Chunk0-SF_GLSL_SWITCH, 63,185): every shader in them is an LZ4 block, the
#   engine's default shader compression since 4.26, decoded here (lz4_shaders) without the host.
# Unreal Engine 5.6 (FINAL FANTASY RESONANCE) has no shader code archive in its pak (FFRS-Switch.pak holds configs only): the cooker converted both libraries into its IoStore container
#   (FFRS-Switch.utoc / .ucas, Oodle in 64 KB blocks, not encrypted) as one ShaderCodeLibrary chunk each (the tables) and one ShaderCode chunk per group of shaders, every group Oodle-compressed
#   on its own (Toc, io_archive). Both layers need the game's decoder, which runs in the Mac host's tool mode (OodleHost); the libraries come out as version 2 archives with every shader decoded.
# The AES key is in main (Unreal embeds it): the 32-byte window of main's read-only or data segment that decrypts the index start to its mount point ("../../../"; Octopath Traveler 0: one window of
#   116,287 tried). It is only kept in memory, never printed or written.
# Pak footer (version 11, the last 0xdd bytes): encryption key GUID (16), encrypted index flag (u8), magic 0x5A6F12E1, version (u32), index offset (u64), index size (u64), index SHA-1 (20),
#   5 compression method names (32 bytes each).
# Index: mount point (FString), entry count (i32), path hash seed (u64), path hash index (i32 flag, then u64 offset, u64 size, SHA-1), full directory index (the same, encrypted like the index),
#   encoded entries (i32 size + bytes), the count of unencoded entries (0 here). Directory index: i32 count, then per directory its name (FString) and its files (i32 count, then name + i32 offset into
#   the encoded entries). FString: i32 length with the NUL, UTF-8; a negative length is UTF-16.
# Encoded entry: u32 bits (0-5 compression block size >> 11, 0x3f = a u32 follows; 6-21 block count; 22 encrypted; 23-28 compression method, 1-based; 29 stored size fits 32 bits; 30 raw size fits
#   32 bits; 31 offset fits 32 bits), then offset, raw size, stored size (compressed entries only) and, for several blocks or an encrypted one, each block's u32 stored size. The data starts after
#   the FPakEntry the pak repeats in front of it (53 bytes, + 4 + 16 per block when compressed); blocks follow each other, 16-aligned when encrypted.
# Older paks (version 4, UE 4.18: DRAGON QUEST XI S, pakchunk0-Switch.pak 6.6 GB / 264,844 files and pakchunk1-Switch.pak 7.2 GB / 147,824 files, the update's *_0_P.pak beside them) keep the
#   legacy layout. Footer (the last 0x2d bytes): encrypted index flag (u8), magic, version, index offset, index size, SHA-1. Index: mount point, entry count, then per file its name (relative to the
#   mount point) and its FPakEntry: offset, stored size, raw size (i64 each), compression flags (i32), SHA-1 (20), for a compressed file the block count (i32) and each block's start and end
#   (i64, from the file start before version 5, from the entry after), the encrypted flag (u8) and the compression block size (u32). The FPakEntry is repeated in front of the data.
#   The compression flags are no names: 1 zlib, 2 gzip, 4 custom; DRAGON QUEST XI S's engine uses 3, which is LZ5 2.0 (main exports LZ5_*; every block starts with its level, 0x2d = 45), and only the
#   game's own decoder reads it (hle_oodle.c, through a decode function given to Pak.read).
# Unreal Engine 4.27 with bShareMaterialShaderCode off (OCTOPATH TRAVELER II: Majesty/Content/Paks/Majesty-Switch.pak, version 11, 3.3 GB / 376,601 files, index not encrypted, Zlib blocks)
#   has no shader code archive at all: each material keeps its shaders in its own cooked package (.uexp) and the engine's global shaders are in Engine/GlobalShaderCache-SF_GLSL_SWITCH.bin,
#   every shader an LSLG record stored without compression, as in a legacy pak (inline_shaders; shader_split.py ue_legacy_jobs reads them). Zlib and LZ4 blocks are decoded here (Pak.read).
# Shader code archive (version 2): shader map hashes (20 bytes each), shader hashes (20 each), shader map entries {u32 first index, u32 shader count, u32 first preload, u32 preload count}, shader
#   entries {u64 offset, u32 size, u32 raw size, u8 frequency} (17 bytes, packed), preload entries (16 each), shader indices (u32): each array is a u32 count and its elements; the code follows,
#   offsets relative to its start. A shader whose size differs from its raw size is compressed.
# Usage: uepak.py probe <RomFS> <main NSO> [<oodle_serve>]               what the shader tools see in the paks and IoStore containers (a game they do not read yet)
#        uepak.py list <pak> <main NSO> <out tsv>                       every file in the pak: path, raw size, stored size, compression, encrypted, blocks
#        uepak.py job <RomFS> <main NSO> <work dir> [<Mac host> <rewritten modules> | <oodle_serve>]   the shader code archives of every pak, and an Oodle job of their Oodle-compressed shaders (LZ4 ones
#                                                                       decoded at once); IoStore shader libraries (UE 5.6) decoded at once through the game's Oodle in the host (OodleHost)
#        uepak.py finish <work dir> <out dir>                           after the host has run the job: the archives with every shader decoded
import ctypes, json, os, struct, sys

PAK_MAGIC, ARCHIVE_VERSION = 0x5A6F12E1, 2
JOB_MAGIC, OUT_MAGIC = 0x4a4f4d44, 0x524f4d44   # "DMOJ", "DMOR" (hle_oodle.c)
FREQ = {0: 'vs', 1: 'hs', 2: 'ds', 3: 'ps', 4: 'gs', 5: 'cs'}   # EShaderFrequency (the archive's frequency census: 0 vertex, 3 pixel, 5 compute)

_aes = None
def _aes_backend():
    """AES-256 ECB decryption with what the system has, no Python package needed: CommonCrypto on a Mac, CNG (bcrypt.dll) on Windows (the Windows packer, nxn_pack.py),
    OpenSSL's libcrypto elsewhere (Linux tests). → decrypt(key, data)"""
    if sys.platform == 'darwin':
        cc = ctypes.CDLL('/usr/lib/libSystem.B.dylib').CCCrypt
        cc.restype = ctypes.c_int32
        cc.argtypes = [ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t)]
        def dec(key, data):
            out = ctypes.create_string_buffer(len(data)); moved = ctypes.c_size_t()
            if cc(1, 0, 2, key, len(key), None, data, len(data), out, len(data), ctypes.byref(moved)): raise ValueError('CCCrypt failed')   # decrypt, AES, ECB
            return out.raw[:moved.value]
        return dec
    if os.name == 'nt':
        bc = ctypes.WinDLL('bcrypt.dll'); h = ctypes.c_void_p()
        if bc.BCryptOpenAlgorithmProvider(ctypes.byref(h), ctypes.c_wchar_p('AES'), None, 0): raise OSError('BCryptOpenAlgorithmProvider(AES) failed')
        mode = ctypes.create_unicode_buffer('ChainingModeECB')
        if bc.BCryptSetProperty(h, ctypes.c_wchar_p('ChainingMode'), mode, ctypes.sizeof(mode), 0): raise OSError('BCryptSetProperty(ChainingModeECB) failed')
        keys = {}
        def dec(key, data):
            k = keys.get(key)
            if k is None:
                if len(keys) > 64: keys.clear()   # find_key tries one window after another: keep only a few handles (they are small; the process ends soon after)
                k = ctypes.c_void_p()
                if bc.BCryptGenerateSymmetricKey(h, ctypes.byref(k), None, 0, ctypes.c_char_p(bytes(key)), len(key), 0): raise ValueError('BCryptGenerateSymmetricKey failed')
                keys[key] = k
            out = ctypes.create_string_buffer(len(data)); got = ctypes.c_ulong()
            if bc.BCryptDecrypt(k, ctypes.c_char_p(bytes(data)), len(data), None, None, 0, out, len(data), ctypes.byref(got), 0): raise ValueError('BCryptDecrypt failed')
            return out.raw[:got.value]
        return dec
    from ctypes.util import find_library   # (import ctypes.util here would make ctypes local to the whole function: UnboundLocalError on Windows and the Mac)
    lc = ctypes.CDLL(find_library('crypto') or 'libcrypto.so')
    lc.EVP_CIPHER_CTX_new.restype = ctypes.c_void_p; lc.EVP_aes_256_ecb.restype = ctypes.c_void_p
    for f in (lc.EVP_DecryptInit_ex, lc.EVP_CIPHER_CTX_set_padding, lc.EVP_DecryptUpdate, lc.EVP_CIPHER_CTX_free): f.argtypes = None
    def dec(key, data):
        c = ctypes.c_void_p(lc.EVP_CIPHER_CTX_new()); out = ctypes.create_string_buffer(len(data) + 32); n = ctypes.c_int()
        try:
            lc.EVP_DecryptInit_ex(c, ctypes.c_void_p(lc.EVP_aes_256_ecb()), None, ctypes.c_char_p(bytes(key)), None); lc.EVP_CIPHER_CTX_set_padding(c, 0)
            if not lc.EVP_DecryptUpdate(c, out, ctypes.byref(n), ctypes.c_char_p(bytes(data)), len(data)): raise ValueError('EVP_DecryptUpdate failed')
        finally: lc.EVP_CIPHER_CTX_free(c)
        return out.raw[:n.value]
    return dec

def aes_decrypt(key, data):
    """AES-256 ECB decryption (_aes_backend)"""
    global _aes
    if _aes is None: _aes = _aes_backend()
    return _aes(key, data)

_M, _K0, _K1, _K2 = (1 << 64) - 1, 0xc3a5c85c97cb3127, 0xb492b66fbe98f273, 0x9ae16a3b2f90404f
def _rot(v, s): return ((v >> s) | (v << (64 - s))) & _M if s else v
def _f64(s, i): return struct.unpack_from('<Q', s, i)[0]
def _bswap(v): return int.from_bytes((v & _M).to_bytes(8, 'little'), 'big')
def _h16(u, v, mul=0x9ddfea08eb382d69):
    a = ((u ^ v) * mul) & _M; a ^= a >> 47
    b = ((v ^ a) * mul) & _M; b ^= b >> 47
    return (b * mul) & _M
def _weak(s, i, a, b):
    w, x, y, z = _f64(s, i), _f64(s, i + 8), _f64(s, i + 16), _f64(s, i + 24)
    a = (a + w) & _M; b = _rot((b + a + z) & _M, 21); c = a
    a = (a + x + y) & _M; b = (b + _rot(a, 44)) & _M
    return ((a + z) & _M, (b + c) & _M)
def city64(s):
    """CityHash64 (Google's CityHash 1.1, the one Unreal's Core links; checked against python-cityhash 0.4.10 on 1,500 random inputs of 0 to 299 bytes)"""
    n = len(s)
    if n <= 16:
        if n >= 8:
            mul = _K2 + n * 2; a = (_f64(s, 0) + _K2) & _M; b = _f64(s, n - 8)
            return _h16((_rot(b, 37) * mul + a) & _M, ((_rot(a, 25) + b) * mul) & _M, mul)
        if n >= 4:
            mul = _K2 + n * 2
            return _h16((n + (struct.unpack_from('<I', s, 0)[0] << 3)) & _M, struct.unpack_from('<I', s, n - 4)[0], mul)
        if n:
            y, z = s[0] + (s[n >> 1] << 8), n + (s[n - 1] << 2); v = ((y * _K2) ^ (z * _K0)) & _M
            return ((v ^ (v >> 47)) * _K2) & _M
        return _K2
    mul = _K2 + n * 2
    if n <= 32:
        a = (_f64(s, 0) * _K1) & _M; b = _f64(s, 8); c = (_f64(s, n - 8) * mul) & _M; d = (_f64(s, n - 16) * _K2) & _M
        return _h16((_rot((a + b) & _M, 43) + _rot(c, 30) + d) & _M, (a + _rot((b + _K2) & _M, 18) + c) & _M, mul)
    if n <= 64:
        a = (_f64(s, 0) * _K2) & _M; b = _f64(s, 8); c = _f64(s, n - 24); d = _f64(s, n - 32)
        e = (_f64(s, 16) * _K2) & _M; f = (_f64(s, 24) * 9) & _M; g = _f64(s, n - 8); h = (_f64(s, n - 16) * mul) & _M
        u = (_rot((a + g) & _M, 43) + (_rot(b, 30) + c) * 9) & _M; v = (((a + g) ^ d) + f + 1) & _M
        w = (_bswap((u + v) * mul) + h) & _M; x = (_rot((e + f) & _M, 42) + c) & _M
        y = ((_bswap((v + w) * mul) + g) * mul) & _M; z = (e + f + c) & _M
        a = (_bswap((x + z) * mul + y) + b) & _M; b = ((z + a) * mul + d + h) & _M; b = ((b ^ (b >> 47)) * mul) & _M
        return (b + x) & _M
    x = _f64(s, n - 40); y = (_f64(s, n - 16) + _f64(s, n - 56)) & _M; z = _h16((_f64(s, n - 48) + n) & _M, _f64(s, n - 24))
    v = _weak(s, n - 64, n, z); w = _weak(s, n - 32, (y + _K1) & _M, x); x = (x * _K1 + _f64(s, 0)) & _M
    left, i = (n - 1) & ~63, 0
    while left:
        x = (_rot((x + y + v[0] + _f64(s, i + 8)) & _M, 37) * _K1) & _M
        y = (_rot((y + v[1] + _f64(s, i + 48)) & _M, 42) * _K1) & _M
        x ^= w[1]; y = (y + v[0] + _f64(s, i + 40)) & _M; z = (_rot((z + w[0]) & _M, 33) * _K1) & _M
        v = _weak(s, i, (v[1] * _K1) & _M, (x + w[0]) & _M); w = _weak(s, i + 32, (z + w[1]) & _M, (y + _f64(s, i + 16)) & _M)
        z, x = x, z; i += 64; left -= 64
    return _h16((_h16(v[0], w[0]) + (y ^ (y >> 47)) * _K1 + z) & _M, (_h16(v[1], w[1]) + x) & _M)

def nso_image(path):
    """A decompressed NSO image and its (read-only start, data end)"""
    import lz4.block
    d = open(path, 'rb').read()
    flags = struct.unpack_from('<I', d, 0xc)[0]; segs = [struct.unpack_from('<III', d, 0x10 + i * 0x10) for i in range(3)]; csz = struct.unpack_from('<III', d, 0x60)
    img = bytearray(segs[2][1] + segs[2][2])
    for i, (fo, mo, sz) in enumerate(segs):
        raw = d[fo:fo + csz[i]]
        img[mo:mo + sz] = lz4.block.decompress(raw, uncompressed_size=sz) if flags >> i & 1 else raw
    return bytes(img), segs[1][1], segs[2][1] + segs[2][2]

class OodleHost:
    """The game's own OodleLZ_Decompress in the Mac host's tool mode (DM_OODLE_SERVE, dm/host/hle_oodle.c: served before the SDK starts, so no boot), called as decode(compressed, raw length).
    host = the Mac host built for the game, modules = its rewritten modules, env = the host's environment (default: this process's)"""
    what = "the game's Oodle in the Mac host"
    def __init__(self, host, modules, env=None):
        import subprocess, tempfile
        self.err = tempfile.TemporaryFile()
        self.p = subprocess.Popen([os.path.abspath(str(host)), str(modules)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.err, env=dict(env or os.environ, DM_OODLE_SERVE='1'))
        self.n = 0
    def __call__(self, comp, n):
        try:
            self.p.stdin.write(struct.pack('<QQ', len(comp), n)); self.p.stdin.write(comp); self.p.stdin.flush()
            got = struct.unpack('<Q', self.p.stdout.read(8))[0]
        except (BrokenPipeError, struct.error): got = None
        if got != n:
            self.err.seek(0)
            raise ValueError(f'{self.what} failed on a {len(comp)} → {n} byte stream; ---- output ----\n' + self.err.read().decode(errors='replace')[-3000:])
        self.n += 1
        return self.p.stdout.read(n)
    def close(self):
        if self.p.poll() is None:
            self.p.stdin.close()
            try: self.p.wait(10)
            except Exception: self.p.kill()

class Ooz(OodleHost):
    """Oodle without the game: ooz, Powzix's open-source decoder (Kraken, Mermaid, Selkie, Leviathan, LZNA, BitKnit), as oodle_serve (dm/tools/oodle_serve; oodle_serve.exe in the Windows
    tools), which answers the requests of the Mac host's tool mode; decode(compressed, raw length) like OodleHost. The Windows packer decodes Unreal games' shaders with it (nxn_pack.py ue_decode)"""
    what = 'ooz (oodle_serve)'
    def __init__(self, exe): super().__init__(exe, '-')

def probe(romfs, mains=()):
    """What the shader tools see in an Unreal game's RomFS, as lines of text: each pak (version, encryption, compression methods, files, shader code archives with their version, shader
    count and compression, the first bytes of a compressed shader), each IoStore container (version, chunks of each shader type, methods). For a game the tools do not read yet"""
    out, keys = [], Keys(mains)
    for pak in paks(romfs):
        rel = os.path.relpath(pak, romfs)
        try:
            with open(pak, 'rb') as f: enc, ioff, isz, meths, ver = footer(f)
        except Exception as x: out.append(f'{rel}: no pak footer read ({x})'); continue
        line = f'{rel}: pak version {ver}, {os.path.getsize(pak) / 1e6:,.0f} MB, index {"encrypted" if enc else "plain"}, methods {[m for m in meths if m]}'
        try: k = keys(pak)
        except Exception as x: out.append(line + f'; no key ({x})'); continue
        try: p = Pak(pak, k)
        except Exception as x: out.append(line + f'; index not read ({x})'); continue
        exts = {}
        for n in p.files: e = os.path.splitext(n)[1].lower(); exts[e] = exts.get(e, 0) + 1
        out.append(line + f'; {len(p.files):,} files, mount {p.mount}, inline {inline_shaders(pak, k)}; ' + ', '.join(f'{e or "(none)"} {c:,}' for e, c in sorted(exts.items(), key=lambda x: -x[1])[:12]))
        for n in sorted(x for x in p.files if x.endswith('.ushaderbytecode') or 'GlobalShaderCache' in x or x.endswith('.ushadercode')):
            e = p.entry(n); line = f'    {n}: {e["raw"]:,} bytes, method {e["method"] or "stored"}, {len(e["blocks"])} block(s)'
            try: b = p.read(n, getattr(probe, 'decode', None))
            except Exception as x: out.append(line + f'; not read ({x})'); continue
            line += f'; version {struct.unpack_from("<I", b)[0]}, head {b[:16].hex()}'
            try:
                a = archive(b); comp = [(i, sh) for i, sh in enumerate(a['shaders']) if sh[1] != sh[2]]
                line += f'; {len(a["shaders"]):,} shaders, {len(comp):,} compressed'
                if comp:
                    i, (off, size, raw, fr) = comp[0]; c = b[a['code'] + off:a['code'] + off + size]
                    line += f', LZ4 {"yes" if lz4_shaders(b, a) else "no"}, first {size} → {raw} bytes: {c[:12].hex()}'
                else:
                    off, size, raw, fr = a['shaders'][0]; line += f', first: {b[a["code"] + off:a["code"] + off + 8].hex()}'
            except Exception as x: line += f'; not a version {ARCHIVE_VERSION} archive ({x})'
            out.append(line)
    for tp in sorted(os.path.join(dp, f) for dp, _, fs in os.walk(romfs) for f in fs if f.endswith('.utoc')):
        try:
            t = Toc(tp); kinds = {}
            for c in t.ids: kinds[c[11]] = kinds.get(c[11], 0) + 1
            out.append(f'{os.path.relpath(tp, romfs)}: TOC version {t.version}, {len(t.ids):,} chunks, encrypted {t.encrypted}, methods {getattr(t, "methods", "?")}, chunk types {dict(sorted(kinds.items()))}')
        except Exception as x: out.append(f'{os.path.relpath(tp, romfs)}: not read ({x})')
    return out

class R:
    def __init__(self, b, o=0): self.b, self.o = b, o
    def take(self, fmt):
        v = struct.unpack_from(fmt, self.b, self.o); self.o += struct.calcsize(fmt); return v if len(v) > 1 else v[0]
    def raw(self, n): v = self.b[self.o:self.o + n]; self.o += n; return v
    def fstr(self):
        n = self.take('<i')
        if n < 0: return self.raw(-2 * n).decode('utf-16-le')[:-1]
        return self.raw(n)[:-1].decode('utf-8', 'replace') if n else ''

LEGACY = (4, 5, 6, 7, 8, 9)   # pak versions with the per-file index; 10 and 11 have the encoded one. Version 8 (UE 4.22 to 4.25; upstream: DRAGON BALL Z: KAKAROT) keeps version 4's index with the
#   FPakEntry compression method as an index (from 1) into the footer's method names, and version 11's footer: key GUID, encrypted flag, magic 0xcc from the end, the names after the SHA-1
LEGACY_METHODS = {1: 'Zlib', 2: 'Gzip', 3: 'LZ5', 4: 'Custom'}   # compression flags of a legacy pak (3: DRAGON QUEST XI S's engine, see the header)

def magic_back(f):
    """(how far from the end the footer's magic is, the pak version): a footer before version 8 is the last 0x2d bytes (magic 0x2c from the end); from version 8 the compression method
    names follow it, 32 bytes each: 4 or 5 of them (magic 0xac / 0xcc from the end; Octopath Traveler 0 (UE5): 0xc8), and version 9 has a frozen index flag before them (0xad / 0xcd;
    Guilty Gear Strive: 0xcd)"""
    size = f.seek(0, 2)
    for back in (0x2c, 0xcc, 0xc8, 0xcd, 0xac, 0xad):
        if size < back + 1: continue   # shorter than this footer
        f.seek(-back, 2); m, ver = struct.unpack('<II', f.read(8))
        if m == PAK_MAGIC: return back, ver
    raise ValueError('no pak footer')

def pak_version(f):
    return magic_back(f)[1]

def footer(f):
    """(encrypted index, index offset, index size, compression method names by number from 1, version). From the encrypted flag on: flag (u8), magic, version, index offset, index size,
    SHA-1 (20), for version 9 the frozen index flag (u8), from version 8 the method names; versions 7 and later put the key GUID (16) in front"""
    back, ver = magic_back(f)
    if ver < 4 or ver > 11 or (ver >= 8) == (back == 0x2c): raise ValueError(f'pak version {ver} (footer magic {back:#x} from the end): versions 4 to 11 are read')
    f.seek(-(back + 1), 2); ft = f.read(back + 1)
    ioff, isz = struct.unpack_from('<QQ', ft, 9); k = 45
    if ver == 9:
        if ft[k]: raise ValueError('a frozen pak index (version 9 with bIndexIsFrozen): not read')
        k += 1
    if ver < 8: methods = [LEGACY_METHODS.get(i, f'flags {i}') for i in range(1, 8)]
    else: methods = [ft[k + 32 * i:k + 32 * i + 32].rstrip(b'\0').decode('latin1') for i in range((len(ft) - k + 31) // 32)]
    return ft[0], ioff, isz, methods, ver

def code_keys(img, lo):
    """32-byte keys that main's code stores from two 16-byte literals: stp qA, qB, [x0] after ldr qA / qB, each from an adrp page plus its offset, within 8 instructions before it.
    UE_REGISTER_ENCRYPTION_KEY's callback copies a 32-byte array into its argument, and clang may split the array into two 16-byte constants that do not lie side by side
    (DRAGON QUEST III HD-2D Remake: main+0xa3fd24 is adrp, adrp, ldr q0, ldr q1, stp q0, q1, [x0], ret), so no window of main holds the key"""
    w = struct.unpack_from(f'<{lo // 4}I', img)
    out = []
    for i, x in enumerate(w):
        if x & 0xFFFF83E0 != 0xAD000000: continue   # stp qA, qB, [x0, #0] (signed offset)
        page, half = {}, {}
        for j in range(max(0, i - 8), i):
            y = w[j]
            if y & 0x9F000000 == 0x90000000:   # adrp: the page of pc + the 21-bit immediate pages
                imm = (y >> 29 & 3) | (y >> 5 & 0x7FFFF) << 2
                page[y & 31] = (j * 4 & ~0xFFF) + ((imm - (1 << 21) if imm & 1 << 20 else imm) << 12)
            elif y & 0xFFC00000 == 0x3DC00000 and (y >> 5 & 31) in page:   # ldr qT, [xN, #imm12 * 16] on an adrp base
                half[y & 31] = page[y >> 5 & 31] + (y >> 10 & 0xFFF) * 16
            else: page.pop(y & 31, None); half.pop(y & 31, None)   # anything else that may write the register ends what it held
        a, b = half.get(x & 31), half.get(x >> 10 & 31)
        if a is not None and b is not None and a + 16 <= len(img) and b + 16 <= len(img): out.append(img[a:a + 16] + img[b:b + 16])
    return out

def find_key(img, lo, hi, pak, first=()):
    """The AES key that decrypts the index start to a short mount point: one of first (a key another pak of the game opened with), one main's code stores from two 16-byte literals
    (code_keys), else one of main's 32-byte windows (read-only and data segments, 4-aligned, at least 20 distinct bytes)"""
    with open(pak, 'rb') as f:
        _, ioff, _, _, _ = footer(f); f.seek(ioff); blk = f.read(16)
    def opens(k):   # the index starts with its mount point, an FString: length with the NUL (< 512), then a path from "." or "/": "../../../", or "/" in the empty paks beside
        d = aes_decrypt(k, blk)   # IoStore containers (DRAGON BALL Sparking! ZERO's pakchunk1-17); the 12 bytes the block holds are printable up to the NUL
        n = struct.unpack_from('<i', d)[0]
        if not 1 < n < 512 or d[4] not in b'./': return False
        s = d[4:min(4 + n, 16)]
        return all(0x20 <= c < 0x7F for c in s[:n - 1]) and (len(s) < n or s[n - 1] == 0)
    for k in first:   # before code_keys, which reads all of main's code
        if opens(k): return k
    for k in code_keys(img, lo):
        if opens(k): return k
    for a in range(lo, hi - 32, 4):
        w = img[a:a + 32]
        if len(set(w)) >= 20 and opens(w): return w
    return None

class Keys:
    """The AES keys of a game's paks, from its mains (the ExeFS main of each version, base game first): keys(pak) → None for a pak whose index is not encrypted, else the key find_key finds,
    trying each main in turn; ValueError when none opens it. Each main is loaded once, at the first encrypted pak, and a key found is tried first on the next pak, so a game's
    second pak or version does not search main again (the shader code archives, job; the paks with the shaders inline, shader_split.py ue_legacy_jobs)"""
    def __init__(self, mains):
        self.mains, self.imgs, self.found = list(mains), {}, []
    def __call__(self, pak):
        with open(pak, 'rb') as f: enc = footer(f)[0]
        if not enc: return None
        for m in self.mains:
            if m not in self.imgs: self.imgs[m] = nso_image(m)
            img, lo, hi = self.imgs[m]
            k = find_key(img, lo, hi, pak, first=self.found)
            if k:
                if k not in self.found: self.found.append(k)
                return k
        raise ValueError(f'{pak}: the index is encrypted and no key in main (a 32-byte window or two 16-byte literals its code stores together) decrypts it')

class Pak:
    def __init__(self, path, key=None):
        self.path, self.key = path, key; self.f = open(path, 'rb')
        enc, ioff, isz, self.methods, self.version = footer(self.f)
        if enc and not key: raise ValueError(f'{path}: the index is encrypted and no key was given')
        r = R(self.read_at(ioff, isz, enc))
        self.mount = r.fstr(); self.count = r.take('<i')
        if self.version in LEGACY:   # one FPakEntry per file, kept as parsed
            self.files = {}
            for _ in range(self.count):
                name = r.fstr(); off, size, raw, meth = r.take('<qqqi'); r.raw(20)
                blocks = [r.take('<qq') for _ in range(r.take('<i'))] if meth else []
                e, bsz = r.take('<BI'); head = 53 + (4 + 16 * len(blocks) if meth else 0)
                if self.version < 5: blocks = [(s - off, t - s) for s, t in blocks]
                else: blocks = [(s, t - s) for s, t in blocks]
                self.files[name] = dict(off=off, raw=raw, size=size, method=(LEGACY_METHODS.get(meth, f'flags {meth}') if self.version < 8 else self.methods[meth - 1] if 0 < meth <= len(self.methods) else f'method {meth}') if meth else '', encrypted=e, block_size=bsz, blocks=blocks or [(head, size)])
            return
        r.take('<Q')
        if r.take('<i'): r.take('<QQ'); r.raw(20)   # path hash index (not needed with the full directory index)
        if not r.take('<i'): raise ValueError(f'{path}: no full directory index')
        doff, dsz = r.take('<QQ'); r.raw(20)
        self.enc = r.raw(r.take('<i'))
        if r.take('<i'): raise ValueError(f'{path}: unencoded entries are not read')
        d = R(self.read_at(doff, dsz, enc)); self.files = {}
        for _ in range(d.take('<i')):
            dn = d.fstr()
            for _ in range(d.take('<i')): fn = d.fstr(); self.files[(dn + fn).lstrip('/')] = d.take('<i')
    def read_at(self, off, n, enc):
        self.f.seek(off); b = self.f.read((n + 15) & ~15 if enc else n)
        return aes_decrypt(self.key, b)[:n] if enc else b
    def entry(self, path):
        if self.version in LEGACY: return self.files[path]
        r = R(self.enc, self.files[path]); v = r.take('<I')
        bsz = (v & 0x3f) << 11
        if v & 0x3f == 0x3f: bsz = r.take('<I')
        nblk, enc, meth = v >> 6 & 0xffff, v >> 22 & 1, v >> 23 & 0x3f
        off = r.take('<I' if v >> 31 & 1 else '<Q'); raw = r.take('<I' if v >> 30 & 1 else '<Q')
        size = r.take('<I' if v >> 29 & 1 else '<Q') if meth else raw
        cur, blocks = 53 + (4 + 16 * nblk if meth else 0), []
        if nblk == 1 and not bsz: bsz = raw   # FINAL FANTASY RESONANCE's pak (UE 5.6) stores block size 0 for a file of one block
        if nblk == 1 and not enc: blocks = [(cur, size)]
        else:
            for _ in range(nblk): s = r.take('<I'); blocks.append((cur, s)); cur += (s + 15) & ~15 if enc else s
        return dict(off=off, raw=raw, size=size, method=self.methods[meth - 1] if meth else '', encrypted=enc, block_size=bsz, blocks=blocks)
    def read(self, path, decode=None):
        """A file's bytes, block by block (each block holds block_size raw bytes, the last one the rest). Zlib and LZ4 blocks are decoded here (OCTOPATH TRAVELER II: Zlib); any other
        method needs decode(block bytes, raw length) → bytes: the game's own decoder in the Mac host (shader_split.py oodle); Octopath Traveler 0's archives go through the Oodle job instead"""
        e = self.entry(path)
        if not e['method']: return self.read_at(e['off'] + 53, e['size'], e['encrypted'])
        if e['method'] == 'Zlib': import zlib; decode = lambda b, k: zlib.decompress(b)
        elif e['method'] == 'LZ4': import lz4.block; decode = lambda b, k: lz4.block.decompress(b, uncompressed_size=k)
        elif e['method'].lower() == 'zstd': decode = zstd_block   # Guilty Gear Strive (version 9: zstd and Zlib)
        elif not decode: raise ValueError(f'{path} is {e["method"]}-compressed in the pak')
        out, left = [], e['raw']
        for s, n in e['blocks']:
            k = min(left, e['block_size']); out.append(decode(self.read_at(e['off'] + s, n, e['encrypted']), k)); left -= k
        return b''.join(out)

_zstd = None
def zstd_block(b, k):
    """A zstd frame of k raw bytes: compression.zstd (Python 3.14), its backport (pip install backports.zstd) or the zstandard package, else the zstd command (zstd.exe in the Windows tools)"""
    global _zstd
    if _zstd is None:
        for mod in ('compression.zstd', 'backports.zstd', 'zstandard'):
            try: m = __import__(mod, fromlist=['x']); break
            except ImportError: m = None
        if m is not None and mod == 'zstandard': _zstd = lambda b, k: m.ZstdDecompressor().decompress(b, max_output_size=max(k, 1))
        elif m is not None: _zstd = lambda b, k: m.decompress(b)
        else:
            import shutil, subprocess
            exe = shutil.which('zstd')
            if not exe: raise ValueError('zstd-compressed pak blocks: this Python has no zstd module (pip install backports.zstd) and there is no zstd command')
            _zstd = lambda b, k: subprocess.run([exe, '-d', '-c', '-q'], input=b, stdout=subprocess.PIPE, check=True).stdout
    return _zstd(b, k)

def archive(b):
    """A shader code archive's tables: {'maps': [(first index, count)], 'shaders': [(offset, size, raw size, frequency)], 'indices': [...], 'code': start of the code}"""
    r = R(b)
    if r.take('<I') != ARCHIVE_VERSION: raise ValueError('not a version 2 shader code archive')
    nmap = r.take('<I'); r.raw(20 * nmap); nsh = r.take('<I'); r.raw(20 * nsh)
    maps = [r.take('<IIII')[:2] for _ in range(r.take('<I'))]
    shaders = [r.take('<QIIB') for _ in range(r.take('<I'))]
    r.raw(16 * r.take('<I'))
    n = r.take('<I'); indices = list(struct.unpack_from(f'<{n}I', b, r.o)); r.o += 4 * n
    return dict(maps=maps, shaders=shaders, indices=indices, code=r.o)

def decoded_archive(b, raws):
    """The archive with every shader replaced by its decoded bytes (raws, in entry order): the same tables, each entry's size = its raw size, the code laid out again
    (the preload entries keep their old file ranges; only the shader tools read these copies)"""
    a = archive(b); r = R(b); r.take('<I')
    for elem in (20, 20, 16): r.raw(elem * r.take('<I'))
    head, ents_at = b[:r.o + 4], r.o + 4; n = len(a['shaders']); tail_at = ents_at + 17 * n
    ents, off = bytearray(), 0
    for (_, _, raw, fr), d in zip(a['shaders'], raws):
        if len(d) != raw: raise ValueError(f'decoded shader of {len(d)} bytes, the archive says {raw}')
        ents += struct.pack('<QIIB', off, raw, raw, fr); off += raw
    return head + bytes(ents) + b[tail_at:a['code']] + b''.join(raws)

def lz4_shaders(b, a):
    """Every shader of an archive decoded as an LZ4 block (Unreal Engine 4.26 and later compress shaders with LZ4 unless the project picks another format: DRAGON QUEST VII Reimagined's
    64,949), or None when one of the compressed ones is no LZ4 block that decodes to its raw size as an LSLG record (Octopath Traveler 0's Oodle: the game's own decoder is needed)"""
    import lz4.block
    out = []
    for off, size, raw, _ in a['shaders']:
        c = b[a['code'] + off:a['code'] + off + size]
        if size == raw: out.append(c); continue
        try: d = lz4.block.decompress(c, uncompressed_size=raw)
        except Exception: return None
        if len(d) != raw or d[:4] != b'LSLG': return None
        out.append(d)
    return out

TOC_MAGIC, IO_SHADER_LIBRARY, IO_SHADER_CODE = b'-==--==--==--==-', 8, 9   # EIoChunkType in Unreal Engine 5 (TOC version 4 and later; 4.27 numbers its chunk types otherwise)

class Toc:
    """An IoStore container: the .utoc's chunk table and compression blocks, the data in the .ucas beside it (<name>_s<n>.ucas for partitions after the first). A chunk is a range of the
    container's uncompressed stream, which is cut into blocks of one size, each stored or compressed on its own (method index 0 = stored, else the TOC's method names from 1).
    Header (FIoStoreTocHeader, 144 bytes): magic, u8 version, u8, u16, u32 header size, entry count, block count, block entry size (12), method count, method name length, block size,
    directory index size, partition count, u64 container ID, encryption key GUID (16), u8 flags (1 compressed, 2 encrypted, 4 signed, 8 indexed), u8, u16, u32 perfect hash seed count,
    u64 partition size, u32 count of chunks without a perfect hash, then reserved words. After it: chunk IDs (12 bytes: u64 hash, u16 index, u8, u8 type), offsets and lengths
    (5 + 5 bytes, big-endian), the perfect hash seeds and overflow list (u32 each), the blocks (5-byte offset, 3-byte stored size, 3-byte raw size, u8 method; little-endian), the method names"""
    def __init__(self, path, key=None):
        b = open(path, 'rb').read()
        if b[:16] != TOC_MAGIC: raise ValueError(f'{path}: not an IoStore TOC')
        self.path, self.key, self.version = path, key, b[16]
        hsz, n, nblk, bsz, nmeth, mlen, self.block_size, _, nparts = struct.unpack_from('<9I', b, 20)
        if bsz != 12: raise ValueError(f'{path}: compression block entries of {bsz} bytes')
        self.encrypted = b[80] >> 1 & 1
        nseeds = struct.unpack_from('<I', b, 84)[0] if self.version >= 4 else 0
        self.part_size = struct.unpack_from('<Q', b, 88)[0] if self.version >= 3 and nparts > 1 else 1 << 64
        nover = struct.unpack_from('<I', b, 96)[0] if self.version >= 5 else 0
        if self.encrypted and not key: raise ValueError(f'{path}: the container is encrypted and no key was given')
        o = hsz; self.ids = [b[o + 12 * i:o + 12 * i + 12] for i in range(n)]; o += 12 * n
        self.ranges = [(int.from_bytes(b[o + 10 * i:o + 10 * i + 5], 'big'), int.from_bytes(b[o + 10 * i + 5:o + 10 * i + 10], 'big')) for i in range(n)]; o += 10 * n + 4 * nseeds + 4 * nover
        self.blocks = []
        for i in range(nblk):
            e = b[o + 12 * i:o + 12 * i + 12]
            self.blocks.append((int.from_bytes(e[:5], 'little'), int.from_bytes(e[5:8], 'little'), int.from_bytes(e[8:11], 'little'), e[11]))
        o += 12 * nblk
        self.methods = [b[o + mlen * i:o + mlen * (i + 1)].rstrip(b'\0').decode('latin1') for i in range(nmeth)]
        self.index = {c: i for i, c in enumerate(self.ids)}; self.files = {}
    def of_type(self, t):
        """Indices of the chunks of one EIoChunkType (Unreal Engine 5 numbering: TOC version 4 and later)"""
        return [i for i, c in enumerate(self.ids) if c[11] == t] if self.version >= 4 else []
    def ucas(self, part):
        if part not in self.files: self.files[part] = open(self.path[:-5] + ('.ucas' if not part else f'_s{part}.ucas'), 'rb')
        return self.files[part]
    def read(self, i, decode=None):
        """Chunk i's bytes; Oodle blocks need decode(block bytes, raw length) → bytes (the game's own decoder, OodleHost)"""
        off, ln = self.ranges[i]; first = off // self.block_size; out = []
        for k in range(first, (off + ln - 1) // self.block_size + 1 if ln else first):
            at, size, raw, m = self.blocks[k]; f = self.ucas(at // self.part_size); f.seek(at % self.part_size)
            d = f.read((size + 15) & ~15 if self.encrypted else size)
            if self.encrypted: d = aes_decrypt(self.key, d)[:size]
            meth = self.methods[m - 1] if m else ''
            if not meth: out.append(d[:raw])
            elif meth == 'Oodle':
                if not decode: raise ValueError(f'{self.path}: chunk {i} is Oodle-compressed and no decoder was given')
                out.append(decode(d, raw))
            elif meth == 'Zlib': import zlib; out.append(zlib.decompress(d))
            elif meth == 'LZ4': import lz4.block; out.append(lz4.block.decompress(d, uncompressed_size=raw))
            else: raise ValueError(f'{self.path}: compression method {meth} is not read')
        s = off - first * self.block_size
        return b''.join(out)[s:s + ln]

def io_library_name(toc, i, names):
    """A shader library chunk's archive name: Unreal makes its chunk ID from CityHash64 of "<library>-<format>" lowercased, in UTF-16 (FINAL FANTASY RESONANCE: global-sf_glsl_switch-sp_glsl_switch
    → be76feab0415c156, the hash's bytes in memory order), names = the candidate "ShaderArchive-<library>-<format>" names (the RomFS manifests list them); a chunk none matches is named by its ID"""
    h = toc.ids[i][:8]
    for n in names:
        if city64(n[len('ShaderArchive-'):].lower().encode('utf-16-le')).to_bytes(8, 'little') == h: return n
    return f'ShaderArchive-IoStore-{h.hex()}'

def io_archive(toc, i, decode):
    """An IoStore shader library (Unreal Engine 5: FIoStoreShaderCodeArchive) as a version 2 shader code archive with every shader decoded, the form the shader tools read.
    The library chunk: u32 version (1), shader map hashes (20 bytes each), shader hashes (20 each), the shader groups' chunk IDs (12 each), shader map entries {u32 first index, u32 shader count},
    shader entries (u64: frequency in bits 0-3, group in 4-33, offset in the group's decoded bytes from bit 34), group entries {u32 first index, u32 shader count, u32 raw size, u32 stored size},
    shader indices (u32): each a u32 count and its elements. Each group is one ShaderCode chunk holding its shaders end to end, Oodle-compressed as a whole when its stored size is below its raw
    size (FINAL FANTASY RESONANCE: 5,919 groups of 74,244 shaders); a shader runs to the next shader's offset in its group, or to the group's end"""
    r = R(toc.read(i, decode))
    if r.take('<I') != 1: raise ValueError(f'{toc.path}: shader library chunk {i} is not version 1')
    maph = r.raw(20 * r.take('<I')); nsh = r.take('<I'); shh = r.raw(20 * nsh)
    gids = [r.raw(12) for _ in range(r.take('<I'))]
    maps = [r.take('<II') for _ in range(r.take('<I'))]
    n = r.take('<I'); ents = struct.unpack_from(f'<{n}Q', r.b, r.o); r.o += 8 * n
    groups = [r.take('<IIII') for _ in range(r.take('<I'))]
    k = r.take('<I'); idx = struct.unpack_from(f'<{k}I', r.b, r.o); r.o += 4 * k
    if r.o != len(r.b) or n != nsh or len(gids) != len(groups): raise ValueError(f'{toc.path}: shader library chunk {i} does not parse')
    code = [None] * n
    for g, (gid, (first, cnt, raw, stored)) in enumerate(zip(gids, groups)):
        if gid not in toc.index: raise ValueError(f'{toc.path}: shader group {g} has no chunk')
        d = toc.read(toc.index[gid], decode)
        if len(d) != stored: raise ValueError(f'{toc.path}: shader group {g} is {len(d)} bytes, its entry says {stored}')
        if stored < raw: d = decode(d, raw)
        mine = sorted(((ents[s] >> 34, s) for s in idx[first:first + cnt]))
        for (at, s), (nxt, _) in zip(mine, mine[1:] + [(raw, None)]):
            if (ents[s] >> 4) & 0x3FFFFFFF != g: raise ValueError(f'{toc.path}: shader {s} is listed in group {g} but names another')
            code[s] = d[at:nxt]
    if any(c is None for c in code): raise ValueError(f'{toc.path}: {sum(c is None for c in code)} shaders in no group')
    out, off = bytearray(struct.pack('<II', ARCHIVE_VERSION, len(maph) // 20) + maph + struct.pack('<I', n) + shh + struct.pack('<I', len(maps))), 0
    for a, c in maps: out += struct.pack('<IIII', a, c, 0, 0)
    out += struct.pack('<I', n)
    for e, c in zip(ents, code): out += struct.pack('<QIIB', off, len(c), len(c), e & 0xF); off += len(c)
    out += struct.pack('<I', 0) + struct.pack(f'<I{len(idx)}I', len(idx), *idx)
    return bytes(out) + b''.join(code)

def io_shader_tocs(romfs):
    """The IoStore containers under the RomFS that hold Unreal Engine 5 shader libraries"""
    out = []
    for dp, _, fs in os.walk(romfs):
        for f in fs:
            if not f.endswith('.utoc'): continue
            try:
                if Toc(os.path.join(dp, f), b'\0' * 32).of_type(IO_SHADER_LIBRARY): out.append(os.path.join(dp, f))
            except (OSError, ValueError, struct.error): pass
    return sorted(out)

def archive_names(romfs):
    """The shader code archive names ("ShaderArchive-<library>-<format>") the RomFS's manifests list (Unreal's Manifest_UFSFiles_<platform>.txt)"""
    import re
    names = set()
    for f in os.listdir(romfs):
        if f.startswith('Manifest_') and f.endswith('.txt'):
            names |= set(re.findall(r'(ShaderArchive-[\w-]+?)\.ushaderbytecode', open(os.path.join(romfs, f), encoding='utf-8', errors='replace').read()))
    return sorted(names)

def paks(romfs):
    """Every pak under the RomFS"""
    return sorted(os.path.join(dp, f) for dp, _, fs in os.walk(romfs) for f in fs if f.endswith('.pak'))

def inline_shaders(path, key=None):
    """Whether a pak keeps its shaders inline in its cooked packages rather than in shader code archives: a legacy pak (version 4, DRAGON QUEST XI S; version 8) whose index names no
    .ushaderbytecode, and a version 11 pak whose directory index names cooked packages (.uexp) and no .ushaderbytecode (OCTOPATH TRAVELER II: bShareMaterialShaderCode off). FINAL FANTASY
    RESONANCE's pak holds configs only (its shaders are in its IoStore container): it does not count. An encrypted index is read with key (main's, Keys); without one a version 11 pak counts as
    one with archives (Octopath Traveler 0), a legacy one as inline (DRAGON QUEST XI S). None: the pak names no file"""
    with open(path, 'rb') as f:
        enc, ioff, isz, _, ver = footer(f)
        if enc and not key: return ver in LEGACY
        def at(off, n):   # the index and the full directory index are encrypted alike (Pak.read_at)
            f.seek(off); b = f.read((n + 15) & ~15 if enc else n)
            return aes_decrypt(key, b)[:n] if enc else b
        idx = at(ioff, isz)
        if ver in LEGACY: return b'.ushaderbytecode\0' not in idx
        r = R(idx); r.fstr(); count, _ = r.take('<iQ')
        if not count: return None
        if r.take('<i'): r.take('<QQ'); r.raw(20)
        if not r.take('<i'): return False
        doff, dsz = r.take('<QQ'); d = at(doff, dsz)
    return b'.ushaderbytecode\0' not in d and b'.uexp\0' in d

def unreal_paks(romfs, inline=None, mains=()):
    """The paks under the RomFS that Unreal wrote (its magic in the footer; inline None = any, True = those whose shaders are inline in the cooked packages, False = those with shader code
    archives, inline_shaders; a pak that names no file is neither): decode_ue_shaders (the NSP script) and ue_decode (nxn_pack.py) decode the shader code archives; shader_split.py reads the
    inline ones file by file (ue_legacy_jobs). mains: the ExeFS mains whose key opens an encrypted index (Keys); a pak no key opens is read as inline_shaders reads one without a key"""
    out, keys = [], Keys(mains)
    for p in paks(romfs):
        try: k = keys(p) if mains else None
        except (OSError, ValueError, struct.error): k = None
        try: inl = inline_shaders(p, k)
        except (OSError, ValueError, struct.error): continue   # shorter than a footer, or no Unreal pak
        if inline is None or inl == inline: out.append(p)
    return out

def job(romfs, main_nso, work, decode=None):
    """The shader code archives of every pak under the RomFS into <work>/archives, and one Oodle job (<work>/oodle.job) of every compressed shader in them; <work>/job.json lists them.
    The shader libraries of IoStore containers (Unreal Engine 5.6, FINAL FANTASY RESONANCE: no archive in the pak) go there already decoded: their container blocks and shader groups are
    Oodle-compressed, two layers, so they need decode (OodleHost: the game's decoder over a pipe) rather than the job"""
    os.makedirs(os.path.join(work, 'archives'), exist_ok=True)
    keys = Keys([main_nso]); listing, recs = [], []
    tocs = io_shader_tocs(romfs)
    if tocs and not decode: raise ValueError(f'{tocs[0]}: IoStore shader libraries need the game\'s decoder (decode)')
    names = archive_names(romfs)
    for tp in tocs:
        t = Toc(tp)
        for i in t.of_type(IO_SHADER_LIBRARY):
            name = io_library_name(t, i, names) + '.ushaderbytecode'; b = io_archive(t, i, decode)
            open(os.path.join(work, 'archives', name), 'wb').write(b)
            listing.append(dict(name=name, pak=os.path.relpath(tp, romfs), path=f'chunk {t.ids[i].hex()}', shaders=len(archive(b)['shaders']), compressed=0, compression='IoStore, decoded'))
    for pak in unreal_paks(romfs, inline=False, mains=[main_nso]):
        p = Pak(pak, keys(pak))
        for path in sorted(x for x in p.files if x.endswith('.ushaderbytecode')):
            b = p.read(path, decode); a = archive(b); name = os.path.basename(path)
            comp = [i for i, (_, size, raw, _) in enumerate(a['shaders']) if size != raw]
            raws = lz4_shaders(b, a)
            if comp and raws: b = decoded_archive(b, raws); comp, how = [], 'LZ4'   # decoded here: the Oodle job gets none of them
            else: how = 'Oodle' if comp else ''
            open(os.path.join(work, 'archives', name), 'wb').write(b)
            for i in comp:
                off, size, raw, _ = a['shaders'][i]; recs.append((name, i, b[a['code'] + off:a['code'] + off + size], raw))
            listing.append(dict(name=name, pak=os.path.relpath(pak, romfs), path=path, shaders=len(a['shaders']), compressed=len(comp), compression=how))
    with open(os.path.join(work, 'oodle.job'), 'wb') as f:
        f.write(struct.pack('<II', JOB_MAGIC, len(recs)))
        for _, _, c, raw in recs: f.write(struct.pack('<II', len(c), raw)); f.write(c)
    json.dump(dict(archives=listing, records=[(n, i) for n, i, _, _ in recs]), open(os.path.join(work, 'job.json'), 'w'), indent=1)
    return listing, len(recs)

def finish(work, out):
    """The decoded archives into out, from <work>/oodle.job.out (the host's results, in job order)"""
    meta = json.load(open(os.path.join(work, 'job.json')))
    b = open(os.path.join(work, 'oodle.job.out'), 'rb').read() if meta['records'] else struct.pack('<II', OUT_MAGIC, 0)   # no Oodle shader: no host run
    magic, n = struct.unpack_from('<II', b)
    if magic != OUT_MAGIC or n != len(meta['records']): raise ValueError('the job output does not match the job')
    o, dec = 8, {}
    for name, i in meta['records']:
        l = struct.unpack_from('<I', b, o)[0]; o += 4
        if not l: raise ValueError(f'{name}: shader {i} was not decoded')
        dec[(name, i)] = b[o:o + l]; o += l
    os.makedirs(out, exist_ok=True)
    for x in meta['archives']:
        src = open(os.path.join(work, 'archives', x['name']), 'rb').read(); a = archive(src)
        raws = [dec.get((x['name'], i)) or src[a['code'] + off:a['code'] + off + size] for i, (off, size, _, _) in enumerate(a['shaders'])]
        tmp = os.path.join(out, x['name'] + '.partial'); open(tmp, 'wb').write(decoded_archive(src, raws)); os.replace(tmp, os.path.join(out, x['name']))
    return [x['name'] for x in meta['archives']]

def lslg(s):
    """A decoded Switch shader (LSLG): 'LSLG', a stage tag (SV vertex, SP pixel, SC compute, ...), a header with the shader's source name, then u32 code length, the code area,
    u32 control length and the control section (0x880 bytes), and a short tail (24 or 29 bytes). → (tag, control section, code area), or None if the layout differs"""
    if s[:4] != b'LSLG': return None
    k = s.find(b'\x34\x12\x76\x98')
    if k < 8: return None
    nctl, ncode = struct.unpack_from('<I', s, k - 4)[0], struct.unpack_from('<I', s, k + 0x704)[0]
    c = k - 4 - ncode
    if c < 4 or struct.unpack_from('<I', s, c - 4)[0] != ncode or k + nctl > len(s): return None
    return s[4:6].decode('latin1'), s[k:k + nctl], s[c:c + ncode]

if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'probe':   # uepak.py probe <RomFS> <main NSO> [<oodle_serve>]: what probe() sees, for a game the tools do not read yet
        if len(sys.argv) > 4: probe.decode = Ooz(sys.argv[4])
        print('\n'.join(probe(sys.argv[2], sys.argv[3:4])))
    elif cmd == 'list':
        p = Pak(sys.argv[2], Keys([sys.argv[3]])(sys.argv[2]))
        with open(sys.argv[4], 'w') as f:
            f.write('path\traw\tstored\tmethod\tencrypted\tblocks\n')
            for path in sorted(p.files):
                e = p.entry(path); f.write(f"{path}\t{e['raw']}\t{e['size']}\t{e['method'] or 'none'}\t{e['encrypted']}\t{len(e['blocks'])}\n")
        used = sorted({p.entry(x)['method'] for x in p.files} - {''})
        print(f'pak version {p.version}, mount {p.mount}, {len(p.files)} files, compression {used}')
    elif cmd == 'job':
        dec = OodleHost(*sys.argv[5:7]) if len(sys.argv) > 6 else Ooz(sys.argv[5]) if len(sys.argv) > 5 else None   # the Mac host and its modules, or oodle_serve
        try: listing, n = job(*sys.argv[2:5], decode=dec)
        finally:
            if dec: dec.close()
        for x in listing: print(f"{x['name']}: {x['shaders']} shaders, {x['compressed']} compressed")
        print(f'{n} records in {os.path.join(sys.argv[4], "oodle.job")}')
    elif cmd == 'finish':
        print('decoded:', ', '.join(finish(*sys.argv[2:4])))
    else: sys.exit(__doc__ or 'usage: uepak.py list | job | finish (see the header)')
