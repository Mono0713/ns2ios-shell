"""A Shader whose type hash no bundle and no KNOWN_TREES entry has takes its Unity release line's layout (KNOWN_BY_VERSION), only if every object reads to its end (Unspottable, Unity 2019.4.22f1)."""
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import unityfs

UNKNOWN_HASH = bytes.fromhex('00112233445566778899aabbccddeeff')


def write(node, out):
    """every vector and map with one element, every string 'x', every number 1: an object that tells layouts apart"""
    def align():
        out.extend(bytes(-len(out) % 4))
    if node.type in unityfs.PRIM and not node.kids:
        out.extend(struct.pack('<' + unityfs.PRIM[node.type], True if node.type == 'bool' else 1))
    elif node.type == 'string':
        out.extend(struct.pack('<i', 1) + b'x')
        if node.kids[0].flags & 0x4000: align()
    elif node.kids and node.kids[0].type == 'Array':
        arr = node.kids[0]
        out.extend(struct.pack('<i', 1)); write(arr.kids[1], out)
        if arr.flags & 0x4000: align()
    else:
        for k in node.kids: write(k, out)
    if node.flags & 0x4000: align()


def serialized(unity, root):
    payload = bytearray(); write(root, payload); payload = bytes(payload)
    metadata = (unity.encode() + b'\0' + struct.pack('<i?iiBh', 38, False, 1, unityfs.CLASS_SHADER, 0, -1)
                + UNKNOWN_HASH + struct.pack('<i', 1))
    metadata += bytes(-(20 + len(metadata)) % 4)
    metadata += struct.pack('<qIII', 1, 0, len(payload), 0)
    return (struct.pack('>IIII', len(metadata), 0x100 + len(payload), 21, 0x100) + bytes(4) + metadata).ljust(0x100, b'\0') + payload


def second_pass_trees():
    trees = {k: unityfs.known_tree(*k) for k in unityfs.KNOWN_TREES}
    for cid, line in unityfs.KNOWN_BY_VERSION: trees[unityfs.version_key(cid, line)] = unityfs.known_version_tree(cid, line)
    return trees


class ShaderByVersionTests(unittest.TestCase):
    def test_2019_4_shader_reads_with_the_release_line_layout(self):
        data = serialized('2019.4.22f1', unityfs.known_version_tree(unityfs.CLASS_SHADER, '2019.4'))
        objs = list(unityfs.serialized_objects(data, {}, {unityfs.CLASS_SHADER}, second_pass_trees()))
        self.assertEqual(len(objs), 1)
        sh = objs[0][2]
        self.assertEqual(sh['m_Name'], 'x')
        self.assertEqual(sh['offsets'], [[1]])
        sp = sh['m_ParsedForm']['m_SubShaders'][0]['m_Passes'][0]['progVertex']['m_SubPrograms'][0]
        self.assertEqual(sp['m_LocalKeywordIndices'], [1])
        self.assertIn('m_ConstantBuffers', sp)

    def test_without_the_fallback_the_file_has_no_tree(self):
        data = serialized('2019.4.22f1', unityfs.known_version_tree(unityfs.CLASS_SHADER, '2019.4'))
        trees = {k: unityfs.known_tree(*k) for k in unityfs.KNOWN_TREES}
        with self.assertRaises(unityfs.NoTree):
            list(unityfs.serialized_objects(data, {}, {unityfs.CLASS_SHADER}, trees))

    def test_a_layout_that_does_not_fit_is_refused(self):
        # an object of another layout (2018.3's) under a 2019.4 header: the guess must not decode it
        other = unityfs.known_tree(unityfs.CLASS_SHADER, bytes.fromhex('8db760073e1392061e4a36995f0735af'))
        data = serialized('2019.4.22f1', other)
        with self.assertRaises(unityfs.NoTree):
            list(unityfs.serialized_objects(data, {}, {unityfs.CLASS_SHADER}, second_pass_trees()))

    def test_other_release_lines_have_no_guess(self):
        data = serialized('2021.3.5f1', unityfs.known_version_tree(unityfs.CLASS_SHADER, '2019.4'))
        with self.assertRaises(unityfs.NoTree):
            list(unityfs.serialized_objects(data, {}, {unityfs.CLASS_SHADER}, second_pass_trees()))


if __name__ == '__main__':
    unittest.main()
