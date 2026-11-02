#!/usr/bin/env python3
"""One entry point for re-importing buildings edited in TownsWorkshop (#377).

    python3 tools/reimport.py                       # compare (read-only for the repo)
    python3 tools/reimport.py compare --json out.json
    python3 tools/reimport.py apply --ids chapel,hippodrome
    python3 tools/reimport.py apply --all-changed

Close the game and return to the menu first so your edits are saved (the tool
refuses to run on a world that is open; `compare --allow-open-world` gives a
read-only look at the last saved state).

compare  Takes one read-only SQLite snapshot of the workshop, exports every
         registered TownsWorkshop building into a SCRATCH copy of tools/ and
         schematics/ (the repo tree is never written), and reports per building:
         unchanged / changed (node diff by name) / size or entrance change /
         fails. It also scans a ring around every capture box for possible
         clipped architecture (see tools/reimport_scan.lua for the noise filter).
apply    Runs the right exporter (template path: workshop_export/export.py;
         Roman: issue139_import/export_roman.py; outskirts: issue196_import/
         export.py) with --only for the chosen ids against the real workshop, then
         gates the result: only those ids' schematics/sidecars and manifest records
         may change, manifest provenance must stay put, Roman changes pass
         tools/roman_check/run.py. It prints which test pins likely need updating
         but never edits tests or the hand-maintained Roman/outskirts catalogs.

This script only orchestrates the existing exporters; it does not reimplement
capture or rotation. Run the unit tests with `python3 -m unittest tools/test_reimport.py`.
"""
import argparse
import collections
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools/issue341_import'))
sys.path.insert(0, str(ROOT / 'tools/issue139_import'))
from common import ENGINE, WORLDS, copy_world, run_server, sha256, world_is_open  # noqa: E402
import export_roman  # noqa: E402

WORKSHOP = WORLDS / 'TownsWorkshop'

# Ids that look like workshop buildings but must NEVER be exported from the workshop.
# Each is skipped by name in every mode; naming one in --ids is an error.
EXCLUDED = {
    # Authored in code (tools/issue255_farm/build.py, #282); the workshop copy is the stale
    # fenced farm. issue196_import/export.py also refuses to write the farm files.
    'farm': 'authored in code (#282); the workshop copy is stale',
    # Stock VoxeLibre village schematics seeded into a scratch world (workshop_export/README.md).
    'tavern': 'stock village template, not a TownsWorkshop build',
    'well': 'stock village template, not a TownsWorkshop build',
    'library': 'stock village template, not a TownsWorkshop build',
    'blacksmith': 'stock village template, not a TownsWorkshop build',
}
# Geometry-bearing record fields; a change in one of them moves test pins / catalogs.
GEOMETRY_KEYS = ('size', 'entrance', 'entrance_kind', 'ground_offset', 'rotation')
# Per-run provenance that differs on every export and carries no content.
VOLATILE_KEYS = ('snapshot_sha256', 'source_map_sha256')
# Verification counters older records never stored; their first appearance is not a change.
BACKFILLED_KEYS = ('wall_count', 'wall_mismatches')
SCAN_MARGIN = 8


# ---------------------------------------------------------------- registry

def _load_outskirts(repo):
    spec = importlib.util.spec_from_file_location('issue196_export', repo / 'tools/issue196_import/export.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.BUILDINGS


def registry(repo=ROOT, world=None):
    """Every registered TownsWorkshop building: id -> {kind, box, files, ...}.

    kind is 'template' (workshop_export), 'roman' (export_roman) or 'outskirts'
    (issue196 export). `box` is the fixed capture box (min, max) or None for
    auto-captured template buildings (the exporter fails on its own if those
    outgrow their survey region). Excluded ids are not included.
    """
    reg = {}
    config = json.loads((repo / 'tools/workshop_export/buildings.json').read_text())
    for b in config['buildings']:
        if b['id'] in EXCLUDED:
            continue
        box = (b['capture_min'], b['capture_max']) if 'capture_min' in b else None
        reg[b['id']] = {'kind': 'template', 'box': box, 'clip': bool(b.get('clip_to_capture')),
                        'files': ['schematics/templates/%s.mts' % b['id'], 'schematics/templates/%s.lua' % b['id']]}
    recorded = {}
    if world is not None and (Path(world) / 'issue139-validation.json').exists():
        recorded = {r['id']: r for r in json.loads((Path(world) / 'issue139-validation.json').read_text())['records']}
    for i in export_roman.IDS:
        if i in EXCLUDED:
            continue
        box = export_roman.FIXED_BOXES.get(i)
        if box is None and i in recorded:
            o, s = recorded[i]['origin'], recorded[i]['size']
            box = (o, {k: o[k] + s[k] - 1 for k in 'xyz'})
        reg[i] = {'kind': 'roman', 'box': box,
                  'files': ['schematics/imports/roman/%s.mts' % i, 'schematics/imports/roman/%s.lua' % i]}
    for b in _load_outskirts(repo):
        if b['id'] in EXCLUDED:
            continue
        reg[b['id']] = {'kind': 'outskirts', 'box': (b['min'], b['max']),
                        'files': [b['path'], b['path'].replace('.mts', '.lua')]}
    return reg


MANIFESTS = {'template': 'schematics/templates/manifest.json', 'roman': 'schematics/imports/roman/manifest.json'}
CATALOGS = {'template': 'schematics/templates/catalog.lua'}  # generated; the others are hand-maintained


def load_records(repo, kind):
    path = Path(repo) / MANIFESTS.get(kind, '')
    if kind not in MANIFESTS or not path.exists():
        return {}
    return {b['id']: b for b in json.loads(path.read_text())['buildings']}


# ---------------------------------------------------------------- MTS reading and diffing

def read_mts(path):
    """Read a Luanti .mts (v3/v4): {'size': (x, y, z), 'names': [...], 'param2': bytes}, x fastest."""
    d = Path(path).read_bytes()
    if d[:4] != b'MTSM':
        raise ValueError('not an MTS file: %s' % path)
    version, sx, sy, sz = struct.unpack('>HHHH', d[4:12])
    p = 12 + (sy if version >= 3 else 0)
    count, = struct.unpack('>H', d[p:p + 2])
    p += 2
    table = []
    for _ in range(count):
        n, = struct.unpack('>H', d[p:p + 2])
        table.append(d[p + 2:p + 2 + n].decode('utf-8'))
        p += 2 + n
    raw = zlib.decompress(d[p:])
    total = sx * sy * sz
    ids = struct.unpack('>%dH' % total, raw[:2 * total])
    return {'size': (sx, sy, sz), 'names': [table[i] for i in ids], 'param2': raw[3 * total:4 * total]}


def diff_nodes(old, new, top=8):
    """Summarise the node difference of two read_mts results (None means the file is absent)."""
    if old is None or new is None:
        return {'size_changed': False, 'changed': 0, 'added_file': old is None, 'removed_file': new is None}
    if old['size'] != new['size']:
        delta = collections.Counter(new['names'])
        delta.subtract(collections.Counter(old['names']))
        return {'size_changed': True, 'old_size': list(old['size']), 'new_size': list(new['size']),
                'changed': sum(abs(v) for v in delta.values()) // 2,
                'count_delta': {k: v for k, v in sorted(delta.items(), key=lambda kv: -abs(kv[1])) if v}}
    pairs = collections.Counter()
    param2_only = 0
    for a, b, pa, pb in zip(old['names'], new['names'], old['param2'], new['param2']):
        if a != b:
            pairs['%s -> %s' % (a, b)] += 1
        elif pa != pb and a != 'air':
            param2_only += 1
    return {'size_changed': False, 'changed': sum(pairs.values()), 'param2_only': param2_only,
            'by_name': dict(pairs.most_common(top)), 'distinct_changes': len(pairs)}


def diff_records(old, new):
    """Changed manifest-record keys (volatile provenance ignored): {key: [old, new]}."""
    old, new = old or {}, new or {}
    return {k: [old.get(k), new.get(k)] for k in sorted(set(old) | set(new))
            if k not in VOLATILE_KEYS and old.get(k) != new.get(k)
            and not (k in BACKFILLED_KEYS and k not in old)}


def classify(entry):
    """Status string for a compare entry (see compare_one)."""
    if entry.get('failure'):
        return 'fails'
    if entry['geometry']:
        return 'geometry'
    if entry['nodes']['changed'] or entry['nodes'].get('param2_only') or entry['sidecar_changed'] \
            or entry['records']:
        return 'changed'
    return 'unchanged'


# ---------------------------------------------------------------- running exporters

def exporter_command(repo, kind, ids, world, engine, validate=False):
    py = sys.executable
    if kind == 'template':
        cmd = [py, str(repo / 'tools/workshop_export/export.py'), '--world', str(world), '--engine', engine, '--only', *ids]
        return cmd + (['--validate'] if validate else [])
    if kind == 'roman':
        return [py, str(repo / 'tools/issue139_import/export_roman.py'), '--world', str(world), '--engine', engine, '--only', *ids]
    return [py, str(repo / 'tools/issue196_import/export.py'), '--world', str(world), '--engine', engine, '--only', *ids]


def run_exporter(repo, kind, ids, world, engine, validate=False):
    """Run one exporter with --only. Returns (ok, output, reason)."""
    proc = subprocess.run(exporter_command(repo, kind, ids, world, engine, validate),
                          capture_output=True, text=True)
    out = proc.stdout + proc.stderr
    if proc.returncode == 0:
        return True, out, ''
    reason = [l for l in out.splitlines() if l.strip()][-1:] or ['exporter failed']
    m = re.search(r'inspect (\S+engine\.log)', out) or re.search(r'inspect (\S+runtime\.log)', out)
    if m and Path(m.group(1)).exists():
        errors = [l for l in Path(m.group(1)).read_text(errors='replace').splitlines() if 'ERROR' in l]
        if errors:
            reason = [errors[-1].split('ERROR[Main]:')[-1].strip()]
    return False, out, reason[0]


def group_by_kind(reg, ids):
    groups = collections.OrderedDict()
    for i in ids:
        groups.setdefault(reg[i]['kind'], []).append(i)
    return groups


# ---------------------------------------------------------------- compare

def snapshot_world(world, scratch):
    """Consistent read-only copy of `world` (plus the Roman validation report the exporter reads)."""
    snap = scratch / 'world'
    if copy_world(world, snap) is None:
        raise SystemExit('The workshop map changed while it was being copied; close the game and retry.')
    for name in ('issue139-validation.json',):
        if (world / name).exists():
            shutil.copy2(world / name, snap / name)
    return snap


def scratch_repo(scratch):
    """Copy of the pieces the exporters write to / run from, so exporters cannot touch the real tree."""
    repo = scratch / 'repo'
    shutil.copytree(ROOT / 'tools', repo / 'tools', ignore=shutil.ignore_patterns('__pycache__'))
    shutil.copytree(ROOT / 'schematics', repo / 'schematics')
    return repo


def compare_one(i, info, repo_old, repo_new):
    files = info['files']
    mts_old, mts_new = repo_old / files[0], repo_new / files[0]
    lua_old, lua_new = repo_old / files[1], repo_new / files[1]
    nodes = diff_nodes(read_mts(mts_old) if mts_old.exists() else None, read_mts(mts_new) if mts_new.exists() else None)
    sidecar = (lua_old.read_text() if lua_old.exists() else None) != (lua_new.read_text() if lua_new.exists() else None)
    kind = info['kind']
    records = diff_records(load_records(repo_old, kind).get(i), load_records(repo_new, kind).get(i))
    geometry = {k: v for k, v in records.items() if k in GEOMETRY_KEYS}
    if nodes.get('size_changed'):
        geometry.setdefault('size', [nodes['old_size'], nodes['new_size']])
    entry = {'id': i, 'kind': kind, 'nodes': nodes, 'sidecar_changed': sidecar, 'geometry': geometry,
             'records': {k: v for k, v in records.items() if k not in GEOMETRY_KEYS and k != 'required_nodes'}}
    entry['status'] = classify(entry)
    return entry


def run_scan(snap, boxes, engine, margin, port=39499):
    """Run reimport_scan.lua on a copy of the snapshot. boxes: {id: (min, max)}."""
    work = snap.parent / 'scan-world'
    if copy_world(snap, work) is None:
        raise SystemExit('Snapshot changed unexpectedly.')
    (work / 'reimport-scan-job.json').write_text(json.dumps(
        {'margin': margin, 'boxes': [{'id': i, 'min': lo, 'max': hi} for i, (lo, hi) in boxes.items()]}))
    mod = work / 'worldmods/reimport_scan'
    mod.mkdir(parents=True)
    shutil.copy2(ROOT / 'tools/reimport_scan.lua', mod / 'init.lua')
    (mod / 'mod.conf').write_text('name = reimport_scan\n')
    (work / 'helper.conf').write_text('enable_ipv6 = false\nbind_address = 127.0.0.1\nserver_announce = false\n')
    run_server(work, port, engine)
    out = work / 'reimport-scan.json'
    if not out.exists():
        raise SystemExit('Outside-box scan failed; inspect ' + str(work / 'engine.log'))
    return json.loads(out.read_text())


def compare(world, engine, allow_open, ids=None, margin=SCAN_MARGIN, keep=False, scan=True):
    if world_is_open(world) and not allow_open:
        raise SystemExit('%s is open: return to the menu so edits are saved, or pass --allow-open-world '
                         'to look at the last saved state.' % world.name)
    scratch = Path(tempfile.mkdtemp(prefix='towns-reimport-'))
    try:
        snap = snapshot_world(world, scratch)
        reg = registry(ROOT, snap)
        selected = list(ids) if ids else list(reg)
        for i in selected:
            if i not in reg:
                raise SystemExit('Unknown or excluded id %s%s' % (i, ' (%s)' % EXCLUDED[i] if i in EXCLUDED else ''))
        repo = scratch_repo(scratch)
        failures = {}
        for kind, group in group_by_kind(reg, selected).items():
            print('Exporting %s buildings to scratch: %s' % (kind, ', '.join(group)), flush=True)
            ok, out, reason = run_exporter(repo, kind, group, snap, engine)
            if not ok:
                # One bad building fails the whole --only run: find which.
                for i in group:
                    ok1, _, why = run_exporter(repo, kind, [i], snap, engine)
                    if not ok1:
                        failures[i] = why
        entries = []
        for i in selected:
            if i in failures:
                entries.append({'id': i, 'kind': reg[i]['kind'], 'status': 'fails', 'failure': failures[i],
                                'nodes': {}, 'geometry': {}, 'records': {}, 'sidecar_changed': False})
            else:
                entries.append(compare_one(i, reg[i], ROOT, repo))
        scan_report = []
        if scan:
            boxes = {i: reg[i]['box'] for i in selected if reg[i]['box']}
            print('Scanning around %d capture boxes' % len(boxes), flush=True)
            scan_report = run_scan(snap, boxes, engine, margin)
        by_id = {r['id']: r for r in scan_report}
        for e in entries:
            e['outside_scan'] = by_id.get(e['id'])
            if e['outside_scan']:
                # clip_to_capture entries (wall assets) deliberately keep only the box, so their
                # wall arms leaving the box are expected, not a missed part of the building.
                e['outside_scan']['expected'] = reg[e['id']].get('clip', False)
        report = {'world': str(world), 'excluded': EXCLUDED, 'buildings': entries,
                  'scratch': str(scratch) if keep else None}
        return report
    finally:
        if not keep:
            shutil.rmtree(scratch, ignore_errors=True)


def format_report(report):
    lines = []
    rows = report['buildings']
    width = max(len(e['id']) for e in rows)
    for e in rows:
        n = e['nodes']
        parts = []
        if e['status'] == 'fails':
            parts.append(e['failure'])
        if e['geometry']:
            parts.append('; '.join('%s %s -> %s' % (k, json.dumps(v[0]), json.dumps(v[1])) for k, v in e['geometry'].items()))
        if n.get('changed') and not n.get('size_changed'):
            top = ', '.join('%s x%d' % (k, v) for k, v in list(n['by_name'].items())[:4])
            parts.append('%d nodes (%s%s)' % (n['changed'], top, ', ...' if n['distinct_changes'] > 4 else ''))
        elif n.get('size_changed'):
            top = ', '.join('%s %+d' % kv for kv in list(n['count_delta'].items())[:4])
            parts.append('node counts: ' + top)
        if n.get('param2_only'):
            parts.append('%d param2-only' % n['param2_only'])
        if e['sidecar_changed']:
            parts.append('sidecar (metadata/inventories) differs')
        if e['records'] and not parts:
            parts.append('record fields: ' + ', '.join(e['records']))
        lines.append('%-*s  %-9s %-9s %s' % (width, e['id'], e['kind'], e['status'].upper(), ' | '.join(parts)))
    clipped = [e for e in rows if e.get('outside_scan') and e['outside_scan']['touching']
               and not e['outside_scan']['expected']]
    expected = [e['id'] for e in rows if e.get('outside_scan') and e['outside_scan']['touching']
                and e['outside_scan']['expected']]
    lines.append('')
    if not any(e.get('outside_scan') for e in rows):
        lines.append('Outside-box scan: not run')
    elif not clipped:
        lines.append('Outside-box scan: nothing possibly clipped')
    else:
        lines.append('Possible clipped architecture (non-natural nodes above ground touching the box from outside;')
        lines.append('expected for wall tie-in stubs and similar; real misses need a larger capture box):')
        for e in clipped:
            s = e['outside_scan']
            b = s['bounds']
            names = ', '.join('%s x%d' % kv for kv in sorted(s['names'].items(), key=lambda kv: -kv[1])[:4])
            lines.append('  %s: %d nodes (%s) x %d..%d y %d..%d z %d..%d  e.g. %s' % (
                e['id'], s['touching'], names, b['min']['x'], b['max']['x'], b['min']['y'], b['max']['y'],
                b['min']['z'], b['max']['z'], s['samples'][0]))
    if expected:
        lines.append('Wall arms leaving clip_to_capture boxes (expected): ' + ', '.join(expected))
    counts = collections.Counter(e['status'] for e in rows)
    lines.append('')
    lines.append('Summary: ' + ', '.join('%d %s' % (v, k) for k, v in sorted(counts.items())))
    skipped = ', '.join(sorted(report['excluded']))
    lines.append('Excluded (not TownsWorkshop-sourced or retired): ' + skipped)
    return '\n'.join(lines)


# ---------------------------------------------------------------- apply and its gate

def hash_tree(root):
    root = Path(root)
    return {str(p.relative_to(root)): sha256(p) for p in sorted(root.rglob('*')) if p.is_file()}


def allowed_files(reg, ids):
    allowed = set()
    for i in ids:
        allowed.update(reg[i]['files'])
        kind = reg[i]['kind']
        if kind in MANIFESTS:
            allowed.add(MANIFESTS[kind])
        if kind in CATALOGS:
            allowed.add(CATALOGS[kind])
    return allowed


def file_violations(before, after, allowed):
    """Paths whose hash changed (or that appeared/vanished) and are not in `allowed`.

    Keys are repo-relative paths under schematics/ (hash_tree of the repo's schematics dir,
    prefixed by the caller)."""
    return sorted(p for p in set(before) | set(after) if before.get(p) != after.get(p) and p not in allowed)


def manifest_violations(kind, before, after, ids, allow_keys=()):
    """Messages for manifest changes beyond the named ids' records, `last_export_buildings`
    and any `allow_keys` (runtime_validation when the template validation was re-run)."""
    problems = []
    for key in sorted(set(before) | set(after)):
        if key in ('buildings', 'last_export_buildings') or key in allow_keys:
            continue
        if before.get(key) != after.get(key):
            problems.append('%s manifest top-level %r changed (%s -> %s)' % (
                kind, key, json.dumps(before.get(key))[:60], json.dumps(after.get(key))[:60]))
    old = {b['id']: b for b in before.get('buildings', [])}
    new = {b['id']: b for b in after.get('buildings', [])}
    for i in sorted((set(old) | set(new)) - set(ids)):
        if old.get(i) != new.get(i):
            problems.append('%s manifest record %s changed' % (kind, i))
    return problems


def read_manifest(repo, kind):
    path = Path(repo) / MANIFESTS[kind]
    return json.loads(path.read_text()) if path.exists() else {}


def git_status_outside(repo):
    proc = subprocess.run(['git', '-C', str(repo), 'status', '--porcelain'], capture_output=True, text=True)
    if proc.returncode:
        return None
    return {l for l in proc.stdout.splitlines() if 'schematics/' not in l}


def pin_hints(repo, before_geom, after_geom, reg, ids):
    """Files that probably pin the geometry of ids whose size/entrance moved."""
    hints = []
    for i in ids:
        if before_geom.get(i) == after_geom.get(i):
            continue
        kind = reg[i]['kind']
        files = []
        for d in ('tests', 'tools/roman_check'):
            for p in sorted((Path(repo) / d).glob('*.lua')):
                if re.search(r'\b%s\b' % re.escape(i), p.read_text(errors='replace')):
                    files.append(str(p.relative_to(repo)))
        if kind == 'roman':
            files.append('schematics/imports/roman/catalog.lua (hand-maintained size/entrance/ground_offset)')
        elif kind == 'outskirts':
            files.append('schematics/outskirts/catalog.lua (hand-maintained)')
        hints.append('%s: %s -> %s; check: %s' % (i, json.dumps(before_geom.get(i)), json.dumps(after_geom.get(i)),
                                               ', '.join(files) or 'no test mentions it'))
    return hints


def geometry_of(repo, reg, i):
    info = reg[i]
    rec = load_records(repo, info['kind']).get(i)
    if rec is not None and info['kind'] == 'template':
        return {k: rec.get(k) for k in ('size', 'entrance', 'ground_offset')}
    mts = Path(repo) / info['files'][0]
    return {'size': list(read_mts(mts)['size'])} if mts.exists() else None


def apply(ids, world, engine, repo=ROOT, validate=True, allow_clipped=False, margin=SCAN_MARGIN):
    world = Path(world)
    if world_is_open(world):
        raise SystemExit('%s is open: return to the menu so edits are saved, then retry.' % world.name)
    reg = registry(repo, world)
    for i in ids:
        if i not in reg:
            raise SystemExit('Unknown or excluded id %s%s' % (i, ' (%s)' % EXCLUDED[i] if i in EXCLUDED else ''))
    if not allow_clipped:
        boxes = {i: reg[i]['box'] for i in ids if reg[i]['box']}
        scratch = Path(tempfile.mkdtemp(prefix='towns-reimport-scan-'))
        try:
            clipped = [r for r in run_scan(snapshot_world(world, scratch), boxes, engine, margin)
                       if r['touching'] and not reg[r['id']].get('clip')]
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
        if clipped:
            raise SystemExit('Possible clipped architecture, nothing exported (inspect with `compare`; '
                             'pass --allow-clipped if expected):\n' + json.dumps(clipped, indent=1))
    schem = Path(repo) / 'schematics'
    before = {'schematics/' + k: v for k, v in hash_tree(schem).items()}
    manifests_before = {k: read_manifest(repo, k) for k in MANIFESTS}
    geom_before = {i: geometry_of(repo, reg, i) for i in ids}
    outside_before = git_status_outside(repo)
    for kind, group in group_by_kind(reg, ids).items():
        print('Exporting %s: %s' % (kind, ', '.join(group)), flush=True)
        ok, out, reason = run_exporter(repo, kind, group, world, engine, validate and kind == 'template')
        sys.stdout.write(out)
        if not ok:
            raise SystemExit('Exporter failed (%s). schematics/ may be partly written; review `git status`.' % reason)
    after = {'schematics/' + k: v for k, v in hash_tree(schem).items()}
    problems = ['schematics file changed outside the named ids: ' + p
                for p in file_violations(before, after, allowed_files(reg, ids))]
    for kind in MANIFESTS:
        problems += manifest_violations(kind, manifests_before[kind], read_manifest(repo, kind),
                                        [i for i in ids if reg[i]['kind'] == kind],
                                        ('runtime_validation',) if validate else ())
    if validate and 'template' in {reg[i]['kind'] for i in ids}:
        if 'runtime_validation' in manifests_before['template'] and \
                'runtime_validation' not in read_manifest(repo, 'template'):
            problems.append('template manifest lost runtime_validation (re-run with validation)')
    outside_after = git_status_outside(repo)
    if outside_before is not None and outside_after != outside_before:
        problems.append('files outside schematics/ changed: ' + ', '.join(sorted(outside_after ^ outside_before)))
    # Provenance: the manifest must keep naming the real workshop, with the real map's hash.
    sha = sha256(world / 'map.sqlite')
    roman = read_manifest(repo, 'roman')
    if world.resolve() == WORKSHOP.resolve() and roman and roman.get('source_world') != str(WORKSHOP.resolve()):
        problems.append('roman manifest source_world is %s, not the real workshop' % roman.get('source_world'))
    for rec in roman.get('buildings', []) if roman else []:
        if rec['id'] in ids and rec.get('source_map_sha256') != sha:
            problems.append('roman record %s source_map_sha256 does not match %s' % (rec['id'], world.name))
    if problems:
        raise SystemExit('Reimport gate FAILED (inspect and `git checkout -- schematics` to discard):\n  '
                         + '\n  '.join(problems))
    changed_ids = [i for i in ids if any(before.get(f) != after.get(f) for f in reg[i]['files'])]
    if any(reg[i]['kind'] == 'roman' for i in changed_ids):
        print('Roman landmark changed: running roman_check', flush=True)
        subprocess.run([sys.executable, str(Path(repo) / 'tools/roman_check/run.py'), '--engine', engine,
                        '--settings-from', str(world)], check=True)
    geom_after = {i: geometry_of(repo, reg, i) for i in ids}
    print('\nChanged: %s' % (', '.join(changed_ids) or 'nothing'))
    for hint in pin_hints(repo, geom_before, geom_after, reg, ids):
        print('Size/entrance moved, update pins: ' + hint)
    print('Gate passed. Run `/Users/tad/.local/bin/lua5.1 tests/run.lua` (or lua5.1 tests/run.lua) and review `git diff --stat`.')
    return changed_ids


# ---------------------------------------------------------------- CLI

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument('--world', type=Path, default=WORKSHOP)
    common.add_argument('--engine', default=ENGINE)
    sub = ap.add_subparsers(dest='mode')
    c = sub.add_parser('compare', parents=[common], help='read-only report of what changed in the workshop (default)')
    c.add_argument('--ids', help='comma-separated ids (default: every registered building)')
    c.add_argument('--json', metavar='FILE', help='write the machine-readable report here ("-" for stdout)')
    c.add_argument('--allow-open-world', action='store_true', help='read the last saved state of an open world')
    c.add_argument('--margin', type=int, default=SCAN_MARGIN)
    c.add_argument('--no-scan', action='store_true')
    c.add_argument('--keep-scratch', action='store_true')
    a = sub.add_parser('apply', parents=[common], help='re-export the chosen buildings into the repo, with gates')
    g = a.add_mutually_exclusive_group(required=True)
    g.add_argument('--ids', help='comma-separated ids')
    g.add_argument('--all-changed', action='store_true', help='run compare first and apply every changed id')
    a.add_argument('--no-validate', action='store_true', help='skip the slow template runtime validation')
    a.add_argument('--allow-clipped', action='store_true', help='export even if the outside-box scan finds something')
    a.add_argument('--margin', type=int, default=SCAN_MARGIN)
    a.add_argument('--repo', type=Path, default=ROOT, help='repo whose tools/ and schematics/ to use (default: this one)')
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv or argv[0] not in ('compare', 'apply', '-h', '--help'):
        argv.insert(0, 'compare')  # compare is the default mode
    args = ap.parse_args(argv)
    mode = args.mode
    args.world = args.world.resolve()
    if mode == 'compare':
        ids = args.ids.split(',') if args.ids else None
        report = compare(args.world, args.engine, args.allow_open_world, ids, args.margin, args.keep_scratch,
                         not args.no_scan)
        print(format_report(report))
        if args.json == '-':
            print(json.dumps(report, indent=1))
        elif args.json:
            Path(args.json).write_text(json.dumps(report, indent=1) + '\n')
        if report['scratch']:
            print('Scratch kept at', report['scratch'])
        return 0
    if args.all_changed:
        report = compare(args.world, args.engine, False, None, args.margin, False, False)
        ids = [e['id'] for e in report['buildings'] if e['status'] in ('changed', 'geometry')]
        print(format_report(report))
        if not ids:
            print('Nothing changed.')
            return 0
    else:
        ids = args.ids.split(',')
    apply(ids, args.world, args.engine, args.repo.resolve(), not args.no_validate, args.allow_clipped, args.margin)
    return 0


if __name__ == '__main__':
    sys.exit(main())
