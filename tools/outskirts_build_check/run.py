#!/usr/bin/env python3
"""Run a direct #236 outskirts apply probe in a disposable VoxeLibre world."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = Path.home() / 'Library/Application Support/minetest/worlds/TownsWorkshop'

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--engine', default='/Applications/luanti.app/Contents/MacOS/luanti')
    ap.add_argument('--settings-from', type=Path, default=DEFAULT_SOURCE)
    ap.add_argument('--town-type', choices=['medieval', 'roman'], default='medieval')
    ap.add_argument('--seed', type=int, default=5)
    ap.add_argument('--port', type=int, default=39492)
    args = ap.parse_args()
    world = Path(tempfile.mkdtemp(prefix='towns-outskirts-'))
    for name in ('world.mt', 'map_meta.txt'):
        shutil.copy2(args.settings_from / name, world / name)
    mods = world / 'worldmods'; mods.mkdir()
    towns = mods / 'towns'; towns.mkdir()
    for name in ('init.lua', 'mod.conf'): shutil.copy2(ROOT / name, towns / name)
    for name in ('src', 'schematics'): shutil.copytree(ROOT / name, towns / name)
    check = mods / 'outskirts_build_check'; check.mkdir()
    shutil.copy2(Path(__file__).with_name('init.lua'), check / 'init.lua')
    (check / 'mod.conf').write_text('name = outskirts_build_check\ndepends = towns, living_villages\n')
    with (world / 'world.mt').open('a') as f:
        f.write('\nload_mod_towns = worldmods/towns\nload_mod_outskirts_build_check = worldmods/outskirts_build_check\n')
    (world / 'check.conf').write_text(
        'enable_ipv6 = false\nbind_address = 127.0.0.1\nserver_announce = false\n'
        'outskirts_check_seed = %d\noutskirts_check_town_type = %s\n' % (args.seed, args.town_type))
    proc = subprocess.run([args.engine, '--server', '--world', str(world), '--gameid', 'mineclone2',
                           '--config', str(world / 'check.conf'), '--port', str(args.port),
                           '--logfile', str(world / 'engine.log')], capture_output=True, text=True, timeout=900)
    path = world / 'outskirts-check.json'
    if not path.exists(): raise SystemExit('No engine report; inspect ' + str(world / 'engine.log'))
    report = json.loads(path.read_text())
    print(json.dumps(report, indent=2))
    if not report.get('ok'): raise SystemExit('Outskirts engine probe failed; inspect ' + str(world / 'engine.log'))

if __name__ == '__main__': main()
