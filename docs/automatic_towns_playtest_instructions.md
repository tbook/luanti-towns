# Automatic towns client trials

These disposable worlds copy settings and enabled mods from TownsWorkshop; they
do not open its map. Run commands from this checkout. Join `127.0.0.1` at the
given port using a Luanti client. The first connected player is moved by the
server. Stop other demanding workloads for comparable timing.

The runner prints `Scratch world: ...` at startup and writes server output to
`stdout-phase1.log` in that directory. In a second terminal, monitor it with
`tail -f '<scratch world>/stdout-phase1.log'`, replacing `<scratch world>`
with the printed path. The duration counts from probe startup, not from when
the client joins; the join windows below leave time for each complete route.

## Five-minute visual check

```sh
python3 tools/auto_towns_probe/run.py --settings-from '/Users/tad/Library/Application Support/minetest/worlds/TownsWorkshop' --scenario fresh --production-build --mg-name flat --seed 2014 --fixture remote:10752,0,10751,10752,0,10751 --route tools/auto_towns_probe/routes/405-flat-visual.json --duration 720 --timeout 900 --port 39921
```

Wait until `stdout-phase1.log` contains a `[towns] automatic` JSON record with
`"outcome":"complete"` before joining; joining early can block construction at
the player-clearance check. Join within five minutes of probe startup, leaving
at least seven minutes before the configured shutdown for the five-minute route.
If the build has not completed within that window, restart the trial. Record
whether the completed town is visible
and reachable, any terrain pop-in or noticeable stalls, and screenshots with
approximate route position and time. This is a known flat-world fixture and does
not measure discovery in ordinary terrain.

## Thirty-minute discovery route

```sh
python3 tools/auto_towns_probe/run.py --settings-from '/Users/tad/Library/Application Support/minetest/worlds/TownsWorkshop' --scenario fresh --production-build --mg-name v7 --seed 12345 --fixture sky:-10000,1000,-10000,-10000,1000,-10000 --route tools/auto_towns_probe/routes/405-walk.json --duration 2100 --timeout 2300 --port 39920
```

Join within four minutes of probe startup, leaving at least 31 minutes before
the configured shutdown.
The route lasts 30 minutes at 4.3 nodes/second. Record town sightings and whether
they can be reached, with approximate time and position; also record visible
terrain loading and stalls. Repeat with the same seed, route, fixture, duration,
and hardware, omitting `--production-build`, for a matched no-Towns baseline:
the baseline does not load the Towns mod at all.
Keep each printed scratch directory and report path.

The probe moves the connected player with `set_pos`; this is scripted movement,
not ordinary manual travel. It holds the last height over ungenerated ground;
the report counts ungrounded steps. The remote sky fixture is scripted demand.
The observer does not instrument client map-ready events, so server timings and
player observations cannot establish network request-to-ready latency.
