# Towns

Towns is a Luanti mod for generating large, planned settlements in VoxeLibre.
Its first target is a medieval town with a dense center, streets, public spaces,
landmarks, and surrounding development. It is intended to work alongside
[Living Villages](https://github.com/tbook/luanti-villages), which handles
villager behavior.

The mod currently builds one populated town on demand with
`/towns_generate` (see below): real cathedral, castle, city hall, jail,
services and ordinary buildings, alleys, and one Living Villages resident per
valid bed. Natural generation is a later phase. See the [design brief](docs/design_brief.md) for the intended direction
and the [engineering design](docs/engineering_design.md) for implementation phases.

To add a building, see the [building workflow](docs/building_workflow.md),
which covers capturing `.mts` schematics from a local world with WorldEdit.
The catalog includes `demo_house`, the cleaned `castle` and `cathedral` compound, and thirteen
edited Home buildings. Workshop buildings can be
[re-exported automatically](tools/workshop_export/README.md) with saved bounds,
entrance choices, and inventory/decoration data.

## Town command

`/towns_generate [medieval|roman] [seed]` (needs the `server` privilege)
searches near you for a site and builds a populated town there. The town
type is optional and defaults to `medieval`, so `/towns_generate` and
`/towns_generate 42` behave as before. The medieval town has the real
cathedral and its parvis, a market square with the city hall, the castle, a
jail, taverns, wells and chapels, ordinary houses, shops and workshops on the
street frontage, paved access alleys, initialized functional nodes (chests,
item frames, jukebox, well), and then one villager spawned and bed-claimed
per valid bed.

`/towns_generate roman [seed]` builds the first-version Roman town through
the same search, build, node setup and resident stages. Its civic layout is
authored in `src/roman_civic_plan.lua`: a forum square, four arches at the
ends of the cardo and decumanus streets, a temple on each side of the north
street, an amphitheatre, a theatre, a bath and four domus monuments, with
paved blocks and street frontage. Ordinary houses, shops, workshops,
services and the jail come from the shared catalog where they fit,
and any shortfall is reported. The Roman layout has no cathedral, castle,
city hall or market square; the Roman report names only the sites it
actually has. The layout is the same for every seed, so the seed only
changes the surrounding content and is recorded for repeat instructions.

The former opt-in `/towns_place_town` command and its
`towns_enable_place_town` setting were removed; `/towns_generate` is the one
production path.

> **WARNING: it OVERWRITES the chosen site immediately, with no preview and
> no confirmation.** Use it only in disposable Creative worlds (such as
> Testlandia). It flattens the town interior to the median surface height,
> clears trees and terrain inside it, and does no edge smoothing.

- Stand on solid ground, then run the command. It looks for a site within
  about 320 nodes. Shallow water and ice (up to 6 nodes deep, over at most
  25% of the footprint) is landfilled to ground level; deep water, lava and
  too-wet footprints reject the site. The middle 95% of surface heights must
  span at most 16 nodes (up to 2.5% of columns at each extreme are ignored,
  rounded down). Every column must be within 24 nodes of the median height,
  limiting cutting and filling. Terrain is inspected within 48 nodes above
  and below your ground level.
  The search runs in the background; you are told when it starts and when it
  finishes. Only one search or build runs at a time on the server; a second
  command is refused until it finishes.
- `medieval` or `roman` (case-insensitive) may come first; anything else
  before the seed is rejected. `seed` is an integer from -1073741823 to
  1073741823. If omitted, a seed is generated and printed. The same type,
  seed and chosen centre reproduce the same town. The success report repeats
  the type and seed, e.g. `/towns_generate roman 42`. Anything else
  (unknown types, decimals, words, extra arguments, or a larger number such
  as a 64-bit world seed) is rejected with the usage and nothing is changed.
- On success it reports and logs the seed, centre, ground level, bounds,
  cathedral, parvis, market, castle and city hall coordinates (for a Roman
  town, each named monument and square it has), building,
  service and alley counts, the catalog ids used, valid and skipped beds,
  spawned residents and any unmet service targets. If a stage after the
  town was placed (bed enumeration or resident spawning) did not complete,
  the first line says the build is INCOMPLETE and names the problem; the
  town itself is still in the world.
- The report lists landfilled water/ice columns, replaced buried liquids
  and how many candidate sites were skipped and why.
- Zero-write failures (no suitable site, deep water, lava, too-wet, an uneven or unloaded
  surface, a missing schematic or unregistered node found by the preflight)
  say why and "Nothing was changed". A failure once writing began (terrain,
  a schematic, node initialization) is reported as a partly built site with
  the stage, building and bounds; it never says nothing changed.
- Residents are recorded per bed in mod storage (keys `resident:x,y,z` in
  the Towns mod's storage, `mod_storage.sqlite` in the world directory) so a
  bed is never spawned twice, even if you rebuild the same site. To re-test
  from scratch, remove the villagers (or use a fresh world) and, with the
  server stopped, delete the `resident:` rows for the `towns` mod from
  `mod_storage.sqlite` (or delete that file to reset every mod's storage).

## Test command

`/towns_test` (Phase 1) is unchanged:

`/towns_test <building_id> <rotation>` (needs the `server` privilege;
rotation is 0, 90, 180 or 270) places a catalog building eight nodes east of
the node you stand on, with a 5x5 paved square outside its entrance. It
**overwrites the chosen site immediately, with no preview or confirmation**:
use it only in disposable Creative worlds (such as Testlandia). Unsuitable
sites (water, or a surface that varies by more than one node) are rejected
without changing anything. The site surface must also be within one node of
your ground level. It needs no WorldEdit.

## Installation

Place this repository in a directory named `towns` under Luanti's `mods`
directory or a world's `worldmods` directory. Enable it for a VoxeLibre world.

**Required mods** (`mod.conf`): [Living Villages](https://github.com/tbook/luanti-villages)
(`living_villages`, which itself needs `mobs_mc`, `mcl_beds`, `mcl_villages`,
`mcl_decor`, `mcl_itemframes`, `mcl_lectern` and `mcl_wool`), plus the VoxeLibre
mods Towns calls directly: `mcl_core`, `mcl_chests` and `mcl_itemframes`.
Living Villages supplies the pulpit node used by the cathedral and chapel
templates and recognizes the tavern jukebox and the well by node and shape;
the Towns node setup (`src/node_setup.lua`, run by `/towns_generate`) only
prepares those nodes and never reimplements villager behaviour.

## Settings

Towns reads no `minetest.conf` settings. (`towns_enable_place_town` no longer
exists.) The headless check `python3 tools/place_check/run.py` repeats a
`/towns_generate` build in a scratch superflat world through the command
controller and re-reads it.

## Tests

Geometry and catalog logic are pure Lua and tested with plain Lua 5.1. From the
mod root:

    lua5.1 tests/run.lua

The default run skips generated-planner suites that dominate runtime. Run
`TOWNS_TEST_FULL=1 lua5.1 tests/run.lua` to include the full seed and fuzz set.
Each test group prints its status and elapsed time so slow runs are visible.

GitHub Actions runs the default command on every pull request and on pushes to
`main` (see `.github/workflows/tests.yml`).

## License

GPL-3.0; see [LICENSE](LICENSE).
