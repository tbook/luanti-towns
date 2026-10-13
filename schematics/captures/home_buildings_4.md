# Additional Home captures

Raw copies captured from a read-only SQLite snapshot of Home. The source
was not launched or written by the capture process. Captures retain original
orientation and metadata sidecars for later workshop cleanup.

| Building | Source minimum | Source maximum | Size X × Y × Z |
| --- | --- | --- | --- |
| Butcher shop | (224, 6, 164) | (232, 13, 172) | 9 × 8 × 9 |
| Mason's yard | (233, 5, 163) | (239, 10, 171) | 7 × 6 × 9 |
| Chapel | (-129, 8, 480) | (-120, 21, 498) | 10 × 14 × 19 |

Verified all **3,686 nodes** by placement in the scratch world: zero
node-name/param2 mismatches and zero ignore nodes. Metadata and inventories
are recorded in JSON sidecars; MTS alone does not preserve them. Independent
entities are not copied.

- **Butcher shop**: Approximate base 6.5 captured from Y=6, beneath the Y=7 mud floor. Top trimmed from 24 to 13; Y=14..24 are empty in the supplied box. Raw surrounding terrain is retained for editing.
- **Mason's yard**: Approximate base 5.5 captured from Y=5. Refined X/Z to (233..239,163..171) to keep the full stone yard and roof while excluding the neighboring butcher shop eaves and adjacent buildings. Roof slabs reach Y=10, one layer above supplied top 9.
- **Chapel**: Approximate base 8.5 captured from Y=8 beneath the Y=9 floor. Supplied X/Z bounds retained; top extended to 21 for the finial. Includes mcl_decor chairs and living_villages pulpit. Some courtyard-wall and terrain fragments remain for workshop cleanup; underground areas below the supplied base are excluded.
