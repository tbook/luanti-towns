#!/usr/bin/env python3
"""Capture the cleaned Issue 139 buildings as standalone, non-generator assets."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HELPER = Path(__file__).resolve().parent
WORKSHOP = Path.home() / 'Library/Application Support/minetest/worlds/TownsWorkshop'
# Fixed capture boxes (inclusive world coordinates) that replace the validation
# report's building box. Each is recorded per building in the manifest.
FIXED_BOXES = {
    # Tight bath box (#171): the architecture plus the two ground rows and the
    # approach, without the dirt/grass/gravel platform margin around it.
    'bath': ({'x': 101, 'y': 7, 'z': 399}, {'x': 188, 'y': 24, 'z': 441}),
    # Insula (#193): the issue's box (213..248, 6..25, 399..426) minus the x=0 and
    # z=27 grass/dirt platform margin; the eaves at x=1..35 and z=0..26 are kept.
    'insula': ({'x': 214, 'y': 6, 'z': 399}, {'x': 248, 'y': 25, 'z': 425}),
}
# Buildings recorded in the Issue 139 workshop report; insula is not.
RECORDED = ('domus', 'arch', 'theatre', 'villa', 'aqueduct', 'amphitheater', 'temple', 'bath')
IDS = RECORDED + ('insula',)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--world', type=Path, default=WORKSHOP)
    ap.add_argument('--engine', default='/Applications/luanti.app/Contents/MacOS/luanti')
    ap.add_argument('--port', type=int, default=39489)
    ap.add_argument('--only', nargs='+', choices=IDS,
                    help='re-export just these buildings, keeping the other manifest records')
    args = ap.parse_args()
    wanted = tuple(args.only) if args.only else IDS
    source = args.world.resolve()
    opened = subprocess.run(['lsof', '-F', 'n', str(source / 'map.sqlite')], capture_output=True, text=True)
    if opened.returncode != 1 or opened.stdout:
        raise SystemExit('TownsWorkshop is open; return to the menu before exporting.')
    validation = json.loads((source / 'issue139-validation.json').read_text())
    records = {r['id']: r for r in validation['records']}
    if set(records) != set(RECORDED):
        raise SystemExit('Issue 139 workshop report does not contain exactly the expected eight buildings.')
    jobs = []
    for name in wanted:
        r = records.get(name)
        if r is None and name not in FIXED_BOXES:
            raise SystemExit(name + ' has no workshop record and no fixed box.')
        lo = dict(r['origin']) if r else dict(FIXED_BOXES[name][0])
        size = dict(r['size']) if r else None
        hi = {k: lo[k] + size[k] - 1 for k in ('x', 'y', 'z')} if r else None
        if name in FIXED_BOXES:
            lo, hi = (dict(c) for c in FIXED_BOXES[name])
        if size is None:
            size = {k: hi[k] - lo[k] + 1 for k in ('x', 'y', 'z')}
        r = r or {'origin': lo, 'size': size}
        if name == 'temple':
            # Keep the terrain row below the quartz platform so the floor stands on it (#134).
            lo = {**lo, 'y': lo['y'] - 1}
        jobs.append({'id': name, 'min': lo, 'max': hi, 'building_origin': r['origin'],
                     'building_size': r['size']})
    work = Path(tempfile.mkdtemp(prefix='towns-roman-export-'))
    for filename in ('world.mt', 'map_meta.txt'):
        shutil.copy2(source / filename, work / filename)
    with sqlite3.connect((source / 'map.sqlite').as_uri() + '?mode=ro', uri=True) as src:
        with sqlite3.connect(work / 'map.sqlite') as dst:
            src.backup(dst)
    snapshot_sha = hashlib.sha256((work / 'map.sqlite').read_bytes()).hexdigest()
    source_sha = hashlib.sha256((source / 'map.sqlite').read_bytes()).hexdigest()
    (work / 'roman-export.json').write_text(json.dumps(jobs))
    (work / 'out').mkdir()
    mod = work / 'worldmods/roman_export'
    mod.mkdir(parents=True)
    shutil.copy2(HELPER / 'export_roman.lua', mod / 'init.lua')
    (mod / 'mod.conf').write_text('name = roman_export\n')
    (work / 'export.conf').write_text('enable_ipv6 = false\nbind_address = 127.0.0.1\nserver_announce = false\n')
    with (work / 'stdout.log').open('w') as log:
        p = subprocess.run([args.engine, '--server', '--world', str(work), '--gameid', 'mineclone2',
                            '--config', str(work / 'export.conf'), '--port', str(args.port),
                            '--logfile', str(work / 'engine.log')], stdout=log, stderr=subprocess.STDOUT, timeout=300)
    result_path = work / 'roman-results.json'
    if p.returncode or not result_path.exists():
        raise SystemExit('Roman capture failed; inspect ' + str(work / 'engine.log'))
    results = json.loads(result_path.read_text())
    if {r['id'] for r in results} != set(wanted):
        raise SystemExit('Roman capture report is incomplete: ' + str(work))
    output = ROOT / 'schematics/imports/roman'
    output.mkdir(parents=True, exist_ok=True)
    manifest_path = output / 'manifest.json'
    kept = json.loads(manifest_path.read_text()) if args.only else None
    manifest = {'source_world': str(source), 'snapshot_sha256': snapshot_sha,
                'buildings': [], 'generator_catalog': False}
    for job in jobs:
        result = next(r for r in results if r['id'] == job['id'])
        metadata = result.get('metadata') or []
        required_nodes = result.get('required_nodes') or []
        shutil.copy2(work / 'out' / (job['id'] + '.mts'), output / (job['id'] + '.mts'))
        data = {'metadata': metadata, 'required_nodes': required_nodes}
        (output / (job['id'] + '.lua')).write_text(
            '-- Generated by tools/issue139_import/export_roman.py.\nreturn ' +
            lua(data) + '\n')
        # Each record names the snapshot it was captured from, so a selective
        # re-export never claims the top-level snapshot for its building.
        manifest['buildings'].append({**job, 'size': result['size'],
            'snapshot_sha256': snapshot_sha, 'source_map_sha256': source_sha,
            'non_air_node_types': len(required_nodes),
            'metadata_nodes': len(metadata),
            'required_nodes': required_nodes})
    if args.only:
        # Selective run: keep the top-level provenance and the other records.
        fresh = {b['id']: b for b in manifest['buildings']}
        known = {b['id'] for b in kept['buildings']}
        kept['buildings'] = [fresh.get(b['id'], b) for b in kept['buildings']]
        kept['buildings'] += [b for b in manifest['buildings'] if b['id'] not in known]
        manifest = kept
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'output': str(output),
                      ('record_snapshot_sha256' if args.only else 'snapshot_sha256'): snapshot_sha,
                      **({'kept_top_level_snapshot_sha256': manifest['snapshot_sha256']} if args.only else {}),
                      'buildings': len(results), 'metadata_nodes': sum(len(r.get('metadata') or []) for r in results)}, indent=2))


def lua(value):
    if isinstance(value, dict):
        return '{' + ','.join('[' + lua(k) + ']=' + lua(v) for k, v in value.items()) + '}'
    if isinstance(value, list):
        return '{' + ','.join(lua(v) for v in value) + '}'
    if isinstance(value, str):
        return '"' + ''.join('\\' + str(ord(c)).zfill(3) if ord(c) < 32 else '\\' + c if c in '\\"' else c for c in value) + '"'
    if isinstance(value, bool):
        return 'true' if value else 'false'
    if value is None:
        return 'nil'
    return str(value)


if __name__ == '__main__':
    main()
