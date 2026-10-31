"""unity_layouts.txt: the Shader and ComputeShader trees of every Unity release from 5.5 (AssetRipper's TypeTreeDumps), tried in turn for a stripped file whose hash no bundle and
no hand-written layout has, each kept only if it reads every object to its end."""
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import unityfs

UNKNOWN_HASH = bytes.fromhex('00112233445566778899aabbccddeeff')


def write(node, out):
    """every vector and map with one element, every string 'x', every number 1"""
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


def serialized(unity, root, cid, count=1, extra=b''):
    payload = bytearray(); write(root, payload); one = bytes(payload) + extra; payload = one * count
    metadata = (unity.encode() + b'\0' + struct.pack('<i?iiBh', 38, False, 1, cid, 0, -1) + UNKNOWN_HASH + struct.pack('<i', count))
    metadata += bytes(-(20 + len(metadata)) % 4)
    for i in range(count):
        metadata += struct.pack('<qIII', i + 1, i * len(one), len(one), 0)
    return (struct.pack('>IIII', len(metadata), 0x100 + len(payload), 21, 0x100) + bytes(4) + metadata).ljust(0x100, b'\0') + payload


def sig(n):
    return ('vector' if n.type == 'staticvector' else n.type, n.name, bool(n.flags & 0x4000), tuple(sig(k) for k in n.kids))


def generated():
    return {unityfs.GENERATED: True}


class UnityLayoutTests(unittest.TestCase):
    def test_every_release_line_from_5_5_is_covered(self):
        have = {(cid, '.'.join(v.split('.')[:2])) for cid, vs, _ in unityfs._layouts() for v in vs}
        lines = ['5.5', '5.6'] + ['2017.%d' % i for i in range(1, 5)] + ['2018.%d' % i for i in range(1, 5)] + ['2019.%d' % i for i in range(1, 5)] + \
                ['2020.%d' % i for i in range(1, 4)] + ['2021.%d' % i for i in range(1, 4)] + ['2022.%d' % i for i in range(1, 4)] + ['2023.1', '2023.2', '6000.0']
        for cid in (unityfs.CLASS_SHADER, unityfs.CLASS_COMPUTE_SHADER):
            for line in lines: self.assertIn((cid, line), have)

    def test_the_hand_written_layouts_are_the_dumped_ones(self):
        # each layout written by hand for a game, and checked on that game, is one of the generated trees node for node
        gen = {(cid, sig(n)) for cid, _, n in unityfs._layouts()}
        for cid, h in unityfs.KNOWN_TREES: self.assertIn((cid, sig(unityfs.known_tree(cid, h))), gen, (cid, h.hex()))
        for cid, line in unityfs.KNOWN_BY_VERSION: self.assertIn((cid, sig(unityfs.known_version_tree(cid, line))), gen, (cid, line))

    def test_each_layout_reads_under_its_own_version(self):
        for cid, vs, root in unityfs._layouts():
            for v in (vs[0], vs[-1]):
                data = serialized(v, root, cid, 2)
                objs = list(unityfs.serialized_objects(data, {}, {cid}, generated()))
                self.assertEqual(len(objs), 2, v)
                self.assertEqual(objs[0][2]['m_Name'], 'x')

    def test_the_exact_version_is_tried_first(self):
        for cid, vs, root in unityfs._layouts():
            self.assertIs(unityfs.layout_candidates(cid, vs[0])[0], root)

    def test_a_version_the_dumps_lack_takes_the_nearest_that_reads(self):
        # 2021.3.45f1's tree in a file whose header says 2021.3.5f1 (whose own tree is 2021.2's): the first candidate does not read to the end, the next that does is kept
        root = unityfs.layout_candidates(unityfs.CLASS_SHADER, '2021.3.45f1')[0]
        self.assertIsNot(unityfs.layout_candidates(unityfs.CLASS_SHADER, '2021.3.5f1')[0], root)
        objs = list(unityfs.serialized_objects(serialized('2021.3.5f1', root, unityfs.CLASS_SHADER), {}, {unityfs.CLASS_SHADER}, generated()))
        p = objs[0][2]['m_ParsedForm']['m_SubShaders'][0]['m_Passes'][0]
        self.assertIn('m_SerializedKeywordStateMask', p)
        # and a version newer than every dump still finds its tree
        objs = list(unityfs.serialized_objects(serialized('6000.9.1f1', root, unityfs.CLASS_SHADER), {}, {unityfs.CLASS_SHADER}, generated()))
        self.assertEqual(len(objs), 1)

    def test_without_the_generated_key_nothing_is_guessed(self):
        root = unityfs.layout_candidates(unityfs.CLASS_SHADER, '2023.2.20f1')[0]
        with self.assertRaises(unityfs.NoTree):
            list(unityfs.serialized_objects(serialized('2023.2.20f1', root, unityfs.CLASS_SHADER), {}, {unityfs.CLASS_SHADER}, {}))

    def test_data_no_layout_reads_stops(self):
        root = unityfs.layout_candidates(unityfs.CLASS_SHADER, '2019.4.22f1')[0]
        # 4 bytes more than any tree reads: the object's size in the table covers them, so no tree reads it to its end
        data = serialized('2019.4.22f1', root, unityfs.CLASS_SHADER, extra=b'\1\0\0\0')
        with self.assertRaises(unityfs.NoTree):
            list(unityfs.serialized_objects(data, {}, {unityfs.CLASS_SHADER}, generated()))


if __name__ == '__main__':
    unittest.main()
