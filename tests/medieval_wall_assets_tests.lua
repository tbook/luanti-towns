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
