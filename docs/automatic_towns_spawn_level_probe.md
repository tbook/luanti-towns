# Spawn level probe: is `core.get_spawn_level` an ocean pre-screen? (#448, #431 T2)

Status: measured in the real engine (Luanti 5.18.0, VoxeLibre 0.92.3, mapgen v7)
on disposable worlds. Tool: `tools/spawn_level_probe/` (see its README). Design
context: `docs/automatic_towns_multi_candidate.md`.

## Method

- Each candidate centre gets the 9 points of a 3x3 grid at offsets -132, 0, +132.
- `get_spawn_level` is called from a `core.after` timer callback (main thread).
  Each point is called 5 times; the first value is kept and the calls must agree.
- The engine's own generated column is the ground truth. Each sample column is
  emerged in a disposable world and classed as `ocean` (water above the highest
  solid node), `land`, or `none`, over y -32..80.
- Saved-world truth: the same columns are classed from a SQLite copy of the
  Testlandia save with the same seed. Where both are loaded, 69 of 70 columns
  match the engine-generated truth. The one difference is a surface detail
  (saved ground 4, engine ground 2) and is not a terrain mismatch.
- The live Testlandia save was only read, never written. A read-only SQLite
  backup was taken into a scratch copy, and the probe runs only on disposable
  worlds. The game had no open handle on the save when the copy was made.

## Results

Level = value returned by `get_spawn_level` (`-` = nil). Truth counts are for the
9 points of the site. "Pass" means at least 5 of 9 points return a height, the
design's `prescreen_wet` threshold.

| Site (centre) | Real outcome | Points with height | Height min..max | Truth ocean / land | Screen |
| --- | --- | --- | --- | --- | --- |
| T no_ground (-511,-511) | no_ground | 2/9 | 4..10 | 7 / 2 | reject, correct |
| T no_ground (-515,1540) | no_ground | 5/9 | 6..19 | 3 / 6 | pass, wrong (see below) |
| T no_ground (1542,1543) | no_ground | 2/9 | 11..18 | 6 / 3 | reject, correct |
| T too_deep_water (515,2562) | too_deep_water | 3/9 | 8..17 | 5 / 4 | reject, correct |
| T too_deep_water (1528,519) | too_deep_water | 0/9 | - | 8 / 1 | reject, correct |
| T busy (506,-506) | busy, never inspected | 0/9 | - | 4 / 5 (heights 18-80) | reject, unknown |
| T busy (520,505) | busy, never inspected | 2/9 | 9..17 | 6 / 3 | reject, unknown |
| T busy (-508,514) | busy, never inspected | 5/9 | 6..16 | 2 / 7 | pass, unknown |
| T busy (519,1531) | busy, never inspected | 5/9 | 6..19 | 2 / 7 | pass, unknown |
| Land contrast (500,1600) | not a candidate | 4/9 | 4..17 | 0 / 9 (heights up to 26) | reject, dry land lost |
| Land contrast (1200,1000) | not a candidate | 7/9 | 5..16 | 0 / 9 | pass |
| Land contrast (0,1100) | not a candidate | 4/9 | 4..14 | 0 / 9 (heights up to 38) | reject, dry land lost |
| Roman town (1543,-5632) | complete | 8/9 | 5..19 | 0 / 9 (all land) | pass, correct |

Roman truth comes from the engine generating the seed in a new world (see caveats).

Aggregate over all 13 sites (117 points, 74 of them land):

| Point class | Count | Returned a height | Returned nil |
| --- | --- | --- | --- |
| Ocean (engine truth) | 43 | 0 | 43 |
| Land, ground height <= 16 | 57 | 47 | 10 (ground 0-3 and 9-10) |
| Land, ground height > 16 | 17 | 0 | 17 (ground 18-80) |

Heights returned are about 2 to 6 nodes above the engine's ground height
(median 3), so they are usable as an approximate level but not an exact one.

Cost and context (all calls succeeded, 0 errors):

| Context | Result |
| --- | --- |
| Main thread, `core.after` timer | callable, consistent across 5 repeats at every point |
| `on_generated` (emerge thread) | callable, 120 calls over 40 generated chunks, 0 errors |
| Per-call cost, 10,000 batch | 0.15 us per call (1.5 ms total) |
| Full 9-point screen | about 1.4 us |
| Inspection it would avoid (`inspect_site`, from logs) | 3-8 s per candidate |

## Conclusion

**Usable as a cheap ocean rejector, not as a land ranker.**

- It agrees with real terrain where it counts for the ocean. None of the 43
  ocean points returned a height, so `nil` means water or no ground, and a
  height means dry land. Within the Testlandia set, all 39 heights were on land.
- It is cheap enough to ignore. About 1.4 us per screen versus 3-8 s per
  inspection. It works from a timer and from `on_generated`.
- Its positive signal is partial. It returned no height for 17 of 27 land points
  above ground 16 (all 17 such points), which is the highland loss the design
  accepted. It also returned nothing for 10 low land points (ground 0-3 and
  9-10), which the design did not anticipate. Only 47 of 74 land points (64%)
  had a height.
- At the design's 5-of-9 threshold, 4 of the 5 declined Testlandia candidates
  are rejected correctly. The exception is (-515,1540): 5 points return
  heights, so it passes, and the real inspection then declined it with
  `no_ground` at (-451,1459). That column is not on this 3x3 grid. The grid is
  too coarse to see a single bad column at a coast, so a passing candidate can
  still fail its inspection. This costs one inspection and is not a false
  "dry" from the noise.
- The Roman success passes (8/9), as it should.

Recommendation for T5: keep the pre-screen as designed, since it removes the
ocean cells cheaply and reliably. Do not expect it to rank land or to replace
the inspection's `no_ground` check at coasts. Whether the 5-of-9 threshold lets
enough towns through is a playtest question (#431 T7). This probe does not
measure the town rate.

## Caveats and what remains uncertain

- **Sample size.** 13 sites in one seed plus a land contrast. The land points
  are 3 contrast centres and the Roman site, so the highland and low-land
  miss rates are rough.
- **Busy candidates** have no real outcome. Their rows are predictions only.
- **Roman seed (11605533223103715697).** The seed comes from `debug.txt.1`
  (Testlandia world, 2026-11-06 13:20). That save has since been reseeded, so its
  original `map_meta.txt` is not available. This run used the current Testlandia
  noise parameters with the seed replaced.
  The original world's parameters are unknown, so its terrain, and therefore its
  truth column, may not match the original. Its 8/9 pass is consistent with the
  success but is not a verified agreement.
- **Inspector footprint.** The inspection uses its own footprint and window
  (bottom near y -8). The probe classes columns over y -32..80 and compares
  against the inspector's reason codes only loosely.
- **Truth classification** is heuristic: plants and leaves are excluded from
  ground, and ice is treated as water-like. One saved-world column disagreed
  (see Method).
- **Timing** is from `core.get_us_time`. The 0.15 us figure is far below the
  resolution of a single call, so it comes from the batch loop. It is low for
  multi-octave noise, and the engine may be caching. Only the order of magnitude
  matters here.
- **Thread check.** The `on_generated` values were not compared against the
  timer values for identical coordinates, so the claim that both contexts return
  the same values is not verified.
- **Mapgen.** Only mapgen v7 with VoxeLibre was tested. Flat mapgen (the
  TownsPlaytest and TownsWorkshop worlds) was not tested. The design says flat
  passes every point, but this is unverified.
- **Engine version.** The binary is Luanti 5.18.0. The design text cites the
  master source, so the behaviour described there may differ from 5.18.

## Reproducing

See `tools/spawn_level_probe/README.md`. Raw per-point JSON is written to a
scratch world and is not committed.
