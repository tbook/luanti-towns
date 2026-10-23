#!/usr/bin/env python3
"""Check the outdoor objects in an isolated VoxeLibre world."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--engine', default='/Applications/luanti.app/Contents/MacOS/luanti')
    args = ap.parse_args()
    world = Path(tempfile.mkdtemp(prefix='towns-objects-'))
    mods = world / 'worldmods'
    target = mods / 'towns'
    target.mkdir(parents=True)
    for name in ('init.lua', 'mod.conf'):
        shutil.copy2(ROOT / name, target / name)
    for name in ('src', 'schematics'):
        shutil.copytree(ROOT / name, target / name)
    helper = mods / 'towns_object_check'
    helper.mkdir()
    (helper / 'mod.conf').write_text('name = towns_object_check\ndepends = towns\n')
    shutil.copy2(Path(__file__).with_name('check.lua'), helper / 'init.lua')
    (world / 'world.mt').write_text(
        'gameid = mineclone2\nbackend = sqlite3\nplayer_backend = sqlite3\n'
        'auth_backend = sqlite3\nmod_storage_backend = sqlite3\n'
        'load_mod_towns = worldmods/towns\n'
        'load_mod_towns_object_check = worldmods/towns_object_check\n'
        'load_mod_living_villages = mods/living_villages\n'
        'load_mod_mcl_decor = mods/mcl_decor\n')
    (world / 'map_meta.txt').write_text(
        'mg_name = flat\nmgflat_ground_level = 8\n'
        'mgflat_spflags = nolakes, nohills, nocaverns\n'
        'mcl_superflat_classic = true\nmg_flags = nocaves, nodungeons, light, nodecorations, biomes, ores\n'
        'seed = 204\nmapgen_limit = 31007\n[end_of_params]\n')
    (world / 'check.conf').write_text(
        'enable_ipv6 = false\nbind_address = 127.0.0.1\nserver_announce = false\n'
        'creative_mode = true\nenable_damage = false\n')
    print('Scratch world:', world, flush=True)
    proc = subprocess.run(
        [args.engine, '--server', '--world', str(world), '--gameid', 'mineclone2',
         '--config', str(world / 'check.conf'), '--port', '39491',
         '--logfile', str(world / 'engine.log')],
        capture_output=True, text=True, timeout=120)
    report = world / 'object-check.txt'
    if proc.returncode != 0 or not report.exists():
        print(proc.stdout[-6000:])
        print(proc.stderr[-6000:])
        raise SystemExit(f'Object check failed; inspect {world / "engine.log"}')
    print(report.read_text(), end='')


if __name__ == '__main__':
    main()
