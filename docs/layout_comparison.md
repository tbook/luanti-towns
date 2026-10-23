# Layout comparison (ticket #109)

A reproducible, engine-free way to compare town layouts before and after the
layout tickets (#86 street spacing, #105 parvis, #106 hall, #107 exits, #108
edge compounds). Development and review tooling only.

## Run it

From the mod root (needs only `lua5.1`; about 7 seconds):

    lua5.1 tools/layout_compare/run.lua docs/layout_baseline

Arguments: `[OUTDIR] [seed,seed,...] [--town-type=medieval|roman]`. Without a
seed list the documented set below is used (the medieval set; Roman has its own,
see "Roman plans"). The committed baseline in `docs/layout_baseline/` was produced
by exactly that command on the planner before any of the tickets above.

To compare a change against the baseline, write to a scratch directory and diff:

    lua5.1 tools/layout_compare/run.lua /tmp/layout_after
    diff -ru docs/layout_baseline /tmp/layout_after

`metrics.tsv` has one row per seed and is the easiest file to diff;
`report.md` holds the readable table, the totals and the layout constants.
When a layout ticket lands deliberately, regenerate `docs/layout_baseline/`
into a new directory (for example `docs/layout_after_86/`) rather than
overwriting the baseline, and record the before/after in the PR.

## Roman plans (issue #152)

The same tool renders and measures the authored Roman plan (`src/roman_planner.lua`,
layout in `src/roman_civic_plan.lua`, populated as in `tests/roman_population_tests.lua`).
Select it with `--town-type=roman`; the default stays medieval, so every
invocation above is unchanged.

Reproducible command, writing to a scratch directory (the Roman output has no
default location and must not go under `docs/`, so the historical medieval
baselines are never overwritten):

    lua5.1 tools/layout_compare/run.lua /tmp/layout_roman --town-type=roman

Seed set: `1, 2, 3, 7` (the seeds of `tests/roman_population_tests.lua`), with
the same round-robin centres. A narrower run takes a seed list as usual:

    lua5.1 tools/layout_compare/run.lua /tmp/layout_roman 1,2 --town-type=roman

What a Roman run shows, in `seed_N.svg` and `seed_N.txt`: the forum square
(`Q`, labelled `forum`), every landmark instance (`L`, labelled by its unique
site name, such as `temple_east`, `temple_west`, `domus_1` to `domus_4`, the
four arches, `amphitheater`, `theatre`, `bath`), the streets and ring, ordinary
buildings, the tavern, well and jail. The ASCII header lists
each site instance with its kind, catalog id and extent. Medieval-only classes
(market, parvis, cathedral, castle, city hall, chapel, approach window) are not
in the Roman legend.

Roman reports state the town type, seeds, catalog identity and the authored
layout settings: every value of `src/roman_civic_plan.lua`, flattened into
sorted `key.sub = value` lines with a hash over them. That hash is the layout
version for comparisons; a changed hash means the authored plan changed and
the outputs are not comparable.

Medieval-only metrics (`parvis_*`, `market_*`) are `n/a` in Roman rows and are
left out of the Roman totals. Roman streets use their own widths (6 nodes) for
`street_len_*`, while the medieval 5 and 4 divisors stay as defined below. All
other metrics apply to both town types.

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
boxes), boundary approach windows, the town centre, and the
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
placed ordinary buildings and unblocked boundary all count as
free ground, since buildings can sit on it).

- `street_len`: estimated centreline length of the ordinary street network.
  Counting convention: unique pavement nodes of principal streets divided by 5
  plus unique pavement nodes of secondary streets divided by 4 (Roman plans
  divide by their street widths, 6 and 6), in both cases
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
- `frontage_square_used`: summed width of ordinary buildings facing square
  pavement, in the same units as `frontage_square`. Square runs are packed
  before street runs and measured separately.
- `ordinary`, `houses`, `shops`, `workshops`: actual placed ordinary
  buildings from `plan.content.counts`. `jail`, `services`,
  `shortages` count reservations and unmet targets; `empty_runs` the street and square runs that received no building;
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
  anything painted over it is subtracted (since #106 the city hall stands
  beside the market, so this is normally the whole rectangle);
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
(`SLIVER_WEIGHT`). (The exceptions below were per street rectangle; issue
#122, last section, replaced them with geometric ones on the combined
pavement.) Exceptions: one street width at each street end
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

### Before and after (#106 hall beside the market)

Same 12 seeds and centres, catalog hash `62aae063`, on `origin/main`
(3e4714c, after #86) and on this change; artifacts of the change are in
`docs/layout_after_106/`. The hall used to stand inside the market with a
5-node pavement ring; it now lies outside the open market, touching one edge
with its door facing across it.

| metric (12 seeds, sums) | before | after |
| --- | --- | --- |
| market area (nodes) | 6566 | 6705 |
| market open nodes / share | 5798 / 0.883 | 6705 / 1.000 |
| largest open square (sum of per-seed sides; range) | 130 (7 to 15) | 263 (20 to 25) |
| narrow strips (count) | 63 | 55 |
| narrow strip cells | 7482 | 6216 |
| street length (est.) | 6699 | 6649 |
| placed ordinary buildings (houses/shops/workshops) | 488 (298/89/101) | 517 (324/69/124) |
| frontage used by placed buildings | 4473 | 4722 |
| blocks / single-row blocks | 124 / 49 | 131 / 55 |
| shortages / planning failures | 0 / 0 | 0 / 0 |
| planner attempts (sum) | 44 | 44 |
| tool time for the 12 seeds | 15.1 s | 14.2 s |

The random stream changed (the hall is now drawn right after the market and
the other landmarks keep clear of it), so individual towns differ; the totals
above are not a like-for-like tuning result.

### Before and after (#126 town hall template)

Same 12 seeds and centres on main after #128 (714b63c, 22-entry catalog hash
`86fae7e9`) and on this change (22-entry catalog hash `70a54cb4`). Both sides
include the soup shop, library, blacksmith, and updated office from #128;
the city hall `tower` grows from 8 x 50 x 8 to 18 x 50 x 21. Artifacts of
the change are in `docs/layout_after_126/`. The hall still stands beside the
open market touching one edge (#106); its facade (18) is shorter than
`MARKET_MIN` (20), so the market needs no expansion and keeps its ordinary
20 to 28 node sides.

| metric (12 seeds, sums) | before | after |
| --- | --- | --- |
| market area (nodes) | 6705 | 6665 |
| market open nodes / share | 6705 / 1.000 | 6665 / 1.000 |
| largest open square (sum of per-seed sides; range) | 263 (20 to 25) | 263 (20 to 26) |
| narrow strips (count) | 55 | 49 |
| narrow strip cells | 6216 | 4893 |
| street length (est.) | 6649 | 7574 |
| placed ordinary buildings (houses/shops/workshops) | 536 (253/131/152) | 568 (257/147/164) |
| frontage used by placed buildings | 4759 | 5069 |
| blocks / single-row blocks | 131 / 55 | 128 / 40 |
| shortages / planning failures | 0 / 0 | 0 / 0 |
| planner attempts (sum) | 44 | 79 |

The wider hall box changes what the sampler accepts and rejects, so the
random stream differs and these totals are not a like-for-like tuning
result. Every seed still plans with the whole market open and no shortages.

## Route consolidation and edge spacing (issue #122)

The #86 checks were per street rectangle, and a gap of 0 (a road touching a
road) passed. Two things followed: a route could run directly beside an
existing one (an 8 to 10 wide band with no building row between the two), and a
road split into several rectangles got an exemption at every piece's ends.
Now (`src/streets.lua`):

- Spacing is judged on the exposed edges of the combined road footprint
  (`gap_scan` `edge_runs`), so the verdict does not depend on how a route is
  cut into rectangles. Roads that touch have no edge between them.
- Exemptions are geometric: the first street width of an edge beside a concave
  corner (a real junction with a road or a square), a street end cap (a
  corner-to-corner edge no longer than a street), the entrance transition of
  each exit (its window grown by one street width), the landmark door windows
  and the castle gate apron. An arbitrary rectangle endpoint is not one.
- Routes (router penalty `WIDE_PENALTY`) and secondary strips beside or over an
  existing road are pulled into the shared corridor; a result that still has a
  fully paved `STREET_WIDTH + 1` square of road (`wide_cells`) fails the
  attempt. Squares and the gate apron are not roads, so a junction, bend,
  crossing or intentional square never counts.
- Blocks and frontage are carved after this, from what is left.

`streets.narrow_gaps(plan, C)` and `streets.wide_pavement(plan, C)` measure a
finished plan (fixtures in `tests/route_consolidation_tests.lua`).

### Before and after (#122)

`origin/main` (eb45238) against this change, seeds 1 to 40 (same seeds and
centres in both runs, as `run.lua` assigns them), current
catalog. Parallel paving is road cells inside a fully paved 6 x 6 square
(`streets.wide_pavement`, measured for seeds 11 to 40 and the 12 default
seeds); the other columns are `metrics.tsv` sums.

| metric (40 seeds, sums) | before | after |
| --- | --- | --- |
| parallel paving cells (seeds 11 to 40) | 11075 (23 of 30 seeds) | 0 |
| narrow edge runs | 1 (seeds 11 to 40) | 0 |
| streets | 686 | 663 |
| secondary street cells | 58284 | 51824 |
| blocks | 419 | 456 |
| placed ordinary buildings | 1810 | 2017 |
| town (boundary) cells | 937094 | 958481 |
| buildings per 1000 boundary cells | 1.93 | 2.10 (+9%) |
| planner attempts | 362 | 387 |

The default 12-seed set of this tool is an unlucky sample for this change: it
shows 534 against 443 buildings, but the random stream changes with the
routing, so single seeds grow different towns (seed 99999 shrinks from 29106 to
17153 boundary cells) and totals over few seeds are noisy. Compare larger seed
sets or the per-cell density.

Planning time: `run.lua` prints (and writes to `timing.txt`, not to the
byte-identical report) the total, mean and maximum planning CPU seconds per
run. Over seeds 1 to 40 on one machine: 79.5 s before, 102 s after (about
1.3x; slowest seed 7.6 s before, 8.2 s after). The consolidation checks are
the hot spots in `src/streets.lua`: `edge_runs` results are cached per road
layer, the wide-pavement test uses a precomputed window table, and candidate
strips already tested are memoised.
