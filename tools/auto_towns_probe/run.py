#!/usr/bin/env python3
"""Disposable-world frontier and freshness probe for automatic towns (#391, slice 0).

Copies only the settings (world.mt, map_meta.txt) of a source world into a
scratch world, installs init.lua from this folder as a scratch-only observer
mod, and runs the Luanti server headlessly. Nothing is written to the source
world or to any installed mod. Towns is not loaded in the scratch world.

Each scenario runs one or two server phases on the same scratch world. Each
phase writes auto-towns-probe-phaseN.json and .jsonl with one event per line
(ids "p<phase>-<seq>"). This script then checks the scenario's expectations
and writes probe-report.json. Exit status 0 means every check passed.

Scripted fixture boxes are explicit, bounded emerge requests. They are a proxy
for load, not evidence of actual player request latency.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HELPER = Path(__file__).resolve().parent
DEFAULT_SOURCE = Path.home() / 'Library/Application Support/minetest/worlds/TownsWorkshop'
DEFAULT_ENGINE = '/Applications/luanti.app/Contents/MacOS/luanti'
DEFAULT_LV = Path.home() / 'Library/Application Support/minetest/mods/living_villages'
DEFAULT_GAME = Path.home() / 'Library/Application Support/minetest/games/mineclone2'

# Fixture boxes are inclusive node boxes "id:x1,y1,z1,x2,y2,z2"; one entry per phase.
# Phases are separated by "|" inside a scenario, and boxes by ";".
SCENARIOS = {
    # One phase of surface boxes around the origin.
    'fresh': {
        'phases': ['fresh-surface:-40,0,-40,39,47,39'],
        'duration': 60,
        'about': 'fresh world: fixture boxes generate new chunks',
    },
    # Sky-high and underground boxes over the same columns; classes come from the mapgen VoxelManip.
    'sky-underground': {
        'phases': ['sky-high:-40,80,-40,39,127,39;deep:-40,-80,-40,39,-17,39'],
        'duration': 60,
        'about': 'sky and underground chunks generated before any surface chunk',
    },
    # Three overlapping boxes issued in the same tick.
    'concurrent': {
        'phases': ['ov-a:-40,0,-40,39,47,39;ov-b:0,0,0,79,47,79;ov-c:-80,0,-80,-1,47,-1'],
        'duration': 60,
        'about': 'concurrent overlapping requests from one tick',
    },
    # Phase 1 generates a box; phase 2 (same world, new process) overlaps it.
    'old-neighbor': {
        'phases': ['old:-40,0,-40,39,47,39',
                   'neighbor:0,0,-40,119,47,39'],
        'duration': 60,
        'about': 'a new request next to chunks generated and saved in an earlier process',
    },
    # Phase 2 repeats phase 1 exactly: nothing may be generated again.
    'restart': {
        'phases': ['restart:-40,0,-40,39,47,39',
                   'restart:-40,0,-40,39,47,39'],
        'duration': 60,
        'about': 'restart in a fresh process must not regenerate saved chunks',
    },
    # The largest single-phase area (1024 mapblocks). VoxeLibre places its village
    # structblock at a chunk's minimum corner, y = -32 for the chunk layer that holds
    # the ground here, so the fixture is the one block layer -32..-17 that contains it.
    # Fixture blocks are forceloaded after they complete so the structblock LBM runs
    # without a player. The seed gate (blockseed % 77 == 17) fires for about 1 in 77
    # chunks. Zero village outcomes is reported as absent, not as a pass.
    'villages': {
        'phases': ['village-area:-256,-32,-256,255,-17,255'],
        'duration': 180,
        'forceload': True,
        'about': 'forceloaded area to observe natural village opportunities (not guaranteed to fire)',
    },
}


def parse_route(path):
    """Validate a walking or flying route before handing it to the scratch world."""
    route = json.loads(Path(path).read_text())
    if route.get('mode') not in ('walk', 'fly'):
        raise SystemExit('route mode must be "walk" or "fly"')
    speed = route.get('speed')
    if not isinstance(speed, (int, float)) or not 0 < speed <= 30:
        raise SystemExit('route speed (nodes per second) must be in (0, 30]')
    points = route.get('points')
    if not isinstance(points, list) or not 2 <= len(points) <= 200:
        raise SystemExit('route needs 2 to 200 [x, y, z] points')
    for p in points:
        if not (isinstance(p, list) and len(p) == 3 and all(isinstance(v, (int, float)) for v in p)):
            raise SystemExit('each route point must be [x, y, z] numbers')
    return route


def count_blocks(fixture_text):
    """Mapblocks requested by a fixture string (mirrors the Lua cap of 1024)."""
    total = 0
    for item in fixture_text.split(';'):
        if not item.strip():
            continue
        _, rest = item.split(':', 1)
        v = [int(n) for n in rest.split(',')]
        blocks = 1
        for a, b in ((v[0], v[3]), (v[1], v[4]), (v[2], v[5])):
            blocks *= (max(a, b) // 16) - (min(a, b) // 16) + 1
        total += blocks
    return total


def read_events(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def git_rev(path):
    if not path or not (Path(path) / '.git').exists():
        return None
    out = subprocess.run(['git', '-C', str(path), 'rev-parse', '--short', 'HEAD'],
                         capture_output=True, text=True)
    return out.stdout.strip() or None


def engine_version(engine):
    out = subprocess.run([engine, '--version'], capture_output=True, text=True)
    return (out.stdout or out.stderr).strip().splitlines()[:1] or None


def scenario_checks(name, phases, events):
    """Scenario expectations, computed from the events of each phase.

    phases: list of (phase number, report dict). events: phase number -> list.
    Returns (label, ok) pairs. Only fixture requests (source "fixture") count.
    """
    out = []

    def blocks(n, actions=None):
        return {(e['block']['x'], e['block']['y'], e['block']['z']) for e in events[n]
                if e.get('kind') == 'emerge_block' and e.get('source') == 'fixture'
                and (actions is None or e.get('action') in actions)}

    def generated_chunks(n):
        return [e for e in events[n] if e.get('kind') == 'generated']

    first = phases[0][0]
    if name == 'fresh':
        out.append(('fresh: fixture generated new chunks', len(blocks(first, ('generated',))) > 0))
    elif name == 'sky-underground':
        classes = {e.get('class') for e in generated_chunks(first)}
        out.append(('sky-underground: sky chunks recorded', 'sky' in classes))
        out.append(('sky-underground: underground chunks recorded', 'underground' in classes))
    elif name == 'concurrent':
        minps = [json.dumps(e['minp'], sort_keys=True) for e in generated_chunks(first)]
        out.append(('concurrent: no chunk generated twice in one phase', len(minps) == len(set(minps))))
    elif name == 'old-neighbor' and len(phases) == 2:
        second = phases[1][0]
        old = blocks(first)
        new_generated = blocks(second, ('generated',))
        out.append(('old-neighbor: no saved block generated again', not (new_generated & old)))
        out.append(('old-neighbor: saved blocks reloaded from disk or memory',
                    bool(blocks(second, ('from_disk', 'from_memory')) & old)))
        out.append(('old-neighbor: neighbor generated new blocks', len(new_generated) > 0))
    elif name == 'restart' and len(phases) == 2:
        second = phases[1][0]
        out.append(('restart: no block generated again after restart', len(blocks(second, ('generated',))) == 0))
        out.append(('restart: fixture blocks reloaded after restart', len(blocks(second)) > 0))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--scenario', default='fresh', choices=sorted(SCENARIOS),
                    help='; '.join('%s: %s' % (k, v['about']) for k, v in SCENARIOS.items()))
    ap.add_argument('--engine', default=DEFAULT_ENGINE)
    ap.add_argument('--port', type=int, default=39490, help='server port (place_check uses 39489)')
    ap.add_argument('--seed', type=int, help='map seed written into the scratch map_meta.txt (default: source seed)')
    ap.add_argument('--mg-name', help='mapgen written into the scratch map_meta.txt, e.g. v7 (default: source, flat)')
    ap.add_argument('--settings-from', type=Path, default=DEFAULT_SOURCE,
                    help='world whose world.mt / map_meta.txt are copied; its map is NOT used')
    ap.add_argument('--duration', type=int, help='seconds per phase (default depends on scenario)')
    ap.add_argument('--start-delay', type=int, default=2, help='seconds before fixture requests are issued')
    ap.add_argument('--fixture', help='override the scenario fixture boxes, "id:x1,y1,z1,x2,y2,z2;..." (one phase)')
    ap.add_argument('--route', type=Path,
                    help='walk or fly route JSON {"mode","speed","points"} for one connected client (see README)')
    ap.add_argument('--timeout', type=int, default=900, help='per-phase engine timeout in seconds')
    ap.add_argument('--keep', action='store_true', help='keep the scratch world even when every check passes')
    args = ap.parse_args()

    scenario = SCENARIOS[args.scenario]
    phases = [args.fixture] if args.fixture else scenario['phases']
    duration = args.duration or scenario['duration']
    forceload = scenario.get('forceload', False)
    for fixture in phases:
        blocks = count_blocks(fixture)
        if blocks > 1024:
            raise SystemExit('fixture requests %d mapblocks; cap is 1024' % blocks)
    if args.route:
        parse_route(args.route)

    invocation = ' '.join(['python3', 'tools/auto_towns_probe/run.py'] + sys.argv[1:])
    work = Path(tempfile.mkdtemp(prefix='towns-auto-probe-'))
    for name in ('world.mt', 'map_meta.txt'):
        shutil.copy2(args.settings_from / name, work / name)
    overrides = {}
    if args.seed is not None:
        overrides['seed'] = str(args.seed)
    if args.mg_name:
        overrides['mg_name'] = args.mg_name
    if overrides:
        # VoxeLibre's village gate rejects perfectly flat chunks (height difference <= 1),
        # so flat superflat worlds cannot show natural village planning. --mg-name lets
        # the scratch copy use another mapgen; the source map_meta.txt is not changed.
        meta = (work / 'map_meta.txt').read_text().splitlines()
        for key, value in overrides.items():
            prefix = key + ' = '
            meta = [prefix + value if line.startswith(prefix) else line for line in meta]
            if not any(line.startswith(prefix) for line in meta):
                meta.append(prefix + value)
        (work / 'map_meta.txt').write_text('\n'.join(meta) + '\n')
    mods = work / 'worldmods'
    mods.mkdir()
    probe = mods / 'auto_towns_probe'
    probe.mkdir()
    shutil.copy2(HELPER / 'init.lua', probe / 'init.lua')
    shutil.copy2(HELPER / 'mod.conf', probe / 'mod.conf')
    if args.route:
        shutil.copy2(args.route, work / 'route.json')
    with (work / 'world.mt').open('a') as f:
        f.write('\nload_mod_auto_towns_probe = worldmods/auto_towns_probe\n')
    print('Scratch world:', work, flush=True)

    report = {'invocation': invocation, 'scenario': args.scenario, 'about': scenario['about'],
              'seed_override': args.seed, 'mg_name_override': args.mg_name, 'engine': args.engine,
              'engine_version': engine_version(args.engine),
              'repo_revisions': {'towns': git_rev(ROOT), 'living_villages': git_rev(DEFAULT_LV),
                                 'mineclone2': git_rev(DEFAULT_GAME)},
              'duration_s': duration, 'phases': [], 'checks': [], 'ok': False}
    events = {}
    phase_reports = []
    for index, fixture in enumerate(phases, start=1):
        with (work / 'check.conf').open('w') as f:
            f.write('enable_ipv6 = false\nbind_address = 127.0.0.1\nserver_announce = false\n')
            f.write('auto_towns_probe_phase = %d\n' % index)
            f.write('auto_towns_probe_scenario = %s\n' % args.scenario)
            f.write('auto_towns_probe_duration = %d\n' % duration)
            f.write('auto_towns_probe_start_delay = %d\n' % args.start_delay)
            f.write('auto_towns_probe_forceload = %s\n' % ('true' if forceload else 'false'))
            f.write('max_forceloaded_blocks = 4096\n')
            f.write('auto_towns_probe_fixture = %s\n' % fixture)
            f.write('auto_towns_probe_invocation = %s\n' % invocation)
        log = work / ('stdout-phase%d.log' % index)
        with log.open('w') as out:
            subprocess.run(
                [args.engine, '--server', '--world', str(work), '--gameid', 'mineclone2',
                 '--config', str(work / 'check.conf'), '--port', str(args.port),
                 '--logfile', str(work / ('engine-phase%d.log' % index))],
                stdout=out, stderr=subprocess.STDOUT, timeout=args.timeout)
        report_file = work / ('auto-towns-probe-phase%d.json' % index)
        if not report_file.exists():
            report['checks'].append({'ok': False, 'label': 'phase %d wrote a report' % index})
            print('FAIL phase %d wrote no report; inspect %s' % (index, work / ('engine-phase%d.log' % index)))
            break
        phase = json.loads(report_file.read_text())
        phase_reports.append((index, phase))
        events[index] = read_events(work / ('auto-towns-probe-phase%d.jsonl' % index))
        report['phases'].append(phase)
        print('Phase %d: %s' % (index, json.dumps({
            'fixtures': [{k: f[k] for k in ('id', 'blocks', 'reported', 'complete')} for f in phase['fixtures']],
            'observations': phase['observations'], 'route': phase['route'],
            'errors': phase['errors']['total']})))
        for c in phase['checks']:
            report['checks'].append({'ok': c['ok'], 'label': 'phase %d: %s' % (index, c['label'])})
        if not phase.get('ok'):
            report['checks'].append({'ok': False, 'label': 'phase %d report ok' % index})

    # Scenario expectations describe the preset boxes only; a --fixture override has none.
    if len(phase_reports) == len(phases) and not args.fixture:
        for label, ok in scenario_checks(args.scenario, phase_reports, events):
            report['checks'].append({'ok': bool(ok), 'label': label})
    report['ok'] = bool(report['checks']) and all(c['ok'] for c in report['checks'])
    (work / 'probe-report.json').write_text(json.dumps(report, indent=2))
    for c in report['checks']:
        print('PASS' if c['ok'] else 'FAIL', c['label'])
    print('Report:', work / 'probe-report.json')
    if not args.keep and report['ok']:
        shutil.rmtree(work, ignore_errors=True)
    else:
        print('Scratch world kept:', work)
    raise SystemExit(0 if report['ok'] else 1)


if __name__ == '__main__':
    main()
