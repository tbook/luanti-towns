# Issue 139 Roman building imports

These are cleaned captures from TownsWorkshop. `catalog.lua` registers arch,
temple, domus, theatre, amphitheater, bath, insula, vespasianum, basilica,
temple_of_jupiter, temple_of_vesta and hippodrome with the shared generator as
fixed `landmark` entries. They do not enter medieval random building pools; domus,
insula, vespasianum, basilica and the two temples and the hippodrome (#341) are
not random houses. The Roman civic plan places temple_of_jupiter (#351) and
temple_of_vesta (#352) but not the hippodrome yet; a follow-up ticket handles that. The villa is also registered separately as a rural outskirts building;
it remains outside the shared urban catalog. Aqueduct remains a standalone import.
Each `.mts` is a native Luanti schematic in the orientation and dimensions
recorded in `manifest.json`; the matching `.lua` stores node metadata,
inventories, and required node names for tooling that supports the Towns
schematic sidecar format.

The bath capture includes the full basement volume and the two ground rows
(dirt below the grass datum) that carry its `ground_offset`. Since #171 it is a
tight box around the architecture (`FIXED_BOXES` in the exporter): the dirt,
grass, stone and gravel platform it stood on in the workshop, and the empty rows
above the roof, are excluded. The other captures preserve the complete
workshop bounds, including authored empty space. Independent entities are not
included.

To refresh these assets from the saved TownsWorkshop world, close the world and
run from the mod directory:

```sh
python3 tools/issue139_import/export_roman.py
```

`--only bath` (any subset of ids) re-exports just those buildings and keeps the
other manifest records and the top-level `snapshot_sha256`. Every record
written by the exporter carries its own `min`/`max` capture box,
`snapshot_sha256` (the temporary map backup it was captured from) and
`source_map_sha256` (the source `map.sqlite` file). A record without these two
fields was captured by the original full export, whose snapshot is the
top-level `snapshot_sha256`. Since #193 the bath, domus, amphitheater, villa,
aqueduct and insula records were re-exported with `--only` from a byte-identical
scratch copy of TownsWorkshop (`--world <copy>`), so `source_map_sha256` equals
the workshop file's hash at that time (`6eab09ff...`). Temple, theatre and arch
were not re-exported: their only changes were grass/dirt flips in the ground row.
The TownsWorkshop world has since changed, so the vespasianum (#207) and
basilica (#211) records were captured from a byte-identical copy of the current
file and their `source_map_sha256` is `d073c3fb...`. Records captured before that
change keep `6eab09ff...`. The bath and domus were then re-exported again with
`--only` after the owner tweaked the workshop, from a byte-identical copy whose
`source_map_sha256` is `852b14cd...`; their records carry that hash. The
temple_of_jupiter, temple_of_vesta and hippodrome records (#341) were exported
by `tools/issue139_import/export_roman.py --only` from the TownsWorkshop map
after `tools/issue341_import` placed them, so their `source_map_sha256` is
`1a5bd7dd...` at the first import. They were re-exported after the owner edited the
workshop copies (Vesta's copper roof weathering; the hippodrome's ground, seating and
underground passage; Jupiter unchanged); the records now carry the newer snapshot
hash. Re-export with `python3 tools/issue341_import/update.py` (see its README).

The bath record (#370) was re-exported alone with `export_roman.py --only bath`
after the workshop bath gained a pediment row at Z=398 (outside the old box), with
the box's min Z lowered from 399 to 398. Its `source_map_sha256` is `10f6496d...`.
Every other manifest record and schematic file is byte-identical.

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
| temple | 18×11×12 | 3,2,5 | -X | 0 | Spruce double door at X=3 on the quartz platform (Y=1, first stair at X=0); terrain row (dirt, grass at the edge) at Y=0 (#134). |
| domus | 38×11×22 | 1,2,9 | -X | 1 | Spruce double front door; grass/path surface at Y=1. |
| theatre | 21×11×14 | 10,5,1 | -Z | 3 | Open central gap (X=10..11, Y=5..7) in the cavea's back row at Z=0, no door. The entrance cell sits one node in at Z=1 on full cobble (10,4,1); the half-step stair at (10,4,0) is the outside step (#213). The stage and scaenae door at Z=13 face away from the street. Perimeter grass at Y=3. |
| amphitheater | 29×9×29 | 15,3,0 | -Z | 2 | Gravel approach at X=15, Y=2 (re-captured in #193); open entrance under outer structure. |
| bath | 88×18×44 | 4,4,21 | -X | 2 | Central front door over quartz at Y=3 (quartz approach slab at X=0); perimeter grass at Y=2 above lower dirt layer. |
| insula | 35×20×27 | 17,3,2 | -Z | 2 | Spruce door in the front wall at Y=3 over a stone threshold at Y=2; gravel approach at Y=2 (Z=0). A second front door is at X=11, and a rear spruce door at (17,3,24). |
| vespasianum | 10×8×8 | 1,3,3 | -X | 2 | No door. A 1-wide, 2-high opening in the -X wall at Y=3 over a hardened-clay threshold at Y=2, with gravel at (0,2,3) outside; the only air route into the room. Trapdoors inside, a water channel, a flower pot and an item frame. |
| basilica | 28×14×16 | 23,3,7 | +X | 2 | Spruce double door at X=23 (Z=7..8) at Y=3 over a stone threshold at Y=2, with stone outside at (24,2,7). Two more single doors at Z=3 and Z=12 on the same +X face, a trapdoor above the central door, and a granite arcade on the outside. |
| temple_of_jupiter | 20×15×27 | 9,3,8 | -Z | 1 | Spruce double door (X=9..10) into the cella at Z=8, over the quartz floor at Y=2 inside the front colonnade; a mirror door at Z=18 faces the rear porch. The clay ground rows (Y=0..1) are Creative mesa terrain. |
| temple_of_vesta | 11×11×11 | 5,2,3 | -Z | 0 | No door. A one-node gap in the cella's north wall (Z=3) between two quartz pillars, over a quartz slab floor at Y=1 inside a ring colonnade; the other three cella walls are closed. Eternal fire on netherrack at the centre. The ground row (Y=0) is orange clay terrain. |
| hippodrome | 37×22×25 | 18,8,3 | -Z | 7 | Opening in the long -Z side's portico: the central arcade gap at X=18, Z=3 (air at Y=8..9) over stone at (18,7,3), aligned with the stair at (18,8,5)-(18,9,6). The west short-end doors at (2,8,7) and (2,8,19), the east end and a south door at (6,8,20) are secondary and not chosen (docs/roman_expansion_layout.md section 6). The surrounding ground row was grassed and graveled in the workshop. Seven buried rows (clay, stone, dirt) hold the underground passage and chambers the owner wants kept, so they stay in the capture. |
| villa | 46×20×26 | 26,2,22 | +Z | 0 | Main double wooden door at X=26..27; courtyard approach at Z=23. Dirt ground row at Y=0. Registered separately for rural Roman outskirts (#229). |

The basilica capture (#211) is the issue's box 53..79 × 7..20 × 415..430,
widened one column to x=52 (the roof eave slabs at Z=420 and 425) and with the
empty top row (Y=20) removed; a Y=6 dirt row is added below, so two dirt rows sit
under the Y=8 grass datum: world box (52,6,415)-(79,19,430), 28×14×16. Its only
doors are on the +X face. The central double door is the main entrance; the
other doors are not chosen. The approach at X=24 is air. The metadata is
eight door states and no inventories.

The vespasianum capture (#207) is the issue's box 285..294 × 7..14 × 406..413
with the empty top row (Y=14) removed and a Y=6 dirt row added below, so two
dirt rows sit under the Y=8 grass datum: world box (285,6,406)-(294,13,413),
10×8×8. It has no doors, so its entrance is the only opening from outside into
the room, not a chosen front door. Its facing (-X) follows from that single
opening; the layout work should confirm which side faces the street.

The #341 captures come from the Creative world (boxes below, inclusive) via
`tools/issue341_import`, placed unrotated at the workshop origins
(100,7,500), (140,8,500) and (170,1,500) with their terrain rows unchanged, and
are fixed landmarks like the others; no entrance was part of the ticket, so the
entrances above are simple picks. Temple of Jupiter is 65,12,1128 x 46,27,1103
without its empty top row, plus the +Z roof row added in the workshop (world box (100,7,500)-(119,21,526), 20×15×27); Temple of Vesta is
18,23,1136 x 8,13,1146 (11×11×11 whole); Hippodrome is -69,6,1234 x -105,27,1258
(37×22×25 whole). No nodes needed mapping. Metadata: Jupiter 9 (door states,
a chest), hippodrome 50 (doors, item frames, signs, chests, fence gates), Vesta 0.

The insula capture (#193) is the issue's box 213..248 × 6..25 × 399..426 with
only the x=0 column and z=27 row of grass and dirt platform removed: world box
(214,6,399)-(248,25,425), 35×20×27. Its dirt rows (Y=0..1), the Y=2 datum row
and the eaves at Y=17 are kept. The front approach row at Z=0 stays inside the
capture. The entrance is the front spruce door, not the wooden door at X=11,
which is a choice for the layout work.

The bath's 88×18×44 capture keeps the basement, ground rows, and all saved
metadata (295 nodes); only the platform margin and empty top rows were
trimmed (#171: world box (101,7,399)-(188,24,441), widened to min Z 398 by #370
to keep the copper pediment row at file Z=0). Its door is recessed four
nodes from the capture edge; the temple
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
resident adapter accepts all eight domus beds, all six bath basement beds and
all 23 insula beds at every rotation; the other assets, including vespasianum
and basilica, have no beds.

See [validation evidence](../../../docs/roman_assets_validation.md) for the
disposable-world run and preserved capture caveats.
