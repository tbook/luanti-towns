#!/usr/bin/env python3
"""Real-engine benchmark of site inspection (issue #186).

Creates a scratch superflat world (only world.mt / map_meta.txt are copied;
no existing map is read or written), installs this checkout as a world mod,
runs the Luanti server headlessly and prints one row per search with planning,
emergence and inspection time kept separate, plus engine call counts.
The raw report stays in the scratch world as site-bench.json (printed path).
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HELPER = Path(__file__).resolve().parent
DEFAULT_SOURCE = Path.home() / 'Library/Application Support/minetest/worlds/TownsWorkshop'


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--engine', default='/Applications/luanti.app/Contents/MacOS/luanti')
    ap.add_argument('--port', type=int, default=39493)
    ap.add_argument('--reps', type=int, default=3)
    ap.add_argument('--settings-from', type=Path, default=DEFAULT_SOURCE)
    ap.add_argument('--timeout', type=int, default=1800)
    ap.add_argument('--json', type=Path, help='also copy the raw report here')
    args = ap.parse_args()

    work = Path(tempfile.mkdtemp(prefix='towns-site-bench-'))
    for name in ('world.mt', 'map_meta.txt'):
        shutil.copy2(args.settings_from / name, work / name)
    mods = work / 'worldmods'
    towns = mods / 'towns'
    towns.mkdir(parents=True)
    for name in ('init.lua', 'mod.conf'):
        shutil.copy2(ROOT / name, towns / name)
    for name in ('src', 'schematics'):
        shutil.copytree(ROOT / name, towns / name)
    helper = mods / 'towns_site_bench'
    helper.mkdir()
    shutil.copy2(HELPER / 'init.lua', helper / 'init.lua')
    (helper / 'mod.conf').write_text('name = towns_site_bench\ndepends = towns\n')
    with (work / 'world.mt').open('a') as f:
        f.write('\nload_mod_towns = worldmods/towns\nload_mod_towns_site_bench = worldmods/towns_site_bench\n')
    (work / 'check.conf').write_text(
        'enable_ipv6 = false\nbind_address = 127.0.0.1\nserver_announce = false\n'
        'towns_site_bench_reps = %d\n' % args.reps)
    print('Scratch world:', work, flush=True)
    with (work / 'stdout.log').open('w') as log:
        subprocess.run(
            [args.engine, '--server', '--world', str(work), '--gameid', 'mineclone2',
             '--config', str(work / 'check.conf'), '--port', str(args.port),
             '--logfile', str(work / 'engine.log')],
            stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
    report_file = work / 'site-bench.json'
    if not report_file.exists():
        raise SystemExit('No report written; inspect %s' % (work / 'engine.log'))
    report = json.loads(report_file.read_text())
    if args.json:
        shutil.copy2(report_file, args.json)
    if report.get('error'):
        print('ERROR:', report['error'])
    print('footprints:', json.dumps(report.get('footprints')))
    hdr = '%-20s %-8s %-3s %9s %9s %9s %9s %5s %10s %4s %11s  %s'
    print(hdr % ('run', 'town', 'ok', 'total_ms', 'plan_ms', 'emerge_ms', 'inspect_ms',
                 'insp', 'get_node', 'vm', 'vm_nodes', 'outcome'))
    for r in report['runs']:
        outcome = ('cols %s ground %s wet %s' % (r.get('columns'), r.get('ground_y'), r.get('wet_columns'))
                   if r['accepted'] else json.dumps(r.get('rejections')))
        print('%-20s %-8s %-3s %9.0f %9.0f %9.0f %9.0f %5d %10d %4d %11d  %s' % (
            r['fixture'], r['town'], 'Y' if r['accepted'] else 'N', r['total_ms'], r['planning_ms'],
            r['emerge_ms'], r['inspect_ms'], r['inspections'], r['get_node_calls'],
            r['voxelmanip_reads'], r['voxelmanip_nodes_requested'], outcome))
    print('bulk-read probe (flat fixture, same volume and column scan done from one VoxelManip):')
    for r in report.get('probe', []):
        print('  ' + json.dumps(r))
    print('Report:', report_file)
    raise SystemExit(1 if report.get('error') else 0)


if __name__ == '__main__':
    main()
