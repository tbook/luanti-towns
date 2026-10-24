# Outskirts v1: scattered countryside buildings

Status: contract for the Outskirts tickets (epic #225), written for #226 and
rewritten after the product owner changed the direction. This replaces the first
version of this document (exits, roads, paths, approaches, village groups, slots,
services, an own terrain writer); that design is in git history only. This file
adds no generation code. `tests/outskirts_contract_tests.lua` checks the
constants, the worked example, the asset facts and the Living Villages facts
stated here.

## 1. Direction

Scatter rural buildings around a generated town the way an ordinary village
scatters its houses:

- 18 farms and 6 shepherd's huts, plus (Roman towns only) 2 villas and
  (medieval towns only) 1 chapel. **Every number is a placeholder** and a single
  constant (section 2).
- Farms lie in a **near band** around the urban bounds; huts, villas and the
  chapel lie in a **far band**. Each building has a deterministic random
  rotation.
- No roads, paths, approaches, exits, groups, services or join to the urban
  edge. People walk over open ground (Living Villages wears real paths where
  villagers walk).
- Terrain is prepared by **Living Villages' terraform pipeline** (pads, slopes,
  plants, trees, holes). Towns writes no outskirts terrain of its own.
- The town is never damaged: Living Villages is given a **protected rectangle**
  and Towns keeps every plot clear of it.
- Urban `plan.bounds`, `plan.boundary`, the planner's random stream and the
  urban build are unchanged.

Out of scope: new villager behaviour, path generation, roads, walls, natural
generation, performance work (#186).

## 2. Constants

Frozen as names and meanings, **placeholders as values**. No runtime settings:
retune by editing the block, `tests/outskirts_fixture.lua` (`F.constants`) and
this text together (the test checks that they agree).

```lua
VERSION = 1,                  -- result.version
FARM_COUNT = 18,              -- farms wanted
HUT_COUNT = 6,                -- shepherd's huts wanted
VILLA_COUNT = 2,              -- Roman towns only
CHAPEL_COUNT = 1,             -- medieval towns only
FARM_BAND_NEAR = 36,          -- farms: gap to plan.bounds, nodes (inclusive)
FARM_BAND_FAR = 76,           -- ... (exclusive)
OUTER_BAND_NEAR = 76,         -- huts, villas, chapel: gap to plan.bounds (inclusive)
OUTER_BAND_FAR = 144,         -- ... (exclusive)
MIN_SPACING = 20,             -- minimum gap between two plot rects
PROTECT_MARGIN = 24,          -- protected rectangle = plan.bounds grown by this
TERRAFORM_REACH = 10,         -- Living Villages margin 2 + radius 8 (defaults), for derived checks
PLAYER_MARGIN = 16,           -- plots stay this far from the player
ATTEMPTS_PER_BUILDING = 6,    -- candidate sites tried per building
SAMPLE_LIMIT = 50,            -- random draws to find a rect inside the band, per attempt
MAX_SPREAD = 4,               -- largest height difference under a footprint (= site_planner max_spread)
SCAN_UP = 48,                 -- reader window above the urban ground (= site_search)
SCAN_DOWN = 48,               -- ... and below it
SALT = 226,                   -- private random stream
```

*Gap* means the Chebyshev distance between a plot rect and `plan.bounds`:
`max(b.x1 - r.x2, r.x1 - b.x2, b.z1 - r.z2, r.z1 - b.z2)`; a positive value is
outside. Derived checks (tested): the bands are ordered and farms are nearer;
`FARM_BAND_NEAR >= PROTECT_MARGIN + TERRAFORM_REACH` (the nearest pad's
terraform reach stays outside the protected rectangle); `MIN_SPACING >= 2 *
TERRAFORM_REACH` (neighbouring pads' reaches do not overlap);
`PLAYER_MARGIN >= TERRAFORM_REACH`; each band holds at least twice its
buildings at the packing `MIN_SPACING` implies, for the Roman and the medieval
bounds.

## 3. Conventions

X east, Z north, Y up (`src/geometry.lua`). Rects are inclusive
`{x1, z1, x2, z2}`, boxes `{min = {x, y, z}, max = {x, y, z}}`.

Three different Ys, each with one name:

| Name | Definition |
| --- | --- |
| *schematic origin Y* | `site_ground_y - ground_offset` (`preflight.compose`) |
| *site ground Y* (`ground_y`) | Y of the finished surface node row of the plot. Living Villages `pad.y` / plan `pos.y` is this value ("the schematic's bottom slice is the ground layer, so `pos.y` is the surface"), never the schematic origin |
| *entrance feet Y* | `origin Y + entrance.y`, a per-entry catalog value that cannot be derived from `ground_offset`. `builder.check_door` owns door height (starts at `(approach, ground + 1)` and climbs authored steps) |

The stock VoxeLibre schematics keep their dirt layer (file y 0) as the ground
row, so `ground_offset = 0` and the floor stands on file y 1, as for the tavern
and well templates.

## 4. Assets and jobs

| Class | Source | Measured (file x, y, z) | Notes |
| --- | --- | --- | --- |
| farm | VoxeLibre `mcl_villages/schematics/farm.mts` | 9, 8, 7 | no door, no bed; one `mcl_composters:composter` at (4,2,0); water sources and crops (wheat 13, potato 4, carrot 3) |
| hut ("shepherd's hut") | `mcl_villages/schematics/small_house.mts` | 9, 9, 8 | door at (4,2,2); `mcl_loom:loom` at (3,2,5); one bed at (4,2,5) |
| villa | existing Roman villa (`schematics/imports/roman/villa.mts`, #229) | measured by #229 | Roman towns only |
| chapel | existing medieval `chapel` template (shared catalog entry) | 9, 14, 17 | medieval towns only |

(Facts for the first two are checked against the installed game by the test.)

**Copy, do not point at the game's files.** `preflight.check`, `schematic.place`
and the catalog all prefix `modpath .. "/" .. entry.path`, so a game path would
need code changes in several places; the repository already copies stock
mcl_villages schematics (tavern, well, library, blacksmith: see
`tools/workshop_export/README.md`, "Stock village templates", and
`schematics/templates/NOTICE-stock-village.md`; CC-BY-SA 4.0, MysticTempest).
The farm and the hut follow that precedent into `schematics/outskirts/`, with
the same notice.

**Isolation.** Rural-only entries (`farm`, `shepherd_hut`, `villa`) live in a new
`schematics/outskirts/catalog.lua` (fields as `schematics/objects/catalog.lua`
plus `class`). `src/catalog.lua` does not read it: no rural id appears in
`catalog.entries`, `catalog.snapshot()`, `planner.landmark_profile`,
`planner.row_depth`, `content_planner` or any urban role pool. The chapel is a
shared entry referenced by id. `outskirts.assets(urban_entries)` returns a new
merged lookup (`out.entries`); only the outskirts part of preflight, the
outskirts builder and the combined node setup see it. A rural id equal to an
urban id is a programming error.

**Entrance-less farm.** The farm has no door, so it is composed like the oak and
garden objects (`kind = "object"`, no entrance, no door check).

**Workplaces (what the game does).** VoxeLibre `mobs_mc/villager.lua` gives a
villager a profession by the jobsite node it claims: composter is the farmer's
(`professions.farmer.jobsite`), loom the shepherd's. `look_for_job` /
`find_nodes_in_area` searches a box of +/-48 nodes around the villager (line
~867 of the installed file); a claimed composter also anchors Living Villages'
bounded crop visit (`farmer.lua`). Consequences:

- Each hut has a bed, so Towns' resident enumeration counts it and spawns one
  resident who claims the loom and becomes a shepherd. Living Villages'
  `loomless_house.lua` removes the loom from about half of the small houses it
  places itself; Towns places the schematic with its own placer, so that wrapper
  does not apply and every hut keeps its loom (one shepherd per hut).
- A farm has no bed, so nobody lives there; its composter is a **workplace for
  townspeople**. An unemployed townsperson claims it only if the composter is
  within 48 nodes of them when they look for work, and they are sent home when
  they stray more than about 50 nodes from their bed. A farm at gap 36 is
  reachable from houses within about 12 nodes of the town edge; a farm at gap 76
  is out of reach of every resident. The near band therefore provides workplaces
  only for the edge of town. Whether that is acceptable or `FARM_BAND_FAR`
  should shrink is a tuning question for #238 (section 10).

## 5. The scatter planner

Our own small deterministic planner, not Living Villages' `site_planner.lua`.
That module plans a standalone village (belltower, a ring generator around it,
church reservation, a minimum of 8 buildings, `create_site_plan` wrapper
installation, VoxeLibre `settlements`/`pr` environment); reusing it would mean
adapting all of that to avoid about sixty lines of rejection sampling. Its one
idea we reuse is the footprint levelness limit, as `MAX_SPREAD`.

### 5.1 Private random stream

```lua
state = (seed * 31 + SALT) % 2147483646 + 1
next  = function() state = state * 48271 % 2147483647; return state end
int(a, b) = a + next() % (b - a + 1)
```

`outskirts.new_rng(seed)`; same family as `open_space.lua`. Never the planner's
stream; no global generator.

### 5.2 Order and algorithm

Classes in fixed order: farms (`FARM_COUNT`), huts (`HUT_COUNT`), then villas
(`VILLA_COUNT`, Roman) or the chapel (`CHAPEL_COUNT`, medieval). Per building:

1. `rotation = int(0, 3) * 90`; `asset` = the class's catalog entry (the first
   in id order if a class ever has several; a draw is added then).
2. Its rect size is the rotated footprint (`geometry.place`).
3. Up to `ATTEMPTS_PER_BUILDING` attempts:
   - `outskirts.sample(band, size, bounds, rng)` draws a position uniformly in the
     band's outer box (`plan.bounds` grown by the far gap) and keeps the first
     whose gap to `plan.bounds` lies in the band, after at most `SAMPLE_LIMIT`
     draws; none: reject `no_site`.
   - `outskirts.fits(rect, plots, protected, player_pos)`: the rect's reach
     (rect grown by `TERRAFORM_REACH`) must not touch the protected rectangle
     (`plot_protected`), the gap to every accepted plot must be at least
     `MIN_SPACING` (`plot_spacing`), and the gap to the player must be at least
     `PLAYER_MARGIN` (`plot_player`); coordinates beyond +/-31000 are
     `plot_out_of_range`.
   - Emerge the plot's terraform volume (section 6) and read the footprint
     (`outskirts.check_site`): unreadable or ignore nodes `plot_unloaded`, any
     liquid or ice `plot_water`, spread over `MAX_SPREAD` `plot_uneven`; else
     `ground_y = site_search.median(heights)` (lower median). An emerge that
     fails or times out is `emerge_failed` (three timeouts in a row stop the
     outskirts planning with a dependency failure, as `site_search`).
   - The first attempt that passes yields the plot; the rest are skipped.
4. A building without an accepted plot is simply missing; each failed attempt is
   one recorded rejection.

Determinism: the stream is consumed in a fixed pattern (one rotation draw per
building, two draws per sample), so the plan is a function of the seed and of
the terrain the reader saw. Everything in section 5 except the emerge and the
reader is pure; the planner never writes.

### 5.3 Records

```lua
plot = {
  id = "f01",             -- class letter + running number: f farm, h hut, v villa, c chapel
  class = "farm",         -- "farm" | "hut" | "villa" | "chapel"
  asset = "farm",         -- id in out.entries
  rotation = 90,
  band = "near",          -- "near" (farms) | "far"
  rect = {x1, z1, x2, z2},    -- EXACTLY the rotated footprint (preflight.resolve requires it)
  distance = 40,          -- gap to plan.bounds
  heights = {min = 60, max = 62},
  ground_y = 61,          -- site ground Y (lower median of the footprint heights)
}

-- result.outskirts
outskirts_result = {
  version = 1,
  status = "planned",     -- "planned" | "empty" (nothing fit; not an error)
  seed = 8, center = {x, z},          -- must equal result.plan.seed / result.center
  ground_y = 62,                      -- the urban ground (reader window reference)
  protected = {x1, z1, x2, z2},       -- plan.bounds grown by PROTECT_MARGIN
  entries = {...},                    -- merged id -> catalog entry (not serialisable)
  plots = {plot, ...},                -- accepted, in planning order
  structures = {structure, ...},      -- composed (below), same order
  rejections = {rejection, ...},      -- every omission, in decision order
  counts = {requested = {farm = 18, hut = 6, villa = 2, chapel = 0},
            planned   = {farm = 16, hut = 6, villa = 1, chapel = 0},
            rejected  = {plot_water = 5, plot_uneven = 3, no_site = 1}},
}

-- composed structure: preflight.compose shape (min/max/size/entrance/front/rect/
-- rotation/ground_offset) plus:
structure = { id, kind = "outskirts" | "object", role = class, plot = "f01",
              site_ground_y = 61 }     -- the ground of THIS structure

rejection = { stage = "plot" | "terraform" | "emerge", code = "plot_water",
              subject = "f01:a3", detail = "one sentence with the numbers" }
```

The farm composes as `kind = "object"` (no entrance); the others as
`"outskirts"`.

### 5.4 Rejection codes (omissions)

| Code | Meaning |
| --- | --- |
| `no_site` | no position inside the band within `SAMPLE_LIMIT` draws |
| `plot_protected` | the plot's terraform reach touches the protected rectangle |
| `plot_spacing` | closer than `MIN_SPACING` to an accepted plot |
| `plot_player` | closer than `PLAYER_MARGIN` to the player's X/Z |
| `plot_out_of_range` | a coordinate would leave +/-31000 |
| `plot_unloaded` | a footprint column was not available |
| `plot_water` | a footprint column is water, ice or lava |
| `plot_uneven` | footprint height spread over `MAX_SPREAD` |
| `emerge_failed` | the plot's volume could not be loaded |
| `terraform_declined` | Living Villages returned `false, reason` for the plot (apply stage) |
| `terraform_incomplete` | Living Villages skipped unloaded blocks for the plot (apply stage) |

## 6. What Towns needs from Living Villages

Designed against the three issues as filed (not yet implemented). Today
(`village_smoothing.lua`, installed commit 457c485) `M.terraform(plan, pr, env,
config)` does the right pipeline (load area, `clear_trees`, smooth, `apply`,
holes) but: it is reachable only by `dofile`; it reads footprints from
`env.settlements.schematic_table` and needs `mcl_vars`; on an empty plan or an
unreadable area it calls the VoxeLibre `env.original` terraform and returns
`false`; it returns only a boolean (the numbers go to the log); and nothing
keeps it out of a protected area. Its defaults are `margin 2, radius 8, cap 5,
wall 6`; Towns uses them unchanged (the cap, wall and holes limits are Living
Villages' business, not ours).

### 6.1 luanti-villages#274: public table

Towns needs exactly this from `living_villages.terrain` (name as proposed):

- `version`: an integer API version; Towns requires `1`. Anything else is a
  dependency failure.
- `terraform(plan, schematics, opts)` (from #275).
- `volume(plan, schematics, opts) -> {minp, maxp}`: **an addition to the issue
  as filed.** The box that `terraform` reads and writes for those pads
  (`area_of` plus the tree margin `fragments.config.cap_radius`, the hole area
  `holes.area`, below/above), so Towns can emerge it. `terraform` never emerges.

Towns does not need `targets`, `pads`, `structure_test`, `heights`, `set_column`
or the site planner. It does not `dofile` Living Villages files.

### 6.2 luanti-villages#275: caller-supplied plan, no fallback

`terraform(plan, schematics, opts) -> true, result | false, reason`

- `plan`: settlement-style entries `{name, pos, rotat, surface_mat}`. Towns passes
  one entry per call: `pos` = the footprint's minimum X/Z corner and **`pos.y` =
  the plot's `ground_y`**; `rotat = tostring(rotation)`; `surface_mat` nil (Living
  Villages' default). The rotated footprint Living Villages derives
  (`village_terrain.footprint`: `rotat` "90"/"270" swap width and depth) equals
  the plot rect (tested).
- `schematics`: caller-supplied table
  `{ {name, hwidth, hdepth, hheight}, ... }` = the file size x, z, y of the entry
  (no `settlements` global).
- `opts`: `protected` (6.3) and optionally `config`; nothing else.
- Must not call the VoxeLibre fallback, `settlements.*` or `mcl_vars`; loads
  nodes through the engine.
- Returns `true, result` with `result = {stats = {changed, cut, filled,
  steepest, violations, unloaded, trees, holes}, box = {min, max}}` (the numbers
  it logs today, and the X/Y/Z box it wrote), or `false, reason` when it cannot
  run (empty plan, unreadable terrain). `stats.unloaded > 0` (blocks it skipped)
  is Towns' `terraform_incomplete`; `false` is `terraform_declined`.
- Existing village behaviour unchanged.

### 6.3 luanti-villages#276: protected rectangles

`opts.protected = { {x1, z1, x2, z2}, ... }` (inclusive X/Z). No column inside
is read as changeable or written, including tree removal and cleanup, hole
filling and ramps; protected columns are fixed ground for the slope limit.
Towns passes one rectangle: `plan.bounds` grown by `PROTECT_MARGIN`, which is
`F.protected` in the fixture. Towns also asserts `result.box` does not intersect
it; a violation is a programming error (`outskirts_error`), reported honestly
after the fact.

### 6.4 A draft already exists

The Living Villages working tree (uncommitted when this was written) has
`docs/terrain-api.md` describing `living_villages.terrain.terraform(plan, pr, env,
{config, schematic_table, protected})` returning `false, reason` or `true,
stats` with `written` (the inclusive `minp`/`maxp` box), protected rectangles
as `{x0, z0, x1, z1, margin}` (so `PROTECT_MARGIN` could be passed as `margin`
instead of growing the rectangle), plus pure `pads`/`targets`/`structure_test`.
It matches the capabilities above with different spellings (positional `pr`
and `env`, `schematic_table` in `opts`, `stats.written` for the box) and does
not mention `version` or `volume`. Towns needs the capabilities, not the
spellings: whatever lands, `outskirts_terrain` (#231) is the only module that
spells the call, and the missing `volume` and `version` remain requests.

### 6.5 The plot-to-call mapping (worked example, section 9)

Farm `f01`: rect `x 1000..1006, z -1875..-1867` (rotation 90 of a 9 x 7
footprint), ground 61: plan `{name = "farm", pos = {x = 1000, y = 61, z =
-1875}, rotat = "90"}`, schematic `{name = "farm", hwidth = 9, hdepth = 7, hheight
= 8}`.

## 7. Integration

```
/towns_generate
  generate_command.search(pos, seed, town_type, done)
    site_search.search(...) -> result                  -- unchanged
    outskirts.search(result, {player_pos = pos, ...}, cb, env)   -- NEW: async, reads + emerges only
        cb(out) -> result.outskirts = out; done(result, nil, details)
        cb(nil, msg, "outskirts_dependency" | "outskirts_error") -> command stops, nothing written
  generate_command.build(result)
    preflight.check(...)                               -- urban, unchanged
    preflight.check_outskirts(out, env, params)        -- NEW, zero writes
    builder.build_town(result, {entries = catalog.entries}, env)   -- unchanged: urban terrain,
                                                                   --   schematics, doors, node setup
    outskirts_build.apply(out, env)                    -- NEW: the only outskirts writes
    summary.town.structures = urban ++ placed outskirts structures
    residents.enumerate(summary.town.structures, ...)  -- unchanged call
    residents.initialize(...)                          -- unchanged
```

`site_search`, `planner.plan`, `generate.lua`'s controller and `builder` are not
changed. `result.outskirts` is an additional field; `outskirts.search` plans from
`result.plan` (the accepted-centre plan `same_footprint` verified).

### 7.1 `outskirts.search(result, opts, done, env)`

Reads and emerges only. `opts = {assets, terrain, player_pos}` where `player_pos`
is the `pos` that `generate_command.search` already receives and `terrain` is
`living_villages.terrain`. `env` is the `site_search` env. Steps:

1. Dependencies: `terrain.version == 1`, `terrain.terraform` and `terrain.volume`
   are functions, `outskirts.assets` succeeds (rural catalog readable, shared ids
   present). Otherwise `done(nil, message, "outskirts_dependency")`.
2. Plan as in 5.2. Each candidate emerges
   `outskirts.volume(plot, ground_ref)`: X/Z from `terrain.volume`, Y from the
   volume's range widened by `SCAN_DOWN`/`SCAN_UP` around the urban ground.
3. After planning, re-emerge each accepted plot's volume once (at most 27
   emerges) so everything is loaded when the build runs in the same step
   (emerged blocks can unload after about half a minute without players).
4. `validate`, then `done(out)`. Any raised error is caught by `pcall` and
   becomes `done(nil, "internal error in outskirts: ...", "outskirts_error")`.

Worst case work: `(FARM_COUNT + HUT_COUNT + VILLA_COUNT + CHAPEL_COUNT) *
ATTEMPTS_PER_BUILDING` emerges (162 with the placeholders); the typical case is
close to one per building.

### 7.2 Preflight

`preflight.check_outskirts(out, env, params)` (zero writes):

- `preflight.compose_outskirts(out, entries)` resolves each plot at its own
  `ground_y` (not the urban one), passing the **plot's own rect** as the bounds
  `preflight.resolve` checks (it rejects rects outside the bounds it is given; the
  urban `plan.bounds` would reject every plot). The rect must equal the rotated
  footprint, no two structures overlap, none touches `plan.bounds` or the
  protected rectangle, none is within `PLAYER_MARGIN` of the player.
- Files, sizes and node registrations of the rural ids are checked once per id.
  Geometry, overlap or protection errors are `outskirts_error`; a missing rural
  file, a size mismatch or an unregistered node is `outskirts_dependency`. Both
  stop the command (`inspection_failed`, zero writes).

### 7.3 `outskirts_build.apply(out, env)`: ordering and risk

Runs after `builder.build_town` returned a summary, so the urban town is
complete. Then, in this order:

1. **Terraform every plot**, one `terrain.terraform` call per plot, with
   `protected`. A `false` or `stats.unloaded > 0` marks that plot skipped
   (`terraform_declined` / `terraform_incomplete`, reported); the others go on.
2. **Place every non-skipped plot's schematic** with the same
   `env.place_structure` the urban build uses, then run `check_door` with the
   plot's ground for structures that have an entrance.
3. `env.setup_nodes(outskirts_structures, entries)` (functional nodes: the
   composter, loom, chests; `node_setup` keys placements by `id@min`, so a
   second call is independent).

Why terraform-all-then-place-all: Living Villages reads the surface by scanning
columns, so a finished building next to a later pad would look like a hill. With
`MIN_SPACING >= 2 * TERRAFORM_REACH` the pads do not influence each other; the
order protects against the cases where the holes or tree margin do. Why one call
per plot: a decline skips only that plot. The cost is that tree clearing and hole
filling run 27 times and the whole `apply` happens in one server step (a stall,
cf. #186).

Risks, stated plainly:

- Living Villages writes through `swap_node` outside Towns' preflight and region
  model, so there is no "prove zero writes first" for the outskirts; a failure
  in `apply` is a post-write failure. The urban town is already complete and
  untouched by construction (protected rectangle, `result.box` assertion).
- A plot can be terraformed and then fail to place (placement error, unreachable
  door). That is a `write_failed` with every attempted box (urban box and each
  plot's `result.box`); no retry, no rollback.
- Towns no longer writes outskirts terrain through its own region, so the
  fresh-region-per-commit rule of the earlier design does not apply. If Towns
  ever writes a region again it must open it just before its own commit.

### 7.4 Residents and summary

`summary.town.structures` is the urban list followed by the placed outskirts
structures; `generate_command`'s existing `residents.enumerate` and
`residents.initialize` run unchanged and find the huts' beds. `summary.outskirts
= {status, counts, rejections (counts), skipped = {{plot, code, reason}},
boxes}` for the report (#238).

## 8. Outcome classes

| Class | Examples | Signal | Result |
| --- | --- | --- | --- |
| **Omission** | every code in 5.4: no site, water, uneven, spacing, protected, player nearby, emerge failure, Living Villages declining or skipping a pad | `nil, rejection` / `skipped` entry | Never an error. Fewer buildings, possibly none; reported with counts. Urban town builds. |
| **Dependency failure** | `living_villages.terrain` missing, wrong `version`, or lacking `terraform`/`volume`; rural catalog or schematic missing, wrong size or unregistered node | `outskirts_dependency` | Whole command stops before any write. |
| **Programming error** | malformed plan or record, `validate` failure, a structure that is not its rotated footprint, a plot overlapping another or the protected rectangle, rural/urban id collision, a Living Villages box inside the protected rectangle | `error(...)`, `pcall` in `search`; code `outskirts_error` (after the fact: `write_failed`) | Whole command stops before any write; reported as an error. |
| **Post-write failure** | `place_structure` error, unreachable door, node setup failure, a plot that cannot be placed after its terraform | `outskirts_build.apply` | `write_failed` listing attempted boxes; partial world; no retry; no residents. |

Not finding places, unsuitable terrain and Living Villages declining a pad are
omissions and never fail the command.

## 9. Worked example

Fixture: `tests/outskirts_fixture.lua`. Roman town, seed 8, centre `(1000,
-2000)`, urban ground 62, `plan.bounds x 905..1085, z -2086..-1915`; protected
rectangle `x 881..1109, z -2110..-1891` (bounds + 24).

| | `f01` farm | `h01` hut |
| --- | --- | --- |
| band, gap to bounds | near, 40 (36..75) | far, 125 (76..143) |
| rotation | 90 (first stream draw: 22928725 % 4 = 1) | 0 |
| rect | x 1000..1006, z -1875..-1867 (7 x 9) | x 1210..1218, z -2010..-2003 (9 x 8) |
| footprint heights | 60..62 (spread 2), ground 61 | 63..65 (spread 2), ground 64 |
| schematic origin Y / box | 61 (`ground_offset` 0), y 61..68 | 64, y 64..72 |
| entrance | none (object) | file (4,2,2): world `(1214, 66, -2008)`, front -Z, feet Y 66 |
| terraform reach to protected | 16 | far |

The hut's canonical entrance front (-Z) is an assumption until #227 measures the
import; the door position, loom and bed are measured. The Living Villages call for
the farm is the plan and schematic of 6.5 with `protected = {F.protected}`; an
illustrative result is `{stats = {changed = 152, cut = 40, filled = 112,
steepest = 2, violations = 0, unloaded = 0}, box = {min = (988, 41, -1885),
max = (1018, 85, -1857)}}`, whose box stays outside the protected rectangle (its
south edge z -1885 is above -1891). The example town ends with 16 of 18 farms, 6
huts, 1 of 2 villas; the 9 recorded rejections (`plot_water` 5, `plot_uneven` 3,
`no_site` 1) account for the shortfall.

## 10. Open questions and added complexity

For the product owner:

1. **Farm reach versus job reach.** Villagers find a composter only within 48
   nodes and are sent home beyond about 50 from their bed (section 4). With the
   near band at gap 36..76, farms give work only to residents near the town edge.
   Options: narrow the band (for example 36..56), accept it, or later give farms
   a bed. Unchanged unless told.
2. **Door failure after terraform** is a `write_failed` of the whole command
   (consistent with the urban builder). A softer rule (report and leave the
   hut) is possible.
3. **No structure protection.** Ruined portals and outposts in the countryside
   can be damaged by terraforming (Living Villages' site planner avoids them;
   its terraform does not unless a `scan` is passed). Not planned for v1.
4. **No special handling when the town ends on a cliff.** Plots are planned from
   the bands as if the ground were open; `plot_uneven` and `plot_water` thin them
   out.

Added complexity of this direction (for the product owner): it depends on three
unmerged Living Villages issues (#274 plus the `volume` addition, #275, #276) and
cannot start there; terraform runs 27 times in one server step after the urban
build, with tree clearing and hole filling (a visible stall); up to about 160
emerges during planning; the farm gives workplaces only near the town edge;
huts add six residents; and the near/far bands, counts and spacing are
placeholders that will need playtesting.
