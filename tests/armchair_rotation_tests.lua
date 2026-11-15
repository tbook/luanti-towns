-- Armchairs in rotated buildings (#444). mcl_decor armchairs are 4dir nodes
-- whose shape is chosen by the node NAME (armchair_<color>, armchair_1_..,
-- _2_, _3_: the chair turned N quarter turns). core.place_schematic rotates
-- positions (and param2), never names, so a rotated building kept every
-- armchair facing its unrotated way. schematic.place now advances the variant
-- by rotation / 90 along with param2.
local eq, schematic = ...

eq(schematic.turn_armchair("mcl_decor:armchair_red", 0), "mcl_decor:armchair_red", "no turn")
eq(schematic.turn_armchair("mcl_decor:armchair_red", 1), "mcl_decor:armchair_1_red", "0 -> 1")
eq(schematic.turn_armchair("mcl_decor:armchair_red", 3), "mcl_decor:armchair_3_red", "0 -> 3")
eq(schematic.turn_armchair("mcl_decor:armchair_3_red", 1), "mcl_decor:armchair_red", "3 wraps to 0")
eq(schematic.turn_armchair("mcl_decor:armchair_2_light_blue", 3), "mcl_decor:armchair_1_light_blue", "underscored color")
eq(schematic.turn_armchair("mcl_decor:armchair_light_blue", 2), "mcl_decor:armchair_2_light_blue", "underscored color, base")
eq(schematic.turn_armchair("mcl_decor:chair_spruce", 1), "mcl_decor:chair_spruce", "other chairs untouched")

local saved_core, saved_vector = rawget(_G, "core"), rawget(_G, "vector")
local world = {}
local function key(x, y, z) return x .. "," .. y .. "," .. z end
-- A 3x1x2 schematic: a facedir chair, a base armchair, an armchair_2 whose
-- stored param2 disagrees with its variant (castle template), and stone.
local size = {x = 3, y = 1, z = 2}
local nodes = {
	{name = "mcl_decor:chair_spruce", param2 = 1}, {name = "mcl_decor:armchair_white", param2 = 0}, {name = "mcl_decor:armchair_2_purple", param2 = 3},
	{name = "mcl_core:stone", param2 = 0}, {name = "mcl_decor:armchair_3_blue", param2 = 3}, {name = "air", param2 = 0},
}
local data = {}
for i, n in ipairs(nodes) do data[i] = {name = n.name, param1 = 0, param2 = n.param2} end
_G.vector = {add = function(a, b) return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z} end}
_G.core = {
	registered_nodes = {},
	read_schematic = function() return {size = size, data = data} end,
	place_schematic = function(pos, _, rotation)
		for z = 0, size.z - 1 do for x = 0, size.x - 1 do
			local n = data[z * size.x + x + 1]
			local o = schematic.rotate_offset(size, {x = x, y = 0, z = z}, rotation)
			-- The engine moves nodes and rotates facedir/4dir param2, never names.
			local p2 = n.param2
			if n.name:find("chair") then p2 = (p2 + tonumber(rotation) / 90) % 4 end
			world[key(pos.x + o.x, pos.y + o.y, pos.z + o.z)] = {name = n.name, param2 = p2}
		end end
		return true
	end,
	get_node = function(p) return world[key(p.x, p.y, p.z)] or {name = "air", param2 = 0} end,
	swap_node = function(p, node) world[key(p.x, p.y, p.z)] = {name = node.name, param2 = node.param2} end,
	get_item_group = function() return 0 end,
}
-- The mod's modpath is irrelevant: schematic.validate reads the data file.
local entry = {id = "fake", path = "fake.mts"}
local real_validate = schematic.validate
schematic.validate = function() return true end

local pos = {x = 10, y = 5, z = 10}
for _, rotation in ipairs({0, 90, 180, 270}) do
	world = {}
	eq(schematic.place(entry, pos, rotation, "/m", {initialize = false}), true, "placed at " .. rotation)
	local turns = rotation / 90
	for z = 0, size.z - 1 do for x = 0, size.x - 1 do
		local src = data[z * size.x + x + 1]
		local o = schematic.rotate_offset(size, {x = x, y = 0, z = z}, rotation)
		local got = world[key(pos.x + o.x, pos.y + o.y, pos.z + o.z)]
		if src.name:find("^mcl_decor:armchair") then
			eq(got.name, schematic.turn_armchair(src.name, turns), src.name .. " variant at " .. rotation)
			eq(got.param2, (src.param2 + turns) % 4, src.name .. " param2 at " .. rotation)
		elseif src.name ~= "air" then
			eq(got.name, src.name, src.name .. " name kept at " .. rotation)
		end
	end end
end
-- Spot checks of the table above.
world = {}
schematic.place(entry, pos, 90, "/m", {initialize = false})
local o = schematic.rotate_offset(size, {x = 1, y = 0, z = 0}, 90)
eq(world[key(pos.x + o.x, pos.y, pos.z + o.z)].name, "mcl_decor:armchair_1_white", "base armchair faces +1 at 90")

schematic.validate = real_validate
_G.core = saved_core
_G.vector = saved_vector
