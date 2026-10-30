# City margin smoothing — issue 256

Design and implementation-ticket brief, 2026-10-25. Source baseline: Towns
`c668908`, Living Villages `b0a5387`. This document records research and proposed
interfaces; it does not describe implemented behavior. Parent:
[Towns #256](https://github.com/tbook/luanti-towns/issues/256).

## 1. Agreed behavior

- Soften artificial cliffs around the city. A rise of one node per horizontal
  node (1:1) is a goal, not a universal acceptance requirement.
- Follow the actual flattened boundary, `plan.boundary.rects`, at the existing
  `result.ground_y`. Do not add a flat strip outside the city.
- Use a 20-node transition radius and at most 20 nodes of surface-height change
  per exterior column. Leave difficult cliffs partly softened.
- Preserve the town itself. Leave water and existing structures alone, accepting
  gaps in smoothing. Keep the current city elevation and site-selection rules.
- Build the city, attempt margin smoothing, then **plan** suburban plots from the
  resulting world. Farms may subsequently terraform those margins again.
- Margin failures, including partial writes, are warnings. Continue suburban
  work using the actual terrain. No rollback or automatic smoothing retry.
- No elevation optimization, guaranteed perimeter access, retaining walls,
  stairs, farm-distance retuning, or simulated future terrain in this change.

Terminology: “suburban work” below is the existing `outskirts` pipeline, including
farms, huts, villas, and chapels. This feature initially belongs to
`/towns_generate`, for both town types, not the low-level builder independently.

## 2. What the code already provides

Paths in this section are relative to this repository unless prefixed with
`../living_villages/`.

| Source | Relevant behavior |
| --- | --- |
| `src/town_layout.lua`, `src/builder.lua` | Flatten only the union of boundary rectangles, then pave and place structures. The urban builder is synchronous. |
| `src/medieval_planner.lua` | Boundary is the union of the core, cathedral, and castle rectangles. |
| `src/roman_planner.lua` | Boundary is one rectangle. |
| `src/site_search.lua` | Read-only urban search. Chooses median ground, raised to surrounding water when necessary; cut/fill can reach 24 nodes. Accepted result includes urban heights and build/emerge bounds. |
| `src/generate_command.lua` | Currently searches urban and rural sites before writes, preflights both, builds the town, applies rural terrain/structures, then initializes residents. |
| `src/generate.lua` | Controller expects synchronous `deps.build(result)`. It currently releases its busy lock before invoking build. That is unsuitable for a build with asynchronous stages. |
| `src/outskirts.lua` | Existing asynchronous, read-only plot search. Reads real map nodes; rejects water and footprint spread over four nodes. No change to its sampling algorithm is needed. |
| `src/outskirts_terrain.lua` | Maps individual rural plots to Living Villages' schematic-based terrain API. Protects the urban **bounding rectangle plus six nodes**. Keep that rural contract unchanged. |
| `src/outskirts_build.lua` | Terraforms surviving plots first, then places structures. Existing declines/incomplete terrain omit individual plots. |
| `../living_villages/init.lua` | Exposes `living_villages.terrain.volume`, `terraform`, `pads`, `targets`, `structure_test`; supplies default tree/structure helpers. |
| `../living_villages/village_smoothing.lua` | Pure pad/height-grid slope solver; engine pipeline for load checks, trees, heights, structures, writes, then hole filling. Defaults: yard 2, radius 8, movement cap 5. |
| `../living_villages/village_terrain.lua` | VoxelManip height reader; surface/fill materials; plant and snow movement; column cuts/fills and support. |
| `../living_villages/village_fragments.lua` | Structure scan and whole-tree/fragment cleanup. Tree cleanup writes through its own VoxelManip, not `swap_node`. |
| `../living_villages/village_holes.lua` | Separate raise-only depression filling and cliff ramps, with independent reach, movement limits, and budgets. Omit this stage for city margins. |
| `tools/place_check/` | Disposable engine validation, currently assuming synchronous populated builds and a largely superflat world. Must be updated for callbacks; needs additional margin scenarios. |

The existing public API is documented in
`../living_villages/docs/terrain-api.md`. It is available after mods load. Public
terraform never falls back to VoxeLibre's original terraformer. The volume query
does not emerge terrain; callers must emerge and wait first.

### Why not just call today's terraform with a city-sized fake schematic?

It is possible to construct synthetic schematic records, but that does not solve
the important semantics:

1. After buildings are placed, a general height scan can see roofs, walls, and
   paving. Interior slope constraints must use the city's known ground height.
2. Protected columns in `targets` are fixed but are not marked as hard pad
   constraints. A large difference can be ignored rather than partly softened.
3. Unprotected footprints are hard constraints, but `apply` also fills under
   unchanged footprints. City interiors must never enter that write path.
4. Today's terraform always runs hole filling. This adds work and changes beyond
   the intended margin operation; its separate ramp rules also complicate the
   20-node movement limit.
5. Tree clearing uses expanded rectangular zones, and can continue beyond them.
   A `swap_node` wrapper alone cannot confine its VoxelManip writes.

Recommendation: add two narrow boundary functions in Living Villages. Reuse its
solver and terrain/tree helpers; keep existing village and farm behavior intact.
Do not copy the solver into Towns or expand the existing schematic API with a
collection of city-specific flags.

## 3. Research probe

A Lua 5.1 probe called the existing `smoothing.targets` with zero yard,
radius 20, cap 20, and an explicit interior ground-height lookup. Rectangular
cases used x=0..180, z=0..170; the irregular case used three adjoining rectangles.
The probe asserted no interior target-height changes and movement <=20.

| Case | Changed exterior columns | Largest movement | Counted steps over one | Pure planning time |
| --- | ---: | ---: | ---: | ---: |
| Town y=20, countryside y=8 | 7,964 | 11 | 0 | 0.080 s |
| Town y=8, countryside y=20 | 7,964 | 11 | 0 | 0.081 s |
| Town y=35, countryside y=5 | 14,544 | 20 | 1,416 | 0.153 s |
| Same 30-node cliff, town passed as protected instead of hard footprint | 0 | 0 | 0 | 0.072 s |
| Irregular union, town y=20, countryside y=8 | 6,600 | 11 | 0 | 0.073 s |

The zero violations in the protected case is misleading: existing diagnostics
count only pairs where a target changes, so doing nothing reports zero. Use the
hard-footprint interpretation and inspect actual edge changes in tests. These
measurements establish solver reuse, not engine runtime, write safety, or final
visual quality. No production code or engine worlds were changed for this probe.

Reproduce from Towns with
`lua5.1 tools/issue256_margin_probe.lua` (optional argument: Living Villages path).
This is a research tool, not a replacement for the implementation tests below.

## 4. Proposed Living Villages contract

Names below are the proposed ticket contract. Settle changes in the LV tickets
before dependent Towns implementation; agents should not invent alternate APIs.

```lua
local boundary = {
  {x0 = 0, z0 = 0, x1 = 120, z1 = 100},
  -- Inclusive world X/Z rectangles; overlap is allowed.
}
local options = {radius = 20, cap = 20}
local box, reason = living_villages.terrain.boundary_volume(boundary, ground_y, options)
-- Caller emerges box.minp..box.maxp and waits for completion.
local ok, result = living_villages.terrain.smooth_boundary(boundary, ground_y, options)
-- true, stats OR false, reason. May have written before a late failure.
```

No schematics, random stream, town catalogs, or `settlements` plan records in
this interface. Default radius/cap are 20; allow optional `options.env` for the
same engine/helper injection pattern as the existing API. Other operational
constants belong inside Living Villages, not in Towns. Do not add user settings
for this first version.

### Geometry and solver

- Interpret rectangles as a union. Validate dense, nonempty lists, finite integer
  coordinates/ground, ordered endpoints, and nonnegative integer radius/cap.
- Create internal zero-yard pads for those rectangles. Use the existing rounded
  Euclidean distance from a rectangle: change columns with distance **less than
  radius** from the union; columns at radius remain fixed. This preserves solver
  conventions and avoids an off-by-one redesign. Radius zero is a no-op.
- For interior columns, supply `ground_y` regardless of the map nodes above it.
  Keep them as hard footprint constraints in `targets`. Do **not** pass the city
  union as protected rectangles to that solver.
- For writes, exclude every interior column, including unchanged footprint
  support filling. A filtered targets view whose `pad(x,z)` is nil inside the
  union can reuse `apply`; also enforce the exterior write predicate at the
  writer boundary. The two roles (fixed constraint, forbidden write) differ.
- Supply the union as protected rectangles to **tree cleanup**, where protection
  is the appropriate behavior. Never protect the entire urban bounding rectangle
  for margin smoothing: that would exclude medieval recesses.
- Scan structures using the existing predicate and one-node structure margin.
  Exterior columns near structures, unknown terrain, or overhangs are skipped.
  Interior constraints still return `ground_y`, even beside a town building.
- Explicitly skip liquid and ice surfaces. The current smoothing path tests
  liquids, but its ice treatment is not identical to Towns' classification.
  Reuse LV's existing ice helper where appropriate and test ice explicitly.
  Leave directly adjacent ground fixed as a small shoreline buffer; this follows
  the existing holes stage's conservative approach without running that stage.
  No fluid simulation or guarantee against every possible later water flow.
- Surface movement is measured against the exterior ground height used by the
  planner after vegetation cleanup. Support depth and vegetation changes are
  not surface displacement. Never clamp a footprint and accidentally move town
  ground to satisfy the cap.
- Reuse LV material handling; its default grass surface is acceptable for v1.
  A biome-palette redesign is outside scope.

### Stages and loading

Run: validate -> check loaded volume -> clear trees -> read heights/structures
-> compute targets -> apply exterior targets -> return stats. **No hole pass.**
Tree removal can be committed before later work fails; callers must not infer
zero writes from `false` or an exception.

The 20-node radius limits **ground grading**. Existing whole-tree and fragment
cleanup may remove vegetation beyond it. Permit that cleanup halo to reuse the
existing helper; include it in emerge and reported bounds. Do not promise that
every vegetation write is within 20 nodes. Protect all city columns throughout.
Avoid separate per-column calls to tree cleanup: use one batched call over the
expanded rectangle zones, with the city union protected. Clearing vegetation
throughout that exterior work zone is acceptable for v1.

`boundary_volume` must use the same internal bounds calculation as the writer,
return inclusive `{minp,maxp}` aligned outward to mapblocks, and do no world IO.
The bounds must include the full read/write reach of cleanup and column helpers,
not just the visible grading band. In particular:

- Use a fixed surface inspection interval around ground (proposed +/-48).
  Skip columns whose true top cannot be established within that interval.
- Allow target heights up to `cap` above/below observed ground; include support
  probes/fill 20 below the target, cut clearance above the old ground, and plant
  handling up to 32 above the target.
- Tree cleanup currently reads a horizontal halo of
  `max(cap_radius, orphan_margin + leaf_reach)` (18), and 40 extra vertically.
  Its zone boxes include the rectangle's radius expansion. Obtain constants
  from LV's helpers/shared bounds code rather than copying them into Towns.
- Validate derived world bounds before emerging near the engine's map limits.
  If an operation cannot fit, decline it and let Towns continue without margins.
- Check required loaded blocks before starting cleanup. A missing block may
  decline the whole margin operation; per-block recovery is unnecessary for v1.

Stats: `changed`, `cut`, `filled` count ground columns; `max_movement` is their
largest height change; `steps_over_one` is a diagnostic, not a failure;
`tree_removed` and `written` describe cleanup as well. `written` is an inclusive
XYZ envelope, nil when no nodes changed. Do not use envelope overlap as proof
that protected columns were written. Snapshot protected nodes in engine tests.

## 5. Towns orchestration

```text
urban site search (read only)
  -> urban preflight
  -> synchronous urban build (existing builder, unchanged)
  -> query margin volume, emerge asynchronously, attempt smoothing
       failure/timeout/throw: record warning and continue
  -> existing asynchronous outskirts.search, reading the actual world
  -> outskirts preflight
  -> existing outskirts_build.apply
  -> combine successfully placed structures
  -> bed enumeration and resident initialization
  -> one final report; release command lock
```

Move all suburban planning after the margin attempt, including when it is
skipped or incomplete. Keep the original player position for plot exclusion.
Keep catalog/dependency checks that can cheaply run before urban writes, but do
not turn the new margin API into a mandatory dependency: older LV versions may
skip smoothing and still use their existing rural API.

`towns.populated.search` becomes urban-only and stores `player_pos`.
`towns.populated.build(result, done)` becomes callback-based; final callback
receives the existing `(summary, message, code, extra)` tuple. There is no new
promise abstraction and no dual synchronous/asynchronous build mode. The
low-level `builder.build_town` stays synchronous. Update the controller contract,
tests, and `tools/place_check` in the same migration ticket.

The controller must hold its busy lock until the final callback, ignore duplicate
callbacks, and prevent stale callbacks from starting another write stage. An
expired active **build** must not be replaced while it may still resume writing;
retain the existing stale-search policy only before the first write. Make these
phase distinctions explicit rather than just increasing the stale timeout.
Reuse `site_search.core_env` and its emerge/after services, with a once-only
watchdog around margin emergence. Timeout means skip smoothing and continue;
a late emerge completion must never run smoothing afterward.

### Recovery scope

| Event | Outcome |
| --- | --- |
| Urban search/preflight/build failure | Existing error handling. This design does not attempt to repair an incomplete urban build. |
| New boundary API absent, volume declined/threw, emerge failed/timed out, smooth returned false/threw | Record margin warning; continue suburban search on actual terrain. |
| Some slopes remain steep | Successful best-effort smoothing; report diagnostics, continue. |
| Suburban search cannot return a plan after the city exists | Record suburban warning; finalize urban residents/report. Do not claim nothing changed. |
| Rural preflight fails | Skip rural application with a warning; finalize urban residents/report. |
| An individual plot is unsuitable or its terraform declines | Existing omission behavior; continue other plots. |
| Unexpected rural writer/placement infrastructure failure | Preserve existing `write_failed` handling and attempted bounds. Broad rural runtime recovery is outside #256; it must not prevent starting rural work after a margin failure. |

Optional stage failures must not call success code with a malformed empty rural
plan. Prefer a branch that finalizes the known urban summary when there is no
valid rural plan. Do not retry after partial writes or silently rerun searches
with a new seed.

### Reporting and modified bounds

Store `summary.margins = {status, reason, stats, attempted_bounds}` with statuses
`smoothed`, `skipped`, or `incomplete`. An API throw/false after an attempt is
conservatively incomplete, because cleanup may already have written. Capture
the attempted volume **before** calling the writer. Missing API/failed emergence
with no writer call is skipped. Do not classify a nonzero slope diagnostic as
incomplete.

Report one short margin line plus warning text when needed. Report optional
suburban failure separately. Expected margin omissions should not use the
controller's fatal error return or stop residents.

Union urban, margin, and rural modified bounds in both success and failure
reports. When margin writes fail, include the attempted volume even if stats are
unavailable. Keep geometry fields such as `summary.town.bounds` and the farm
protection rectangle unchanged. Distinguish actual write envelopes from
conservative possible-write bounds in the report; never claim “nothing outside
it was touched” using urban-only bounds after margin work.

## 6. Ticket-sized implementation sequence

Each ticket should include the agreed behavior and the relevant contract from
this document, exact files, dependencies, and its own acceptance checks. These
are filed below. Do not assign “implement issue 256” as a single Luna task. Keep
tests with each behavior change; do not create a separate late testing ticket
for correctness.

| Design task | Filed issue | Depends on |
| --- | --- | --- |
| LV-1 | [Terrain API: add pure boundary planning and volume query](https://github.com/tbook/luanti-villages/issues/296) | None |
| LV-2 | [Terrain API: apply best-effort exterior boundary smoothing](https://github.com/tbook/luanti-villages/issues/297) | LV-1 |
| T-1 | [City margins: migrate populated builds to callbacks and retain the build lock](https://github.com/tbook/luanti-towns/issues/258) | None |
| T-2 | [City margins: add optional asynchronous Living Villages adapter](https://github.com/tbook/luanti-towns/issues/259) | LV-1, LV-2 |
| T-3 | [City margins: smooth before suburban planning and continue after optional failures](https://github.com/tbook/luanti-towns/issues/260) | T-1, T-2 |
| T-4 | [City margins: report optional-stage results and complete modified bounds](https://github.com/tbook/luanti-towns/issues/261) | T-3 |
| V-1 | [City margins: validate terrain transitions and suburban continuation in disposable worlds](https://github.com/tbook/luanti-towns/issues/262) | LV-2, T-4 |

### LV-1: Pure boundary planning and volume contract

- **Files:** new `village_boundary.lua` (or equivalently scoped module), public
  wiring in `init.lua`, `docs/terrain-api.md`, dedicated standalone tests.
- **Scope:** boundary validation/membership, zero-yard internal pads, known
  interior heights, pure targets reuse, write-mask representation, shared
  operation bounds, public `boundary_volume`. No world mutation yet.
- **Checks:** raised/cut town, overlapping and irregular rectangles, narrow recess,
  strict radius edge, cap 20, extreme 30-node difference produces partial work,
  invalid input, negative coordinates, mapblock rounding and world-limit decline.
  Confirm interior footprint constraints remain hard rather than protected.
- **Dependencies:** none. Do not change existing `targets` behavior for villages.

### LV-2: Apply boundary smoothing through existing terrain helpers

- **Files:** LV-1 module, `init.lua`, `docs/terrain-api.md`, dedicated tests;
  small shared-helper extraction only if needed.
- **Scope:** public `smooth_boundary`; loaded-volume check; one batched tree
  cleanup; structure/liquid/ice/shoreline filtering; existing exterior column
  writer; stats and complete write-envelope accounting. No hole filling.
- **Checks:** no node or param2 changes inside the union, including tree canopy
  crossing it and unchanged-footprint support; no soil grading outside radius;
  cap; pond/ice/foreign structure/overhang skips; plants and stalks; unloaded
  precheck writes nothing; late failures may be partial; every read/write fits
  the queried envelope. Existing village and public farm API tests still pass.
- **Dependencies:** LV-1. Preserve legacy village defaults and API signatures.

### T-1: Make populated builds callback-based without changing stage order

- **Files:** `src/generate.lua`, `src/generate_command.lua`,
  `tests/generate_tests.lua`, `tests/outskirts_integration_tests.lua`,
  `tools/place_check/init.lua`.
- **Scope:** migrate `deps.build` and `towns.populated.build` to callbacks;
  preserve today's generation order temporarily. Keep lock through build;
  once-only completion and phase-aware stale handling. Update all callers.
- **Checks:** synchronous and delayed completion; second command refused during
  delayed build; duplicate completion ignored; stale search never builds;
  an active post-write build cannot be replaced; exceptions reported once.
  Existing engine probe awaits completion rather than reading return values.
- **Dependencies:** none; independently mergeable before LV work lands.

### T-2: Add an optional asynchronous margin adapter

- **Files:** new `src/city_margins.lua`, `init.lua`, dedicated tests registered
  in `tests/run.lua`. No controller reordering in this ticket.
- **Scope:** map `boundary.rects` names (`x1/z1/x2/z2`) to LV names
  (`x0/z0/x1/z1`); radius/cap 20; call `boundary_volume`, emerge with watchdog,
  then `smooth_boundary`; normalize result/warnings and attempted bounds.
- **Checks:** actual union passed, not bounding box; original rectangles not
  mutated; missing API, false returns, exceptions, failed/timeout emergence all
  complete once; late callbacks never write; writer called only after emerge;
  partial attempt retains its envelope. Inject API/environment in tests.
- **Dependencies:** frozen LV-1/LV-2 public contract; tests may use fakes.

### T-3: Reorder suburban planning after margins, with best-effort continuation

- **Files:** `src/generate_command.lua`, integration/search-wiring tests,
  `docs/outskirts_design.md` sections 7 and 8.
- **Scope:** urban-only search; urban preflight/build -> margin adapter -> rural
  search/preflight/apply -> residents. Extract final resident/summary handling
  into one shared local helper if needed. Preserve rural sampler, bands, counts,
  per-plot terraforming, and urban builder.
- **Checks:** recorded stage order; rural search observes a node/height changed
  by smoothing; smoothing failures still call rural search; rural search and
  preflight failures preserve urban summary and initialize urban residents;
  successful rural beds still join residents once; partial margin bounds survive
  a later rural fatal error. Do not reuse a pre-smoothing `result.outskirts`.
- **Dependencies:** T-1 and T-2. No requirement to change farm distances or #255.

### T-4: Report margin results and complete modified bounds

- **Files:** `src/generate.lua`, summary assembly in `src/generate_command.lua`,
  `tests/generate_tests.lua` and integration tests.
- **Scope:** margin line/warnings; optional rural-stage warning; combine all
  attempted/actual boxes for success and later failures. Preserve urban geometry.
- **Checks:** successful, skipped, partial margins; margin warning with successful
  suburbs; urban-only result after rural search failure; later fatal error
  contains margin bounds. No false zero-write claims or automatic retry.
- **Dependencies:** T-3. Until this lands, T-3 must at least log warnings and
  conservatively retain bounds; reporting must not be the only failure evidence.

### V-1: Engine scenarios and visual review

- **Files:** extend `tools/place_check` scenarios/output; record observations in
  `docs/city_margins_validation.md`. Small isolated fixtures, no new harness.
- **Scope:** disposable world cases for rectangular and irregular towns, raised
  and cut edges, extreme cliffs, pond/ice, trees/structures, and farms overlapping
  the completed margin. Include a natural-terrain sample, not only superflat.
- **Evidence:** before/after images or height sections; interior snapshots including
  param2; changed soil distances and surface movement; slope diagnostics; separate
  emerge, solver, cleanup, and write timings; suburban success/omission counts.
  Measure margins immediately before farms, because farms may legitimately
  replace them. Exercise a forced margin failure and show rural work continues.
- **Dependencies:** LV-2 and T-4. Record results rather than inventing a hard
  performance threshold from the pure-planner probe. If there is an unacceptable
  server stall, file a focused follow-up; do not silently add coroutine/VM rewrites.

Recommended merge order: LV-1 -> LV-2; T-1 can land independently; then T-2 ->
T-3 -> T-4 -> V-1. Use the existing Lua 5.1 suites for each repository and the
updated disposable engine check for integration. Ticket authors should repeat
the small interface contracts so an agent does not need the whole conversation.

## 7. Remaining uncertainties and scope guardrails

No product questions remain. The chosen defaults above resolve implementation
details for ticketing; LV implementation may extract a small shared bounds or
apply helper, but must preserve the public contract and existing village tests.

Engine runtime and visual quality remain unmeasured. The probe only exercised
pure height planning. Tree cleanup may clear more vegetation than visually
necessary, and the conservative volume is substantially larger than a 20-node
surface band. Start with the batched existing implementation and measure it.

Water/structure avoidance and movement limits intentionally leave steep spots.
Don't turn diagnostics into site rejection, widen the band dynamically, move
town elevation, constrain later farm terraforming, or require all suburbs to
succeed to declare margin work complete. Coordinate actual larger-field testing
with #255 and distance observations with #238, without expanding their scope.
