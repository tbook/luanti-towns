# Automatic towns — issue 355

Revised proposal for review, 2026-11-02. Parent:
[Towns #355](https://github.com/tbook/luanti-towns/issues/355).
Source baseline: Towns `3618e34`, installed Living Villages `668c5fc`, and
the installed VoxeLibre village generator. Also account for outside roads from
[#357](https://github.com/tbook/luanti-towns/issues/357), absent from that Towns
baseline. This document adds no runtime code. The engine experiments below
have not been run.

## 1. Direction and review decisions

Generate a sparse set of seed-derived town sites. Begin inspection when terrain
generation first reaches a site's outer envelope, rather than its center.
Inspect one position; if it fails, that site has no town.

This changes the initial village-opportunity proposal. The
[review](https://github.com/tbook/luanti-towns/pull/390#pullrequestreview-5744264574)
identified that a large town centered on a normal generation trigger is likely
to overlap older terrain. The installed defaults generate within 10 mapblocks
(160 nodes) of players, while current town footprints plus outskirts and terrain
work extend a comparable distance from their center. Five positions offset by
32 nodes enlarge that envelope without buying another exact inspection.
These are reasons to test first-touch placement, not measured acceptance rates
or proof that every village-centered proposal fails.

Keep the agreed product constraints:

- Modify only terrain from this initial-generation operation, including
  neighboring chunks freshly generated to complete it. Never retrofit old land.
- Use both existing town types and their existing layout/content variation.
- Prefer reasonably level terrain. Do not seek rivers, coasts, or water access;
  water outside the town is acceptable.
- Reuse the populated town pipeline. Keep selection and generation bounded.

**Confirmed direction after review:** use first-touch sites, and make ordinary
exploration the only player-facing discovery method in v1. A developer lookup
is for testing. Maps, directions, and new town layouts are outside this issue.
First-touch sites replace overlapping village plans; they do not require a
village opportunity. The provisional discovery target is at least half of
ordinary walking routes encountering a town within 30 minutes. Review the other
numerical targets against the engine experiment before creating implementation
tickets.

## 2. Cheap site lookup

Divide X/Z into 1,024-node cells, using floor division for negative coordinates.
Hash the full world-seed string, cell coordinates, and a versioned salt to derive
one proposed center, town type, and planner seed per cell. Give medieval and
Roman equal weights initially. Reduce only the planner seed to its supported
range; do not round a 64-bit world seed through a Lua number or consume village
randomness.

Keep a site's maximum read/write envelope inside its cell with at least one
mapchunk of clearance from cell edges. Derive the allowed center jitter from
that bound, not a second tunable distance. Reject unsupported oversized plans.
This separates neighboring sites even after mapchunk rounding and extra reads.

A generation callback examines only its intersecting cells, a bounded arithmetic
lookup, and starts a site when an eligible overworld surface chunk first touches
the fixed envelope. Ignore underground-only, sky-only, other-dimension, and
singlenode generation. Copy valid ground-height samples from the intersecting
surface while the heightmap exists. Use their median as the reference for the
existing +/-48-node surface window; reject unavailable or implausible references.
An edge reference need not represent the center, so measure these rejections.

The trigger envelope must be computable before inspecting or planning a full
town. Use one conservative horizontal maximum derived from supported layouts,
asset dimensions, and every stage's maximum reach. Verify it against all
supported layout variants and reject future plans that exceed it. Build the
actual plan only for a triggered site. A small in-memory terminal set prevents
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

Initial exact limits remain: middle 95% height range <=16, every column within
24 nodes of finished ground, water/ice depth <=6, and wet fraction <=25%.
Retain lava, unknown-ground, protection, and structure rejection. Water gets
no positive score; there is no score to optimize. Inspect the single position
once, then build or decline.

Reuse `towns.populated.build` for urban terrain, margins, walls, outside roads,
outskirts, node setup, and residents. Outskirts already accepts a nil player
position and can omit unsuitable plots. Keep a shared lock with command
generation, allowing one job at a time. If busy on a site's first touch, mark
that site declined for this session; do not queue a town to appear later.
Do not start nested jobs from terrain generated for an active job.

Before loading and immediately before first town writes, require every online
player to be outside the write envelope plus 16 horizontal nodes. Record the
clearance and elapsed approach time: first-touch makes early completion possible,
but does not guarantee it. Spawn, teleport, fast travel, and simultaneous
exploration can still cause rejection.

Site identity and layout are deterministic. Acceptance can depend on load,
existing structures, freshness, and player arrival. Do not promise identical
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

The first-touch callback must reserve its envelope before any village planner
can write within it. Use explicit `mcl_mapgen_core` priority and verify ordering
in the engine experiment. Completed existing structures still reject the town.
There is no need to inspect private pending-village tables or retain their plans.

On a town rejection, release the temporary reservation; subsequent villages
proceed normally. A village rejected during that inspection may be lost even
if the town later fails. Count that loss in the survey rather than promising
that failed town attempts leave every village unaffected.

There is no deferred village continuation: no late heightmap access, delayed
marker placement, or replay through an LBM. This removes the fallback bugs in
the original proposal and the need for an upstream scheduler hook.

Use cell lookup for nearby reservations/accepted records. Keep completed and
interrupted envelopes; do not introduce mapchunk buckets or a global list scan
on every generation callback.

## 5. Freshness and one envelope calculation

Provide one envelope function listing all build stages. Distinguish its fixed
horizontal trigger bound, the conservative XYZ write bound relative to reference
ground, and the larger read/request bounds. Account for:

- Urban cut/fill, clearing, foundations, and tallest structures.
- Margin smoothing and its tree-cleanup/inspection reach.
- Walls, features, gate/postern approaches, and support depth.
- Outside roads from #357 for Roman and unwalled medieval towns, using their
  maximum ramp length, clearance, and support bounds.
- Outskirts bands, rotated rural assets, and terrain/tree/hole reach.

Use existing volume queries and shared configuration. Do not assume that the
visible smoothing radius bounds tree cleanup or support writes. Whichever
change merges second, #355 or #357, must update this calculation and its tests.

Prefer per-mapchunk accounting from `emerge_area` actions over a generation
observer. The just-generated trigger chunk is explicitly fresh. For other
chunks, the proposed rule is that at least one requested mapblock must report
`EMERGE_GENERATED`; later blocks in that chunk may report `FROM_MEMORY`.
A chunk with only memory/disk actions rejects the site. Cancellation/error
rejects, even if it could be concurrent emergence.

**This accounting is an experiment, not a proved engine guarantee.** Check
mixed old/new regions, request ordering, chunk overgeneration, and concurrency:
a generated block must not wrongly authorize old player-modified blocks in the
same chunk. If actions cannot establish freshness conservatively, keep the
feature disabled while resolving the evidence gap. First-touch does not itself
prove freshness when Towns is added to an old world or terrain is generated by
other requests.

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

One candidate avoids duplicate scans and the extra 64-node span of the earlier
five-position proposal. Read terrain through bounded VoxelManip snapshots,
cache classifications, and release buffers promptly. Selection remains roughly
`O(footprint_area * scan_height)`, plus bounded terrain generation.

Do not submit the entire envelope as one large emerge queue entry. Start with
one mapchunk-sized request in flight, then issue the next after completion.
Measure its impact before increasing concurrency. Count total requested chunks
and snapshot voxels against hard caps; measure current maximum plans and freeze
numerical caps before construction is enabled. No retry, expanding search, or
unbounded queue.

Budget inspection by elapsed CPU work, initially about 5 ms before yielding.
Remove the fixed 256-columns-per-step rule: for a 35,000-column footprint it
would consume roughly 140 server steps even with cheap reads. Yield timing
must not change site identity or terrain acceptance.

The main risks are CPU pauses, memory growth, emerge-queue contention that
stalls player terrain, and a player reaching the site before completion.
Measure each separately. The urban builder is synchronous; `after` does not
make its terrain commit or schematic placement nonblocking. Split a measured
hot stage only if needed, rather than redesigning construction in advance.

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
Compare village-centered and first-touch trigger geometry using the actual
plan/envelope dimensions. Then probe per-chunk emerge actions and queue behavior.
Do not generate around every logged chunk just to measure it: that changes the
frontier being measured.

After that, use isolated fresh-world trials for potential site acceptance, and
separate route trials for the real first-touch lifecycle. Include a matched
Towns-disabled route for player-loading latency. Run each acceptance trial in a
fresh world or well-separated area. Label terrain generated by the survey,
ordinary exploration, and other structures separately so the survey does not
quietly count its own extra generation as natural rejection.

Provisional v1 acceptance targets, subject to product review and survey evidence:

| Measure | Starting target |
| --- | --- |
| Successful town rarity | At least four successful villages per town across representative explored areas |
| Discovery through exploration | At least half of representative ordinary walking routes encounter a town within 30 minutes |
| Player terrain loading | Added p95 request-to-ready delay <=1 second versus the matched baseline; report worst stalls too |
| Main-thread work | Cooperative slices near 5 ms; no added construction pause >100 ms |
| Time from first touch to ready town | p95 <=10 seconds, also reporting player-clearance rejections |

For discovery, count entering within 128 horizontal nodes of the urban footprint
as an encounter proxy; validate actual visibility and access in playtests.
Nearest-town distance and density alone do not imply a route encounter time.
Fix route speed, seeds, settings, and hardware, and report sample sizes and both
types. Adjust the 1,024-node cell size first if density/discovery misses targets.
Do not relax freshness or terrain rules to manufacture the target.

Record declined sites by reason, actual successful villages, villages suppressed
during unsuccessful inspections, total generated chunks, peak snapshot size,
batch pauses, full inspection/build time, and player terrain request latency.
Include defaults and busy-server/multiplayer trials. Instrument request-to-ready
latency directly; time to the next generated chunk is only a proxy if demand is
known. Visual checks cover plains, hills, forests, and water edges.

Before release, engine tests must cover old neighbors in memory/on disk,
vertical boundaries, pending villages, outside roads, tree cleanup, concurrent
emergence, cancellation/late callbacks, player approach, and shutdown before/
after first writes. Pure tests cover seed/cell lookup, one-candidate limits,
freshness aggregation, village bounds, reservations, and records. Passing unit
tests alone does not establish first-touch viability or acceptable loading.

## 9. Implementation slices after review

0. **Frontier and freshness experiment:** establish trigger geometry, emerge
   action semantics, and player-loading impact. No town writes.
1. **One-site selector and survey:** deterministic cells, first-touch lookup,
   explicit-reference single-site inspection, shared envelopes, and measured
   caps. Evaluate the numerical targets against the confirmed placement and
   exploration-only discovery direction.
2. **Village coordination and lifecycle:** guarded planner wrapper, shared lock,
   temporary reservations, accepted records, and developer lookup.
3. **Construction integration:** reuse the populated pipeline, include #357
   roads, verify containment, measure pauses and discovery, then enable natural
   generation only when the release targets are met.

Keep #355 as the player-facing parent. Create child tickets after design review
and slice 0's evidence settle the architecture. This PR does not create them.

## References

- [PR review and supporting calculations](https://github.com/tbook/luanti-towns/pull/390#pullrequestreview-5744264574)
- [Existing engineering design](engineering_design.md#4-natural-generation-and-world-safety)
- [Outskirts design](outskirts_design.md)
- [City margins design](city_margins_design.md)
- [Luanti core API](https://api.luanti.org/core-namespace-reference/): emerge actions,
  generation callbacks, and their main-thread limitations.
- [Luanti mapgen objects](https://api.luanti.org/mapgen-objects/): callback-local data.
