# Towns engineering design

Status: working plan for implementation epics. Based on the [design brief](design_brief.md)
and the locally installed VoxeLibre 0.92.3 and Living Villages code as of October 2026.
Phase 3 and later describe agreed implementation targets, not completed features.

## Goal and approach

Build one medieval town that is enjoyable to discover, recognize from a distance,
and explore on foot. Its cathedral or other large landmark, market square, streets,
and tight building frontage matter more than a historically exact layout or a fixed
population count. Later town styles are possible, but this plan does not build a
general town-style framework up front.

The first useful result is a town generated on demand in a test world. Natural
generation follows after the layout and construction are reliable. Each phase
below should end with something that can be judged in game, not just a set of
internal APIs.

## What the current code tells us

| Existing code | Consequence for Towns |
| --- | --- |
| `mcl_villages/init.lua` chooses candidate mapchunks with `blockseed % 77 == 17`, then calls `settlements.create_site_plan`, `terraform`, `paths`, and `place_schematics`. `build_a_settlement` is local to that file. | Towns should have its own planner and builder. Replacing the village planner would entangle two very different layouts; the existing call chain is not a public entry point for a second settlement type. |
| `mcl_villages/buildings.lua` places 10–25 buildings in widening rings. Its schematic list and terrain functions are global `settlements` state. | We can learn from its node handling, but dense blocks, streets, and landmarks need a different plan. Avoid adding Towns buildings to `settlements.schematic_table`. |
| `mcl_mapgen_core/api.lua` provides `register_generator(id, voxel_fn, node_fn, priority)`. `mcl_villages` uses a node generator and later `emerge_area` through a marker/LBM flow. | Use a separate generator for natural Towns. Large builds extend beyond one mapchunk, so the phase must explicitly load the full build area and prevent duplicate attempts. |
| `mcl_structures/api.lua` offers `place_schematic`, which calls `emerge_area` and then places one schematic asynchronously. The engine also provides `minetest.place_schematic`. | Use the helper where convenient for early prototypes. For a full town, emerge the whole area once and place components in a controlled sequence; measure before optimizing further. |
| `mcl_villages/buildings.lua` privately initializes certain placed nodes and spawns villagers at red beds after schematic placement. | Towns needs a small, explicit post-placement pass for the nodes it actually uses and for resident spawning. Copying that entire function would couple Towns to village internals. |
| Living Villages looks for a tavern jukebox within 48 nodes of a villager's bed (`tavern.lua`), and a recognizable well within 42 (`well.lua`). VoxeLibre sends villagers back if they wander over 50 nodes from their bed (`mobs_mc/villager.lua`). | Put services within neighborhood walking distance; do not expect every resident to cross the entire town for dinner or water. Test actual walking routes, doors, and crowding. |
| Living Villages' `site_planner.lua`, `village_terrain.lua`, and `village_smoothing.lua` handle difficult village terrain and cross-chunk loading. | Reuse lessons and small helpers where licensing and interfaces permit, but start Towns on flatter ground and reject troublesome sites. A giant terrain system is not an early requirement. |
| The installed WorldEdit has `//mtschemcreate`, which writes `.mts` files to a world's `schems` directory. | Begin handmade building capture with WorldEdit and a documented copy/register workflow. Add an in-game capture command only if repeated authoring makes it worthwhile. |

These are observations about the installed versions, not promises about future
VoxeLibre APIs. Keep engine-facing calls together so an upstream change is easy
to isolate.

## Thin technical shape

This is the target architecture. The current `/towns_generate` builds the
Phase 2 layout with empty blocks and landmark blockouts. Authored catalog
assets can be placed with `/towns_test`; populated-town planning, functional
node initialization for whole towns, and residents remain Phase 3 work.

The planner takes a site description, a deterministic seed, and a catalog of
available buildings. It returns a plain Lua town plan without changing the
world. A plan needs only the data used by the current builder: center, build
bounds and ground level, reserved spaces, street segments, building placements
with rotation, and later walls/gates and fringe sites. Start with rectangles
and an occupancy map at node or small grid-cell resolution; use a street graph
only if real routing problems call for one.

The builder validates that the plan fits, prepares the ground, lays streets
and squares, places schematics, performs node setup, then adds residents. It
must know exactly which area to emerge before writing, and report failures
without claiming an incomplete town is finished. Its ordering should be
simple and visible in logs. Building placement must use actual rotated
footprints and clearance around doors, not the `hsize` radius used by
VoxeLibre villages.

The current building catalog records stable IDs, `.mts` paths, full dimensions
and entrance XYZ offsets. Phase 3 will add the role classifications, role
filtering and planner snapshots specified in [#28](https://github.com/tbook/luanti-towns/issues/28).
The canonical front is the -Z axis; rotate
at placement time. Each schematic box fully contains the building, including
eaves and any deliberately captured side clearance. Boxes may touch with zero
nodes between them but must never overlap, including their air. There is no
separate plot model in Phase 3. Schematics should carry normal VoxeLibre nodes,
beds, and workstations rather than special Towns nodes where possible.

Add `mod.conf` dependencies only as they become real: `mcl_structures` for
its placement helper, `mcl_mapgen_core` for natural generation, and the
VoxeLibre mob/bed mods when Towns spawns residents. By product decision,
Living Villages is a required dependency for populated Phase 3 towns
([#46](https://github.com/tbook/luanti-towns/issues/46)); `mod.conf` lists
`living_villages`, `mcl_core`, `mcl_chests` and `mcl_itemframes`. Keep bed-claim setup in one adapter:
the current village spawner sets a villager's `_bed` and the bed metadata's
`villager` ID, but that is implementation detail we must check in game.

Use a local seeded random generator and stable iteration order for planning.
The same site and seed should give the same plan. Record the seed and bounds
with a generated town so a bad layout can be reproduced. Do not promise that
a town already built in a saved world will be regenerated identically after
the catalog changes.

## Proposed phases

### 1. Building workshop and visible test site

**Result:** a developer can place one handmade building and a small paved
square at a chosen location, then inspect its orientation and ground contact.

- Document WorldEdit capture, naming, orientation, origin, and where `.mts`
  files go in this repo. Add a few tiny reference schematics or an intentionally
  simple test structure.
- Add a minimal catalog and a privileged, hand-triggered test command. Report
  the building ID, rotation, and exact bounds (no seed until the Phase 2
  planner exists). The command may overwrite its chosen site immediately: it
  is for the disposable Testlandia Creative world, requires the `server`
  privilege, and says so in its help text. There is no preview or
  confirmation flow.
- Prove rotated footprints, entrance location, schematic placement, and
  basic terrain clearing on flat ground.

**Exit check:** capture a new structure in Creative, register it with little
metadata, and see it placed correctly in game. This is the content pipeline
for every later phase.

### 2. First walkable town plan

**Result:** a privileged `/towns_generate [seed]` builds, in a disposable
Creative world, a first fully procedural, walkable medieval town near the
player. From above it reads as a planned settlement; on foot, its main
destinations connect naturally.

Agreed behavior (replaces the earlier "modest rectangle, dry-run preview"
sketch):

- **Boundary.** A broad, stepped orthogonal outline about 96 nodes across,
  not a square, generated from the seed. There is no fixed template: the
  boundary, the two landmark sites, the parvis, the market square, the
  principal and secondary streets and the blocks all come from rules and the
  seed.
- **Parvis (profile plans, #105).** A 12-wide (`PARVIS_WIDTH`) by 8-deep
  (`PARVIS_FRONT_DEPTH`) rect on the entrance side, touching the compound box
  edge and centred on the catalog door's lateral coordinate (not the compound
  midpoint). For an even width the extra node falls on the lower-coordinate
  (-x / -z) side in world space for every rotation. It does not span the
  compound front; legacy (no profile) plans keep the old margin rule.
- **Sites.** Reserve a cathedral (with its parvis) and a castle as landmark
  sites and a separate market square. The first landmarks are temporary
  physical blockouts (recognizable silhouettes, real doors and gates) while
  the handmade structures are being built.
- **Streets and blocks.** Orthogonal principal and secondary streets connect
  the boundary approaches, market, parvis and castle gate; leftover blocks
  are left empty with recorded buildable frontage. One or two coherent
  paving materials.
- **Site search.** Search outward from the command player for a site whose
  middle 95% of surface heights span at most 16 nodes, with no water and
  fully loaded terrain. Exclude up to 2.5% of columns from each height tail,
  rounded down; every column must be within 24 nodes of the median. Search
  within 320 nodes and inspect heights within 48 nodes above and below the
  player’s ground level. Actual surface extremes determine the build bounds.
  The search is read-only and asynchronous (it emerges what it inspects).
  Water (ticket #104): only liquid or ice at the top of a column counts as
  surface water; buried pockets and caves are ignored by the search and are
  made safe by the builder (below). The site SEARCH of `/towns_generate` keeps
  the strict rule (any surface water or ice rejects, wet mode off). The
  builder changes below are shared: `/towns_generate` output also differs
  whenever liquid is buried in the cut or beside the town above ground
  level (previously `inspection_failed` or ignored). Flow is treated as
  4-neighbour horizontal; paved and approach columns keep headroom unsealed. `/towns_place_town` opts into
  `WET_DEFAULTS`: a column covered by at most `MAX_WATER_DEPTH` = 6 nodes of
  water or ice (bed found within that depth) is "wet" and is landfilled; wet
  columns may be at most `MAX_WET_FRACTION` = 25% of the footprint, deeper
  water rejects as `too_deep_water`, more wet columns as `too_wet`, lava as
  `lava`. For range and median a wet column counts at its water surface; the
  finished ground is the median raised to the highest water surface in the
  footprint or in the one-node ring around it, so no water ends up above the
  ground. Fill is measured from the bed and still limited by the 24 node
  cut/fill cap. The failure message and the success report list rejection
  counts per reason.
- **Liquids in the build volume.** The builder replaces every liquid or ice
  node that lies at or below a column's surface inside the owned rows (cut
  volume, support rows, landfilled wet columns); liquid above a dry column's
  surface is a stale inspection and fails the build with nothing written. A
  liquid outside the town beside an open cell above ground level is sealed:
  the natural solid terrain cell is kept, otherwise stone is written (inside
  the town columns only). Deep pockets below the support rows are left alone.
- **Flattening.** The accepted town interior is cut and filled to the median
  surface height of its columns, with the natural surface node kept at the
  new ground level. Smoothing the terrain at and beyond the town edge is
  deferred: a visible step at the boundary is expected.
- **Direct build.** The command builds immediately on an accepted site. There
  is no preview, dry run or confirmation (the same posture as `/towns_test`,
  and likewise for disposable Creative worlds only). It reports and logs the
  seed, chosen centre, ground level, exact bounds, landmark and square
  coordinates and street, block and frontage counts. A rejected site or
  failed search changes nothing and says why; only a failed engine write can
  leave a partial site, and is reported as such with its bounds.
- **Reproducibility.** The pure plan depends on the seed alone (the centre
  only translates it), so the same seed at the same centre reproduces the
  plan. Seeds are integers in +/-(2^30 - 1); larger values are rejected, not
  folded. A missing seed is generated and printed.
- **Not in this phase.** Natural generation, ordinary buildings, residents,
  walls, edge smoothing and real landmark schematics.

Implementation: `src/planner.lua` and `src/streets.lua` (pure plan),
`src/site_search.lua` (read-only candidate search), `src/builder.lua` with
`src/town_layout.lua` and `src/blockouts.lua` (construction), and
`src/generate.lua` plus `src/generate_command.lua` (the command; pure
argument, seed and report logic with an injected `core` layer).

**Exit check:** a player can walk from the edge through the market to the
landmark sites without dead ends or accidental walls. A view from above shows
a distinct center, streets, and blocks. A failed site explains why and
changes nothing. At least two seeds were checked in a disposable world.

### 3. First populated town

**Result:** the empty blocks become dense handmade street fronts, the existing
cathedral and castle replace their blockouts, a city hall stands beside the
market square, and residents begin using the town with Living Villages enabled.

Agreed scope:

- **User-authored library.** The user builds the initial houses, shop-houses,
  workshops, taverns, wells and city hall in Creative. An agent captures and
  registers each supplied structure, checking its full bounds, foundation,
  entrance and rotations. Additional variants are separate content tasks;
  code work can proceed with synthetic fixtures while buildings are authored.
- **Existing landmarks and town scale.** Import the intended complete castle
  and current cathedral from TownsWorkshop. Their footprints are much larger
  than the Phase 2 reservations. Derive reservations and approaches from the
  current schematics, preserving the stepped boundary, parvis and connected
  streets. Enlargement of the town is authorized. Engineering trials began at
  a 192-node envelope; the profile envelope is
  now 208 (#89) with principal streets 5 wide (#88), wider-spaced secondary
  streets (#86); the street spacing and minimum block side are derived
  from the catalog's ordinary building depth (#86, `docs/layout_comparison.md`). Tune the size for usable
  residential frontage and acceptable planning cost; this is not a fixed
  product size. Keep the current terrain acceptance limits.
- **Placement unit.** Pack the full schematic boxes, not separate lots. Their
  fronts must face the street or square, with entrances accessible from the
  pavement. Boxes can be immediately adjacent. Side windows, eaves and
  setbacks are authored inside each box, not added by the planner. Never
  stretch, crop, mirror or overlap a building to fill a run.
- **Frontage and corners.** Use seeded, stable packing with shared occupancy
  across all faces of a block. Leave space that no supplied building fits.
  Corners may eventually use authored corner buildings; the initial fallback
  leaves an open corner rather than intersecting buildings. Keep that space
  as ordinary ground initially. Dedicated corner rules wait for real content.
- **Alleys and access.** Redistribute spare frontage into one or two small
  alleys reaching leftover block interior, preferring two-node width where
  space allows. Reserve or repack whole ordinary buildings, never carve
  schematics. Known passages through buildings may supplement access, but
  guaranteed access initially uses free cells outside their boxes. Check
  connected leftover interior areas, including touching block rectangles.
  Leave interiors undecorated until Phase 3b.
- **Simple services first.** Reserve taverns and wells before ordinary
  buildings. Begin with tunable targets of three of each, selecting subsequent
  fitting placements far from earlier services of the same type. Report
  shortages rather than forcing overlaps. Wells include a usable apron and
  must match Living Villages' recognition rules; taverns contain accessible
  jukeboxes. No hard per-bed service coverage guarantee or optimizer yet.
- **City hall.** Add one user-authored tower, including a larger base if
  supplied, beside the market square (#106): the complete rotated box lies
  outside the open market rectangle, touching one market edge, its facade
  within that edge and its real (possibly off-centre or recessed) door facing
  across it, so the door approach is a market pavement node. The market is
  sized independently of the hall (it must only be as long as the facade, so
  no ring of pavement is reserved round the hall) and stays one contiguous
  open square. The hall keeps a street width from the cathedral, parvis and
  castle, is an obstacle for streets, blocks and routes, and ordinary
  buildings, services and roads respect its footprint; the other three
  market sides stay open to streets and building frontage. Candidates run
  along the four market edges, centred first then flush to an end; the seeded
  rng picks among the first tier that fits inside the boundary.
- **Residents.** Require Living Villages. Spawn one resident per valid,
  complete, accessible bed inside placed buildings, including tavern and
  landmark beds. Support the game's bed colors, count each pair once, and
  claim beds through a narrow VoxeLibre adapter. No population cap, assigned
  profession, workplace quota, bed/workplace balancing or automatic replacement
  of dead residents in this phase.
  Caveats: initialization records are keyed by bed position and never
  validated against the world, so re-placing or clearing a town on identical
  coordinates reports "already initialized" until the records are cleared
  (server stopped; `sqlite3 <world>/mod_storage.sqlite "delete from entries
  where modname='towns' and key like 'resident:%'"`; also remove existing
  villagers and bed claims, which are respected). Mod storage is flushed
  periodically, so a hard crash can lose a pending or done record: a lost
  pending is the safe case (the bed meta is the second guard), a lost done
  with unsaved bed meta can allow a duplicate. Living Villages' own births
  can fill skipped beds with children; that is not a Towns cap or
  replenishment.
- **Construction.** Preflight selected assets, node names, placement geometry
  and complete emerged bounds before terrain writes. Bounds include the true
  schematic heights. Prepare ground and pavement, place schematics, initialize
  only required functional nodes, then spawn/claim residents. Persistent
  initialization records and existing claims prevent duplicate spawning on
  repeat calls or reload. Log interrupted resident initialization for
  inspection rather than blindly retrying it. Any failure after writes is
  reported as partial construction, with bounds and the failing stage.
- **Command.** Retain the privileged direct-build `/towns_generate [seed]`
  flow for disposable Creative worlds, with no preview or confirmation.
  Report actual bounds, selected catalog IDs, building/service/alley counts,
  bed/resident counts and unmet targets. A fixed seed, center and catalog
  profile reproduces the plan; changing the library may change packing.

**Exit check:** inspect two fixed seeds with the actual initial library.
Street fronts are mostly continuous, doors and leftover interiors are
accessible, city hall stands beside an open, walkable market, and the real landmarks fit
without damaging routes. Observe one full day/night cycle: residents can
sleep and use nearby services when their behavior triggers. Verify no duplicate
initial residents after reload, and record construction cost and the largest
navigation defects. Fix essential access/use failures; optimized service
coverage, employment balance and decorated interiors are not exit requirements.

Implementation is tracked in [Phase 3 epic #27](https://github.com/tbook/luanti-towns/issues/27).
Its 24 child tickets specify dependencies, narrow changes and acceptance checks.
Content variants should each use a separate capture ticket/PR. The work is split
into catalog/capture conventions; individual building imports; landmark and
city hall reservations; single-frontage packing; services; shared occupancy;
interior-access validation; alleys; preflight/emergence; physical placement;
node setup; bed enumeration; resident spawning; command reporting; and in-game
validation. Pure geometry tickets can use synthetic fixtures while waiting
for user-authored buildings.

### 3b. Observe and tune the populated town

**Result:** improve the first populated town using evidence from the actual
buildings, leftover spaces and resident behavior. This is a bounded observation
and tuning pass, separate from Phase 4's natural generation and world safety.

- **Block interiors:** inspect their real shapes and access, then agree simple
  yards, gardens or other treatments with the user. The placeholder ticket is
  for design first, followed by small implementation tickets; do not build a
  general decoration or lot framework in advance.
- **Services:** assess tavern/well shortages, spacing, walking, visits and
  congestion. Tune the simple counts and placement rules. Discuss any new hard
  coverage guarantee or major service policy before implementation.
- **Beds and workplaces:** count available beds and usable workstations and
  observe employment/travel. Decide with the user whether to adjust authored
  content, building mix or placement. One workplace per bed is not an agreed
  requirement; one initial resident per valid bed remains the Phase 3 rule.
- Refine gaps, corners and building variety where the first streets reveal
  concrete problems. Additional content and any significant product changes
  get explicit, small follow-up tickets.

**Exit check:** record the observed issues and agreed changes, validate the
chosen improvements on the saved seeds, and resolve major access or resident-use
failures before natural generation. Perfect interiors, service optimization
and a fixed employment ratio are not prerequisites for Phase 4.

Deferred placeholders: [#51 — block interiors](https://github.com/tbook/luanti-towns/issues/51),
[#52 — service tuning](https://github.com/tbook/luanti-towns/issues/52), and
[#53 — bed/workplace assessment](https://github.com/tbook/luanti-towns/issues/53).
These call for observation and agreed design before follow-up implementation,
and are explicitly excluded from Phase 3 completion.

### 4. Natural generation and world safety

**Result:** new worlds occasionally generate towns without a command, in
places where they look intentional and do not damage nearby structures.

- Add a separate `mcl_mapgen_core` generator for Towns with a low candidate
  frequency distinct from VoxeLibre's village trigger. Check nearby village
  attempts and structures rather than assuming a different modulus alone
  prevents overlap.
- Sample the whole proposed site for slope, water, unsuitable biomes or
  surfaces, and existing structures. Reject bad sites. Limit terraforming to
  the accepted bounds and smooth the edge enough to avoid a floating slab or
  severe cut wall. Start with one terrain profile; expand only after seeing
  real failures.
- Emerge the full town footprint before construction. Reserve and record
  accepted sites, make repeated callbacks harmless, and log a town
  ID/seed/center/bounds. Record pending and completed states; after an
  interrupted build, log it for inspection instead of blindly building a
  second town over the partial one. An automatic repair system can wait.
- Provide a way to find the nearest generated town during testing.

**Exit check:** on fresh worlds, several known seeds produce towns in
different suitable sites, with no duplicate builds, obvious overlaps, or
extreme terrain scars. Generation cost is acceptable on the test machine.

### 5. Defining silhouette and outskirts

**Result:** the town has a strong skyline and a believable transition to the
countryside.

- Replace remaining landmark blockouts and tune their setting: cathedral
  parvis, castle edge position, and views along important streets.
- Add a simple optional wall kit with straight sections, gatehouses where
  roads cross, and towers at selected corners or long runs. Skip a wall on a
  plan if the fit is poor; an unwalled town with good streets is preferable.
- Add a sparse fringe related to roads leaving the gates or town edge. Use a
  small set of rural structures and avoid spreading development everywhere.
- Tune building mix, a few alleyways and block interiors, lighting, pacing,
  and visual variety by play-testing rather than adding a broad decoration
  framework.

**Exit check:** from a hill or Creative flight, the town is clearly different
from a large village; on foot, the gates, squares, streets, and landmarks
create a memorable route. The outskirts thin out naturally.

## Validation during the phases

Use small pure-Lua tests for planner geometry, rotation, overlap, and stable
seeds. Use fresh disposable worlds for construction and mapgen checks: those
behaviors depend on loaded mapblocks, structure order, and actual VoxeLibre
nodes. Save a few world seeds and screenshots as visual regressions. Keep a
short list of observed defects and tune the layout against them. In-game
walking and distant views are the final test of quality.

The main risks to watch are cross-mapchunk writes, partial builds after a
server stop, schematic doors or beds that are unusable after rotation,
villager pathfinding across a large town, and generation time. Address each
when its phase reaches it. Avoid a general-purpose zoning engine, economy,
complex lot model, river crossing, or theme framework until the first town
is fun to explore.

### Planner town types

`planner.plan(center, seed, opts)` and `planner.validate(plan)` remain the
shared entry points. Generated plans carry `town_type = "medieval"`; omitting
the field when validating an older plan also selects the medieval validator.
An authored Roman plan sets `town_type = "roman"` and supplies an envelope,
boundary rectangles, named sites, streets, blocks, and frontage. Roman
validation checks those authored fields and public pavement access to each
landmark approach without requiring medieval civic sites. Authored frontage
runs use the shared run schema from `planner.lua` (the one-node block edge row,
facing the street or square it borders). The Roman planner derives its blocks
from explicit rectangles in `roman_civic_plan.lua`, one catalog row depth
deep, and its runs from the pavement along their edges. A square-ish ring of
four secondary bands (issue #164) surrounds the forum: it crosses the north and
east arms, its south and west bands end beside their arms, and the south-west
bath quadrant is left out. Blocks may stand flush against a ring band's inner or
outer side. Roman generation is
selected through `/towns_generate roman [seed]`, which passes `town_type =
"roman"` to the shared search and build (issue #151). Any other explicit type
is rejected with a reason.
