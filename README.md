# Towns

Towns is a Luanti mod for generating large, planned settlements in VoxeLibre.
Its first target is a medieval town with a dense center, streets, public spaces,
landmarks, and surrounding development. It is intended to work alongside
[Living Villages](https://github.com/tbook/luanti-villages), which handles
villager behavior.

The mod currently builds one first walkable town on demand with
`/towns_generate` (see below); natural generation, ordinary buildings and
residents are later phases. See the [design brief](docs/design_brief.md) for the intended direction
and the [engineering design](docs/engineering_design.md) for implementation phases.

To add a building, see the [building workflow](docs/building_workflow.md),
which covers capturing `.mts` schematics from a local world with WorldEdit.
The catalog includes `demo_house`, the cleaned `castle` and `cathedral` compound, and thirteen
edited Home buildings. Workshop buildings can be
[re-exported automatically](tools/workshop_export/README.md) with saved bounds,
entrance choices, and inventory/decoration data.

## Town command

`/towns_generate [seed]` (needs the `server` privilege) searches near you
for a site and builds a first walkable town there: a stepped boundary about
96 nodes across, a cathedral and its parvis, a market square, a castle, and
connected principal and secondary streets with empty blocks for later
buildings. The cathedral and castle are temporary blockouts.

> **WARNING: it OVERWRITES the chosen site immediately, with no preview and
> no confirmation.** Use it only in disposable Creative worlds (such as
> Testlandia). It flattens the town interior to the median surface height,
> clears trees and terrain inside it, and does no edge smoothing.

- Stand on solid ground, then run the command. It looks for a site within
  about 320 nodes with no water. The middle 95% of surface heights must
  span at most 16 nodes (up to 2.5% of columns at each extreme are ignored,
  rounded down). Every column must be within 24 nodes of the median height,
  limiting cutting and filling. Terrain is inspected within 48 nodes above
  and below your ground level.
  The search runs in the background; you are told when it starts and when it
  finishes. Only one search or build runs at a time on the server; a second
  command is refused until it finishes.
- `seed` is an integer from -1073741823 to 1073741823. If omitted, a seed is
  generated and printed. The same seed at the same chosen centre reproduces
  the same layout. Anything else (decimals, words, extra arguments, or a
  larger number such as a 64-bit world seed) is rejected with the allowed
  range and nothing is changed.
- On success it reports and logs the seed, centre, ground level, exact
  bounds, cathedral, parvis, market and castle coordinates and the number of
  streets, blocks and frontage runs. If no site is suitable (water, an
  uneven or unloaded surface) it says why and changes nothing. A failed
  engine write is the one case that may leave a partly built site; the
  message then says so and gives the bounds.

## Test command

`/towns_test` (Phase 1) is unchanged:

`/towns_test <building_id> <rotation>` (needs the `server` privilege;
rotation is 0, 90, 180 or 270) places a catalog building eight nodes east of
the node you stand on, with a 5x5 paved square outside its entrance. It
**overwrites the chosen site immediately, with no preview or confirmation**:
use it only in disposable Creative worlds (such as Testlandia). Unsuitable
sites (water, or a surface that varies by more than one node) are rejected
without changing anything. The site surface must also be within one node of
your ground level. It needs neither WorldEdit nor Living Villages.

## Installation

Place this repository in a directory named `towns` under Luanti's `mods`
directory or a world's `worldmods` directory. Enable it for a VoxeLibre world.

## Tests

Geometry and catalog logic are pure Lua and tested with plain Lua 5.1. From the
mod root:

    lua5.1 tests/run.lua

GitHub Actions runs the same command on every pull request and on pushes to
`main` (see `.github/workflows/tests.yml`).

## License

GPL-3.0; see [LICENSE](LICENSE).
