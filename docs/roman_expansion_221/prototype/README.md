# #221 prototype: how the numbers in roman_expansion_layout.md were made

Development evidence only; nothing here is loaded by the mod or the tests.

Setup (a scratch copy; never edit the real `src/`):

1. Copy the mod (`src`, `tests`, `tools`, `schematics`, `init.lua`,
   `mod.conf`) to a scratch directory `MOD`.
2. Hippodrome entrance: in `MOD/schematics/imports/roman/catalog.lua` set
   the hippodrome entrance to x 18, y 8, z 3 with no facing, and
   `entrance_kind` to `"opening"` (section 6 of the layout doc).
3. Planner extensions: `python3 scripts/patch_planner.py MOD/src/roman_planner.lua`
   (inserts `scripts/new_arch.lua` and `scripts/new_bounds.lua`: the
   terminal landmark with forecourt, and `main_rect` plus compound union).
4. Layout: copy one of `layouts/stage35N_roman_civic_plan.lua.txt` or
   `../proposed_roman_civic_plan.lua.txt` (the #354 end state) to
   `MOD/src/roman_civic_plan.lua`.

Runs, from `MOD` as the working directory, with Lua 5.1, passing the
absolute path of `MOD` as the first argument:

- `census.lua MOD [cx cz]`: per-seed counts (seeds 1, 2, 3, 7 at the
  round-robin centres, or all at one centre), house/shop/workshop, jail and
  service blocks, shortages, the bed estimate (bed-bottom nodes in the
  placed ordinary templates; landmark beds separately), per-block counts.
- `sweep.lua MOD 100`: seeds 1..100 over four centres; min/max/mean,
  failures, shortages, plans without a jail, blocks left empty.
- `unused.lua MOD`: ground inside the main rectangle less its 4-node apron
  that is neither street, square, landmark nor block.
- `consumers.lua MOD`: validate, `preflight.compose`, `town_layout.new`,
  `site_search.boundary_columns` at two centres.
- `plan_dump.lua MOD`, `map2.lua MOD 2`: rectangles and the lettered map.
- `route_all.lua MOD` (uses `route_check.lua`): `builder.check_door` for
  the Jupiter, Vesta and hippodrome entrances at all rotations.
- `walk.lua`, `dump.lua`, `cells.lua`, `row.lua`, `find.lua`,
  `buried.lua`: read the `.mts` files (node-by-node routes, layer dumps,
  gap rows, node search, buried-row check).

`results/` holds the outputs quoted in the doc: `res_0_current.txt` was
run on unmodified `origin/main` (0dc6495); `res_1` to `res_4` on the
prototype at each implementation stage (#351, #352, #353, #354).
`tools/layout_compare/run.lua OUT --town-type=roman` on the #354 state
produced `../proposed_metrics.tsv` and the SVG/ASCII renders.
