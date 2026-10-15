# Layout comparison (ticket #109)

A reproducible, engine-free way to compare town layouts before and after the
layout tickets (#86 street spacing, #105 parvis, #106 hall, #107 exits, #108
edge compounds). Development and review tooling only.

## Run it

From the mod root (needs only `lua5.1`; about 7 seconds):

    lua5.1 tools/layout_compare/run.lua docs/layout_baseline

Arguments: `[OUTDIR] [seed,seed,...]`. Without a seed list the documented set
below is used. The committed baseline in `docs/layout_baseline/` was produced
by exactly that command on the planner before any of the tickets above.

To compare a change against the baseline, write to a scratch directory and diff:

    lua5.1 tools/layout_compare/run.lua /tmp/layout_after
    diff -ru docs/layout_baseline /tmp/layout_after

`metrics.tsv` has one row per seed and is the easiest file to diff;
`report.md` holds the readable table, the totals and the layout constants.
When a layout ticket lands deliberately, regenerate `docs/layout_baseline/`
into a new directory (for example `docs/layout_after_86/`) rather than
overwriting the baseline, and record the before/after in the PR.

## Inputs

- Planner call, identical to `/towns_place_town` (`src/town_place_command.lua`
  plus `src/site_search.lua`): `planner.plan(center, seed, {landmarks =
  planner.landmark_profile(catalog.snapshot())})`. The profile carries the
  cathedral, castle, city hall, jail, services and ordinary content. Site
  search is not used: it only chooses the centre, and the centre merely
  translates a layout.
- Seeds, chosen before any result was inspected, not tuned afterwards:
  `1, 7, 42, 101, 256, 1024, 2718, 31415, 99999, 123456, 777777, 1000003`.
- Centres, assigned round-robin by seed index: `(0,0)`, `(1500,-2500)`,
  `(-4200,3100)`. Plans are translation invariant (checked in
  `tests/layout_compare_tests.lua`), so the centres only vary coordinates.
- Catalog identity: the catalog has no version field, so the report lists the
  entry count and a 32-bit hash (djb2, base 33, start 5381) over the sorted
  entries `id|role|size x,y,z|entrance x,y,z|ground_offset` joined by `;`. A
  changed hash means the real catalog changed and plans are not comparable.
- Layout constants: every value of `planner.resolve_constants({landmarks =
  profile})` is printed in `report.md`.
- Failed seeds stay in the report (`status = FAILED`, with the planner's
  reason); they get no artifact files. The baseline set has none.

## Artifacts per seed

- `seed_N.txt`: overhead ASCII, 1 character = 2x2 nodes, north (+Z) up, east
  (+X) right, with a legend. Highest paint priority of the four nodes wins.
- `seed_N.svg`: standalone vector overhead (4 px per node, legend at the
  right), openable in any browser and attachable to an issue.

Both distinguish: plan boundary, free block ground, secondary and principal
streets, market, parvis, cathedral and castle compounds, city hall, jail,
tavern/well/chapel, actual placed houses/shops/workshops (exact footprint
boxes), access alleys, boundary approach windows, the town centre, and the
narrow strips measured below.

Hooks for later tickets (legend entries exist; nothing is drawn until the
plan carries the field, so the field names are provisional and the ticket that
adds the feature may adjust `layers()` in `tools/layout_compare/lib.lua`):
town core `plan.core` (rect), complete construction footprint
`plan.footprint` (rect, drawn as outline), designated exits `plan.exits`
(list with `rect` or `edge`).

## Metric definitions

All lengths are in nodes. All cells are classified from the finished plan's
rectangles; a node takes the last-painted class (squares over streets,
landmarks over blocks, buildings over blocks). "Free ground" is boundary
ground not covered by a street, square, landmark, jail or service (blocks,
placed ordinary buildings, access alleys and unblocked boundary all count as
free ground, since buildings can sit on it).

- `street_len`: estimated centreline length of the ordinary street network.
  Counting convention: unique pavement nodes of principal streets divided by 5
  plus unique pavement nodes of secondary streets divided by 4, in both cases
  excluding nodes covered by the market or parvis and counting a node covered
  by both kinds as principal. Junctions and bends are counted once; it is an
  estimate, not a graph length. `street_len_principal`, `street_len_secondary`
  and the cell counts are reported separately. `street_rect_run_sum` is the
  alternative sum of the long side of every street rectangle (bends and
  junctions double counted) for cross-checking.
- `frontage_ordinary`: total length of frontage runs that face an ordinary
  street (`run.street`), i.e. theoretical frontage. Runs that face the market
  or parvis are `frontage_square` and are not building frontage for ordinary
  content.
- `frontage_usable`: the part of `frontage_ordinary` whose block, measured
  perpendicular to the run, is at least D deep. D is the catalog-derived row
  depth (see "Depth policy" below), not a placeholder. Blocks thinner than
  D are never carved with the depth policy active, so this equals
  `frontage_ordinary` for current plans; it stays as a guard against a
  future change of the minimum block side. Do not read it as packing
  capacity.
- `frontage_used`: summed width along its street of the ordinary buildings
  actually placed, in the same units as `frontage_ordinary`. The ratio
  `frontage_used / frontage_ordinary` shows how much theoretical frontage
  became real rows. More theoretical frontage with the same used length is not
  an improvement, and a shorter network with the same placed buildings is not
  a regression; judge rows by `ordinary` (placed buildings), `frontage_used`
  and the strip and unused figures together.
- `ordinary`, `houses`, `shops`, `workshops`: actual placed ordinary
  buildings from `plan.content.counts` (after alleys). `jail`, `services`,
  `shortages` count reservations and unmet targets. `alleys` is the number
  of access alleys; `empty_runs` the ordinary runs that received no building;
  `unused_len` the total length of run intervals no building covers
  (continuity of rows: lower is more continuous).
- `blocks`, `block_cells`: planner blocks and their area. `blocks_single_row`
  counts blocks whose shorter side is under 2 x D, which cannot hold two
  opposing rows back to back.
- `strips`, `strip_cells`: narrow strips. Free ground is opened with a
  D x D window (cells inside any all-free D x D square are
  buildable); the residue is the free ground outside every such window. A
  narrow strip is a 4-connected component of residue whose longer bounding box
  side is at least D. So it is ground bounded by a road, square, landmark
  or the town boundary on both sides at under D depth, such as the
  reported 1- and 3-node gaps. `specks` and `speck_cells` count smaller
  residue components, which are leftover corners rather than strips. The
  metric measures buildable depth only, not whether rows were placed, and a
  strip that a later wall ticket (#95) claims is still counted. Strip cells are
  magenta in the SVG and `!` in the ASCII. A plan "has narrow strips" when
  `strips > 0`.
- `parvis_x`, `parvis_z`, `parvis_area`: parvis rectangle extents and node
  count.
- `market_x`, `market_z`, `market_area`: market rectangle extents and node
  count. `market_open` is the number of market nodes left as market after
  the city hall (or anything else painted over it) is subtracted;
  `market_open_share = market_open / market_area`;
  `market_open_square` is the side of the largest all-open square inside the
  market. Openness is area based, so a market that is open but squeezed into a
  thin strip shows a small `market_open_square`.
- `attempts`: planner attempt number that succeeded (not a quality metric).

Not yet measured (hooks only): inward landmark approaches, core bounds,
construction footprint, exits. Add them with the ticket that introduces the
feature and extend this section.

## Limits

- Everything is derived from the plan, not from a built world; it complements
  rather than replaces disposable-world observation and #50 validation.
- D is a depth only: it measures whether a row fits behind a street. It does
  not include setbacks, because the packer places boxes flush against the
  street row with their door on the pavement.
- The narrow-strip metric opens free ground with D x D windows, so a sliver
  that lies between a block edge and a road is covered by the block's own
  cells and is not reported; it shows up as a block without frontage and
  in the placed-building count instead. `streets.narrow_gaps(plan, C)`
  reports the road-side runs directly and is zero for every accepted plan.
- Ground between a landmark or market and the town edge is not between
  roads and is not gated; it is what walls (#95) and edge compounds (#108)
  will claim, and it keeps being reported as strips.

## Depth policy (ticket #86)

Derived from the catalog, not fixed. `planner.row_depth(profile)` takes the
eligible ordinary entries (house, shop, workshop) and their depth behind the
street. The packer turns file X into the run axis and puts file Z (depth)
behind it, with the door on the street row, so a block that is `d` deep
admits exactly the entries with `size.z <= d`; the door approach is the
pavement node in front of it and no further clearance sits inside the block.
D is the smallest depth that admits at least half of the eligible entries
(lower median): neither the smallest sample house (7, the demo house) nor
the deepest (13). With the stock catalog (11 entries) the depths are
7, 9, 9, 9, 9, 9, 11, 11, 12, 13, 13 and D = 9.

`planner.depth_policy(profile)` turns D into the constants listed in the
report: `MIN_BLOCK_SIDE = max(D, 12)`, `ROAD_GAP = 2 D` (two opposing rows between
roads), `SQUARE_GAP`, `LANDMARK_GAP` and `BOUNDARY_GAP = D` (one row from a
square, a landmark or the town edge; `BOUNDARY_GAP` is the named gap that
walls #95 will claim). Squares (market, parvis) are paved edges: a road
within `SQUARE_GAP` of one is as narrow as one within `ROAD_GAP` of a road.
Enforcement is in `src/streets.lua`: the router pays `NARROW_PENALTY` per
step beside a narrow gap, a secondary candidate is shifted, shortened from
its free end or rejected, an accepted layout that still keeps a narrow run
beside a street fails the attempt, and block carving prefers rectangles that
do not leave a sliver between their edge and the pavement
(`SLIVER_WEIGHT`). Exceptions: one street width at each street end
(junctions, bends and entrance approaches), runs shorter than
`MIN_FRONTAGE_RUN`, and a gap of 0 (a street touching a road or a landmark;
a street touching the town edge is not exempt). Plans without ordinary
content in the profile, and the legacy 96 envelope, plan without the policy.

`MIN_BLOCK_SIDE` is intentionally the larger of D and the #89 product value
(`LANDMARK_TUNING.MIN_BLOCK_SIDE = 12`): the derived depth must not thin the
#89 look, and a deeper catalog raises it. Explicit `opts.constants` win.

### Before and after (#86)

Same seeds, centres and metric (D = 9) on `origin/main` (ea510ed, after
#105 compact parvis) and on this change; artifacts of the change are in
`docs/layout_after_86/`. The committed `docs/layout_baseline/` predates #105
and the 19th catalog entry and is kept as the historical pre-#86 record; its
D_min = 7 strips are not comparable with these.

| metric (12 seeds, sums) | before | after |
| --- | --- | --- |
| narrow strips (count) | 111 | 63 |
| narrow strip cells | 19586 | 7482 |
| street length (est.) | 7133 | 6699 |
| ordinary frontage | 7755 | 7402 |
| frontage used by placed buildings | 4902 | 4473 |
| placed ordinary buildings (houses/shops/workshops) | 536 (336/82/118) | 488 (298/89/101) |
| blocks / single-row blocks | 108 / 35 | 124 / 49 |
| empty runs | 49 | 76 |
| unused run length | 2851 | 2929 |
| shortages | 0 | 0 |
| planning failures | 0 | 0 |
| planner attempts (sum) | 27 | 44 |
| plan time (30 seeds, this machine) | 15.5 s | 34 s |

Placed buildings fall by about 9% (6% over seeds 1 to 30); the town-edge and
between-road strips are gone. Seed 3 of the test set loses its second
chapel (a reported shortage, not a failure). Variant A (minimum block side
= D = 9) placed 789 buildings; it was not taken to keep the #89 look.
