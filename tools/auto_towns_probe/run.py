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


def rects_touch(a, b):
    return a['x1'] <= b['x2'] and a['x2'] >= b['x1'] and a['z1'] <= b['z2'] and a['z2'] >= b['z1']


def model_a10_observation(events):
    try:
        return _model_a10_observation(events)
    except (KeyError, TypeError, ValueError, IndexError) as exc:
        return {'evidence_status': 'inconclusive', 'complete': False, 'callback_relation': 'unobserved',
                'missing_or_invalid': ['malformed event: ' + str(exc)],
                'interpretation': 'Scratch synchronous adapter only; A10 remains UNVERIFIED.'}


def _model_a10_observation(events):
    """Strictly identify a complete scratch model trace; never promote the gate."""
    def find(kind, state=None):
        return [(i, e) for i, e in enumerate(events) if e.get('kind') == kind
                and (state is None or e.get('state') == state)]
    geometry = find('wt_a10_geometry')
    entries = find('wt_a10_planner', 'entry')
    missing = []
    relation = 'unobserved'
    if len(geometry) != 1 or len(entries) != 1:
        missing.append('exactly one geometry record and one matching planner entry')
    else:
        ei, entry = entries[0]
        if geometry[0][1].get('fixture_version') != 2:
            missing.append('recognized fixture version')
        planner_entries = [(i, e) for i, e in find('wt_planner', 'enter') if i < ei and e.get('minp') == entry.get('minp')]
        if not planner_entries:
            missing.append('matching real planner entry')
        site = entry['site']['id']
        matching = lambda kind, state: [(i, e) for i, e in find(kind, state)
                                        if e.get('site') == site]
        declines = matching('wt_a10_planner', 'declined')
        requests = matching('wt_a10_competing', 'request')
        callbacks = matching('wt_a10_competing', 'callback')
        triggers = [(i, e) for i, e in find('wt_a10_surface')
                    if e.get('site') == site and e.get('minp') == entry.get('minp')
                    and e.get('valid', 0) > 0 and e.get('site_state') == 'inspecting']
        exits = [(i, e) for i, e in find('wt_planner', 'exit') if i > ei]
        if not triggers or triggers[0][0] >= ei or entry.get('fresh_state') != 'inspecting':
            missing.append('matching surface trigger and inspecting site before planner entry')
        if len(declines) != 1 or len(requests) != 1 or len(callbacks) != 1 or not exits:
            missing.append('decline, competing request, callback, and planner exit')
        else:
            di, decline = declines[0]; ri, request = requests[0]; ci, callback = callbacks[0]
            xi = exits[0][0]
            if not (ei < di < ri < ci and ei < xi):
                missing.append('planner, decline, request, callback order')
            requests_in_window = [(i, e) for i, e in find('wt_request') if ei < i < xi]
            center = entry['site'].get('center', {})
            if not requests_in_window or requests_in_window[0][0] <= ri \
                    or requests_in_window[0][1].get('minp', {}).get('x') != center.get('x') \
                    or requests_in_window[0][1].get('minp', {}).get('z') != center.get('z'):
                missing.append('decline precedes first planner-window terrain request')
            if decline.get('inactive_after') != 'declined' or callback.get('before') != 'declined' \
                    or callback.get('after') != 'declined' or callback.get('activations') != 0:
                missing.append('declined state blocks activation')
            if request.get('minp') != callback.get('minp'):
                missing.append('callback matches requested chunk')
            if callback.get('valid', 0) <= 0:
                missing.append('competing callback has valid surface heights')
            rect = entry['site']['activation_rect']
            lo, hi = callback['minp'], callback.get('maxp', {})
            chunk = {'x1': lo['x'], 'z1': lo['z'], 'x2': hi.get('x', lo['x'] - 1), 'z2': hi.get('z', lo['z'] - 1)}
            if not rects_touch(chunk, rect):
                missing.append('competing chunk intersects activation rectangle')
            if any(e.get('kind') == 'wt_generated' and e.get('minp') == lo for e in events[:ri]):
                missing.append('competing chunk was fresh at request')
            emitted = [(i, e) for i, e in find('wt_generated') if e.get('minp') == lo and i >= ci]
            if not emitted:
                missing.append('matching generated event')
            relation = 'during_planner' if ci < xi else 'after_planner'
        if entry.get('inactive_before') is not None:
            missing.append('inactive session initially has no site state')
    return {'evidence_status': 'inconclusive', 'complete': not missing,
            'callback_relation': relation, 'missing_or_invalid': missing,
            'interpretation': 'Scratch synchronous adapter only; A10 remains UNVERIFIED.'}


def controlled_a10_observation(events):
    """Validate the controlled A10 instrumentation without promoting A10 to PASS."""
    reserve_min = {'x': -192, 'y': -32, 'z': 128}
    test_pos = {'x': 10000, 'y': 0, 'z': 10000}
    callback_min = {'x': 9968, 'y': -32, 'z': 9968}

    def first(predicate):
        return next((e for e in events if predicate(e)), None)

    reserve = first(lambda e: e.get('kind') == 'wt_synthetic' and e.get('state') == 'reserve'
                    and e.get('minp') == reserve_min)
    planner_enter = first(lambda e: e.get('kind') == 'wt_planner' and e.get('state') == 'enter'
                          and e.get('minp') == reserve_min)
    planner_marker = first(lambda e: e.get('kind') == 'wt_synthetic'
                           and e.get('state') == 'planner_entry' and e.get('reserved') is True
                           and e.get('minp') == reserve_min)
    control_request = first(lambda e: e.get('kind') == 'wt_control' and e.get('state') == 'request')
    emerge_request = first(lambda e: e.get('kind') == 'wt_request'
                           and e.get('minp') == test_pos and e.get('maxp') == test_pos)
    wait_end = first(lambda e: e.get('kind') == 'wt_control' and e.get('state') == 'wait_end')
    planner_exit = first(lambda e: e.get('kind') == 'wt_planner' and e.get('state') == 'exit'
                         and planner_enter is not None
                         and isinstance(e.get('t_ms'), (int, float))
                         and e.get('t_ms') >= planner_enter.get('t_ms', float('inf')))
    generated = first(lambda e: e.get('kind') == 'wt_generated' and e.get('minp') == callback_min)
    generated_emerge = first(lambda e: e.get('kind') == 'wt_emerge'
                             and e.get('action') == 'generated'
                             and e.get('block') == {'x': 625, 'y': 0, 'z': 625}
                             and emerge_request is not None
                             and e.get('request') == emerge_request.get('request'))

    required = {
        'synthetic reservation marker': reserve,
        'planner entry': planner_enter,
        'reserved marker at planner entry': planner_marker,
        'injected request marker': control_request,
        'matching unrelated emerge request': emerge_request,
        'control wait end': wait_end,
        'planner exit': planner_exit,
        'competing generated-chunk callback': generated,
        'matching generated emerge completion': generated_emerge,
    }
    missing = [label for label, event in required.items() if event is None]
    ordered = False
    relation = 'inconclusive'
    timestamps = {}
    if not missing:
        timestamps = {
            'reservation_ms': reserve.get('t_ms'),
            'planner_enter_ms': planner_enter.get('t_ms'),
            'planner_marker_ms': planner_marker.get('t_ms'),
            'request_marker_ms': control_request.get('t_ms'),
            'emerge_request_ms': emerge_request.get('t_ms'),
            'wait_end_ms': wait_end.get('t_ms'),
            'planner_exit_ms': planner_exit.get('t_ms'),
            'generated_callback_ms': generated.get('t_ms'),
            'generated_emerge_ms': generated_emerge.get('t_ms'),
        }
        ordered = all(isinstance(t, (int, float)) for t in timestamps.values())
        ordered = ordered and (
            timestamps['reservation_ms'] <= timestamps['planner_enter_ms']
            <= timestamps['planner_marker_ms'] <= timestamps['request_marker_ms']
            <= timestamps['emerge_request_ms'] <= timestamps['wait_end_ms']
            <= timestamps['planner_exit_ms']
            and timestamps['generated_callback_ms'] >= timestamps['emerge_request_ms']
            and timestamps['generated_emerge_ms'] >= timestamps['generated_callback_ms'])
        if not ordered:
            missing.append('timestamps in reservation/request/callback order')
        elif generated.get('t_ms') < planner_enter.get('t_ms'):
            missing.append('competing callback after planner entry')
            ordered = False
        elif generated.get('t_ms') <= planner_exit.get('t_ms'):
            relation = 'during_planner'
        else:
            relation = 'after_planner'

    complete = not missing and ordered
    return {
        'evidence_status': 'inconclusive',
        'instrumentation_status': 'complete' if complete else 'incomplete',
        'callback_relation': relation,
        'required_events_observed_in_order': complete,
        'missing_or_invalid': missing,
        'times_ms': timestamps,
        'interpretation': 'Synthetic observer instrumentation only; A10 remains UNVERIFIED.',
    }


def inactive_trigger_a10_observation(events):
    """Validate one inactive structblock's explicit single-block activation."""
    trigger_pos = {'x': -192, 'y': -32, 'z': 128}
    before = [e for e in events if e.get('kind') == 'wt_test'
              and e.get('state') == 'before_forceload']
    loads = [e for e in events if e.get('kind') == 'wt_test'
             and e.get('state') == 'forceload']
    planners = [e for e in events if e.get('kind') == 'wt_planner'
                and e.get('state') == 'enter' and e.get('minp') == trigger_pos]
    exit_events = [e for e in events if e.get('kind') == 'wt_planner'
                   and e.get('state') == 'exit']
    planner_time = planners[0].get('t_ms') if len(planners) == 1 else None
    exits = [e for e in exit_events if isinstance(planner_time, (int, float))
             and isinstance(e.get('t_ms'), (int, float)) and e.get('t_ms') >= planner_time]

    missing = []
    if len(before) != 1:
        missing.append('exactly one pre-forceload node observation')
    elif before[0].get('pos') != trigger_pos or before[0].get('node') != 'mcl_villages:structblock':
        missing.append('expected structblock at trigger position before forceload')
    if len(loads) != 1:
        missing.append('exactly one single-block forceload event')
    elif loads[0].get('pos') != trigger_pos or loads[0].get('ok') is not True \
            or loads[0].get('single_block') is not True:
        missing.append('successful single-block forceload at trigger position')
    if len(planners) != 1:
        missing.append('exactly one planner entry matching trigger chunk')
    if len(exits) != 1 or not exits[0].get('planned'):
        missing.append('one successful planner exit')

    times = {}
    if not missing:
        times = {
            'structblock_before_forceload_ms': before[0].get('t_ms'),
            'single_block_forceload_ms': loads[0].get('t_ms'),
            'matching_planner_entry_ms': planners[0].get('t_ms'),
            'planner_exit_ms': exits[0].get('t_ms'),
        }
        values = list(times.values())
        if not all(isinstance(t, (int, float)) for t in values) \
                or not (values[0] <= values[1] <= values[2] <= values[3]) \
                or events.index(before[0]) >= events.index(loads[0]) \
                or events.index(loads[0]) >= events.index(planners[0]):
            missing.append('structblock/forceload/planner timestamps in order')

    complete = not missing
    return {
        'evidence_status': 'inconclusive',
        'instrumentation_status': 'complete' if complete else 'incomplete',
        'required_events_observed_in_order': complete,
        'trigger_pos': trigger_pos,
        'missing_or_invalid': missing,
        'times_ms': times,
        'interpretation': 'One direct activation fixture only; A10 remains UNVERIFIED.',
    }


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
    ap.add_argument('--model-a10', action='store_true', help='run the scratch-only pure-state A10 model')
    ap.add_argument('--production-survey', action='store_true', help='load Towns in survey mode in the scratch world')
    ap.add_argument('--inactive-trigger-a10', action='store_true',
                    help='forceload one inactive village structblock after fixture generation (villages scenario only)')
    ap.add_argument('--route', type=Path,
                    help='walk or fly route JSON {"mode","speed","points"} for one connected client (see README)')
    ap.add_argument('--timeout', type=int, default=900, help='per-phase engine timeout in seconds')
    ap.add_argument('--cleanup', action='store_true',
                    help='remove the scratch world when every check passes (it is kept otherwise)')
    args = ap.parse_args()

    scenario = SCENARIOS[args.scenario]
    if args.controlled_a10 and args.scenario != 'villages':
        raise SystemExit('--controlled-a10 requires --scenario villages')
    if args.model_a10 and (args.scenario != 'villages' or args.fixture or args.controlled_a10 or args.inactive_trigger_a10):
        raise SystemExit('--model-a10 requires the unmodified villages scenario and no other A10 mode')
    if args.controlled_a10 and args.fixture:
        raise SystemExit('--controlled-a10 uses the villages scenario fixture; do not pass --fixture')
    if args.inactive_trigger_a10 and args.scenario != 'villages':
        raise SystemExit('--inactive-trigger-a10 requires --scenario villages')
    if args.inactive_trigger_a10 and args.fixture:
        raise SystemExit('--inactive-trigger-a10 uses the villages scenario fixture; do not pass --fixture')
    if args.inactive_trigger_a10 and args.controlled_a10:
        raise SystemExit('choose one controlled A10 mode per run')
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
    if args.model_a10:
        shutil.copy2(HELPER / 'a10_model.lua', probe / 'a10_model.lua')
        shutil.copy2(HELPER / 'a10_geometry.lua', probe / 'a10_geometry.lua')
        for directory in ('src', 'schematics'):
            shutil.copytree(ROOT / directory, probe / 'towns_source' / directory)
    if args.route:
        shutil.copy2(args.route, work / 'route.json')
    world_lines = copy_source_mods(args.settings_from / 'world.mt', work)
    if args.production_survey:
        shutil.copytree(ROOT, work / 'worldmods' / 'towns',
                        ignore=shutil.ignore_patterns('.git', '__pycache__'))
        with (work / 'worldmods' / 'towns' / 'mod.conf').open('a') as config:
            config.write('\noptional_depends = auto_towns_probe\n')
        world_lines.append('load_mod_towns = worldmods/towns')
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
    write_through_events = {}
    phase_reports = []
    for index, fixture in enumerate(phases, start=1):
        with (work / 'check.conf').open('w') as f:
            f.write('enable_ipv6 = false\nbind_address = 127.0.0.1\nserver_announce = false\n')
            f.write('max_forceloaded_blocks = 4096\n')
            if args.production_survey:
                f.write('towns_auto_mode = survey\n')
                f.write('auto_towns_probe_survey_suppression = true\n')
            if args.controlled_a10 or args.inactive_trigger_a10 or args.model_a10:
                f.write('num_emerge_threads = 4\n')
            f.write('auto_towns_probe_phase = %d\n' % index)
            f.write('auto_towns_probe_scenario = %s\n' % args.scenario)
            f.write('auto_towns_probe_duration = %d\n' % duration)
            f.write('auto_towns_probe_start_delay = %d\n' % args.start_delay)
            f.write('auto_towns_probe_forceload = %s\n' % (
                'true' if forceload and not args.inactive_trigger_a10 else 'false'))
            f.write('auto_towns_probe_controlled_a10 = %s\n' % ('true' if args.controlled_a10 else 'false'))
            f.write('auto_towns_probe_model_a10 = %s\n' % ('true' if args.model_a10 else 'false'))
            f.write('auto_towns_probe_inactive_trigger_a10 = %s\n' % (
                'true' if args.inactive_trigger_a10 else 'false'))
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
        write_through_file = work / ('auto-towns-probe-writethrough-phase%d.jsonl' % index)
        write_through_events[index] = read_events(write_through_file)
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
    if args.model_a10:
        observation = model_a10_observation(write_through_events.get(1, []))
        report['model_a10'] = observation
        report['checks'].append({'ok': observation['complete'], 'label': 'model A10: complete ordered trace'})
    if args.controlled_a10:
        observation = controlled_a10_observation(write_through_events.get(1, []))
        report['controlled_a10'] = observation
        report['checks'].append({
            'ok': observation['required_events_observed_in_order'],
            'label': 'controlled A10: required synthetic events observed in order',
        })
    if args.inactive_trigger_a10:
        observation = inactive_trigger_a10_observation(write_through_events.get(1, []))
        report['inactive_trigger_a10'] = observation
        report['checks'].append({
            'ok': observation['required_events_observed_in_order'],
            'label': 'inactive-trigger A10: structblock, one forceload, and matching planner observed',
        })
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
