#!/usr/bin/env python3
"""Disposable-world check for town schematic placement (ticket #45).

Creates a scratch superflat world (never touching any real world), installs
this checkout as a world mod, runs the Luanti server headlessly, searches for
a site, builds a town with real schematics and alleys, re-reads the world and
writes place-check.json. Exit status 0 means every check passed.
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
    ap.add_argument('--port', type=int, default=39489)
    ap.add_argument('--seed', type=int, default=6)
    ap.add_argument('--settings-from', type=Path, default=DEFAULT_SOURCE,
                    help='world whose world.mt / map_meta.txt (game, mods, flat mapgen) are copied; its map is NOT used')
    ap.add_argument('--timeout', type=int, default=900)
    ap.add_argument('--keep', action='store_true', help='print the scratch world path and keep it')
    args = ap.parse_args()

    work = Path(tempfile.mkdtemp(prefix='towns-place-check-'))
    for name in ('world.mt', 'map_meta.txt'):
        shutil.copy2(args.settings_from / name, work / name)
    mods = work / 'worldmods'
    mods.mkdir()
    towns = mods / 'towns'
    towns.mkdir()
    for name in ('init.lua', 'mod.conf'):
        shutil.copy2(ROOT / name, towns / name)
    for name in ('src', 'schematics'):
        shutil.copytree(ROOT / name, towns / name)
    helper = mods / 'towns_place_check'
    helper.mkdir()
    shutil.copy2(HELPER / 'init.lua', helper / 'init.lua')
    (helper / 'mod.conf').write_text('name = towns_place_check\ndepends = towns\n')
    with (work / 'world.mt').open('a') as f:
        f.write('\nload_mod_towns = worldmods/towns\nload_mod_towns_place_check = worldmods/towns_place_check\n')
    (work / 'check.conf').write_text(
        'enable_ipv6 = false\nbind_address = 127.0.0.1\nserver_announce = false\n'
        'towns_enable_place_town = true\ntowns_place_check_seed = %d\n' % args.seed)
    print('Scratch world:', work, flush=True)
    with (work / 'stdout.log').open('w') as log:
        process = subprocess.run(
            [args.engine, '--server', '--world', str(work), '--gameid', 'mineclone2',
             '--config', str(work / 'check.conf'), '--port', str(args.port),
             '--logfile', str(work / 'engine.log')],
            stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
    report_file = work / 'place-check.json'
    if not report_file.exists():
        raise SystemExit('No report written (engine exit %s); inspect %s' % (process.returncode, work / 'engine.log'))
    report = json.loads(report_file.read_text())
    print(json.dumps({k: v for k, v in report.items() if k != 'checks'}, indent=2))
    for c in report['checks']:
        print('PASS' if c['ok'] else 'FAIL', c['label'])
    if not args.keep and report.get('ok'):
        shutil.rmtree(work, ignore_errors=True)
    raise SystemExit(0 if report.get('ok') else 1)


if __name__ == '__main__':
    main()
