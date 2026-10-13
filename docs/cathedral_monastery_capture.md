# Cathedral and monastery captures

## Earlier edited working scan (2026-10-11)

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

## Source history (superseded)

The following sections document the source captures and workshop preparation.
These are historical records; **schematics/templates/cathedral.mts is the only
registered, canonical file** for the cathedral in the Towns mod.

- **Raw capture (64 × 36 × 53)**: Captured with WorldEdit's `mtschemcreate` on
  a fresh read-only backup of the VoxeLibre world `Home`. The `.mts` is version
  4, 18,981 bytes, SHA-256
  `33d6e4552acb4309d048358d57bf3d5fde1d6a6869b4f2e269f4f48c253b75e5`.
  A loaded-world comparison of all 117,504 positions found zero node-name or
  `param2` differences from the source crop.

- **Working capture (59 × 36 × 53)**: Edited in the flat `TownsWorkshop`
  Creative world and placed at source `(100, 7, 98)` through `(163, 42, 150)`.
  The `.mts` is version 4, 16,164 bytes, SHA-256
  `525315574ea8a82c0327ce4a166a57a2e0cf8135f571bf0842b4c4200f34a8dc`.
  All 112,572 captured positions matched the workshop by node name and `param2`.

- **Cleaned template (55 × 35 × 59)**: The raw crop included source terrain and
  optional-mod nodes (`mcl_decor`, `living_villages:pulpit`), which are
  declared as required. MTS files do not preserve node metadata or inventory;
  door state (open/closed) is recorded, but chest and barrel contents are lost.

## Current cleaned game template (2026-10-13)

The active `cathedral` catalog entry now uses
`schematics/templates/cathedral.mts` plus its `.lua` metadata sidecar. The
cleaned cathedral and monastery are kept together. Current source bounds are
**(100, 7, 96) through (158, 41, 150)**: **59 × 35 × 55** before rotation.
The older working capture omitted the monastery wall at Z=97 and entry steps
at Z=96. These two rows are included; only the empty Y=42 layer is removed.
Within the older box, the current source differs at three name/param2 positions
from the earlier working scan; this may include normal world updates.

Rotate the compound 90 degrees so the main double doorway and its exterior
steps face -Z. The canonical size is **55 × 35 × 59**. The selected door bottom
is source **(150, 12, 131)**, canonical **(35, 5, 8)**; its adjacent door half
and approach steps are preserved. The foundation is one layer below workshop
ground, so on site ground Y=8 the origin is Y=7 and the door bottom is Y=12.
The generated catalog records `ground_offset = 1` and role `cathedral`.

This template preserves the current mcl_decor furniture, Living Villages
pulpit, and structural node state. Door state (open/closed) is preserved,
but inventories are not: chest, barrel, and item-frame contents are lost
in the MTS format. Source claims, stale simulation data and
source-coordinate formspecs are omitted, as for the other workshop assets.
Placement will report missing nodes before attempting to build.

## Verification complete (ticket #31)

**Verification as of 2026-10-13**: The registered cathedral entry has been
verified against `schematics/templates/cathedral.mts` and the Lua catalog entry.

**File header verified**:
- Magic: MTSM (version 4)
- Size from file header: 55×35×59 matches catalog declaration ✓

**Entrance geometry verified at all four rotations** (using `src/geometry.lua`
pure functions with non-zero placement position {x=100, y=20, z=50}):
- Rotation 0°: entrance (135, 25, 58), outside at (135, 25, 57), outside is out of footprint ✓
- Rotation 90°: entrance (108, 25, 69), size swapped to 59×35×55, outside is out of footprint ✓
- Rotation 180°: entrance (119, 25, 100), size 55×35×59, outside is out of footprint ✓
- Rotation 270°: entrance (150, 25, 85), size swapped to 59×35×55, outside is out of footprint ✓
- All rotations: entrance.y = placement.y + entrance.y (20 + 5 = 25) ✓
- All rotations: outside = entrance + front vector direction ✓

**Metadata and required nodes**:
- 36 metadata entries (door state only; inventories not preserved) ✓
- 149 required node types, no duplicates ✓
- Critical nodes present:
  - `living_villages:pulpit` ✓
  - `mcl_jukebox:jukebox` ✓
  - `mcl_books:bookshelf` ✓
  - `mcl_lectern:lectern` (pulpit is registered only when this exists) ✓

The compound also contains library and monastery doors; only the main entrance
facing -Z (catalog position 35,5,8) is planned for town generation at this time.

**Status**: All verification tests pass. No defects found. The canonical file
is schematics/templates/cathedral.mts with metadata in schematics/templates/cathedral.lua.
