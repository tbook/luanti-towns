# Office and banker captures

Raw copies captured 2026-10-13 with Luanti 5.17.0 / VoxeLibre from a
read-only SQLite snapshot of Home. Home was never launched or written by
the capture process. All engine writes occurred in
`/tmp/towns-houses-capture-4`.

| Building | Minimum corner | Maximum corner | Size X × Y × Z |
| --- | --- | --- | --- |
| [office_building_home_raw](office_building_home_raw.mts) | (256, 5, 176) | (267, 23, 187) | 12 × 19 × 12 |
| [banker_house_home_raw](banker_house_home_raw.mts) | (235, 7, 196) | (246, 18, 206) | 12 × 12 × 11 |

Placed both copies in the scratch world and compared all **4,320 nodes**
with the snapshot: zero node-name or param2 mismatches, zero ignore nodes.
This was programmatic verification, not visual inspection.

JSON sidecars preserve node metadata and inventory data at local offsets.
MTS placement alone does not restore them. Entities are excluded. Review
ownership and world-coordinate references before applying metadata.

Original orientations and supplied base levels retained. Foundation cleanup,
entrance orientation, and catalog registration remain for workshop editing.

- **office_building_home_raw**: Supplied base Y=5 and Z bounds retained. Maximum X extended to 267 for entrance steps. Empty Y=24 trimmed; the top torch is at Y=23. Some surrounding terrain and farm-edge nodes remain for cleanup.
- **banker_house_home_raw**: Supplied base Y=7 retained. X extended to 235..246 and Z to 196..206 for projecting shutters. Empty Y=19 trimmed; highest wall blocks are at Y=18. Underground connections below the supplied base are excluded. Nearby street-lamp and paving fragments remain for cleanup.
