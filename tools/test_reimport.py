"""Unit tests for the pure parts of tools/reimport.py (#377).

Run from the repo root:  python3 -m unittest tools/test_reimport.py
"""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import reimport  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]


def mts(size, names, param2=None):
    n = size[0] * size[1] * size[2]
    return {'size': size, 'names': names, 'param2': bytes(param2 or [0] * n)}


class DiffTests(unittest.TestCase):
    def test_same_size_counts_by_name(self):
        a = mts((2, 1, 2), ['air', 'a', 'b', 'a'])
        b = mts((2, 1, 2), ['air', 'c', 'b', 'c'])
        d = reimport.diff_nodes(a, b)
        self.assertEqual(d['changed'], 2)
        self.assertEqual(d['by_name'], {'a -> c': 2})

    def test_param2_only_and_identical(self):
        a = mts((1, 1, 2), ['a', 'air'], [1, 5])
        self.assertEqual(reimport.diff_nodes(a, mts((1, 1, 2), ['a', 'air'], [1, 5]))['changed'], 0)
        d = reimport.diff_nodes(a, mts((1, 1, 2), ['a', 'air'], [2, 7]))
        self.assertEqual((d['changed'], d['param2_only']), (0, 1))

    def test_size_change(self):
        d = reimport.diff_nodes(mts((1, 1, 1), ['a']), mts((2, 1, 1), ['a', 'b']))
        self.assertTrue(d['size_changed'])
        self.assertEqual(d['count_delta'], {'b': 1})

    def test_real_schematic_reads_and_matches_itself(self):
        m = reimport.read_mts(ROOT / 'schematics/templates/chapel.mts')
        self.assertEqual(len(m['names']), m['size'][0] * m['size'][1] * m['size'][2])
        self.assertEqual(reimport.diff_nodes(m, m)['changed'], 0)

    def test_record_diff_ignores_provenance_and_backfilled_counters(self):
        old = {'size': {'x': 1}, 'snapshot_sha256': 'a'}
        new = {'size': {'x': 2}, 'snapshot_sha256': 'b', 'wall_count': 0}
        self.assertEqual(reimport.diff_records(old, new), {'size': [{'x': 1}, {'x': 2}]})

    def test_classify(self):
        base = {'nodes': {'changed': 0}, 'sidecar_changed': False, 'geometry': {}, 'records': {}}
        self.assertEqual(reimport.classify(dict(base)), 'unchanged')
        self.assertEqual(reimport.classify(dict(base, sidecar_changed=True)), 'changed')
        self.assertEqual(reimport.classify(dict(base, geometry={'size': [1, 2]})), 'geometry')
        self.assertEqual(reimport.classify(dict(base, failure='x')), 'fails')


class GateTests(unittest.TestCase):
    REG = {'chapel': {'kind': 'template', 'files': ['schematics/templates/chapel.mts', 'schematics/templates/chapel.lua']},
           'bath': {'kind': 'roman', 'files': ['schematics/imports/roman/bath.mts', 'schematics/imports/roman/bath.lua']},
           'shepherd_hut': {'kind': 'outskirts', 'files': ['schematics/outskirts/small_house.mts',
                                                           'schematics/outskirts/small_house.lua']}}

    def test_allowed_files(self):
        self.assertEqual(reimport.allowed_files(self.REG, ['chapel']), {
            'schematics/templates/chapel.mts', 'schematics/templates/chapel.lua',
            'schematics/templates/manifest.json', 'schematics/templates/catalog.lua'})
        self.assertEqual(len(reimport.allowed_files(self.REG, ['shepherd_hut'])), 2)  # no manifest

    def test_file_violations(self):
        allowed = reimport.allowed_files(self.REG, ['bath'])
        before = {'schematics/imports/roman/bath.mts': 'a', 'schematics/imports/roman/arch.mts': 'x',
                  'schematics/outskirts/farm.mts': 'f'}
        after = {'schematics/imports/roman/bath.mts': 'b', 'schematics/imports/roman/arch.mts': 'y',
                 'schematics/outskirts/farm.mts': 'f', 'schematics/new.mts': 'n'}
        self.assertEqual(reimport.file_violations(before, after, allowed),
                         ['schematics/imports/roman/arch.mts', 'schematics/new.mts'])

    def test_manifest_violations(self):
        before = {'source_world': 'w', 'buildings': [{'id': 'a', 'v': 1}, {'id': 'b', 'v': 1}]}
        ok = {'source_world': 'w', 'buildings': [{'id': 'a', 'v': 2}, {'id': 'b', 'v': 1}]}
        self.assertEqual(reimport.manifest_violations('roman', before, ok, ['a']), [])
        other = {'source_world': 'w', 'buildings': [{'id': 'a', 'v': 1}, {'id': 'b', 'v': 2}]}
        self.assertEqual(len(reimport.manifest_violations('roman', before, other, ['a'])), 1)
        moved = dict(ok, source_world='/tmp/scratch')
        self.assertEqual(len(reimport.manifest_violations('roman', before, moved, ['a'])), 1)
        rv = dict(ok, runtime_validation={'n': 1})
        self.assertEqual(len(reimport.manifest_violations('template', before, rv, ['a'])), 1)
        self.assertEqual(reimport.manifest_violations('template', before, rv, ['a'], ('runtime_validation',)), [])


class RegistryTests(unittest.TestCase):
    def test_excluded_ids_never_registered(self):
        reg = reimport.registry(ROOT)
        for i in reimport.EXCLUDED:
            self.assertNotIn(i, reg)
        self.assertEqual(reg['soup_shop']['kind'], 'template')
        self.assertEqual(reg['hippodrome']['kind'], 'roman')
        self.assertEqual(reg['shepherd_hut']['kind'], 'outskirts')
        self.assertTrue(reg['wall_tower']['clip'])
        self.assertIn('farm', reimport.EXCLUDED)

    def test_pin_hints_only_for_moved_geometry(self):
        reg = reimport.registry(ROOT)
        hints = reimport.pin_hints(ROOT, {'chapel': {'size': [1]}, 'bath': {'size': [1]}},
                                   {'chapel': {'size': [1]}, 'bath': {'size': [2]}}, reg, ['chapel', 'bath'])
        self.assertEqual(len(hints), 1)
        self.assertIn('roman/catalog.lua', hints[0])


if __name__ == '__main__':
    unittest.main()
