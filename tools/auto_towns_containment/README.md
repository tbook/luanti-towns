# Automatic towns containment test (#392, assumption A12)

A write-capable, scratch-world test that builds real Towns through the public pipeline and
compares every node that changed with the #393 envelope (`src/auto_bounds.lua`, `plan_envelope`).
It adds no builder and no per-node interception. Source worlds, installed mods and the game are
never written: `run.py` copies `world.mt` / `map_meta.txt` of a source world (default
`TownsWorkshop`; its map is not used), copies every mod that `world.mt` loads and this checkout
(`init.lua`, `mod.conf`, `src/`, `schematics/`) into a fresh `worldmods/`, and installs
`init.lua` here as the scratch-only mod `auto_towns_containment`. The scratch world is kept
(use `--cleanup` to remove it after a passing run).

## What one sample does

1. `towns.populated.search` (production site search, forced walls on/off for the medieval families).
2. Emerges a window (envelope plus the snapshot ring plus one more chunk), then waits `--settle`
   seconds (default 30) so deferred mapgen work (geodes, liquid queues) settles.
3. Calls `towns.populated.build`. When `builder.build_town` is entered, nothing has been written
   yet; the harness computes `plan_envelope` from the same plan, wall, wall features and ground,
   and takes a VoxelManip snapshot (content id and param2 of every node, one fresh VoxelManip per
   mapblock, compressed) of the envelope read box plus `--ring` nodes (default 80) on every axis.
4. The public stage functions `builder.build_town`, `living_villages.terrain.smooth_boundary`,
   `towns.outskirts.search` and `towns.outskirts_build.apply` are wrapped to diff at stage
   boundaries, so each stage's writes are attributed to its own boxes: `urban`, `margins`,
   `walls_or_roads` (the wall, feature and gate approach stage of a walled town, or the road-exit
   grading of an unwalled one: they share one interval), `rural`, plus idle intervals in between.
5. At completion the first snapshot is diffed with the world (the aggregate) against every write box.

Verdict per sample: `contained` when no node outside every write stage box changed, other than
natural liquid reflow (below). `stage_overrun_nodes` counts nodes a stage wrote inside another
stage's box but outside its own; `interval_outside_nodes` is the outside count summed over the
stage intervals. Read side: every `core.emerge_area` request made during the build is recorded and
compared with the envelope read box (mapblock rounding slack of 15 allowed), and the search's
`inspection_volume` is compared with the `urban_read` box.

Liquid reflow: after chunks load, the liquid simulation turns air and `buildable_to` nodes into
flowing liquid and renews sources, with no Towns write involved. A change outside every allowed box
counts as reflow only if the node became a liquid or a liquid became air. It is reported separately
and never makes a sample fail; `--control SECONDS` builds nothing, snapshots, waits and diffs, to show
the ambient changes of the same window. Reflow inside a write box is an ordinary change there.

## Commands (from the Towns mod directory)

```sh
python3 tools/auto_towns_containment/run.py --family medieval-walled --count 4
python3 tools/auto_towns_containment/run.py --family medieval-unwalled --count 6 --set-meta mg_name=v7
python3 tools/auto_towns_containment/run.py --family roman --count 4 --set-meta mg_name=v7 --map-seed 7777
python3 tools/auto_towns_containment/run.py --family medieval-walled --count 1 --control 45 --set-meta mg_name=v7
python3 tools/auto_towns_containment/run.py --family roman --first-index 3 --count 1 ...   # re-run one site
python3 tools/auto_towns_containment/summarize.py LABEL=<scratch>/containment-summary.json ... --digest out.json
TOWNS_LIVING_VILLAGES=<living_villages> lua5.1 tools/auto_towns_containment/cap_sweep.lua 300 8
```

`--set-meta KEY=VALUE` overrides `map_meta.txt` in the scratch copy only (the source world is flat;
`mg_name=v7` gives real relief so ramps, cut and fill actually happen). `--first-index` selects the
sample index, which sets both the site (a grid of 4 columns, `--spacing` 2500 nodes apart) and the town
seed (`--first-seed + index - 1`). Output in the scratch world: `containment-sample-N.json`,
`containment-env.json`, `containment-summary.json`, `engine.log`.

`cap_sweep.lua` is pure Lua: for N seeds per family it builds the envelope from the real planner and the
real Living Villages volume queries, and counts distinct chunks at every alignment of the town to the
chunk grid, to check the `MAX_REQUEST_CHUNKS` cap independently of where the sampled towns happened to land.

## Limits

- Only content ids and param2 are compared (light is not). A node rewritten with identical id and
  param2 is invisible, which is harmless for containment.
- Reads made with `VoxelManip`/`get_node` inside dependencies are not observable without interception;
  the read side is the emerge requests plus the search's inspection volume.
- The snapshot covers the envelope read box plus the ring. A write further out than the ring would be
  missed; the aggregate also compares the changed region with `max_rect`, and the builder's own reported
  bounds (`summary.write_bounds` and the stage `attempted_bounds`) are compared with the envelope write box.
- A sample whose site search finds nothing (`no_site`) is not a sample. Relief and biomes come from the
  scratch map, so the matrix is limited to the terrains actually run.
- `auto_bounds` loads `medieval_walls.lua` with `core.get_current_modname()`, which is nil in a callback;
  the harness scopes a shim around `default_config` and `plan_envelope` (reported in the A12 results).
