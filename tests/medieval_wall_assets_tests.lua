-- Medieval inline tower capture (#276): the full foundation is kept below
-- finished ground, and both straight wall tie-ins match the generated core.
local eq, catalog, geometry = ...
local read_mts = dofile("tests/mts_reader.lua")
local entry = catalog.get("wall_tower_inline")
eq(entry ~= nil, true, "inline wall tower is catalogued")
if not entry then return end

eq(entry.size.x, 7, "inline tower width")
eq(entry.size.y, 17, "inline tower height with foundation")
eq(entry.size.z, 7, "inline tower depth")
eq(entry.ground_offset, 1, "inline tower retains one foundation row below finished ground")
eq(entry.entrance.x, 4, "inline tower entrance x")
eq(entry.entrance.y, 2, "inline tower entrance file y")
eq(entry.entrance.z, 1, "inline tower entrance z")
eq(entry.entrance.y - entry.ground_offset, 1,
	"inline tower entrance is one node above finished ground")

local schematic = read_mts("schematics/templates/wall_tower_inline.mts")
eq(schematic.at(entry.entrance.x, entry.entrance.y, entry.entrance.z):find("_door_b_", 1, true) ~= nil,
	true, "inline tower selected entrance is its lower door")
eq(schematic.at(entry.entrance.x, entry.ground_offset, entry.entrance.z), "mcl_core:cobble",
	"inline tower entrance floor is retained at finished ground")

-- medieval_walls.inspect builds its core from ground+1 through ground+4.
-- The sample's two end stubs must fill those same levels on the centerline.
for _, z in ipairs({0, entry.size.z - 1}) do
	for dy = 1, 4 do
		local y = entry.ground_offset + dy
		eq(schematic.at(3, y, z), "mcl_core:stonebrick",
			("inline tower wall join at x=3, ground+%d, z=%d"):format(dy, z))
	end
end

-- The authored file's y=0 foundation is placed one node below the town datum.
local bounds = geometry.place(entry, {x = 100, y = 39, z = 100}, 0)
eq(bounds.min.y + entry.ground_offset, 40,
	"inline tower ground datum aligns with the generated wall's town ground")

-- The alternate furnishings (#343) share the primary tower's shape, entrance
-- and foundation, so the planner can swap one asset id for the other.
local alt = catalog.get("wall_tower_inline_alt")
eq(alt ~= nil, true, "alternate inline wall tower is catalogued")
if not alt then return end
eq(alt.size.x, entry.size.x, "alternate inline tower width matches the primary")
eq(alt.size.y, entry.size.y, "alternate inline tower height matches the primary")
eq(alt.size.z, entry.size.z, "alternate inline tower depth matches the primary")
eq(alt.ground_offset, entry.ground_offset, "alternate inline tower foundation matches the primary")
eq(alt.entrance.x, entry.entrance.x, "alternate inline tower entrance x matches the primary")
eq(alt.entrance.y, entry.entrance.y, "alternate inline tower entrance y matches the primary")
eq(alt.entrance.z, entry.entrance.z, "alternate inline tower entrance z matches the primary")
local alt_schematic = read_mts("schematics/templates/wall_tower_inline_alt.mts")
eq(alt_schematic.size.x, schematic.size.x, "alternate schematic width matches the primary")
eq(alt_schematic.size.y, schematic.size.y, "alternate schematic height matches the primary")
eq(alt_schematic.size.z, schematic.size.z, "alternate schematic depth matches the primary")
eq(alt_schematic.at(alt.entrance.x, alt.entrance.y, alt.entrance.z):find("_door_b_", 1, true) ~= nil,
	true, "alternate inline tower selected entrance is its lower door")
for _, z in ipairs({0, alt.size.z - 1}) do
	for dy = 1, 4 do
		local y = alt.ground_offset + dy
		eq(alt_schematic.at(3, y, z), "mcl_core:stonebrick",
			("alternate inline tower wall join at x=3, ground+%d, z=%d"):format(dy, z))
	end
end

local gate = read_mts("schematics/templates/wall_gatehouse.mts")
for x = 6, 9 do
	for z = 0, 8 do
		for y = 1, 3 do
			eq(gate.at(x, y, z), "air", "gate has a four-wide clear passage throughout its capture")
		end
	end
end

-- The secondary-road postern keeps its one-node foundation and two-leaf
-- passage. The catalog entrance selects the first door leaf, while both sides
-- of the gate retain two nodes of clear approach and headroom.
local postern_entry = catalog.get("wall_postern")
eq(postern_entry.size.x, 3, "postern wall depth")
eq(postern_entry.size.y, 8, "postern height with foundation")
eq(postern_entry.size.z, 10, "postern width with shoulders")
eq(postern_entry.ground_offset, 1, "postern retains one foundation layer below ground")
eq(postern_entry.entrance.y - postern_entry.ground_offset, 1,
	"postern passage is one node above finished ground")
local postern = read_mts("schematics/templates/wall_postern.mts")
eq(postern.at(postern_entry.entrance.x, postern_entry.entrance.y,
	postern_entry.entrance.z):find("_door_b_", 1, true) ~= nil, true,
	"postern catalog entrance selects a lower gate door")
for z = 6, 7 do
	eq(postern.at(1, 2, z):find("_door_b_", 1, true) ~= nil, true,
		"postern keeps the two-leaf passage door at z=" .. z)
	eq(postern.at(1, 3, z):find("_door_t_", 1, true) ~= nil, true,
		"postern keeps the upper passage door at z=" .. z)
	for _, x in ipairs({0, 2}) do
		for y = 2, 3 do
			eq(postern.at(x, y, z), "air",
				("postern approach clear at x=%d, y=%d, z=%d"):format(x, y, z))
		end
	end
end
local _, postern_door_facing = postern.at(1, 2, 6)
eq(postern_door_facing, 3, "postern door faces local -X in the authored schematic")
