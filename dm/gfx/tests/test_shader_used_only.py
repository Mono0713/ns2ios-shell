"""Used-only packing of Unity games with too many keyword variants (shader_split.select_used / unity_blob_info / recorded_keys)."""
from pathlib import Path
import os
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
os.environ.setdefault('DM_GAME', '0100000000010000')
import shader_split


def variants(shader, stage, sets, start):
    """{key: [(group, stage, tier, keywords)]} for one pass of one shader; keys numbered from start"""
    g = (f'/data#{shader}', 'p', (0, 0, 'progVertex' if stage == 'vs' else 'progFragment'))
    return {f'{start + i:016x}': [(g, stage, 0, frozenset(kw))] for i, kw in enumerate(sets)}


LIT = [(), ('DIRECTIONAL',), ('DIRECTIONAL', 'SHADOWS_SCREEN'), ('DIRECTIONAL', 'SHADOWS_SCREEN', 'FOG_LINEAR'),
       ('POINT',), ('POINT', 'FOG_LINEAR'), ('DIRECTIONAL', 'LIGHTMAP_ON'), ('DIRECTIONAL', 'FOG_LINEAR')]


class SelectUsedTests(unittest.TestCase):
    def setUp(self):
        self.metas = {}
        self.metas.update(variants('Lit', 'vs', LIT, 0x100))
        self.metas.update(variants('Lit', 'ps', LIT, 0x200))
        self.metas.update(variants('Toon', 'vs', LIT[:4] + [('DIRECTIONAL', 'SHADOWS_SCREEN', '_RIM')], 0x300))
        self.metas.update(variants('UI', 'vs', [('UNITY_UI_CLIP_RECT',), ('UNITY_UI_ALPHACLIP',), ('UNITY_UI_CLIP_RECT', 'UNITY_UI_ALPHACLIP')], 0x400))

    def test_nothing_recorded_keeps_the_fewest_keywords_of_each_group(self):
        keep, why = shader_split.select_used(self.metas, set())
        self.assertEqual(keep, {f'{0x100:016x}', f'{0x200:016x}', f'{0x300:016x}', f'{0x400:016x}', f'{0x401:016x}'})
        self.assertEqual((why['recorded'], why['predicted']), (0, 0))

    def test_recorded_keywords_predict_the_same_variant_of_other_shaders(self):
        rec = {f'{0x103:016x}'}   # Lit vs with DIRECTIONAL SHADOWS_SCREEN FOG_LINEAR
        keep, why = shader_split.select_used(self.metas, rec | {'ffffffffffffffff'})   # a key the game files lack is not packed
        self.assertIn(f'{0x103:016x}', keep)
        self.assertIn(f'{0x203:016x}', keep)   # Lit ps, same keywords
        self.assertIn(f'{0x303:016x}', keep)   # Toon vs, same keywords
        self.assertNotIn(f'{0x304:016x}', keep)   # Toon's _RIM variant was never seen
        self.assertNotIn(f'{0x106:016x}', keep)   # LIGHTMAP_ON never seen
        self.assertNotIn('ffffffffffffffff', keep)
        self.assertEqual(why['recorded'], 1)

    def test_recorded_keywords_are_cut_to_a_group_s_own_keywords(self):
        # a UI shader drawn with the lit keywords enabled globally: the UI groups know none of them, so the variant without them is what they predict (already the seed)
        rec = {f'{0x103:016x}', f'{0x402:016x}'}
        keep, _ = shader_split.select_used(self.metas, rec)
        self.assertIn(f'{0x402:016x}', keep)
        # Lit's space has no UNITY_UI_*, so the UI keywords predict Lit's no-keyword variant (also the seed), nothing more
        self.assertNotIn(f'{0x104:016x}', keep)

    def test_shared_key_counts_in_every_group(self):
        m = dict(self.metas)
        m[f'{0x300:016x}'] = m[f'{0x300:016x}'] + [((f'/data#Other', 'p', (0, 0, 'progVertex')), 'vs', 0, frozenset(('X',)))]
        keep, _ = shader_split.select_used(m, set())
        self.assertIn(f'{0x300:016x}', keep)


class BlobInfoTests(unittest.TestCase):
    def test_keyword_names_from_name_indices(self):
        o = {'m_ParsedForm': {'m_SubShaders': [{'m_Passes': [{
            'm_NameIndices': [{'first': 'DIRECTIONAL', 'second': 3}, {'first': 'FOG_LINEAR', 'second': 7}],
            'progVertex': {'m_SubPrograms': [{'m_BlobIndex': 0, 'm_KeywordIndices': [3, 7], 'm_ShaderHardwareTier': 1},
                                             {'m_BlobIndex': 1, 'm_GlobalKeywordIndices': [3], 'm_LocalKeywordIndices': [9]}]},
            'progFragment': {'m_SubPrograms': [{'m_BlobIndex': 2, 'm_KeywordIndices': []}]}}]}]}}
        info = shader_split.unity_blob_info(o)
        self.assertEqual(info[0], ((0, 0, 'progVertex'), 1, frozenset({'DIRECTIONAL', 'FOG_LINEAR'})))
        self.assertEqual(info[1][2], frozenset({'DIRECTIONAL', '#9'}))
        self.assertEqual(info[2], ((0, 0, 'progFragment'), -1, frozenset()))

    def test_keyword_names_of_2022_and_player_subprograms(self):
        o = {'m_ParsedForm': {'m_KeywordNames': ['A', 'B', 'C'], 'm_SubShaders': [{'m_Passes': [{
            'progVertex': {'m_SubPrograms': [], 'm_PlayerSubPrograms': [[{'m_BlobIndex': 4, 'm_KeywordIndices': [0, 2]}]]}}]}]}}
        self.assertEqual(shader_split.unity_blob_info(o)[4][2], frozenset({'A', 'C'}))


class UnityShadersMetaTests(unittest.TestCase):
    def test_programs_carry_their_group_and_keywords_to_the_keys(self):
        import unityfs
        obj = {'m_ParsedForm': {'m_Name': 'Lit', 'm_SubShaders': [{'m_Passes': [{
            'm_NameIndices': [{'first': 'POINT', 'second': 5}],
            'progVertex': {'m_SubPrograms': [{'m_BlobIndex': 0, 'm_KeywordIndices': []}, {'m_BlobIndex': 1, 'm_KeywordIndices': [5]}]}}]}]}}
        saved = (unityfs.is_serialized, unityfs.serialized_objects, unityfs.shader_programs, unityfs.subprogram, shader_split.unity_program,
                 shader_split.unity_compute, shader_split.unity_text_glslc, shader_split.COMMON)
        try:
            unityfs.is_serialized = lambda x: True
            unityfs.serialized_objects = lambda *a: iter([(48, 1, obj)])
            unityfs.shader_programs = lambda o, only: iter([(20, 0, b'a'), (20, 1, b'b'), (20, 2, b'c')])
            # blob 0 names no keyword in its header (2021.2 on): the parsed form's indices count; blob 1 names its own; blob 2 is in no pass
            unityfs.subprogram = lambda sp: (1, 0, ['DIRECTIONAL'] if sp == b'b' else [], [], sp, 0)
            shader_split.unity_program = lambda code, where, stage=None: [('vs', code * 0x30, b'code' + code)]
            shader_split.unity_compute = lambda *a: []
            shader_split.unity_text_glslc = lambda *a: []
            shader_split.COMMON = {}
            found, meta = [], {}
            shader_split.unity_shaders(b'x' * 16, '/data', found, {}, meta)
        finally:
            (unityfs.is_serialized, unityfs.serialized_objects, unityfs.shader_programs, unityfs.subprogram, shader_split.unity_program,
             shader_split.unity_compute, shader_split.unity_text_glslc, shader_split.COMMON) = saved
        g = ('/data#Lit', 20, (0, 0, 'progVertex'))
        self.assertEqual(meta['/data#Lit#var20.0'], (g, -1, frozenset()))
        self.assertEqual(meta['/data#Lit#var20.1'], (g, -1, frozenset({'DIRECTIONAL'})))
        self.assertEqual(meta['/data#Lit#var20.2'], (('/data#Lit', 20, None), -1, frozenset()))
        uniq = {shader_split.skey(c, k): (w, st, c, k) for w, st, c, k in found}
        keyed = shader_split.with_meta(uniq, found, meta)
        k1 = shader_split.skey(b'b' * 0x30, b'codeb')
        self.assertEqual(keyed[k1][4], [(g, 'vs', -1, frozenset({'DIRECTIONAL'}))])


class RecordedKeysTests(unittest.TestCase):
    def test_reads_every_keys_file(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, '0000000100000002.keys').write_text('00000000000000AA\n0000000000000bb\nnot a key\n')
            Path(d, '0000000300000004.keys').write_text('00000000000000cc\n00000000000000aa\n')
            Path(d, 'x.txt').write_text('00000000000000dd\n')
            self.assertEqual(shader_split.recorded_keys(d), {'00000000000000aa', '00000000000000cc'})
            self.assertEqual(shader_split.recorded_keys(os.path.join(d, 'missing')), set())
            self.assertEqual(shader_split.recorded_keys(''), set())


if __name__ == '__main__':
    unittest.main()
