#!/usr/bin/env python3
"""Disposable-world frontier and freshness probe for automatic towns (#391, slice 0).

Copies only settings (world.mt, map_meta.txt) and the mods that the source
world.mt loads into a scratch world. Each copied mod is a copy, so no installed
mod or source world map is referenced or modified. Towns is never loaded.
Installs init.lua from this folder as a scratch-only observer mod and runs the
Luanti server headlessly, one process per phase.

Each scenario runs one or two phases on the same scratch world. Each phase writes
auto-towns-probe-phaseN.json and .jsonl (one event per line, ids "p<phase>-<seq>").
This script normalizes absent keys to explicit null, checks the scenario's
expectations and writes probe-report.json into the scratch world. The scratch world
is kept by default so the report and events survive; --cleanup removes it on pass.
Exit status 0 means every check passed.

Scripted fixture boxes are explicit, bounded emerge requests. They are a proxy
for load, not evidence of actual player request latency.
"""
import argparse
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HELPER = Path(__file__).resolve().parent
USER_DATA = Path.home() / 'Library/Application Support/minetest'
DEFAULT_SOURCE = USER_DATA / 'worlds/TownsWorkshop'
DEFAULT_ENGINE = '/Applications/luanti.app/Contents/MacOS/luanti'
DEFAULT_LV = USER_DATA / 'mods/living_villages'
DEFAULT_GAME = USER_DATA / 'games/mineclone2'

# Fixture boxes are inclusive node boxes "id:x1,y1,z1,x2,y2,z2"; one list entry per phase,
# several boxes in one entry separated by ";".
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
    # Center chunk (origin chunk, minp -32 mod 80) generated, then requested again in a new process.
    # Phase 2 must not regenerate it; the center heightmap exists only inside the first callback (#392, A9).
    'center': {
        'phases': ['center:-40,0,-40,39,47,39',
                   'center:-40,0,-40,39,47,39'],
        'duration': 60,
        'about': 'center chunk: fresh heightmap in its own callback, then an old chunk in a new process',
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

# Keys that the observer omits when it has no value. Written out as explicit null here.
EVENT_NULLABLE = {
    'generated': ['nearest_player_distance'],
    'terrain': ['height_difference', 'limit', 'passed'],
    'village': ['minp', 'maxp', 'buildings', 'reason'],
    'emerge_request': ['caller', 'fixture'],
    'emerge_block': ['fixture'],
}
REPORT_NULLABLE = [
    'engine', 'game', 'modpaths.living_villages', 'modpaths.mcl_villages',
    'mapgen.chunksize', 'route.mode', 'route.speed', 'forceload.ms', 'main_loop.longest_step_at_s',
]


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


def copy_source_mods(source_world_mt, work):
    """Copy every load_mod_<name> of the source world.mt into worldmods/ and rewrite it
    to the copy. Returns the rewritten world.mt lines. Live installed mods are never
    referenced; the game itself (gameid) is read by the engine and never written."""
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
            raise SystemExit('the source world loads towns; the probe never loads Towns')
        src = Path(value) if Path(value).is_absolute() else USER_DATA / value
        if not (src / 'mod.conf').is_file():
            raise SystemExit('mod %s not found at %s' % (name, src))
        shutil.copytree(src, worldmods / name, ignore=shutil.ignore_patterns('.git', '__pycache__'))
        lines.append('load_mod_%s = worldmods/%s' % (name, name))
    return lines


def read_events(path):
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def write_events(path, events):
    path.write_text(''.join(json.dumps(e, sort_keys=True) + '\n' for e in events))


def normalize_event(e):
    for key in EVENT_NULLABLE.get(e.get('kind'), []):
        e.setdefault(key, None)
    return e


def normalize_report(phase):
    for dotted in REPORT_NULLABLE:
        *parents, leaf = dotted.split('.')
        node = phase
        for key in parents:
            node = node.setdefault(key, {})
        if node is not None:
            node.setdefault(leaf, None)
    return phase


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
    """Scenario expectations, computed from the events of each completed phase.

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
    elif name == 'center' and len(phases) == 2:
        first, second = phases[0][0], phases[1][0]
        origin = {'x': -32, 'y': -32, 'z': -32}
        fresh = [e for e in generated_chunks(first) if e['minp'] == origin]
        out.append(('center: origin chunk generated fresh in phase 1', len(fresh) == 1))
        out.append(('center: fresh origin chunk has valid heightmap', bool(fresh) and fresh[0]['heightmap'].get('valid', 0) > 0))
        again = [e for e in generated_chunks(second) if e['minp'] == origin]
        out.append(('center: origin chunk not generated again in phase 2', len(again) == 0))
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
    ap.add_argument('--controlled-a10', action='store_true',
                    help='enable the synthetic reservation and competing-emerge timing probe (villages scenario only)')
    ap.add_argument('--route', type=Path,
                    help='walk or fly route JSON {"mode","speed","points"} for one connected client (see README)')
    ap.add_argument('--timeout', type=int, default=900, help='per-phase engine timeout in seconds')
    ap.add_argument('--cleanup', action='store_true',
                    help='remove the scratch world when every check passes (it is kept otherwise)')
    args = ap.parse_args()

    scenario = SCENARIOS[args.scenario]
    if args.controlled_a10 and args.scenario != 'villages':
        raise SystemExit('--controlled-a10 requires --scenario villages')
    if args.controlled_a10 and args.fixture:
        raise SystemExit('--controlled-a10 uses the villages scenario fixture; do not pass --fixture')
    phases = [args.fixture] if args.fixture else scenario['phases']
    duration = args.duration or scenario['duration']
    forceload = scenario.get('forceload', False)
    for fixture in phases:
        blocks = count_blocks(fixture)
        if blocks > 1024:
            raise SystemExit('fixture requests %d mapblocks; cap is 1024' % blocks)
    if args.route:
        parse_route(args.route)
    invocation = shlex.join(['python3', 'tools/auto_towns_probe/run.py', *sys.argv[1:]])

    work = Path(tempfile.mkdtemp(prefix='towns-auto-probe-'))
    shutil.copy2(args.settings_from / 'map_meta.txt', work / 'map_meta.txt')
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
    probe = work / 'worldmods' / 'auto_towns_probe'
    probe.mkdir(parents=True)
    shutil.copy2(HELPER / 'init.lua', probe / 'init.lua')
    shutil.copy2(HELPER / 'mod.conf', probe / 'mod.conf')
    if args.route:
        shutil.copy2(args.route, work / 'route.json')
    world_lines = copy_source_mods(args.settings_from / 'world.mt', work)
    world_lines.append('load_mod_auto_towns_probe = worldmods/auto_towns_probe')
    (work / 'world.mt').write_text('\n'.join(world_lines) + '\n')
    print('Scratch world:', work, flush=True)

    report = {'invocation': invocation, 'scenario': args.scenario, 'about': scenario['about'],
              'seed_override': args.seed, 'mg_name_override': args.mg_name, 'engine': args.engine,
              'engine_version': engine_version(args.engine),
              'repo_revisions': {'towns': git_rev(ROOT), 'living_villages': git_rev(DEFAULT_LV),
                                 'mineclone2': git_rev(DEFAULT_GAME)},
              'scratch_world': str(work), 'duration_s': duration, 'phases': [], 'checks': [], 'ok': False}
    events = {}
    phase_reports = []
    for index, fixture in enumerate(phases, start=1):
        with (work / 'check.conf').open('w') as f:
            f.write('enable_ipv6 = false\nbind_address = 127.0.0.1\nserver_announce = false\n')
            f.write('max_forceloaded_blocks = 4096\n')
            if args.controlled_a10:
                f.write('num_emerge_threads = 4\n')
            f.write('auto_towns_probe_phase = %d\n' % index)
            f.write('auto_towns_probe_scenario = %s\n' % args.scenario)
            f.write('auto_towns_probe_duration = %d\n' % duration)
            f.write('auto_towns_probe_start_delay = %d\n' % args.start_delay)
            f.write('auto_towns_probe_forceload = %s\n' % ('true' if forceload else 'false'))
            f.write('auto_towns_probe_controlled_a10 = %s\n' % ('true' if args.controlled_a10 else 'false'))
            f.write('auto_towns_probe_fixture = %s\n' % fixture)
            f.write('auto_towns_probe_invocation = %s\n' % invocation)
        entry = {'phase': index, 'status': None, 'exit_code': None, 'report': None}
        report['phases'].append(entry)
        log = work / ('stdout-phase%d.log' % index)
        try:
            with log.open('w') as out:
                done = subprocess.run(
                    [args.engine, '--server', '--world', str(work), '--gameid', 'mineclone2',
                     '--config', str(work / 'check.conf'), '--port', str(args.port),
                     '--logfile', str(work / ('engine-phase%d.log' % index))],
                    stdout=out, stderr=subprocess.STDOUT, timeout=args.timeout)
            entry['exit_code'] = done.returncode
        except subprocess.TimeoutExpired:
            # Recorded as a failed phase, distinct from an observation that was simply absent.
            entry['status'] = 'timeout'
        report_file = work / ('auto-towns-probe-phase%d.json' % index)
        if entry['status'] == 'timeout':
            report['checks'].append({'ok': False, 'label': 'phase %d timed out after %ds' % (index, args.timeout)})
        if not report_file.exists():
            entry['status'] = entry['status'] or 'no_report'
            report['checks'].append({'ok': False, 'label': 'phase %d: %s (inspect %s)' % (
                index, entry['status'], work / ('engine-phase%d.log' % index))})
            print('FAIL phase %d: %s; inspect %s' % (index, entry['status'], work / ('engine-phase%d.log' % index)))
            break
        entry['status'] = entry['status'] or 'completed'
        phase = normalize_report(json.loads(report_file.read_text()))
        report_file.write_text(json.dumps(phase, indent=2, sort_keys=True))
        events_file = work / ('auto-towns-probe-phase%d.jsonl' % index)
        events[index] = [normalize_event(e) for e in read_events(events_file)]
        write_events(events_file, events[index])
        entry['report'] = phase
        phase_reports.append((index, phase))
        print('Phase %d: %s' % (index, json.dumps({
            'fixtures': [{k: f[k] for k in ('id', 'blocks', 'reported', 'complete')} for f in phase['fixtures']],
            'observations': phase['observations'], 'route': phase['route'],
            'errors': phase['errors']['total']})))
        for c in phase['checks']:
            report['checks'].append({'ok': c['ok'], 'label': 'phase %d: %s' % (index, c['label'])})
        if not phase.get('ok'):
            report['checks'].append({'ok': False, 'label': 'phase %d report ok' % index})
        if entry['exit_code'] != 0:
            report['checks'].append({'ok': False, 'label': 'phase %d engine exit status %s' % (index, entry['exit_code'])})

    if len(phase_reports) == len(phases) and not args.fixture:
        # Scenario expectations describe the preset boxes only; a --fixture override has none.
        for label, ok in scenario_checks(args.scenario, phase_reports, events):
            report['checks'].append({'ok': bool(ok), 'label': label})
    report['ok'] = bool(report['checks']) and all(c['ok'] for c in report['checks'])
    (work / 'probe-report.json').write_text(json.dumps(report, indent=2))
    for c in report['checks']:
        print('PASS' if c['ok'] else 'FAIL', c['label'])
    print('Report:', work / 'probe-report.json')
    if report['ok'] and args.cleanup:
        shutil.rmtree(work, ignore_errors=True)
        print('Scratch world removed (--cleanup).')
    else:
        print('Scratch world kept:', work)
    raise SystemExit(0 if report['ok'] else 1)


if __name__ == '__main__':
    main()
