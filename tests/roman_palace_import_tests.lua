-- Roman palace import (#439): the palace is catalogued from TownsWorkshop as an
-- import only. It has no role, so no planner or town type selects it, and its
-- walk-in entrance is a clear opening in the north portico.
local eq, catalog = ...
local read_mts = dofile("tests/mts_reader.lua")
local entry = catalog.get("roman_palace")
eq(entry ~= nil, true, "roman palace is catalogued")
if not entry then return end

eq(entry.role, nil, "roman palace has no role (import only, never selected by a planner)")
eq(entry.size.x, 62, "palace width")
eq(entry.size.y, 15, "palace height (ground row to roof)")
eq(entry.size.z, 52, "palace depth")
eq(entry.entrance.x, 28, "palace entrance x (north portico, centre)")
eq(entry.ground_offset or 0, 0, "palace keeps its ground row as row 0")
eq(entry.entrance.y, 2, "palace entrance one node above the floor (floor row 1)")
eq(entry.entrance.z, 2, "palace entrance z (the north wall, world Z 501)")
eq(entry.entrance_kind, "opening", "palace entrance is a walk-in opening")
eq(entry.path, "schematics/templates/roman_palace.mts", "palace schematic path")
eq(entry.data_path, "schematics/templates/roman_palace.lua", "palace metadata path")

local schematic = read_mts("schematics/templates/roman_palace.mts")
eq(schematic.size.x, entry.size.x, "schematic width matches the catalog")
eq(schematic.size.y, entry.size.y, "schematic height matches the catalog")
eq(schematic.size.z, entry.size.z, "schematic depth matches the catalog")

-- The opening needs two clear air nodes over a solid floor (the exporter's rule).
local e = entry.entrance
eq(schematic.at(e.x, e.y, e.z), "air", "palace opening is clear at the entrance")
eq(schematic.at(e.x, e.y + 1, e.z), "air", "palace opening is clear above the entrance")
eq(schematic.at(e.x, e.y - 1, e.z) ~= "air", true, "palace opening has a floor below")
eq(schematic.at(e.x, 0, e.z) ~= "air", true, "palace opening stands on the retained ground row")
