# Automatic town measurements: 2026-11-06

These measurements are partial; they do not establish discovery rates, the
village-to-town ratio, player loading times, or a safe protection optimization.
No placement or resource constants were tuned from them.

## Protection provider

On Darwin arm64, Luanti 5.17.0, VoxeLibre 0.92.3, Towns `8cf4294`, Living
Villages and Areas `377ad685d171f85905567fa028a048c653aa9eee`, an otherwise
empty Areas database with default settings was enabled in a scratch copy of
the TownsWorkshop settings. Flat seed 2014, the Roman remote fixture
`10752,0,10751`, and no connected player were used. A scratch-only timer around
the real protection check recorded **44,815,680 positions in 177.269 seconds**
for the first full write-envelope pass. The engine reported a maximum lag of
178.347 seconds. The server's 120-second duration expired during that pass;
shutdown interrupted later asynchronous build stages, so this is not a completed
town or a measurement of subsequent passes. The empty claims database does not
represent a populated server. Instrumentation added one timer read before and
after the pass, with no per-position wrapper.

The raw scratch world, copied code, `stdout-phase1.log` and
`auto-towns-probe-phase1.json` are in
`/var/folders/nf/h9p5hfvs7jj6vs6q252mzhw00000gn/T/towns-auto-probe-ote8dc7_`.
The runner had not written its aggregate `probe-report.json` when observed.
The probe invocation was:

```sh
python3 tools/auto_towns_probe/run.py --settings-from /private/tmp/towns-405-areas-settings --scenario fresh --production-build --mg-name flat --seed 2014 --fixture remote:10752,0,10751,10752,0,10751 --duration 120 --timeout 900 --port 39904
```

The settings copy added Areas to TownsWorkshop's mod list. The previous #404
no-op-provider benchmark reported 44,815,680 positions in about 0.013 seconds;
it was a separate run and synthetic envelope, not a matched connected-player
trial. The active provider's synchronous scan is a serious usability problem.
The exhaustive check was subsequently removed by product decision; automatic
towns do not honor protection-mod claims.

The same flat Roman fixture with the real Areas mod and an empty claims
database was then run without the node observer. Its production log reported
`complete` in 27.37 seconds after 224 chunk requests; the observer reported a
2.51-second longest step. This ran while the Lua suite was active and is not a
matched performance benchmark; the probe validator checks fixture completion,
while the town completion was read from the production log. No client was
connected. Scratch report and log: `towns-auto-probe-86yo116m` in the system
temporary directory. Command:

```sh
python3 tools/auto_towns_probe/run.py --settings-from /private/tmp/towns-405-areas-settings --scenario fresh --production-build --mg-name flat --seed 2014 --fixture remote:10752,0,10751,10752,0,10751 --duration 80 --timeout 220 --port 39910
```

After that change, two flat seed-2014 production builds used a scratch provider
that reports every position protected. Both completed with one accepted record
and passed the bounded independent node/metadata observer. Roman requested 224
chunks and completed in 30.83 seconds; medieval requested 254 and completed in
36.56 seconds. Their reported snapshot bounds were 92,160,000 and 107,520,000
voxels. Observer longest steps were 4.40 and 3.80 seconds, respectively. These
runs overlapped and the observer's full snapshots and diffs add main-thread
work; they are not matched benchmarks or player-visible latency measurements.
The controlled provider tests the intended behavior, not a real claims mod.

```sh
python3 tools/auto_towns_probe/run.py --scenario fresh --production-build --observe-build --protected-provider --fixture remote:10752,0,10751,10752,0,10751 --duration 100 --timeout 300 --port 39908
python3 tools/auto_towns_probe/run.py --scenario fresh --production-build --observe-build --protected-provider --fixture remote:11776,0,10752,11776,0,10752 --duration 110 --timeout 300 --port 39909
```

Scratch reports: `towns-auto-probe-ps7oe8fw` and `towns-auto-probe-2255jxi7`
under the system temporary directory. The observer covers the approved box and
a 16-node ring rounded to mapblocks; it cannot detect identical rewrites or
changes beyond that window. No connected player participated.

A separate scratch fixture measured one Areas `getAreasIntersectingArea` query
over a representative write box: an empty database returned in 7 microseconds;
one claim touching the box boundary was found, and a one-node near miss was
clear. This is one synthetic query, not a completed production build or a
populated-server benchmark. The normal secure-mod environment exposed
`debug.getinfo` but not `debug.getupvalue`, so the Areas wrapper's captured
previous provider could not be inspected. Calling only this region API would
not account for an unknown provider elsewhere in the protection chain.
Fixture: `/private/tmp/towns-405-debug.py`; scratch world:
`/var/folders/nf/h9p5hfvs7jj6vs6q252mzhw00000gn/T/towns-areas-introspection-ba27snxa`.

## Fixed isolated v7 sites

Two additional handpicked, player-free fixture requests used the production
coordinator with reason logging in a scratch copy. Seed 12345 at
`10752,0,10751` declined `too_high`; seed 67890 at `11776,0,10752` declined
`too_deep_water`. Each loaded 23 chunks before rejection; the one reported
suppression in each was an injected planner call. The respective scratch worlds
are `towns-auto-probe-a3l4m20h` and `towns-auto-probe-qvkwyha7` under the system
temporary directory. These are not an exploration sample and do not estimate
acceptance, village opportunities, or town density.

## Connected-client visual check

On 2026-11-06, the product manager joined the disposable flat seed-2014 world
from the [five-minute visual check](automatic_towns_playtest_instructions.md),
after the fixed Roman town had completed. The server moved the first connected
player along the scripted route using `set_pos` at 2 nodes/second. The product
manager reported: “I see the town. Terrain looks good.” They also said:
“walking is funny - I'm being dragged into the town, but the game looks fine.”
The scripted movement explains the reported dragging. The route log recorded a
connected player and movement; the run was still active when this observation
was recorded, so route completion and access were not established. The server
also logged a separate town build near spawn after the first build completed.

This known flat fixture is a qualitative visibility observation, not natural
discovery or a client request-to-ready latency measurement. The probe has no
client map-ready instrumentation; the user did not report measured timings.
Scratch world and live logs:
`/var/folders/nf/h9p5hfvs7jj6vs6q252mzhw00000gn/T/towns-auto-probe-awwcw6w5`.

Natural walking/flying discovery, access, a matched connected-client baseline,
client loading latency, and broader acceptance measurements remain open. See
[client trial instructions](automatic_towns_playtest_instructions.md).
