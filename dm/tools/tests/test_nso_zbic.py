"""nso_zbic.py: an NSO whose segments are ZBIC-compressed becomes the same module with those segments stored raw (Super Bunny Man 1.3.0's main)."""
from pathlib import Path
import hashlib
import struct
import sys
import tempfile
import types
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import nso_zbic

# a stand-in decoder: "ZBIC" + the raw bytes (the real format is zstd with other entropy tables; only the framing matters here)
sys.modules['zbic'] = types.SimpleNamespace(decompress=lambda b: b[4:])


def nso(segs, flags, zbic):
    name = b'GameAssembly\0'
    hdr = bytearray(0x100); hdr[:4] = b'NSO0'
    body = bytearray(name); pos = 0x100 + len(name); mo = 0
    csz = []
    for i, s in enumerate(segs):
        stored = (b'ZBIC' + s) if zbic[i] else s
        struct.pack_into('<III', hdr, 0x10 + i * 0x10, pos, mo, len(s))
        hdr[0xa0 + 0x20 * i:0xc0 + 0x20 * i] = hashlib.sha256(s).digest()
        body += stored; pos += len(stored); mo += (len(s) + 0xfff) & ~0xfff; csz.append(len(stored))
    struct.pack_into('<I', hdr, 0xc, flags)
    struct.pack_into('<III', hdr, 0x60, *csz)
    hdr[0x40:0x50] = bytes(range(16))
    return bytes(hdr + body)


class NsoZbicTests(unittest.TestCase):
    segs = [b'T' * 100, b'R' * 50, b'D' * 30]

    def test_zbic_segments_are_stored_raw(self):
        out = nso_zbic.decompress_nso(nso(self.segs, 0xbf, [1, 1, 1]))
        self.assertEqual(struct.unpack_from('<I', out, 0xc)[0], 0x38)   # only the hash bits are left
        self.assertEqual(out[0x40:0x50], bytes(range(16)))
        self.assertEqual(out[0x100:0x10d], b'GameAssembly\0')
        csz = struct.unpack_from('<III', out, 0x60)
        for i, s in enumerate(self.segs):
            fo, mo, sz = struct.unpack_from('<III', out, 0x10 + i * 0x10)
            self.assertEqual((sz, csz[i]), (len(s), len(s)))
            self.assertEqual(out[fo:fo + sz], s)
        self.assertFalse(nso_zbic.is_zbic(out))

    def test_an_lz4_module_is_left_alone(self):
        d = nso(self.segs, 0x38, [0, 0, 0])
        self.assertFalse(nso_zbic.is_zbic(d))
        with tempfile.TemporaryDirectory() as t:
            (Path(t) / 'sdk').write_bytes(d); (Path(t) / 'main').write_bytes(nso(self.segs, 0xbf, [1, 1, 1])); (Path(t) / 'main.npdm').write_bytes(b'META')
            self.assertEqual(nso_zbic.normalize_exefs(t), ['main'])
            self.assertEqual((Path(t) / 'sdk').read_bytes(), d)
            self.assertFalse(nso_zbic.is_zbic((Path(t) / 'main').read_bytes()))

    def test_a_wrong_hash_stops(self):
        d = bytearray(nso(self.segs, 0xbf, [1, 1, 1])); d[0xa0] ^= 1
        with self.assertRaises(SystemExit):
            nso_zbic.decompress_nso(bytes(d))


if __name__ == '__main__':
    unittest.main()
