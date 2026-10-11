# Towns engineering design

Status: working plan for implementation epics. Based on the [design brief](design_brief.md)
and the locally installed VoxeLibre 0.92.3 and Living Villages code as of October 2026.

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

The building catalog should initially contain a stable ID, `.mts` path,
dimensions, entrance side, and a short role such as `landmark`, `house`, or
`tavern`. Add rules such as corner-only or abutting only after real buildings
need them. Capture all buildings in one documented orientation; rotate at
placement time. Schematics should carry normal VoxeLibre nodes, beds, and
workstations rather than special Towns nodes where possible.

Add `mod.conf` dependencies only as they become real: `mcl_structures` for
its placement helper, `mcl_mapgen_core` for natural generation, and the
VoxeLibre mob/bed mods when Towns spawns residents. Living Villages should be
an optional companion; Towns' generated buildings should still work as
VoxeLibre buildings without it. Keep any bed-claim setup in one adapter: the
current village spawner sets a villager's `_bed` and the bed metadata's
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
  the chosen seed and bounds. Only build in a fresh test area; do not make
  repeat commands silently overwrite player work.
- Prove rotated footprints, entrance location, schematic placement, and
  basic terrain clearing on flat ground.

**Exit check:** capture a new structure in Creative, register it with little
metadata, and see it placed correctly in game. This is the content pipeline
for every later phase.

### 2. First walkable town plan

**Result:** from above, a hand-triggered town reads as a planned settlement;
on foot, its main destinations connect naturally.

- Choose a modest, mostly rectangular footprint and a single ground level on
  suitable terrain. Reserve two large landmark sites, a parvis, and a market
  square. The first landmarks may be blockouts while the handmade structures
  are being built.
- Make a few orthogonal principal and secondary streets that connect those
  spaces, then derive buildable frontage from the leftover blocks. Use one or
  two coherent paving materials, not per-node noise.
- Keep the plan serializable or printable for debugging. Provide a dry-run
  summary or simple top-down plan view before building.

**Exit check:** a player can walk from the edge through the market to the
landmark sites without dead ends or accidental walls. A screenshot from above
shows a distinct center, streets, and blocks. A failed site explains why.

### 3. Dense, usable town core

**Result:** the empty blocks become convincing streets and the town begins
to feel lived in.

- Populate street frontage with a small varied set of handmade houses, shops,
  workshops, and taverns. Pack by actual width and depth, reserve door access,
  and allow some buildings to touch. Leave manageable interiors; decorate a
  few simply rather than modeling every lot.
- Add wells and multiple taverns near residential groups. Keep entrances,
  beds, workstations, jukeboxes, and well access usable by villagers. Start
  with a modest resident count and raise it only after watching travel and
  server performance.
- Place the first real landmark schematics when ready. A cathedral and castle
  are visual goals, but the planner should tolerate temporary blockouts so
  layout work does not wait on those large builds.
- Give the builder a narrow post-placement pass for node initialization and
  spawn residents at valid beds, with no duplicate spawning when areas reload.

**Exit check:** the core has mostly continuous street fronts; several
residents can sleep, work, and reach a nearby tavern or well. Play-test one
day/night cycle and fix the biggest visual and navigation failures.

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
