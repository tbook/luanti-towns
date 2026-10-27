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

The exporter rereads each saved `.mts` and checks its wall names against its
stored neighbours before placing it with the inverse rotation. It then compares
node names and param2 to the source, allowing wall names to be recomputed from
source neighbours. `--validate` additionally
runs a smoke check through the runtime helper: it places the complete catalog
(including the castle) at all four rotations and checks that each placement
succeeds, leaves no unloaded cells, places non-air nodes, has a working
entrance, and restores saved metadata fields and inventory contents. Runtime
placement may normalize node names and param2 values, so this check focuses on
placement behavior rather than raw voxel equality. Snapshot paths and logs are
printed for inspection if a check fails.

VoxeLibre walls store their connections in node names. After rotating a source,
the exporter recomputes each wall name from its neighbours inside the template
box and verifies that the saved orientation has no mismatches. Runtime placement
keeps the same recomputation as a safeguard for older shipped templates and for
rotated placements. Existing shipped templates are intentionally left as-is;
outside-facing wall arms are dropped by this rule because neighbours beyond the
template box are not part of the schematic.

Reload the game after replacing schematics because Luanti caches them. To
look at a template on its own, copy it to a world's `schems` directory and use
WorldEdit's `//mtschemplace`; towns place them through `/towns_generate`.
The catalog IDs are `tower`, `leather_worker`,
`corner_house`, `jail`, `townhouses`, `weaver_house`, `scribe`, `gaboo_house`,
`office_building`, `banker_house`, `butcher_shop`, `mason_yard`, and `chapel`.
The `armory`, `castle`, `cathedral` compound and the hand-made `demo_house`
are also in the catalog.

Placing a template (`src/schematic.lua`, used by `/towns_generate`)
reconstructs containers and decorations, restores inventory contents and door
state, and creates their display entities. It does not import source
villagers, bed ownership, simulation timestamps or formspecs with old world
coordinates. Villagers and other independent entities are not schematic
contents. Gaboo and the townhouses require **mcl_decor**. The chapel requires
**mcl_decor** for chairs and **living_villages** for its pulpit. The town
preflight reports unavailable nodes before anything is changed.

The exporter reads the selected world from a consistent, read-only snapshot.
It never overwrites workshop edits. The templates are registered for the
building catalog and placed by the town generator.

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

The active castle keeps its authored optional-mod furnishings. Both landmarks
require mcl_decor and Living Villages for authored furnishings.
Foliage constructors that would recompute palette/flags are skipped, preserving
saved colors while functional node initialization and inventories still run.

Landmark bounds and source settings are recorded in `buildings.json` and the
generated template manifest.

## Reimports from issue #130

The updated TownsWorkshop versions of the jail, cathedral/monastery, butcher
shop, corner house, Gaboo house, townhouses, banker house and castle are
captured in their saved source bounds. The cathedral compound now includes
the extra source layer at y=6 so the stone floor beneath the monastery library
is retained. The armory is a new workshop at source x=210..218, y=9..14,
z=301..310; its entrance is (214,10,303), and its source front already faces
-Z.

Gaboo house keeps its three beds in the schematic, but two beds that can only
be reached by ladder are excluded from Towns' resident spawning. The
`excluded_resident_beds` building field stores canonical schematic offsets;
placement rotates those offsets with the building before bed enumeration.

## Stock village templates (tavern, well, library, blacksmith)

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
  kept. The tavern keeps its dirt layer (stock y 0) as the template ground
  row (`floor_y` and `ground_y` 7, `ground_offset` 0) with the floor on the
  next row, so the floor stands one block above the street (#87): 12 x 13 x 10
  as authored (door on the -X side, `rotation` 270), which is 10 x 13 x 12 in
  the canonical -Z-front file, entrance y 2. The well keeps its dirt layer, because its standing apron is air at
  stock y 1 over that dirt: 6 x 7 x 8, front already on -Z.

`library` (role `shop`) and `blacksmith` (role `workshop`, #112) come from the
same scratch world and the same seeder, which places them at (180,7,100) and
(220,7,100) beside the tavern and well (regenerate with `--only library
blacksmith`; the world needs a valid `[end_of_params]` line in `map_meta.txt`
and a clean `worldmods/stock_seed` that is a copy of the directory, not nested).

- Library: stock 12 x 9 x 12 with bookshelves but no jobsite: Living
  Villages' `library_schematic.lua` replaces the wooden stair at stock (6,2,9)
  with a `mcl_lectern:lectern` so a librarian can exist;
  `stock_seed` does the same, and the stock cell is asserted before the edit.
  Real door at stock (2,2,7) on the -X side (`rotation` 270) behind two stair
  rows on the floor row; the second door at (10,2,5) is internal. Dirt row kept
  (`ground_y` 7), box x 180..191, z 101..110 (the stock z 0 and z 11 rows are
  empty): 10 x 8 x 12, entrance (3,2,2), `ground_offset` 0. It is 12 deep.
- Blacksmith: stock 8 x 8 x 11, no Living Villages furnishing step (only
  `mcl_villages` and the village job sites). Open-front smithy on the -X side
  (`rotation` 270, `entrance_kind` opening at stock (2,2,7): the floor under
  it is cobble, with the half-step stair outside at (1,1,7)); the only door,
  (2,2,5), is internal to the back room. Four enclosed lava sources under a
  chimney, anvil, blast furnace (`mcl_blast_furnace`), chest. Box x 221..227,
  z 101..109: 9 x 7 x 7, entrance (2,2,1), `ground_offset` 0.

A selective export (`--only`) keeps the manifest's top-level `world` and
`snapshot_sha256` untouched, so exporting these two from a scratch world does
not rewrite provenance; each building record carries its own snapshot hash.
The top-level `snapshot_sha256` therefore only names the last full export;
the per-building hashes are authoritative and legitimately differ between
buildings (several `--only` runs, and the tavern/well come from a scratch
world). `last_export_buildings` lists the buildings of the most recent
`--only` run, so when one change re-exports buildings in several runs (as
#87 did: weaver_house, chapel, corner_house and townhouses from TownsWorkshop,
tavern from the stock scratch world) the list is set by hand to the union.
Attribution for the two files is in
`schematics/templates/NOTICE-stock-village.md`.

## tavern_2 (workshop tavern, #96)

`tavern_2` (role `tavern`) is the TownsWorkshop tavern at source x 206..221,
y 6..16, z 267..273 (the five item frames on the west wall at x 206 are part of
the build, one block outside the ticket's x 207..221). The first export used
the door at (220,9,272) on the source's +X side (`rotation` 90), which put the
building's back toward the street. Since #189 the front is the other ground
door, at (211,9,271) on the source's -X side (`rotation` 270). The floor (mud
bricks, source y 8) is flush with the surrounding terrain in the source, with
a two-row cellar and its stair below, so the capture keeps rows y 6..7
(`ground_y` 8, `ground_offset` 2) and the floor stays flush with the street,
as authored: 7 x 11 x 16 in the canonical file, entrance (2, 3, 5).
Intentionally omitted: source y 5, the
cellar's lowest row (furnace, smoker, the bottom granite stair step, a wood
row and cobble there; the rest of that layer is the world's bedrock, over
`mcl_core:void` at y 4 and below). Capturing it would put bedrock and void
cells at street minus 3, and the exporter has no bedrock-to-dirt mapping, so
the template starts at y 6. Consequences: the cellar furnace and smoker are
not in the template, the stair ends one step short of the bottom, and the
cellar's row 0 sits directly on whatever terrain is at street minus 3 (the
town site is flattened and filled, so a cave or liquid opening into it is
unlikely but not excluded). `tavern_2` is placed in towns: as one of the
medieval tavern variants drawn for the service slots, and in all three Roman
tavern slots.

## soup_shop (Home world, #110)

`soup_shop` (role `shop`) is a build in the **Home** world, not TownsWorkshop.
Any world can be the source: the exporter takes it from `--world`, and
`buildings.json` only holds coordinates, so the entry is exported with
`--only` against that world:

```sh
python3 tools/workshop_export/export.py \
  --world "$HOME/Library/Application Support/minetest/worlds/Home" --only soup_shop
```

Home is a normal-mapgen world, so `--validate` against it fails for every
template containing `dirt_with_grass` (the runtime constructor paints the
grass colour from the biome at the test site, not from the saved node). Run the
validation from TownsWorkshop instead; it checks the whole catalog, soup shop
included: `--world <TownsWorkshop> --only office_building --validate`
(an idempotent re-export of an unchanged build). Set `last_export_buildings`
in the manifest by hand afterwards.

Source box x 240..246, y 7..16, z 233..241 (the ticket's "246,6,233 x
240,17,241"; y 6 is natural stone below the cellar and y 17 is air). The
build has no door node anywhere: it is a serving-counter shop with open
storefronts. The chosen entrance is the walk-in gap in the south wall at
(244,12,234) (`entrance_kind = "opening"`, front -Z, `rotation` 0), reached by
four cobble steps at z 233. The same stairs wrap round the +X side, where a
second gap at (246,12,235) is a counter window with its own stair run.

Floor and ground: the floor row (cobble/granite, y 11) stands one block above
the street (path/grass at y 10), exactly like the #87 buildings, so the ground
row y 10 is kept (`ground_y` 10) together with the cellar below it:
`capture_min.y` 7, `ground_offset` 3, entrance (4, 5, 1), 7 x 10 x 9.

Cellar (3 x 3 interior at x 242..244, z 237..239, y 8..10): mycelium at y 7
with brown/red mushrooms at y 8, a ladder up to a spruce trapdoor in the floor
at (242,11,239), one wall torch. It is enclosed on every side by the
template's own dirt walls, the mycelium floor and the floor row, so nothing
opens to the terrain below. Row y 7 outside the cellar is natural stone,
granite and some dirt that the fixed box captured; row y 6 (natural stone) is
omitted. No bedrock or void is involved at this depth.

`clip_to_capture` (new optional entry field): the building to the north has
eave slabs at z 242 (y 16) that fall inside the survey margin the exporter
requires around the structure, so the whole-survey bounds check would either
fail or capture them. With `clip_to_capture: true` and a fixed capture box,
only the box is surveyed and anything outside it is ignored (the check that a
build does not escape its box is skipped for such entries).

Contents: one bed, two barrels, a crafting table, six item frames, three wall
torches, a ladder, a trapdoor, two bark-slab roof corners. The back strip at
floor height (grass and path at z 241 and along x 246) is terrain that sits
inside the box and is captured with it. The planner has no corner-lot concept: the soup shop is
placed like any other shop and has no preferred position.

## Town hall (`tower`, #126)

The `tower` entry (role `city_hall`, label "Town hall") is the TownsWorkshop
town hall: the former 8 x 50 x 8 cobble tower with a diorite hall built round
its foot. The catalog id stays `tower` so it remains the only `city_hall` entry
(the planner takes the first sorted id of the role). Source box x 93..113,
y 8..57, z 200..217 (the upper tower reaches z 200, one node beyond the hall
body); front is +X (door at (105,10,209), `rotation` 90). The terrain row y 8
is kept (`floor_y` and `ground_y` 8, `ground_offset` 0), so the hall floor
(y 9) is one block above the street with real porch steps, as authored:
18 x 50 x 21 in the canonical file, entrance (9, 2, 8). The standing sign at
(104,9,197) is the workshop label and is excluded; a 5-wide diorite_smooth
paving strip (source x 109..113, y 8) in front of the porch is part of the
capture.
