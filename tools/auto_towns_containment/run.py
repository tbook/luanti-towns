#!/usr/bin/env python3
"""Write-capable containment test for automatic towns (#392, assumption A12).

Creates a scratch world (copies only world.mt / map_meta.txt of a source world, plus a
copy of every mod that world.mt loads and a copy of this checkout as the mod `towns`),
runs the Luanti server headlessly, builds real Towns through the public pipeline
(towns.populated.search / build) and diffs the region around each town before and after
against the #393 envelope (src/auto_bounds.lua). Nothing in the source world, the
installed mods or the game is written. The scratch world is kept (use --cleanup to remove
it when every sample is contained).

Exit status 0 only if every sample was evaluated and contained.
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
FAMILIES = ('medieval-walled', 'medieval-unwalled', 'roman')


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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--family', required=True, choices=FAMILIES)
    ap.add_argument('--count', type=int, default=3, help='samples (towns) built in this run')
    ap.add_argument('--first-index', type=int, default=1,
                    help='index of the first sample: it sets the site (a 4-column grid of --spacing) and the town seed (first-seed + index - 1)')
    ap.add_argument('--first-seed', type=int, default=1, help='town seed of sample index 1')
    ap.add_argument('--spacing', type=int, default=2500, help='nodes between sample sites (grid of 4 columns)')
    ap.add_argument('--engine', default='/Applications/luanti.app/Contents/MacOS/luanti')
    ap.add_argument('--port', type=int, default=39491)
    ap.add_argument('--settings-from', type=Path, default=DEFAULT_SOURCE)
    ap.add_argument('--map-seed', type=int, help='map seed written into the scratch map_meta.txt')
    ap.add_argument('--set-meta', action='append', default=[], metavar='KEY=VALUE',
                    help='override a map_meta.txt key in the scratch copy (e.g. mg_name=v7, mgflat_spflags=hills,nolakes,nocaverns)')
    ap.add_argument('--ring', type=int, default=80, help='nodes of snapshot beyond the envelope read box (all axes)')
    ap.add_argument('--timeout', type=int, default=3600)
    ap.add_argument('--control', type=int, default=0, metavar='SECONDS',
                    help='build nothing: snapshot, wait SECONDS, diff (ambient changes such as liquid reflow)')
    ap.add_argument('--settle', type=int, default=30, help='seconds to wait after the window is generated, before the first snapshot')
    ap.add_argument('--cleanup', action='store_true')
    args = ap.parse_args()

    work = Path(tempfile.mkdtemp(prefix='towns-containment-'))
    meta = (args.settings_from / 'map_meta.txt').read_text().splitlines()
    overrides = dict(kv.split('=', 1) for kv in args.set_meta)
    if args.map_seed is not None:
        overrides['seed'] = str(args.map_seed)
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
    helper = mods / 'auto_towns_containment'
    helper.mkdir()
    for name in ('init.lua', 'mod.conf'):
        shutil.copy2(HELPER / name, helper / name)
    lines += ['load_mod_towns = worldmods/towns', 'load_mod_auto_towns_containment = worldmods/auto_towns_containment']
    (work / 'world.mt').write_text('\n'.join(lines) + '\n')
    (work / 'check.conf').write_text(
        'enable_ipv6 = false\nbind_address = 127.0.0.1\nserver_announce = false\n'
        'max_forceloaded_blocks = 4096\n'
        'containment_family = %s\ncontainment_count = %d\ncontainment_first_seed = %d\ncontainment_first_index = %d\n'
        'containment_spacing = %d\ncontainment_ring = %d\ncontainment_control_seconds = %d\ncontainment_settle_seconds = %d\n'
        % (args.family, args.count, args.first_seed, args.first_index, args.spacing, args.ring, args.control, args.settle))
    print('Scratch world:', work, flush=True)
    with (work / 'stdout.log').open('w') as log:
        try:
            process = subprocess.run(
                [args.engine, '--server', '--world', str(work), '--gameid', 'mineclone2',
                 '--config', str(work / 'check.conf'), '--port', str(args.port),
                 '--logfile', str(work / 'engine.log')],
                stdout=log, stderr=subprocess.STDOUT, timeout=args.timeout)
        except subprocess.TimeoutExpired:
            print('engine timed out; partial samples are summarized below')
    samples = []
    for i in range(args.first_index, args.first_index + args.count):
        f = work / ('containment-sample-%d.json' % i)
        if f.exists():
            samples.append(json.loads(f.read_text()))
    rep = work / 'containment-summary.json'
    all_ok = len(samples) == args.count
    evaluated = 0
    print('family=%s samples_written=%d of %d' % (args.family, len(samples), args.count))
    for s in samples:
        e = s.get('envelope') or {}
        ch = s.get('changed') or {}
        out = s.get('outside') or {}
        print('  seed=%s status=%s build_ok=%s center=%s chunks=%s changed=%s outside_nonliquid_reflow=%s snapshot_s=%s diff_s=%s' % (
            s.get('seed'), s.get('status'), s.get('build_ok'), s.get('center'), e.get('chunks'),
            ch.get('nodes'), (out.get('non_liquid'), out.get('liquid_reflow')), s.get('snapshot_s'), s.get('diff_s')))
        if s.get('status') == 'control':
            c = s.get('control') or {}
            print('    control: %s changed nodes in %ss: %s' % (c.get('changed_nodes'), c.get('seconds'), c.get('transitions')))
            continue
        if s.get('status') == 'no_site':
            continue  # the production search found no acceptable site here: not an A12 sample
        evaluated += 1
        print('    stage_overrun_nodes=%s interval_outside_nodes=%s' % (s.get('stage_overrun_nodes'), s.get('interval_outside_nodes')))
        if s.get('status') != 'contained':
            all_ok = False
    rep.write_text(json.dumps({'family': args.family, 'args': vars(args) | {'settings_from': str(args.settings_from)},
                               'samples': samples}, indent=1, default=str))
    print('report:', rep)
    if args.control == 0 and evaluated == 0:
        all_ok = False
    print('evaluated=%d' % evaluated)
    print('PASS' if all_ok else 'FAIL')
    if all_ok and args.cleanup:
        shutil.rmtree(work)
    raise SystemExit(0 if all_ok else 1)


if __name__ == '__main__':
    main()
