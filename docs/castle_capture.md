# Castle capture from Creative

The castle was captured on 2026-10-11 from the local VoxeLibre world `Creative`.
The original world was left untouched: a consistent SQLite backup and copies
of its other files were made at `/private/tmp/towns-creative-extended`, and
Luanti with WorldEdit ran on that copy.

| Schematic | Inclusive source bounds (X, Y, Z) | Size | SHA-256 |
| --- | --- | --- | --- |
| `schematics/castle_creative_raw.mts` | `(125, -5, 426)` to `(178, 33, 475)` | 54 × 39 × 50 | `52cda0bfa9c9c918bcf5f30b92e9bc4e7c79c6a8d190616dc1ddb5a83befb4c8` |
| `schematics/castle_creative_with_finials.mts` | `(125, -5, 426)` to `(178, 34, 475)` | 54 × 40 × 50 | `352179010f81b539606ad3aea9b875106d0be318460b9dea3a743873e2c3ea32` |

Ground level is Y=0. Both files include five layers below it, and each
schematic's origin is its minimum corner. The first file follows the requested
bounds exactly. Four red end rods at `(166, 34, 465)`, `(176, 34, 465)`,
`(166, 34, 475)`, and `(176, 34, 475)` continue one block above the stated
top; the second file includes them. The surveyed Y=35 layer was empty.

The finial-inclusive capture was checked against the copied world by node name
and `param2`: zero differences across 108,000 positions. Its added X=125–129
slice was also checked at all 10,000 positions with zero differences. Neither
capture contains `ignore` nodes. The finial-inclusive crop contains 27,691
non-air nodes. Both are MTS version 4. As with the cathedral captures,
MTS does not preserve node metadata or inventory contents. The raw castle also
uses nodes from `mcl_decor`, `living_villages`, and `farming`, so it needs
cleanup or matching mods before use as a Towns catalog building.

## Workshop placement

An editable copy of the finial-inclusive castle is placed in `TownsWorkshop`
at `(245, 3, 100)` through `(298, 42, 149)`, east of the cathedral. Source
ground Y=0 aligns with workshop ground Y=8. The workshop's mod settings were
not changed. Its three `farming:mint_4` nodes were omitted during placement;
the saved source schematic above retains them. The original 49-column
placement was checked at all 98,000 positions. After correcting the minimum
source X from 130 to 125, only the missing workshop columns X=245–249 were
added, preserving the existing castle. The new 5-column slice matched its
source at all 10,000 positions. A copy of the workshop from before this
extension is at `/private/tmp/TownsWorkshop-before-castle-x-extension`.

## Earlier edited castle and legacy catalog conversion (2026-10-11)

After the workshop cleanup, `schematics/castle_workshop_edited.mts` captured
the live castle at `(245, 3, 100)` through `(298, 42, 149)` (54 × 40 × 50).
It is an exact snapshot, SHA-256
`25cf15328a9a925a8e5dfb8facd8a8017d4815b8ca4b92629f8d6589513adda9`.
All 108,000 node names and `param2` values matched the workshop copy; there
were no `ignore` nodes. This preserves the user's edits and the optional-mod
furniture for future reference. The live workshop was not changed by capture.

`schematics/castle.mts` is the earlier core-only catalog conversion (54 × 40 × 50, SHA-256
`0dfe4fdecf31c84b9e06090c2eadad5f0d5749819148b2c69553742394b554de`).
It is rotated 180 degrees so the apparent main gate faces -Z. The gate's
file-local offset is `(30, 8, 6)`; the site ground is five nodes above the
schematic bottom. The earlier Towns catalog registered it as `castle` with role
`landmark` and `ground_offset = 5`.

The catalog version uses VoxeLibre nodes only. It replaces `mcl_decor`
chairs, tables, fences, hedges, paths and a lamp with stairs, slabs, a fence,
leaves, stone and a lantern. The Living Villages pulpit becomes a VoxeLibre
lectern. Twenty-four `mcl_itemframes:plate` nodes become air because those
plates belong to `mcl_decor` and MTS cannot retain their displayed items.
The edited source had 38 nodes with metadata fields and 11 nodes with
inventory lists; MTS does not retain those contents, so placed castles have
empty containers and frames.

In a disposable flat VoxeLibre world with `mcl_decor` and Living Villages
disabled, `/towns_test castle 0` placed the catalog schematic at a site with
ground Y=8. Its foundation started at Y=3, the reported gate was at Y=11,
and all 108,000 placed nodes matched the catalog file. The test placement
was in a scratch world, not `TownsWorkshop`.

## Current cleaned game template (2026-10-13)

The active `castle` catalog entry now uses `schematics/templates/castle.mts`
and its `.lua` metadata sidecar. It captures the current TownsWorkshop bounds
**(245, 3, 100) through (298, 41, 149)**, retaining the full footprint and
five foundation layers. Y=42 is empty, so the template is **54 × 39 × 50**.
It is rotated 180 degrees to face -Z; the recessed walk-in approach is
source **(268, 11, 143)**, canonical **(30, 8, 6)**. On site ground Y=8,
the origin remains Y=3 and the entrance remains Y=11.

The current source differs at 118 node-name/param2 positions from the earlier
edited capture; this comparison does not distinguish author edits from normal
world updates. This version preserves actual mcl_decor furnishings, hedges,
plates, the Living Villages pulpit, and saved inventories instead of the
legacy substitutions. Those mods are required to place this asset; missing
nodes are reported before destination writes. Foliage placement retains the
saved palette/flags rather than rerunning biome-color constructors.

The catalog role is `castle`. The old converted `schematics/castle.mts` and
original capture files remain historical references; they do not supply the
active catalog entry. Source bounds, ground datum, entrance and orientation
are saved in `tools/workshop_export/buildings.json` for future re-export.

## Verification (ticket #30)

The cleaned castle template dimensions and catalog registration were verified
against the file header and placement geometry functions:

- **MTS header:** magic `MTSM`, version 4, size 54×39×50 (matches catalog registration)
- **Entrance file-local coordinates:** x=30, y=8, z=6 (all within bounds)
- **Ground offset:** 5 (within bounds)
- **Footprint at rotations:** 54×50 (rotations 0, 180) and 50×54 (rotations 90, 270)
- **Placement geometry:** entrance world coordinates verified at all four rotations
  with explicit coordinate checks via `geometry.place(castle, origin, rotation)`.
  The outside-node cell lies **inside** the footprint box, a documented property of
  the z=6 recessed entrance.

### Gate height and ground contact

The gate is at file-local y=8, placing it at world y=11 when the origin is at y=3
(ground_offset 5 below site ground at y=8). Thus the gate is **3 nodes above site
ground**. The nodes below the gate (steps/podium structure) and ground contact
mechanics were **not verified** — a disposable world is required to inspect what
stands between the foundation (y=3) and the gate entrance at y=11. The outside
cell at z=5 (rotation 0) is the ground contact point; the planner must approach
from that cell along the direction vector, not from the footprint edge.

### Implications for ticket #38

The planner must take the approach from the placed outside cell (computed as
`entrance + front` direction), not from the nearest bounding-box side. For the
castle, the outside cell lies inside the landmark footprint due to the recessed
recess gate, and the gate is 3 nodes above surrounding ground. These constraints
affect how the planner positions adjacent roads and plazas.

### Historical source files (not used by catalog)

The catalog `castle` entry uses only `schematics/templates/castle.mts`. The
following earlier sources remain for reference and are not referenced by the
active catalog:

- `schematics/castle_creative_raw.mts` — Original 54×39×50 raw capture from Creative world
- `schematics/castle_creative_with_finials.mts` — Finials-inclusive 54×40×50 version
- `schematics/castle_workshop_edited.mts` — Edited workshop version (54×40×50) with user changes
- `schematics/castle.mts` — Legacy core-only converted version (54×40×50)

## Gate re-selected by walking the placed castle (ticket #45)

The earlier entrance (source (268,11,143), canonical (30,8,6)) is the air above
a fence post inside a two-thick wall and cannot be walked to. The user named the
real gate in TownsWorkshop: its middle is at source (295, 8.5, 124), a 6-wide
(z 122..127), 6-high opening in the east wall (x=298) over a stone floor at
y=8, with two stair nodes at (288..289, 9) leading up to the terrace floor at
y=9. The castle is therefore exported with `rotation` 90 (source +X becomes the
canonical -Z front) and entrance source (295, 9, 124): canonical (24, 6, 3) in a
50 x 39 x 54 template, three nodes recessed and flush with ground (rise 1,
`ground_offset` 5). Planner profile, tests and the interior-access pins were
updated; the castle route is verified on the real nodes in
`tests/town_build_tests.lua` and in `tools/place_check/run.py`.
