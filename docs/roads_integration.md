# Roads integration API (`towns_api`)

Towns publishes a small, versioned, read-only API so an optional consumer
(the Roads mod) can find completed automatic settlements and their verified
road exits, avoid Towns-built land, and avoid writing terrain while Towns is
writing. Issue #458. Towns generates no roads and never depends on Roads;
Roads lists `towns` in `optional_depends`.

The API is the global table `towns_api`, defined at the end of Towns' `init.lua`
(`src/towns_api.lua`). Roads must not read Towns mod storage or the internal
`towns` table. Every function returns fresh tables (deep copies), integer
coordinates, and a deterministic order. Functions are plain functions, not
methods: call `towns_api.settlements(pos, r)`.

## Version policy

`towns_api.version` is an integer, currently `1`. Within one version, fields
are only added, never removed or retyped; consumers ignore unknown fields.
A breaking change increments `version`; consumers check it and treat a higher
number as unsupported. Published data carries its own `format` (currently `1`)
inside Towns storage; consumers never see it.

## Functions

### `towns_api.available()` -> `true` | `false, reason`

True when the automatic-town record registry loaded and is healthy. When
false (for example the stored records were malformed) every other query
function except `writer()` fails with code `"unavailable"`; Roads should not
treat that as "no towns here" and should not write near unexplored land.

### `towns_api.settlements(pos, radius)` -> `list` | `nil, reason, code`

Completed, published settlements whose centre is within `radius` nodes
(horizontal distance) of `pos = {x, z}` (`y` ignored). `radius` is a number
from 0 to 1024. At most 32 are returned, sorted by distance to `pos`, then by
`id`. Codes: `invalid_position`, `invalid_radius`, `unavailable`.

Only settlements in state `complete` with valid published data are listed.
Candidates, building, interrupted, unsupported and invalid settlements are
never listed.

### `towns_api.settlement(id)` -> `settlement` | `nil, status, message`

One settlement by id. `status` is one of:

- `not_found`: no such record (including any malformed id).
- `incomplete`: the record exists but is `building` or `interrupted`.
- `unsupported`: complete, but without published exit data (see below).
- `invalid`: complete, but its stored published data was malformed and has been
  discarded.
- `unavailable`: the registry is not healthy.

### `towns_api.exclusions(rect)` -> `list` | `nil, reason, code`

`rect = {x1, z1, x2, z2}` (inclusive, integers, each side at most 2048 nodes).
Returns the areas Roads must not write into that intersect `rect`, sorted by
`kind` then `id`. More than 256 items returns `nil, reason, "too_many"`:
query a smaller rect. Codes: `invalid_rect`, `too_many`, `unavailable`.

Item: `{id, kind, state, rects = {{x1,z1,x2,z2}...}, y_min, y_max}`. A rect is
listed when any of its `rects` overlaps the query; `y_min`/`y_max` bound all of
the item's rects vertically.

- `kind = "settlement"`, `id` = the settlement id.
  - Complete with published data: `rects` = the town `core` plus the
    `structures` rects (what Towns actually built). The rest of the
    reservation (the outskirts belt Towns owns but did not build on) is not an
    exclusion: roads may cross it.
  - Any other state (building, interrupted, or complete without published
    data): `rects` = one rect, the whole reservation envelope, because Towns may
    have written (or may be about to write) anywhere inside it.
  - `state` is the record state: `building`, `interrupted` or `complete`.
- `kind = "candidate"`, `id` = the automatic site id: a site contacted or being
  inspected in this session that Towns may yet build. `rects` = its maximum
  envelope; `y_min`/`y_max` are `-31000`/`31000` (unbounded vertically).
  `state` is `contacted` or `inspecting`. Candidates exist only in memory for
  the current session and disappear when declined.

### `towns_api.writer()` -> `nil` | `{kind, phase, since}`

`nil` when no Towns terrain writer is active. Otherwise `kind` is `"automatic"`
(a first-touch cell job) or `"manual"` (`/towns_generate`), `phase` is the lock
phase (`"search"`, `"loading"` or `"build"`) and `since` is the time the
operation started (seconds on a monotonic clock; compare only with other
`since` values, not with `core.get_gametime()`).

## Shapes

### Settlement

```
{
  id          = "auto:<cx>:<cz>",   -- the automatic cell key of the record
  site_id     = "...",              -- the auto_sites id; informational, may be absent
  state       = "complete",
  town_type   = "medieval" | "roman",
  center      = {x, y, z},          -- y is the town ground level
  reservation = {min = {x,y,z}, max = {x,y,z}},   -- everything Towns owns (read envelope)
  core        = {x1, z1, x2, z2},   -- town plan bounds widened by the wall line (1 node)
  structures  = {{x1,z1,x2,z2}...}, -- outskirts structures/terraform and wall features
                                    --   outside the core, sorted, at most 128
  exits       = {exit...},          -- sorted by id, at most 32
}
```

`id` is stable for the life of the world: it is derived from the persistent
record's cell. `site_id` is not a stable key (candidate ids change when the
site lattice version changes); do not use it for identity. If more than 128
outside rects exist, Towns publishes one rect: their union (only ever more
protective).

### Exit

```
{
  id        = "+x:<x>:<z>",   -- direction label and first column, see below
  source    = "street" | "wall_gatehouse" | "wall_postern" | "wall_opening",
  direction = {x, z},         -- outward unit vector: one of (1,0) (-1,0) (0,1) (0,-1)
  columns   = {{x, z}...},    -- the n = 0 cells, 1 to 4 of them (2 or 4 in practice), sorted
                              --   by transverse position
  length    = L,              -- 4 to 16 steps built
  profile   = {{y, name, param2}...},   -- one entry per step n = 0 .. L-1
}
```

The full exit id is `settlement_id .. "/" .. exit.id`. The exit `id` is the
direction label (`+x`, `-x`, `+z`, `-z`) followed by the x and z of the
column with the lowest transverse coordinate (z for east/west roads, x for
north/south), so it depends only on the built geometry, not on build or
iteration order.

Geometry. Column `c` at step `n` is the node
`(c.x + direction.x * n, profile[n + 1].y, c.z + direction.z * n)`. The
profile is the same for every column: `y`, node `name` and `param2` of the road
surface node at that step. The **landing** is step `L - 1` (the last built
node); the **connector seam** is step `L`, the first node beyond it, which is
the natural terrain surface the ramp meets. Roads is responsible for
everything from step `L` outward. A flat exit is all
`mcl_core:cobble`, `param2 = 0`, the same `y`; a graded exit uses
`mcl_stairs:stair_cobble` (with a facedir `param2`), `mcl_stairs:slab_cobble`
and `mcl_core:cobble` to follow the terrain. Towns guarantees these nodes were
read back from the world and matched when the town completed; Roads should
still check what it needs at write time.

`source` records provenance: `street` (an unwalled town's street ramp),
`wall_gatehouse` and `wall_postern` (an outside approach of a placed gatehouse
or postern feature), `wall_opening` (a bare wall opening graded like a street).
Planned openings from the planner are not exits: an exit exists only after its
nodes were written and verified.

## Lifecycle and the publish rule

1. Before the first write Towns saves a `building` record (reservation).
2. During the build, each approach that was graded and written is recorded as
   an *unverified* candidate in memory only.
3. After the town is built and populated, Towns re-reads every column and step
   of every candidate with `core.get_node` and keeps an exit only if every node
   matches `name` and `param2`. A mismatch or an unloaded node omits the exit
   and logs the reason. If verification itself fails, the town is published
   with no exits.
4. The record changes `building` -> `complete` **and** stores the published
   data in one save. Only then does `settlements()` list it. If the save fails
   the record stays `building` in memory and on disk; nothing is published.
5. A restart converts any `building` record to `interrupted`; interrupted
   records are never published, and a published record can never be changed.
   An interrupted or failed town is an exclusion over its whole reservation,
   forever.

Published data is limited to 32 exits (the rest are recorded as omitted),
128 outside rects and 32 omission entries. Omitted exits are not exposed
through the API; they are logged by Towns.

## Unsupported settlements (no backfill)

Only automatic settlements completed by a Towns version with this API have
published data. Towns never reconstructs exits from a centre, seed or by
scanning for cobblestone. The following are *unsupported destinations*:

- towns built by `/towns_generate` (manual towns: never recorded);
- automatic towns completed before this feature (a `complete` record without
  published data);
- automatic towns whose stored published data is malformed (reported
  `invalid`; the data is dropped and logged, and the registry keeps working).

Unsupported records are still reservations: `exclusions()` reports their whole
reservation envelope, so Roads never writes over them, but they are never
returned by `settlements()` and `settlement(id)` reports `unsupported`.
Manual towns are not recorded at all; `writer()` is the only protection while
one is being built.

**Downgrade.** The storage key is unchanged (`towns.auto_records.v1`); the new
fields are optional. An older Towns that reads this data ignores them (and
drops them if it rewrites the records), leaving complete records that this
version treats as unsupported. No other behaviour changes.

## Writer coordination

Roads emerging terrain can itself trigger Towns generation: Towns starts a
cell job from `on_generated` when a chunk first touches a site's activation
area, then loads and builds asynchronously. "Emerge finished" is therefore not
a safe point to write. Towns provides these guarantees:

- **G1.** Towns writes only into freshly generated chunks that are recorded in a
  live cell and lie inside the candidate's maximum envelope (`max_rect`).
  Terrain Roads has already generated is never a Towns write target, and any
  land that could still become one is reported by `exclusions()` as a
  `candidate` (or, once accepted, a `settlement`).
- **G2.** `writer()` is non-nil for the entire span of every Towns write,
  automatic or manual, from before the first write until after the last
  (including population, finalization and the cosmetic Roman aqueduct).
- **G3.** A cell triggered by a newly generated chunk either declines or takes
  the generation lock synchronously inside `on_generated`, before the emerge
  callback of that chunk reaches Roads. So when Roads' callback runs,
  `writer()` and `exclusions()` already show any job or candidate the new
  terrain caused.
- **G4.** Towns never calls into, waits for, or holds a lock on behalf of
  Roads. Every Towns job is ended by Towns' own timers (the emerge watchdogs
  fail a job whose terrain never arrives), so a stuck or slow Roads job cannot
  deadlock Towns and a stuck Towns job ends by itself.

Towns offers no lock for Roads to hold and no `claim(rect)`; a claim API is
deferred. Roads is protected from Towns only by G1 and by the procedure below.

### Recommended Roads procedure

1. Emerge the area for a slice of the road.
2. Poll `towns_api.writer()` with `core.after` until it returns `nil`, with a
   time limit (suggested 180 s). On timeout, abandon the slice and report
   `towns_busy`; do not write.
3. Query `towns_api.exclusions(rect)` for the slice's rect.
4. In the same callback that writes the slice, check that `writer()` is `nil`
   and that no returned exclusion overlaps the slice (honouring `y_min`/`y_max`
   if it works vertically). Otherwise defer again.
5. Never hold the road job across `writer()` being non-nil by looping; always
   yield with `core.after`.

Steps 3 and 4 repeat per slice: a slice written later can see a settlement that
completed after an earlier slice was checked.

## Coverage, bounds and caps (summary)

| Item | Bound |
| --- | --- |
| `settlements` radius | 0 .. 1024 nodes; 32 results |
| `exclusions` rect side | 2048 nodes; 256 items (else `too_many`) |
| exits per settlement | 32 |
| structure rects per settlement | 128 (collapsed to their union above that) |
| exit columns / length | 1..4 columns, 4..16 steps |
| omission entries | 32 |

## Tests and demonstration

`lua5.1 tests/run.lua` covers the pure modules (`town_exits`, `auto_records`,
`towns_api`) and the coordination cases in `tests/automatic_integration_tests.lua`.
`tools/roads_api_demo/` runs the API in a scratch world against an actual
automatically generated settlement (see its README).
