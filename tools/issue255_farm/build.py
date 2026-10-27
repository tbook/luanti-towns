#!/usr/bin/env python3
"""Rebuild the authored farm field schematic for issue #255."""
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "schematics/outskirts/farm.mts"
SIZE = (17, 2, 13)
sx, sy, sz = SIZE
nodes = {}


def put(x, y, z, name):
	assert 0 <= x < sx and 0 <= y < sy and 0 <= z < sz
	nodes[x, y, z] = name


# Dirt paths form a one-node cross. The composter sits above their intersection.
for z in range(sz):
	put(8, 0, z, "mcl_core:dirt")
for x in range(sx):
	put(x, 0, 6, "mcl_core:dirt")

# Four 8 x 6 beds with one source near each center. Each source replaces one
# farmland node, leaving 47 planted cells in each bed.
beds = (
	(0, 0, 3, 2, "mcl_farming:wheat"),
	(9, 0, 12, 2, "mcl_farming:wheat"),
	(0, 7, 3, 9, "mcl_farming:carrot"),
	(9, 7, 12, 9, "mcl_farming:potato"),
)
for x0, z0, wx, wz, crop in beds:
	for z in range(z0, z0 + 6):
		for x in range(x0, x0 + 8):
			if (x, z) == (wx, wz):
				put(x, 0, z, "mcl_core:water_source")
			else:
				put(x, 0, z, "mcl_farming:soil_wet")
				put(x, 1, z, crop)
put(8, 1, 6, "mcl_composters:composter")

names = sorted({"air", *nodes.values()})
ids = {name: i for i, name in enumerate(names)}
ordered = [nodes.get((x, y, z), "air")
	for z in range(sz) for y in range(sy) for x in range(sx)]
raw = b"".join(struct.pack(">H", ids[name]) for name in ordered)
raw += bytes([127]) * len(ordered)  # Deterministic node placement probability.
raw += bytes(len(ordered))  # No facedir or other param2 data is needed.

header = b"MTSM" + struct.pack(">4H", 4, sx, sy, sz) + bytes([127]) * sy
header += struct.pack(">H", len(names))
for name in names:
	encoded = name.encode("utf-8")
	header += struct.pack(">H", len(encoded)) + encoded
OUTPUT.write_bytes(header + zlib.compress(raw, 9))
print(f"Wrote {OUTPUT.relative_to(ROOT)}: {sx} x {sy} x {sz}")
