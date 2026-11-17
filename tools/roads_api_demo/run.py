#!/usr/bin/env python3
"""Demonstrate the Roads integration API (#458) against automatically generated towns.

Creates a scratch world (copies only world.mt / map_meta.txt of a source world, plus a copy
of every mod that world.mt loads and a copy of this checkout as the mod `towns`), runs the
Luanti server headlessly with the scratch helper mod `roads_api_demo`, and lets the production
first-touch coordinator build towns. The helper lists settlements through towns_api, re-reads
every published exit with core.get_node and compares node name and param2, and runs a
Roads-like consumer that emerges fresh land and waits on towns_api.writer().

One scratch world per map seed; seeds are tried in order until a run has verified both a flat
and a sloped exit (or the list ends). Nothing in the source world, the installed mods or the
game is written. Results go to tools/roads_api_demo/results/ (one JSON per seed).

Exit status 0 only if every exit that was published matched the built nodes, at least one
settlement was published, and both a flat and a sloped exit were verified across the runs.
"""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HELPER = Path(__file__).resolve().parent
USER_DATA = Path.home() / 'Library/Application Support/minetest'
DEFAULT_SOURCE = USER_DATA / 'worlds/TownsWorkshop'


def copy_source_mods(source_world_mt, work):
    worldmods = work / 'worldmods'
    worldmods.mkdir(exist_ok=True)
    lines = []
    for line in source_world_mt.read_text().splitlines():
        m = re.match(r'^\s*load_mod_([^=\s]+)\s*=\s*(.+?)\s*$', line)
        if not m:
            lines.append(line)
            continue
        name, value = m.groups()
        if name == 'towns':
            raise SystemExit('the source world loads towns; refusing')
        src = Path(value) if Path(value).is_absolute() else USER_DATA / value
        if not (src / 'mod.conf').is_file():
            raise SystemExit('mod %s not found at %s' % (name, src))
        shutil.copytree(src, worldmods / name, ignore=shutil.ignore_patterns('.git', '__pycache__'))
        lines.append('load_mod_%s = worldmods/%s' % (name, name))
    return lines


def run_seed(args, map_seed):
    work = Path(tempfile.mkdtemp(prefix='towns-roads-demo-'))
    meta = (args.settings_from / 'map_meta.txt').read_text().splitlines()
    overrides = {'mg_name': 'v7', 'seed': str(map_seed)}
    overrides.update(dict(kv.split('=', 1) for kv in args.set_meta))
    for key, value in overrides.items():
        prefix = key + ' = '
        if any(line.startswith(prefix) for line in meta):
            meta = [prefix + value if line.startswith(prefix) else line for line in meta]
        else:
            meta.insert(0, prefix + value)
    (work / 'map_meta.txt').write_text('\n'.join(meta) + '\n')
    lines = copy_source_mods(args.settings_from / 'world.mt', work)
    mods = work / 'worldmods'
    towns = mods / 'towns'
    towns.mkdir()
    for name in ('init.lua', 'mod.conf'):
        shutil.copy2(ROOT / name, towns / name)
    for name in ('src', 'schematics'):
        shutil.copytree(ROOT / name, towns / name)
    helper = mods / 'roads_api_demo'
    helper.mkdir()
    for name in ('init.lua', 'mod.conf'):
        shutil.copy2(HELPER / name, helper / name)
    lines += ['load_mod_towns = worldmods/towns', 'load_mod_roads_api_demo = worldmods/roads_api_demo']
    (work / 'world.mt').write_text('\n'.join(lines) + '\n')
    (work / 'check.conf').write_text(
        'enable_ipv6 = false\nbind_address = 127.0.0.1\nserver_announce = false\n'
        'max_forceloaded_blocks = 4096\ntowns_auto_mode = on\n'
        'roads_demo_max_cells = %d\nroads_demo_cell_wait = %d\n' % (args.max_cells, args.cell_wait))
    print('Scratch world (map seed %s): %s' % (map_seed, work), flush=True)
    with (work / 'stdout.log').open('w') as log:
        try:
            subprocess.run(
                [args.engine, '--server', '--world', str(work), '--gameid', 'mineclone2',
                 '--config', str(work / 'check.conf'), '--port', str(args.port),
                 '--logfile', str(work / 'engine.log')],
                stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
        except subprocess.TimeoutExpired:
            print('engine timed out; the partial report is used')
    result = work / 'roads-api-demo.json'
    report = json.loads(result.read_text()) if result.exists() else None
    if report is not None:
        # core.write_json writes an empty Lua table as null.
        for key in ('settlements', 'cells', 'errors'):
            report[key] = report.get(key) or []
    if report is not None:
        out = HELPER / 'results'
        out.mkdir(exist_ok=True)
        (out / ('roads-api-demo-seed-%s.json' % map_seed)).write_text(json.dumps(report, indent=1, sort_keys=True))
        shutil.copy2(work / 'engine.log', out / ('engine-seed-%s.log' % map_seed))
    if report is not None and args.cleanup:
        shutil.rmtree(work)
    return report


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--map-seeds', default='2014,7777,31337', help='comma separated map seeds, tried in order')
    ap.add_argument('--max-cells', type=int, default=10, help='cells to emerge per world')
    ap.add_argument('--cell-wait', type=int, default=240, help='seconds to wait for Towns per cell')
    ap.add_argument('--engine', default='/Applications/luanti.app/Contents/MacOS/luanti')
    ap.add_argument('--port', type=int, default=39492)
    ap.add_argument('--settings-from', type=Path, default=DEFAULT_SOURCE)
    ap.add_argument('--set-meta', action='append', default=[], metavar='KEY=VALUE',
                    help='override a map_meta.txt key in the scratch copy (mg_name defaults to v7)')
    ap.add_argument('--timeout', type=int, default=3600)
    ap.add_argument('--cleanup', action='store_true')
    args = ap.parse_args()

    flat = sloped = mismatches = settlements = 0
    failed = False
    for seed in [s for s in args.map_seeds.split(',') if s]:
        report = run_seed(args, seed)
        if report is None:
            print('seed %s: no report written' % seed)
            failed = True
            continue
        print('seed %s: status=%s settlements=%d flat_verified=%d sloped_verified=%d mismatches=%s consumer=%s' % (
            seed, report.get('status'), len(report.get('settlements', [])), report.get('flat_verified', 0),
            report.get('sloped_verified', 0), report.get('mismatches'), json.dumps(report.get('consumer'))))
        for e in report.get('errors', []):
            print('  error:', e)
        flat += report.get('flat_verified', 0)
        sloped += report.get('sloped_verified', 0)
        mismatches += report.get('mismatches') or 0
        settlements += len(report.get('settlements', []))
        failed = failed or report.get('status') != 'pass' and bool(report.get('errors'))
        if flat and sloped:
            break
    ok = not failed and mismatches == 0 and settlements > 0 and flat > 0 and sloped > 0
    print('settlements=%d flat_verified=%d sloped_verified=%d mismatches=%d' % (settlements, flat, sloped, mismatches))
    print('PASS' if ok else 'FAIL')
    raise SystemExit(0 if ok else 1)


if __name__ == '__main__':
    main()
