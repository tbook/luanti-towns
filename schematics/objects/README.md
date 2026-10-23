# Small outdoor objects (#204)

Two Towns-authored assets for occasional placement in open town ground:

| ID | Size X × Y × Z | Ground row | Contents |
| --- | --- | ---: | --- |
| `oak_tree` | 7 × 9 × 7 | 0 | Grass, oak trunk/branches, irregular oak crown |
| `garden` | 7 × 3 × 7 | 1 | Grass border, two crop beds, two water sources, gravel path |

Both are designed for a **9 × 9 clearing**, with one node of clearance around
the 7 × 7 footprint. For the oak this includes the entire canopy. It is a
completed tree, not a sapling that can grow beyond its reserved space.

The garden's soil, water, grass, and path are at surrounding ground level.
Its bottom row is dirt, one node below ground, sealing the water holes. Nine
wheat plants and nine carrot plants sit on hydrated farmland, at mixed growth
stages. Every crop is within four nodes of water. The unobstructed path runs
along X=3, joining the -Z and +Z edges. The border is grass, with no fence or
raised frame. Crops use the game's normal farming behavior.

## Inspect in game

After restarting the world to load the command and fresh schematic files:

```text
/towns_place_object oak_tree
/towns_place_object garden
/towns_place_object garden 90
```

Requires the `server` privilege. Stand on level ground and look toward an
open spot. The command centers the object eight nodes ahead, using the ground
height beneath your feet. It loads the target area and overwrites the whole
schematic volume, including air and the garden's buried dirt row. It does not
search for terrain or suitable clearings. Use it in a disposable build area.

The native `.mts` files can also be placed directly. For ground height G,
the schematic minimum Y is G for the oak and G−1 for the garden. The separate
`catalog.lua` records offsets and dimensions.

## Automatic town placement

Both medieval and Roman towns plan objects after buildings and services.
Each selected object occupies the center of a fully unused 9 × 9 clearing,
leaving a one-node ring of open ground around its complete 7 × 7 footprint.
Roads, squares, landmarks, buildings, and service reservations are excluded.

Eligible squares are grouped into connected pockets; narrow strips that
cannot contain a 9 × 9 square do not connect them. At most half of the
reachable pockets are selected (rounded down, with one allowed when there
is a single pocket), and each receives at most one oak or garden. A pocket
can be skipped if an earlier reservation prevents a suitable placement.

The choice is seeded and repeatable, without changing building placement.
Objects require access to public pavement. The garden's path points toward
a reserved walking route to a street or square, and later objects avoid that
route. The clear ring preserves passage around the footprint and along
adjacent buildings. The planner uses building rectangles, so unrecorded
overhangs outside those rectangles still require in-game observation.

Objects participate in preflight file/node checks, construction bounds,
schematic placement, and node setup. They are counted separately from
buildings and have no fabricated building doors or resident beds.

## Previews and authoring

- [Oak geometry diagram](oak_tree.svg)
- [Garden geometry diagram](garden.svg)

These show schematic geometry, not in-game textures. The `.mts` assets and
diagrams are generated from the authored definitions in
[`tools/object_assets/build.py`](../../tools/object_assets/build.py):

```sh
python3 tools/object_assets/build.py
```

Edit those definitions and regenerate rather than editing generated files.
These small objects have their own authoring source; captured buildings
continue to use the workshop exporter.

## Checks

```sh
python3 tools/object_assets/check.py
```

Creates a disposable VoxeLibre world, loads the real game nodes, places both
native schematics through Towns' placement helper at all four rotations, and
compares every node and its orientation with the source. Also checks dimensions,
registered dependencies, crop support and irrigation, water containment, the
garden path, and preview-command registration. The scratch world is retained.

The two individual assets have passed user playtesting. Automated checks do
not replace in-game observation of their placement in complete towns.
