# Automatic towns — issue 355

Design proposal for review, 2026-11-02. Parent:
[Towns #355](https://github.com/tbook/luanti-towns/issues/355).
Source baseline: Towns `3618e34`, installed Living Villages `668c5fc`, and
the installed VoxeLibre village generator. Also account for outside roads from
[#357](https://github.com/tbook/luanti-towns/issues/357), absent from that Towns
baseline. This document adds no runtime code. The engine experiments below
have not been run.

## 1. Direction

Generate a sparse set of seed-derived town sites. Begin inspection when terrain
generation first reaches a site's activation envelope.
Inspect one position; if it fails, that site has no town.

Product constraints:

- Modify only terrain from this initial-generation operation, including
  neighboring chunks freshly generated to complete it. Never retrofit old land.
- Use both existing town types and their existing layout/content variation.
- Prefer reasonably level terrain. Do not seek rivers, coasts, or water access;
  water outside the town is acceptable.
- Reuse the populated town pipeline. Keep selection and generation bounded.

Use first-touch sites, and make ordinary exploration the only player-facing
discovery method in v1. A developer lookup
is for testing. Maps, directions, and new town layouts are outside this issue.
First-touch sites replace overlapping village plans; they do not require a
village opportunity. The provisional discovery target is at least half of
ordinary walking routes encountering a town within 30 minutes. Review the other
numerical targets during playtesting; they are starting values, not release
gates.

## 2. Cheap site lookup

Divide X/Z into 1,024-node cells, using floor division for negative coordinates.
Hash the full world-seed string, cell coordinates, and a versioned salt to derive
one proposed center, town type, and planner seed per cell. Give medieval and
Roman equal weights initially. Reduce only the planner seed to its supported
range; do not round a 64-bit world seed through a Lua number or consume village
randomness.

Keep a site's activation envelope (the maximum horizontal read/write envelope
padded by village reach, section 4) inside its cell with at least one mapchunk
of clearance from cell edges. Derive allowed center jitter from that bound.
Verify the fit using actual supported layouts and village configuration;
enlarge the cell or decline unsupported oversized plans if necessary. This
separates sites even after mapchunk rounding and extra reads.

A generation callback examines only its intersecting cells, a bounded arithmetic
lookup. First contact with a site's envelope at any height starts its freshness
record; only an eligible overworld surface chunk touching the activation
envelope starts inspection. Underground-only and sky-only chunks are recorded
even before surface activation. Ignore other dimensions and singlenode generation.

Request the center surface chunk first. Copy its valid heightmap values within
the urban footprint during generation and use their median as the reference
for the existing +/-48-node exact scan. The trigger surface layer is only a
bounded hint for requesting the center, never the reference height. If that
request supplies no valid center ground, decline without a vertical search.
Retain center data if ordinary exploration generates that chunk before the job
requests it. No callback-local heightmap may be read after its callback returns.

The activation envelope must be computable before inspecting or planning a full
town. Derive its horizontal maximum from supported layouts, asset dimensions,
every stage's reach, and village reach. Verify all supported layout variants
and reject future plans that exceed it. Build the actual plan only for a
triggered site. A small in-memory terminal set prevents
later callbacks from repeatedly inspecting the same declined site.

No candidate lattice, coarse sampling/ranking pass, separate spatial index, or
village-scheduler patch is needed. Tune cell size from survey results rather than
adding more positions or relaxing the terrain test.

## 3. One inspection, shared construction

Adapt `site_search.search` for an explicit center and reference ground, with
`max_radius = 0` and no synthetic player's standing-ground/inside checks.
Reuse exact terrain classification, height selection, composition, and rejection
rules. Its existing pump handles asynchronous continuations; its column scan
still needs a measured work budget and bulk reader.

Automatic placement currently accepts a middle 95% height range <=20, every
column within 24 nodes of finished ground, water/ice depth <=10, and wet
fraction <=25%. `/towns_generate` keeps its existing range <=16 and water/ice
depth <=6 limits; both modes retain the 24-node cut/fill and 25% wet-fraction
limits.
Retain lava and unknown-ground rejection. Automatic towns may overwrite existing
structures and do not honor protection-mod claims (product decision, 2026-11-06). Water gets
no positive score; there is no score to optimize. Inspect the single position
once, then build or decline.

Reuse `towns.populated.build` for urban terrain, margins, walls, outside roads,
outskirts, node setup, and residents. Outskirts already accepts a nil player
position and can omit unsuitable plots. Keep a shared lock with command
generation, allowing one job at a time. If busy when a site would activate, mark
that site declined for this session; do not queue a town to appear later.
Do not start nested jobs from terrain generated for an active job.

Before loading and immediately before first town writes, require every online
player to be outside the write envelope plus 16 horizontal nodes. Spawn,
teleport, fast travel, and simultaneous exploration can still cause rejection.
Once building starts, a player arriving later needs no special handling.

Site identity and layout are deterministic. Acceptance can depend on load,
freshness and player arrival. Do not promise identical
accepted towns for every exploration order.

## 4. Village coordination without a game patch

Install a guarded wrapper around the current `settlements.create_site_plan`
after Living Villages has installed its planner. The function receives
`(maxp, minp, pr)`; returning false stops the public village build chain.
Use the existing guarded-wrapper precedent and preserve normal village calls
and their random state.

Before calling the original planner, decline a village whose conservative
possible write envelope intersects an active or accepted town envelope.
Towns take precedence over pending, unwritten villages. Derive the village
bound from the supported planner's ring radius, center relocation, largest
rotated schematic, and terrain/tree/hole reach. The ring radius alone is not
a complete write bound. Validate the wrapper's assumptions against the installed
Living Villages version; disable automatic towns if integration is unsupported.

Activate and reserve the town when a surface chunk touches the maximum
horizontal read/write envelope padded by that village reach. A village capable
of reaching the town then has its trigger chunk inside this larger activation
envelope, so the reservation exists before its LBM-driven planner runs. Numeric
generator priority does not protect an asynchronous village build; verify this
activation-to-planner ordering directly in slice 0.

If the wrapper encounters a potentially overlapping candidate site that never
activated (for example, its surrounding trigger terrain predates Towns), mark
that site declined for this session before calling the original village planner.
It must not activate midway through that planner's own terrain requests.
Completed existing structures do not reject towns. There is no need to inspect
private pending-village tables or retain their plans.

On a town rejection, release the temporary reservation; subsequent villages
proceed normally. A village rejected during that inspection may be lost even
if the town later fails. Count that loss in the survey rather than promising
that failed town attempts leave every village unaffected.

There is no deferred village continuation, late marker placement, or village
replay. Normal villages keep the existing game/Living Villages build chain.

Use cell lookup for nearby reservations/accepted records. Keep completed and
interrupted envelopes; do not introduce mapchunk buckets or a global list scan
on every generation callback.

## 5. Freshness and one envelope calculation

Provide one envelope function listing all build stages. Distinguish the maximum
horizontal read/write envelope, the larger activation envelope including village
reach, the XYZ write bound relative to center ground, and read/request bounds.
The activation halo itself is not requested or required to be fresh. Account for:

- Urban cut/fill, clearing, foundations, and tallest structures.
- Margin smoothing and its tree-cleanup/inspection reach.
- Walls, features, gate/postern approaches, and support depth.
- Outside roads from #357 for Roman and unwalled medieval towns, using their
  maximum ramp length, clearance, and support bounds.
- Outskirts bands, rotated rural assets, and terrain/tree/hole reach.

Use existing volume queries and shared configuration. Do not assume that the
visible smoothing radius bounds tree cleanup or support writes. Whichever
change merges second, #355 or #357, must update this calculation and its tests.

Use the existing first-touch generation callback to record exact generated
mapchunk bounds in a small in-memory set per contacted site. Start the set on
first contact with its envelope at any height, before applying the surface-only
activation filter. Record that chunk and every later chunk intersecting the
site's maximum read/write envelope, regardless of whether exploration, Towns,
or another request generated it. Sky and underground chunks generated before
surface activation remain recorded. Recording alone does not reserve the site,
load terrain, or start inspection. Discard the set when the site finishes or is
declined. Do not mark overgenerated padding outside the callback's actual
generated bounds as fresh.

After each bounded load, require the covered possible-write chunks to be present
in that set. Read-only chunks do not authorize writes outside the approved bound.
A `FROM_MEMORY`/`FROM_DISK` action alone proves neither freshness nor age: player
exploration may have just generated the chunk and the callback record supplies
the evidence. Chunks predating first recorded contact have no record and reject
the site. Restart discards the sets, so earlier terrain cannot
be authorized by a new session. `EMERGE_CANCELLED` still requires proof that
terrain is available and recorded; if that cannot be established, decline
without retry. Errors decline.

**Engine experiment required:** confirm that generated-chunk recording runs
before the corresponding emerge completion is consumed, including concurrent
player requests and requests whose blocks subsequently report `FROM_MEMORY`.
Test partial old/new coverage and padding explicitly. Until that evidence
holds, keep automatic construction disabled. No separate observer or persistent
world-wide freshness ledger is needed.

Require fresh coverage for every possible write, after all bounded requests
finish and before construction. Never infer freshness from air, unloaded nodes,
or absence of recognizable buildings. Repeated stage emerges may load those
approved chunks from memory; they must not expand the approved operation.

Keep containment simple: check each stage's declared volume before running it,
omit rural plots that escape the envelope, and compare the accumulated
`summary.write_bounds` afterward. Log an excess as an interrupted build and
fix it before release; detection after writing is diagnostic, not prevention.
Engine tests must assert containment, including tree cleanup. Do not add guards
inside every VoxelManip writer across both mods. Add a targeted guard if a
specific writer cannot otherwise honor its declared volume.

## 6. Work limits and player-visible loading

Read the single candidate through bounded VoxelManip snapshots,
cache classifications, and release buffers promptly. Selection remains roughly
`O(footprint_area * scan_height)`, plus bounded terrain generation.

Load in two stages:

1. Request urban footprint chunks center outward, taking the height reference
   from the center. Stop as soon as reliable heightmap evidence proves failure.
   For example, a height range above 48 across required urban columns cannot
   meet the exact +/-24 cut/fill limit. Use only valid terrain heights with
   semantics matching the exact test; ambiguous or clipped data goes to exact
   inspection, not an approximate rejection. Run the exact urban test once.
2. Only after that passes, request remaining chunks for margins, walls, outside
   roads, and outskirts. Require full fresh write coverage before any town write.

Do not submit the entire envelope as one large emerge queue entry. Start with
one mapchunk-sized request in flight, then issue the next after completion.
Measure its impact before increasing concurrency. Count total requested chunks
and snapshot voxels against hard caps; measure current maximum plans and freeze
numerical caps before construction is enabled. No retry, expanding search, or
unbounded queue.

An inspection budget around 5 ms before yielding is a starting tuning value,
not a release target. Measure both the work and the delay introduced by yielding.
Yield timing must not change site identity or terrain acceptance.

The main risks are CPU pauses, memory growth, emerge-queue contention that
stalls player terrain, and losing player clearance before the first write.
Measure each separately. A rare pause of a few seconds is acceptable; use about
5 seconds as the provisional maximum single pause. Synchronous build stages run
on the server's main thread, so distance from the town does not shorten that pause.
The existing [margin validation](city_margins_validation.md#timing-observations)
already measured `smooth_boundary` alone at about 1.07–1.77 seconds. Measure the
longest single pause across the full pipeline; do not add a build-splitting
implementation slice up front.

## 7. Minimal records

Keep inspecting/declined state in memory, with once-only job callbacks and log
lines for the survey. Persist only accepted towns, just before their first
write: `{cell, version, seed, type, center, envelope, state}`.

States are `building`, `complete`, or `interrupted`. On restart, treat leftover
building records as interrupted and retain their reservations. Do not retry
construction, resume unfinished inspections, or replay villages in old land.
Optional rural omissions may still be complete; required build/population
failure is interrupted. The accepted-record lookup also supports a developer
nearest-town command.

A declined site's terminal bit need not survive restart: old coverage should
reject any later attempt, which must be tested. Accepted records prevent repeat
builds regardless of callbacks or design-version changes.

## 8. Experiments and provisional targets

**Slice 0 comes first:** in disposable worlds, log natural generation along
walking and flying routes before implementing a selector or village wrapper.
Record chunk bounds, nearest-player distance, valid surface heights, and known
generation history within roughly +/-200 nodes. A session callback log can
establish history on a fresh disposable world; `ignore` cannot prove it.
Measure first-touch geometry using the actual activation and write dimensions,
including village reach. Count natural village opportunities and successful
builds to establish the village success rate before tuning town density. Check
fresh-chunk recording versus emerge completion, and probe queue behavior.
Do not generate around every logged chunk just to measure it: that changes the
frontier being measured.

After that, use isolated fresh-world trials for potential site acceptance, and
separate route trials for the real first-touch lifecycle. Include a matched
Towns-disabled route for player-loading latency. Run each acceptance trial in a
fresh world or well-separated area. Label terrain generated by the survey,
ordinary exploration, and other structures separately so the survey does not
quietly count its own extra generation as natural rejection.

Starting values for playtest tuning, not numerical release gates. Enable natural
generation once the freshness, containment, and village-coordination engine
checks pass, then tune these numbers in play:

| Measure | Starting target |
| --- | --- |
| Successful town rarity | Towns less frequent than successful villages; four villages per town is a tuning preference |
| Discovery through exploration | At least half of representative ordinary walking routes encounter a town within 30 minutes |
| Player terrain loading | Added p95 request-to-ready delay <=1 second versus the matched baseline; report worst stalls too |
| Main-thread pause | A rare generation pause of about 5 seconds at most; measure the longest single pause across all stages |

For discovery, count entering within 128 horizontal nodes of the urban footprint
as an encounter proxy; validate actual visibility and access in playtests.
Nearest-town distance and density alone do not imply a route encounter time.
Fix route speed, seeds, settings, and hardware, and report sample sizes and both
types. Adjust the 1,024-node cell size first if density/discovery misses targets.
If the four-villages preference conflicts with discovery, retain the 30-minute
discovery target and relax that preference while keeping towns rarer than
villages. Cell size alone cannot make incompatible targets achievable. If
discovery and the basic rarity requirement still conflict, bring the measured
tradeoff back for review rather than silently dropping either. Never relax
freshness or terrain rules to manufacture the target.

Record declined sites by reason, actual successful villages, villages suppressed
during unsuccessful inspections, total generated chunks, peak snapshot size,
batch pauses, longest single pipeline pause, full inspection/build time,
pre-build clearance rejections, and player terrain request latency.
Include defaults and busy-server/multiplayer trials. Instrument request-to-ready
latency directly; time to the next generated chunk is only a proxy if demand is
known. Visual checks cover plains, hills, forests, and water edges.

Before release, engine tests must cover old neighbors in memory/on disk,
vertical boundaries, pending villages, outside roads, tree cleanup, concurrent
emergence, cancellation/late callbacks, player approach, and shutdown before/
after first writes. Pure tests cover seed/cell lookup, one-candidate limits,
fresh-chunk recording, village bounds/activation halo, reservations, and records.
Include sky/underground generation before surface activation, exploration
generating chunks during staged requests, and villages whose planning emerges
into the site. Passing unit tests alone does not establish first-touch viability;
loading performance is measured and tuned in play.

## 9. Implementation slices after review

0. **Frontier and freshness experiment:** establish activation geometry including
   village reach, generated-callback recording before emerge completion, natural
   village success rate, and player-loading impact. No town writes.
1. **One-site selector and survey:** deterministic cells, first-touch lookup,
   center-reference single-site inspection, footprint-first loading with early
   rejection, shared envelopes, and measured caps. Evaluate the numerical targets
   against the confirmed placement and exploration-only discovery direction.
2. **Village coordination and lifecycle:** guarded planner wrapper, shared lock,
   temporary reservations, accepted records, and developer lookup.
3. **Construction integration:** reuse the populated pipeline, include #357
   roads, and enable natural generation once the freshness, containment, and
   village-coordination engine checks pass. Measure the longest single pause
   and overall completion time, then tune numerical targets in play. No advance
   build-splitting work is required.

Keep #355 as the player-facing parent. After design review, create the slice 0
ticket first; use its evidence to scope the remaining implementation tickets.
This PR does not create them.

## References

- [Existing engineering design](engineering_design.md#4-natural-generation-and-world-safety)
- [Outskirts design](outskirts_design.md)
- [City margins design](city_margins_design.md)
- [City margins validation and timings](city_margins_validation.md#timing-observations)
- [Luanti core API](https://api.luanti.org/core-namespace-reference/): emerge actions,
  generation callbacks, and their main-thread limitations.
- [Luanti mapgen objects](https://api.luanti.org/mapgen-objects/): callback-local data.
