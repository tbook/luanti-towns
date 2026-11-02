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

## Reimport workflow (all TownsWorkshop buildings)

`tools/reimport.py` is the one entry point for re-importing buildings you edited
in TownsWorkshop. It orchestrates the exporters below (template path
`workshop_export/export.py`, Roman path `issue139_import/export_roman.py`,
outskirts path `issue196_import/export.py`) and picks the right one per id, so
you do not need to remember which is which. Close the game and return to the
menu first so your edits are saved; the tool refuses to run on an open world.

```sh
python3 tools/reimport.py                       # compare: what changed? (repo untouched)
python3 tools/reimport.py compare --json /tmp/report.json
python3 tools/reimport.py apply --ids chapel,hippodrome
python3 tools/reimport.py apply --all-changed
lua5.1 tests/run.lua                            # then review the repo diff
```

Reading `compare` (about 15 s; it exports into a scratch copy of `tools/` and
`schematics/` and discards it, so nothing is written to the repo):

- `UNCHANGED`: the re-export is node-for-node and sidecar-identical.
- `CHANGED`: node names, param2, metadata/inventories or other manifest fields
  differ; the node diff is listed by `old -> new` name with counts. After a size
  change only per-name count deltas are shown.
- `GEOMETRY`: size, entrance, ground offset, entrance kind or rotation moved
  (old -> new shown). Test pins and hand-maintained catalogs need attention.
- `FAILS`: the exporter rejected the building (for example a structure reaching
  its survey edge or "extends beyond fixed capture"); the reason is shown.
- "Possible clipped architecture": non-natural nodes above ground level that
  touch a fixed capture box from outside, i.e. something may have grown past the
  box (change `capture_min/max` or `FIXED_BOXES`). Everything at or below ground
  level (platform gravel, paving, terrain), natural terrain and plants, other
  registered buildings' boxes and structures separated by a gap are filtered
  out. The wall tower/gatehouse/postern assets (`clip_to_capture`) always show
  their wall arms leaving the box; they are listed separately as expected.
  Auto-captured template buildings (no fixed box) are not scanned: the exporter
  itself fails if they reach the survey edge.

`apply` re-exports exactly the ids you name (or all changed ones) with the
exporters' own `--only` paths against the real workshop, then fails unless only
those ids' `.mts`/`.lua` files and manifest records changed (plus the generated
template `catalog.lua`), the manifest provenance still names the real workshop,
and nothing outside `schematics/` changed. Template ids are re-validated at all
rotations (`--no-validate` skips it); Roman changes run `tools/roman_check/run.py`.
It prints the tests and catalogs that likely pin a size/entrance that moved but
never edits them. If the gate fails, discard the partial result by checking out
`schematics/` again.

Not exported, by an explicit table in the script: `farm` (authored in code, #282)
and the stock-village ids `tavern`, `well`, `library`, `blacksmith`. `--world`
points at another world, for example a scratch copy when testing the tool.
`compare --allow-open-world` reads the last saved state of an open world.
`tests/run.lua` keeps going after a group that errors and lists the failed
groups at the end, so unrelated failures do not hide the rest.

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

## Reimports from issue #374

Six catalog buildings had changed in TownsWorkshop since their last export.
They were re-exported with `--only ... --validate`. Sizes, entrances and source
boxes are unchanged. The counts below are node-name differences from the
previously committed `.mts` files.

- `wall_tower` (30 nodes): two bed pairs, two chests, a crafting table and three
  wall torches are added, and stonebrick is removed in 12 places and replaced by
  stairs in 8. The beds are valid resident beds when the schematic is placed on
  its own (`tests/residents_tests.lua`), so they house residents and no
  `excluded_resident_beds` entry is set. `required_nodes` grows from 10 to 15.
  The corner tower's entrance and wall stubs are unchanged.
- `wall_tower_inline` (12 nodes): four hay bales, three wall torches, a spruce
  chair, a spruce table and a crafting table are added, and two
  grass-topped dirt nodes become dirt. It has no beds.
- `castle` (24 nodes): a spruce door pair at file (35,7..8,45) is an interior
  door with no special handling. Four barrels and a smoker become spruce tables.
  Battlement stonebrick and stairs are added, and three deepslate bricks become
  wooden stairs. The metadata gains six door records: two for the new pair and
  four for existing doors at x=10.
- `cathedral` (54 nodes): the birch sapling at (18,5,54) has grown into a tree
  (50 leaves and four trunk nodes). This is intentional garden texture and is
  kept. `required_nodes` now lists the leaves and trunk instead of the sapling.
- `gaboo_house` (11 nodes): nine stonebrick become cobble, and one air and one
  wood node become slabs.
- `soup_shop` (1 node): one barrel becomes spruce wood (see its section below).

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

## soup_shop (TownsWorkshop, #110)

`soup_shop` (role `shop`) is a build in **TownsWorkshop**, like the other
shops. It is exported with the usual selective command:

```sh
python3 tools/workshop_export/export.py \
  --world "$HOME/Library/Application Support/minetest/worlds/TownsWorkshop" \
  --only soup_shop --validate
```

The coordinates below are TownsWorkshop positions. The first survey recorded
the same build in an older Home world at x 240..246, y 7..16, z 233..241; those
positions are shifted by (-35, +1, +237) to reach the current workshop box.

Source box x 205..211, y 8..17, z 470..478 (`capture_min`/`capture_max` in
`buildings.json`; the survey box is x 201..215, y 6..20, z 466..482). Y 7 is
natural stone below the cellar and y 18 is air. The
build has no door node anywhere: it is a serving-counter shop with open
storefronts. The chosen entrance is the walk-in gap in the south wall at
(209,13,471) (`entrance_kind = "opening"`, front -Z, `rotation` 0), reached by
four cobble steps at z 470. The same stairs wrap round the +X side, where a
second gap at (211,13,472) is a counter window with its own stair run.

Floor and ground: the floor row (cobble/granite, y 12) stands one block above
the street (path/grass at y 11), exactly like the #87 buildings, so the ground
row y 11 is kept (`ground_y` 11) together with the cellar below it:
`capture_min.y` 8, `ground_offset` 3, entrance (4, 5, 1), 7 x 10 x 9.

Cellar (3 x 3 interior at x 207..209, z 474..476, y 9..11): mycelium at y 8
with brown/red mushrooms at y 9, a ladder up to a spruce trapdoor in the floor
at (207,12,476), one wall torch. It is enclosed on every side by the
template's own dirt walls, the mycelium floor and the floor row, so nothing
opens to the terrain below. Row y 8 outside the cellar is natural stone,
granite and some dirt that the fixed box captured; row y 7 (natural stone) is
omitted. No bedrock or void is involved at this depth.

`clip_to_capture` (new optional entry field): the building to the north has
eave slabs at z 479 (y 17) that fall inside the survey margin the exporter
requires around the structure, so the whole-survey bounds check would either
fail or capture them. With `clip_to_capture: true` and a fixed capture box,
only the box is surveyed and anything outside it is ignored (the check that a
build does not escape its box is skipped for such entries).

Contents: one bed, one barrel (the second barrel became spruce wood in #374), a
crafting table, six item frames, three wall torches, a ladder, a trapdoor, two
bark-slab roof corners. The back strip at
floor height (grass and path at z 478 and along x 211) is terrain that sits
inside the box and is captured with it. The planner has no corner-lot concept: the soup shop is
placed like any other shop and has no preferred position.

## Town hall (`tower`, #126)

The `tower` entry (role `city_hall`, label "Town hall") is the TownsWorkshop
town hall: the former 8 x 50 x 8 cobble tower with a diorite hall built round
its foot. The catalog id stays `tower` so it remains the only `city_hall` entry
(the planner takes the first sorted id of the role). Source box x 92..113,
y 8..57, z 200..218 (the upper tower reaches z 200, one node beyond the hall
body); front is +X (door at (105,10,209), `rotation` 90). The terrain row y 8
is kept (`floor_y` and `ground_y` 8, `ground_offset` 0), so the hall floor
(y 9) is one block above the street with real porch steps, as authored:
19 x 50 x 22 in the canonical file, entrance (9, 2, 8). The standing sign at
(104,9,197) is the workshop label and is excluded; a 5-wide diorite_smooth
paving strip (source x 109..113, y 8) in front of the porch is part of the
capture.

The reworked parapet (#345) is a diorite and stair cap at y 16..19 that
overhangs the hall by one node on its west side (x 92) and its south side
(z 218), so the fixed capture was widened by one node in each direction. In
canonical terms the back grows to 22 (+Z) and one side to 19 (+X). The door
stays at canonical (9, 2, 8) because it is measured from the unchanged front
and the unchanged z 200 edge. Apart from terrain, the only non-air nodes in a
51 x 61 node survey around the hall that lie outside the box are the cap
overhang and a floor-level diorite_smooth row at x 114 (y 8), which is
outside the footprint and is not captured.

## Medieval wall tower (#276)

`wall_tower` is the corner tower sample in TownsWorkshop, not a general-purpose
straight-wall tower. The source crop is x 288..295, y 8..24, z 187..194
(8 x 17 x 8), with the ground/floor datum at y 8. The export rotates the
source 180 degrees; its canonical entrance is (4,1,1), facing -Z. The sample
has a spruce door at source (291,9,193), mapped to that entrance. Its two
one-node wall tie-in stubs are retained at canonical (3,1..4,0) and
(7,1..4,4). The associated wall centerlines project to x=3 and z=4; their
intersection is (3,4), four nodes inward from the -Z entry edge and four nodes
inward from the +X edge. Thus the projected wall runs meet at a right angle
within the tower footprint, with the stubs marking where each run reaches the
perimeter. Longer wall arms outside the crop are omitted. This is a
corner-only contract; do not use the sample for straight runs without
preparing a separate variant or trimming one of the stubs.

The entrance door at (4,1,1) is immediately beside the (3,1..4,0) stub at its
front-left corner (diagonal at floor level); the stub does not occupy the door
cell. The full captured ground layer, local y=0 across the 8 x 8 footprint,
contains dirt, grass and cobble. Placement therefore owns/replaces that whole
ground footprint, not just the tower's masonry.

The source coordinates are the #276 TownsWorkshop tower location. The survey
margin includes neighboring wall/sample blocks, so the entry uses a fixed
capture box and `clip_to_capture`; the export does not modify the source world.
The isolated export was validated against a disposable world: 1,088 nodes in
the tower template and all catalog rotations/placements passed runtime
validation. This is not an in-game visual preview or a claim that #276 is
complete. No separate standalone wall asset was exported as part of this
ticket.

## Primary-road gatehouse (#278)

`wall_gatehouse` is the primary-road gatehouse sample in TownsWorkshop. The
source capture is x 289..297, y 8..22, z 207..222 (9 x 15 x 16); its ground
datum and full captured ground/foundation row are y 8. Source `-X` is
normalized to canonical `-Z` with a 270-degree export rotation. This is the
inward face: the gatehouse extends three nodes inward from the wall plane at
source x 292, and five nodes outward to source x 297. The canonical footprint
is 16 x 15 x 9, with the wall plane at local z=3 and the outward face at z=8.
The inward face is canonical z=0. That orientation puts the shorter projection
inside town and leaves the longer approach outside.

The road axis is canonical Z. The four-node passage crosses the wall at
canonical x=6..9 (source z=213..216) and runs from canonical z=0..8 (source
x=289..297). Above the floor, canonical y=1..3 stays clear across the full
passage. Iron-bar grilles cross the passage at y=4 in two rows, and upper-half
slabs form the roof at y=5, leaving four nodes of practical standing
clearance. The attached wall centerline is canonical z=3;
its core reaches four nodes above ground (local y=1..4). The short wall tie-in
stubs at both ends of that line remain inside the capture box. The capture
also retains the sample's full ground/foundation footprint, including its
cobble approach and dirt/grass border.

The passage is four nodes wide through the gatehouse. Generation must taper a
primary road from six nodes inside town to four nodes at the gate and outside;
that approach grading is separate from this imported asset. The sample has
side-room doors, two empty chests, beds, barred openings, and no gate mechanism
or guard system. Export provenance is recorded per building in
`schematics/templates/manifest.json`; the asset was captured from the
read-only TownsWorkshop snapshot with `--only wall_gatehouse --validate`.

## Medieval inline wall tower (#276)

`wall_tower_inline` is the straight-run sample from the same issue. Its fixed
source crop is x=289..295, y=7..23, z=230..236 (7 x 17 x 7). The full
foundation layer at y=7 is retained, with finished ground at y=8
(`ground_offset` 1). The exporter rotates the sample 180 degrees; the lower
entrance is canonical file offset (4,2,1), which is one node above finished
ground, facing -Z. In canonical orientation, the wall centerline runs along Z
at x=3. Its one-node tie-in stubs occupy file offsets (3,2..5,0) and
(3,2..5,6), or y=1..4 relative to finished ground; parapet details remain
part of the captured tower. This is a straight-run asset, distinct from the
corner-only `wall_tower`. Its full ground footprint is replaced when placed.
The source region is clipped to the fixed capture box because the survey
margin includes nearby samples; the Workshop is read only. The exporter
verified all 833 captured nodes and all four runtime placements in a
disposable world. As with the corner sample, this does not establish in-game
fit with generated walls.

## Medieval secondary-road postern (#280)

`wall_postern` uses the small TownsWorkshop postern at source x=291..293,
y=7..14, z=195..204. Its canonical capture is 3 x 8 x 10 and keeps one
foundation layer below finished ground (`ground_offset` 1). The double-door
passage is on local x=1 and spans local z=6..7; the catalog entrance selects
the first lower door at (1,2,6). Both approaches have two clear nodes of
headroom. The exporter checked all four schematic rotations and every catalog
placement in a disposable world. Generation should align the door pair with
the central two columns of a four-wide secondary road, tapering from four
nodes inside to two through the postern and outside. Placement maps local +X
outward, so the authored door facing (local -X) faces back toward town. The
passage is otherwise symmetric across the wall plane. In-game fit remains to
be confirmed.

## Alternate inline wall tower (#343)

`wall_tower_inline_alt` is the same straight-run tower with different
furnishings (mcl_decor chair, fletching table, spruce bark). It is captured
from TownsWorkshop at x=289..295, y=7..23, z=242..248: the same 7 x 17 x 7
box and offsets as `wall_tower_inline` (ground_y 8, rotation 180, entrance
(4,2,1) in file offsets). The ticket's y=7..22 box produced 16 layers because
the primary capture's top layer is empty, so the box was widened to y=23 to
keep the catalog size identical. The exporter verified 833 nodes, the same
count as the primary.

The planner picks the variant for each straight-run tower with a coin flip
that depends only on the plan seed and the tower's order along the wall. It
does not use the planner RNG, so translated plans keep the same variants.
Corner towers always use `wall_tower`. If the alternate asset is not valid,
every inline tower uses `wall_tower_inline`.

## Medieval town square fountain (#344)

`town_square_fountain` is the fixed capture x=248..252, y=7..11, z=303..307
(5 x 5 x 5). Y=7 is the buried dirt/foundation row; finished ground is y=8
(`ground_offset` 1), where a diorite floor carries a slab-rimmed basin with a
central water spout. It has no role, so no random building pool uses it, and
is not a building: the medieval planner adds it to `plan.objects` at the centre
of the market square (`src/medieval_planner.lua`) and `src/preflight.lua`
resolves it as an outdoor object, so it is built with the town, left unpaved
and has no door check. The catalog still requires an entrance, so the
`opening` entrance is the rim node (2,3,0) on the -Z edge; it is unused.
