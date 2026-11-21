"""dmsh_build.py spv_single_lane on vertex shaders that use subgroup operations (data/subgroup_*_vs.vert, compiled with glslang -V --target-env vulkan1.1):
SPIRV-Cross refuses any subgroup builtin in a Metal vertex function ("Subgroup builtins are not available in this type of function"), which stopped two of Super Mario Party
Jamboree's vertex shaders. Every subgroup builtin, its decoration and every subgroup operation must be gone after the one-lane rewrite, and SPIRV-Cross (when on PATH) must accept it."""
import ast
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[2] / 'gfx/tools'
DATA = Path(__file__).resolve().parent / 'data'
FUNCS = {'spv_single_lane', '_ep_drop'}
NAMES = {'SG_OPS', 'SG_BUILTINS'}


def load():
    tree = ast.parse((TOOLS / 'dmsh_build.py').read_text(encoding='utf-8'))
    nodes = [n for n in tree.body if (isinstance(n, ast.FunctionDef) and n.name in FUNCS)
             or (isinstance(n, ast.Assign) and any(getattr(t, 'id', None) in NAMES for t in n.targets))]
    ns = {'struct': struct}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(TOOLS / 'dmsh_build.py'), 'exec'), ns)
    assert FUNCS <= set(ns), FUNCS - set(ns)
    return ns


NS = load()


def instructions(path):
    d = path.read_bytes(); w = struct.unpack('<%dI' % (len(d) // 4), d); i, out = 5, []
    while i < len(w): n = w[i] >> 16; out.append(w[i:i + n]); i += n
    return out


class SingleLane(unittest.TestCase):
    def check(self, name):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / name
            shutil.copyfile(DATA / name, p)
            before = instructions(p)
            self.assertTrue(any(x[0] & 0xffff == 71 and len(x) > 3 and x[2] == 11 and x[3] in NS['SG_BUILTINS'] for x in before))
            self.assertTrue(NS['spv_single_lane'](str(p)))
            after = instructions(p)
            self.assertFalse([x for x in after if x[0] & 0xffff == 71 and len(x) > 3 and x[2] == 11 and x[3] in NS['SG_BUILTINS']], 'a subgroup builtin is left')
            self.assertFalse([x for x in after if x[0] & 0xffff in NS['SG_OPS']], 'a subgroup operation is left')
            sc = shutil.which('spirv-cross')
            if sc:
                r = subprocess.run([sc, '--msl', '--msl-version', '20300', '--msl-argument-buffers', str(p)], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertNotIn('simd_', r.stdout)

    def test_khr_masks_by_component_and_arithmetic(self): self.check('subgroup_khr_vs.spv')   # gl_SubgroupEqMask[0], ballot bit count / extract / inverse / LSB, add, inclusive max, shuffle

    def test_arb_ballot(self): self.check('subgroup_arb_vs.spv')   # SPV_KHR_shader_ballot: ballotARB, readFirstInvocationARB, readInvocationARB, gl_SubGroupEqMaskARB

    def test_nothing_to_do(self):
        with tempfile.TemporaryDirectory() as t:
            p = Path(t) / 'x.spv'
            p.write_bytes(struct.pack('<5I', 0x07230203, 0x10300, 0, 10, 0))
            self.assertFalse(NS['spv_single_lane'](str(p)))


if __name__ == '__main__':
    unittest.main()
