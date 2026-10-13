# More Home building captures

Raw copies captured 2026-10-13 using Luanti 5.17.0 / VoxeLibre on a
read-only SQLite snapshot of Home. The source world was never launched or
written by the capture process. All engine writes occurred in
`/tmp/towns-houses-capture-3`.

| Building | Minimum corner | Maximum corner | Size X × Y × Z |
| --- | --- | --- | --- |
| [weaver_house_home_raw](weaver_house_home_raw.mts) | (213, 9, 225) | (221, 17, 231) | 9 × 9 × 7 |
| [scribe_home_raw](scribe_home_raw.mts) | (235, 7, 207) | (247, 19, 217) | 13 × 13 × 11 |
| [gaboo_house_home_raw](gaboo_house_home_raw.mts) | (258, 8, 211) | (268, 19, 223) | 11 × 12 × 13 |

Placed each schematic in the scratch world and compared all **4,142 nodes**
with the snapshot: zero node-name or param2 mismatches, zero ignore nodes.
Verification was programmatic; no visual inspection has been performed.

JSON sidecars record node metadata and inventories with local offsets. MTS
placement alone does not restore them. Entities are not captured. Review
ownership, world coordinates, and third-party nodes during template cleanup.

The supplied base levels are preserved. The scribe and Gaboo buildings connect
to underground passages and furnished areas outside these building boxes;
those networks are excluded. Original orientations are retained; foundation
cleanup, canonical entrance orientation, and catalog registration remain for
workshop editing.

- **weaver_house_home_raw**: Supplied bounds retained, including ground layers below the Y=11 floor. Roof fits the original X/Z bounds and reaches Y=17.
- **scribe_home_raw**: Minimum X extended to 235 and minimum Z to 207 for roof overhangs. Empty Y=20 trimmed. Supplied base Y=7 retained; ladders and furnished underground passages continue below it and are excluded.
- **gaboo_house_home_raw**: Minimum Z extended to 211 for the taller north section and its roof. Empty Y=20 trimmed. Supplied base Y=8 retained; a furnished room and connected underground tunnels continue below it and are excluded. Includes third-party mcl_decor and seasons nodes.
