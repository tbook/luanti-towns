# Automatic towns: several candidates per cell (#431)

Status: implemented in T3-T5 (the busy queue, T6, is not yet implemented). Source:
architect recommendation for #431, 2026-11-16, with PM decisions recorded below. Items marked **UNCERTAIN**
were not verified and are settled by the named ticket or by playtesting.

## Why

Playtests (see `automatic_towns_validation.md`, `automatic_towns_playtest_405.md`)
produced 1 completed town in 42 candidate outcomes. A later Testlandia session
(seed 14993866105032827525, with the #440 instrumentation) produced 9 outcomes
and no towns: 4 busy (none self-triggered; three within one second of world
start), 3 `no_ground`, 2 `too_deep_water`. Replaying the three `no_ground`
columns against the saved world showed real ocean, not a generation race. With
one candidate per 1,024-node cell, a cell mostly covered by sea fails entirely.

The sample is small and unstructured. It is not a discovery rate.

## Goal and decisions

Towns about one third as frequent as successful villages, while keeping
first-generation freshness, village coordination, player clearance, bounded work
and command generation.

PM decisions (2026-11-16):

1. Replace the design doc's "do not queue" rule with a small bounded queue that
   expires entries after 60 s.
2. Accept that towns favour low land (see the pre-screen limitation).
3. No extra minimum spacing between towns in neighbouring cells for now.
4. Start `MAX_INSPECTIONS` at 2 (the architect suggested 3). Raise it only if
   playtests show the rate below target. Undershooting is safer than overshooting.

## Design

### Geometry and candidates

From `src/auto_bounds.lua`: a town's `max_rect` is +/-245 nodes; village reach
178 pads it to an activation rect of +/-423. Today's +/-8 jitter exists only
because the whole activation rect must sit inside the cell with 80 nodes of
edge clearance.

- Relax the rule: only `max_rect` must stay inside the cell with the 80-node
  clearance. Candidate offsets can then range +/-186 around the cell middle
  (325..698 within the cell). Activation rects then reach up to 98 nodes into
  neighbouring cells.
- Each cell gets 9 candidates: a 3x3 grid at offsets {-180, 0, +180} plus seeded
  jitter of +/-6. The urban footprint is +/-132, so neighbours overlap by about
  80 nodes. All candidates are deterministic functions of (seed, cell, config).
- Town type and planner seed stay per cell, so the land check does not bias type.
- `auto_sites.lookup` pads its query rect by the overhang and caches per-cell
  descriptors (it runs on every generated chunk).
- Bump `auto_sites.VERSION` to 2. New id: `2:cx:cz:k:type:seed:x:z` with k the
  candidate index. The record key stays `towns.auto_records.v1` (records are
  keyed and checked by cell), so no migration is needed and old accepted cells
  keep their reservations. Unaccepted old cells sit on land saved by an earlier
  session and can never pass the freshness check.

**UNCERTAIN:** whether 9 candidates and this lattice is the right number and
spacing; the architect chose it by reasoning, not measurement.

### Freshness

Checked against `src/auto_state.lua`: a site's chunk set starts at first contact
with its activation rect at any height, and every chunk generated afterwards is
recorded. Chunks loaded from disk are never recorded, so `covers` fails for them.
With one activation per cell, no surface chunk inside any candidate's `max_rect`
can pre-date the cell's activation, so nothing new is needed to prove freshness.

- One chunk set per cell, covering the union of the candidates' `max_rect`s.
  `covers(id, box)` requires the box inside that candidate's `max_rect` and every
  touched chunk in the cell's set. The set is dropped when the cell finishes.
- A cell activates at most once per session.
- Candidates stay `contacted` until the job calls `session:begin(id)`; at most
  one candidate per cell is `inspecting`. A failed candidate becomes `declined`.
  A success finishes that candidate and declines its siblings (the cell is terminal).
- Contacts caused by the job's own requests (`requested_by`) record chunks but do
  not activate a neighbouring cell, to avoid chains the player never caused.
- Limit time from cell activation to the last inspection to 60 s.

### Pre-screen

`core.get_spawn_level(x, z)` was read in engine source (master, not the exact
5.18 tag). It is registered for the main server environment only, uses noise only
and generates no terrain. It returns nothing for river channels, for noise-only
base terrain at or below water level, and for mountain terrain above
`max_spawn_y` (about water level + 16 with default noise). VoxeLibre has no v7
noise overrides (only the cavern threshold); for flat mapgen every point passes.

Score: sample 9 points over each candidate's urban footprint, count those that
return a height, skip a candidate below 5 of 9 (`prescreen_wet`), rank the rest,
break ties with the seeded order. If none qualify, decline the cell without
loading anything.

Limitation: land above roughly y 16-17 also returns nothing, so the check means
"low, dry, not mountain" and highland-only cells lose towns (accepted, decision 2).
The fallback is rebuilding base terrain height in Lua from `core.get_perlin` and
`get_mapgen_setting_noiseparams`, which depends on unverified seed handling.

**UNCERTAIN:** whether `get_spawn_level` agrees with real terrain, and how fast it
is. Ticket T2 settles both. If it disagrees, use the runner-up below.

Runner-up: the same design without the pre-screen, trying 3 seeded candidates
blind. Blind tries in an ocean cell mostly fail together.

### Cost and the busy queue

`inspect_site` loads the whole volume before scanning, so each exact inspection
costs 24-48 chunk loads and 3-8 s (measured in the logs). With
`MAX_INSPECTIONS = 2` the worst case holds the generation lock for roughly 15-20 s
plus the build (about 25 s at 3). The loader is unchanged and the lock is held for
the whole cell job. No center-heightmap early rejection is added: the loader's
own comment says it was left out on purpose because height semantics are unproven.

Queue: FIFO of activated cells, capped at 4, entries expire 60 s after activation
(`queue_expired`), clearance is re-checked when a job starts, and queued
candidates stay `contacted` so villages can still decline them. This reverses the
design doc's "do not queue" rule (decision 1). It matters because a cell job now
runs longer and one chunk can activate two cells at a cell edge.

### Villages, reservations, records

- `auto_villages.lua` works unchanged once lookup returns the candidates: it
  suppresses a village that overlaps the one candidate being inspected, and
  declines `contacted` candidates that overlap a village (villages beat untried
  candidates).
- One town per cell: the cell job declines siblings on success, and
  `Registry:begin` already rejects a second record for a cell or any overlapping
  envelope (`already_accepted`). Towns in neighbouring cells stay at least 160
  nodes apart. No extra spacing rule for now (decision 3).

### Expected effect and measurement

Earlier sessions logged 42 outcomes and 14 villages: about 0.33 villages per
activated cell. A third of villages is about 0.11 towns per activated cell.
Today it is about 0.024 (1 of 42).

**UNCERTAIN:** the architect estimates 0.1-0.3 towns per cell with 2-3
inspections if the pre-screen removes ocean; the range includes the target and
its top end exceeds it. This is reasoning, not measurement. Measure pooled across
sessions: `Village built.` lines, town `complete` outcomes, cells activated and
`suppressed_villages`. Tune `MAX_INSPECTIONS`, then the score threshold; never the
terrain or freshness rules. Living Villages is untouched.

Per-cell log line: cell, activation and trigger, queue wait, and per candidate its
index, center, score, min and max spawn level, outcome and reason, plus the
winner and the number of tries.

## Implemented constants (T5, `src/automatic.lua`)

- `CANDIDATES = 9` candidates per cell.
- `PRESCREEN_MIN = 3` (design said 5). **UNCERTAIN:** the T2 probe showed 5-of-9 also
  rejects dry low land, so 3-of-9 is a deliberately conservative starting point, to be tuned
  at T7.
- `MAX_INSPECTIONS = 2` (PM decision 4). **UNCERTAIN** until playtested.

One cell job holds the generation lock from the first inspection to the last and releases it
once, when the cell ends. Every way the job gives up (no candidates, inspections spent, the
60 s limit, a refused `begin`, or a clearance, guard, build or record failure) declines every
remaining live candidate, so the cell is terminal and its chunk set is dropped. A village that
declines a not-yet-tried candidate mid-cell just skips it. Any failure before acceptance
(inspection, load, emerge, timeout, freshness) moves on to the next ranked candidate while
inspections and the 60 s limit allow.

## Risks

- Highland towns disappear; towns look more alike (favour low land).
- The generation lock is held longer, so `/towns_generate` may report busy more often.
- Overlapping activation areas across cell edges.
- Engine assumption A10 (activation runs before the village planner) now applies
  to a larger activation area. **UNCERTAIN** whether it still holds.

## Tickets

Order: T1 and T2 first (independent), then T3 -> T4 -> T5 -> T6. Each of T3-T5
must keep single-candidate (N = 1) behaviour working so it can merge alone.
T7 (playtest and tuning) is tracked on #431.

- T1: `water_over_air` rejection reason.
- T2: `get_spawn_level` pre-screen probe (gates T5).
- T3: `auto_sites` v2 candidate lattice (pure, not wired).
- T4: `auto_state` cell activation and shared chunk set.
- T5: cell job in `automatic.lua` (pre-screen ranking, sequential inspections).
- T6: bounded busy queue.
