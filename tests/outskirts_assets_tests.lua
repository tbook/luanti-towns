-- Issue #227: the copied rural schematics and their measured catalog data.
local eq, geometry, catalog, placement, planner, builder_factory = ...
local assets = dofile("schematics/outskirts/catalog.lua")
local read = dofile("tests/mts_reader.lua")

local farm = read(assets.farm.path)
local hut = read(assets.shepherd_hut.path)
local function same_size(s, e, label)
	eq(s.size.x, e.size.x, label .. " width")
	eq(s.size.y, e.size.y, label .. " height")
	eq(s.size.z, e.size.z, label .. " depth")
end
same_size(farm, assets.farm, "farm")
same_size(hut, assets.shepherd_hut, "shepherd hut")

local function find(s, name)
	local found = {}
	for z = 0, s.size.z - 1 do for y = 0, s.size.y - 1 do for x = 0, s.size.x - 1 do
		if s.at(x, y, z) == name then found[#found + 1] = {x = x, y = y, z = z} end
	end end end
	return found
end
local composter = find(farm, "mcl_composters:composter")
eq(#composter, 1, "farm has one composter")
eq(composter[1] and composter[1].x == assets.farm.composter.x
	and composter[1].y == assets.farm.composter.y and composter[1].z == assets.farm.composter.z,
	true, "farm composter position")
eq(#find(farm, "mcl_doors:wooden_door_b_1"), 0, "farm has no door")
eq(#find(farm, "mcl_beds:bed_red_bottom"), 0, "farm has no bed")
eq(farm.at(0, 0, 0), "mcl_core:dirt", "farm keeps dirt ground row")
eq(assets.farm.entrance, nil, "farm has no entrance")

local doors = find(hut, "mcl_doors:wooden_door_b_1")
local looms = find(hut, "mcl_loom:loom")
local beds = find(hut, "mcl_beds:bed_red_bottom")
local function at(p, q, label)
	eq(#p, 1, "hut has one " .. label)
	eq(p[1] and p[1].x == q.x and p[1].y == q.y and p[1].z == q.z,
		true, "hut " .. label .. " position")
end
at(doors, assets.shepherd_hut.entrance, "door")
at(looms, assets.shepherd_hut.loom, "loom")
at(beds, assets.shepherd_hut.bed, "bed")
eq(assets.shepherd_hut.ground_offset, 0, "hut dirt layer is ground row")
eq(hut.at(0, 0, 0), "mcl_core:dirt", "hut keeps dirt ground row")
eq(hut.at(assets.shepherd_hut.entrance.x, assets.shepherd_hut.entrance.y,
	assets.shepherd_hut.entrance.z - 1), "air", "hut door faces canonical -Z")

-- Rural entries are not imported into any urban catalog or profile.
for _, id in ipairs({"farm", "shepherd_hut"}) do
	eq(catalog.entries[id], nil, id .. " absent from urban entries")
	eq(catalog.snapshot()[id], nil, id .. " absent from urban snapshot")
end
local profile = assert(planner.landmark_profile(catalog.snapshot()))
for _, id in ipairs({"farm", "shepherd_hut"}) do
	eq(profile.content[id], nil, id .. " absent from urban role pools")
end

-- Exercise the real copied hut footprint and door with the shared door walker
-- after each schematic rotation.
do
	local builder = builder_factory(placement, planner)
	local origin, ground = {x = 100, y = 20, z = 100}, 20
	local function rotated(x, z, r)
		if r == 0 then return x, z end
		if r == 90 then return z, hut.size.x - 1 - x end
		if r == 180 then return hut.size.x - 1 - x, hut.size.z - 1 - z end
		return hut.size.z - 1 - z, x
	end
	for _, rotation in ipairs(geometry.ROTATIONS) do
		local placed = geometry.place(assets.shepherd_hut, origin, rotation)
		local rect = {x1 = placed.min.x, z1 = placed.min.z,
			x2 = placed.max.x, z2 = placed.max.z}
		local cells = {}
		for z = 0, hut.size.z - 1 do for y = 0, hut.size.y - 1 do for x = 0, hut.size.x - 1 do
			local wx, wz = rotated(x, z, rotation)
			cells[(origin.x + wx) .. "," .. (origin.y + y) .. "," .. (origin.z + wz)] = hut.at(x, y, z)
		end end end
		local st = {rect = rect, min = placed.min, max = placed.max, rotation = rotation,
			entrance = placed.entrance, front = placed.front}
		local function node(x, y, z)
			local name = cells[x .. "," .. y .. "," .. z]
			if name == nil and y <= ground then name = "mcl_core:stone" end
			if name == nil or name == "air" then return {walkable = false}, "air" end
			if name:find("^mcl_doors:") then return {walkable = true, door = true}, name end
			return {walkable = true}, name
		end
		local route, why = builder.check_door(st, ground, node)
		eq(route ~= nil, true, "copied hut door reachable at " .. rotation .. ": " .. tostring(why))
	end
end
