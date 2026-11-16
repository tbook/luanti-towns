#!/usr/bin/env python3
"""Probe core.get_spawn_level as an ocean pre-screen (issue 448).

For each seed in sites.json this builds a disposable world (world.mt settings
and map_meta.txt copied from --source-world, no map.sqlite, the towns and
living_villages mods left out), runs probe.lua in the real engine on its own
port, and reads back spawn_level_probe.json. Each sample point gets the
get_spawn_level result and timing plus the column the engine generates there
(ground truth). With --saved-map, the same columns are also read from a saved
world with the same seed; that world must be a copy (see README.md), never the
live save.

Results are printed as a table; the write-up is docs/automatic_towns_spawn_level_probe.md.
"""
import argparse
import json
import re
import shutil
import struct
import sqlite3
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORLDS = Path.home() / 'Library/Application Support/minetest/worlds'
ENGINE = '/Applications/luanti.app/Contents/MacOS/luanti'
OFFSETS = [-132, 0, 132]
Y_MIN, Y_MAX = -32, 80
TOWNS_LOADS = ('load_mod_towns', 'load_mod_living_villages', 'world_name')
PLANT = ('leaves', 'tree', 'log', 'flower', 'grass', 'fern', 'vine', 'mushroom',
         'sapling', 'deadbush', 'cactus', 'sugar_cane', 'bamboo', 'kelp', 'seagrass', 'coral')


def build_scratch(source, scratch, seed, lua_path, sites):
    """Create a new disposable world with the probe mod and its job file."""
    scratch.mkdir(parents=True)  # must not exist yet, so nothing is overwritten
    source_mt = (source / 'world.mt').read_text().splitlines()
    world_mt = [line for line in source_mt if not line.startswith(TOWNS_LOADS)]
    world_mt.append('world_name = spawn_level_scratch')
    world_mt.append('load_mod_spawn_level_probe = worldmods/spawn_level_probe')
    (scratch / 'world.mt').write_text('\n'.join(world_mt) + '\n')

    map_meta = (source / 'map_meta.txt').read_text()
    map_meta = re.sub(r'(?m)^seed = .*$', 'seed = %s' % seed, map_meta)
    (scratch / 'map_meta.txt').write_text(map_meta)

    mod = scratch / 'worldmods' / 'spawn_level_probe'
    mod.mkdir(parents=True)
    shutil.copy2(lua_path, mod / 'init.lua')
    (mod / 'mod.conf').write_text('name = spawn_level_probe\n')
    (scratch / 'helper.conf').write_text(
        'enable_ipv6 = false\nbind_address = 127.0.0.1\nserver_announce = false\n')
    job = {'seed': seed, 'offsets': OFFSETS, 'y_min': Y_MIN, 'y_max': Y_MAX, 'sites': sites}
    (scratch / 'spawn_level_job.json').write_text(json.dumps(job))


def run_engine(scratch, engine, port, timeout=1800):
    with (scratch / 'stdout.log').open('w') as log:
        proc = subprocess.run([engine, '--server', '--world', str(scratch), '--gameid', 'mineclone2',
                               '--config', str(scratch / 'helper.conf'), '--port', str(port),
                               '--logfile', str(scratch / 'engine.log')],
                              stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
    return proc.returncode


def classify(name):
    """Same node classes as classify() in probe.lua."""
    if name is None or name == 'ignore':
        return 'unloaded'
    if name == 'air':
        return 'air'
    if 'water' in name:
        return 'water'
    if 'ice' in name:
        return 'ice'
    if any(word in name for word in PLANT):
        return 'plant'
    return 'solid'


def column_truth(node_at, x, z):
    """Mirror read_column() in probe.lua for a function node_at(x, y, z) -> name or None."""
    water_top = ground_y = ground_name = None
    unloaded = False
    for y in range(Y_MAX, Y_MIN - 1, -1):
        name = node_at(x, y, z)
        cls = classify(name)
        if cls == 'unloaded':
            unloaded = True
        if cls == 'water' and water_top is None:
            water_top = y
        if cls == 'solid' and ground_y is None:
            ground_y, ground_name = y, name
    ocean = water_top is not None and (ground_y is None or water_top > ground_y)
    if unloaded:
        cls = 'unloaded'
    elif ocean:
        cls = 'ocean'
    elif ground_y is not None:
        cls = 'land'
    else:
        cls = 'none'
    depth = water_top - ground_y if ocean and ground_y is not None else None
    return {'class': cls, 'ground_y': ground_y, 'ground_name': ground_name,
            'water_top': water_top, 'depth': depth}


def saved_node_reader(db_path):
    """Read node names from a saved mapblock table (format version 29 and later)."""
    from compression import zstd  # Python 3.14+ standard library
    con = sqlite3.connect('file:%s?mode=ro' % db_path, uri=True)
    cache = {}

    def block(bx, by, bz):
        key = (bx, by, bz)
        if key not in cache:
            row = con.execute('select data from blocks where x=? and y=? and z=?', key).fetchone()
            cache[key] = decode_block(row[0], zstd) if row else None
        return cache[key]

    def node_at(x, y, z):
        names = block(x // 16, y // 16, z // 16)
        if names is None:
            return None
        return names[(z % 16) * 256 + (y % 16) * 16 + (x % 16)]
    return node_at


def decode_block(data, zstd):
    if data[0] < 29:
        raise ValueError('mapblock version %d is not supported' % data[0])
    body = zstd.decompress(data[1:])
    o = 1 + 2 + 4 + 1  # flags, lighting_complete, timestamp, name-id mapping version
    count, = struct.unpack_from('>H', body, o)
    o += 2
    names = {}
    for _ in range(count):
        ident, length = struct.unpack_from('>HH', body, o)
        o += 4
        names[ident] = body[o:o + length].decode()
        o += length
    o += 2  # content width, params width
    ids = struct.unpack_from('>4096H', body, o)
    return [names[i] for i in ids]


def summarize(sites, saved_truth):
    """Per-site rows. saved_truth(x, z) is None when no saved world applies to the seed."""
    rows = []
    for site in sites:
        pts = site['points']
        for p in pts:
            if saved_truth is not None:
                p['saved_truth'] = saved_truth(p['x'], p['z'])
        levels = [p['level'] for p in pts if p.get('level') is not None]
        calls = sorted(p['us'] for p in pts if 'us' in p)
        eng = {}
        for p in pts:
            eng[p['truth']['class']] = eng.get(p['truth']['class'], 0) + 1
        rows.append({
            'label': site['label'], 'group': site['group'], 'outcome': site['outcome'],
            'seed': site['seed'], 'points_with_level': len(levels), 'of': len(pts),
            'min_level': min(levels) if levels else None, 'max_level': max(levels) if levels else None,
            'call_us_median': calls[len(calls) // 2] if calls else None,
            'call_us_max': calls[-1] if calls else None,
            'engine_truth': eng,
        })
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--sites', type=Path, default=HERE / 'sites.json')
    ap.add_argument('--source-world', type=Path, default=WORLDS / 'Testlandia',
                    help='World whose world.mt and map_meta.txt are copied (never opened)')
    ap.add_argument('--scratch-root', type=Path, required=True,
                    help='Directory for disposable worlds; one new subdirectory per seed')
    ap.add_argument('--saved-map', type=Path, default=None,
                    help='SQLite copy of a saved world with the source seed, for saved ground truth')
    ap.add_argument('--engine', default=ENGINE)
    ap.add_argument('--port', type=int, default=39471)
    ap.add_argument('--only-seed', default=None)
    args = ap.parse_args()

    source_seed = re.search(r'(?m)^seed = (\d+)', (args.source_world / 'map_meta.txt').read_text()).group(1)
    all_sites = json.loads(args.sites.read_text())['sites']
    seeds = []
    for site in all_sites:
        if site['seed'] not in seeds and (args.only_seed is None or site['seed'] == args.only_seed):
            seeds.append(site['seed'])

    lua = HERE / 'probe.lua'
    summary = {}
    for seed in seeds:
        sites = [s for s in all_sites if s['seed'] == seed]
        scratch = args.scratch_root / ('seed-%s' % seed)
        build_scratch(args.source_world, scratch, seed, lua, sites)
        rc = run_engine(scratch, args.engine, args.port)
        out = scratch / 'spawn_level_probe.json'
        if rc or not out.exists():
            raise SystemExit('Probe failed for seed %s; see %s' % (seed, scratch / 'engine.log'))
        result = json.loads(out.read_text())
        for got, want in zip(result['sites'], sites):
            got['seed'] = want['seed']
        saved_truth = None
        if args.saved_map is not None and seed == source_seed:
            node_at = saved_node_reader(args.saved_map)
            saved_truth = lambda x, z, f=node_at: column_truth(f, x, z)  # noqa: E731
        summary[seed] = {'result': result, 'rows': summarize(result['sites'], saved_truth)}
        print('seed %s: %d sites, engine_version %s' % (seed, len(sites), result.get('engine_version')))
        ongen = result.get('ongen', {})
        print('  emerge_errors=%s ongen_chunks=%s ongen_calls=%s ongen_errors=%s ongen_us_avg=%s' % (
            result.get('emerge_errors'), ongen.get('chunks'), ongen.get('calls'),
            ongen.get('errors'), ongen.get('us_avg')))

    out_path = args.scratch_root / 'probe_summary.json'
    out_path.write_text(json.dumps(summary, indent=1))
    print('Summary written to', out_path)


if __name__ == '__main__':
    main()
