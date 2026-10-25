# Outskirts reporting and runtime evidence

`tools/place_check/run.py` creates a fresh temporary world, copies the selected
world's settings (not its map), starts Luanti, builds through
`towns.populated.search` and `towns.populated.build`, and removes nothing from
the source world. With `--keep`, the JSON report remains in the printed
`towns-place-check-*` directory. The probe records elapsed search time, total
synchronous build time, `core.emerge_area` calls during search, elapsed time and
call count for Living Villages `terrain.terraform`, planner counts, and the
terraform API's returned stats. Timings use `core.get_us_time()` and describe
these runs only; they are not a performance benchmark.

Reproduce the flat run:

```sh
python3 tools/place_check/run.py --keep --seed 238 --port 39512
```

Using the installed flat TownsWorkshop settings, this run built at center
`(0,64)`, ground Y 8. Search took 2.465 s and called `core.emerge_area` 50
times. The synchronous build took 2.286 s; its 24 terrain calls took 1.298 s
in total. It placed 17/18 farms, 6/6 huts and 1/1 chapel. The planner counted
22 `plot_spacing` candidate rejections. All 24 terrain calls returned zero
changed, cut, filled, step, wall and unloaded counts. The build and the
restart persistence check passed (147/147 residents).

The probe also reads the placed farm composters and enumerated bed spawn
positions. In this flat run, 17 composters were present; 25 of 141 urban bed
spawn positions had at least one composter within the actual axis-aligned
48-node search range, and 7 of 17 composters had an urban bed within that
range. This measures geometric reach from the bed position only. It does not
show villagers choosing a profession, claiming the composter, or navigating to
it.

Reproduce the non-flat run with the installed V7 settings:

```sh
python3 tools/place_check/run.py --keep --seed 239 --port 39510 \
  --settings-from "$HOME/Library/Application Support/minetest/worlds/Home"
```

The runner uses a fresh scratch map and starts at the generated surface. This
run's town centered at `(320,208)`, ground Y 20. Search took 75.444 s and the
synchronous build took 2.326 s. It placed 16/18 farms, 6/6 huts and 1/1 chapel;
the planner recorded 21 `plot_spacing`, 3 `plot_uneven` and 10 `plot_water`
candidate rejections. Its 23 terraform calls changed 2,313 columns (1,037 cut,
1,276 filled), with maximum `steepest` 5, 127 `steps_over_one`, zero walls and
zero unloaded blocks. No plot was skipped and no placement warning was
recorded. The build verification passed. On the separate restart phase, 147 of
148 recorded residents were found; this run therefore did not pass the
resident persistence check. The result is recorded as observed and has not
been attributed to this change.

The API stats named in the player report are `changed`, `cut`, `filled`,
`steepest`, `steps_over_one`, `walls`, `wall_max`, and `unloaded_blocks`, as
returned by the installed Living Villages terrain implementation. Missing
numeric fields are treated as zero; a stats table with no numeric fields is
omitted.

These engine checks establish placement, terrain API results, and geometric
reach for two disposable seeds. A human playtest is still needed to judge
visual density and to observe actual villager profession claims, jobsite use,
and navigation over time. No placeholder counts or spacing bands were changed
from this evidence.
