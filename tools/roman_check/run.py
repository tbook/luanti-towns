#!/usr/bin/env python3
"""Verify the six Roman catalog captures in a new disposable Luanti world.

Only world settings are copied; no existing map is read or changed.
The scratch world and JSON report are retained for inspection.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engine', default='/Applications/luanti.app/Contents/MacOS/luanti')
    parser.add_argument('--settings-from', type=Path, default=Path.home() /
                        'Library/Application Support/minetest/worlds/TownsWorkshop')
    parser.add_argument('--port', type=int, default=39491)
    args = parser.parse_args()
    world = Path(tempfile.mkdtemp(prefix='towns-roman-check-'))
    for name in ('world.mt', 'map_meta.txt'):
        shutil.copy2(args.settings_from / name, world / name)
    towns = world / 'worldmods/towns'
    towns.mkdir(parents=True)
    for name in ('init.lua', 'mod.conf'):
        shutil.copy2(ROOT / name, towns / name)
    for name in ('src', 'schematics'):
        shutil.copytree(ROOT / name, towns / name)
    helper = world / 'worldmods/roman_check'
    helper.mkdir()
    shutil.copy2(Path(__file__).with_name('init.lua'), helper / 'init.lua')
    (helper / 'mod.conf').write_text('name = roman_check\ndepends = towns\n')
    with (world / 'world.mt').open('a') as stream:
        stream.write('\nload_mod_towns = worldmods/towns\nload_mod_roman_check = worldmods/roman_check\n')
    (world / 'check.conf').write_text(
        'enable_ipv6 = false\nbind_address = 127.0.0.1\nserver_announce = false\n')
    print('Scratch world:', world, flush=True)
    result = subprocess.run([
        args.engine, '--server', '--world', str(world), '--gameid', 'mineclone2',
        '--config', str(world / 'check.conf'), '--port', str(args.port),
        '--logfile', str(world / 'engine.log')], capture_output=True, text=True, timeout=240)
    report_path = world / 'roman-check.json'
    if result.returncode or not report_path.exists():
        print(result.stdout[-4000:])
        print(result.stderr[-4000:])
        raise SystemExit('Check failed; inspect ' + str(world / 'engine.log'))
    report = json.loads(report_path.read_text())
    print(json.dumps({k: v for k, v in report.items() if k != 'placements'}, indent=2))
    for row in report['placements'] or []:
        print(row['id'], row['rotation'], 'entrance', row['entrance'],
              'beds', row['beds'], 'skipped', len(row['skipped_beds'] or []))
    print('Report:', report_path)
    raise SystemExit(0 if report['ok'] else 1)


if __name__ == '__main__':
    main()
