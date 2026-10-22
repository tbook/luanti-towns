-- Rotated walls (#166): VoxeLibre wall variants keep their connections in the
-- node name (mcl_walls "<base>_N"), and the engine rotates only param2, which
-- walls do not use. schematic.place must rename walls for the rotation.
-- Fake core and a small synthetic template; no .mts bytes are read.
local eq, schematic = ...

local saved_core, saved_vector = rawget(_G, "core"), rawget(_G, "vector")
local world, schem

local function key(p) return p.x .. "," .. p.y .. "," .. p.z end
local function is_wall(name) return name ~= nil and name:find("^mcl_walls:") ~= nil end

_G.vector = {add = function(a, b) return {x = a.x + b.x, y = a.y + b.y, z = a.z + b.z} end}
_G.core = {
	registered_nodes = {},
	read_schematic = function(path) return schem[path] end,
	place_schematic = function(pos, path, rotation)
		local s = schem[path]
		for z = 0, s.size.z - 1 do for y = 0, s.size.y - 1 do for x = 0, s.size.x - 1 do
			local n = s.nodes[x .. "," .. y .. "," .. z] or {name = "air", param2 = 0}
			local p = vector.add(pos, schematic.rotate_offset(s.size, {x = x, y = y, z = z}, rotation))
			world[key(p)] = {name = n.name, param2 = n.param2}
		end end end
		return true
	end,
	get_node = function(p) return world[key(p)] or {name = "air", param2 = 0} end,
	swap_node = function(p, node) world[key(p)] = {name = node.name, param2 = node.param2} end,
	get_item_group = function(name, group)
		if group == "wall" and is_wall(name) then return 1 end
		return 0
	end,
}

-- Name mapping. Bits: +X=1, +Z=2, -X=4, -Z=8; 16 and 21 are the straight
-- walls (5 and 10) with a tall neighbour above.
eq(schematic.rotate_wall_name("mcl_walls:cobble_5", 90), "mcl_walls:cobble_10", "straight X to Z")
eq(schematic.rotate_wall_name("mcl_walls:cobble_5", 270), "mcl_walls:cobble_10", "straight X to Z at 270")
eq(schematic.rotate_wall_name("mcl_walls:cobble_1", 90), "mcl_walls:cobble_8", "+X end at 90 points -Z")
eq(schematic.rotate_wall_name("mcl_walls:cobble_1", 270), "mcl_walls:cobble_2", "+X end at 270 points +Z")
eq(schematic.rotate_wall_name("mcl_walls:cobble_1", 180), "mcl_walls:cobble_4", "+X end at 180 points -X")
eq(schematic.rotate_wall_name("mcl_walls:cobble_16", 90), "mcl_walls:cobble_21", "tall straight keeps tall flag")
eq(schematic.rotate_wall_name("mcl_walls:cobble_21", 270), "mcl_walls:cobble_16", "tall Z back to X")
eq(schematic.rotate_wall_name("mcl_walls:cobble_0", 90), "mcl_walls:cobble_0", "post unchanged")
eq(schematic.rotate_wall_name("mcl_walls:cobble_5", 0), "mcl_walls:cobble_5", "rotation 0 unchanged")
eq(schematic.rotate_wall_name("mcl_walls:cobble", 90), "mcl_walls:cobble", "unsuffixed name unchanged")
eq(schematic.rotate_wall_name("mcl_core:stone", 90), "mcl_core:stone", "non-wall unchanged")
for n = 0, 15 do
	for _, r in ipairs({90, 180, 270}) do
		local name = "mcl_walls:diorite_" .. n
		eq(schematic.rotate_wall_name(schematic.rotate_wall_name(name, r), (360 - r) % 360), name,
			"round trip " .. n .. " at " .. r)
	end
end

-- Synthetic L-shaped wall, 4 (x) by 2 (y) by 3 (z), unrotated:
--   X arm at z=1: (0,1) +X end, (1,1) straight, (2,1) corner joining +Z
--   Z leg at x=2: (2,2) -Z end
--   tall straight wall (16) at (1,1,1) above the arm, and a stone node at (0,0,0).
-- Expected positions and names per rotation are worked out by hand from the
-- rotation mapping in geometry.lua (rel = relative to pos).
local size = {x = 4, y = 2, z = 3}
local template = {
	["0,0,1"] = {name = "mcl_walls:cobble_1", param2 = 0},
	["1,0,1"] = {name = "mcl_walls:cobble_5", param2 = 0},
	["2,0,1"] = {name = "mcl_walls:cobble_6", param2 = 0},
	["2,0,2"] = {name = "mcl_walls:cobble_8", param2 = 2},
	["1,1,1"] = {name = "mcl_walls:cobble_16", param2 = 0},
	["0,0,0"] = {name = "mcl_core:stone", param2 = 0},
}
local pos = {x = 100, y = 10, z = -20}
local entry = {id = "synthetic_l_wall", path = "synthetic_l_wall.mts"}
local modpath = "/m"
schem = {[modpath .. "/" .. entry.path] = {size = size, nodes = template}}

-- rotation -> list of {rel x, rel y, rel z, expected wall name}
local cases = {
	[0] = {{0, 0, 1, "mcl_walls:cobble_1"}, {1, 0, 1, "mcl_walls:cobble_5"},
		{2, 0, 1, "mcl_walls:cobble_6"}, {2, 0, 2, "mcl_walls:cobble_8"},
		{1, 1, 1, "mcl_walls:cobble_16"}},
	[90] = {{1, 0, 3, "mcl_walls:cobble_8"}, {1, 0, 2, "mcl_walls:cobble_10"},
		{1, 0, 1, "mcl_walls:cobble_3"}, {2, 0, 1, "mcl_walls:cobble_4"},
		{1, 1, 2, "mcl_walls:cobble_21"}},
	[180] = {{3, 0, 1, "mcl_walls:cobble_4"}, {2, 0, 1, "mcl_walls:cobble_5"},
		{1, 0, 1, "mcl_walls:cobble_9"}, {1, 0, 0, "mcl_walls:cobble_2"},
		{2, 1, 1, "mcl_walls:cobble_16"}},
	[270] = {{1, 0, 0, "mcl_walls:cobble_2"}, {1, 0, 1, "mcl_walls:cobble_10"},
		{1, 0, 2, "mcl_walls:cobble_12"}, {0, 0, 2, "mcl_walls:cobble_1"},
		{1, 1, 1, "mcl_walls:cobble_21"}},
}

for _, rotation in ipairs({0, 90, 180, 270}) do
	world = {}
	eq(schematic.place(entry, pos, rotation, modpath), true, rotation .. " placed")

	local walls = 0
	for _, n in pairs(world) do
		if is_wall(n.name) then walls = walls + 1 end
	end
	eq(walls, 5, rotation .. " wall count")

	for _, c in ipairs(cases[rotation]) do
		local n = world[key({x = pos.x + c[1], y = pos.y + c[2], z = pos.z + c[3]})]
		eq(n and n.name, c[4], rotation .. " wall at " .. c[1] .. "," .. c[2] .. "," .. c[3])
	end

	-- The stone and the -Z end's param2 are carried over, at their rotated places.
	local sp = schematic.rotate_offset(size, {x = 0, y = 0, z = 0}, rotation)
	eq(world[key({x = pos.x + sp.x, y = pos.y + sp.y, z = pos.z + sp.z})].name, "mcl_core:stone",
		rotation .. " non-wall untouched")
	local dp = schematic.rotate_offset(size, {x = 2, y = 0, z = 2}, rotation)
	eq(world[key({x = pos.x + dp.x, y = pos.y + dp.y, z = pos.z + dp.z})].param2, 2,
		rotation .. " param2 kept")

	-- Continuity on the ground row: each wall's connection bits point at
	-- walls, and every adjacent wall is connected, so the segment is one piece.
	local dirs = {{1, 0, 1}, {0, 1, 2}, {-1, 0, 4}, {0, -1, 8}}
	for k, n in pairs(world) do
		local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
		x, y, z = tonumber(x), tonumber(y), tonumber(z)
		if is_wall(n.name) and y == pos.y then
			local bits = tonumber(n.name:match("_(%d+)$"))
			for _, d in ipairs(dirs) do
				local q = world[(x + d[1]) .. "," .. y .. "," .. (z + d[2])]
				eq(q ~= nil and is_wall(q.name), bits % (d[3] * 2) >= d[3],
					rotation .. " connection at " .. k .. " bit " .. d[3])
			end
		end
	end
end

_G.core = saved_core
_G.vector = saved_vector
