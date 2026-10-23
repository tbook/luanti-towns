-- The Roman checker's expected node names (tools/roman_check/expect.lua, #188)
-- must equal what schematic.place leaves on the map. Each Roman capture is read
-- from its real .mts and placed through the real schematic.place, with a fake
-- core whose place_schematic writes template names as the engine does and
-- whose item groups are the ones the real game reported.
local eq, schematic = ...

local read = dofile("tests/mts_reader.lua")
local expect = dofile("tools/roman_check/expect.lua")
local fixture = dofile("tests/wall_groups_fixture.lua")
local groups = {solid = {}, wall = {}, torch = {}}
for g, list in pairs(fixture) do for _, n in ipairs(list) do groups[g][n] = true end end
local wall_bases = {}
for n in pairs(groups.wall) do
	local base = n:match("^(.*_)%d+$")
	if base then wall_bases[base] = true end
end
local function in_group(group, name)
	if group == "wall" then
		local base = name:match("^(.*_)%d+$")
		return groups.wall[name] == true or (base ~= nil and wall_bases[base] == true)
	end
	return groups[group][name] == true
end

local saved_core, saved_vector = rawget(_G, "core"), rawget(_G, "vector")
local world, files = {}, {}
local function key(x, y, z) return x .. "," .. y .. "," .. z end
_G.vector = {add = function(a, b) return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z} end}
_G.core = {
	registered_nodes = {},
	read_schematic = function(path) return files[path] end,
	place_schematic = function(pos, path, rotation)
		local f = files[path]
		for z = 0, f.size.z - 1 do for y = 0, f.size.y - 1 do for x = 0, f.size.x - 1 do
			local o = schematic.rotate_offset(f.size, {x = x, y = y, z = z}, rotation)
			local name = f.data[z * f.size.x * f.size.y + y * f.size.x + x + 1].name
			world[key(pos.x + o.x, pos.y + o.y, pos.z + o.z)] = {name = name, param2 = 0}
		end end end
		return true
	end,
	get_node = function(p) return world[key(p.x, p.y, p.z)] or {name = "air", param2 = 0} end,
	swap_node = function(p, node) world[key(p.x, p.y, p.z)] = {name = node.name, param2 = node.param2} end,
	get_item_group = function(name, group)
		return groups[group] and in_group(group, name) and 1 or 0
	end,
}

local function load(id)
	local rel = "schematics/imports/roman/" .. id .. ".mts"
	local s = read(rel)
	local data = {}
	for z = 0, s.size.z - 1 do for y = 0, s.size.y - 1 do for x = 0, s.size.x - 1 do
		data[z * s.size.x * s.size.y + y * s.size.x + x + 1] = {name = (s.at(x, y, z))}
	end end end
	-- schematic.place reads "<modpath>/<entry.path>"; modpath is "." here.
	files["./" .. rel] = {size = s.size, data = data}
	return {id = id, path = rel}
end

local pos = {x = 100, y = 10, z = -20}
local renamed = 0
for _, id in ipairs({"amphitheater", "arch", "bath", "domus", "insula", "temple", "theatre", "vespasianum", "basilica"}) do
	local entry = load(id)
	local source = files["./" .. entry.path]
	for _, rotation in ipairs({0, 90, 180, 270}) do
		world = {}
		eq(schematic.place(entry, pos, rotation, ".", {initialize = false}), true, id .. " placed at " .. rotation)
		local expected = expect.expected_names(source, rotation, schematic)
		local mismatched, raw_differs = 0, 0
		for z = 0, source.size.z - 1 do for y = 0, source.size.y - 1 do for x = 0, source.size.x - 1 do
			local o = schematic.rotate_offset(source.size, {x = x, y = y, z = z}, rotation)
			local placed = world[key(pos.x + o.x, pos.y + o.y, pos.z + o.z)].name
			local template = source.data[z * source.size.x * source.size.y + y * source.size.x + x + 1].name
			if placed ~= expected[expect.key(o)] then mismatched = mismatched + 1 end
			if placed ~= template then raw_differs = raw_differs + 1 end
		end end end
		eq(mismatched, 0, id .. " rot " .. rotation .. " expected names match placement")
		renamed = renamed + raw_differs
	end
end
-- The check is not vacuous: placement really renames walls, so raw template
-- names would have failed (the amphitheater and arch fail that way).
assert(renamed > 0, "placement changed no template name")

_G.core, _G.vector = saved_core, saved_vector
