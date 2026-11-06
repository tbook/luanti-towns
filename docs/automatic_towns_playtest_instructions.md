# Automatic towns client trials

These disposable worlds copy settings and enabled mods from TownsWorkshop; they
do not open its map. Run commands from this checkout. Join `127.0.0.1` at the
given port using a Luanti client. The first connected player is moved by the
server. Stop other demanding workloads for comparable timing.

## Five-minute visual check

```sh
python3 tools/auto_towns_probe/run.py --settings-from '/Users/tad/Library/Application Support/minetest/worlds/TownsWorkshop' --scenario fresh --production-build --mg-name flat --seed 2014 --fixture remote:10752,0,10751,10752,0,10751 --route tools/auto_towns_probe/routes/405-flat-visual.json --duration 420 --timeout 600 --port 39921
```

Wait until the server log reports the automatic build `complete` before joining;
joining early can block construction at the player-clearance check. The route
takes five minutes from connection. Record whether the completed town is visible
and reachable, any terrain pop-in or noticeable stalls, and screenshots with
approximate route position and time. This is a known flat-world fixture and does
not measure discovery in ordinary terrain.

## Thirty-minute discovery route

```sh
python3 tools/auto_towns_probe/run.py --settings-from '/Users/tad/Library/Application Support/minetest/worlds/TownsWorkshop' --scenario fresh --production-build --mg-name v7 --seed 12345 --fixture sky:-10000,1000,-10000,-10000,1000,-10000 --route tools/auto_towns_probe/routes/405-walk.json --duration 1900 --timeout 2100 --port 39920
```

Join promptly once the server starts; 100 seconds are reserved for joining.
The route lasts 30 minutes at 4.3 nodes/second. Record town sightings and whether
they can be reached, with approximate time and position; also record visible
terrain loading and stalls. Repeat with the same seed, route, fixture, duration,
and hardware, omitting `--production-build`, for a matched baseline.
Keep each printed scratch directory and report path.

The probe moves the connected player with `set_pos`; this is scripted movement,
not ordinary manual travel. It holds the last height over ungenerated ground;
the report counts ungrounded steps. The remote sky fixture is scripted demand.
The observer does not instrument client map-ready events, so server timings and
player observations cannot establish network request-to-ready latency.
