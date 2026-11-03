# Automatic towns probe results (#392, slice 0)

Evidence gate for [automatic towns](automatic_towns_design.md) (epic #355), run with the
disposable probe from #391 (`tools/auto_towns_probe/`, see its [README](../tools/auto_towns_probe/README.md)).
No production code changed, no Towns code was loaded, and no town was written. The source world
`TownsWorkshop` was only read for its settings (`world.mt`, `map_meta.txt`); its map was not used.

## Gate status

Not passed as a whole. This ticket must not be closed as a passing gate.

- Freshness (callback recording before emerge completion, including FROM_MEMORY): **PASS** within the
  tested scenarios.
- Containment feasibility: **UNVERIFIED** (no town writes were attempted by design of this probe).
- Village ordering and activation halo: **UNVERIFIED**. A measured village planner stall of 20.3 s was
  observed, which bears on the pause budget (see below).
- Center ground without vertical search: **UNVERIFIED** (not exercised).
- Player-visible loading: **UNVERIFIED** (no connected client was available).
- Cancellation and late completion: **UNVERIFIED** (not reproduced in an observable way).

## Environment

| Item | Value | Source |
| --- | --- | --- |
| Engine | Luanti 5.17.0 (OSX), LuaJIT 2.1.1764270282, `/Applications/luanti.app/Contents/MacOS/luanti` | probe report `engine_version`, engine log |
| Game | VoxeLibre (`mineclone2`) 0.92.3 at `~/Library/Application Support/minetest/games/mineclone2` (not a git checkout, so no revision) | engine log `VoxeLibre mapgen version`, report `game` |
| Living Villages | `668c5fc` (installed copy, copied into each scratch world) | `git -C .../mods/living_villages rev-parse` |
| Towns (probe branch) | `f744741` (base of this branch) | probe report `repo_revisions` |
| Settings, source world | `seed = 2014`, `mg_name = flat` (superflat), `chunksize = 5`, `mapgen_limit = 31007`, `water_level = 1` | `TownsWorkshop/map_meta.txt`, report `mapgen` |
| Village runs | same seed and settings with `--mg-name v7` (v7 is needed for village planning; flat terrain fails the gate) | commands below |
| Chunk-size test | same as above with `chunksize = 4` (settings copy in scratchpad, source world untouched) | command below |
| Scratch mods | `mcl_decor`, `living_villages`, `worldedit` (3 copies), the probe. Towns is not loaded. | scratch `world.mt` |
| Host | macOS Darwin 25.6.0 | `uname` |

Each run used a fresh scratch world in `$TMPDIR` (below). All runs completed with `ok: true` for
their own checks, except the deliberate cancellation probe, which reports its fixture as incomplete.

## Commands

All from the Towns mod directory. Each run keeps its scratch world (no `--cleanup`).

```sh
python3 tools/auto_towns_probe/run.py --scenario fresh --duration 40
python3 tools/auto_towns_probe/run.py --scenario sky-underground --duration 60
python3 tools/auto_towns_probe/run.py --scenario concurrent --duration 60
python3 tools/auto_towns_probe/run.py --scenario old-neighbor --duration 60   # two phases
python3 tools/auto_towns_probe/run.py --scenario restart --duration 60        # two phases
python3 tools/auto_towns_probe/run.py --scenario villages --mg-name v7 --duration 180
python3 tools/auto_towns_probe/run.py --scenario villages --duration 180      # flat, for comparison
python3 tools/auto_towns_probe/run.py --fixture "cancel:-256,0,-256,255,15,255" --duration 3 --start-delay 2
# chunksize-4 variant: a copy of TownsWorkshop's world.mt and map_meta.txt with "chunksize = 4"
python3 tools/auto_towns_probe/run.py --scenario fresh --duration 40 --settings-from <copy-dir>
```

The batch was run sequentially with `caffeinate -i` so the Mac did not idle-sleep (see the lag
investigation). The per-event ordering was checked with a scratch analysis script kept outside the repo. It checks that every `generated` action has an earlier
`generated` record covering its mapblock, and that every `from_memory` block in a new chunk is covered
by an earlier record.

## Retained artifacts

All in `$TMPDIR` = `/var/folders/nf/h9p5hfvs7jj6vs6q252mzhw00000gn/T/`. Each contains
`probe-report.json`, `auto-towns-probe-phaseN.json`, `auto-towns-probe-phaseN.jsonl`, and the engine logs.

| Run | Scratch world |
| --- | --- |
| fresh | `towns-auto-probe-b2jw0a2i` |
| sky-underground | `towns-auto-probe-6gsxjw97` |
| concurrent | `towns-auto-probe-xw3m1dyg` |
| old-neighbor (2 phases) | `towns-auto-probe-vb069efc` |
| restart (2 phases) | `towns-auto-probe-lhwxzfxb` |
| villages, v7 | `towns-auto-probe-9o11ltj2` |
| villages, flat | `towns-auto-probe-k4krxzc5` |
| cancel (3 s, 1024 blocks) | `towns-auto-probe-xsz4tshz` |
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
| villages, v7 | 180 s | 62 (surface 55, sky 7) | 1262 from_memory, 62 generated | 2 | 1 passed (height diff 6), 1 rejected (see below) | 1 / 1 | **20.29 s** |
| villages, flat | 180 s | 49 (surface 49) | 975 from_memory, 49 generated | 1 | 0 passed, 1 rejected (flat) | 0 / 0 | 0.10 s |
| cancel | 3 s | 22 (surface 22) | 427 from_memory, 22 generated, **449 of 1024 callbacks observed** | not counted | not reached | 0 / 0 | not sampled |
| chunksize 4, fresh | 40 s | 18 (surface 9, sky 9) | 90 from_memory, 18 generated | 0 | not reached | 0 / 0 | not sampled |

Success rate for natural villages: **1 placed village from 2 seed-gate opportunities (50%)**, and 1 of
1 that passed the terrain gate. This is n = 2 from 62 chunks, so it has no statistical weight. The
expected seed-gate rate is 1 in 77 (about 1.3%), and 2 in 62 (about 3.2%) is consistent with that
within noise. Every other run has zero opportunities, which is a sample-size limitation, not evidence of
rarity. None of these runs used ordinary exploration; all terrain came from scripted fixtures, planner
requests, or structure placement.

## Assumption verdicts

| # | Assumption | Verdict | Evidence | Downstream blocked |
| --- | --- | --- | --- | --- |
| A1 | Generated-chunk recording happens before the corresponding emerge callback is consumed, including when the later action is FROM_MEMORY | **PASS** (tested scope) | Analysis script: 0 violations across the runs. Every `generated` callback, and every `from_memory` callback, had an earlier `generated` record covering its block. Counts of covered `from_memory` callbacks: fresh 104, sky-underground 240, concurrent 248, old-neighbor phase 2 88 (the other 17 are old chunks, see A2), v7 1262, flat 975, chunksize 4 90. | Not blocked by A1. Cases not covered (player-driven interleaving, cancellation) are under A13 and A14. |
| A2 | Old chunks loaded from disk or memory produce no record in a new process or session | **PASS** | Restart phase 2 loaded 108 blocks, all `from_disk`, with 0 `generated` events. Old-neighbor phase 2 had 37 `from_disk` blocks with no covering record. Its 17 `from_memory` blocks without a record all lie in chunks loaded from disk earlier in the same phase (checked by chunk membership). | None |
| A3 | Partial old/new coverage: only new chunks are recorded | **PASS** | Old-neighbor phase 2 overlapped old chunks. Records existed only for the 2 new chunks. | None |
| A4 | Sky and underground chunks are recorded even before any surface chunk | **PASS** | sky-underground: sky and underground records precede the first surface record in the event order. 4 sky and 4 underground chunks were recorded, and the probe's classes agree with heightmap validity (sky: 0 valid entries; underground: clipped). | None |
| A5 | Overlapping, same-tick requests each see consistent generation | **PASS** (tested scope) | concurrent: each chunk had one `generated` record. 3 blocks reported `generated` to two overlapping requests, so the emerge action is shared, not per request. | Action-level freshness must not be inferred from the emerge action alone (the design already says this). |
| A6 | Real chunk alignment is not zero-aligned | **PASS** | chunksize 5: minp.x,y,z = -32 + 80k (observed minp -112, -32, 48, 128; maxp = minp + 79). chunksize 4: minp = -32 + 64k (observed -96, -32, 32). Both align to -32, not to 0. | Settles the input for #393 |
| A7 | Supported chunk settings | **PARTIAL**: chunksize 5 is the only supported setting for the village gate. chunksize 4 was observed for generation only. | chunksize 4 generated normally with the same callbacks. VoxeLibre's `evaluate_heightmap` (`mcl_villages/utils.lua`) hard-codes 80-wide rows (`square_start = 1621`, stride 80). Its `half_map_chunk_size = 40` (`const.lua`) also assumes 80 nodes. So villages are not supported for other chunk sizes (code reading, not run). | Constrains #393 to chunksize 5 |
| A8 | Surface-bearing callback can be identified, and valid, clipped, and sentinel heights are distinguishable | **PASS** for the classes below; exact sentinel value **UNVERIFIED** | See "Heightmap classes". 38 + 4 + 1 + 11 + 1 surface chunks, all classified by the rule below. | Sets #395 rules |
| A9 | Center ground is obtained from the center request without a vertical search | **UNVERIFIED** | The probe reads `heightmap` only inside `on_generated`. Bundled Luanti docs say `get_mapgen_object` returns nil outside that callback, so a non-fresh center chunk gives no ground. The design's "decline if no valid center ground" follows from that, but a center request was not exercised. | #397 (center-first loading) |
| A10 | Activation-halo ordering: the village planner runs only after the town reservation exists | **UNVERIFIED** | The trigger chain is confirmed (see Village trigger chain). The planner itself requests terrain beyond the trigger chunk, which is a real ordering risk. No town was present, so the halo ordering could not be tested. | #400, #402, #403, #404 |
| A11 | Village trigger reaches the guarded planner (`settlements.create_site_plan`) | **PASS** | The probe's wrapper saw `planned` and `placed` events on v7. The planner runs under the LV install, and the chain is `structblock LBM -> emerge_area(footprint) -> ecb_village -> create_site_plan`. | Not blocked |
| A12 | Containment feasibility (writes stay inside the envelope) | **UNVERIFIED** | Not in scope for a read-only probe. No write was attempted. | #393 (caps), #397, #403 |
| A13 | Cancelled or late completions are observed and safely handled | **UNVERIFIED** | The cancel run requested 1024 blocks, shut down at 3 s, and observed 449 callbacks (427 from_memory, 22 generated). 575 callbacks never reached the probe's drain, so no `cancelled` action was seen and the missing events cannot be read as cancellations. | #397, #398 |
| A14 | Player-visible loading latency is within the starting targets | **UNVERIFIED** | No connected client was available. Only scripted demand was measured. | #405 and the loading parts of #397 |
| A15 | Village planning pause is acceptable under the ~5 s provisional maximum | **FAIL** (measured, not a correctness assumption of the town code) | v7 village planning stalled the main loop for 20.29 s. See "Village planner stall". | #397 (pause budget), #400. Needs a product or architecture decision (escalation). |

## Heightmap classes (surface-bearing callback)

Measured from the probe's `heightmap` summary (6400 entries per 80-node chunk) in the callback:

| Class in this data | Heights | Meaning |
| --- | --- | --- |
| Sentinel (invalid) | No entry in the probe's valid range (`|v| < 30000`) | No ground inside the chunk, for example sky chunks above the ground. 7 sky chunks in v7 and 9 in chunksize 4 had 0 valid entries. The exact sentinel value was not recorded, and VoxeLibre compares only against -31000 and 31000. Treat it as invalid. |
| Clipped at the chunk top | Value equals `maxp.y` | Ground is at or above the chunk top. Underground chunks (-112..-33) had every column at -33 = maxp.y. In v7, 11 surface chunks had maximum = maxp.y = 47, and 1 had maxp.y = 127. These are not usable ground. |
| Clipped at the chunk bottom (ambiguous) | Value equals `minp.y` | 4 v7 surface chunks have minimum = minp.y. Their semantics are not established. Treat as ambiguous and send to exact inspection. |
| Valid ground | `minp.y < value < maxp.y` | 38 v7 surface chunks and all flat surface chunks (value 8). A ground at exactly `maxp.y` is indistinguishable from a clip, so treat it as clipped. |

The probe's "surface" class is a sample of 8x8x8 VoxelManip points per chunk. It is approximate. One v7 chunk
(`p1-001175`, the second opportunity) was classed "surface" but had 0 valid heights. Use heightmap
validity, not the sampled class, to identify a surface-bearing callback.

## Village trigger chain

Verified from VoxeLibre `mcl_villages` source plus the probe events:

1. `register_generator("villages")` in `on_generated` (emerge thread): returns unless `maxp.y >= 0` and
   `blockseed % 77 == 17`. It places a structblock at the chunk's minp. The probe's `opportunity` flag
   reproduces this gate (2 hits in v7).
2. `settlements.evaluate_heightmap` runs over the center 40x40 of the chunk heightmap. The return value is
   `max_height_difference + 1 = 57` when the difference is 1 or less, which covers flat terrain and
   sentinel-only heights. So the probe's `height_difference = 57` is a sentinel return, not a measured
   difference (correction to the #391 README).
3. The structblock LBM (`run_at_every_load`) runs when the block is activated. It removes the structblock
   and calls `emerge_area(minp, maxp, ecb_village)` for the village footprint (one chunk).
4. `ecb_village` runs `build_a_settlement`: `settlements.create_site_plan` (Living Villages planner, which
   the probe wraps), then `terraform`, `paths` (disabled by Living Villages), and `place_schematics`.

Probe evidence for the v7 village: `p1-001116` is an emerge request for the footprint from `init.lua`
(the LBM). `p1-001312` and `p1-001313` are single-node emerges at `y = 64` from `init.lua`, the
`mcl_vars.get_node(pos, true, ...)` path. `p1-001314` is `village planned` (25 buildings). The chunks
generated during the planning window include the second opportunity chunk. The planner's log lines are
labelled `[Emerge-0]`, so the planner ran on an emerge thread.

## Village planner stall (pause budget finding)

`settlements.find_surface(pos, wait)` (`mcl_villages/utils.lua`) calls `get_node(p6, true, 10000000)`
for the center. That is `mcl_vars.get_node` with `force`, which calls `emerge_area(pos, pos)` and then
busy-waits up to `us_timeout` (10 s) on the ungenerated node (`mcl_init/init.lua`). The engine log
records `Maximum lag peaked at 20.2933` at 19:10:18, the same time as the `village planned` log line,
and the probe's `main_loop.longest_step_s` is 20.29 s at observer elapsed 28.67 s. The two single-node
force-emerges (`p1-001312`, `p1-001313`) fit two busy-wait timeouts. The exact count of waits was not
instrumented, so "two 10 s waits" is inferred.

Consequences:

- A village plan can block the main loop for about 20 s when it reaches ungenerated terrain. Living
  Villages' own design notes say the same about `find_surface` ("busy-waits 10 s for each ungenerated
  chunk"). This is far above the ~5 s provisional pause maximum for towns.
- The planner generates neighboring terrain itself. A town envelope can therefore be touched by
  generation during the village plan, which is the ordering risk in A10.
- Mitigating this (for example, pre-generating the planner's neighbors, or guarding the wait) changes
  existing village behavior. This is a cross-cutting decision and should be escalated (see Blockers).

## Lag investigation: the early ~15 minute flat run

The #391 flat villages run `towns-auto-probe-7le4djsz` logged no output for about 15 minutes, with
"Maximum lag peaked at 940.569". Explanation: **macOS idle system sleep**, not an engine or probe stall.

- Engine log: `Maximum lag peaked at 940.569 (steplen=0.05)` at 18:37:23, and the last ABM line at 18:21:42
  (`active block modifiers took 242ms`).
- Power log (`pmset -g log`): `2026-11-02 18:21:10 Display is turned off`;
  `18:21:40 Entering Sleep state due to 'Idle Sleep'`; `18:37:23 DarkWake from Deep Idle`;
  `18:37:43 SleepService: window has terminated`.
- 18:21:40 to 18:37:23 is 943 s, matching the 940.569 s lag. The run's observer reported 1031 s
  (start 18:20:11) because its clock is wall time and the process was suspended. The `main_loop` field was
  not in that report (it came from an older observer).
- Not reproduced: the later flat reruns had longest steps of 0.10 s, and the batch ran under `caffeinate -i`
  with no sleep. The sleep correlation is strong but was not produced on demand.

The #391 README says "The cause is not established." That should now read: explained by idle sleep (see
above). The batch in this ticket was run under `caffeinate` to avoid it.

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
| Center ground without vertical search | Only from the center chunk's own heightmap at generation. Non-fresh chunks return no heightmap. | UNVERIFIED (not exercised) |
| Village trigger | Seed gate in `on_generated` places a structblock; LBM at block activation runs the planner on the chunk footprint. | PASS (chain observed) |
| Village ordering | Trigger LBM precedes the planner. The planner's own force-reads generate neighbors during planning. | Partly PASS; activation-halo ordering UNVERIFIED |
| Freshness check | `generated` record per chunk precedes emerge callbacks; FROM_MEMORY is not freshness. | PASS (tested scope) |

## Observations

- **Emerge action is shared.** In the concurrent run, two requests reported GENERATED for the same block.
  Freshness must come from the callback record, as the design says.
- **Generated actions are not per chunk.** Most runs had one `generated` callback per new chunk. Overlapping
  requests each received `generated` for the same block (3 such blocks in the concurrent run).
- **Sky-underground order.** In the sky-underground run the sky and underground chunks were recorded
  before the first surface chunk in the event order.
- **Heightmap is clipped.** Heights do not represent the true ground when the ground is outside the chunk, so
  any reference height must use only valid, non-clipped entries.
- **Planner generates terrain.** The v7 village planner requested terrain at `y = 64` (the layer above the
  trigger chunk), and some of those chunks were sky (no ground) or surface.

## Correction to the #391 probe README

- `height_difference = 57` is VoxeLibre's sentinel return for flat or invalid heights, not a measured
  difference. Read `passed = false` with 57 as "flat or invalid", not as a 57-node difference.
- The "15 minute lag" is explained above (idle sleep). It is not an unexplained engine stall.
- The `on_generated` thread claim is consistent with the `[Emerge-0]` log label of VoxeLibre's gate. It
  was not verified independently.

## Limitations

- Only one natural village was observed, and no run used ordinary exploration. Counts and success rate are
  not usable for density tuning.
- No connected client: no player request latency, no exploration-style concurrency, no route runs.
- Cancellation: the probe drops callbacks after shutdown, so late completions cannot be counted. A
  write-through callback log would be needed.
- Chunk-size results cover 4 and 5 only. Other sizes are untested.
- The sentinel value and the bottom clip semantics are not recorded.
- The planner's exact count of busy waits is not instrumented.

## Blockers and next steps

1. Do not close #392 as a passing gate. A10 (activation-halo ordering), A12 (containment), and A9 (center
   ground) are unverified.
2. Pure geometry can proceed. #393 may start on envelope arithmetic with chunksize 5 and origin -32
   (settled). Freezing caps, and the pause numbers they depend on, stay blocked by A12 and A15.
3. #400 (reservations and the village guard) is blocked by A10 and by the planner's own terrain generation.
4. #397 (center-first loading and early rejection) is blocked by A9 (center ground) and A15 (planner pause).
5. #402 to #404 (orchestration, construction, enabling natural generation) are blocked transitively.
6. #405 (playtest) needs A14 (connected-client latency) first.
7. **Escalation (architecture/PM):** the 20 s village planner stall in existing VoxeLibre/Living Villages code
   reaches the ~5 s pause budget. The options (pre-generating the planner's neighbors, guarding or replacing
   `find_surface`'s wait, or accepting the pause) change existing village behavior. This needs a decision
   before #397 or #400.
8. Next probes: (a) a connected client route for A14; (b) a write-through callback log to measure cancellation
   and late callbacks (A13); (c) a center request on a fresh chunk and on an old chunk (A9); (d) a
   deliberate town-activation chunk inside a village planner window (A10).

The epic and #393–#405 blocker texts were not updated, because the failures are unverified rather than
failed. The senior developer should decide that update once the next probes are run.
