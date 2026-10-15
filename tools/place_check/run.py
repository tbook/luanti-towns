#!/usr/bin/env python3
"""Disposable-world check for town schematic placement (#45) and node setup (#46).

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


def manual_bed_counts(report):
    """Complete-pair bed counts per template path, read straight from the
    template .mts files with tests/mts_reader.lua (plain Lua, no engine)."""
    rows = report.get('beds', {}).get('per_structure')
    if not rows:
        return None
    paths = sorted({r['path'] for r in rows})
    script = '''
local read = dofile("tests/mts_reader.lua")
local DIR = {[0]={0,1},[1]={1,0},[2]={0,-1},[3]={-1,0}}
for path in ("%s"):gmatch("[^,]+") do
  do
    local s = read(path)
    local n = 0
    for z = 0, s.size.z - 1 do for y = 0, s.size.y - 1 do for x = 0, s.size.x - 1 do
      local name, p2 = s.at(x, y, z)
      if name:find("^mcl_beds:.*_bottom$") then
        local d = DIR[p2 %% 4]
        local tx, tz = x + d[1], z + d[2]
        if tx >= 0 and tx < s.size.x and tz >= 0 and tz < s.size.z then
          local n2, q = s.at(tx, y, tz)
          if n2 == name:gsub("_bottom$", "_top") and q == p2 then n = n + 1 end
        end
      end
    end end end
    print(path, n)
  end
end
''' % ','.join(paths)
    out = subprocess.run(['lua5.1', '-e', script], cwd=ROOT, capture_output=True, text=True)
    if out.returncode != 0:
        print('manual bed count failed:', out.stderr)
        return None
    return {line.split()[0]: int(line.split()[1]) for line in out.stdout.splitlines() if line.strip()}


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--engine', default='/Applications/luanti.app/Contents/MacOS/luanti')
    ap.add_argument('--port', type=int, default=39489)
    ap.add_argument('--seed', type=int, default=5)
    ap.add_argument('--settings-from', type=Path, default=DEFAULT_SOURCE,
                    help='world whose world.mt / map_meta.txt (game, mods, flat mapgen) are copied; its map is NOT used')
    ap.add_argument('--timeout', type=int, default=900)
    ap.add_argument('--scenario', default='', choices=['', 'water', 'buried'],
                    help="'water': buried pockets, a hill, ponds in and beside the footprint (ticket #104)")
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
        'towns_place_check_seed = %d\n'
        'towns_place_check_scenario = %s\n' % (args.seed, args.scenario))
    print('Scratch world:', work, flush=True)
    def run_engine(tag):
        with (work / ('stdout-%s.log' % tag)).open('w') as log:
            return subprocess.run(
                [args.engine, '--server', '--world', str(work), '--gameid', 'mineclone2',
                 '--config', str(work / 'check.conf'), '--port', str(args.port),
                 '--logfile', str(work / ('engine-%s.log' % tag))],
                stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)

    process = run_engine('phase1')
    report_file = work / 'place-check.json'
    if not report_file.exists():
        raise SystemExit('No report written (engine exit %s); inspect %s' % (process.returncode, work / 'engine-phase1.log'))
    report = json.loads(report_file.read_text())
    print(json.dumps({k: v for k, v in report.items() if k != 'checks'}, indent=2))
    manual = manual_bed_counts(report)
    if manual is not None:
        print('Bed counts per building (valid/skipped/schematic, manual from .mts via tests/mts_reader.lua):')
        agree = True
        for row in report.get('beds', {}).get('per_structure', []):
            m = manual.get(row['path'])
            ok = m == row['schematic_beds']
            agree = agree and ok
            print('  %-18s %3d valid %2d skipped  schematic %2d  manual %s %s' % (
                row['id'], row['valid'], row['skipped'], row['schematic_beds'], m, 'ok' if ok else 'MISMATCH'))
        if not agree:
            report['ok'] = False
            print('FAIL manual .mts bed counts disagree with the engine report')
    for c in report['checks']:
        print('PASS' if c['ok'] else 'FAIL', c['label'])
    if report.get('ok'):
        # Phase 2 (#48): a fresh server process on the same world and mod
        # storage must not spawn any additional resident.
        with (work / 'check.conf').open('a') as f:
            f.write('towns_place_check_phase = 2\nmax_forceloaded_blocks = 4096\n')
        run_engine('phase2')
        restart_file = work / 'place-check-restart.json'
        if not restart_file.exists():
            print('FAIL restart phase wrote no report; inspect', work / 'engine-phase2.log')
            report['ok'] = False
        else:
            restart = json.loads(restart_file.read_text())
            print('Restart phase:', json.dumps(restart.get('restart')))
            for c in restart['checks']:
                print('PASS' if c['ok'] else 'FAIL', c['label'])
            report['ok'] = bool(restart.get('ok'))
    if not args.keep and report.get('ok'):
        shutil.rmtree(work, ignore_errors=True)
    raise SystemExit(0 if report.get('ok') else 1)


if __name__ == '__main__':
    main()
