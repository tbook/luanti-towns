# Automatic towns frontier probe (#391, slice 0)

A disposable-world observer for the automatic-towns design
(`docs/automatic_towns_design.md`). It records what natural generation, the
public village functions and one connected player do, so that later slices can
measure first-touch geometry, generation freshness and village success before
any town is built. It builds nothing, enables nothing and never loads Towns.

The optional `--production-survey` switch copies the current Towns checkout
into the scratch world and sets `towns_auto_mode = survey`. The probe loads
before Towns so its village observer is inside the guard. This mode can load
additional terrain and suppress villages; use it only in disposable worlds.
Survey results are recorded in the engine log. A10 remains unverified.
The probe also makes one controlled public village-planner call while a survey
is active and records `wt_survey_suppression`; this is a synthetic guard check,
not an observation of natural village ordering.

`--production-build` instead sets `towns_auto_mode = on` in the disposable
world. It can construct towns and persist their records there. It exercises the
production coordinator; it does not prove village ordering or player latency.
On 2026-11-05, flat seed 2014 runs at `remote:10752,0,10751,10752,0,10751`
(Roman) and `remote:11776,0,10752,11776,0,10752` (medieval) both reported
`complete`, with 89 urban schematics each and reported final write bounds inside
the approved envelope. Run with `--scenario fresh --production-build --fixture`
and either fixture, `--duration 90`, and a free `--port`. The observer's
controlled planner call accounts for the reported suppression; it does not
establish A10. These are flat, player-free scratch-world samples, not the #404
assembled correctness gate.

On 2026-11-05, a production-survey `fresh` run on flat terrain requested 180
chunks for one Roman site, ran exact inspection, and declined `not_fresh` in
13.70 seconds. The reported snapshot bound was 92,160,000 voxels. The probe
reported no errors and no suppressed villages; it does not verify suppression
under contention. Scratch report: `towns-auto-probe-icnx5tgt/probe-report.json`.
The controlled run `towns-auto-probe-flysvv0g` suppressed that planner call
and the survey result counted one suppressed village before declining as not fresh.
After correcting underground freshness recording, the remote fresh-site run
`towns-auto-probe-g55ysqvn` surveyed successfully in 13.80 seconds after 179
chunk requests; the controlled call was suppressed and counted once. Command:
`python3 tools/auto_towns_probe/run.py --production-survey --scenario fresh
--fixture 'remote:10752,0,10751,10752,0,10751' --duration 50 --port 39624`.

Files:

- `run.py`: copies `world.mt` and `map_meta.txt` from a source world into a
  scratch world. Every mod that the source `world.mt` loads is copied into the
  scratch `worldmods/` and the `load_mod` lines are rewritten to those copies, so
  no installed mod is referenced. Installs `init.lua` and `mod.conf` as the
  scratch-only mod `auto_towns_probe`, runs the Luanti server headlessly (one
  process per phase, like `tools/place_check/run.py`), normalizes absent keys to
  explicit null and checks the scenario's expectations. The game (`mineclone2`) is
  read by the engine from its own directory; the probe never writes to it.
- `init.lua`: the observer. Installed only in the scratch world.

The source world map is not read or modified. The scratch world is always kept
(its `probe-report.json`, `auto-towns-probe-phaseN.json` and `.jsonl` stay with
it); `--cleanup` removes it only when every check passes.

## Commands

From the Towns mod directory. Each command prints PASS/FAIL lines and the
`probe-report.json` path. Exit status 0 means every check passed.

```sh
python3 tools/auto_towns_probe/run.py --scenario fresh --duration 40
python3 tools/auto_towns_probe/run.py --scenario sky-underground
python3 tools/auto_towns_probe/run.py --scenario concurrent
python3 tools/auto_towns_probe/run.py --scenario old-neighbor   # two phases, same world
python3 tools/auto_towns_probe/run.py --scenario restart        # two phases, same world
python3 tools/auto_towns_probe/run.py --scenario center         # two phases; origin chunk fresh, then old (#392)
python3 tools/auto_towns_probe/run.py --scenario villages --mg-name v7   # forceloaded; see below
```

Options: `--engine` (default `/Applications/luanti.app/Contents/MacOS/luanti`),
`--port` (default 39490), `--seed N` and `--mg-name NAME` (written into the
scratch `map_meta.txt` only), `--duration`, `--start-delay`,
`--fixture "id:x1,y1,z1,x2,y2,z2;..."` (one phase, no scenario checks),
`--route route.json`, `--controlled-a10` (controlled synthetic A10 probe; see below),
`--inactive-trigger-a10` (single inactive-trigger fixture; see below),
`--model-a10` (scratch state adapter below), `--cleanup`.

## Scratch state A10 model

`--scenario villages --mg-name v7 --model-a10` copies the Towns source and assets into
the disposable probe mod. It calculates bounds from the actual Towns modules and installed
Living Villages providers, and feeds callback-local heightmaps synchronously into the pure
`auto_state` module using the real `auto_sites` lookup. This synchronous adapter is a
scratch model: no production automatic-town adapter or guard exists here.

It uses two independent sessions. The fresh session receives all generated events; a matching
village trigger must have a valid surface callback and an inspecting site before the planner.
The height validity test covers the entire trigger chunk, as `auto_state` does; that
callback can follow an earlier activation and need not contain valid heights inside the
site's footprint. The trace establishes state at planner entry, not which callback caused it.
The inactive session has not seen those events, modeling a trigger generated in an earlier
session. The model declines an overlapping site before requesting a fresh chunk inside its
activation halo and before calling the actual planner. It observes whether that surface callback
arrives inside or after the planner window and whether the declined session activates. The
strict validator reports missing, misordered, previously generated, non-surface or non-overlapping
events as incomplete. An incomplete trace exits nonzero; a complete trace is still inconclusive
for A10. The model does not test production event delivery, registry reservations, wrapper
installation, or actual guard behavior. It does not prove any universal engine ordering.

Reports include the exact command and revision, and each scratch world retains its copied probe,
Towns source, engine logs, write-through events and report. Fixture version is in the
`wt_a10_geometry` record. Run under `caffeinate -i` on hosts prone to idle sleep.

## Controlled A10 probe

`--controlled-a10` is valid only with `--scenario villages`. It uses four emerge threads, records an
observer-only synthetic reservation for a fixed generated chunk, and requests an unrelated fresh position from
the planner wrapper before a deliberate three-second busy wait. This tests one controlled callback ordering.
It does not load Towns, create a production reservation, or establish activation-halo ordering. The busy wait
adds an artificial pause, so do not use this mode for player loading or performance measurements. The exact
fixture, result, and limitations are recorded in `docs/automatic_towns_probe_results.md` under "Controlled
synthetic contention run". The runner validates the reservation, planner, injected request, and matching
generated callback in timestamp order. Missing or misordered events fail the probe and are recorded as an
incomplete observation. A complete sequence is still reported as inconclusive for production A10.

## Inactive-trigger A10 probe

`--inactive-trigger-a10` is valid only with `--scenario villages`, and cannot be combined with
`--controlled-a10`. It waits for the bounded village fixture to complete, records the node at
`(-192,-32,128)`, and issues exactly one `core.forceload_block` request at that position. It disables the
scenario's usual whole-fixture forceload. The runner requires the expected `mcl_villages:structblock`, one
successful single-block forceload, and one matching planner entry and successful exit in order. Missing or
misordered events fail the run and leave the evidence inconclusive. This tests one inactive trigger in one
disposable world; it does not exercise a Towns reservation or settle A10.

The source world's mapgen is `flat` (superflat). VoxeLibre's
`settlements.evaluate_heightmap` returns `max_height_difference + 1` whenever a
chunk's height difference is 1 or less, so flat chunks never plan villages. Use
`--mg-name v7` (or another non-flat mapgen) to observe village planning. The
`villages` run on `flat` observed one seed-gate opportunity. Its `terrain` record
reads `height_difference = 57`, but 57 is not a measured difference: it is
`max_height_difference + 1`, the sentinel that `evaluate_heightmap` returns for a
difference of 1 or less (flat ground, every heightmap entry 8) and for a 40x40
center with only sentinel heights. Read `passed = false` with 57 as "flat or
invalid", never as a 57-node height difference (#392 correction).

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
- `auto-towns-probe-writethrough-phaseN.jsonl` (#392): the same callbacks written and
  flushed directly from the producing callback, with `t_ms`: `wt_request`, `wt_emerge`
  (action per mapblock, plus `mapgen_heightmap_in_callback`), `wt_generated` (chunk
  bounds, class, valid heights, and the center-column check: heightmap values under two
  index layouts and the top solid node of the VoxelManip, which is a verification-only scan),
  `wt_planner` (`enter`/`exit` of `settlements.create_site_plan`), `wt_test` (controlled A10 fixture
  observations), and `wt_finish`. It is not
  drained by the main thread, so it keeps records after the observer finishes and during shutdown.

`probe-report.json` (in the scratch world) combines the phases with the exact
invocation, engine version and git revisions of Towns, Living Villages and the
game when it is a git checkout.

Null: `run.py` rewrites every phase report and events file so that a field with
no value is an explicit `null`, not a missing key. `nearest_player_distance` is
`null` when no connected player was sampled, never a fabricated distance;
`terrain.height_difference` and `limit` are `null` when the value was unavailable.
An observation category that saw nothing is `null`. Failures are counted separately
in `errors` and make the check fail. A phase that timed out or wrote no report is
recorded in `probe-report.json` as `status: timeout` or `no_report`, which fails
the run.

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
--route route.json --duration 300`, then join the server on `--port`
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
  "maximum lag" of 940 s. The cause is macOS idle system sleep, not the engine or
  the probe: `pmset -g log` shows `Entering Sleep state due to 'Idle Sleep'` at 18:21:40
  and `DarkWake` at 18:37:23, which is 943 s, matching the engine's 940.569 s lag. Run
  the probe under `caffeinate -i` to avoid it (#392).
- `core.get_mapgen_object("heightmap")` is not nil inside an emerge callback, although the
  bundled API says it is nil outside `on_generated`. In callbacks it returned the heightmap of
  the most recently generated chunk (`from_memory`) or an all-zero table (`from_disk`), so
  request-time callback reads must not be used as ground (#392, A9). The `wt_emerge.hm`
  summary exists to check this.
- The queued events file stops at finish; the write-through file keeps recording (#392, A13).
- The `on_generated` callback cannot be unregistered. After exit the queued events stop; the
  write-through file still records generations, and the wrapped globals are restored; `instrumentation_restored`
  checks that.

## Production village guard startup probe (#400)

Run `python3 tools/auto_towns_probe/guard_engine_probe.py`. It copies the source
world settings, enabled mods, and this Towns checkout into a fresh scratch world;
it never opens the source world's map. A scratch-only dependent mod creates an
accepted record and calls the installed guard in automatic mode off. It checks
startup, suppression at the accepted reservation, and pass-through one node
outside the measured village reach. For the calls it replaces the guard's saved
original with a stub, so argument, return and random-object forwarding are
observable; this does not exercise a real village plan or establish A10. The
script prints the scratch path and keeps the engine log and fixture there.

On 2026-11-05, Luanti 5.17.0 with the installed Living Villages and VoxeLibre
0.92.3 reported reach 178, a working startup guard, suppression with zero calls
to the saved planner, and one pass-through call. The planner's identity remains
an assumption because Living Villages does not publish an installation marker.

`python3 tools/auto_towns_probe/guard_engine_probe.py --vanilla-fallback`
turns off Living Villages smoothing in the scratch world. The guard disables
new automatic jobs but keeps accepted reservations protected using a separate
fallback bound audited for VoxeLibre 0.92.3 and the installed Living Villages
church wrapper. The vanilla planner tries at most 20 rings, with at most 19
five-node radius increases from the belltower; rotated schematic footprints and
water repair add their width and 20 nodes, with one node for rounding. Vanilla
paths stay between building positions, and vanilla terraform stays within the
footprints. The bound assumes that audited game and callable chain: their
identity is not exposed by a public API. Malformed or unknown dependencies
leave ordinary villages untouched and cannot guarantee accepted-reservation
protection. The 2026-11-05 fallback run passed startup with automatic jobs
disabled, accepted suppression and the near miss; it used the same stubbed
planner limitation described above.
