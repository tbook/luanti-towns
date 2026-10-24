# Outskirts v1: data and integration contract

Status: contract for issues #227-#238 (epic #225). Written for #226. This
document defines records, signatures, constants and rules so the dependent
tickets do not invent architecture independently. It adds no generation code.
Everything below was checked against the code in this repository at the time of
writing and, where marked, against the installed Living Villages mod (commit
457c485). `tests/outskirts_contract_tests.lua` and `tests/outskirts_fixture.lua`
hold the worked example and executable checks of the exits rule, the example's
arithmetic, the constants quoted here and the Living Villages behaviour relied on.

Scope reminder (epic #225): sparse countryside development beside the roads that
leave medieval and Roman towns, planned after the urban site is accepted. Urban
`plan.bounds`, `plan.boundary`, the planner's random stream and the urban layout
do not change. Not included: new villager AI, path wear, a generic zoning or
decor framework, distant roads, pathfinding, bridges, natural generation, walls,
procedural barns or orchards, performance work (#186), exporter work (#187).

## 1. Conventions

**Coordinates.** Luanti node coordinates as in `src/geometry.lua`: +X east, +Z
north, +Y up. A *column* is an `(x, z)` pair.

**Rectangles and boxes are inclusive.** A rect is `{x1, z1, x2, z2}` with
`x1 <= x2`, `z1 <= z2`; width is `x2 - x1 + 1`. A box is
`{min = {x, y, z}, max = {x, y, z}}`, also inclusive. A direction `dir` is a unit
vector `{x, z}` with exactly one non-zero component.

**Three different Y values.** Mixing them up is the most likely defect in this
feature, so each has one name:

| Name | Definition | Where it comes from |
| --- | --- | --- |
| *schematic origin Y* | world Y of schematic layer 0 = `site_ground_y - ground_offset` | `preflight.compose` places at `{rect.x1, ground_y - ground_offset, rect.z1}` |
| *site ground Y* (`ground_y`) | Y of the finished **surface node row**; the node at `ground_y` is the walking surface, everything above it is air | urban `result.ground_y`; for outskirts `group.ground_y`, `road.y[k]`, `column.at` |
| *entrance feet Y* | `origin Y + entrance.y` (`geometry.place(...).entrance.y`); the door's bottom node. For catalog entries `entrance.y = ground_offset + 1`, so feet stand on the surface row: `feet = ground_y + 1` | `src/geometry.lua`, `builder.check_door` stands at `ground_y + 1` |

Example (section 12): `ground_offset = 1`, ground 67, schematic origin 66,
entrance feet 68. `ground_offset` is the depth of captured foundation below the
site ground, so layers `0 .. ground_offset - 1` lie under the surface row and are
overwritten by the schematic.

Living Villages `pad.y` and `plan[i].pos.y` use the same convention as *site
ground Y* ("the schematic's bottom slice is the ground layer, so `pos.y` is the
surface", `village_smoothing.pads`). Towns' `ground_offset` is not represented in
Living Villages; **`pad.y` is always the site ground Y, never the schematic
origin Y.**

**Finished column.** For a column with finished height `at`:

| Rows | Content |
| --- | --- |
| `y > at` up to `region.bounds.max.y` | air (clears trees, snow, plants, the old terrain above a cut) |
| `y == at` | surface node: the column's natural surface node as read (`opts.surface(x, z)`, as `town_layout` does), falling back to `SURFACE_NODE` when that is not a soil; `PATH_NODE` on road and approach columns |
| `at - SUPPORT_ROWS <= y < at` | filled or support rows, as `town_layout` does for `FILL_DIRT_DEPTH`: dirt in rows that were not solid stable ground |
| below | untouched |

Because every fill is at most `CUT_FILL_CAP` (2) deep and `SUPPORT_ROWS` is 3, a
fill never needs stone; the layout must raise a programming error if a column
needs more.

## 2. Frozen constants

First-version constants. No runtime settings. `tests/outskirts_fixture.lua`
(`F.constants`) mirrors this block and the test checks that this text contains
every line verbatim.

```lua
VERSION = 1,                  -- result.version
TARGET_GROUPS = 2,            -- village groups wanted
ORDINARY_MIN = 8,             -- visual target (2 groups x 4); never a reason to search more
ORDINARY_MAX = 12,            -- hard cap on ordinary buildings (2 groups x 6)
GROUP_PLOTS_MIN = 4,          -- visual target per group
GROUP_PLOTS_MAX = 6,          -- plots a candidate may list (3 per side)
MIN_ACCEPTED_PLOTS = 2,       -- a group with fewer surviving plots is rejected
MAX_VILLAS = 2,               -- Roman towns only
MAX_CHAPELS = 1,              -- medieval towns only
PATH_WIDTH = 3,               -- road lane and every entrance approach
CUT_FILL_CAP = 2,             -- ordinary pad/yard/skirt/approach: max |finished - natural|
VILLA_CAP = 1,                -- the same for a villa pad
ROAD_CAP = 2,                 -- road lane column: max |finished - natural|
ROAD_MAX_LENGTH = 60,         -- lane columns beyond the join, per exit
SLOT_FIRST = 10,              -- first window starts at this road column k
SLOT_STEP = 26,               -- k distance between window starts
SLOTS_PER_EXIT = 2,
GROUP_WINDOW = 24,            -- road columns a group may use (3 plots of 7 + gaps per side)
SETBACK = 3,                  -- free nodes between lane edge and a plot rect
ATTEMPTS_PER_EXIT = 4,        -- 2 slots x {both sides, one side}
GROUP_EVALS = 12,             -- terrain evaluations for village groups, whole town
LANDMARK_EVALS = 4,           -- terrain evaluations for villas and the chapel, whole town
TERRAIN_MARGIN = 2,           -- Living Villages config.margin (flat yard around a footprint)
TERRAIN_RADIUS = 6,           -- Living Villages config.radius (skirt)
TERRAIN_WALL = 4,             -- Living Villages config.wall
SUPPORT_ROWS = 3,             -- equals town_layout FILL_DIRT_DEPTH
CLEAR_ABOVE = 12,             -- air rows above the highest surface or structure of a region
SCAN_UP = 24,                 -- reader window above the urban ground
SCAN_DOWN = 24,               -- ... and below it
CUT_FILL_MARGIN = 8,          -- emerged margin around and below, as site_search.build_volume
SALT = 226,                   -- private random stream
PATH_NODE = "mcl_core:grass_path",
SURFACE_NODE = "mcl_core:dirt_with_grass",
```

Living Villages' own `village_smoothing.config` defaults are `margin 2, radius 8,
cap 5, wall 6`; Towns passes the frozen values explicitly (section 7).

`PATH_NODE` is the node `living_villages/paths.lua` itself produces
(`PATH = "mcl_core:grass_path"`). Its wear logic only converts
`mcl_core:dirt_with_grass`, and only reverts blocks it converted itself
(`is_path[hash]`), so explicit paths are never reverted. `grass_path` is neither
`partial` nor `tall` in `builder.check_door`, so approaches pass the door check.

Derived checks (tested): two minimal groups reach `ORDINARY_MIN`, two full groups
`ORDINARY_MAX`; the last window ends at column
`SLOT_FIRST + (SLOTS_PER_EXIT - 1) * SLOT_STEP + GROUP_WINDOW - 1 = 59 <=
ROAD_MAX_LENGTH`; `SLOT_FIRST - (TERRAIN_MARGIN + TERRAIN_RADIUS) >= 2` so the
first window's smoothing reach never touches the join column.

## 3. Exits

An *exit* is the end of a principal street that leaves the urban boundary
union without being closed by a landmark. A bounding-box edge alone is not an
exit; `plan.bounds` is only used to reject a start node inside it.

### 3.1 Rule

Input: the accepted plan (`result.plan`, the second planning at the accepted
centre; `site_search` compares it with the inspected footprint via
`same_footprint`). Use only `plan.streets`, `plan.boundary.rects`, `plan.sites`
(rects, kind, id), `plan.blocks` and `plan.bounds`. Do **not** use
`gate_span`, `approach.pos` or any landmark door data: issue #230 (castle gate
one node off the road) is fixed in parallel and the rule does not depend on it.

For every street with `kind == "principal"` and each of its two ends along the
long axis of `street.rect`:

1. `cross = {c1, c2}` is the street's extent on the other axis (width 6 for both
   town types); `last` is the end coordinate on the long axis; `sign` is +1 or
   -1 outward.
2. For `k = 1, 2, ...` look at the `width` cells `(last + sign * k, c1..c2)`.
   Classify each cell:
   - `outside`: in no `plan.boundary.rects` rect;
   - `pass`: inside a site with `kind == "landmark"` and `id == "arch"`;
   - `blocked`: inside any other site (landmark or square), any block, or any
     other street's rect;
   - `free`: inside the union and none of the above (the Roman margin).
3. All `outside`: the exit is found; `start` is that cell on the lane centre
   line, `join = start - dir`. Mixed `outside` with anything else, or any
   `blocked`, or a mixture of `pass` and `free`: no exit at this end (the end is
   reported as blocked by the blocker's name). All `pass` or all `free`:
   continue with `k + 1`. `via` is the last arch name crossed.
4. `start` must lie outside `plan.bounds`; otherwise the exit is dropped with
   rejection `exit_inside_bounds`.

*Lane.* `inset = floor((width - PATH_WIDTH) / 2)`; the lane is
`cross.c1 + inset .. cross.c1 + inset + PATH_WIDTH - 1` and `centre` is its
middle coordinate. For a six-wide street the lane sits one node inside the lower
edge (half a node off the street's own centre; cosmetic and deterministic).

### 3.2 Results on real plans

Verified by the test over the real planners.

*Roman* (centre `(0,0)`; the plan translates with the centre): the four
principals end `59` nodes beyond the forum at `z = 73 / -74` and `x = 73 / -74`.
Each is followed by an arch (`arch_north` z 74..81, `arch_south` -82..-75,
`arch_east` x 74..81, `arch_west` -82..-75; 12 wide, so it covers the 6-wide
street) and then four free margin nodes up to the boundary (`plan.bounds` is
`x -95..85, z -86..85`, one rect). Exits: north start `(−1, 86)`, east
`(86, −1)`, south `(−1, −87)`, west `(−96, −1)`, all `via` their arch. Four
exits.

*Medieval* (canonical arrangement, centre `(0,0)`, bounds 210x151: `core`
x -78..77 z -46..45, cathedral x -35..19 z 46..104, castle x -132..-79
z -24..25; principals E-W x -78..77 z -3..2 and N-S x -3..2 z -46..37): the east
end (x 77, next x 78 is outside) and the south end (z -46, next z -47) are
exits; the west end meets the castle rect and the north end meets the parvis
square, both `blocked`. For **all 32 arrangements** (4 market quadrants x castle
west/east x 4 turns) there are exactly two exits, the blocked ends are always
`castle` and `parvis`, and each start is outside both the union and
`plan.bounds`. A turn rotates which compass sides are open; the rule does not
care.

### 3.3 Order

`outskirts.exits` returns exits sorted by direction rank N(+z), E(+x), S(-z),
W(-x), then `street_id`, and numbers them `e1, e2, ...`. The *trial order* is
that list rotated to start at index `seed % #exits + 1` (seed = `plan.seed`).
The order is a pure function of plan and seed, finite, and independent of the
terrain.

### 3.4 Record

```lua
exit = {
  id = "e1", street_id = 1,           -- plan.streets[].id
  via = "arch_north",                 -- nil when no arch was crossed
  dir = {x = 0, z = 1}, axis = "z",   -- axis of travel
  width = 6,
  cross = {c1 = 997, c2 = 1002},      -- street extent on the other axis
  lane  = {c1 = 998, c2 = 1000}, centre = 999,
  join  = {x = 999, z = -1915},       -- last node inside the union, on the lane centre
  start = {x = 999, z = -1914},       -- road column k = 1 (first node outside the union)
}
```

Road column `k` (1-based) is the lane column whose position along `axis` is
`start + (k - 1) * dir`. Everything outskirts-owned lies **outside
`plan.bounds`** (a superset of the union), so it can never touch an urban
column, an urban liquid-seal read ring (one node outside the union), or the
unused corners of the medieval bounding box.

## 4. Records

All plain tables. A "rect" is an inclusive X/Z rect. Fields are the full list;
nothing else is required.

```lua
-- plot: one building site, planned before any terrain is read.
plot = {
  id = "g1p1",                -- "<group id>p<n>", n in candidate order
  class = "cottage",          -- pool name, see 9
  asset = "village_cottage_a",-- id in the merged entries table
  side = -1,                  -- -1: lower coordinate across the road, +1: higher
  rotation = 270,             -- geometry.lua rotation; the entrance faces the lane
  rect = {x1, z1, x2, z2},    -- EXACTLY the rotated footprint (preflight.resolve requires it)
}

-- group (candidate and, once accepted, result): a small cluster served by one road.
group = {
  id = "g1", kind = "village",        -- "village" | "villa" | "chapel"
  exit_id = "e1", slot = 1, attempt = 1,
  window = {k1 = 10, k2 = 33},        -- road columns the group may use
  plots = {plot, ...},                -- accepted: survivors only, ids keep their candidate numbers
  ground_y = 67,                      -- one site ground Y for the whole group (accepted only)
  pads = {pad, ...},                  -- accepted only, parallel to plots
}

-- pad: the Living Villages pad fields plus the plot id. Pure data.
pad = {
  plot_id = "g1p1",
  x0 = 987, z0 = -1905, x1 = 994, z1 = -1899,          -- footprint (inclusive)
  yx0 = 985, yz0 = -1907, yx1 = 996, yz1 = -1897,      -- yard = footprint grown by TERRAIN_MARGIN
  y = 67,                                              -- site ground Y (NOT the schematic origin)
  surface = "mcl_core:dirt_with_grass",                -- SURFACE_NODE
  height = 7,                                          -- size.y; informational
}

-- road: the planned extension of one exit's lane.
road = {
  exit_id = "e1",
  reach = 33,       -- columns that passed the checks, <= ROAD_MAX_LENGTH
  length = 14,      -- columns built: farthest accepted approach column + (PATH_WIDTH - 1) / 2
  join_y = 62,      -- the leveled urban ground at the join
  natural = {...},  -- natural surface height of lane column k (centre), k = 1..length
  y = {...},        -- finished surface height of lane column k; all PATH_WIDTH columns share it
}

-- approach: path from a door to the lane. cells run along dir from `from`,
-- the node outside the entrance, PATH_WIDTH wide across dir, centred on `from`.
approach = {
  plot_id = "g1p1",
  from = {x = 995, z = -1902}, dir = {x = 1, z = 0},
  length = 3,          -- = SETBACK; the last cell touches the lane edge
  width = 3,
  y = {67, 66, 66},    -- finished height of each cell, y[1] == group.ground_y
  road_k = 13, road_y = 66,   -- road column and finished height where it attaches
}

-- composed structure: preflight.compose shape plus three outskirts fields.
structure = {
  id, kind = "outskirts", role = "cottage", rotation, rect, min, max, size,
  entrance, front, ground_offset, excluded_beds,    -- as preflight.compose
  group = "g1", plot = "g1p1",
  site_ground_y = 67,       -- the finished ground of THIS structure (urban ones use result.ground_y)
}

-- terrain target column: one per owned column of a region (changed or not).
column = {
  x = 990, z = -1902,
  kind = "footprint",   -- "footprint" | "yard" | "skirt" (Living Villages kinds)
                        --   | "road" | "approach" (Towns kinds)
  was = 66,             -- natural surface height as read
  at = 67,              -- finished surface height
  pad = "g1p1",         -- owning plot (nil for road)
}

-- region: one VoxelManip write region per exit arm (its road and every group on it).
region = {
  id = "r1", exit_id = "e1",
  bounds = {min = {x, y, z}, max = {x, y, z}},   -- exact write bounds
  volume = {min, max},                           -- emerged volume
  columns = {column, ...},                       -- sorted by x then z; each column once
  structures = {structure, ...},                 -- the arm's structures
}

-- rejection: an ordinary omission. Never an error.
rejection = {
  stage = "accept",       -- "exit" | "road" | "candidate" | "accept" | "emerge"
  code = "pad_cut_fill",  -- section 5.1
  subject = "e3:a1",      -- "<exit>", "<exit>:a<attempt>" or "<plot id>"
  detail = "one human sentence with the numbers",
}

-- complete outskirts result: result.outskirts
outskirts_result = {
  version = 1,
  status = "planned",     -- "planned" | "empty" | "unavailable"
  reason = nil,           -- why, for "empty" and "unavailable"
  seed = 8, center = {x = 1000, z = -2000},   -- must equal result.plan.seed / result.center
  ground_y = 62,          -- the urban ground the roads were joined to
  entries = {...},        -- merged id -> catalog entry lookup (not serialisable), section 9
  exits = {exit, ...},    -- all derived exits, canonical order
  order = {"e1", ...},    -- trial order
  roads = {road, ...},    -- one per exit that was tried
  groups = {group, ...},  -- accepted groups only
  approaches = {approach, ...},
  structures = {structure, ...},   -- all accepted structures, group then plot order
  regions = {region, ...},         -- disjoint boxes, one per arm that has anything to build
  rejections = {rejection, ...},   -- every omission, in decision order
  counts = {groups = 1, ordinary = 2, landmarks = 0, evals = 1,
            rejected = {pad_cut_fill = 1}},
}
```

`status = "empty"` means the planner ran and nothing fit; `"unavailable"` means a
dependency was missing (section 11). Both have empty `groups`, `regions`,
`structures`; neither blocks the town.

## 5. Candidate, road and acceptance rules

### 5.1 Rejection codes (ordinary omissions)

| Code | Meaning |
| --- | --- |
| `no_exits` | the plan has no exit |
| `exit_inside_bounds` | an exit start lies inside `plan.bounds` |
| `road_unloaded` | a lane column's block was not available |
| `road_water` | a lane column is water, ice or lava |
| `road_steep` | a lane column cannot be reached within `ROAD_CAP` of its natural height |
| `road_short` | the road's reach does not cover the candidate's window |
| `plot_unloaded` | a footprint or yard column was not available |
| `plot_water` | a footprint or yard column is water, ice or lava |
| `plot_overlap` | the plot overlaps another plot, structure or yard |
| `plot_inside_town` | the plot, yard or reach touches `plan.bounds` |
| `approach_blocked` | the approach crosses another plot or yard |
| `approach_steep` | ground and road differ by more than `SETBACK - 1`, or an approach column is farther than `ROAD_CAP` from its natural height |
| `pad_cut_fill` | a footprint or yard column differs from the group ground by more than the cap |
| `yard_not_level` | Living Villages left a footprint or yard column not at `pad.y` |
| `skirt_steep` | after merging roads, a changed column has a neighbour more than one node away |
| `group_small` | fewer than `MIN_ACCEPTED_PLOTS` plots survive |
| `region_overlap` | the arm's write box would intersect another region |
| `emerge_failed` | the volume could not be loaded |
| `out_of_range` | a volume would leave +/-31000 |

### 5.2 Candidate generation (deterministic, finite)

Per exit, in trial order, attempts `a = 1 .. ATTEMPTS_PER_EXIT`:

- `slot = ceil(a / 2)`, `window.k1 = SLOT_FIRST + (slot - 1) * SLOT_STEP`,
  `window.k2 = k1 + GROUP_WINDOW - 1`.
- Odd `a`: plots on both sides. Even `a`: one side only, `-1` when `a / 2` is
  odd, else `+1`.
- On each side, plots follow each other from `k1` with one free node between
  them, up to 3 per side and `GROUP_PLOTS_MAX` in total. A plot's near edge is
  `SETBACK` free nodes beyond the lane edge (`rect.x2 = lane.c1 - 1 - SETBACK`
  on the lower side for a north/south road, `rect.x1 = lane.c2 + 1 + SETBACK`
  on the higher side; mirrored for east/west). The rotation makes the entrance
  face the lane (`geometry.place` `front`). A plot whose along-road extent no
  longer fits in the window is not listed. Fewer than `MIN_ACCEPTED_PLOTS`
  listed: `group_small`.
- Plot assets come from the pools (section 9) by the private stream. Whatever a
  rejected attempt consumed from the stream is lost; the stream is only a
  function of `(seed, order of calls)`.
- The first accepted group on an exit ends that exit's attempts (one village
  group per exit). The loop stops at `TARGET_GROUPS` accepted village groups,
  `GROUP_EVALS` terrain evaluations (calls of `terrain.adapt`), or when exits
  run out. Cheap rejections (`road_short`, `plot_*` before the targets call) do
  not consume an evaluation but are bounded by `#exits * ATTEMPTS_PER_EXIT`.
- Villas (Roman only, at most `MAX_VILLAS`) and the chapel (medieval only, at
  most `MAX_CHAPELS`) are candidates of `kind` `"villa"`/`"chapel"` with one
  plot, tried after the village loop over the same exits and unused slots, at
  most `LANDMARK_EVALS` evaluations in total, pad cap `VILLA_CAP` for villas. A
  window is widened to the plot's along-road extent if that is larger, but must
  still end at or before `ROAD_MAX_LENGTH`.

### 5.3 Random stream

Private and seeded; never the planner's. Same family as `open_space.lua`:

```lua
state = (seed * 31 + SALT) % 2147483646 + 1
next  = function() state = state * 48271 % 2147483647; return state end
int(a, b) = a + next() % (b - a + 1)
```

The stream is created once in `outskirts.new_rng(seed)` and passed explicitly;
no function reads a global generator.

### 5.4 Road planning

`plan_road(exit, ground_y, read)` walks lane columns `k = 1 ..
ROAD_MAX_LENGTH`. `read(x, z)` returns the natural height of a column (section
7.3). For each `k` take the natural heights of the `PATH_WIDTH` lane columns;
the *natural* of the column is the median of the three. Then:

```
y[0] = ground_y                                  -- the leveled urban surface at the join
y[k] = y[k-1] + clamp(natural[k] - y[k-1], -1, 1)
the column stops the road when any lane column is unreadable, water, or
  |y[k] - its own natural| > ROAD_CAP
```

`reach` is the number of columns before the first stop. The three lane columns
share `y[k]` (no cross slope). One step per node means every road node is
reachable by the builder's own walk rule (rise 1, drop 3; `builder.check_door`).

**The join.** The urban surface is flat at `result.ground_y` over the whole
boundary union (`town_layout`: `y == g` is pavement or the natural surface node,
everything above `g` is cleared) including the Roman four-node margin beyond the
arch. The first outskirts column (`k = 1`) is the first node outside the union;
`y[0] = ground_y` is the join, so `|y[1] - ground_y| <= 1` by construction. The
transition from the six-wide urban street (and a Roman arch, whose opening is
not modelled) to the three-wide path is not smoothed: the path begins where the
street ends, and in the Roman case the margin nodes between the arch and the
first road column stay plain ground at `ground_y`.

### 5.5 Approach planning

`plan_approach(plot, structure, road, group_ground_y)` starts at `from`, the first
node outside the plot's rect found by stepping from `structure.entrance` along
`structure.front` (the rule of `authored_plan.validate`'s approach check, so a
recessed door is handled; for a flush door it is `geometry.place(...).outside`),
and runs `SETBACK`
cells along `front` to the lane edge, `PATH_WIDTH` wide across, centred on
`from`. With `delta = road_y - ground_y` where `road_y = road.y[road_k]` and
`road_k` is the road column opposite `from`: `|delta| <= SETBACK - 1` else
`approach_steep`; `y[i] = ground_y + sign(delta) * min(i - 1, |delta|)` for cell
`i = 1 ..`, so the last cell equals `road_y` and the approach steps at most one
node per cell. Cells may not intersect another plot's rect or yard
(`approach_blocked`). The door check then stands at `ground_y + 1` on the
first approach cell (`check_door`), whose floor is exactly `ground_y`.

### 5.6 Acceptance

`accept(group, road, site, read, terrain)` runs these steps in order, and
returns `accepted` or `nil, rejection`:

1. Limits: every volume within +/-31000 (`out_of_range`); reach covers the
   window (`road_short`).
2. Per plot, in order: footprint, yard and the smoothing reach outside
   `plan.bounds` (`plot_inside_town`); no overlap with earlier plots and yards, with accepted
   regions' structures and with any already accepted region's box
   (`plot_overlap`, `region_overlap`); every footprint and yard column readable
   (`plot_unloaded`, `plot_water`). A failing plot is dropped with its
   rejection.
3. `ground_y` = upper median of the natural heights under the surviving
   footprints (the element at index `floor(n / 2) + 1` of the sorted list).
4. Drop each plot with a footprint or yard column farther than the cap (2, or
   1 for a villa) from `ground_y` (`pad_cut_fill`). No recomputation of the
   median.
5. Approaches (5.5); drop failing plots.
6. Fewer than `MIN_ACCEPTED_PLOTS` survivors: reject the group
   (`group_small`).
7. `terrain.adapt` over the survivors' pads (section 7). Every footprint and yard
   column must end at `pad.y` and have a kind, else reject the group
   (`yard_not_level`).
8. Merge columns by priority `footprint > road/approach > yard > skirt`; one
   owner per column. Road and approach columns take their planned `y`. Then
   every pair of adjacent columns of the merged table where at least one changed
   must differ by at most 1 (`skirt_steep`), and every changed column must stay
   within the cap of its natural height (the cap is already guaranteed for yard
   and skirt by Living Villages, for footprint by step 4, for road/approach by
   `ROAD_CAP`).
9. Compose structures at `ground_y` (section 8) and compute the arm region box;
   reject on overlap with another arm's box (`region_overlap`).

Failures inside `accept` that mean the inputs are malformed (nil rects, an
unknown asset id, a structure that does not equal its rotated footprint) are
programming errors: `error(...)`, not a rejection.

## 6. Functions

New files: `src/outskirts.lua` (planning and orchestration),
`src/outskirts_terrain.lua` (the Living Villages adapter),
`src/outskirts_layout.lua` (pure node layout for the writer). No registry, no
plugin interface; the three files are plain `dofile`d tables like the existing
modules and are loaded from `init.lua`.

Conventions: pure functions return a value, or `nil, rejection` for an ordinary
omission (never a string), and `error(msg)` for a programming error. `read` is
an injected function; `env` is the injected engine table of `site_search`
(`emerge`, `get_node_name`, `node_info`, `after`, `log`); `rng` is the private
stream.

```lua
local outskirts = dofile(modpath .. "/src/outskirts.lua")(placement, preflight, terrain)
local terrain   = dofile(modpath .. "/src/outskirts_terrain.lua")
local layout    = dofile(modpath .. "/src/outskirts_layout.lua")
```

| Function | Purpose | Kind |
| --- | --- | --- |
| `outskirts.C` | the constants of section 2 | data |
| `outskirts.new_rng(seed) -> rng` | private stream, `rng.int(a, b)` | pure |
| `outskirts.assets(urban_entries) -> assets \| nil, message` | rural catalog + pools + merged lookup (section 9); `nil, message` when a rural file or shared id is missing | reads two Lua data files |
| `outskirts.exits(plan) -> exits` | section 3; raises on a malformed plan | pure |
| `outskirts.order_exits(exits, seed) -> exits` | rotated trial order | pure |
| `outskirts.road_volume(exit, ground_y) -> {min, max}` | lane columns `k = 1..ROAD_MAX_LENGTH` grown by one node, Y window `ground_y - SCAN_DOWN .. ground_y + SCAN_UP + 1` | pure |
| `outskirts.make_reader(class_at, top, bottom) -> read` | `read(x, z) -> y \| nil, why` with `why` in `"water"`, `"unknown"`, `"none"`; `placement.scan_column` semantics (topmost solid ground; vegetation and leaves are not ground); any liquid or ice rejects (no landfill in outskirts) | pure over `class_at(x, y, z)` |
| `outskirts.plan_road(exit, ground_y, read) -> road \| nil, rejection` | 5.4; `nil, road_*` when `reach` would be 0 | pure given `read` |
| `outskirts.candidate(exit, attempt, assets, rng, kind) -> group \| nil, rejection` | 5.2 (candidate generation) | pure |
| `outskirts.read_volume(group, exit, ground_y) -> {min, max}` | pads' bbox grown by `TERRAIN_MARGIN + TERRAIN_RADIUS`, union the lane columns `k = 1..window.k2`, Y window as above | pure |
| `outskirts.plan_approach(plot, structure, road, ground_y) -> approach \| nil, rejection` | 5.5 (route planning) | pure |
| `outskirts.accept(group, road, site, read, terrain) -> accepted \| nil, rejection` | 5.6 (candidate acceptance); `accepted = {group, approaches, columns, structures, bounds}`; `site = {plan, ground_y, entries}` | pure given `read`; calls `terrain.adapt` |
| `outskirts.assemble(exits, order, roads, accepted, rejections, site, C) -> outskirts_result` | builds regions per arm, trims `road.length`, computes bounds and volumes | pure |
| `outskirts.validate(out, site) -> true \| nil, message` | structural and geometric invariants (no overlaps, inside regions, outside `plan.bounds`, caps respected, `out.seed`/`center` match); a failure is a programming error | pure |
| `outskirts.search(result, opts, done, env)` | orchestration, section 10; calls `done(out)` or `done(nil, message, "outskirts_error")` exactly once; never writes | reads (emerge + `get_node_name`) |
| `terrain.load(dofile) -> adapter \| nil, message` | loads `living_villages/village_smoothing.lua`; `nil, message` is a dependency failure | file read |
| `terrain.pad(plot, ground_y) -> pad` | plot to pad record | pure |
| `terrain.adapt(pads, read, cap) -> adaptation \| nil, rejection` | read-only terrain adaptation (section 7): `adaptation = {bbox, columns, stats}` | pure given `read` |
| `layout.new(region, opts) -> L` | the node layout of one region, same shape as `town_layout`: `L.columns`, `L.column_range(x, z)`, `L.node_at(x, y, z) -> name, kind \| nil`, `L.in_area(x, z)`, `L.palette()`; `opts.surface(x, z)` and `opts.max_y = region.bounds.max.y` | pure |
| `preflight.compose_outskirts(out, entries) -> comp \| nil, message, reason` | structures at their own ground; same checks as `compose` per region | pure |
| `builder.build_town(result, opts, env)` | writes the terrain regions, then the structures (section 10) | **world-writing** |

*Terrain writing* is `builder.build_town` driving `layout.new`: it reads each
region through `env.open_region`, collects changed nodes exactly like the urban
read phase (same `is_ground`, liquid and stale-surface checks), and only after
every region and the urban area passed does it call `region.set` and
`region.commit`.

### 6.1 Pure, read-only and world-writing functions

| Function | Pure | Reads the world | Writes the world |
| --- | --- | --- | --- |
| everything in the table above except `search`, `build_town`, `terrain.load` | yes | via injected `read` only | no |
| `outskirts.search` | no | `env.emerge`, `env.get_node_name` | no (emerge only loads or generates map blocks) |
| `preflight.check` | no | schematic files, node registry | no |
| `builder.build_town` | no | `region.get` | `region.set`/`commit`, schematic placement, node setup |
| `residents.enumerate` | no | `env.get_node` | no |
| `residents.initialize` | no | yes | spawns entities, sets bed meta, mod storage |
| Living Villages `village_smoothing.targets` | **yes** | no | no |
| LV `village_smoothing.pads`, `.spread` | yes | no | no |
| LV `village_smoothing.load_area` | no | `env.load_node` | no |
| LV `village_terrain.footprint`, `.area`, `.materials`, `.is_overhang`, `.is_decor`, `.is_growth`, `.top_name`, `.is_top_half` | yes | no | no |
| LV `village_terrain.heights` | no | VoxelManip read | no |
| LV `village_fragments.structure_test`, `.scan_structures` | no | node registry, VoxelManip read | no |
| LV `village_holes.plan`, `.area` | yes | no | no |
| LV `village_smoothing.apply`, `.terraform`, `.install` | no | yes | **yes** (`swap_node`; `install` replaces `settlements.terraform`) |
| LV `village_terrain.set_column`, `.fill_below`, `.put_decor`, `.take_decor` (reads), `.emerge`, `.install` | no | yes | yes (`emerge` generates map) |
| LV `village_holes.apply`, `.run` | no | yes | **yes** |
| LV `village_fragments.clear_trees` | no | yes | **yes** |
| LV `site_planner.plan`, `.install`, `.register_command` | no | yes | install replaces `settlements.create_site_plan` |

Towns v1 calls exactly one Living Villages function: `village_smoothing.targets`.
It does not call `terraform`, `apply`, `install`, `village_holes.*`,
`clear_trees`, `scan_structures` or the village site planner (which assumes a
standalone village and must not be installed as the outskirts planner).

## 7. Terrain adaptation (Living Villages)

### 7.1 `village_smoothing.targets(pads, height_at, config)`

Read from `living_villages/village_smoothing.lua`:

- **Pads.** A list of tables with `x0, z0, x1, z1` (footprint, inclusive),
  `yx0, yz0, yx1, yz1` (yard, inclusive; `village_smoothing.pads` builds it as
  the footprint grown by `config.margin`), `y` (site ground Y), `surface`,
  `height` (not read by `targets`). Towns builds pads itself (`terrain.pad`);
  `village_smoothing.pads(plan, schematics, config)` needs a Living Villages plan
  entry list and `settlements.schematic_table` (`hwidth/hdepth/hheight`), which
  Towns does not have.
- **`height_at(x, z)`** returns the column's current terrain height, or `nil` to
  leave the column alone (water, unread). An optional second value `true`
  marks an overhang slab. Towns passes its own reader (section 7.3) and never the
  second value in v1.
- **`config`** must contain `margin`, `radius`, `cap`, `wall`. Towns passes
  `{margin = TERRAIN_MARGIN, radius = TERRAIN_RADIUS, cap = <cap>, wall =
  TERRAIN_WALL}` where `cap` is `CUT_FILL_CAP` (2) or `VILLA_CAP` (1).
- **Returns** `{x0, z0, x1, z1, at, was, pad, kind, violations, walls,
  wall_max}`. The box is every pad's footprint grown by `radius + margin` (8
  with the frozen values). `at(x, z)`, `was(x, z)`, `pad(x, z)` (index of the
  owning pad) and `kind(x, z)` are lookups that return `nil` outside the box or
  for a column without a height. `kind` is `"footprint"`, `"yard"` or
  `"skirt"`; a column has an owner only when its Euclidean distance to some
  pad's yard rect is `< radius`, so the changed skirt ends at most
  `radius - 1 + margin = 7` nodes beyond the footprint (the eighth ring only
  serves as fixed context).
- Footprint columns are set to `pad.y`; yard columns to `pad.y` clamped to
  `was +/- cap`; skirt columns are moved as little as needed to keep steps at
  most one node. Coordinates are plain node X/Z, the same as Towns.

`terrain.adapt` wraps it: build the `LV pads`, call `targets`, then emit one
`column` per owned column (`pad(x, z) ~= nil`) sorted by x then z, plus
`stats = {owned, changed, cut, fill, steepest, violations, walls}` and
`bbox = {x1 = t.x0, ...}`. It returns `nil, rejection` (`yard_not_level`) if
any footprint or yard column has no kind or does not end at `pad.y`. The
exact numbers for the worked example (807 owned columns, 0 violations, 0 walls)
are checked by the test when Living Villages is installed.

### 7.2 Actual API mismatches

None blocks the contract. Each is handled in Towns, not worked around with a
framework:

1. **No export.** `living_villages/init.lua` `dofile`s `village_smoothing.lua`
   (to call `install`) but keeps no reference; there is no global or
   `living_villages.*` table. Towns (which already depends on `living_villages`
   in `mod.conf`) loads the file itself:
   `dofile(core.get_modpath("living_villages") .. "/village_smoothing.lua")`.
   Loading evaluates `local core = minetest` and three sibling `dofile`s that
   call `core.get_modpath("living_villages")` at load time (no side effects, per
   the header, but each load makes private copies of the sibling modules).
   Headless tests need `minetest = {get_modpath = function() return <path> end}`
   during load; `tests/outskirts_contract_tests.lua` does exactly that and
   skips when the mod is not found (set `TOWNS_LIVING_VILLAGES`). If a stable
   entry point is wanted, the small explicit follow-up belongs in Living
   Villages (export the module); it is not required for v1.
2. **The config table is not merged with defaults** (`config = config or
   M.config`). Missing `radius`, `margin` or `cap` raises an arithmetic error;
   a missing `wall` raises only if a step over one node remains. Always pass all
   four fields (tested).
3. **The footprint is not capped.** A footprint column is set to `pad.y` however
   far from the terrain (tested: 50 nodes). Only yard and skirt honour `cap`.
   Acceptance therefore checks footprint columns itself (5.6 step 4).
4. **Yard columns can fall short.** A yard is clamped to `was +/- cap`, so a yard
   more than `cap` away from `pad.y` ends not level; an overhang column inside
   the yard is dropped (no kind, no target). Acceptance checks `at == pad.y` for
   every footprint and yard column (`yard_not_level`).
5. **No fixed non-pad columns.** `targets` cannot be told that road columns are
   already decided; any road column within the skirt would be treated as a
   skirt column. Towns merges road and approach columns after the call with
   higher priority and re-checks slopes (5.6 step 8).
6. **Writers are not usable.** `apply` and `terraform` write with `swap_node`
   outside Towns' preflight, region and confinement model, move decor with
   `take_decor/put_decor`, and `terraform` also clears trees and fills holes.
   Towns writes through its own `layout` and `env.open_region`. Consequence:
   plants and flowers standing on a changed surface are cleared, not moved.
7. **`height_at` semantics differ.** Living Villages feeds `targets` from
   `village_terrain.heights` (`base_y`: ground skipping trees, using
   `settlements.surface_mat` and an overhang test). Towns feeds it from
   `placement.scan_column`, the same reader class as the urban site search, and
   passes no overhang flag. Rows under a surface that are air are repaired by
   the layout's support rows (3); deeper caves are left alone.
8. **Pad `height` and `surface` are informational for `targets`.** `height` is
   unused; `surface` is only used by `apply`. Towns still fills them so the pad
   is a valid input to any later Living Villages call.

### 7.3 The Towns reader

`read(x, z) -> y | nil, why` is built by `outskirts.make_reader` over
`class_at(x, y, z)` (`placement.classify(env.get_node_name(...), env.node_info)`)
with `top = ground_y + SCAN_UP + 1` and `bottom = ground_y - SCAN_DOWN`, the
same sentinel convention as `site_search.inspection_volume`. `why` is `"water"`
(liquid or ice, which includes `lava`), `"unknown"` (ignore/unregistered node)
or `"none"` (no solid node in the window; includes a surface reaching the top
sentinel). Outskirts never landfills: any water in an owned column rejects it.

## 8. Bounds

Per region (one per arm), all inclusive:

- **X/Z box**: the union of every group's `targets` box
  (`bbox = pads grown by TERRAIN_MARGIN + TERRAIN_RADIUS`, which contains the
  yard, the skirt and one context ring) and the lane and approach columns. It
  is read in full. Only owned columns are written: those with `pad(x, z) ~= nil`
  in a `targets` result, and road and approach columns; each column has exactly
  one owner (merge priority of 5.6 step 8).
- **Y range of a column**: `at - SUPPORT_ROWS` up to the region top.
- **Region top**: `max(highest structure max.y, highest natural-or-finished
  surface in the region) + CLEAR_ABOVE`. Everything above the finished surface
  in an owned column is air up to the top, which clears trunks, canopies, plants
  and snow standing in owned columns. A tree standing partly outside the owned
  columns keeps its outside part; leaves with no trunk decay on their own
  (VoxeLibre leaf decay). `village_fragments.clear_trees` is not used (it
  writes).
- **`region.bounds`**: X/Z = the box above; Y from the lowest
  `at - SUPPORT_ROWS` to the region top. This is the exact write box (the
  builder's confinement check refuses any write outside it or outside the owned
  columns).
- **Schematic air volumes**: a structure's whole box `min..max` (including its
  air nodes: `place_schematic` rewrites the box) must lie inside
  `region.bounds`, and the schematic file must have exactly the declared size
  (preflight already checks this). Its footprint columns are `footprint` kind.
  The layout writes the terrain first and the schematic then overwrites the box,
  so the foundation rows `ground_y - ground_offset .. ground_y - 1` are filled by
  the layout and overwritten by the schematic exactly as in the urban builder.
- **`region.volume`**: `bounds` plus `CUT_FILL_MARGIN` around and below
  (`site_search.build_volume`); this is what is emerged after acceptance.
- **Inspection volume** while reading (`read_volume`, `road_volume`): the reach
  box plus the lane columns, one node wider for liquids, Y window as the
  reader's. Reads therefore cover every column that can later be owned.
- **Disjointness.** Regions of different arms must not intersect as boxes: a
  VoxelManip commit rewrites its whole area, so overlapping regions would
  restore stale data. Overlap rejects the later candidate (`region_overlap`).
  All regions also lie outside `plan.bounds`, hence outside the urban write
  box.

## 9. Rural asset isolation

- **Separate rural catalog.** Rural-only buildings (cottages, the stock farm, an
  inn variant if one is added) live in a new `schematics/outskirts/catalog.lua`
  that returns `id -> entry` with the same fields as
  `schematics/objects/catalog.lua` and the template catalog (`id, path,
  data_path, size, entrance, ground_offset, role, ...`) plus `class`. It is not
  read by `src/catalog.lua`; no rural id appears in `catalog.entries`,
  `catalog.snapshot()`, `planner.landmark_profile`, `planner.row_depth`,
  `content_planner` or the urban role pools. Their sizes cannot influence
  urban row depth, block depth or the Roman frontage.
- **Pools.** `schematics/outskirts/pools.lua` returns `class -> {id, ...}`
  (`cottage`, `farm`, `well`, `workshop`, `inn`, `chapel`, `villa`). Ids may
  reference rural-only entries or existing shared entries (`well`, `tavern`,
  `blacksmith`, `chapel`, shared cottages from the stock templates). A shared id
  must exist in `catalog.entries`; a missing one is a dependency failure.
- **Merge only for outskirts.** `outskirts.assets(urban_entries)` returns
  `{entries = merged, pools = pools}` where `merged` is a new table: the urban
  entries (same objects) plus the rural ones. A rural id equal to an urban id
  is a programming error. `merged` travels as `out.entries`. Urban
  `preflight.check` still receives `catalog.entries` only; the outskirts part
  of preflight and the builder's outskirts placement use `out.entries`, and
  node setup receives the union (urban entries plus `out.entries`) as its
  lookup. The stock catalog, the objects catalog (`oaks`, `gardens`) and their
  random streams are untouched.
- **Adding assets** (#227, #228, #229) means a rural catalog entry and a pool
  line only; no edit of `schematics/templates/catalog.lua`, `src/catalog.lua`'s
  `entries`, or any urban test fixture. The Roman villa exists as
  `schematics/imports/roman/villa.mts` but has no catalog entry; #229 gives it a
  rural-catalog entry, not an urban one.
- **Capabilities are reported, not invented.** Pools only list assets; what a
  farm can do (crops, animals) is whatever its authored contents provide.

## 10. Integration

### 10.1 Flow

```
/towns_generate
  generate_command.search(pos, seed, town_type, done)
    site_search.search(...)  -> result            -- unchanged; plans twice: the
                                                  --   origin plan for inspection and
                                                  --   the accepted-centre plan for the build
    outskirts.search(result, opts, cb, env)       -- NEW; read-only
         cb(out)  -> result.outskirts = out; done(result, nil, details)
         cb(nil, msg, "outskirts_error") -> done(nil, msg, ...)       -- programming error
  generate_command.build(result)
    preflight.check({... outskirts = result.outskirts})   -- urban unchanged, then outskirts
    builder.build_town(result, {entries = catalog.entries}, env)
    residents.enumerate(summary.town.structures, ...)     -- unchanged call, combined list
    residents.initialize(rep.beds, ...)                   -- unchanged
```

`generate_command.search` is the only integration point of the planning half:
`site_search` itself, `planner.plan`, `generate.lua`'s controller and the urban
`result` fields (`plan`, `center`, `ground_y`, `heights`, `build_bounds`,
`build_volume`, `structures`, `wet`) are unchanged. `result.outskirts` is an
additional field. Outskirts are planned from `result.plan` (the accepted-centre
plan), never from the origin plan; because the plan only translates with the
centre, `outskirts.exits` gives the same offsets from the centre either way, but
the accepted-centre plan is the one `same_footprint` verified.

### 10.2 `outskirts.search(result, opts, done, env)`

`opts = {assets = <outskirts.assets(...)>, terrain = <adapter>}` (both supplied
by `generate_command`; tests pass fakes). Steps, all reads:

1. `terrain.load` / `assets` failed: `done({status = "unavailable", reason = ...,
   version = 1, ...empty lists})`.
2. `exits = outskirts.exits(plan)`; none: `done` with `status = "empty"` and
   rejection `no_exits`.
3. For each exit in trial order: emerge `road_volume`; `read` the lane;
   `plan_road`; for each attempt, `candidate`; `road_short` if the reach does
   not cover the window; emerge `read_volume`; `accept`. Every `emerge` follows
   the `site_search` pattern (`emerge(min, max, cb)`, watchdog with
   `EMERGE_TIMEOUT`, failure becomes an `emerge_failed` rejection, three
   consecutive timeouts stop the outskirts, not the town).
4. Landmark pass (villas or chapel).
5. `assemble`, emerge each `region.volume`, `validate`, `done(out)`.

It is wrapped in `pcall`; any raised error becomes
`done(nil, "internal error in outskirts: ...", "outskirts_error")`.

### 10.3 Preflight

`preflight.check(params, env)` gains `params.outskirts` (optional). The urban
checks are unchanged and decide the result as today. For the outskirts part:

- `preflight.compose_outskirts(out, entries)` resolves each accepted structure
  at its own `group.ground_y` (not the urban `ground_y`): rect equals the
  rotated footprint, box inside its region, no overlap with any other structure
  (urban or outskirts), nothing inside `plan.bounds`.
- Files, sizes and node registrations are checked once per id over the
  outskirts ids (with `out.entries`), merged with the urban list into
  `report.files`/`report.nodes`.
- `report.outskirts = {structures, regions, files, nodes}` on success.

Failures split by cause: geometry/overlap/bounds errors are programming errors
(`inspection_failed`, reason `outskirts_invalid`, whole command stops, nothing
written); a missing rural file, a size mismatch or an unregistered node used
only by rural assets is a dependency failure of the optional layer: the report
carries `report.outskirts = {dropped = {reason, message}}`, `generate_command`
sets `result.outskirts = nil` and the urban build proceeds.

### 10.4 Builder and node setup

`builder.build_town(result, opts, env)` is unchanged when `result.outskirts` is
nil. Otherwise:

1. `check_result` is unchanged for the urban fields; `builder.check_outskirts`
   validates the outskirts result (version, seed/center match, regions).
2. The urban `prepare_town` composes the **urban** plan at `result.ground_y`
   exactly as today; it is not asked to compose the outskirts, so nothing is
   recomposed at the urban ground height.
3. Read phase: the urban area, then every region (`env.open_region` over the
   region's `bounds`, one node wider for the liquid read), including the
   stale-surface check that every owned column's `was` row is still solid
   ground and that no liquid stands above it. Any failure is
   `inspection_failed` before the first write (no partial drop of one region in
   v1).
4. Write phase: urban commit, then each region commit, then schematics in this
   order: urban structures (compose order), then outskirts structures (region
   order, then group, then plot).
5. Door checks: `check_door(b, b.site_ground_y or result.ground_y, node)`.
6. `env.setup_nodes(combined, entries)` with `combined = urban structures ++
   outskirts structures` and `entries` the union lookup; `node_setup` keys
   placements by `id@min`, so the combined list is safe.
7. The summary gains `summary.outskirts = {status, groups, ordinary, landmarks,
   regions = {{id, bounds}}, columns, structures, rejections = counts}` and
   `summary.town.structures` is the **combined** list, so `generate_command`'s
   existing `residents.enumerate(summary.town.structures, ...)` and
   `residents.initialize` run unchanged and enumerate outskirts beds.
   `by_structure` entries carry `kind = "outskirts"` for reporting.

### 10.5 Failure shapes

- `inspection_failed`: nothing written (urban or outskirts).
- `write_failed`: as today, with `extra.bounds` the urban box (unchanged
  meaning) and `extra.regions = {urban box, region boxes...}` listing every box
  that may be partially written; `extra.outskirts = {planned, placed}` when the
  failure occurred in the outskirts part. No rollback; no resident
  initialization (`build_town` returned nil).

## 11. Outcome classes

| Class | Examples | Where | Result |
| --- | --- | --- | --- |
| **Omission** | any code of 5.1: water, steep, overlap, short road, too few plots, emerge failure of an optional volume | `nil, rejection` from pure functions; collected in `out.rejections`/`counts.rejected` | Never an error. Fewer or no groups. `status = "empty"` if none. Urban town builds. Logged at `action`, summarized in the report. |
| **Dependency failure** | `living_villages` smoothing module missing or without `targets`; rural catalog or pool file missing; shared id absent; rural schematic missing, wrong size or unregistered node (found in preflight) | `terrain.load`, `outskirts.assets`, preflight outskirts part | Outskirts skipped (`status = "unavailable"` with `reason`, or `report.outskirts.dropped`). Urban town builds. Reported as a warning with the reason. |
| **Programming error** | malformed plan or record, `validate` failure, structure not equal to its rotated footprint, overlapping or out-of-box structures, rural/urban id collision, fill deeper than `SUPPORT_ROWS` | `error(...)`, `pcall` in `search`, preflight `outskirts_invalid`, builder check | Whole command stops before any write: `done(nil, message, "outskirts_error")` or `inspection_failed`. Reported as an error so the defect is seen. |
| **Post-write failure** | engine error while committing a region, `place_structure` failure, unreachable door, node setup failure | `builder.build_town` after the first write | `write_failed` with attempted boxes, as today; partial world; no retry, no residents. |

An unexpected change in the world between planning and the builder read phase
(stale surface, liquid above the surface) is an `inspection_failed`
(zero writes), not an omission, because the urban part would otherwise commit
with a half-reported outskirts layer.

## 12. Worked example

Fixture: `tests/outskirts_fixture.lua`. Everything below is checked by
`tests/outskirts_contract_tests.lua`.

**Town.** Roman, seed 8, centre `(1000, -2000)`, urban `ground_y = 62`.
`plan.bounds` is `x 905..1085, z -2086..-1915` (the Roman bounds `x -95..85,
z -86..85` translated), a single boundary rect.

**Exits.** North `e1`: street 1 (`cardo_north`, `x 997..1002`), `via
arch_north` (`z -1926..-1919`), four free margin nodes `z -1918..-1915`, so
`join = (999, -1915)`, `start = (999, -1914)`, `lane x 998..1000`. East `e2`
start `(1086, -2001)`, south `e3` `(999, -2087)`, west `e4` `(904, -2001)`. Trial
order for seed 8 is `e1, e2, e3, e4` (8 % 4 + 1 = 1).

**Terrain.** `natural(x, z) = 64 + floor((z + 1919) / 6) + (x > 1000 and 1 or 0)`:
a hill rising one node per six nodes northward, one node higher east of the
road.

**Road (e1).** Joined to ground 62. Natural heights of lane columns `k = 1..14`:
`64 65 65 65 65 65 65 66 66 66 66 66 66 67`. Finished `y`: `63 64 65 65 65 65
65 66 66 66 66 66 66 67`. The join clamps the first two columns by one node
(`62 -> 63` against natural 64, `63 -> 64` against 65): `y[1] ~= natural[1]`.
`reach = 33` (covers the window), built `length = 14` = the farthest
approach column plus one.

**Group `g1`.** Attempt 1 (both sides), slot 1, `window k = 10..33`. The
candidate listed six cottages, `g1p1..g1p3` west and `g1p4..g1p6` east; only the
first of each side passed (`g1p2` for example failed `plot_water`).

The cottage asset is **illustrative** (no cottage exists in any catalog until
#227): `size {x = 7, y = 7, z = 8}`, `entrance {x = 3, y = 2, z = 0}`,
`ground_offset = 1`.

| | `g1p1` (west) | `g1p4` (east) |
| --- | --- | --- |
| rotation | 270 (door faces +X) | 90 (door faces -X) |
| rect | x 987..994, z -1905..-1899 (8 x 7) | x 1004..1011, z -1905..-1899 |
| entrance node | (994, **68**, -1902) | (1004, **68**, -1902) |
| node outside the door | (995, 68, -1902) | (1003, 68, -1902) |
| pad yard | x 985..996, z -1907..-1897 | x 1002..1013, z -1907..-1897 |
| natural under footprint | 66 (4 rows), 67 (3 rows) | 67 (4 rows), 68 (3 rows) |

`group.ground_y = 67`: the upper median of the 112 footprint heights (32 at 66,
56 at 67, 24 at 68). **Three Ys:** schematic origin Y `67 - 1 = 66`, site ground Y
`67`, entrance feet Y `66 + 2 = 68 = 67 + 1`. Structure boxes are
`y 66..72`. Fill/cut: `g1p1` fills 1 node over 32 footprint columns, `g1p4` cuts
1 node over 24 (cap 2).

**Approaches.** From `(995, -1902)` east and `(1003, -1902)` west, 3 cells long,
3 wide (`z -1903..-1901`). The road attaches at column `k = -1902 - (-1914) + 1
= 13`, finished 66, so `delta = 66 - 67 = -1`: approach heights `67, 66, 66`
(first cell at the group ground, last at the road). The door check later stands
at `ground_y + 1 = 68` on the first cell and walks to the entrance node.

**Terrain targets (Living Villages).** `targets({pad1, pad2}, natural, {margin 2,
radius 6, cap 2, wall 4})`: box `x 979..1019, z -1913..-1891`, 807 owned columns,
0 violations, 0 walls.

| kind | columns | changed | cut | fill |
| --- | --- | --- | --- | --- |
| footprint `g1p1` | 56 | 32 | 0 | 32 |
| footprint `g1p4` | 56 | 24 | 24 | 0 |
| yard `g1p1` | 76 | 40 | 0 | 40 |
| yard `g1p4` | 76 | 36 | 36 | 0 |
| skirt `g1p1` | 282 | 12 | 0 | 12 |
| skirt `g1p4` | 261 | 0 | 0 | 0 |

Every footprint and yard column ends at 67. Samples: footprint `(990, -1902)`
was 66, at 67; footprint `(1008, -1899)` was 68, at 67; yard `(985, -1907)` was
66, at 67; skirt `(980, -1902)` was 66, at 66; road `(999, -1901)` (k = 14) was
67, at 67; approach `(996, -1902)` was 66, at 66. The merge then lets road and
approach columns override the skirt/yard columns they overlap (the skirt of
`g1p1` reaches `x 1001`).

**Region `r1`.** Owned X/Z = targets box union the lane: `x 979..1019, z
-1914..-1891`. Lowest finished surface 63 (road column 1), minus `SUPPORT_ROWS`
= 60. Region top: `max(72, 69) + CLEAR_ABOVE = 84`. `bounds y 60..84`; `volume
= x 971..1027, y 52..84, z -1922..-1883`. The region lies entirely outside
`plan.bounds` (north edge `z = -1915`).

**Rejections** (the rest of the story): `g1p2` `plot_water`; `e2` `road_water`
(the east road reaches only 4 columns) and `e2:a1` `road_short`; `e3:a1`
`pad_cut_fill`. After `e1` accepted a group and `e2`, `e3` produced nothing, `e4`
is tried within `GROUP_EVALS`; the result may legitimately hold one group.

## 13. Dependency map

```
#226 contract (this)
 |
 +-- #227 cottages ----\                    (rural catalog entries + pool lines)
 +-- #228 farm ---------+--> pools (data) --> #235 content policy
 +-- #229 villa --------/                          |
 |                                                  v
 +-- #231 terrain adapter  (outskirts_terrain)      |
 |       |                                          |
 |       +--> #234 acceptance (outskirts.accept) <--+
 |                  ^           ^
 +-- #232 candidates (exits, new_rng, candidate, order_exits)
 |                  |
 +-- #233 roads (plan_road, plan_approach, make_reader) -- feeds #234
 |
 +-- #236 build (outskirts_layout, preflight.compose_outskirts,
 |                builder changes)  <-- needs the result shape (4) and #234
 |
 +-- #237 integration (outskirts.search, assemble, validate, generate_command,
 |                preflight params, residents flow)  <-- #232-#236
 |
 +-- #238 report (generate.lua formatting) + gameplay validation  <-- #237
```

| Ticket | Files and functions | Depends on |
| --- | --- | --- |
| #227, #228, #229 | `schematics/outskirts/catalog.lua`, `schematics/outskirts/pools.lua`; imports only | this contract |
| #231 | `src/outskirts_terrain.lua`: `load`, `pad`, `adapt` | this contract; Living Villages installed |
| #232 | `src/outskirts.lua`: `C`, `new_rng`, `assets`, `exits`, `order_exits`, `candidate`, `read_volume`, `road_volume` | contract; pools may start with cottages only |
| #233 | `make_reader`, `plan_road`, `plan_approach` | #232 records |
| #234 | `accept` (+ merge, slope check) | #231, #232, #233 |
| #235 | pool content and policy: class frequencies, farm/inn/well/workshop, villa and chapel eligibility | #227-#229, #232 |
| #236 | `src/outskirts_layout.lua`, `preflight.compose_outskirts`, builder changes | #234 record shapes |
| #237 | `outskirts.assemble`, `validate`, `search`, `generate_command` wiring, preflight `params.outskirts` | #232-#236 |
| #238 | report text, gameplay checks | #237 |

Ordering note: the epic lists content selection (#235) after acceptance (#234),
but `candidate` must know real footprints because `plot.rect` has to equal the
rotated footprint, and `accept` reads terrain for exactly those rects. So #232
takes the asset pools as an argument and ships with a minimal pool (cottages),
and #235 refines the pools and selection policy without changing any signature.

## 14. Open questions

1. **Programming errors stop the whole command (chosen).** Everything else about
   the optional layer degrades gracefully, but a violated invariant in the
   outskirts planner aborts before any write so the defect cannot hide behind a
   "no outskirts" town. The alternative is to log and skip the outskirts; say so
   if you prefer a town over a noisy failure.
2. **Living Villages entry point.** v1 loads `village_smoothing.lua` by path
   (section 7.2, mismatch 1). A one-line export in Living Villages would be a
   cleaner, stable seam; it is a follow-up in that repository, not part of this
   work.
3. **Plants on changed ground are cleared, not moved** (writer is Towns' own,
   not Living Villages' `apply`). Moving decor like Living Villages does is a
   possible later refinement of `outskirts_layout`.
4. **Tree fragments** at the edge of owned columns are left (section 8). If
   playtesting shows floating canopy or stumps, a small follow-up can enlarge
   the owned ring or reuse `clear_trees` read-only logic; not planned for v1.
5. **Villa and chapel window size.** The villa has no catalog entry yet (#229)
   and the chapel is 9 x 17; their along-road extent may exceed
   `GROUP_WINDOW`. The contract widens the window up to `ROAD_MAX_LENGTH`; #229
   and #235 confirm that is enough.
6. **One village group per exit, two groups in total.** Roman towns (four exits)
   and medieval towns (two) both fit. A second group on the same exit would
   need a different `SLOTS_PER_EXIT` policy.
7. **Lane alignment.** On a six-wide street the three-wide lane sits one node
   inside the lower edge (half a node off-centre). Cosmetic; changing it later
   only alters `inset`.
8. **Roman arch opening** is not modelled; the lane assumes the opening covers
   the street's cross range (true for the current 12-wide arch). A narrower arch
   would make the exit rule report the end as blocked, which is safe.
