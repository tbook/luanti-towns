# Cathedral and monastery captures

## Edited working scan

`schematics/cathedral_monastery_working.mts` captures the edited cathedral and
monastery in `TownsWorkshop` as of 2026-10-11. Its inclusive workshop bounds
are `(100, 7, 98)` to `(158, 42, 150)`: the entrance-side X boundary is 158,
with the other bounds unchanged. The schematic origin is the minimum corner
and its size is **59 × 36 × 53** nodes.

The working file is MTS version 4, 16,164 bytes, SHA-256
`525315574ea8a82c0327ce4a166a57a2e0cf8135f571bf0842b4c4200f34a8dc`.
It was captured from a copy of the workshop, leaving the live world untouched.
All 112,572 captured positions matched the copied world by node name and
orientation (`param2`); 17,866 positions were non-air. This edited scan is
stored separately from the original raw capture below. As with any MTS file,
node metadata and inventory contents are not included.

## Original raw capture

`schematics/cathedral_monastery_raw.mts` is a source template, not a Towns
catalog building. It has not been trimmed, flattened, reoriented, or made
independent of optional mods.

## Source and bounds

- Source: local VoxeLibre world `Home`. The source was read only. A consistent
  SQLite backup and the other world files were copied to
  `/private/tmp/towns-home-edge`; Luanti and WorldEdit ran on that copy.
- Captured inclusive bounds (X, Y, Z): `(141, 11, 173)` to `(204, 46, 225)`.
- Schematic size: **64 × 36 × 53** nodes, origin at the minimum corner. The
  first capture ended at Z=175; the working capture includes the Z=173–174
  slices and retains the Y=11 foundation layer.
- User landmarks: bottom of front steps `(204, 11, 217)`; rear extent
  `(141, 11, 225)`; corner behind monastery `(160, 13, 175)`; crossing tower
  `(163, 46, 206)`. The survey found occupied nodes through Y=45; Y=46 was
  included as a safety layer.
- The crop deliberately keeps the cathedral and adjacent monastery together.
  Its entrance direction and clean architectural bounds still need inspection
  in the flat workspace.

## Verification and work remaining

- Captured with WorldEdit's `mtschemcreate` on a fresh read-only backup of
  `Home`. The `.mts` is version 4, 18,981 bytes, SHA-256
  `33d6e4552acb4309d048358d57bf3d5fde1d6a6869b4f2e269f4f48c253b75e5`.
- The initial 64 × 36 × 51 capture was placed at `(300, 100, 300)` on a flat
  platform in a scratch copy. A loaded-world comparison of all 117,504
  positions found zero node-name or `param2` differences from that source crop.
- A separate persistent Creative world, `TownsWorkshop`, uses flat mapgen and
  contains the revised raw schematic at `(100, 7, 98)` through
  `(163, 42, 150)`. Existing Z=175–225 content keeps the same world Z
  coordinates, while the full source capture sits one node lower than the
  first placement. Source Y=11 now maps to workshop Y=7.
  Its flat ground is Y=8; new players start east of the front steps near
  `(170, 10, 142)`. WorldEdit, `mcl_decor`, and Living Villages are enabled
  there so the source nodes remain available while editing. The revised
  placement was checked at the restored stone pair `(154, 7, 99)` and
  `(155, 7, 99)`, cobble `(154, 10, 99)`, and the lowered crossing tower
  `(122, 41, 131)`. A consistent backup of the
  workshop before this revision is at `/private/tmp/TownsWorkshop-before-lowering`.
- The raw crop includes source terrain and needs cleanup for a flat town site.
  It also contains `mcl_decor` nodes and `living_villages:pulpit`, so those
  nodes need replacement or explicit runtime dependencies before registration.
- `.mts` does not retain node metadata. The source crop had 36 nodes with
  inventory entries, including chests, barrels, item frames, and a jukebox;
  any desired contents or behavior must be recreated separately.
- Do not register this raw schematic in the Towns catalog or substitute it for
  the Phase 2 landmark blockout yet. The final footprint, ground contact,
  entrance offset/orientation, and optional-node replacements need to be
  settled in the flat workspace first.
