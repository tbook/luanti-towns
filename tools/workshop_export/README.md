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
the workshop. The optional runtime validation expects this repository to be
installed as the `towns` mod, as it is in the current setup.

`buildings.json` records each editable source region, the finished floor
height, chosen entrance node, and export rotation. The narrow-side entrance
is used where available. Jail has one exterior entrance on its long side;
the townhouses keep all three entrances along their shared front.

On each export, bounds are recomputed from all non-air nodes above the
finished floor, plus stairs on the floor layer. The entire floor/foundation
layer within that footprint is retained. Loose terrain/paving outside the
footprint, workshop labels, and buried layers below the finished floor are
excluded. Empty outside rows/columns and empty top layers are trimmed.

If you enlarge, relocate, or raise a building, adjust its survey region,
`floor_y`, or entrance in `buildings.json`. The export fails if the structure
reaches a survey edge, or if the selected entrance is no longer a ground-floor
door one node above the floor. More distant additions outside the survey box
must be included by enlarging that box manually.

Outputs in `schematics/templates/`:

- `.mts`: engine-native schematics in canonical orientation, front toward -Z.
- `.lua`: metadata, inventories, and required node names for runtime placement.
- `catalog.lua`: generated dimensions and entrance offsets used by Towns.
- `manifest.json`: actual source bounds, orientation, dependencies, snapshot
  checksum, and verification results.

The exporter verifies every schematic by placing it with the inverse rotation
and comparing node names and param2 to the source. `--validate` additionally
places all ten templates at all four rotations through the runtime helper,
checking nodes, orientations, entrance locations, fields, and inventories.
Snapshot paths and logs are printed for inspection if a check fails.

Reload the game after replacing schematics because Luanti caches them. Use
`/towns_test <id> <rotation>` in a disposable world, for example
`/towns_test weaver_house 90`. The catalog IDs are `tower`, `leather_worker`,
`corner_house`, `jail`, `townhouses`, `weaver_house`, `scribe`, `gaboo_house`,
`office_building`, and `banker_house`.

The command reconstructs containers and decorations, restores inventory
contents and door state, and creates their display entities. It does not
import source villagers, bed ownership, simulation timestamps or formspecs
with old world coordinates. Villagers and other independent entities are
not schematic contents. Gaboo and the townhouses require **mcl_decor**; the
command reports unavailable nodes before changing the destination.

Raw Home captures and workshop placement records in `schematics/captures/`
are historical references. They are never used to overwrite workshop edits.
The full town generator still uses its existing blockouts; these templates
are registered for the building catalog and test command.
