# Site inspection benchmark (issue #186)

Run: `python3 tools/site_bench/run.py [--reps 3]` (headless Luanti, scratch
superflat world, nothing of an existing world is touched). Measured on the
production `site_search.search` with the production wet defaults, real plans
and preflight composition, at 2026-10-23, commit 9912fc9 (per-node
`core.get_node` inspection, i.e. the "before" state).

Footprints: medieval 151x210 (20,297 inspected columns), Roman 181x172
(31,132 columns). `step=64, radius=128` limits the search to the centres about
one footprint from the player, so rejected-terrain runs inspect 4 (Roman) or 6
(medieval) candidates. All times in ms; `cold` is the first run on a fixture
(emerge sees the map the first time), `warm` the median of runs 2-3.

| fixture (town) | result | total cold / warm | planning | emerge cold / warm | inspection | get_node calls |
|---|---|---|---|---|---|---|
| flat (medieval) | accepted | 445 / 197 | 38-81 | 271 / 1 | 89-156 | 1,050,751 |
| flat (Roman) | accepted | 408 / 265 | 73-119 | 151 / 1-2 | 126-153 | 1,591,901 |
| shallow ponds, wet (medieval) | accepted, 3,877 wet cols | 467 / 198 | 74-90 | 266 / 1 | 95-103 | 1,062,382 |
| shallow ponds, wet (Roman) | accepted, 6,228 wet cols | 461 / 276 | 74-100 | 177 / 2 | 126-173 | 1,610,585 |
| flat, fresh mapgen (medieval) | accepted | 1272 / 205 | 63-96 | 1070 / 1 | 95-127 | 1,050,751 |
| flat, fresh mapgen (Roman) | accepted | 928 / 309 | 72-98 | 649 / 2-107 | 143-170 | 1,591,901 |
| uneven (medieval) | 6 x too_uneven | 1229 / 622 | 17-63 | 641 / 6-103 | 477-504 | 5,170,359 |
| uneven (Roman) | 4 x too_uneven | 760 / 604 | 38-86 | 132 / 2-3 | 466-527 | 5,236,028 |
| deep lake (medieval) | 6 x too_deep_water | 753 / 93 | 18-65 | 639 / 3 | ~0 | 2,187 |
| deep lake (Roman) | 4 x too_deep_water | 305 / 118 | 35-85 | 158 / 2 | ~0 | 225 |

Inspection costs about 85 ns per `core.get_node` call including Lua
classification (about 1.0-1.6 million reads per accepted site, 80 ms to 170 ms).
Water rejections end at the first column, so they are already free.

## Bulk-read probe

The bench also measures what a `VoxelManip` read of the same inspection volume
(4.0-4.1 million nodes) plus the same top-down column scan with cached content
IDs costs on the same terrain, without any production change:

| town | read_from_map | get_data | column scan | total |
|---|---|---|---|---|
| medieval | 1.6 ms | 10-11 ms | 19-22 ms | 31-35 ms |
| Roman | 1.5-1.8 ms | 10-12 ms | 17-19 ms | 29-33 ms |

This is a lower bound for a bulk implementation (the production policy adds
wet-column and lava handling) against 90-170 ms for the per-node path.

## Decision

Threshold: a change is worth its added second code path if it saves at least
25% of end-to-end search time or at least 100 ms per search on the realistic
case (unexplored terrain, where emergence is generated).

Saving per accepted candidate is about 55-65 ms (medieval) and 100-120 ms
(Roman): 4% / 14% of a fresh-terrain search, 12% / 27% of a pre-generated one.
Only rejected-terrain searches over already generated map gain more
(about 50 ms per candidate, up to ~50% of a warm run). The command is a
one-shot privileged operation dominated by map generation, so the bulk read
does not meet the threshold and was not implemented.
