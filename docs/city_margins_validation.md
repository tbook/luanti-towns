# City margins: disposable-world validation

These checks exercise the real `/towns_generate` pipeline in disposable
headless worlds. They used Towns commit `44801f1` and a scratch-world copy of
Living Villages commit `e46889c`, which provides `terrain.boundary_volume` and
`terrain.smooth_boundary`. The runner copied the selected world's settings;
it did not copy or modify that world's map.

## Runs and outcomes

| Case | Map and town | Margin result | Rural result |
| --- | --- | --- | --- |
| Rectangular | Flat, seed 2014, town seed 238, Roman | Smoothed 116 columns: 20 cut, 96 filled; maximum surface movement 20; 13 steps over one node | 17/18 farms and 6/6 huts placed; 0/2 requested villas. All 17 placed farms were within the 20-node margin band. The final run exited 0, including restart verification: 135/135 residents persisted, with 0 respawned or failed |
| Irregular | Flat, seed 2014, town seed 238, medieval | Smoothed 116 columns: 20 cut, 96 filled; maximum movement 20; 13 steps over one node | 17/18 farms, 6/6 huts, 1/1 chapel; 38 spacing rejections; 11 placed farms were within the margin band |
| Forced partial failure | Flat, seed 2014, town seed 238, medieval | The test wrote an exterior dirt node, then forced the API to return `false`; Towns recorded `incomplete` with the forced-failure reason | Rural generation continued: 17 farms, 6 huts, 1 chapel. The urban resident summary recorded 147 spawned and 0 failed |
| Natural terrain | Home map settings, town seed 239, medieval | Smoothed 5,415 columns: 889 cut, 4,526 filled; maximum movement 20; 96 steps over one node; 7,568 tree nodes removed | 14/18 farms, 6/6 huts, 1/1 chapel; 43 spacing, 9 uneven-ground, and 14 water rejections |

The cap was reached on the 35-node raised fixture, leaving a remaining steep
face as expected for a capped pass. In the sampled cross-section, distances 2–5
fell from height 43 to 23; the cut trench at distances 7–9 rose from height 4
to 14, 14, and 13. Distances 20–24 in that section did not move. The section is
one sample across the boundary; it does not independently prove the radius for
every soil column. The full-pass stats report the changed-column count and
maximum movement, while the API does not return per-column distance records.

The rectangular and irregular fixtures each preserved all 22 pond, ice, and
foreign-cobble nodes by name and `param2`. Their synchronous before/after scan
covered the full boundary union from `ground_y - 48` through `ground_y + 40`:
20,297 columns and 1,806,433 nodes in the medieval case, and 31,132 columns and
2,770,748 nodes in the Roman case. The exact ordered name/`param2` signatures
matched with zero changed interior columns in both runs. The natural case also
matched across 20,297 columns and 1,806,433 nodes. These snapshots bracket the
smoothing call itself, before farms run; later farm work may legitimately
change margin terrain.

Farms did overlap the margin band. The overlap counts use the final placed
farm bounds and rounded distance to the city boundary: 11 of 17 placed farms
in the medieval case and 17 of 17 in the Roman case were at distance less than
20. Margin heights and interior snapshots were captured before farms ran;
farms may subsequently replace some smoothed soil.

## Timing observations

Times are elapsed milliseconds from the disposable engine. Phase timing was
collected by narrow observation wrappers in the copied scratch-world
Living Villages mod; no solver or cleanup code was changed. The `emerge` field
is the asynchronous boundary-volume wait. The scratch wrapper times tree
cleanup, terrain scanning, solver work, and the writer plus its post-write
stats separately.

| Case | Boundary emerge | Tree cleanup | Terrain scan | Solver | Apply + stats | Total `smooth_boundary` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Medieval flat | 379 | 812 | 200 | 40 | 15 | 1,069 |
| Roman flat, final passing run | 695 | 1,122 | 617 | 16 | 7 | 1,765 |
| Natural terrain | Not recorded in this run | 609 | 255 | 216 | 66 | 1,148 |

The API's read-only `boundary_volume` query took under 0.01 ms in these runs.
These are observations from small disposable worlds, not performance
thresholds. The natural run predates the boundary-emerge timer, so its value is
unavailable. Natural terrain also triggered 1,772 emerge calls during the
whole town pipeline and about 71.4 seconds of site-search time; those totals
are separate from margin smoothing.

## Reproduction

Use the runner with a source checkout of Living Villages. The runner copies
that source into the scratch world's `worldmods` so an older installed copy
cannot shadow the tested API. The `settings-from` world supplies only world
settings and mapgen metadata.

```sh
python3 tools/place_check/run.py --living-villages /tmp/towns-262-living-villages --scenario margins --town-type roman --seed 238 --keep
python3 tools/place_check/run.py --living-villages /tmp/towns-262-living-villages --scenario margins --town-type medieval --seed 238 --keep
python3 tools/place_check/run.py --living-villages /tmp/towns-262-living-villages --scenario margin-fail --town-type medieval --seed 238 --keep
python3 tools/place_check/run.py --living-villages /tmp/towns-262-living-villages --settings-from "/Users/tad/Library/Application Support/minetest/worlds/Home" --town-type medieval --seed 239 --keep
```

The flat settings were from `TownsWorkshop` (map seed 2014, chunk size 5,
water level 1). The natural settings were from `Home` (map seed
13741136353771787965, chunk size 4, water level 1). Town-generation seeds are
shown separately in the table.

The Lua suite completed with 20,360 checks and 0 failures against the fresh
Living Villages source. The final Roman run exited 0, including restart
verification. Some earlier medieval, natural, and forced-failure JSON reports
still have an overall `ok` flag of false: they predate the final cleanup of
asynchronous checks and contain resident-entity activation or
crop-growth/schematic comparisons. These other headless discrepancies are tracked in
[issue #268](https://github.com/tbook/luanti-towns/issues/268). The synchronous
margin snapshots, stage result, boundary stats, protected-node checks, and
rural counts are the evidence summarized here.
