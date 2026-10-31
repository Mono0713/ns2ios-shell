"""shader_split.py's RomFS and main arguments are comma-separated lists; a game folder whose name holds a comma must stay one path (Snipperclips Plus - Cut It Out, Together)."""
from pathlib import Path
import os
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
os.environ.setdefault("DM_GAME", "0100000000010000")   # any profile with shader groups: importing shader_split reads one
import shader_split


class PathListTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def mk(self, *names):
        out = []
        for n in names:
            p = self.root / n; p.mkdir(parents=True); out.append(str(p))
        return out

    def test_a_comma_in_one_folder_name(self):
        a, = self.mk('Snipperclips Plus - Cut It Out, Together/RomFS')
        self.assertEqual(shader_split.path_list(a), [a])

    def test_two_versions_each_with_commas(self):
        a, b = self.mk('Cut It Out, Together/v0/RomFS', 'Cut It Out, Together/v65536/RomFS')
        self.assertEqual(shader_split.path_list(a + ',' + b), [a, b])

    def test_plain_lists_split_as_before(self):
        a, b = self.mk('game/v0/RomFS', 'game/v1/RomFS')
        self.assertEqual(shader_split.path_list(a + ',' + b), [a, b])
        self.assertEqual(shader_split.path_list('x,y'), ['x', 'y'])


if __name__ == '__main__':
    unittest.main()
