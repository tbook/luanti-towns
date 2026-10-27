-- Issue #227: the copied rural schematics and their measured catalog data.
local eq, geometry, catalog, placement, planner, builder_factory = ...
local assets = dofile("schematics/outskirts/catalog.lua")
local read = dofile("tests/mts_reader.lua")

local farm = read(assets.farm.path)
local hut = read(assets.shepherd_hut.path)
local villa = read(assets.villa.path)
local function same_size(s, e, label)
	eq(s.size.x, e.size.x, label .. " width")
	eq(s.size.y, e.size.y, label .. " height")
	eq(s.size.z, e.size.z, label .. " depth")
end
same_size(farm, assets.farm, "farm")
same_size(hut, assets.shepherd_hut, "shepherd hut")
same_size(villa, assets.villa, "Roman villa")
local farm_data = dofile(assets.farm.data_path)
local hut_data = dofile(assets.shepherd_hut.data_path)
local demo_data = dofile(catalog.get("demo_house").data_path)
eq(type(farm_data.metadata), "table", "farm has a refreshable metadata sidecar")
eq(type(farm_data.required_nodes), "table", "farm sidecar lists required nodes")
local function has_closed_door(data)

	for _, saved in ipairs(data.metadata or {}) do
		if saved.name == "mcl_doors:wooden_door_b_1" and saved.fields
				and saved.fields.is_open == "0" then return true end
	end
	return false
end
eq(has_closed_door(hut_data), true, "hut sidecar preserves closed door state")
eq(has_closed_door(demo_data), true, "demo house sidecar preserves closed door state")

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
eq(farm.at(0, 0, 0) == "mcl_core:dirt" or farm.at(0, 0, 0) == "mcl_core:dirt_with_grass",
	true, "farm ground row has soil")
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
eq(hut.at(0, 0, 0) == "mcl_core:dirt" or hut.at(0, 0, 0) == "mcl_core:dirt_with_grass",
	true, "hut ground row has soil")
eq(hut.at(assets.shepherd_hut.entrance.x, assets.shepherd_hut.entrance.y,
	assets.shepherd_hut.entrance.z - 1), "air", "hut door faces canonical -Z")

-- Rural entries are not imported into any urban catalog or profile.
for _, id in ipairs({"farm", "shepherd_hut", "villa"}) do
	eq(catalog.entries[id], nil, id .. " absent from urban entries")
	eq(catalog.snapshot()[id], nil, id .. " absent from urban snapshot")
end
local profile = assert(planner.landmark_profile(catalog.snapshot()))
for _, id in ipairs({"farm", "shepherd_hut", "villa"}) do
	eq(profile.content[id], nil, id .. " absent from urban role pools")
end

-- The villa reuses the Roman import and sidecar, but is an outskirts class.
eq(assets.villa.class, "villa", "villa outskirts class")
eq(assets.villa.path, "schematics/imports/roman/villa.mts", "villa reuses the Roman capture")
eq(assets.villa.data_path, "schematics/imports/roman/villa.lua", "villa reuses Roman metadata")
eq(assets.villa.ground_offset, 0, "villa ground row is row 0")
eq(villa.at(0, 0, 0):find("dirt", 1, true) ~= nil, true, "villa retains its dirt ground row")
eq(assets.villa.entrance.x, 26, "villa main entrance x")
eq(assets.villa.entrance.y, 2, "villa main entrance y")
eq(assets.villa.entrance.z, 22, "villa main entrance z")
eq(assets.villa.entrance.facing, "+Z", "villa main entrance faces the courtyard")
eq(villa.at(26, 2, 22), "mcl_doors:wooden_door_b_1", "villa main entrance is the real door")
eq(villa.at(26, 3, 22), "mcl_doors:wooden_door_t_1", "villa main entrance has its upper door")
eq(villa.at(26, 2, 23), "air", "villa courtyard side of the entrance is open")
eq(villa.at(26, 1, 23) ~= "air", true, "villa courtyard has ground under the approach")
local villa_data = dofile(assets.villa.data_path)
eq(type(villa_data.metadata), "table", "villa saved metadata is readable")
eq(type(villa_data.required_nodes), "table", "villa required node list is readable")

-- Exercise the real rural footprints and doors with the shared door walker
-- after each schematic rotation.
local function check_door_routes(entry, schematic, label)
	local builder = builder_factory(placement, planner)
	local origin, ground = {x = 100, y = 20, z = 100}, 20
	local function rotated(x, z, rotation)
		if rotation == 0 then return x, z end
		if rotation == 90 then return z, schematic.size.x - 1 - x end
		if rotation == 180 then return schematic.size.x - 1 - x, schematic.size.z - 1 - z end
		return schematic.size.z - 1 - z, x
	end
	for _, rotation in ipairs(geometry.ROTATIONS) do
		local placed = geometry.place(entry, origin, rotation)
		local rect = {x1 = placed.min.x, z1 = placed.min.z,
			x2 = placed.max.x, z2 = placed.max.z}
		local cells = {}
		for z = 0, schematic.size.z - 1 do for y = 0, schematic.size.y - 1 do for x = 0, schematic.size.x - 1 do
			local wx, wz = rotated(x, z, rotation)
			cells[(origin.x + wx) .. "," .. (origin.y + y) .. "," .. (origin.z + wz)] = schematic.at(x, y, z)
		end end end
		local st = {rect = rect, min = placed.min, max = placed.max, rotation = rotation,
			entrance = placed.entrance, front = placed.front}
		local function node(x, y, z)
			local name = cells[x .. "," .. y .. "," .. z]
			if name == nil and y <= ground then name = "mcl_core:stone" end
			if name == nil or name == "air" then return {walkable = false}, "air" end
			if name:find("^mcl_doors:") then return {walkable = true, door = true}, name end
			if name:find("water", 1, true) then return {walkable = false, liquid = true}, name end
			if name:find("^mcl_flowers:") or name:find("^mcl_torches:")
					or name:find("^mcl_lanterns:") or name:find("^mcl_itemframes:") then
				return {walkable = false}, name
			end
			return {walkable = true}, name
		end
		local route, why = builder.check_door(st, ground, node)
		eq(route ~= nil, true, label .. " door reachable at " .. rotation .. ": " .. tostring(why))
		if route then
			eq(route.approach.x < rect.x1 or route.approach.x > rect.x2
				or route.approach.z < rect.z1 or route.approach.z > rect.z2,
				true, label .. " approach is outside the footprint at " .. rotation)
		end
	end
end
check_door_routes(assets.shepherd_hut, hut, "copied hut")
check_door_routes(assets.villa, villa, "real villa")
