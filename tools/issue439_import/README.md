# Issue 439: Roman palace import

Imports the Roman palace from TownsWorkshop as a catalog template
(`roman_palace`). This is an import only: the entry has no `role`, so no
planner, town type or outskirts asset selects it, and nothing places it.

## Result

| Item | Value |
| --- | --- |
| Non-natural bounds (survey, world, inclusive) | (307, 9, 499) to (368, 22, 550); 11725 non-natural nodes |
| Captured box (world, inclusive) | (307, 8, 499) to (368, 22, 550), kept whole with the terrain row at Y = 8 |
| Exported size (x, y, z) | 62 x 15 x 52 |
| Ground row / floor | ground row Y = 8 (natural terrain, template row 0); floor Y = 9 (template row 1) |
| Front (`rotation`) | 0: the north portico, at Z = 499..500, faces -Z |
| Entrance | walk-in opening at world (335, 10, 501), template offset (28, 2, 2) |
| Ground-floor doors (world, Y = 10) | 28; the central double-door pairs at X 335..336 (Z 510, 539 and 547) sit on interior walls |
| Metadata | none recorded: the exporter keeps only non-empty inventories and door state, and the workshop containers are empty |
| Verified | 48360 nodes (names and param2) by the exporter; runtime validation passed at all four rotations |

The ticket's approximate box, (307, 7, 497) to (371, 30, 554), is wider than
the real structure. A survey with a 16-node margin found nothing else
non-natural within 16 nodes of the palace.

Service and bed nodes present in the workshop, recorded for later role work
(none are placed or used yet): 18 beds (36 half nodes, four colours), 10 single
chests and 7 double chests, 2 furnaces, 2 jukeboxes, 1 smoker, 3 armor stands,
3 crafting tables, 1 fletching table, 1 smithing table, 1 grindstone and 1
lectern. The exporter's `.lua` lists every node name the template needs,
including `mcl_decor` and `mcl_copper`.

## Choices a reviewer should check

- **Ground row.** The palace stands on a stone floor one node above natural
  ground. Capturing from the floor row would sink it flush with the street, and
  the stairs on that row would then fail the ground-row rule in
  `tests/town_build_tests.lua` (#87). The box therefore starts at the terrain
  row (`floor_y` and `ground_y` 8), as the chapel and weaver house do, so the
  placed floor sits one block above the street and its stairs are real steps.
  The fixed box also keeps the one-node floor steps in front of each portico.
- **Front.** The palace is symmetric north and south. North (-Z) is taken as the
  front, so `rotation` is 0. If the south side is meant as the front, pick a
  matching opening on the south face, set `rotation` to 180, and re-run
  `import.py`.
- **Entrance.** The north wall has an open 10-node gap at Z = 501, X 331..340,
  with a solid floor at Y = 9. The node (335, 10, 501) has two clear air nodes
  above a walkable floor, which the exporter checks for `entrance_kind`
  `opening`.

## Re-running

The survey and the import need Luanti at the default path and TownsWorkshop
closed (save and return to the menu first). They read a snapshot of the world,
so the workshop is not modified.

```sh
python3 tools/issue439_import/survey.py --scratch /tmp/towns-issue439-survey
python3 tools/issue439_import/import.py
```

`survey.py` writes a full report (`issue439-survey.json`) into the scratch
directory. It has bounds, per-name counts, door positions, layer counts, a
top-down footprint and plan slices (`D` door, `#` structure, `.` air or
ground) at the Y levels given by `--slice-y`. Use a new `--scratch` each time.

`import.py` first checks that `buildings.json` here matches the `roman_palace`
entry in `tools/workshop_export/buildings.json`, which is the only config the
exporter reads. It then runs
`tools/workshop_export/export.py --only roman_palace --validate`, which writes
`schematics/templates/roman_palace.mts`, `.lua`, `catalog.lua` and
`manifest.json`, and prints the manifest record. Pass `--no-validate` to skip
the runtime placement check.

Luanti caches templates, so reload the game before inspecting the new file.

## What is left

- Nothing is needed to import. The catalog entry and schematic are in the
  repo.
- Placing or using the palace is a separate ticket. It needs a `role` (and
  possibly `excluded_resident_beds`) in `tools/workshop_export/buildings.json`,
  a re-export with `import.py`, and a decision on the front and entrance above.
