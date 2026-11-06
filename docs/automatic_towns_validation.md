# Automatic town validation

## Status

The #404 assembled-engine correctness matrix is **incomplete**. The product
owner authorized proceeding on the assumption that unverified scenarios work
when evidence cannot be obtained; the default is `on` for supported
configurations on that basis. Operators may select `off` or `survey`.
Accepted sites may overwrite existing structures, as requested. Do not infer
from the observations below that the complete matrix has passed.

The missing evidence includes independent changed-node and metadata comparisons
around additional production coordinator cases, including rejected sites and
optional omissions; and broader assembled-engine tests of contention and
lifecycle failures. Actual pending/planning village contention also needs to
be observed through the assembled pipeline. A10 (callback ordering
relative to a village planner) remains an explicitly authorized working
assumption, not a verified result. A14 (connected-player loading observation)
is also open.

## Existing evidence and limits

The A12 results in `tools/auto_towns_containment/results/a12-2026-11-03.json`
compare VoxelManip content IDs and param2 across direct populated builds and
include both town types, walls and outside roads. They are independent of
reported builder bounds, but do not compare metadata and do not run the
production coordinator. See `tools/auto_towns_containment/README.md` for
the sampling window, liquid-reflow handling and other limitations. These
results alone do not establish assembled-pipeline containment.

The coordinator's mocked-engine tests cover activation, freshness and failure
paths. They do not prove those paths under the engine. Prior production-build
scratch samples completed one Roman and one medieval town, but their bounds
were self-reported; see `tools/auto_towns_probe/README.md`. Their controlled
planner call is not a natural village race.

## 2026-11-05 and 2026-11-06 engine observations

These disposable worlds used Towns at `8bf16a2`, Luanti 5.17.0 (LuaJIT
2.1.1764270282), the installed VoxeLibre and Living Villages, flat mapgen,
and no connected player. Commands run from the Towns root:

```sh
python3 tools/auto_towns_probe/run.py --scenario sky-underground --production-survey --port 39801
python3 tools/auto_towns_probe/run.py --scenario concurrent --production-survey --port 39802
python3 tools/auto_towns_probe/run.py --scenario old-neighbor --production-survey --port 39803
python3 tools/auto_towns_probe/run.py --scenario restart --production-survey --port 39804
python3 tools/auto_towns_probe/run.py --scenario fresh --production-build --fixture remote:10752,0,10751,10752,0,10751 --duration 90 --port 39805
python3 tools/auto_towns_probe/run.py --scenario fresh --production-build --fixture remote:11776,0,10752,11776,0,10752 --duration 90 --port 39806
python3 tools/auto_towns_probe/guard_engine_probe.py
python3 tools/auto_towns_probe/protection_benchmark.py
```

The first two observer scenarios passed their fixture and callback checks.
In each, one production survey completed after 180 chunk requests, with a
92,160,000-voxel reported snapshot bound, in about 25 seconds under concurrent
test load. The concurrent scenario also observed one busy-site decline. These
checks do not independently assert the coordinator's complete freshness gate;
the one reported suppression is a controlled planner call. Scratch reports:
`towns-auto-probe-j0xh7jw2` and `towns-auto-probe-vh_shpjp` in the system
temporary directory.

The old-neighbor and restart observer scenarios passed their saved-block
checks, with reports in `towns-auto-probe-4gdzwn5v` and
`towns-auto-probe-kzqabcxt`. They do not test accepted-record recovery. The
production coordinator reported a complete Roman build in 40.0 seconds with
224 emerge requests and a complete medieval build in 44.0 seconds with 254
requests. Their reported write bounds fit their approved envelopes; these are
not independent write observations. Their reported snapshot bounds were
92,160,000 and 107,520,000 voxels respectively. Scratch worlds:
`towns-auto-probe-lqculnr1` and `towns-auto-probe-2ryzipuo`. Runs were
concurrent, so timings do not represent isolated performance. The observer's
longest main-loop steps were 2.33 and 4.09 seconds, respectively; no connected
player was present.

After enabling the default, the expanded Lua 5.1 suite with the installed
Living Villages checkout passed 64,647 checks with zero failures; the probe
validators passed 18 Python tests.
The final-cap sweep (`TOWNS_LIVING_VILLAGES=<living_villages> lua5.1
tools/auto_towns_containment/cap_sweep.lua 300 8`) exercised 300 plans per
family at all sampled chunk alignments: the maximum was 210 chunks, below
the frozen cap of 256. This is a planner-envelope sweep, not a substitute for
observing the assembled pipeline's actual writes.

For the production Roman sample, the scratch-only `--observe-build` observer
snapshotted loaded nodes (content ID and param2) and node metadata immediately
before the real builder handoff and after its callback. It observed 111,159
changed nodes and 1,752 changed metadata positions; none were outside the
approved write box. No mapblocks in the observed window were ungenerated.
The window extends 16 nodes beyond the box, rounded to mapblocks; writes beyond
that window and identical rewrites are invisible, and changes are not attributed
to individual stages. The observer runs its snapshot and diff on the main thread,
so its pauses are instrumentation overhead. Scratch world:
`towns-auto-probe-w6b29k64`. Command:

```sh
python3 tools/auto_towns_probe/run.py --scenario fresh --production-build --observe-build --repeat-fixture-on-restart --fixture remote:10752,0,10751,10752,0,10751 --duration 70 --timeout 300 --port 39811
python3 tools/auto_towns_probe/run.py --scenario fresh --production-build --observe-build --repeat-fixture-on-restart --fixture remote:11776,0,10752,11776,0,10752 --duration 70 --timeout 300 --port 39812
```

The equivalent medieval sample (`towns-auto-probe-5ostj5x9`) observed
118,444 changed nodes and 1,728 changed metadata positions, with none outside
the approved box and no ungenerated mapblocks in the observed window. Both
samples use flat terrain and do not independently exercise all required stage
and omission cases. The first fixture version wrote the empty startup record
list as JSON `null`, so its overall restart validator fails the initial-empty
assertion despite the node and metadata observations above. The fixture now
writes `[]` explicitly; the failed report remains in the scratch world.
On 2026-11-06, eight handpicked remote coordinates on v7 seed 2014 all
declined at exact inspection before the observer's builder handoff. Each run
used the `--observe-build` command above with `--mg-name v7`, duration 25, a
distinct port and the corresponding point as `--fixture remote:x,0,z,x,0,z`.
Reruns with scratch-only inspection reason logging produced:

| Fixture x, z | Actual site type | Rejection | Scratch world suffix |
| --- | --- | --- | --- |
| 10752, 10751 | Roman | no_ground | d8p3w18q |
| 11776, 10752 | medieval | too_deep_water | vvymdq7m |
| 4608, 2560 | medieval | too_deep_water | 7dvacdal |
| 7680, 2560 | Roman | too_deep_water | ug8ekkar |
| 8704, 2560 | Roman | too_deep_water | r7kf__q3 |
| 9728, 2560 | Roman | too_high | g0yxgjqb |
| 10752, 2560 | Roman | too_deep_water | 0c1qc42m |
| 11776, 2560 | Roman | too_deep_water | a_v7j5vo |

Scratch directories are `towns-auto-probe-<suffix>` in the system temporary
directory. Their observer reports fail the required-build assertion because
none reached the builder, and supply no containment result. The zero-for-eight
outcome is a real observation, but handpicked nearby sites on one seed are not
an ordinary exploration sample or a density estimate. #405 should measure
acceptance and discovery with its specified routes and baseline.
The corrected Roman run passed all observer and restart checks:

```sh
python3 tools/auto_towns_probe/run.py --scenario fresh --production-build --observe-build --repeat-fixture-on-restart --fixture remote:10752,0,10751,10752,0,10751 --duration 50 --timeout 300 --port 39813
```

Its scratch world is `towns-auto-probe-sy_35n82`. One complete record was
present after the first process, reloaded unchanged in the second, and remained
the only record after repeating the already-generated request. This does not
exercise every possible first-touch request in neighboring chunks.

In the corrected Roman run a controlled call through the guarded public village
planner at the active inspection site returned false; its write-through event
is `wt_survey_suppression`. It demonstrates suppression of that injected call,
not natural pending/planning callback ordering or A10.

After changing the default, `towns-auto-probe-qj5qeibz` ran with no
`towns_auto_mode` setting and completed a Roman build. The independent observer
found no node or metadata changes outside the approved envelope, and the
accepted record was complete at shutdown. Its controlled planner call was
suppressed during inspection. Command:

```sh
python3 tools/auto_towns_probe/run.py --scenario fresh --production-build --use-default-mode --observe-build --assert-guard-suppression --fixture remote:10752,0,10751,10752,0,10751 --duration 60 --timeout 300 --port 39838
```

In `towns-auto-probe-0icr_k6j`, a scratch-only hook moved one proposed rural
structure box just outside the approved envelope before the real outskirts
writer ran. The writer reported plot `f01` skipped for the envelope and did
not place it. The independent comparison observed 110,749 node changes and
1,618 metadata changes, all within the approved envelope; no observed
mapblocks were ungenerated. This tests one controlled omission in a flat
Roman build, not all optional-stage geometries.

```sh
python3 tools/auto_towns_probe/run.py --scenario fresh --production-build --observe-build --omit-unsafe-plot --fixture remote:10752,0,10751,10752,0,10751 --duration 60 --timeout 300 --port 39832
```

A separate Roman scratch run injects a protection denial at the production
write gate. The provider was called; the observer saw zero node or metadata
changes, and no accepted record was created. The fixture is a controlled
provider, not an installed protection mod. Scratch world:
`towns-auto-probe-dyt59svx`.

```sh
python3 tools/auto_towns_probe/run.py --scenario fresh --production-build --observe-build --reject-protected --fixture remote:10752,0,10751,10752,0,10751 --duration 50 --timeout 300 --port 39814
```

Three further controlled Roman runs passed. In `towns-auto-probe-rfc8xy8a`, an
injected accepted-record persistence failure caused zero observed node and
metadata changes and created no record; the actual registered generation
command also reported busy and left the automatic job's lock owner intact.
In `towns-auto-probe-v2u_7wew`, a required urban stage failed immediately
after the record was accepted; the record became interrupted and no changes
were observed. These injected failures do not reproduce every storage or
partial-write failure. In `towns-auto-probe-ktd6oync`, replacing the planner
callable immediately after guard installation disabled automatic processing and
created no accepted record. It does not establish accepted-reservation safety
when another mod later replaces the guard.

```sh
python3 tools/auto_towns_probe/run.py --scenario fresh --production-build --observe-build --reject-storage --check-command-contention --fixture remote:10752,0,10751,10752,0,10751 --duration 50 --timeout 300 --port 39817
python3 tools/auto_towns_probe/run.py --scenario fresh --production-build --observe-build --fail-required-stage --fixture remote:10752,0,10751,10752,0,10751 --duration 50 --timeout 300 --port 39816
python3 tools/auto_towns_probe/run.py --scenario fresh --production-build --observe-build --break-guard --fixture remote:10752,0,10751,10752,0,10751 --duration 20 --timeout 180 --port 39819
```

The guard startup probe passed its accepted-reservation suppression and near
miss, using a stub as the saved planner; it did not exercise the real planner.
Scratch world: `towns400-engine-w3vdc1jp`. The protection benchmark used the
installed no-op provider: 44,815,680 Roman positions in 0.0131 seconds and
42,641,640 medieval positions in 0.0122 seconds. A protection mod can have a
very different per-position cost; no such provider was measured. Scratch world:
`towns-protection-bench-0sgtgxl2`. These timings are not connected-player
latency measurements.

For #405, measure at least one representative active protection mod across the
repeated protection checks in a completed automatic build, including the
longest main-thread pause. Record the provider, its settings, the number of
checks and the number of passes. The no-op figures above do not establish
performance with an active provider.
