-- Disposable-world seeder for the stock VoxeLibre village tavern, well,
-- library and blacksmith.
-- Not part of the mod: copy into <world>/worldmods/stock_seed/ of a scratch
-- singlenode world (see tools/workshop_export/README.md, "Stock village
-- templates"), run the server once, then point export.py at that world with
-- --only tavern well library blacksmith.
--
-- The tavern gets the same furnishing Living Villages applies at village
-- generation (living_villages/tavern_schematic.lua); the change list below is
-- copied from there and must be kept equivalent. The library gets the lectern
-- of living_villages/library_schematic.lua. The stock blacksmith has no
-- Living Villages furnishing step and is placed as authored.
local base = core.get_modpath("mcl_villages") .. "/schematics/"
local TAVERN_POS = {x = 100, y = 7, z = 100} -- stock (0,0,0); floor layer y = 8
local WELL_POS = {x = 140, y = 7, z = 100}  -- stock (0,0,0); dirt layer y = 7
local LIBRARY_POS = {x = 180, y = 7, z = 100}   -- 12 x 9 x 12; dirt layer y = 7
local BLACKSMITH_POS = {x = 220, y = 7, z = 100} -- 8 x 8 x 11; dirt layer y = 7

local CHAIR_FACING = {["-z"] = 0, ["-x"] = 1, ["+z"] = 2, ["+x"] = 3}

local function furnish(schem)
	local size = schem.size
	assert(size.x == 12 and size.y == 13 and size.z == 10, "stock tavern layout changed")
	local function idx(x, y, z) return z * size.y * size.x + y * size.x + x + 1 end
	local changes = {
		{4, 2, 3, "mcl_fences:fence", "mcl_decor:table_wooden", 0},
		{5, 2, 7, "mcl_fences:fence", "mcl_decor:table_wooden", 0},
		{4, 3, 3, "mesecons_pressureplates:pressure_plate_wood_off", "mcl_itemframes:plate", 1},
		{5, 3, 7, "mesecons_pressureplates:pressure_plate_wood_off", "mcl_itemframes:plate", 1},
		{4, 2, 2, "mcl_stairs:stair_wood", "mcl_decor:chair_wooden", CHAIR_FACING["+z"]},
		{4, 2, 4, "mcl_stairs:stair_wood", "mcl_decor:chair_wooden", CHAIR_FACING["-z"]},
		{4, 2, 7, "mcl_stairs:stair_wood", "mcl_decor:chair_wooden", CHAIR_FACING["+x"]},
		{6, 2, 7, "mcl_stairs:stair_wood", "mcl_decor:chair_wooden", CHAIR_FACING["-x"]},
		{5, 2, 3, "air", "mcl_decor:table_wooden", 0},
		{5, 3, 3, "air", "mcl_itemframes:plate", 1},
		{5, 2, 2, "air", "mcl_decor:chair_wooden", CHAIR_FACING["+z"]},
		{5, 2, 4, "air", "mcl_decor:chair_wooden", CHAIR_FACING["-z"]},
		{5, 2, 6, "air", "mcl_decor:table_wooden", 0},
		{5, 3, 6, "air", "mcl_itemframes:plate", 1},
		{4, 2, 6, "air", "mcl_decor:chair_wooden", CHAIR_FACING["+x"]},
		{6, 2, 6, "air", "mcl_decor:chair_wooden", CHAIR_FACING["-x"]},
	}
	for _, c in ipairs(changes) do
		local cell = schem.data[idx(c[1], c[2], c[3])]
		assert(cell and cell.name == c[4], "stock tavern cell differs at " .. c[1] .. "," .. c[2] .. "," .. c[3])
	end
	for _, c in ipairs(changes) do
		schem.data[idx(c[1], c[2], c[3])] = {name = c[5], prob = 255, param2 = c[6]}
	end
	return schem
end

-- Same edit as living_villages/library_schematic.lua: the wooden stair in the
-- gap of the z 9 bookshelf wall becomes a lectern (the librarian's job site).
local function furnish_library(schem)
	local size = schem.size
	assert(size.x == 12 and size.y == 9 and size.z == 12, "stock library layout changed")
	local function idx(x, y, z) return z * size.y * size.x + y * size.x + x + 1 end
	local seat, above = schem.data[idx(6, 2, 9)], schem.data[idx(6, 3, 9)]
	assert(seat and seat.name == "mcl_stairs:stair_wood", "stock library seat differs")
	assert(above and above.name == "air", "stock library lectern headroom differs")
	schem.data[idx(6, 2, 9)] = {name = "mcl_lectern:lectern", prob = 255, param2 = 0}
	return schem
end

local function place(pos, schem)
	local size = schem.size
	assert(core.place_schematic(pos, schem, "0", nil, true))
	for z = 0, size.z - 1 do for y = 0, size.y - 1 do for x = 0, size.x - 1 do
		local p = vector.add(pos, {x = x, y = y, z = z})
		local name = core.get_node(p).name
		local def = core.registered_nodes[name]
		if name ~= "air" and def and def.on_construct then def.on_construct(p) end
	end end end
end

core.register_on_mods_loaded(function() core.after(0, function()
	local lo = {x = 90, y = 0, z = 90}
	local hi = {x = 240, y = 30, z = 120}
	core.emerge_area(lo, hi, function(_, action, remaining)
		core.log("action", "[stock_seed] emerge action " .. tostring(action) .. " remaining " .. tostring(remaining))
		if remaining ~= 0 then return end
		core.after(0, function()
			place(TAVERN_POS, furnish(core.read_schematic(base .. "tavern.mts", {})))
			place(WELL_POS, core.read_schematic(base .. "well.mts", {}))
			place(LIBRARY_POS, furnish_library(core.read_schematic(base .. "library.mts", {})))
			place(BLACKSMITH_POS, core.read_schematic(base .. "blacksmith.mts", {}))
			core.after(1, function() core.request_shutdown("stock village seeded", false, 0) end)
		end)
	end)
end) end)
