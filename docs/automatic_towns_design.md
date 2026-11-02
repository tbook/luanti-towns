# Automatic towns — issue 355

Proposed design for review, 2026-11-02. Parent:
[Towns #355](https://github.com/tbook/luanti-towns/issues/355).
Source baseline: Towns `3618e34`, installed Living Villages `668c5fc`, and
the installed VoxeLibre `mineclone2/mods/MAPGEN/mcl_villages` generator.
This document proposes behavior and implementation work; it adds no runtime code.

## 1. Direction

Replace a small fraction of natural village opportunities with populated towns.
Try a few nearby positions, accept a suitable one, or continue ordinary village
generation. Keep the search local and bounded even if that leaves large gaps
between towns.

Agreed constraints:

- Build only as part of first terrain generation. Never insert towns into
  previously generated terrain, including untouched terrain.
- Generate both existing town types, using their existing layout and content
  variation. New layouts are outside this issue.
- Prefer reasonably level ground and modest terraforming. Do not seek rivers,
  coasts, or water access. Water outside a town is acceptable.
- Reuse the existing urban, margin, wall, outskirts, node setup, and population
  pipeline. Do not build a second town generator.
- Do not add regional placement cells, a world terrain index, an expanding
  search, a general scoring framework, or automatic repair.

The numerical choices below are starting values for the survey, not claims
about the resulting town density or performance.

## 2. What exists and what must change

| Source | Relevant behavior |
| --- | --- |
| `src/site_search.lua` | Searches a lattice around a player, emerges candidate volumes, scans every footprint column, and selects a median ground level. Its player reference and broad search are unsuitable for automatic placement; its terrain rules are reusable. |
| `src/generate_command.lua` | Exposes `towns.populated.search` and callback-based `build`; performs margins, walls, outskirts, and population after the urban build. Some bounds are discovered after writes begin. |
| `src/generate.lua` | Serializes command searches/builds through its controller. Automatic jobs must share a common build lock with this controller. |
| `src/outskirts.lua` | Already bounds rural search attempts and may omit unsuitable plots. Rural planning inspects terrain after town margins. |
| `src/city_margins.lua` | Queries Living Villages for a margin volume before requesting it. The volume includes tree cleanup and inspection reach, beyond the visibly smoothed land. |
| VoxeLibre `mcl_villages/init.lua` | Uses a blockseed gate, a heightmap check, private pending records, and a marker/LBM flow that later emerges and builds the village. |
| Living Villages `site_planner.lua` | Replaces `settlements.create_site_plan`; this is downstream of the natural village trigger and is not a public asynchronous opportunity hook. |

Registering an independent Towns generator does not cancel a village that is
already pending. Wrapping `create_site_plan` alone is also insufficient: it
does not expose the original trigger context or a safe asynchronous fallback.

## 3. Village integration

Add the smallest supported opportunity/defer hook at the natural village
scheduler, before it commits a pending village build. Prefer an explicit
VoxeLibre hook; if maintained through Living Villages, document and guard the
adapter against the supported game version. Do not inspect Lua upvalues or
replace the entire village generator in Towns.

The hook must supply the original trigger bounds, blockseed, a copied surface
reference, and a once-only continuation for ordinary village scheduling. It
must run before rejecting the opportunity using the village-specific height
limit: towns should apply their own footprint test. The continuation retains
the original village checks, random state, and scheduling behavior.
Retain the game's dimension and mapgen eligibility filters, including disabling
natural generation in singlenode; the hook is for overworld surface opportunities.

The narrow lifecycle is:

1. If Towns is disabled/unavailable, or the opportunity is not selected, proceed
   with ordinary village generation immediately.
2. If another command or automatic job holds the shared lock, proceed with the
   village. Do not queue work for a town to appear later in explored terrain.
3. Otherwise hold this opportunity, acquire the lock, and register a temporary
   inspection reservation before emerging any additional terrain.
4. On rejection or a zero-town-write failure, invoke the village continuation
   once and release the reservation and lock.
5. On acceptance, consume the opportunity and retain a town reservation. Never
   invoke village fallback after town writes have started.

Every village attempt must also respect town reservations. Check the final
village structures and their terrain-write reach, not merely its center. A
pending village discovered before the reservation wins; reject the town if
their envelopes conflict. A village attempted during inspection can be declined
if it conflicts; do not retain a growing queue of deferred neighboring villages.
This may omit an occasional neighboring village even if the town later fails.

Only active town reservations and completed/interrupted town envelopes need a
Towns spatial index. Simple mapchunk buckets are sufficient. Village scheduling
needs a way to query its own pending footprints or conservative envelopes.

## 4. Selection and variety

Use a private deterministic random stream derived from the world seed, trigger
coordinates, and a versioned salt. Preserve the full world seed as a string
when deriving it; do not round a 64-bit seed through a Lua number. Reduce the
derived town seed to the planner's supported range. Never consume the village
random stream, global randomness, or wall-clock time.

Initial survey constants:

| Choice | Starting value |
| --- | --- |
| Fraction of village opportunities considered for towns | 1 in 8 |
| Town type | Equal weights for medieval and Roman |
| Candidate centers | Trigger center, then 32 nodes east, north, west, south |
| Coarse sample spacing | 16 nodes, including footprint edges |
| Exact candidate inspections | At most 1 |
| Automatic jobs in flight | 1, sharing the command build lock |

The center comes from the trigger's X/Z bounds. Obtain the reference ground
from its valid copied heightmap samples, excluding unavailable/sentinel values;
reject when no reliable surface reference exists. Use that reference for the
existing +/-48-node scan window, not the trigger chunk's top Y.

Select the type and plan once. Translate that footprint across the five
centers. Coarse samples rank plausible candidates lexicographically by wet
sample fraction, estimated mean absolute displacement from their sampled median,
then original candidate order. Unknown or out-of-window samples make a
candidate unavailable. Coarse sampling does not prove safety and should not
pretend to estimate the exact trimmed height range.

Fully inspect only the highest-ranked candidate. On failure, fall back to the
village; do not inspect the remaining four. This deliberately trades some
acceptance rate for predictable cost. Reconsider the cap only if the survey
shows too few towns despite an adequate opportunity rate.

Use the existing exact terrain limits initially: middle 95% height range <=16,
every column within 24 nodes of finished ground, water/ice depth <=6, and wet
fraction <=25%. Preserve lava and unknown-ground rejection. Water is not an
attraction; dry sites win otherwise comparable coarse rankings. Do not add
biome/type restrictions or perimeter optimization in v1. Visually review the
result before deciding whether natural towns need stricter terrain limits.

The same trigger produces the same proposal. Final acceptance can depend on
already-generated neighbors, reservations, and server activity. Exploration-order
independence is not a v1 guarantee.

## 5. First-generation boundary

A fresh trigger chunk is insufficient: buildings, foundations, margins, road
approaches, and rural terraforming can extend into old chunks.

Use a short-lived set of fresh mapchunks for the active operation. Include the
trigger chunk, then record actual first-generation callbacks intersecting the
bounded request while that operation is active. After emergence completes,
require every mapchunk intersecting the possible write volume to be covered by
that set. An already-generated chunk loaded from disk or memory supplies no
fresh callback and therefore prevents placement. Do not infer freshness from
air, `ignore`, being unloaded, or absence of recognizable construction.

The operation may span several callbacks and asynchronous loading, but it is
one initial-generation operation, never a later retry. Extra generation cannot
start nested town jobs. Generation callbacks must still register village and
other structure conflicts through the normal coordination path.

Before loading, compute one conservative XYZ envelope covering all five
candidate positions and every possible write from the selected plan. Include
foundation depth, tallest structures, supported surface range, walls and their
approaches, margin/tree cleanup reach, and the maximum outskirts band, rotated
asset sizes, and rural terrain/tree/hole reach. Use existing volume queries and
their configuration rather than a guessed fixed padding. Round outward to real
mapchunk boundaries for accounting. Read-only requests may extend farther than
writes but remain bounded and counted.

All later build stages must stay within the approved write envelope. Rural
planning still runs after margins; omit any rural plot whose complete volume
would escape it. Skip an optional stage if its write bound cannot be established;
reject if a required urban stage cannot be bounded. Enforce the bound in terrain
and tree writers as well as node setters; a wrapper around `set_node` alone
does not constrain VoxelManip writes. Do not silently emerge a larger area later.

Before loading and again immediately before the first town write, reject if an
online player is within the write envelope plus 16 horizontal nodes. Continue
existing protection and structure checks. First-generation provenance avoids
scanning the world for player construction; the clearance checks avoid starting
a delayed build around a player who has arrived during inspection.

**Engine experiment required:** prove on the supported Luanti/VoxeLibre version
that the generation observer sees every newly generated chunk before the emerge
completion is consumed, including the original trigger and requests containing
partly old chunks. Prove that full writer volumes can be bounded. Until both
hold, automatic construction stays disabled; a new trigger alone is not an
acceptable substitute. No persistent world-wide freshness ledger is proposed.

## 6. Work and memory bounds

Make one shared, bounded emerge request for the opportunity, then read terrain
in bulk using ordinary VoxelManip snapshots. Reuse the surface samples between
candidates. Do not retain a mapgen VoxelManip or heightmap for later callbacks;
copy the small trigger context while it is available.

Expected selection work is approximately
`O(5 * footprint_area / 16^2 + footprint_area * scan_height)` plus bounded
voxel loading. The exact term occurs once. Plan generation occurs once; reuse
the existing translation/composition checks rather than replanning five times.
Cache node classifications within a job, and release its buffers on completion.

Before emergence, check hard caps on mapchunks requested, voxel snapshot size,
and write-envelope size. Determine numerical caps from measured current plans
in the survey; freeze them before enabling automatic construction. An oversized
plan falls back to a village instead of allocating or expanding without limit.

Process inspection in deterministic batches, initially at most 256 columns per
server step. Wall time may decide when to yield, but not which candidate wins.
A load timeout ends the opportunity; no automatic retry or search expansion.

Selection and construction have separate timing measurements. The existing
urban builder is synchronous, and scheduling it with `after` does not make it
nonblocking. Measure it on the largest current plans. If it causes unacceptable
pauses, split work at existing terrain/structure boundaries before enabling
automatic builds. Do not redesign the builder or move it into an isolated
mapgen environment without measured need.

## 7. Records and failures

Use a stable opportunity ID from trigger coordinates and design version.
Persist compact records: ID, seed, type, center, envelope, state, and outcome.
Never persist terrain arrays. A small state machine is sufficient:

```text
inspecting -> declined
inspecting -> building -> complete
                      -> interrupted
```

Write the `building` record and permanent reservation before the first town
write. Completed and interrupted records suppress duplicate generation and
village overlap. Repeated/late callbacks settle only once. Store warnings for
optional omissions; a populated town with skipped rural plots can be complete.
Failures of required construction or population are reported as interrupted.

After restart, close stale inspecting records without constructing anything or
starting village fallback in now-old terrain. Treat stale building records as
interrupted and keep their reservations. An occasional missing village after a
crash is preferable to replaying construction. No rollback or automatic repair.

Ordinary declined records need only the opportunity ID and rejection reason;
index envelopes only for active, complete, or interrupted towns. Expose a
developer lookup for the nearest recorded town and its status.

## 8. Survey before construction

Build a developer-only survey mode using actual village opportunities. It may
generate the bounded extra terrain but makes no town writes. Run it on fresh,
disposable worlds over fixed explored areas, with Towns disabled as a baseline.
Let ordinary villages continue after each survey attempt.

Record opportunities, selected opportunities, coarse winners, exact acceptances,
rejections by reason, type, fresh-area coverage failures, requested mapchunks,
peak snapshot size, selection elapsed time, and largest main-thread batch.
Record actual successful villages as well as attempts: 1-in-8 replacement
attempts does not mean one town per eight successful villages.

Compare accepted density and distances to representative exploration routes.
Review both types on plains, hills, forest, water edges, and mixed old/new chunk
boundaries. Tune opportunity probability before increasing search effort.
Do not claim a discovery distance or millisecond target until measured results
and the review establish acceptable values.

Required engine checks include old neighbors loaded/unloaded, vertical chunk
boundaries, overlapping pending villages, nested emergence, timeout/late callbacks,
a player approaching during inspection, and shutdown before/after first write.
Use pure Lua tests for deterministic candidate ordering, budgets, coverage,
reservation conflicts, fallback-once behavior, and state transitions. Engine
tests must also prove writes stay inside the approved envelope, including tree
cleanup and optional stages.

## 9. Implementation slices after review

1. **Integration and bounds experiment:** demonstrate village interception and
   fallback, fresh-chunk callback coverage, and conservative writer volumes.
   Identify any small VoxeLibre/Living Villages changes needed. No auto builds.
2. **Bounded selector and survey:** implement the five-position/one-inspection
   algorithm and collect density, memory, and timing evidence. Freeze resource
   caps and revisit only the numerical defaults that evidence contradicts.
3. **Generation lifecycle:** shared lock, village conflict coordination,
   reservations, compact records, failure handling, and developer lookup.
4. **Construction integration:** reuse the populated pipeline with enforced
   bounds, verify first-generation behavior, measure build pauses, and enable
   natural towns only after the checks pass.

Keep #355 as the player-facing parent. Create child tickets after design review;
this PR does not change the issue or create speculative implementation tickets.

## References

- [Existing engineering design, natural generation](engineering_design.md#4-natural-generation-and-world-safety)
- [Outskirts design](outskirts_design.md)
- [City margins design](city_margins_design.md)
- [Luanti mapgen objects](https://api.luanti.org/mapgen-objects/): callback-local
  height/biome data and VoxelManip availability.
- [Luanti core API](https://api.luanti.org/core-namespace-reference/): generation
  callbacks, asynchronous `emerge_area`, and main-thread callback limitations.
