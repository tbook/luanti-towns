# Home captures in TownsWorkshop

Placed 2026-10-13, in original orientations. Teleport to **(100, 10, 195)**
to reach the first row, south of the cathedral and castle.
Three rows with 35-node spacing across X and 50-node spacing across Z.
Each building has a name sign three nodes north of its origin.

| Building | Minimum corner | Maximum corner |
| --- | --- | --- |
| Tower | (100, 7, 200) | (107, 57, 207) |
| Leather worker | (135, 8, 200) | (143, 17, 210) |
| Corner house | (170, 8, 200) | (178, 17, 207) |
| Jail | (205, 7, 200) | (215, 13, 206) |
| Townhouses | (240, 8, 200) | (254, 19, 210) |
| Weaver | (100, 7, 250) | (108, 15, 256) |
| Scribe | (135, 7, 250) | (147, 19, 260) |
| Gaboo house | (170, 7, 250) | (180, 18, 262) |
| Office building | (205, 7, 250) | (216, 25, 261) |
| Banker house | (240, 7, 250) | (251, 18, 260) |
| Butcher shop | (100, 7, 300) | (108, 14, 308) |
| Mason's yard | (135, 8, 300) | (141, 13, 308) |
| Chapel | (170, 8, 300) | (179, 21, 318) |

Initial placement used the workshop surface at Y=8 as the floor reference.
The corner house, townhouses, and weaver were subsequently raised one node
at the user’s request; current bounds are listed above. Lower captured
ground layers extend into the workshop ground. Buildings retain original
orientation, terrain fragments, furnishings, and paired doors.

Restored inventories and node data, including chest contents, armor displays,
item frames, and door states. Removed stale villager/bed ownership and Seasons
bookkeeping from workshop metadata. Seven seasonal leaf nodes in Gaboo’s
capture use ordinary oak leaves because Seasons is not enabled here. Original
raw files and sidecars are unchanged.

Verified **15,955 schematic nodes** (names and param2, allowing the seven
leaf substitutions), plus restored inventory stacks and item metadata.
All ten signs were initialized successfully. This was programmatic verification.

A full pre-import backup is stored at `/tmp/towns-workshop-before-home-import`.
The helper was used only in staging, so reopening the workshop will not
place or overwrite these buildings again. Captures and sidecars are also
copied to the workshop’s `schems/` directory for convenient WorldEdit use.

Height correction: moved the current workshop nodes, inventories, metadata,
and timers up one node for those three buildings. Verified all 3,267 moved
nodes and their metadata with zero mismatches; refilled vacated ground layers.
Pre-correction backup: `/tmp/towns-workshop-before-height-adjustment`.

Additional third row imported 2026-10-13: butcher shop, mason's yard and
chapel at Z=300. These copies were subsequently edited and exported as `butcher_shop`,
`mason_yard`, and `chapel` in the game catalog. Source bounds and metadata are saved in
`*_home_raw.json`; workshop regions are recorded in the companion placement
JSON for future export. Existing user edits in the first two rows are retained.
All 3,686 new nodes matched the source capture (apart from three seasonal
grass substitutions), with inventories restored and verified. The chapel
retains its mcl_decor chairs and Living Villages pulpit.
Pre-import backup: `/tmp/towns-workshop-before-third-row`.

Chapel raised one node at the user’s request on 2026-10-13. All 2,660
current nodes and their metadata matched after the move; timers and contents
were preserved. Backup: `/tmp/towns-workshop-before-chapel-raise`.

Edited-template export: butcher shop 9 × 7 × 9, mason’s yard 7 × 6 × 9,
chapel 9 × 13 × 17. Exact trimmed source bounds and entrance choices are
recorded in `schematics/templates/manifest.json` and
`tools/workshop_export/buildings.json`. The original placement boxes above
remain the editing regions; the game templates use trimmed bounds.
