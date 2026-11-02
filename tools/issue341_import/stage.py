#!/usr/bin/env python3
"""Stage the Issue 341 buildings on a disposable copy of TownsWorkshop."""
import argparse
import json
from pathlib import Path
import shutil
import sqlite3

from common import ENGINE, HERE, WORLDS, copy_world, install_helper, integrity_ok, run_server, sha256, world_is_open

BLOCK_SIZE = 16
HELPER = 'issue341_import'


def read_blocks(path):
    with sqlite3.connect(Path(path).as_uri() + '?mode=ro', uri=True) as db:
        return {(x, y, z): bytes(d) for x, y, z, d in db.execute('select x, y, z, data from blocks')}


def block_range(lo, hi):
    return [range(lo[i] // BLOCK_SIZE, hi[i] // BLOCK_SIZE + 1) for i in range(3)]


def remove_helper(stage):
    shutil.rmtree(stage / 'worldmods' / HELPER)
    lines = [l for l in (stage / 'world.mt').read_text().splitlines() if HELPER not in l]
    (stage / 'world.mt').write_text('\n'.join(lines) + '\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--world', type=Path, default=WORLDS / 'TownsWorkshop')
    ap.add_argument('--captures', type=Path, required=True, help='Output directory of prepare.py')
    ap.add_argument('--engine', default=ENGINE)
    ap.add_argument('--port', type=int, default=39497)
    ap.add_argument('--buildings', type=Path, default=HERE / 'buildings.json')
    ap.add_argument('--output', type=Path, required=True)
    ap.add_argument('--allow-open', action='store_true',
                    help='Dry run against a world that is open in the game. The stage is marked '
                         'provisional and apply.py refuses it.')
    args = ap.parse_args()
    world = args.world
    is_open = world_is_open(world)
    if is_open and not args.allow_open:
        raise SystemExit('TownsWorkshop is open; return to the menu before staging (or pass --allow-open for a dry run).')
    if args.output.exists():
        raise SystemExit('Staging directory already exists: ' + str(args.output))
    jobs = json.loads(args.buildings.read_text())
    captures = {r['id']: r for r in json.loads((args.captures / 'captures.json').read_text())}
    source_sha = copy_world(world, args.output)
    if source_sha is None:
        raise SystemExit('TownsWorkshop map changed while it was being copied; close the game and retry.')
    (args.output / 'source-map.sha256').write_text(source_sha + '\n')
    (args.output / 'schems').mkdir()
    for j in jobs:
        record = captures[j['id']]
        j['schematic'] = 'issue341_' + j['id'] + '.mts'
        j['capture_size'] = record['size']
        j['source_min'], j['source_max'] = record['min'], record['max']
        j['metadata'] = record.get('metadata') or []
        src = args.captures / (j['id'] + '.mts')
        j['source_sha256'] = sha256(src)
        shutil.copy2(src, args.output / 'schems' / j['schematic'])
        sidecar = dict(record, source=j['source'], target_origin=j['origin'])
        (args.output / 'schems' / ('issue341_' + j['id'] + '.json')).write_text(json.dumps(sidecar, indent=2) + '\n')
    for mode, name in (('place', 'issue341-place.json'), ('verify', 'issue341-verify.json')):
        if mode == 'verify':
            remove_helper(args.output)
        (args.output / 'issue341-job.json').write_text(json.dumps({'mode': mode, 'buildings': jobs}))
        install_helper(args.output, HELPER, HERE / 'place.lua')
        rc = run_server(args.output, args.port, args.engine)
        report_path = args.output / name
        if not report_path.exists():
            raise SystemExit('%s pass failed; inspect %s' % (mode, args.output / 'engine.log'))
        report = json.loads(report_path.read_text())
        if report.get('unavailable'):
            raise SystemExit('Nodes unavailable in this game (not substituted): ' + json.dumps(report['unavailable']))
        if rc or report['failures']:
            raise SystemExit('%s pass failed:\n  %s' % (mode, '\n  '.join(report['failures'] or ['engine exit %d' % rc])))
        (args.output / ('stdout-%s.log' % mode)).write_text((args.output / 'stdout.log').read_text())
    # Remove the helper so only the map and notes are applied.
    remove_helper(args.output)
    if not integrity_ok(args.output / 'map.sqlite'):
        raise SystemExit('Staged map database failed its integrity check')
    place = json.loads((args.output / 'issue341-place.json').read_text())
    verify = json.loads((args.output / 'issue341-verify.json').read_text())

    # Independent database-level check: which mapblocks differ from the source?
    src_blocks, new_blocks = read_blocks(world / 'map.sqlite'), read_blocks(args.output / 'map.sqlite')
    region = place['region']
    lo, hi = tuple(region['min'][k] for k in 'xyz'), tuple(region['max'][k] for k in 'xyz')
    # Lighting updates also rewrite the mapblocks touching the loaded region (the tall
    # hippodrome shades the block above it), so allow one block of margin on each side;
    # the in-engine hash covers the node content of the whole region itself.
    ranges = block_range(tuple(v - BLOCK_SIZE for v in lo), tuple(v + BLOCK_SIZE for v in hi))
    allowed = {(x, y, z) for x in ranges[0] for y in ranges[1] for z in ranges[2]}
    changed = sorted(k for k in new_blocks if k in src_blocks and new_blocks[k] != src_blocks[k])
    added = sorted(k for k in new_blocks if k not in src_blocks)
    removed = sorted(k for k in src_blocks if k not in new_blocks)
    stray_changed = [k for k in changed if k not in allowed]
    db_check = {'changed_blocks': len(changed), 'added_blocks': len(added), 'removed_blocks': len(removed),
                'changed_outside_loaded_region': stray_changed,
                'added_outside_loaded_region': [k for k in added if k not in allowed]}
    if removed or stray_changed:
        raise SystemExit('Unexpected mapblock changes: ' + json.dumps(db_check))
    (args.output / 'stage-map.sha256').write_text(sha256(args.output / 'map.sqlite') + '\n')

    records = verify['buildings']
    summary = {'provisional': is_open, 'buildings': len(records),
               'place_failures': len(place['failures'] or []), 'verify_failures': len(verify['failures'] or []),
               'cells': sum(b['cells'] for b in records),
               'non_air_nodes': sum(b['non_air_nodes'] for b in records),
               'node_mismatches': sum(b['node_mismatches'] for b in records),
               'substituted_nodes': sum(b['substituted_nodes'] for b in records),
               'metadata_nodes': sum(b['metadata_nodes'] for b in records),
               'inventory_mismatches': sum(b['inventory_mismatches'] for b in records),
               'outside_cells_compared': place['outside_cells'],
               'outside_unchanged_place_pass': place['outside_hash_before'] == place['outside_hash_after'],
               'outside_unchanged_reloaded_pass': place['outside_hash_before'] == verify['outside_hash_after'],
               'database': db_check, 'source_map_sha256': source_sha, 'records': records}
    (args.output / 'issue341-validation.json').write_text(json.dumps(summary, indent=2) + '\n')
    if is_open:
        (args.output / 'PROVISIONAL').write_text('Staged while the world was open in the game; do not apply. Re-run stage.py after closing it.\n')

    lines = ['# Issue 341 Roman buildings imported into TownsWorkshop', '',
             'Captured from the saved Creative map. Regions use inclusive bounds, are placed unrotated, and keep the source terrain rows (no pad was added). Editing and export into the Roman catalog follow.', '',
             '| Building | Source bounds (inclusive) | Workshop minimum | Workshop maximum | Teleport |',
             '| --- | --- | --- | --- | --- |']
    for j, r in zip(jobs, records):
        o, s = r['origin'], r['size']
        a, b = j['source_min'], j['source_max']
        lines.append('| %s | (%d, %d, %d)-(%d, %d, %d) | (%d, %d, %d) | (%d, %d, %d) | (%d, 10, %d) |' % (
            j['id'], a['x'], a['y'], a['z'], b['x'], b['y'], b['z'], o['x'], o['y'], o['z'],
            o['x'] + s['x'] - 1, o['y'] + s['y'] - 1, o['z'] + s['z'] - 1, o['x'] + s['x'] // 2, o['z'] - 5))
    lines += ['', 'Schematics are copied to `schems/issue341_*.mts` for WorldEdit. Verified %d non-air nodes (names and param2) and metadata restored on %d nodes by reloading the staged map; %d nodes were mapped to substitutes; no other existing node was changed.' % (summary['non_air_nodes'], summary['metadata_nodes'], summary['substituted_nodes'])]
    (args.output / 'issue341-import.md').write_text('\n'.join(lines) + '\n')
    print(json.dumps({k: v for k, v in summary.items() if k != 'records'}, indent=2))
    print('Staged workshop:', args.output, '(PROVISIONAL)' if is_open else '')


if __name__ == '__main__':
    main()
