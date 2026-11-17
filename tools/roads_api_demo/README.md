# Roads API demonstration (#458)

Runs the public `towns_api` (see [Roads integration](../../docs/roads_integration.md))
against towns that the production first-touch coordinator really builds in a
disposable world, and checks the published exits against the built nodes.

`run.py` follows the `tools/auto_towns_containment` pattern: it copies
`world.mt` / `map_meta.txt` of a source world (default `TownsWorkshop`; its map is
not used, `mg_name` is forced to `v7` and the map seed is replaced), copies every
mod that `world.mt` loads and this checkout into a fresh `worldmods/`, and installs
`init.lua` here as the scratch-only mod `roads_api_demo`. The source world,
installed mods and game are never written. The scratch world is kept unless
`--cleanup` is given.

## What the helper mod does

1. Looks up the cells nearest the origin (`auto_sites.lookup`), and emerges the chunk
   at one cell's candidate centre at a time. That is first contact, so Towns starts
   its cell job. The helper waits until `towns_api.writer()` is `nil` (limit
   `--cell-wait`, default 240 s) and logs how long that took.
2. For every settlement `towns_api.settlements()` lists, dumps `settlement(id)` (the
   full JSON, in the report) and re-reads each exit column and step with
   `core.get_node`, comparing `name` and `param2` with the published profile.
   An exit counts as sloped when any step is not plain `mcl_core:cobble` at the
   first step's height. Mismatches are listed with position, wanted and found node.
3. A Roads-like consumer emerges fresh land beside the first settlement, records
   `writer()` and `exclusions()` in its emerge callback, polls `writer()` with
   `core.after` (limit 180 s), then queries `exclusions()` again.
4. Stops after a flat and a sloped exit were verified (and the consumer ran) or
   after `--max-cells` cells.

## Run

```sh
python3 tools/roads_api_demo/run.py                      # seeds 2014,7777,31337 in turn
python3 tools/roads_api_demo/run.py --map-seeds 2014 --max-cells 6
```

Seeds are tried in order until both a flat and a sloped exit were verified.
The command exits 0 only if at least one settlement was published, no published
exit mismatched the world, and both kinds were verified. Reports go to
`results/roads-api-demo-seed-<seed>.json` (settlement dumps, per-exit verification,
consumer timing) with the engine log beside them.

A town that does not get built (wet site, no suitable terrain) is not a failure;
the helper just moves to the next cell. Towns are rare, so a run can legitimately
end with no settlement; try more seeds or `--max-cells`.

## Recorded run

`results/roads-api-demo-seed-2014.json` (and `engine-seed-2014.log`) come from
`python3 tools/roads_api_demo/run.py --map-seeds 2014 --max-cells 24 --cleanup`
on the first map seed, from this branch, on macOS with the installed Luanti.
Three medieval settlements were published (`auto:1:-1`, `auto:1:-2`, `auto:-2:-2`)
with 14 exits: 2 flat and 12 sloped (stair and slab ramps), from `wall_gatehouse`,
`wall_postern` and `wall_opening` sources. Every column and step of every published
exit matched the built node name and `param2` (0 mismatches). The Roads-like consumer's
emerge generated fresh land that started another automatic cell; `writer()` was already
non-nil in its emerge callback (phase `loading`) and went idle 3.1 s later. Street ramps
(unwalled towns) and Roman towns did not occur in this run, so those sources are covered
by the unit tests only.
