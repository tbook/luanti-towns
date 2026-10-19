# Issue 139 Roman building imports

These are standalone, cleaned captures from TownsWorkshop. They are kept out
of `schematics/templates/catalog.lua`, so the town generator does not use them.
Each `.mts` is a native Luanti schematic in the orientation and dimensions
recorded in `manifest.json`; the matching `.lua` stores node metadata,
inventories, and required node names for tooling that supports the Towns
schematic sidecar format.

The bath capture includes the full basement volume and the corrected two-layer
dirt plinth. Its surrounding terrain is part of the import asset so its ground
level remains clear when placed. The other captures preserve the complete
workshop bounds, including authored empty space. Independent entities are not
included.

To refresh these assets from the saved TownsWorkshop world, close the world and
run from the mod directory:

```sh
python3 tools/issue139_import/export_roman.py
```

The exporter reads a consistent, read-only SQLite snapshot and writes only to
this directory. In a game with this mod enabled, a server-privileged player
can place one with `/towns_import_roman <id> [rotation]`. It places the capture
four nodes in front of the player at their current height, restores saved
metadata and inventories, and overwrites the schematic's full volume,
including air. See the manifest for each capture's dimensions and source
bounds. The command is separate from the town generator catalog.
