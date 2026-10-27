-- Issue #227: the copied rural schematics and their measured catalog data.
local eq, geometry, catalog, placement, planner, builder_factory = ...
local assets = dofile("schematics/outskirts/catalog.lua")
local read = dofile("tests/mts_reader.lua")
local schematic = dofile("src/schematic.lua")

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
eq(assets.farm.size.x, 17, "farm width")
eq(assets.farm.size.y, 2, "farm height")
eq(assets.farm.size.z, 13, "farm depth")
eq(assets.farm.ground_offset, 0, "farm field sits at finished ground level")
local water, wet, wheat, carrots, potatoes = find(farm, "mcl_core:water_source"),
	find(farm, "mcl_farming:soil_wet"), find(farm, "mcl_farming:wheat"),
	find(farm, "mcl_farming:carrot"), find(farm, "mcl_farming:potato")
eq(#water, 4, "farm has one irrigation source per bed")
eq(#wet, 188, "farm has 188 planted farmland blocks")
eq(#wheat, 94, "two farm beds are planted with wheat")
eq(#carrots, 47, "one farm bed is planted with carrots")
eq(#potatoes, 47, "one farm bed is planted with potatoes")
local bed_origins = {{x=0,z=0,crop="mcl_farming:wheat"}, {x=9,z=0,crop="mcl_farming:wheat"},
	{x=0,z=7,crop="mcl_farming:carrot"}, {x=9,z=7,crop="mcl_farming:potato"}}
for _, bed in ipairs(bed_origins) do
	local source
	for _, p in ipairs(water) do
		if p.x >= bed.x and p.x < bed.x + 8 and p.z >= bed.z and p.z < bed.z + 6 then source = p end
	end
	eq(source ~= nil, true, "each bed has a central water source")
	local plants = 0
	for z = bed.z, bed.z + 5 do for x = bed.x, bed.x + 7 do
		if x == source.x and z == source.z then
			eq(farm.at(x, 0, z), "mcl_core:water_source", "bed center is water")
		else
			eq(farm.at(x, 0, z), "mcl_farming:soil_wet", "bed is farmland")
			eq(farm.at(x, 1, z), bed.crop, "bed crop matches its planting")
			plants = plants + 1
		end
		if farm.at(x, 0, z) == "mcl_farming:soil_wet" then
			eq(math.abs(x-source.x) <= 4 and math.abs(z-source.z) <= 4,
				true, "each farmland block is within irrigation range")
		end
	end end
	eq(plants, 47, "bed has 47 planted blocks")
end
for i, p in ipairs({{8,5},{7,6},{9,6},{8,7}}) do
	eq(farm.at(p[1], 0, p[2]), "mcl_core:dirt", "path stays open beside composter " .. i)
	eq(farm.at(p[1], 1, p[2]), "air", "path has standing room beside composter " .. i)
end
eq(farm.at(8, 0, 6), "mcl_core:dirt", "composter replaces the central path block")
eq(farm.at(8, 1, 6), "mcl_composters:composter", "composter is above the path")
eq(#find(farm, "mcl_doors:wooden_door_b_1"), 0, "farm has no door")
eq(#find(farm, "mcl_beds:bed_red_bottom"), 0, "farm has no bed")
eq(farm.at(0, 0, 0), "mcl_farming:soil_wet", "farm farmland is at the finished ground level")
eq(assets.farm.entrance, nil, "farm has no entrance")
for _, rotation in ipairs(geometry.ROTATIONS) do
	local placed = geometry.place({size=assets.farm.size, entrance={x=0,y=0,z=0}},
		{x=0,y=0,z=0}, rotation)
	local odd_rotation = rotation == 90 or rotation == 270
	eq(placed.max.x - placed.min.x + 1, odd_rotation and 13 or 17, "rotated farm width " .. rotation)
	eq(placed.max.z - placed.min.z + 1, odd_rotation and 17 or 13, "rotated farm depth " .. rotation)
	local rotated, rotated_water, rotated_soil, rotated_compost = {}, {}, {}, {}
	for z = 0, farm.size.z - 1 do for y = 0, farm.size.y - 1 do for x = 0, farm.size.x - 1 do
		local name = farm.at(x, y, z)
		if name ~= "air" then
			local q = schematic.rotate_offset(farm.size, {x=x,y=y,z=z}, rotation)
			rotated[q.x .. "," .. q.y .. "," .. q.z] = name
			if name == "mcl_core:water_source" then rotated_water[#rotated_water+1] = q end
			if name == "mcl_farming:soil_wet" then rotated_soil[#rotated_soil+1] = q end
			if name == "mcl_composters:composter" then rotated_compost[#rotated_compost+1] = q end
		end
	end end end
	eq(#rotated_water, 4, "rotation preserves four irrigation sources " .. rotation)
	eq(#rotated_soil, 188, "rotation preserves all planted farmland " .. rotation)
	eq(#rotated_compost, 1, "rotation preserves one composter " .. rotation)
	for _, p in ipairs(rotated_soil) do
		local irrigated = false
		for _, w in ipairs(rotated_water) do
			if math.abs(p.x-w.x) <= 4 and math.abs(p.z-w.z) <= 4 then irrigated = true end
		end
		eq(irrigated, true, "rotated farmland remains within irrigation range " .. rotation)
	end
	for i, p in ipairs({{8,5},{7,6},{9,6},{8,7}}) do
		local q = schematic.rotate_offset(farm.size, {x=p[1],y=0,z=p[2]}, rotation)
		eq(rotated[q.x .. ",0," .. q.z], "mcl_core:dirt", "rotated path at composter " .. rotation .. "/" .. i)
		eq(rotated[q.x .. ",1," .. q.z], nil, "rotated path clearance at composter " .. rotation .. "/" .. i)
	end
end

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
