# Roman catalog validation — issue #147

Validated 2026-10-21 with Luanti 5.17.0, the installed VoxeLibre game and Living
Villages in a newly created, headless disposable world. No workshop map was
loaded or changed. The source `.mts` and sidecar files were unchanged for that
run. The bath was later re-exported with a tighter box (#171), so the bath
figures recorded below (including the 475,900-node total) are historical for
the original 95x21x48 export; the bath is now 88x18x43.

Reproduce from the repository root:

```sh
lua5.1 tests/run.lua
python3 tools/roman_check/run.py
```

The Python command accepts `--engine`, `--settings-from`, and `--port`.
It copies only `world.mt` and `map_meta.txt` from the settings world, installs
this checkout as a world mod, and retains a scratch world with `engine.log`
and `roman-check.json`. The JSON records origins, entrances, front vectors,
ground probes, approach floor heights, initialization counts, and bed results
for every placement. This is an engine/node inspection, not a visual walk-through.

### What the node check compares (#188)

Every voxel of every capture (including air and basement) is compared with
the node that `schematic.place` leaves at that position, at all four
rotations. Node names must match exactly, and param2 must match a native
`core.place_schematic` placement. Walls are the one place where the expected
name is not the raw template name: `schematic.place` renames each wall from
its placed neighbours (`schematic.wall_name`, #178), and the template wall
names are not authoritative (#187). `tools/roman_check/expect.lua` applies the
same recompute to the template's neighbours in rotated orientation. No other
tolerance is applied; in particular grass/dirt, gravel and falling nodes are
compared exactly. The `tests/roman_check_expect_tests.lua` group checks this
helper against real `schematic.place` output for every Roman capture.

The checker does not stop at the first failure. Each landmark and rotation is
checked independently; node mismatches go to `mismatches` and raised errors to
`errors` in `roman-check.json`, and `ok` is true only when both are empty. The
temple's ground probe is its Y=0 terrain row (grass datum at `(0,0,0)`), since
#134 moved the quartz platform up to Y=1.

Baseline on `main` before #188: 487 node mismatches, all wall names
(amphitheater, arch, theatre; all rotations), and a temple ground-probe error
at every rotation. After the change the run is unfiltered and passes.

## Recorded result

The run in `towns-roman-check-vgnqo0ax` passed all 24 placements (six assets
at 0°, 90°, 180°, 270°) on a prepared flat site at Y=100:

| Asset | Origin Y | Entrance Y | Ground sample (file-local) | Initialized nodes per placement | Valid beds / skipped |
| --- | --- | --- | --- | --- | --- |
| arch | 100 | 101 | grass `(0,0,0)` | 0 | 0 / 0 |
| temple | 100 | 101 | first quartz stair `(0,0,5)` | 0 | 0 / 0 |
| domus | 99 | 101 | grass `(0,1,0)` | 27 | 8 / 0 |
| theatre | 97 | 102 | grass `(0,3,0)` | 0 | 0 / 0 |
| amphitheater | 98 | 101 | grass `(0,2,0)` | 12 | 0 / 0 |
| bath | 98 | 102 | grass `(0,2,0)` | 194 | 6 / 0 |

All captured nodes including air/basement volume matched source names;
param2 matched independent native engine placements: **475,900 nodes**.
After the shared node initializer ran, **1,488 saved metadata records** and
**17,504 inventory slots** matched the sidecars, including item metadata.
No failed, unregistered, or unhandled functional nodes remained. The dark-oak
gate, upward dispenser, and smithing table use the shared initializer's
existing callback mechanisms. The enchanting table's constructor only creates
a decorative book, which its right-click handler recreates, so it needs no
placement initialization.

At every rotation, the selected entrance matched a real door/opening with a
walkable floor. The outward ray through each captured margin reached the
exterior site ground with two nodes of headroom and floor changes of at most
one node. Ground probes aligned exactly with Y=100. Bath samples confirmed
the lower dirt plinth at local `(0,1,0)`, surface at `(0,2,0)`, and basement
bed at `(44,1,35)` below site ground (the #139 95x21x48 capture; the #171
88x18x43 trim keeps `(0,1,0)` and `(0,2,0)` and moves the bed to
`(40,1,33)`). Six basement beds remained valid.

## Preserved capture caveats

- The bath entrance wall contains stacked door nodes: lower door bottoms at
  X=8, Y=4, Z=21..23 in the original export (X=4, Y=4, Z=19..21 after the
  #171 trim, offset (-4,0,-2)) and additional door bottoms at Y=6. The central lower
  node is the closed `_b_3` variant. These authored nodes are retained; no
  door repair is attempted. The exterior approach passes inspection.
- The temple capture has empty padding and no surrounding grass datum. Its
  first stair and platform are at local Y=0; the chosen placement embeds
  that first step at site-ground level. It does not infer a ground datum
  from the source world's minimum Y. (#134 re-captured the temple with the
  terrain row below the platform; the table above is the original run.)
- The theatre includes uneven subsurface terrain/voids beneath its platform.
  Its perimeter grass is at Y=3 and front apron at Y=4; those are retained.
  The approach rises one node from site ground onto the apron.
- The arch's four-node paving has decorative wall intrusions; its continuous
  clear corridor is two nodes wide. Its pier door is separate from the
  traversable arch opening. The captured path also includes two infested
  cobblestone nodes (`mcl_monster_eggs:monster_egg_cobble`) at local Y=0.
- Temple and bath entrances/adjacent approach nodes are inside their capture
  rectangles. Authored layout validation currently prohibits public pavement
  overlapping landmark rectangles; later layout work must reconcile recessed
  approaches with that rule. This issue adds asset metadata and shared
  composition support, without changing town placement or routing rules.

No new bed exclusions were justified by the engine check. Villa/aqueduct
remain outside the catalog, and medieval role pools retain their existing IDs.

`lua5.1 tests/run.lua` passed **4,569 checks, zero failures**, including the
real-file verification, four-rotation geometry/composition checks, a shared
composition-to-builder door-route check with the unrelated edges blocked,
role-pool exclusions, and malformed-facing tests. This uses the runner's
default suite; the optional `TOWNS_TEST_FULL=1` slow groups were not run.
