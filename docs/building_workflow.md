# Building workflow: capturing schematics for Towns

Towns buildings are Luanti schematics (`.mts`) stored in `schematics/`. They
are captured from a Creative world with WorldEdit's `//mtschemcreate`, copied
into this repository, and later registered in the building catalog (ticket
#3). WorldEdit is a **capture-time tool only**; Towns must not depend on it at
runtime.

The user should not have to run any of this by hand. A request to an agent
needs four inputs:

1. the source world name or path (for example `Testlandia`, or
   `~/Library/Application Support/minetest/worlds/Home`; paths in this guide
   are macOS examples, so substitute your platform's Luanti user directory and
   binary location);
2. the building's rough location or exact bounding coordinates;
3. the desired stable ID (becomes `schematics/<id>.mts`, for example
   `demo_house`);
4. which side is the main entrance (N/E/S/W, in world axes).

## Canonical orientation

Capture every building so that:

- the **main entrance faces north (-Z)**, in the middle of the front (north)
  edge;
- the schematic includes its full foundation; if layers sit below site ground,
  record their depth as `ground_offset` in the catalog;
- the schematic's **minimum X, Y, Z corner is its placement origin**
  (`//pos1` for `//mtschemplace`, `pos` for `minetest.place_schematic`);
- everything is stored with the entrance north; rotation is applied only at
  placement time.

Towns' catalog is canonical-orientation-only: the entrance is always on the
-Z edge. A building whose entrance is on another side must be re-oriented
before capture (for example, rotate it with WorldEdit `//rotate` in a copy of
the world), so that the captured file is canonical.

## Reference: `demo_house`

`schematics/demo_house.mts` is the first handmade test building (VoxeLibre
nodes only, no third-party media).

| Property | Value |
| --- | --- |
| Size (x, y, z) | **9 x 8 x 7** nodes (width x height x depth) |
| Entrance (door bottom node), offset from min corner | **(4, 1, 0)**, door in the north wall, facing north (-Z); the door top is (4, 2, 0) |
| Ground layer | y = 0 is the cobblestone foundation / plank floor (the door sits on y = 1, so the door sill is one node above the lowest layer) |
| Rotation cue | stone-brick chimney on the **east** wall, rising to y = 7 at (8, y, 3); windows on the west, north and south walls but none on the east |
| Contents | oak plank walls, oak log corners, stair roof (ridge along X), glass, a red bed (SW corner, nodes (1,1,5) and (1,1,4)), crafting table (6,1,5), furnace (7,1,3) |
| Metadata | none needed (the furnace is empty) |

Rotations as measured by placing the repo file at a position `P` with
`minetest.place_schematic` (a rotated schematic always keeps its bounding-box
minimum corner at `P`):

| Rotation | Footprint x by z | Door (bottom node) offset from `P` | Chimney top offset from `P` | Entrance faces |
| --- | --- | --- | --- | --- |
| 0 | 9 x 7 | (4, 1, 0) | (8, 7, 3) | north (-Z) |
| 90 | 7 x 9 | (0, 1, 4) | (3, 7, 0) | west (-X) |
| 180 | 9 x 7 | (4, 1, 6) | (0, 7, 3) | south (+Z) |
| 270 | 7 x 9 | (6, 1, 4) | (3, 7, 8) | east (+X) |

The table above is the measured ground truth for `demo_house`; ticket #3
should derive the general rotation formula and test it against these four
rows.

## Capturing a building

### 1. Pick a source world

- **New Creative world:** create it in Luanti with the VoxeLibre game
  (`mineclone2`), Creative mode, and build the structure. Add
  WorldEdit to `world.mt` (below).
- **Existing world:** the capture does not modify terrain, but loading a world
  with an extra mod writes to it (map, mod storage). **Work on a copy** of any
  valuable world (`cp -R <world> <scratch>/<world>_copy`) and capture from the
  copy.

Enable WorldEdit for the world by adding these lines to its `world.mt` if
they are not already there (macOS example: WorldEdit lives in
`~/Library/Application Support/minetest/mods/worldedit/`):

```
load_mod_worldedit = mods/worldedit/worldedit
load_mod_worldedit_commands = mods/worldedit/worldedit_commands
load_mod_worldedit_shortcommands = mods/worldedit/worldedit_shortcommands
```

(An `ERROR ... worldedit_gui requires a supported gui management mod` line at
startup is harmless when `worldedit_gui` is not loaded or has no GUI mod.)

### 2. Choose exact bounds

Find the smallest axis-aligned box that holds the whole building **plus its
ground-level floor/foundation layer** and nothing else you do not want
(surrounding terrain, trees, neighbours). Record it as two corners
`pos1 = (minX, minY, minZ)` and `pos2 = (maxX, maxY, maxZ)`. For the
canonical orientation:

- `minZ` is the front (north) wall's outer face; the entrance is centered
  along X in that wall;
- `minY` is the foundation layer.

Record the entrance's file-local `(x, y, z)` position. A recessed entrance may
have `z > 0`. The catalog uses `ground_offset` to place the bottom layer below
the site's surface; it defaults to zero.

To find bounds in a world that the user has not described precisely, an agent
can read the map directly (for example by running a small throwaway world mod
that scans a region with `minetest.get_node`, or by asking the user for the
coordinates of two opposite corners shown in the F5 debug screen).

### 3. Select and capture

In game, with the `worldedit` privilege, run these WorldEdit chat commands.
Select the corners either by standing on each corner node and running
`//pos1` and `//pos2`, or by coordinates with `//fixedpos`:

```
//fixedpos set1 <minX> <minY> <minZ>
//fixedpos set2 <maxX> <maxY> <maxZ>
//mtschemcreate <id>
```

Without a player in game, an agent can drive the same code headlessly. This
is exactly what was done for `demo_house`:

1. Create a throwaway world mod at `<world>/worldmods/<helper>/` with
   `mod.conf` (`name = ...`, `depends = worldedit_commands`) and an
   `init.lua` that, after the server starts (`minetest.register_on_mods_loaded`
   plus `minetest.after(1, ...)`), emerges the area, then:

   ```lua
   worldedit.pos1["capture_agent"] = vector.new(x1, y1, z1)  -- min corner
   worldedit.pos2["capture_agent"] = vector.new(x2, y2, z2)  -- max corner
   minetest.registered_chatcommands["/mtschemcreate"].func("capture_agent", "<id>")
   minetest.after(1, minetest.request_shutdown)
   ```

   Important: the area must be **loaded** (`minetest.emerge_area`) before the
   capture, otherwise unloaded blocks are saved as `ignore`/air.
2. Start the world headless with its own port and log (the binary path is
   the macOS example; use your platform's `luanti` executable):

   ```
   /Applications/luanti.app/Contents/MacOS/luanti --server \
     --world "<world path>" --gameid mineclone2 --port 30141 --logfile <log>
   ```

   The helper shuts the server down when finished. No game session may have
   the world open at the same time. (Do not use this on a world with a client
   attached, and use a free `--port`; other agents may be running servers.)
3. The result is `<world>/schems/<id>.mts` (the command itself prints nothing
   to the console, so check the file exists).

Filenames allowed by WorldEdit are letters, digits, spaces and a few
punctuation characters; use `lowercase_with_underscores` for IDs.

### 4. Copy and register

```
cp "<world>/schems/<id>.mts" schematics/<id>.mts
```

Commit the `.mts` (it is a small binary). Registration in the catalog is
done by ticket #3's mechanism; until it exists, record the ID, size and
entrance offset in the PR description. Remove any throwaway helper mod from
the world afterwards.

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
doorway and read the coordinates from the F5 debug screen. For the canonical
orientation, the offset's z is 0 (front edge) and x is the building's center
column.

### Four rotations

`//mtschemplace` loads from `<world>/schems/<id>.mts`, not from this repo.
First copy the repo file there:

```
cp schematics/<id>.mts "<world>/schems/<id>.mts"
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
bounding-box minimum corner stays at `P`, (c) the entrance faces west at 90,
south at 180, east at 270, and (d) the asymmetric cue moves with it (for
`demo_house` the chimney is on the east side at 0, north at 90, west at 180,
south at 270).

Place in a clear, loaded area: `place_schematic` is synchronous only for
loaded blocks. Placement overwrites everything in the (rotated) box including
with air; there is no undo.

### In game: `/towns_test`

`/towns_test <building_id> <rotation>` (`server` privilege) places a
registered building and its paved square next to where you stand, and prints
the building ID, rotation and exact combined bounds. **It overwrites the site
immediately, with no preview or confirmation**: only use it in a disposable
Creative world such as Testlandia.

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
