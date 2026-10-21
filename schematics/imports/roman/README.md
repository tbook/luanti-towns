# Issue 139 Roman building imports

These are cleaned captures from TownsWorkshop. `catalog.lua` registers arch,
temple, domus, theatre, amphitheater, and bath with the shared generator as
fixed `landmark` entries. They do not enter medieval random building pools;
domus is not a random house. Villa and aqueduct remain standalone imports.
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
bounds. This command continues to use the unchanged source captures, including
the two assets outside the generator catalog.

## Generator metadata (#147)

All positions below are zero-based offsets in the existing `.mts`, measured
by reading its actual nodes. `ground_offset` is the local site-ground datum;
placement origin Y is `site_ground_y - ground_offset`. Entrance Y is the feet
node (door bottom or open approach), not the floor. Facing names an outward
axis **before** placement rotation; omitted facing defaults to `-Z`.

| ID | Size X×Y×Z | Entrance X,Y,Z | Facing | Ground offset | Measured evidence |
| --- | --- | --- | --- | --- | --- |
| arch | 12×11×8 | 5,1,0 | -Z | 0 | Cobble path at Y=0, open feet/head at the -Z mouth. |
| temple | 18×10×12 | 3,1,5 | -X | 0 | Spruce double door at X=3; quartz platform and first stair at Y=0, X=0. |
| domus | 38×11×22 | 1,2,9 | -X | 1 | Spruce double front door; grass/path surface at Y=1. |
| theatre | 21×11×14 | 10,5,13 | +Z | 3 | Open central front apron over cobble at Y=4; perimeter grass at Y=3. |
| amphitheater | 29×9×29 | 15,3,0 | -Z | 2 | Grass-path approach at X=15, Y=2; open entrance under outer structure. |
| bath | 95×21×48 | 8,4,22 | -X | 2 | Central front door over quartz at Y=3; perimeter grass at Y=2 above lower dirt layer. |

The bath's full 95×21×48 capture, basement, plinth, and saved metadata remain
intact. Its door is recessed eight nodes from the capture edge; the temple
door is recessed three. `geometry.place().outside` remains the single node
adjacent to the entrance, including for recessed doors. Later layout/routing
work must account for these captured margins rather than treating that node
as an exterior footprint edge. No town or street layout is added here.

The arch is traversable along Z. Cobble paving occupies X=4..7; wall posts at
X=4 and X=7, Z=2 and Z=5 narrow the continuous unobstructed corridor to
X=5..6, Z=0..7 (clear at Y=2..3 over the half-slab floor at Y=1).
The generator uses the -Z mouth `(5,1,0)` and approach `(5,1,-1)`, then rotates
both with the asset. The +Z mouth is also open. The door at `(10,1,4)` leads
to the pier ladder and is not the chosen entrance. This is one entrance
marker, without portal-aware or through-building street routing.

There are no authored resident-bed exclusions for these captures. The shared
resident adapter accepts all eight domus beds and all six bath basement beds
at every rotation; the other four assets have no beds.

See [validation evidence](../../../docs/roman_assets_validation.md) for the
disposable-world run and preserved capture caveats.
