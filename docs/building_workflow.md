# Building workflow: capturing and registering buildings for Towns

Towns buildings are Luanti schematics (`.mts`). The agent does all capture,
export and registration work by running the commands below itself; the user is
not asked to run anything. The primary path is the workshop exporter
(`tools/workshop_export/`), which produces `schematics/templates/*.mts` and the
generated `schematics/templates/catalog.lua`. See also
[the exporter README](../tools/workshop_export/README.md).

Principles:

- Capture only structures the user supplied. Do not procedurally invent the
  building library.
- WorldEdit is a capture-time tool (legacy raw captures only); Towns must not
  depend on it at runtime.
- The planner does not alter architecture or add clearance. Side windows,
  eaves and setbacks must be designed inside the captured box so that
  buildings work when placed next to each other.
- Orientation is canonical: the front/entrance faces the **-Z** edge of the
  file. Rotation (+X, -X, +Z, -Z facing) is applied only at placement time.
  Compass labels are avoided here because they are ambiguous (+Z is north in
  Luanti).

## Inputs for a request

1. the source world name or path (for example `TownsWorkshop`,
   `~/Library/Application Support/minetest/worlds/TownsWorkshop`; paths are
   macOS examples);
2. the building's rough location or exact bounding coordinates in that world;
3. the stable ID (`lowercase_with_underscores`, becomes
   `schematics/templates/<id>.mts`) and a `role` (see below);
4. which side of the build is the front, in world axes (+X, -X, +Z or -Z).

## Reference: `demo_house`

`schematics/demo_house.mts` is the first handmade test building (VoxeLibre
nodes only, no third-party media).

| Property | Value |
| --- | --- |
| Size (x, y, z) | **9 x 8 x 7** nodes |
| Entrance (door bottom node), offset from min corner | **(4, 1, 0)**, door in the -Z wall, facing -Z; door top is (4, 2, 0) |
| Ground layer | y = 0 is the cobblestone foundation / plank floor (door sits on y = 1) |
| Rotation cue | stone-brick chimney on the +X wall, rising to y = 7 at (8, y, 3); windows on the -X, -Z and +Z walls but none on the +X wall |
| Contents | oak plank walls, oak log corners, stair roof (ridge along X), glass, a red bed at (1,1,5) and (1,1,4) (the -X/+Z corner), crafting table (6,1,5), furnace (7,1,3) |
| Metadata | none needed (the furnace is empty) |

Measured by placing the repo file at `P` with `minetest.place_schematic` (a
rotated schematic keeps its bounding-box minimum corner at `P`):

| Rotation | Footprint x by z | Door (bottom node) offset from `P` | Chimney top offset from `P` | Entrance faces |
| --- | --- | --- | --- | --- |
| 0 | 9 x 7 | (4, 1, 0) | (8, 7, 3) | -Z |
| 90 | 7 x 9 | (0, 1, 4) | (3, 7, 0) | -X |
| 180 | 9 x 7 | (4, 1, 6) | (0, 7, 3) | +Z |
| 270 | 7 x 9 | (6, 1, 4) | (3, 7, 8) | +X |

## Registering a building (exporter path)

The exporter does not use WorldEdit or `//mtschemcreate`. It snapshots the
source world's `map.sqlite`, scans each building's region in a disposable
copy, writes the `.mts`, a `.lua` metadata file and `catalog.lua`, and
verifies the result at all four rotations.

1. **Work on a copy** of any valuable world; the exporter itself never writes
   to the source world, but you should still build/edit in a copy.
2. **Add or edit the entry** in `tools/workshop_export/buildings.json`
   (`role` goes at the top level of the building object). Fields:

   | Field | Meaning |
   | --- | --- |
   | `id`, `label` | catalog ID and display label |
   | `scan_min`, `scan_max` | source world survey box; the build must not reach its edges |
   | `floor_y` | Y of the finished floor layer |
   | `rotation` | 0/90/180/270, by which source side is the front: front on -Z is 0, +X is 90, +Z is 180, -X is 270 |
   | `entrance` | **world** coordinates of the door bottom node (or walk-in opening node) in the source |
   | `entrance_kind` | optional, `"door"` (default) or `"opening"` |
   | `role` | optional here, but registration tickets must set it: `house`, `shop`, `workshop`, `tavern`, `well`, `cathedral`, `castle`, `city_hall`, `chapel`, `jail` |
   | `label_position` | optional world position of a workshop label sign to exclude from the capture |
   | `capture_min`, `capture_max`, `ground_y` | optional fixed capture box (see clearance below) |

   Example (source front already faces -Z, so `rotation` is 0):

   ```json
   {
     "id": "example_house",
     "label": "Example house",
     "scan_min": {"x": 96, "y": 8, "z": 96},
     "scan_max": {"x": 112, "y": 24, "z": 110},
     "floor_y": 8,
     "rotation": 0,
     "entrance": {"x": 104, "y": 9, "z": 101},
     "label_position": {"x": 100, "y": 9, "z": 95},
     "role": "house"
   }
   ```

   Suppose the non-air nodes span x 100..108, y 8..17, z 100..106. The
   exported size is 9 x 10 x 7 and the entrance, relative to the min corner
   after rotation, is `(104-100, 9-8, 101-100) = (4, 1, 1)`. The generated
   catalog entry is:

   ```lua
   ["example_house"]={["path"]="schematics/templates/example_house.mts",
     ["size"]={["x"]=9,["y"]=10,["z"]=7},
     ["entrance"]={["x"]=4,["y"]=1,["z"]=1},["entrance_kind"]="door",
     ["data_path"]="schematics/templates/example_house.lua",
     ["role"]="house"}
   ```

   The entrance offset is wherever the door really is: it is not centered, and
   z is not necessarily 0 (real catalog values: 0 for `mason_yard`, 1 for most,
   2 for `townhouses`, `scribe`, `banker_house`, `butcher_shop`, `chapel`, 4
   for `gaboo_house`, 6 for `castle`, 8 for `cathedral`; x is off-centre, for
   example 2 of 8 for `tower`, 8 of 11 for `jail`). `entrance.y` is 1 for buildings captured
   from the floor row (defaults to 1 in the runtime catalog), 2 for the ones
   that keep a ground row below the floor (`weaver_house`, `chapel`, `tavern`,
   `corner_house`, `townhouses`); landmarks differ (castle 6, cathedral 5).
3. **Regenerate with `--only`**, from the Towns mod directory:

   ```sh
   python3 tools/workshop_export/export.py \
     --world "$HOME/Library/Application Support/minetest/worlds/TownsWorkshop" \
     --only <id> --validate
   ```

   Always pass `--only <id> [<id> ...]`. An unfiltered run re-exports every
   building in `buildings.json` from whatever world you point it at; if that
   world is not the one the other buildings were authored in, their templates
   would be overwritten with wrong or empty content. With `--only`, other
   buildings' templates, catalog entries and manifest records are left
   unchanged.
4. **Commit** `buildings.json` and the regenerated files in
   `schematics/templates/`. Generated files are never hand-edited.

### What an unattended export requires

- Luanti at the default engine path
  (`/Applications/luanti.app/Contents/MacOS/luanti`; otherwise `--engine`),
  with the same game (`mineclone2`) and node mods as the source world.
- Port 39487 free (`--port` to change).
- The source world saved and closed first, so `map.sqlite` holds the latest
  edits. The exporter reads a read-only snapshot of `map.sqlite`; it never
  installs anything in or writes to the source world.
- Both engine runs (export, then `--validate`) have a 180 second timeout.

### What the exporter keeps and trims

Bounds are recomputed from non-air nodes above the finished floor (plus
stairs on the floor layer); the floor layer under that footprint is kept, and
workshop labels, loose terrain outside the footprint and buried layers are
dropped. **Empty outside rows/columns and empty top layers are trimmed**, so
intended side clearance, eaves or setbacks survive only if they contain
non-air nodes or the entry sets a fixed box with `capture_min` /
`capture_max` and `ground_y` (see the castle and cathedral entries in
`buildings.json`). Use a fixed box when empty clearance must be preserved; the
build must fit inside it or the export fails.

`ground_offset` is derived, not authored: `(ground_y or floor_y) - min Y of
the capture`. Ordinary buildings get 0 (omitted from the catalog); it is
non-zero only for fixed-box landmarks with `ground_y` above the capture's
bottom (castle 5, cathedral 1).

A building that stands on a plinth with steps up to its door (stairs on the
floor row) must keep the terrain row below its floor in the capture: set
`floor_y` and `ground_y` to the terrain row and use a fixed `capture_min` /
`capture_max` box starting there. The placer puts row 0 at street level, so the
floor then stands one block above the street and the stairs are real steps
(`entrance.y` 2, `ground_offset` 0). Capturing from the floor row instead sinks
the floor flush with the street (#87: weaver_house, chapel, tavern,
corner_house).

### Role in the generated catalog

The 13 existing workshop templates currently have **no `role`** in the
generated catalog; only `castle` and `cathedral` do. A registration ticket
adds `role` to the building's `buildings.json` entry and re-exports it with
`--only`.

### Direct entries in `src/catalog.lua`

Hand entries are the exception, used for the `demo_house` reference only.
Template entries with the same ID override a hand entry. Do not use this for
new captures.

## Non-destructive front normalization

If the source front is not on -Z, set `rotation` in `buildings.json` so the
exported file has the front on -Z. Never `//rotate` the source build.

## Per-building checklist

- [ ] Source build is in a copy of the world; saved and closed.
- [ ] Front/entrance side is known in axes (+X, -X, +Z, -Z); `rotation`
      brings it to -Z.
- [ ] `scan_min`/`scan_max` hold the whole building with margin; `floor_y` is
      the finished floor layer.
- [ ] Intended side clearance/eaves kept: non-air nodes, or `capture_min` /
      `capture_max` / `ground_y` set.
- [ ] `entrance` (world coords) is the door bottom node (or the opening
      node, with `entrance_kind: "opening"`).
- [ ] `role` set at the building object's top level.
- [ ] Record exact size, entrance XYZ (file-local), source coordinates, beds,
      and service nodes (chests, furnaces, signs; metadata is not in `.mts`)
      and any initialization needs; "none" if self-contained.
- [ ] Export with `--only <id> --validate`.
- [ ] Check all four rotations (0/90/180/270) in a disposable destination:
      footprint swaps X/Z at 90/270, min corner stays at `P`, entrance faces
      -Z, -X, +Z, +X, asymmetric cues rotate with it.
- [ ] Place two copies adjacent in a disposable destination and check walls,
      windows, doors and eaves do not collide or look misaligned.
- [ ] Commit `buildings.json` and regenerated `schematics/templates/` files.

## Legacy raw capture (WorldEdit)

Only for structures outside the workshop pipeline (historical raw captures in
`schematics/captures/`, and `demo_house`). Enable WorldEdit in the world copy's
`world.mt` (`load_mod_worldedit`, `load_mod_worldedit_commands`,
`load_mod_worldedit_shortcommands`, with paths under your Luanti `mods/`),
select the box with `//fixedpos set1/set2` (or `//pos1`/`//pos2`), run
`//mtschemcreate <id>`, and copy `<world>/schems/<id>.mts` to `schematics/`.
The area must be loaded (emerged) first or unloaded blocks capture as air.
Headless capture can be driven from a throwaway world mod that calls the
registered `/mtschemcreate` command after `minetest.emerge_area`; use its own
`--port` and `--logfile`, and remove the helper afterwards. Raw captures are
historical references and are never used to overwrite workshop edits.

## Inspecting a schematic

### Dimensions

The `.mts` header is `"MTSM"`, a u16 version, then u16 x, y, z sizes
(big-endian). With the repo's Lua 5.1:

```lua
local f = assert(io.open(arg[1], "rb")); local h = f:read(12); f:close()
assert(h:sub(1, 4) == "MTSM", "not an .mts file")
local function u16(i) return h:byte(i) * 256 + h:byte(i + 1) end
print(("version %d, size x=%d y=%d z=%d"):format(u16(5), u16(7), u16(9), u16(11)))
```

`demo_house.mts` prints `version 4, size x=9 y=8 z=7`.

### Entrance offset

Place the schematic with rotation 0 at a known position `P` and read the
door's position: entrance offset = door position - `P`. In game, stand in the
doorway and read the coordinates from the F5 debug screen. Read the entrance
from the building; do not assume it is centered or flush with the edge (only
`demo_house` and `mason_yard` have z = 0).

### Four rotations (optional, legacy manual check)

`export.py --validate` already checks all four rotations. This manual
procedure is only for extra visual inspection or for files outside the
exporter. `//mtschemplace` loads from `<world>/schems/<id>.mts`, not from this repo.
First copy the repo file there:

```
cp schematics/templates/<id>.mts "<world>/schems/<id>.mts"
# (demo_house lives at schematics/demo_house.mts)
```

Luanti caches loaded schematics, so if an older version of `<id>.mts` was
already loaded in that world, restart the server after replacing the file.
Then, with `//pos1` set at a clear spot (use a different spot for each
rotation):

```
//mtschemplace <id> 0
//mtschemplace <id> 90
//mtschemplace <id> 180
//mtschemplace <id> 270
```

or programmatically `minetest.place_schematic(P, path, "90")` for each
rotation. Check, for each: (a) the footprint swaps x and z at 90/270, (b) the
bounding-box minimum corner stays at `P`, (c) the entrance faces -X at 90, +Z at 180 and +X at 270, and (d) the
asymmetric cue moves with it (for `demo_house` the chimney is on the +X side
at 0, -Z at 90, -X at 180, +Z at 270).

Place in a clear, loaded area: `place_schematic` is synchronous only for
loaded blocks. Placement overwrites everything in the (rotated) box including
with air; there is no undo.

### In game: `/towns_test`

`/towns_test <building_id> <rotation>` (`server` privilege) places a
registered building and its paved square next to where you stand, and prints
the building ID, rotation and exact combined bounds. **It overwrites the site
immediately, with no preview or confirmation**: only use it in a disposable
Creative world such as Testlandia.

## Placed node initialization (ticket #46)

`core.place_schematic` runs no node callbacks, so the town placement path
(`/towns_generate`, `builder.build_town`) places every schematic without
constructors and then, once all schematics and door routes succeeded, runs
`src/node_setup.lua` inside the placed boxes only. It initializes just the
functional nodes present in the registered templates:

| Nodes | Initialization |
|-------|----------------|
| `mcl_jukebox:jukebox`, `mcl_barrels:barrel_closed`, `mcl_furnaces:furnace`, `mcl_smoker:smoker`, `mcl_blast_furnace:blast_furnace`, `mcl_brewing:stand_000`, `mcl_books:bookshelf`, `mcl_composters:composter`, `mcl_grindstone:grindstone`, `mcl_campfires:campfire_lit`, `mcl_chests:black_shulker_box_small` | `on_construct` (inventory lists, formspec, particles) |
| `mcl_itemframes:frame`, `glow_frame`, `invisible_frame`, `plate` | `on_construct`, then item display refresh |
| `mcl_fences:fence_gate`, `mcl_crimson:warped_fence_gate` | `on_construct` (state meta) |
| `mesecons_pressureplates:pressure_plate_wood_off` | `on_construct` (starts the node timer) |
| `mcl_dispensers:dispenser` | `after_place_node` without a placer (inventory, formspec) |
| `mcl_chests:chest_small/left/right`, `trapped_chest_small/left/right` | inventory lists `main` 27 and `input` 1 if absent, chest entity refresh (the chest constructor also merges neighbouring chests, so it is not called) |
| `mcl_armor_stand:armor_stand` | entity spawned if none is there |

Saved metadata and inventories are snapshotted before and restored after every
callback, so bed claims, `villager` fields and stocked inventories survive and
repeated calls are harmless (completion is recorded per placement and node).
Beds, doors, bells, lecterns, looms, the pulpit and similar nodes have no
registered initialization and are left alone. A required node that has an
`on_construct` or is a container and is neither supported nor listed in
`node_setup.NOT_REQUIRED` is reported as `unhandled` in the build summary and
log. No loot, guest policy, bed enumeration or villagers happen here (#47,
#48). Adding a template that uses a new functional node requires extending
`node_setup.SUPPORTED`; `tests/node_setup_tests.lua` fails until it is either
supported or listed as not required.

## Caveats

- **Caching.** Luanti caches schematics once loaded. After replacing a `.mts`
  file, restart the server (or at least the world) before checking placement;
  otherwise you may see the old version.
- **Metadata is not stored.** `.mts` keeps node names, `param1` probability
  and `param2` (facing/orientation) only. It does **not** store node metadata:
  chest and furnace inventories, sign text, book contents, bed ownership,
  spawner settings, and similar. During capture, list any such nodes in the
  region (`minetest.get_meta(pos):to_table()`), and recreate them separately
  after placement if needed. `demo_house` has none.
- **Ground contact.** The schematic includes its foundation layer but does not
  store the terrain around it; terrain preparation is the placer's job.
- **Beds and doors** keep their paired halves and facing in `param2`; check the
  rotated result in game (ticket #4) rather than assuming.
- **Generated files are authoritative.** `schematics/templates/catalog.lua`,
  `.mts` files, and `.lua` metadata are all produced by the exporter and
  regenerated for the exported buildings on each run. Do not hand-edit them; edit the source
  `tools/workshop_export/buildings.json` or the TownsWorkshop world instead,
  then re-export.

## Recorded round trip (ticket #2)

All in the disposable `Testlandia` world (MineClone2, creative), headless
Luanti 5.17.0, WorldEdit from `~/Library/Application Support/minetest/mods/worldedit`.

- **Source build** at min corner `(100, 150, 100)`, built with `set_node`
  from a throwaway world mod in an otherwise clear area above the terrain.
- **Source bounds:** `pos1 = (100, 150, 100)`, `pos2 = (108, 157, 106)`.
- **Capture:** `//mtschemcreate demo_house` through WorldEdit's registered
  chat command, producing `Testlandia/schems/demo_house.mts` (423 bytes), copied
  to `schematics/demo_house.mts`.
- **Dimensions** (read from the file header): 9 x 8 x 7.
  **Entrance offset:** (4, 1, 0).
- **Destination:** the repo file was copied back to `Testlandia/schems/` and
  placed with `//mtschemplace demo_house 0` at `(160, 150, 100)`, after
  clearing a box extending 3 nodes beyond the schematic on each side.
  Check: all 504 nodes (name and `param2`) match the source; 0 non-air
  nodes outside the 9 x 8 x 7 box; the destination `(0,0,0)` is cobblestone and
  `(4,1,0)` is `mcl_doors:wooden_door_b_1`.
- **Rotations:** placed at 0/90/180/270 and measured as in the table above.
- **Not covered:** a visual in-game inspection (the run was headless).

## Edited TownsWorkshop templates

The thirteen imported Home buildings now have game templates in
`schematics/templates/`, generated catalog entries, and runtime decoration
initialization. See [the repeatable workshop exporter](../tools/workshop_export/README.md)
for source regions, trimming rules, re-export commands and validation.

Open-front shops and yards may record a walk-in entrance instead of a door.
The exporter checks two clear air nodes over a solid floor and records
`entrance_kind = "opening"` alongside the usual XYZ entrance offset.
