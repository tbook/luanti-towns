# Re-exporting the workshop

The source remains **TownsWorkshop**. The exporter opens its map database
read-only and takes a consistent SQLite backup. All engine inspection,
rotation and verification happen in a temporary world. It never installs a
helper or writes to the workshop. Return to the menu first to ensure your
latest in-game edits have been saved.

From the Towns mod directory:

```sh
python3 tools/workshop_export/export.py \
  --world "$HOME/Library/Application Support/minetest/worlds/TownsWorkshop" \
  --validate
```

Use `--engine /path/to/luanti` on another system, or `--port 39488` if the
validation port is in use. Luanti must have the same game and node mods as
the workshop. Runtime validation installs an isolated copy of this checkout into the
disposable snapshot, so it also works from a separate Git worktree.

`buildings.json` records each editable source region, the finished floor
height, chosen entrance node, and export rotation. The narrow-side entrance
is used where available. Jail has one exterior entrance on its long side;
the townhouses keep all three entrances along their shared front.

To update only the three new templates while preserving other exported versions:

```sh
python3 tools/workshop_export/export.py \
  --world "$HOME/Library/Application Support/minetest/worlds/TownsWorkshop" \
  --only butcher_shop mason_yard chapel --validate
```

Each building keeps the checksum of its own source snapshot in the manifest.
Runtime validation still checks the complete catalog after a selective export.

On each export, bounds are recomputed from all non-air nodes above the
finished floor, plus stairs on the floor layer. The entire floor/foundation
layer within that footprint is retained. Loose terrain/paving outside the
footprint, workshop labels, and buried layers below the finished floor are
excluded. Empty outside rows/columns and empty top layers are trimmed.

If you enlarge, relocate, or raise a building, adjust its survey region,
`floor_y`, or entrance in `buildings.json`. The export fails if the structure
reaches a survey edge, or if the selected entrance is no longer a ground-floor
door one node above the floor. Open-front structures use
`entrance_kind = "opening"`; their selected entrance must have two clear air
nodes over a solid floor. The butcher shop uses its west storefront opening;
the mason’s yard uses the opening in its south boundary. The chapel keeps its
-Z-facing doorway. More distant additions outside the survey box
must be included by enlarging that box manually.

Outputs in `schematics/templates/`:

- `.mts`: engine-native schematics in canonical orientation, front toward -Z.
- `.lua`: metadata, inventories, and required node names for runtime placement.
- `catalog.lua`: generated dimensions and entrance XYZ offsets used by Towns.
- `manifest.json`: actual source bounds, orientation, dependencies, snapshot
  checksum, and verification results.

The exporter verifies every schematic by placing it with the inverse rotation
and comparing node names and param2 to the source. `--validate` additionally
places the complete catalog (including the castle) at all four rotations through the runtime helper,
checking nodes, orientations, entrance locations, fields, and inventories.
Snapshot paths and logs are printed for inspection if a check fails.

Reload the game after replacing schematics because Luanti caches them. Use
`/towns_test <id> <rotation>` in a disposable world, for example
`/towns_test weaver_house 90`. The catalog IDs are `tower`, `leather_worker`,
`corner_house`, `jail`, `townhouses`, `weaver_house`, `scribe`, `gaboo_house`,
`office_building`, `banker_house`, `butcher_shop`, `mason_yard`, and `chapel`.
The `castle`, `cathedral` compound and existing `demo_house` are also available.

The command reconstructs containers and decorations, restores inventory
contents and door state, and creates their display entities. It does not
import source villagers, bed ownership, simulation timestamps or formspecs
with old world coordinates. Villagers and other independent entities are
not schematic contents. Gaboo and the townhouses require **mcl_decor**.
The chapel requires **mcl_decor** for chairs and **living_villages** for its
pulpit. The command reports unavailable nodes before changing the destination.

Raw Home captures and workshop placement records in `schematics/captures/`
are historical references. They are never used to overwrite workshop edits.
The full town generator still uses its existing blockouts; these templates
are registered for the building catalog and test command.

## Cleaned landmarks

Re-export only the current cleaned castle and cathedral/monastery:

```sh
python3 tools/workshop_export/export.py \
  --world "$HOME/Library/Application Support/minetest/worlds/TownsWorkshop" \
  --only castle cathedral --validate
```

Landmarks use explicit `capture_min` / `capture_max` compound bounds and
`ground_y` rather than the ordinary floor-level crop. The castle retains five
foundation layers; the cathedral retains one. Their entrance heights may be
above the outside ground because authored stairs remain in the box. Bounds
checks inspect architecture above outside ground and fail if it escapes the
chosen capture. Update these bounds if the user extends the compound.

The active castle keeps its authored optional-mod furnishings; the previous
core-only converted castle and older source captures remain historical files.
Both landmarks require mcl_decor and Living Villages for authored furnishings.
Foliage constructors that would recompute palette/flags are skipped, preserving
saved colors while functional node initialization and inventories still run.

Detailed records: `docs/castle_capture.md`,
`docs/cathedral_monastery_capture.md`, and the generated template manifest.

## Stock village templates (tavern, well)

`tavern` (role `tavern`) and `well` (role `well`) are the stock VoxeLibre
village buildings, not TownsWorkshop builds, so their source is a scratch
world seeded from the installed game schematics:

- Source files: `<game>/mods/MAPGEN/mcl_villages/schematics/tavern.mts`
  (12 x 13 x 10, MTS v4) and `well.mts` (6 x 7 x 8, MTS v4), VoxeLibre
  0.92.3 (`game.conf` release 38585) as installed at
  `games/mineclone2`.
- Licence: the `mcl_villages` README credits "Completely new schematics for
  VoxeLibre: MysticTempest - CC-BY-SA 4.0" (mod code is GNU GPLv3,
  (c) Rochambeau 2018, from "settlements"/"ruins" by BlockMen). The two
  templates are verbatim copies of those schematics (the tavern with the
  Living Villages furnishing below) and carry CC-BY-SA 4.0 with that
  attribution.
- Regenerate: create a scratch world with `mg_name = singlenode`, a
  `world.mt` enabling `mcl_decor` and `living_villages` (as TownsWorkshop
  does), copy `tools/workshop_export/stock_seed/` to
  `<world>/worldmods/stock_seed/`, run the server once (it places both
  schematics and shuts down), then:

  ```sh
  python3 tools/workshop_export/export.py --world <scratch world> \
    --only tavern well --validate
  ```

  The seeder places the tavern at (100,7,100) and the well at (140,7,100)
  and applies the Living Villages `tavern_schematic.lua` furnishing (two
  fence-and-plate tables become four tables with eight chairs and four
  plates). Keep the change list in `stock_seed/init.lua` equivalent to that
  file.
- Both entries use fixed capture boxes so the stock footprint and apron are
  kept. The tavern drops only the buried dirt layer (stock y 0), so its floor
  layer is the template ground layer: 12 x 12 x 10 as authored (door on the
  -X side, `rotation` 270), which is 10 x 12 x 12 in the canonical -Z-front
  file. The well keeps its dirt layer, because its standing apron is air at
  stock y 1 over that dirt: 6 x 7 x 8, front already on -Z.
