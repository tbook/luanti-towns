# Towns

Towns is a Luanti mod for generating large, planned settlements in VoxeLibre.
Its first target is a medieval town with a dense center, streets, public spaces,
landmarks, and surrounding development. It is intended to work alongside
[Living Villages](https://github.com/tbook/luanti-villages), which handles
villager behavior.

This repository is a starting point. The mod loads, but does not generate towns
yet. See the [design brief](docs/design_brief.md) for the intended direction
and the [engineering design](docs/engineering_design.md) for implementation phases.

To add a building, see the [building workflow](docs/building_workflow.md),
which covers capturing `.mts` schematics from a local world with WorldEdit.

## Installation

Place this repository in a directory named `towns` under Luanti's `mods`
directory or a world's `worldmods` directory. Enable it for a VoxeLibre world.

## Tests

Geometry and catalog logic are pure Lua and tested with plain Lua 5.1. From the
mod root:

    lua5.1 tests/run.lua

## License

GPL-3.0; see [LICENSE](LICENSE).
