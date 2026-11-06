"""dm/tools/sdk_auto_cuts.py: on synthetic text it finds the node-area and alignment cuts exactly where the registered
builds of dm/tools/sdk_patches.py have them, refuses ambiguous text, and prepare() writes a patch file only for an
unregistered sdk build. No game files."""
import importlib.util
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1]
REPO = TOOLS.parents[1]
sys.path.insert(0, str(TOOLS))
import sdk_auto_cuts as sac

spec = importlib.util.spec_from_file_location('sdk_patches_t', TOOLS / 'sdk_patches.py'); SP = importlib.util.module_from_spec(spec); spec.loader.exec_module(SP)
NODE_WORDS = {'08fca752', '09fca752', 'e8230b32', 'e9230b32'}


def image(entries, size=None):
    size = size or ((max(o for o, *_ in entries) + 0x1000) & ~0xfff)
    img = bytearray(size)
    for o, ob, *_ in entries: img[o:o + 4] = bytes.fromhex(ob)
    return img


def nso(path, text, bid):
    hdr = bytearray(0x100); hdr[:4] = b'NSO0'
    struct.pack_into('<III', hdr, 0x10, 0x100, 0, len(text))
    struct.pack_into('<III', hdr, 0x20, 0x100 + len(text), len(text), 0)
    struct.pack_into('<III', hdr, 0x30, 0x100 + len(text), len(text), 0)
    struct.pack_into('<III', hdr, 0x60, len(text), 0, 0)
    hdr[0x40:0x50] = bytes.fromhex(bid)
    Path(path).write_bytes(bytes(hdr) + bytes(text))


class Cuts(unittest.TestCase):
    def test_registered_node_areas(self):
        n = 0
        for bid, cs in SP.CUTS.items():
            node = [c for c in cs if c[1] in NODE_WORDS]
            if len(node) != 2: continue
            img = image(node); got = sac.cuts(img, len(img))
            self.assertEqual([(o, ob, nb) for o, ob, nb, _ in got[:2]], [(o, ob, nb) for o, ob, nb, _ in node], bid); n += 1
        self.assertGreater(n, 15)

    def test_sea_of_stars_alignment(self):
        cs = SP.CUTS['3053b22935e32ddf15ef81997603e5c2']
        img = image(cs); got = sac.cuts(img, len(img))
        self.assertEqual([(o, ob, nb) for o, ob, nb, _ in got], [(o, ob, nb) for o, ob, nb, _ in cs])

    def test_registered_orr_alignment(self):
        n = 0
        for bid, cs in SP.CUTS.items():
            if not any(c[1] == 'ea030232' for c in cs): continue
            img = image(cs); got = sac.cuts(img, len(img))
            self.assertEqual([(o, ob, nb) for o, ob, nb, _ in got], [(o, ob, nb) for o, ob, nb, _ in cs], bid); n += 1
        self.assertGreaterEqual(n, 3)

    def test_ambiguous_or_absent(self):
        self.assertEqual(sac.cuts(bytearray(0x10000), 0x10000), [])
        e = [(0x1000, '08fca752'), (0x1080, '09fca752'), (0x8000, '08fca752'), (0x8080, '09fca752')]
        self.assertEqual(sac.cuts(image(e), 0x10000), [])

    def test_prepare(self):
        with tempfile.TemporaryDirectory() as t:
            exe = Path(t) / 'ExeFS'; exe.mkdir(); dst = Path(t) / 'auto'
            text = image([(0x1000, '08fca752'), (0x109c, '09fca752')], 0x4000)
            nso(exe / 'sdk', text, 'ab' * 16)
            d, line, body = sac.prepare(str(exe), ['main', 'sdk'], str(dst), str(REPO))
            self.assertEqual(d, str(dst), line)
            spec = importlib.util.spec_from_file_location('auto_t', dst / 'sdk_auto' / 'patches.py'); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
            self.assertEqual([(o, ob, nb) for o, ob, nb, _ in m.CUTS['ab' * 16]], [(0x1000, '08fca752', '087ca052'), (0x109c, '09fca752', '097ca052')])
            reg = next(iter(SP.CUTS))
            nso(exe / 'sdk', text, reg)
            d, line, body = sac.prepare(str(exe), ['main', 'sdk'], str(dst), str(REPO))
            self.assertIsNone(d); self.assertFalse((dst / 'sdk_auto' / 'patches.py').exists(), 'a stale file stays')


if __name__ == '__main__':
    unittest.main()
