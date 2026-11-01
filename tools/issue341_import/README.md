# Issue 341 Roman building import

Moves the Temple of Jupiter, Temple of Vesta and Hippodrome from the Creative
world into TownsWorkshop (boxes in `buildings.json`, inclusive, either corner
order), using the issue 139 staging-first flow. Close the game first.

```sh
python3 tools/issue341_import/prepare.py --output /tmp/towns-issue341-captures
python3 tools/issue341_import/stage.py --captures /tmp/towns-issue341-captures \
  --output /tmp/towns-issue341-stage
python3 tools/issue341_import/apply.py --stage /tmp/towns-issue341-stage
```

`prepare.py` snapshots Creative read-only and captures each box. `stage.py`
copies TownsWorkshop, places the buildings at the `origin` values (unrotated, no
pad; the terrain rows in each box are kept), restores metadata, then reloads the
saved map and verifies every node name, `param2`, metadata field and inventory
stack. Placement fails if a cell in a footprint is not air or natural ground,
and a hash of every other cell in the loaded region must be unchanged. Nodes
missing from the game are never substituted (`replacements` in `place.lua` is
empty; none were needed). `apply.py` backs up the map (`/tmp/towns-workshop-before-issue341`)
and refuses to run if the workshop map changed since staging. `survey.py`
lists non-natural columns in a workshop area; it was used to pick the free
area x 80..260, z 480..600 (all natural flat terrain).

Origins (file Y=0 row): Jupiter (100,7,500), Vesta (140,8,500), Hippodrome
(170,1,500), so each building's ground datum row lands on Y=8 (offsets 1, 0, 7).
Export with `python3 tools/issue139_import/export_roman.py --only temple_of_jupiter
temple_of_vesta hippodrome`.

## Updating after workshop edits

```sh
python3 tools/issue341_import/update.py
```

With the game closed, this snapshots the workshop read-only, scans around the
three boxes in `FIXED_BOXES` (`export_roman.py`) and stops if anything non-natural
lies outside a box (`scan.py` runs alone too), re-exports only these three ids,
checks that no other manifest record changed, and runs `tools/roman_check/run.py`.
It does not recompute `catalog.lua`: check sizes, ground offsets and entrances
against the printed summary, then run `lua5.1 tests/run.lua`. If a building outgrew
its box, edit `FIXED_BOXES` deliberately and re-run.
