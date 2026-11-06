# Paced terrain-demand probe

This short exploratory probe is not a walking or discovery trial. No player or
client was connected. A scratch-only mod requested a vertical stack of 12
mapblocks from y=-16 to 160 every 80/4.3 seconds, at x=0,80,...,720 and z=0.
The schedule uses the distance and nominal speed of walking, but generates a
narrow strip rather than the area that a player would request. Its emerge
callback delay is server-side scripted demand, not network or client map-ready
latency. No village LBM was deliberately activated; the synthetic suppression
injected by the existing observer is not a lost village. There is no visual or
access check and no estimate of the fraction of 30-minute walks finding towns.

Both runs use fresh worlds, TownsWorkshop mod settings, seed 12345, v7, Luanti
5.17.0, and the merged Towns revision `1c7b9c1`; each also requests one remote
sky fixture. They run sequentially on the same Darwin arm64 host. The scratch
mod copied in each world as `worldmods/towns_405_pacer` records request start,
completion time, and emerge actions in `stdout-phase1.log`. The no-Towns
baseline does not load Towns. Each request covers the same 12 mapblocks; the
engine can generate whole 80-node chunks beyond those blocks.

```sh
python3 tools/auto_towns_probe/run.py --settings-from /private/tmp/towns-405-pacer-settings --scenario fresh --production-build --mg-name v7 --seed 12345 --fixture sky:-10000,1000,-10000,-10000,1000,-10000 --duration 210 --timeout 360 --port 39930
python3 tools/auto_towns_probe/run.py --settings-from /private/tmp/towns-405-pacer-settings --scenario fresh --mg-name v7 --seed 12345 --fixture sky:-10000,1000,-10000,-10000,1000,-10000 --duration 210 --timeout 360 --port 39931
```

The settings directory copies TownsWorkshop's `world.mt` and `map_meta.txt`
and appends `load_mod_towns_405_pacer = /private/tmp/towns-405-pacer`. The
copied mod is preserved in each scratch world; this temporary settings directory
and mod must be reconstructed from that copy to repeat the exact commands.

The Towns-enabled run completed all ten paced requests, median 0.2655 seconds,
maximum 0.298 seconds; the observer's longest main-loop step was 0.077 seconds.
It logged one candidate, Roman cell (0,0), center (516,507), declining
`center_ground_missing` after requesting one center chunk. The generated
center layer was y=-32..47. The observer sampled y=47 at that chunk's center
(487,487), inside the candidate's ±132-node inspection footprint. That value is
clipped at the chunk's upper boundary; the state requires a center footprint
with no clipped columns, explaining why it retained no center copy from this
layer. It completed no towns. Raw report and logs:
`/var/folders/nf/h9p5hfvs7jj6vs6q252mzhw00000gn/T/towns-auto-probe-hxkxtq3j`.

The no-Towns baseline completed all ten requests, median 0.252 seconds,
maximum 0.278 seconds; the observer's longest main-loop step was 0.079 seconds.
Raw report and logs:
`/var/folders/nf/h9p5hfvs7jj6vs6q252mzhw00000gn/T/towns-auto-probe-79me45_h`.
Ten samples, no completed town, and unpaired system noise preclude a useful p95
or a general claim about Towns' effect on player loading. Both runs reported
zero seed-gate opportunities in the observed events; without natural village
activation these are not village success or rarity measurements.
