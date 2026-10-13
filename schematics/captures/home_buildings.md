# Home building captures

Raw, unedited copies from a read-only SQLite snapshot of Home. All engine
inspection, export and verification writes took place in `/tmp/towns-houses-capture`.
Home was never launched or written by this capture process.

| Building | Minimum corner | Maximum corner | Size X × Y × Z |
| --- | --- | --- | --- |
| [leather_worker_home_raw](leather_worker_home_raw.mts) | (224, 8, 189) | (232, 17, 199) | 9 × 10 × 11 |
| [corner_house_home_raw](corner_house_home_raw.mts) | (225, 8, 217) | (233, 17, 224) | 9 × 10 × 8 |
| [jail_home_raw](jail_home_raw.mts) | (225, 9, 225) | (235, 15, 231) | 11 × 7 × 7 |
| [townhouses_home_raw](townhouses_home_raw.mts) | (224, 11, 241) | (238, 22, 251) | 15 × 12 × 11 |

Each schematic was placed in the scratch world and every node name and
param2 compared with the snapshot: **4,229 nodes total, zero mismatches,
zero ignore nodes**. These checks do not constitute visual inspection.

JSON sidecars preserve node metadata and inventories using local offsets.
MTS placement alone does not restore these. Entities, including villagers
and entity-based decorations, are not captured. Metadata may include stale
ownership or global coordinates; review it before applying to a template.

Original orientation is retained. Foundation cleanup, canonical entrance
orientation, and catalog registration are deferred until workshop editing.

- **leather_worker_home_raw**: Base Y=8 retains the cobblestone floor. Empty Y=18 trimmed; Z extended to 199 for the lantern surround. Some nearby paving and decoration remain for workshop cleanup.
- **corner_house_home_raw**: Base Y=8 retains the groundwork. Top extended to Y=17 for roof ridge slabs; Z extended to 224 for the rear balcony and exterior stairs.
- **jail_home_raw**: Fractional base 9.5 treated as approximate: Y=9 retains ground below the Y=10 floor. Minimum Z refined to 225 to exclude the neighboring corner-house balcony at Z=224.
- **townhouses_home_raw**: Fractional base 11.4 treated as approximate: Y=11 retains groundwork beneath the Y=12 floor. Minimum Z extended to 241 to include all three entrance steps. Captured as one row of three homes. Contains mcl_decor furniture nodes.
