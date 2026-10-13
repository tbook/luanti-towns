# Tower — raw Home capture

Source bounds: **(-135, 41, 314) through (-128, 91, 321)**, inclusive.
Size: **8 × 51 × 8**. Captured 2026-10-13 with Luanti 5.17.0 / VoxeLibre.
The supplied Y=92 layer was empty; X/Z bounds include the roof overhang.

This is an unedited copy in its original orientation, awaiting cleanup and
entrance selection in a flat test world. The base contains hillside dirt and
grass, and the interior stairs continue below the capture into the hillside.
Keep this raw file as a reference when preparing the standard template.

The JSON sidecar records local offsets and node metadata, including two open
doors and a chest containing a spyglass. MTS files do not restore that data
by themselves. Entities are not included.

Captured using the engine on a temporary SQLite backup opened read-only at
its source. Home was never launched by the capture process. All engine writes
were confined to /tmp/towns-tower-capture. Home's map database changed during
this work through another process; its world.mt and map_meta.txt stayed unchanged.

Placed in the temporary world and checked all **3,264 nodes** against the
source capture: node names and param2 matched, with zero ignore nodes.

Not yet registered in the Towns catalog; canonical entrance orientation and
foundation cleanup will be decided during editing.
