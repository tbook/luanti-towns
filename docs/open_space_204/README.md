# Open-space study for issue #204

Measured on 2026-10-23 using the current medieval planner and catalog, with
the twelve seeds used by `tools/layout_compare/lib.lua`. This is a design
study. The [oak and garden assets](../../schematics/objects/README.md) now have
manual preview commands and seeded placement in reachable clearings. The
counts below describe candidate space before object placement.

## Findings

**Use 9 × 9 nodes as the initial minimum clearing.** Every sampled town has
one or more eligible pockets. Larger minimums would exclude most towns.

| Minimum square clearing | Pockets across 12 towns | Pockets per town | Towns with any |
| --- | ---: | ---: | ---: |
| 5 × 5 | 211 | 11–23 | 12 |
| 7 × 7 | 79 | 5–10 | 12 |
| 9 × 9 | 35 | 1–5 | 12 |
| 11 × 11 | 5 | 0–2 | 4 |
| 13 × 13 | 2 | 0–2 | 1 |

| Seed | 9 × 9 pockets | Pockets touching a street | Largest clear square (side, nodes) |
| --- | ---: | ---: | ---: |
| 1 | 4 | 3 | 12 |
| 7 | 3 | 1 | 10 |
| 42 | 4 | 4 | 11 |
| 101 | 1 | 0 | 10 |
| 256 | 4 | 1 | 11 |
| 1024 | 1 | 1 | 10 |
| 2718 | 1 | 0 | 10 |
| 31415 | 5 | 3 | 15 |
| 99999 | 3 | 2 | 10 |
| 123456 | 2 | 2 | 10 |
| 777777 | 3 | 2 | 10 |
| 1000003 | 4 | 3 | 10 |

Twenty-two of the 35 pockets touch a street. The others suggest back gardens
or trees within blocks, subject to actual access. A street contact alone
does not establish a usable garden entrance.

## Maps

- [Seed 1](seed_1_9.svg)
- [Seed 42](seed_42_9.svg)

Dark green marks all ground covered by at least one fully empty 9 × 9
square. Numbered regions are eligible pockets, not proposed objects or
areas to fill completely. Maps use current plans regenerated from the seed;
the older comparison artifacts remain unchanged.

Automatic-placement examples: [seed 1](placed_seed_1.svg) (one oak, one
garden) and [seed 42](placed_seed_42.svg) (two gardens). Object footprints
are outlined and labelled. Generated with:

```sh
lua5.1 tools/layout_compare/run.lua /tmp/towns-object-placement 1,42
```

The planner selects some reachable pockets and preserves a walking route
from each selected object to public pavement. The decoration outlines do
not change the layout tool's historical building and street metrics.

## Method and limits

For each seed, call `planner.plan({x=0,z=0}, seed, {landmarks=profile})`,
where `profile = planner.landmark_profile(catalog.snapshot())`. Classify
the finished plan with `tools/layout_compare/lib.lua`'s `analyze` function.
Only `boundary` and `block` cells count as empty. Roads, public squares,
landmark footprints, jail, services, and ordinary building footprints are
excluded. Ground outside the actual town boundary is excluded too.

For each candidate size, find every axis-aligned square made entirely of
empty cells. Union those squares, then count their four-connected components
as pockets. Narrow strips that cannot hold the square do not connect pockets.
One pocket may accommodate several alternative placements or more than one
object; these counts are not an object capacity or a placement quota.
Pockets at different thresholds are recomputed independently and need not
have a one-to-one correspondence.

The measurement uses complete catalog footprint rectangles. It does not inspect
individual schematic nodes, roof overhangs beyond those rectangles, back doors,
resident routes, tree growth, or garden entrances. No extra clearance has been
subtracted from the measured square; clearance must fit inside it if required.
This study covers medieval towns only.

## Suggested first objects

- **Tree:** a modest tree whose complete initial canopy fits within 7 × 7,
  centered inside a reserved 9 × 9 clearing. This leaves one node of ground
  clearance on each side. Height and any later growth need to respect nearby
  structures.
- **Garden:** a 7 × 7 composition of planted beds and a walking path, inside
  a 9 × 9 clearing. Keep it unfenced initially and orient its path toward a
  usable access point. Exact crop and water requirements remain to be chosen.

Choose some eligible pockets and leave others as grass. Start with at most
one object in each chosen pocket, without targeting a fixed number per town.
Reserve access before choosing the final object position. Defer long narrow
strips and larger compositions.
