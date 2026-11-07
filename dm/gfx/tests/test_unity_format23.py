"""Serialized format 23 (Unity 6000.5, Super Bunny Man): format 22's header and object table. Files without type trees read as before; in bundles each type's tree is a
second 16-byte hash and a size-prefixed "mhtt" block that unityfs.py steps over, taking the Shader layout of unity_layouts.txt by version instead.
A newer format is reported (newer_format) instead of being skipped without a word."""
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import unityfs
from test_unity_layouts import write, UNKNOWN_HASH, generated


def fmt23(unity, root, mhtt=None, ver=23, deps=None):
    """one Shader object; mhtt = the tree block's bytes after "mhtt" (None: a file without type trees); deps = type dependencies after the block"""
    payload = bytearray(); write(root, payload); payload = bytes(payload)
    types = struct.pack('<iBh', unityfs.CLASS_SHADER, 0, -1) + UNKNOWN_HASH
    if mhtt is not None:
        block = b'mhtt' + mhtt
        types += bytes(range(16)) + struct.pack('<I', len(block)) + block
        if deps is not None: types += struct.pack('<i', len(deps)) + b''.join(struct.pack('<i', x) for x in deps)
    meta = unity.encode() + b'\0' + struct.pack('<i?i', 38, mhtt is not None, 1) + types + struct.pack('<i', 1)
    head = 48
    meta += bytes(-(head + len(meta)) % 4)
    meta += struct.pack('<qqIi', 1, 0, len(payload), 0)
    doff = (head + len(meta) + 15) & ~15
    total = doff + len(payload)
    hdr = struct.pack('>IIII', 0, 0, ver, 0) + bytes(4) + struct.pack('>Iqqq', len(meta), total, doff, 0)
    return (hdr + meta).ljust(doff, b'\0') + payload


class Format23Tests(unittest.TestCase):
    def setUp(self):
        self.root = unityfs.layout_candidates(unityfs.CLASS_SHADER, '6000.5.5f1')[0]

    def read(self, data):
        self.assertTrue(unityfs.is_serialized(data))
        return list(unityfs.serialized_objects(data, {}, {unityfs.CLASS_SHADER}, generated()))

    def test_without_type_trees(self):
        objs = self.read(fmt23('6000.5.7f1', self.root))
        self.assertEqual(len(objs), 1); self.assertEqual(objs[0][2]['m_Name'], 'x')

    def test_mhtt_block_is_stepped_over(self):
        objs = self.read(fmt23('6000.5.7f1', self.root, mhtt=struct.pack('<II', 0x17, 0x6b) + bytes(37)))
        self.assertEqual(len(objs), 1); self.assertEqual(objs[0][2]['m_Name'], 'x')

    def test_mhtt_block_then_type_dependencies(self):
        objs = self.read(fmt23('6000.5.7f1', self.root, mhtt=bytes(40), deps=[3, 4]))
        self.assertEqual(len(objs), 1)

    def test_newer_format_is_reported(self):
        data = fmt23('6000.9.1f1', self.root, ver=24)
        self.assertFalse(unityfs.is_serialized(data))
        self.assertEqual(unityfs.newer_format(data), 24)
        self.assertEqual(unityfs.newer_format(fmt23('6000.5.7f1', self.root)), 0)


if __name__ == '__main__':
    unittest.main()
