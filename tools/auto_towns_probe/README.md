# Automatic towns frontier probe (#391, slice 0)

A disposable-world observer for the automatic-towns design
(`docs/automatic_towns_design.md`). It records what natural generation, the
public village functions and one connected player do, so that later slices can
measure first-touch geometry, generation freshness and village success before
any town is built. It builds nothing, enables nothing and never loads Towns.

Files:

- `run.py`: copies only `world.mt` and `map_meta.txt` from a source world into a
  scratch world, installs `init.lua` and `mod.conf` as the scratch-only mod
  `auto_towns_probe`, runs the Luanti server headlessly (one process per phase,
  like `tools/place_check/run.py`) and checks the scenario's expectations.
- `init.lua`: the observer. Installed only in the scratch world.

The source world map and installed mods are not modified. The scratch world is
kept when a check fails or with `--keep`.

## Commands

From the Towns mod directory. Each command prints PASS/FAIL lines and the
`probe-report.json` path. Exit status 0 means every check passed.

```sh
python3 tools/auto_towns_probe/run.py --scenario fresh --duration 40
python3 tools/auto_towns_probe/run.py --scenario sky-underground
python3 tools/auto_towns_probe/run.py --scenario concurrent
python3 tools/auto_towns_probe/run.py --scenario old-neighbor   # two phases, same world
python3 tools/auto_towns_probe/run.py --scenario restart        # two phases, same world
python3 tools/auto_towns_probe/run.py --scenario villages --mg-name v7   # forceloaded; see below
```

Options: `--engine` (default `/Applications/luanti.app/Contents/MacOS/luanti`),
`--port` (default 39490), `--seed N` and `--mg-name NAME` (written into the
scratch `map_meta.txt` only), `--duration`, `--start-delay`,
`--fixture "id:x1,y1,z1,x2,y2,z2;..."` (one phase, no scenario checks),
`--route route.json`, `--keep`.

The source world's mapgen is `flat` (superflat). VoxeLibre's
`settlements.evaluate_heightmap` returns `max_height_difference + 1` whenever a
chunk's height difference is 1 or less, so flat chunks never plan villages. Use
`--mg-name v7` (or another non-flat mapgen) to observe village planning. The
`villages` run on `flat` observed one seed-gate opportunity, rejected by that
rule (height difference 57 against a limit of 56 in the event log).

Scenario fixtures are bounded: at most 1024 mapblocks per phase, enforced by
both `run.py` and the observer. The observer itself never emerges any area;
only fixture boxes are requested, and each is tagged `source: "fixture"`.

## Outputs

Each phase writes two files into the scratch world (path printed at the start):

- `auto-towns-probe-phaseN.json`: engine and game identity, mod paths, mapgen
  settings (`mg_name`, `seed`, `chunksize`, `mapgen_limit`, `water_level`),
  fixture completion, `observations`, `route` status, `errors`, `checks`,
  `instrumentation_restored` and `ok`.
- `auto-towns-probe-phaseN.jsonl`: one event per line, id `p<phase>-<seq>`.
  Kinds: `generated` (chunk bounds, `class` = sky/surface/underground/unavailable
  from sampled mapgen VoxelManip nodes, `heightmap` summary copied during the
  callback, `opportunity` = seed gate `blockseed % 77 == 17` with `maxp.y >= 0`,
  `nearest_player_status` and `nearest_player_distance`), `emerge_request`,
  `emerge_block` (action per mapblock), `terrain` (VoxeLibre's heightmap gate),
  `village` (`planned`, `no_plan`, `placed`, `place_error`), `route`, `error`.

`probe-report.json` (in the scratch world) combines the phases with the exact
invocation, engine version and git revisions of Towns, Living Villages and the
game when it is a git checkout.

Null and absence: a key that is absent from an event, or an observation shown as
`null`, means nothing was observed. A missing `nearest_player_distance` means no
connected player was sampled, never a fabricated distance. Failures are counted
separately in `errors` and make the check fail.

## Scripted demand is a proxy

Fixture emerges and the forceload step of `villages` are scripted demand. They
show generation and LBM behavior under a known load. They are not evidence of real
player request latency. Measure player latency only with a connected client
(see below).

## Connected-player route

`--route route.json` drives the first connected player along a route once that
player connects. It does not start a client. Without one, the route stays
`no_player`. Format:

```json
{"mode": "walk", "speed": 4.3, "points": [[0, 8, 0], [200, 8, 0], [200, 8, 200]]}
```

`walk` keeps the player on the ground, using the first non-air node below its
position; over ungenerated terrain it holds its last height and counts
`ungrounded_steps`. `fly` keeps the y coordinates of the points. Speed is in
nodes per second, at most 30. To drive a route, run `run.py --scenario fresh
--route route.json --duration 300 --keep`, then join the server on `--port`
(default 39490) with a client while the phase runs. This path has not been
exercised here: no client was available, so every route run in this slice
reported `no_player`.

## Known limits

- `on_generated` runs in the emerge thread. Its callback reads only mapgen
  objects and appends to a queue; the main thread writes the file. Whether the
  engine serializes that queue append with the main thread is not verified here.
- The emerge action is `generated` on only some mapblocks of a newly generated
  chunk; `from_memory`/`from_disk` does not prove freshness. Freshness evidence is
  the `generated` record itself.
- The seed gate is reproduced arithmetically from VoxeLibre's `villages`
  generator (`blockseed % 77 == 17`). VoxeLibre's own gate also checks its
  placeholder structblock and pending table, which this probe does not read.
- Village outcomes are observed through `settlements.evaluate_heightmap`,
  `settlements.create_site_plan` (after Living Villages' planner) and
  `settlements.place_schematics`. `terraform` and `paths` are not observed.
- The `villages` scenario forceloads fixture blocks after they complete, so their
  LBMs run without a player. `forceload.ms` is the cost of the forceload calls
  themselves; the engine loads the blocks afterwards, so it does not measure that
  work. `main_loop.longest_step_s` is the longest step seen by the observer.
  One early run on `flat` logged no server output for about 15 minutes and a
  "maximum lag" of 940 s. A rerun with the same settings did not reproduce it
  (longest step 0.099 s). The cause is not established.
- The `on_generated` callback cannot be unregistered. After exit it records
  nothing, and the wrapped globals are restored; `instrumentation_restored`
  checks that.
