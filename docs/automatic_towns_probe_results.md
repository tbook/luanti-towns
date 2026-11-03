# Automatic towns probe results (#392, slice 0)

Evidence gate for [automatic towns](automatic_towns_design.md) (epic #355), run with the
disposable probe from #391 (`tools/auto_towns_probe/`, see its [README](../tools/auto_towns_probe/README.md)).
No production code changed, no Towns code was loaded, and no town was written. The source world
`TownsWorkshop` was only read for its settings (`world.mt`, `map_meta.txt`); its map was not used.
The probe changes in this ticket are observer and runner additions only (write-through log, a
center scenario, a center-column check, planner timing marks); they are verification tooling.

## Gate status

Not closed. The epic requires every correctness assumption to be PASS before this gate passes.
A10 (activation-halo ordering) and A14 (player-visible loading) are still UNVERIFIED, so #392 stays
open. A12 (containment) was tested with a write-capable scratch-world test and is **PASS (tested scope)**,
see "Containment (A12)".

- Freshness (callback recording before emerge completion, including FROM_MEMORY): **PASS** within the
  tested scenarios.
- Center ground (A9): **PASS** for the design's method (capture the center chunk's heightmap inside its own
  generation callback, no search). **FAIL** for reading the heightmap at request time: that read is not nil,
  as the bundled API says, but returns stale or zero data.
- Cancellation and late completion (A13): **PASS** for delivery and for write-through records after finish.
  Cancelled is not evidence of "not generated".
- Village ordering and activation halo (A10): **UNVERIFIED**. The planner's own terrain requests complete only
  after the planner returns (one window observed). A town-activation chunk arriving inside a window was not
  reproduced, because no town exists in this probe.
- Containment feasibility (A12): **PASS (tested scope)**: 36 of 36 real built plans (13 walled medieval,
  13 unwalled medieval, 10 Roman) wrote nothing outside the #393 envelope. Three read-side and envelope
  findings need follow-up (a 1-node `urban_read` gap, a 210-chunk worst case, a callback-time loading
  defect), none of which breaks containment. See "Containment (A12)".
- Player-visible loading (A14): **UNVERIFIED** (no connected client was available).
- Village planner pause (A15): **accepted** by the PM as pre-existing upstream behavior. Not a gate
  failure and not a blocker. See "Village planner stall".

## Environment

| Item | Value | Source |
| --- | --- | --- |
| Engine | Luanti 5.17.0 (OSX), LuaJIT 2.1.1764270282, `/Applications/luanti.app/Contents/MacOS/luanti` | probe report `engine_version`, engine log |
| Game | VoxeLibre (`mineclone2`) 0.92.3 at `~/Library/Application Support/minetest/games/mineclone2` (not a git checkout, so no revision) | engine log `VoxeLibre mapgen version`, report `game` |
| Living Villages | `668c5fc` (installed copy, copied into each scratch world) | `git -C .../mods/living_villages rev-parse` |
| Towns (probe branch) | `f744741` (base of this branch) plus this ticket's probe changes | probe report `repo_revisions` |
| Settings, source world | `seed = 2014`, `mg_name = flat` (superflat), `chunksize = 5`, `mapgen_limit = 31007`, `water_level = 1` | `TownsWorkshop/map_meta.txt`, report `mapgen` |
| Village and center-v7 runs | same seed with `--mg-name v7` (flat terrain fails the village gate) | commands below |
| Chunk-size test | same settings with `chunksize = 4` (settings copy in scratchpad, source world untouched) | command below |
| Scratch mods | `mcl_decor`, `living_villages`, `worldedit` (3 copies), the probe. Towns is not loaded. | scratch `world.mt` |
| Host | macOS Darwin 25.6.0 | `uname` |

Each run used a fresh scratch world in `$TMPDIR`. Runs were sequential and under `caffeinate -i`.

## Commands

All from the Towns mod directory. Each run keeps its scratch world.

```sh
python3 tools/auto_towns_probe/run.py --scenario fresh --duration 40
python3 tools/auto_towns_probe/run.py --scenario sky-underground --duration 60
python3 tools/auto_towns_probe/run.py --scenario concurrent --duration 60
python3 tools/auto_towns_probe/run.py --scenario old-neighbor --duration 60   # two phases
python3 tools/auto_towns_probe/run.py --scenario restart --duration 60        # two phases
python3 tools/auto_towns_probe/run.py --scenario center --duration 60         # two phases, A9 (flat)
python3 tools/auto_towns_probe/run.py --scenario center --mg-name v7 --duration 40   # A9 (v7)
python3 tools/auto_towns_probe/run.py --scenario villages --mg-name v7 --duration 180 # A10
python3 tools/auto_towns_probe/run.py --scenario villages --duration 180      # flat, for comparison
python3 tools/auto_towns_probe/run.py --fixture "cancel:-256,0,-256,255,15,255" --duration 1 --start-delay 0   # A13
python3 tools/auto_towns_probe/run.py --scenario fresh --duration 40 --settings-from <copy-dir>   # chunksize 4
# chunksize-4 variant: a copy of TownsWorkshop's world.mt and map_meta.txt with "chunksize = 4"
```

The cancellation run exits with status 1 by design: its fixture is cut short by shutdown, so the
queued-event checks fail. The write-through file is the evidence for that run.

## Retained artifacts

All in `$TMPDIR` = `/var/folders/nf/h9p5hfvs7jj6vs6q252mzhw00000gn/T/`. Each world contains
`probe-report.json`, `auto-towns-probe-phaseN.json`/`.jsonl`, `auto-towns-probe-writethrough-phaseN.jsonl`
(where the run had the write-through log), and the engine logs.

| Run | Scratch world |
| --- | --- |
| fresh | `towns-auto-probe-b2jw0a2i` |
| sky-underground | `towns-auto-probe-6gsxjw97` |
| concurrent | `towns-auto-probe-xw3m1dyg` |
| old-neighbor (2 phases) | `towns-auto-probe-vb069efc` |
| restart (2 phases) | `towns-auto-probe-lhwxzfxb` |
| villages, v7 (first run, before write-through) | `towns-auto-probe-9o11ltj2` |
| villages, v7 (rerun with write-through, A10) | `towns-auto-probe-v85bagro` |
| villages, flat | `towns-auto-probe-k4krxzc5` |
| center, flat (A9, 2 phases) | `towns-auto-probe-iz66wlra` |
| center, v7 (A9, 2 phases) | `towns-auto-probe-d_tbptbh` |
| cancel, first with write-through (before the post-finish fix) | `towns-auto-probe-_rhlmtv8` |
| cancel, after the post-finish fix (A13) | `towns-auto-probe-ocdikkj5` |
| chunksize 4, fresh | `towns-auto-probe-eyw85aot` |
| early flat villages run (lag investigation, from #391 development, older observer) | `towns-auto-probe-7le4djsz` |

## Sample counts

Generated chunks are counted once per `generated` record. Emerge counts are per mapblock callback.

| Run | Duration | Chunks generated (class) | Emerge callbacks | Natural opportunities (seed gate) | Terrain gate passed / rejected | Plans / placed | Longest main-loop step |
| --- | --- | --- | --- | --- | --- | --- | --- |
| fresh | 40 s | 4 (surface 4) | 104 from_memory, 4 generated | 0 | not reached | 0 / 0 | 0.066 s |
| sky-underground | 60 s | 12 (sky 4, underground 4, surface 4) | 240 from_memory, 12 generated | 0 | not reached | 0 / 0 | 0.070 s |
| concurrent | 60 s | 7 (surface 7) | 248 from_memory, 10 generated (7 unique blocks) | 0 | not reached | 0 / 0 | 0.061 s |
| old-neighbor, phase 1 | 60 s | 4 (surface 4) | 104 from_memory, 4 generated | 0 | not reached | 0 / 0 | 0.061 s |
| old-neighbor, phase 2 | 60 s | 2 new (surface 2) | 37 from_disk, 105 from_memory, 2 generated | 0 | not reached | 0 / 0 | 0.062 s |
| restart, phase 1 | 60 s | 4 (surface 4) | 104 from_memory, 4 generated | 0 | not reached | 0 / 0 | 0.061 s |
| restart, phase 2 | 60 s | 0 new | 108 from_disk | 0 | not reached | 0 / 0 | 0.061 s |
| center, flat, phase 1 / phase 2 | 60 s | 4 / 0 new | 4 generated + 104 from_memory / 108 from_disk | 0 | not reached | 0 / 0 | not sampled (run predates the heightmap summary field) |
| center, v7, phase 1 / phase 2 | 40 s | 4 / 0 new | 4 generated + 104 from_memory / 108 from_disk | 0 | not reached | 0 / 0 | not sampled |
| villages, v7 (rerun) | 180 s | 62 (surface 55, sky 7) | 1262 from_memory, 62 generated | 2 | 1 passed (height diff 6), 1 rejected (see below) | 1 / 1 | 20.37 s |
| villages, v7 (first run) | 180 s | 62 (surface 55, sky 7) | 1262 from_memory, 62 generated | 2 | 1 passed, 1 rejected | 1 / 1 | 20.29 s |
| villages, flat | 180 s | 49 (surface 49) | 975 from_memory, 49 generated | 1 | 0 passed, 1 rejected (flat) | 0 / 0 | 0.10 s |
| cancel, after fix | 1 s | 2 late (surface, see A13) | 2 generated + 3 from_memory + 1019 cancelled | not counted | not reached | 0 / 0 | not sampled |
| chunksize 4, fresh | 40 s | 18 (surface 9, sky 9) | 90 from_memory, 18 generated | 0 | not reached | 0 / 0 | not sampled |

Natural village success: **1 placed village from 2 seed-gate opportunities (50%)**, and 1 of 1 that passed
the terrain gate. This is n = 2 from 62 chunks, so it has no statistical weight. The expected seed-gate rate
is 1 in 77 (about 1.3%). Every other run has zero opportunities, which is a sample limitation, not evidence
of rarity. The v7 village rerun reproduced the first run's outcome. No run used ordinary exploration; all
terrain came from scripted fixtures, planner requests, or structure placement.

## Assumption verdicts

| # | Assumption | Verdict | Evidence | Downstream blocked |
| --- | --- | --- | --- | --- |
| A1 | Generated-chunk recording happens before the corresponding emerge callback is consumed, including when the later action is FROM_MEMORY | **PASS** (tested scope) | Analysis script: 0 violations across the runs. Every `generated` callback, and every `from_memory` callback, had an earlier `generated` record covering its block. Covered `from_memory` callbacks: fresh 104, sky-underground 240, concurrent 248, old-neighbor phase 2 88 (the other 17 are old chunks, see A2), v7 1262, flat 975, chunksize 4 90. | Not blocked by A1. Player-driven interleaving is under A14. |
| A2 | Old chunks loaded from disk or memory produce no record in a new process or session | **PASS** | Restart phase 2 loaded 108 blocks, all `from_disk`, with 0 `generated` events. Old-neighbor phase 2 had 37 `from_disk` blocks with no covering record. Its 17 `from_memory` blocks without a record all lie in chunks loaded from disk earlier in the same phase (checked by chunk membership). | None |
| A3 | Partial old/new coverage: only new chunks are recorded | **PASS** | Old-neighbor phase 2 overlapped old chunks. Records existed only for the 2 new chunks. | None |
| A4 | Sky and underground chunks are recorded even before any surface chunk | **PASS** | sky-underground: sky and underground records precede the first surface record in the event order. | None |
| A5 | Overlapping, same-tick requests each see consistent generation | **PASS** (tested scope) | concurrent: each chunk had one `generated` record. 3 blocks reported `generated` to two overlapping requests, so the emerge action is shared, not per request. | Action-level freshness must not be inferred from the emerge action alone. |
| A6 | Real chunk alignment is not zero-aligned | **PASS** | chunksize 5: minp.x,y,z = -32 + 80k. chunksize 4: minp = -32 + 64k. Both align to -32, not to 0. | Settles the input for #393 |
| A7 | Supported chunk settings | **PARTIAL**: chunksize 5 is the only supported setting for the village gate. chunksize 4 was observed for generation only. | chunksize 4 generated normally with the same callbacks. VoxeLibre's `evaluate_heightmap` (`mcl_villages/utils.lua`, lines 213 and 245) hard-codes 80-wide rows; `half_map_chunk_size = 40` (`const.lua:76`) also assumes 80 nodes. So villages are not supported for other sizes (code reading, not run). | Constrains #393 to chunksize 5 |
| A8 | Surface-bearing callback can be identified, and valid, clipped, and sentinel heights are distinguishable | **PASS** for the classes below; exact sentinel value **UNVERIFIED** | See "Heightmap classes". | Sets #395 rules |
| A9 | Center ground is obtained from the center request without a vertical search | **PASS** for the design's method: capture inside the center chunk's own generation callback. **FAIL** sub-finding: request-time heightmap reads are unusable. | Fresh center (v7): the callback that generated the chunk recorded its heightmap (4 of 4 generated blocks matched the chunk record). Request-time callbacks for old chunks returned a non-nil table that was all zero (`from_disk`, 108 of 108) or the heightmap of the most recently generated chunk (`from_memory`, 16 of 104 matched a different chunk, see "Callback heightmap"). Design consequence: the center reference must be read only inside the on_generated call for that chunk, and old centers decline. Center-column semantics (heightmap vs top solid node) are UNVERIFIED, see "Callback heightmap". | #397 must capture only in on_generated; the bundled API note must not be relied on |
| A10 | Activation-halo ordering: the village planner runs only after the town reservation exists, and a town-activation chunk cannot arrive midway through the planner's terrain requests | **UNVERIFIED** (partial positive) | One planner window (v7, village). Its two forced terrain requests were issued 10 s apart (9989 ms, 19995 ms) and completed only after the planner returned (30457 ms, 30503 ms; window 9967-30003 ms). No `on_generated` record fell inside the window. See "Planner window timing". No town existed, so a town-activation chunk arriving in the window was not reproduced. | #400, #402, #403, #404 |
| A11 | Village trigger reaches the guarded planner (`settlements.create_site_plan`) | **PASS** | The probe's wrapper recorded `planned` and `placed` in both v7 runs. The chain is `structblock LBM -> emerge_area(footprint) -> ecb_village -> create_site_plan`. | Not blocked |
| A12 | Containment feasibility (writes stay inside the envelope) | **PASS (tested scope)**: 36 evaluated plans (3 families, flat and relief terrain), 0 nodes written outside the envelope write boxes (aggregate) and 0 outside a stage's own boxes in the stage intervals; builder-reported write bounds inside the envelope in 36 of 36. | Write-capable scratch-world test, `tools/auto_towns_containment/`; numbers, commands and caveats in "Containment (A12)". Cap sweep: 900 plans, worst case 210 chunks (cap 256). | #393 (cap freeze, after the findings below are decided), #397, #403 |
| A13 | Cancelled or late completions are delivered and recorded; cancelled does not mean ungenerated | **PASS** | cancel after fix: 1019 `cancelled` callbacks delivered after `wt_finish` (2159 to 2560 ms), 2 chunks generated after finish with `after_finish` records, and 31 cancelled blocks lying inside those generated chunks. See "Cancellation". | #398 may keep the rule that `EMERGE_CANCELLED` requires proof and records |
| A14 | Player-visible loading latency is within the starting targets | **UNVERIFIED** | No connected client was available. Only scripted demand was measured. | #405 and the loading parts of #397 |
| A15 | Village planner pause | **ACCEPTED (PM decision)**: pre-existing upstream behavior, not a gate failure, not a blocker | See "Village planner stall". | None (the PM accepted the pause) |

## Heightmap classes (surface-bearing callback)

Measured from the probe's `heightmap` summary (6400 entries per 80-node chunk) in the callback:

| Class in this data | Heights | Meaning |
| --- | --- | --- |
| Sentinel (invalid) | No entry in the probe's valid range (`|v| < 30000`) | No ground inside the chunk, for example sky chunks above the ground. 7 sky chunks in v7 and 9 in chunksize 4 had 0 valid entries. The exact sentinel value was not recorded, and VoxeLibre compares only against -31000 and 31000. Treat it as invalid. |
| Clipped at the chunk top | Value equals `maxp.y` | Ground is at or above the chunk top. Underground chunks (-112..-33) had every column at -33 = maxp.y. In v7, 11 surface chunks had maximum = maxp.y = 47, and 1 had maxp.y = 127. These are not usable ground. |
| Clipped at the chunk bottom (ambiguous) | Value equals `minp.y` | 4 v7 surface chunks have minimum = minp.y. Their semantics are not established. Treat as ambiguous and send to exact inspection. |
| Valid ground | `minp.y < value < maxp.y` | 38 v7 surface chunks and all flat surface chunks (value 8). A ground at exactly `maxp.y` is indistinguishable from a clip, so treat it as clipped. |

The probe's "surface" class is a sample of 8x8x8 VoxelManip points per chunk. It is approximate. One v7
chunk (`p1-001175`, the second opportunity) was classed "surface" but had 0 valid heights. Use heightmap
validity, not the sampled class, to identify a surface-bearing callback.

## Callback heightmap (A9 detail)

`core.get_mapgen_object("heightmap")` was probed inside every emerge callback, and its summary was recorded
in `wt_emerge.hm`:

| Callback action | Flat center run (`iz66wlra`) | v7 center run (`d_tbptbh`) |
| --- | --- | --- |
| `generated` (same request that generated the chunk) | not recorded (run predates the `hm` field) | 4 callbacks, all match the chunk's own `generated` record |
| `from_memory` | not recorded | 104 callbacks, see below | 104 callbacks: 88 match their own chunk (the origin chunk, which was generated last), 16 equal the summary of chunk (-32,-32,-112), a different chunk, so stale |
| `from_disk` (phase 2, old chunks) | not recorded | 108 callbacks, all summaries all zero (min = max = median = 0, valid 6400) |

Conclusions:

- `mapgen_heightmap_in_callback` was `true` in every emerge callback (flat and v7 runs, all actions). The bundled API (`lua_api.md`, Mapgen
  objects) says the object is nil outside `on_generated`, which does not hold in this build.
- Inside the chunk's own `on_generated`, the heightmap is that chunk's heightmap (the design's method works; checked in the v7 run).
- Outside it, the value is stale (previous chunk) or zero (old chunk). Zero is inside the numeric valid range,
  so it would look like ground to a naive check. Reading the heightmap at request time is therefore
  unusable, and old centers must decline.
- Center column check (`wt_generated.center`, v7): heightmap and top solid node agree at 3 of 4 chunks
  (29, 29, 24). At chunk (-32,-32,-32) the heightmap says 32 while the top non-air node is 40, which is
  probably vegetation. Whether "ground" means the heightmap's node or the top solid node is a design judgment.
  Escalated (see Blockers).
- The two candidate index layouts cannot be distinguished, because the chosen center column lies on the
  diagonal (ix = iz). The layout is UNVERIFIED.

## Planner window timing (A10 detail)

From `towns-auto-probe-v85bagro`, `auto-towns-probe-writethrough-phase1.jsonl` (write-through `t_ms`, elapsed
from observer start):

- `wt_planner enter` at 9967 ms and `exit` at 30003 ms (20.04 s).
- `r13` single-node terrain request at 9989 ms (planner, y = 64) completed `generated` at 30457 ms.
- `r14` single-node request at 19995 ms (10.0 s after r13, the length of one busy-wait) completed `generated`
  at 30503 ms.
- No `wt_generated` record fell inside the window. The 19 callbacks at 9967 ms were `from_memory` callbacks of
  request `r12` (issued 9929 ms), delivered at window entry, before the planner's own requests.

So the planner's own requested terrain finished only after the planner returned. Under this observation, a
town-activation chunk requested by the planner would activate after the planner, not midway through it. This
is one window and one seed. A chunk arriving from elsewhere during a window is not established. Design
judgment needed (see Blockers).

## Containment (A12)

Verdict: **PASS (tested scope).** Every one of the 36 sampled plans that were built was contained. No run
wrote a node outside the #393 envelope, aggregate or per stage. The scope is the terrain, seeds and
families below; it is not a proof for every possible terrain.

### Method

`tools/auto_towns_containment/` (README there) is a scratch-world mod plus a runner. It does not add a builder or
intercept node writes. For each sample it:

1. Runs the production site search (`towns.populated.search`, forced walls on or off for the medieval families,
   Roman for the third) at a fresh grid point, 2500 nodes from the previous one.
2. Emerges a window one chunk wider than the snapshot region and waits 30 s so deferred mapgen work settles.
3. Calls the production build (`towns.populated.build`). When `builder.build_town` is entered (nothing written yet)
   it computes `auto_bounds` `plan_envelope` from the same plan, wall, wall features and ground, then snapshots, with
   VoxelManip (content id and param2 of every node, one fresh VoxelManip per mapblock), the envelope read box plus 80
   nodes on every axis (mapblock aligned). The window it emerged is checked to contain that region.
4. Diffs again at each stage boundary by wrapping the public stage functions (`builder.build_town`,
   `living_villages.terrain.smooth_boundary`, `towns.outskirts.search`, `towns.outskirts_build.apply`) and at
   completion, so each stage's writes are checked against its own boxes: urban, margins, the wall / feature / gate
   approach stage (or the road-exit grading of an unwalled or Roman town; one interval), the rural stage, plus the idle
   gaps between them. The first snapshot against the final world is the aggregate.
5. Compares every changed node with the envelope's write boxes (per-stage names `urban_build`, `city_margins`, `walls`,
   `wall_approaches[i]`, `wall_features[i]`, `outside_roads[i]`, `outskirts`), the builder's own reported bounds
   (`summary.write_bounds`, stage `attempted_bounds`) with the envelope write box, and the changed region with
   `max_rect` (centre-relative).

Providers: the real Living Villages `terrain.volume` and `terrain.boundary_volume` (LV `668c5fc`), `settlements.schematic_table`,
the Living Villages planner config, the rural catalog plus chapel and the `wall_*` catalog entries. Scratch worlds copy
`TownsWorkshop`'s `world.mt` / `map_meta.txt` and its mods; its map, the installed mods and the game are not written.

Liquid reflow: after chunks load the liquid simulation fills air (and buildable_to nodes such as snow) with flowing liquid
and renews sources, with no Towns write. A change outside every allowed box counts as reflow only if the node became a
liquid or a liquid became air. These are counted and reported separately and never fail a sample. Control runs (no build,
snapshot, 45 s, diff) on the same v7 windows changed 4,298 and 2,662 nodes, every one of them
`air`, `water_flowing`, `water_source` or `lava_flowing`, so reflow is ambient (an earlier control without the 30 s settle
also showed geode and basalt decoration from deferred mapgen; the settle removes it).

### Commands and artifacts

From the Towns mod directory (each run kept its scratch world; the paths below are under
`/var/folders/nf/h9p5hfvs7jj6vs6q252mzhw00000gn/T/` and are temporary):

```sh
python3 tools/auto_towns_containment/run.py --family medieval-walled   --count 4                       # flat, TownsWorkshop mapgen
python3 tools/auto_towns_containment/run.py --family medieval-unwalled --count 4
python3 tools/auto_towns_containment/run.py --family roman             --count 4
python3 tools/auto_towns_containment/run.py --family <family> --count 8 --set-meta mg_name=v7                  # relief, map seed 2014
python3 tools/auto_towns_containment/run.py --family <family> --count 6 --set-meta mg_name=v7 --map-seed 7777  # relief, map seed 7777
python3 tools/auto_towns_containment/run.py --family medieval-walled --count 2 --control 45 --set-meta mg_name=v7  # ambient control
TOWNS_LIVING_VILLAGES=<living_villages> lua5.1 tools/auto_towns_containment/cap_sweep.lua 300 8               # 900 plans x 1000 alignments
python3 tools/auto_towns_containment/summarize.py LABEL=<scratch>/containment-summary.json ... --digest out.json
```

Committed digest of the evaluated runs: `tools/auto_towns_containment/results/a12-2026-11-03.json` (per sample: status, envelope
chunks, worst-alignment chunks, changed and reflow counts, per-stage reach, interval counts, read-side checks). Scratch worlds
(per-sample `containment-sample-N.json`, `engine.log`):
the nine runs behind the table were made on 2026-11-03 (Luanti 5.17.0, LuaJIT, VoxeLibre `mineclone2`, Living Villages
`668c5fc`); the scratch world of each is named in its `containment-summary.json` and in the run output, and the committed
digest holds the numbers. The earlier ambient-control world is `towns-containment-io1_m971`.

### Sample counts and results

"No site" means the production search found no acceptable site at that grid point (water, trees, mountains) after
moving the fake player up to 8 times; it is not a sample.

| Terrain | Family | Requested | No site | Evaluated | Contained | Written nodes (sum) | Chunks (min to max) | Placed wall features |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| flat | medieval walled | 4 | 0 | 4 | 4 | 467,776 | 180 to 210 | 100 |
| flat | medieval unwalled | 4 | 0 | 4 | 4 | 347,533 | 180 to 210 | 0 |
| flat | Roman | 4 | 0 | 4 | 4 | 437,711 | 180 | 0 |
| v7, map seed 2014 | medieval walled | 8 | 2 | 6 | 6 | 1,149,862 | 144 to 210 | 136 |
| v7, map seed 2014 | medieval unwalled | 8 | 2 | 6 | 6 | 1,084,614 | 144 to 210 | 0 |
| v7, map seed 2014 | Roman | 8 | 3 | 5 | 5 | 1,323,183 | 144 to 180 | 0 |
| v7, map seed 7777 | medieval walled | 6 | 3 | 3 | 3 | 658,779 | 120 to 180 | 72 |
| v7, map seed 7777 | medieval unwalled | 6 | 3 | 3 | 3 | 631,212 | 120 to 180 | 0 |
| v7, map seed 7777 | Roman | 6 | 5 | 1 | 1 | 202,461 | 144 | 0 |
| **all** | | 54 | 18 | **36** | **36** | **6,303,131** | **120 to 210** | 308 |

(Per-row node sums and placed-feature counts are recomputed from the digest; the "written nodes" sum counts every changed node
in the snapshot region; 20,140 of them are liquid reflow outside the boxes.) The 24 v7 footprints had a surface height range
of 16 to 43 nodes (finished ground y 10 to 30; the flat world is y 8), so ramps, cut and fill and margin smoothing really ran: margin
`max_movement` reached its 20-node cap, 95 road exits were graded (13 refused cleanly), 13 walled towns placed 20 to 25
features each (308, from 325 selected) and had 78 bare gate-crossing approach boxes.

Aggregate and per-stage outcome over the 36 evaluated plans:

- Nodes changed outside every write box that were not liquid reflow: **0** (aggregate, every sample).
- Nodes a stage wrote in another stage's box but outside its own, over the stage intervals: **0**. Nodes outside every box
  in the stage intervals: **0**. Idle gaps between stages changed only reflow (28,519 + 525 nodes).
- Changed region against `max_rect` (centre relative, +/-245): within in 36 of 36; the largest extent was 205 nodes from the
  centre. Vertically the writes ran from 46 below to 75 above the finished ground, inside the envelope's y ranges.
- Builder-reported write bounds (`summary.write_bounds`, every stage `attempted_bounds`) inside `envelope.write`: 36 of 36.
- Every envelope was produced (0 declined for `oversized`, `map_limit`, `chunk_cap` or `snapshot_cap`).
- Snapshot region inside the emerged window and containing no ungenerated (`ignore`) block: 36 of 36.

### The #393 caveats (reaches derived from constants and comments)

Per stage, furthest horizontal reach beyond `plan.bounds`: the stage `stage_reach` that #393 derived; the largest
stage box built from the real plans (the 36 builds, and the cap sweep over 900 plans in brackets); and the furthest node
actually written (v7 builds; attributed by the stage interval, and for the shared wall/road interval by lying in exactly
one stage's box):

| Stage | stage_reach | Largest box overhang | Furthest node written |
| --- | --- | --- | --- |
| urban_build | 8 | 8 (8) | 0 beyond the plan bounds |
| city_margins | 63 | 53 (51) | 32 |
| walls | 6 | 6 (6) | 6 |
| wall_approaches | 22 | 16 (16) | not separable (see below) |
| wall_features | 34 | 22 (22) | 17 |
| outside_roads | 16 | 16 (16) | 15 |
| outskirts | 113 | 113 (113) | 76 |
| any node in the wall / road interval | | | 17 |

- Wall approach, wall feature and outside road reaches: no written node fell outside its stage's own boxes, and every box
  overhang is within its `stage_reach` (equal for `walls`, `outside_roads` and `outskirts`, so those three are tight; the
  others have slack). The 22-node `wall_approaches` and 34-node `wall_features` reaches are never approached: the boxes
  reach 16 and 22 and the furthest written node of the whole wall interval is 17. Gate approaches cannot be separated from
  the other wall stages by exclusive box membership (they sit inside the walls, feature and margin boxes except at the outer
  ramp end), so their reach is bounded by the 17 of the shared interval, which is below 22.
- The stage code in `generate_command.lua` opens its working region from the same box functions that `auto_bounds` uses
  (`walls.bounds`, `approach_bounds`, `feature_clearance_bounds`), which is why the boxes and the writes agree; the samples
  confirm it, they do not prove it for terrain the sampled maps did not produce.

### Caps and chunk count

`MAX_REQUEST_CHUNKS` 256 holds. The 36 real builds had 120 to 210 chunks (observed alignment) and 107,520,000 snapshot voxels at
the most, against 131,072,000.

The documented "180-chunk measured maximum" is not the maximum. The chunk count depends on where the town lands on the
80-node engine chunk grid. `cap_sweep.lua` builds 300 seeds per family (900 plans, none declined) with the real planner, the
real Living Villages volumes and the real wall features, and counts distinct chunks at 1000 alignments (steps of 8 on each
axis):

| Family | Max at the planner origin alignment | Max over all alignments |
| --- | --- | --- |
| medieval walled | 144 | 210 |
| medieval unwalled | 144 | 210 |
| Roman | 144 | 210 |

210 looks structural: the outskirts box (plan bounds grown by 113 horizontally, 270 nodes tall) dominates the union, and all
three families reach the same worst case (about 7 x 6 x 5 chunks by my reading of the box sizes, not separately verified). Four of the real builds landed on a 210-chunk alignment. The cap's headroom is therefore 256 / 210 = 1.22, not the 1.4
quoted in `auto_bounds`, and 210 chunks hold 107,520,000 voxels, inside the 131,072,000 snapshot cap.

### Read side (feasible part)

- Every `core.emerge_area` request made while the build ran (34 to 78 per sample, 1,804 in all, recorded by wrapping
  `core.emerge_area` in the scratch world) lay inside the envelope read box with 0 nodes of excess (rounding slack of 15 was
  allowed and not needed).
- `build_volume` (the cut and fill margin emerge) was inside the `urban_build` box in 36 of 36.
- **Finding:** `result.inspection_volume` (the area the search read) was 1 node wider than the `urban_read` box on x and z in
  36 of 36. The production search uses `site_search.WET_DEFAULTS` (wet mode, a one-node ring), while
  `auto_bounds.default_config().wet_ring` is 0. The union read box still contained it (36 of 36), so no envelope is wrong, but a
  caller using the production search must set `config.wet_ring = 1`. The y extent matched exactly (98 nodes, `reference_y - 48 ..
  reference_y + 49`) once the reference is the search's own reference ground, which differed from the finished ground by -35 to
  +19 in these samples. The harness passed the finished ground as `reference_y`, which is why `urban_read` itself is not compared
  in y.
- Reads made by VoxelManip or `get_node` inside the dependencies are not observable without engine-level interception, which
  was out of scope. The emerge requests bound the data the engine had to load; they are not a proof that every read was inside
  the box.

### Findings and corrections (findings 1 and 3 applied in `src/auto_bounds.lua`; 2 is for callers)

1. **Callback-time loading** (fixed): `auto_bounds.default_config()` and the first `plan_envelope` used to `dofile`
   `medieval_walls.lua` lazily, whose sibling loader calls `core.get_modpath(core.get_current_modname())`; outside mod load
   time the modname is nil and the call raised. `auto_bounds` now loads its sibling modules when it is loaded, so it must be
   required while the Towns mod loads (as #394 onward will), and a test (`tests/auto_bounds_tests.lua`) covers use with a nil
   mod name. The harness loads it under a modname shim because it is not the Towns mod.
2. **Wet ring** (config): set `wet_ring = 1` (or derive it from `site_search.WET_DEFAULTS`) when the production search is used;
   the default of 0 leaves `urban_read` one node short of what is read. Not applied: the existing test fixes the default as 0.
3. **Cap basis** (corrected): the `M.CAPS` basis string and `auto_bounds` header now state the worst alignment, 210 chunks
   (144 at the planner origin alignment), headroom 1.22. The 256 cap is unchanged and `PROVISIONAL` stays set until the gate
   owner accepts A12.

### Limits of this evidence

- 36 plans: 13 walled medieval, 13 unwalled medieval, 10 Roman (only 1 Roman on map seed 7777, 5 on 2014). Two relief maps and
  the flat world; no ocean, snow, desert or mountain-biome sites (the search rejected those grid points).
- Only content id and param2 are compared. A node rewritten with the same id and param2 is invisible, which is harmless for
  containment. Light is not compared.
- The snapshot is the envelope read box plus 80 nodes; a write further out would be missed. The changed-region and
  builder-reported-bounds checks above would catch a stage reporting such a write, not an unreported one.
- Attribution inside the shared wall / road interval is by box membership, not by timing.
- Liquid reflow is ambient and excluded from the verdict; a Towns write of liquid (not seen in any box here) outside every box
  would be hidden among it. The control runs are the only check on that; liquid written by Towns (fountains, wells)
  lies inside boxes in these samples.
- The 30 s settle before the first snapshot and the 45 s control are fixed choices, not measured limits.

## Cancellation (A13 detail)

Two runs with the write-through file (1 s, 1024 blocks, requested in the same globalstep that finishes the run):

| Run | Observed by queued events | Observed by write-through |
| --- | --- | --- |
| before the post-finish fix (`_rhlmtv8`) | 0 of 1024 (events stop at finish) | 1024 callbacks after `wt_finish` at 1861 ms: 3 generated, 7 from_memory, 1014 cancelled (1920 to 2016 ms). No `wt_generated` for the 3 generated chunks, because the on_generated record was switched off at finish. |
| after the fix (`ocdikkj5`) | 0 of 1024 | 1024 callbacks after `wt_finish` at 2044 ms: 2 generated (2115, 2158 ms), 3 from_memory (2116 to 2117 ms), 1019 cancelled (2159 to 2560 ms). Both generated chunks have `wt_generated` records with `after_finish: true`. |

Findings:

- Shutdown does not drop pending emerge callbacks. They are delivered as `cancelled` during shutdown.
- Terrain can still be generated and recorded during shutdown.
- A `cancelled` block can lie inside a chunk that was generated and recorded: 31 of 1019 cancelled blocks did.
  So `EMERGE_CANCELLED` is not evidence that terrain is absent. The design's rule (cancelled requires proof
  that terrain is available and recorded, otherwise decline) is the right one.
- Late completion: a late `generated` callback is observable only if the recorder stays active, which the
  probe now does through the write-through path. The 988 cancelled blocks outside any generated chunk fit the
  same pattern. Their absence from the chunk records is a consequence of the cancel, not a missing event.

Not tested: a cancellation mid-generation (the emerge queue was drained by shutdown, not interrupted), and
late completions in a live session (no client).

## Village trigger chain

Verified from VoxeLibre `mcl_villages` source plus the probe events:

1. `register_generator("villages")` in `on_generated` (emerge thread): returns unless `maxp.y >= 0` and
   `blockseed % 77 == 17`. It places a structblock at the chunk's minp. The probe's `opportunity` flag
   reproduces this gate (2 hits in v7).
2. `settlements.evaluate_heightmap` runs over the center 40x40 of the chunk heightmap. The return value is
   `max_height_difference + 1 = 57` when the difference is 1 or less, which covers flat terrain and
   sentinel-only heights. So the probe's `height_difference = 57` is a sentinel return, not a measured
   difference (correction to the #391 README, now made).
3. The structblock LBM (`run_at_every_load`) runs when the block is activated. It removes the structblock
   and calls `emerge_area(minp, maxp, ecb_village)` for the village footprint (one chunk).
4. `ecb_village` runs `build_a_settlement`: `settlements.create_site_plan` (Living Villages planner, which
   the probe wraps), then `terraform`, `paths` (disabled by Living Villages), and `place_schematics`.

Probe evidence for the v7 village: `p1-001116` is an emerge request for the footprint from `init.lua` (the
LBM). `p1-001312` and `p1-001313` (first run; `r13` and `r14` in the rerun) are single-node emerges at `y = 64` from `init.lua`, the
`mcl_vars.get_node(pos, true, ...)` path. `p1-001314` is `village planned` (25 buildings). The planner's log
lines are labelled `[Emerge-0]`, so the planner ran on an emerge thread.

## Village planner stall (accepted upstream behavior, A15)

Status: **accepted by the PM**. The stall is in core VoxeLibre and Living Villages code, not in Towns, and
it happens with or without automatic towns. It is recorded here because it is why village planning can freeze
the server independent of towns.

Mechanism, with file references:

- `mcl_villages/buildings.lua:91`: `settlements.find_surface(center, true)` for the village center.
- `mcl_villages/buildings.lua:137`: `settlements.find_surface(pos1, true)` for further buildings.
- `mcl_villages/utils.lua:33`: `find_surface` calls `get_node(p6, true, 10000000)` when `wait` is set.
- `mcl_init/init.lua:210-237`: `mcl_vars.get_node(pos, force, us_timeout)` with `force` calls
  `minetest.emerge_area(pos, pos)` and then busy-waits up to `us_timeout` (10 s) on the ungenerated node.
- `living_villages/site_planner.lua:99`: Living Villages calls `settlements.find_surface(pos, first and wait or nil)`.

Measured (`towns-auto-probe-v85bagro`, the same as the first run): the planner window is 20.04 s; the two
forced reads are 10 s apart; the engine logged `Maximum lag peaked at 20.2933` at 19:10:18, and the probe's
`main_loop.longest_step_s` is 20.29 s (first run) and 20.37 s (rerun). The planner's own terrain completes after its exit (see "Planner window
timing").

Consequence, accepted: village planning on ungenerated terrain can stall the main loop for about 20 s, with
or without towns. Towns must not add to it, and the pause budget for towns remains the design's provisional
~5 s (measured separately in #397).

## Lag investigation: the early ~15 minute flat run

The #391 flat villages run `towns-auto-probe-7le4djsz` logged no output for about 15 minutes, with
"Maximum lag peaked at 940.569". Explanation: **macOS idle system sleep**, not an engine or probe stall.

- Engine log: `Maximum lag peaked at 940.569 (steplen=0.05)` at 18:37:23, and the last ABM line at 18:21:42
  (`active block modifiers took 242ms`).
- Power log (`pmset -g log`): `2026-11-02 18:21:10 Display is turned off`;
  `18:21:40 Entering Sleep state due to 'Idle Sleep'`; `18:37:23 DarkWake from Deep Idle`;
  `18:37:43 SleepService: window has terminated`.
- 18:21:40 to 18:37:23 is 943 s, matching the 940.569 s lag. The run's observer reported 1031 s because its
  clock is wall time and the process was suspended.
- Not reproduced on demand. The later flat reruns had longest steps of 0.10 s, and the batches ran under
  `caffeinate -i`.

The #391 README now states this (updated in this ticket).

## Chunk and mapblock conventions

| Topic | Convention | Status |
| --- | --- | --- |
| Mapblock | 16 nodes; a mapblock index `b` covers nodes `16b .. 16b+15`. | PASS (engine API) |
| Chunk size | 80 nodes (chunksize 5) for villages. 64 nodes (chunksize 4) for generation only. | PASS for generation; villages require 5 (code reading) |
| Chunk origin | minp = -32 + size*k on each axis. Chunk index `k = floor((x + 32) / size)`. Chunks never start at 0. | PASS (observed for sizes 4 and 5) |
| Chunk membership of a mapblock | Mapblock lies wholly inside one chunk because -32 is a multiple of 16. | PASS (follows from origin) |
| Generated callback bounds | Use the callback's own `minp, maxp`. A requested box can be smaller than the generated chunk (fresh: requested y 0..47, chunk -32..47). | PASS |
| Surface-bearing callback | Heightmap has an entry with `minp.y < h < maxp.y`. Class from VoxelManip sampling is approximate. | PASS for flat and v7 |
| Sentinel heights | No ground in chunk (sky chunks). Treated as invalid. Exact value not recorded. | PASS (class); exact value UNVERIFIED |
| Clipped heights | Value equals `maxp.y` (ground above the chunk); bottom-equals-`minp.y` is ambiguous. | PASS (top); bottom UNVERIFIED |
| Center ground | Capture the heightmap only inside that chunk's own `on_generated`. Request-time reads are stale or zero. Old centers decline. | PASS (capture); FAIL (request-time read) |
| Center column semantics | Heightmap node vs top solid node disagree at one v7 chunk (vegetation likely). | UNVERIFIED, design judgment |
| Village trigger | Seed gate in `on_generated` places a structblock; LBM at block activation runs the planner on the chunk footprint. | PASS (chain observed) |
| Village ordering | Trigger LBM precedes the planner. The planner's own requests complete only after it returns (one window). | Partial PASS; activation-halo UNVERIFIED |
| Freshness check | `generated` record per chunk precedes emerge callbacks; FROM_MEMORY is not freshness. | PASS (tested scope) |
| Cancelled actions | Delivered at shutdown; not evidence of absence (31 of 1019 inside generated chunks). | PASS |

## Observations

- **Emerge action is shared.** In the concurrent run, two requests reported GENERATED for the same block.
  Freshness must come from the callback record, as the design says.
- **Most runs had one `generated` callback per new chunk.** Overlapping requests each received `generated` for
  the same block (3 such blocks in the concurrent run).
- **Sky-underground order.** The sky and underground chunks were recorded before the first surface chunk.
- **Heightmap is clipped.** Heights do not represent the true ground when the ground is outside the chunk.
- **Callback heightmaps are stale or zero outside generation.** See "Callback heightmap".
- **Planner generates terrain.** The v7 village planner requested terrain at `y = 64` (the layer above the trigger
  chunk). Those requests completed only after the planner returned.

## Correction to the #391 probe README (made in this ticket)

- `height_difference = 57` is VoxeLibre's sentinel return for flat or invalid heights, not a measured difference.
  Read `passed = false` with 57 as "flat or invalid".
- The "15 minute lag" is explained by idle sleep (see the lag investigation). It is not an unexplained engine stall.
- Callback heightmaps are not nil outside `on_generated` in this build (see "Callback heightmap").

## Limitations

- Only one natural village was observed, and no run used ordinary exploration. Counts and success rate are not
  usable for density tuning.
- No connected client: no player request latency, no exploration-style concurrency, no route runs.
- Chunk-size results cover 4 and 5 only. Other sizes are untested.
- The sentinel value and the bottom-clip semantics are not recorded.
- The center check uses one diagonal column, so the index layout is not distinguished.
- Planner timing covers one village window on one seed. A surface-activation chunk arriving from elsewhere during
  a window was not observed.
- The probe's cancellation runs are short (1 s). Mid-generation cancellation was not tested.

## Blockers and next steps

1. Do not close #392. A10 (activation-halo ordering) and A14 (player-visible loading) are still UNVERIFIED. A12
   (containment) is PASS (tested scope).
2. Pure geometry can proceed. #393 may start on envelope arithmetic with chunksize 5 and origin -32 (settled).
   Freezing caps is no longer blocked by A12: write bounds are measured and contained. Three follow-ups from A12 (two applied)
   are listed under "Findings and proposed corrections" (callback-time loading, wet ring, cap basis text).
3. #397 (center-first loading): center ground must be captured only inside the center chunk's own on_generated
   (A9 FAIL for request-time reads). Old centers decline. The planner pause is accepted (A15), so it is not a
   blocker for #397.
4. #400 (reservations and village guard) is blocked by A10 (activation-halo ordering), with only one window observed.
5. #402 to #404 are blocked transitively (A10; A12 is no longer a blocker). #405 needs A14 first.
6. **Design judgment to escalate:** (a) which node counts as ground for the center reference (heightmap vs top solid,
   for vegetation); (b) whether the planner-window evidence is enough to drop or keep the activation decline in
   the wrapper (A10), or whether more windows are required.
7. Next probes: (a) a connected client route for A14; (b) more village windows on other seeds for A10. The A12
   write-capable test exists (`tools/auto_towns_containment/`); rerun it after any change to the stage boxes or the
   builder.

The epic and the #393-#405 blocker texts were not updated in this ticket. The senior developer should decide that
update, now that the verdicts above are known.
