-- Walls in placed buildings (#166). VoxeLibre walls (mcl_walls) keep their
-- connections in the node name ("<base>_N"), and nothing but a player placing
-- or digging a node refreshes them. Two things broke them in generated towns:
--   * core.place_schematic rotates only param2, never names (confirmed against
--     a real Luanti 5.17 server with mineclone2 0.92.3), so a rotated wall
--     kept the connections of the unrotated template;
--   * templates exported with a rotation by tools/workshop_export went through
--     that same unrotated-name rotation, so castle, cathedral, tower and
--     tavern shipped with connection names that match no geometry at all.
-- schematic.place therefore recomputes each wall's name from its placed
-- neighbours (schematic.wall_name). These tests run the real .mts files
-- through a fake core whose place_schematic behaves like the engine (nodes
-- move, names stay) and whose item groups are the ones the real game reported
-- (tests/wall_groups_fixture.lua).
local eq, schematic = ...

local read = dofile("tests/mts_reader.lua")
local fixture = dofile("tests/wall_groups_fixture.lua")
local groups = {solid = {}, wall = {}, torch = {}}
for g, list in pairs(fixture) do for _, n in ipairs(list) do groups[g][n] = true end end
-- A wall variant name that no template happens to use (a recomputed
-- connection set) is still a wall: every "<base>_N" of a known base is.
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
	read_schematic = function(path) return {size = files[path].size} end,
	place_schematic = function(pos, path, rotation)
		local f = files[path]
		for z = 0, f.size.z - 1 do for y = 0, f.size.y - 1 do for x = 0, f.size.x - 1 do
			local name, param2 = f.at(x, y, z)
			local o = schematic.rotate_offset(f.size, {x = x, y = y, z = z}, rotation)
			world[key(pos.x + o.x, pos.y + o.y, pos.z + o.z)] = {name = name, param2 = param2}
		end end end
		return true
	end,
	get_node = function(p) return world[key(p.x, p.y, p.z)] or {name = "air", param2 = 0} end,
	swap_node = function(p, node) world[key(p.x, p.y, p.z)] = {name = node.name, param2 = node.param2} end,
	get_item_group = function(name, group)
		return groups[group] and in_group(group, name) and 1 or 0
	end,
}

-- Bits: +X=1, +Z=2, -X=4, -Z=8; 16 / 21 are the straight walls (5 / 10) with
-- a solid node or torch above. turn() is the engine's rotation of a
-- direction, taken from the real-engine run (+X -> -Z at 90).
local DIRS = {{1, 0, 1}, {0, 1, 2}, {-1, 0, 4}, {0, -1, 8}}
local function turn(dx, dz, r)
	if r == 90 then return dz, -dx elseif r == 180 then return -dx, -dz elseif r == 270 then return -dz, dx end
	return dx, dz
end
local function bit_of(dx, dz)
	for _, d in ipairs(DIRS) do if d[1] == dx and d[2] == dz then return d[3] end end
end
local function turned_name(name, r)
	local base, n = name:match("^(.*_)(%d+)$")
	n = tonumber(n)
	local tall = n == 16 or n == 21
	if n == 16 then n = 5 elseif n == 21 then n = 10 end
	local mask = 0
	for _, d in ipairs(DIRS) do
		if n % (d[3] * 2) >= d[3] then mask = mask + bit_of(turn(d[1], d[2], r)) end
	end
	return base .. (tall and mask + 11 or mask)
end
local function is_wall(name) return name ~= "air" and in_group("wall", name) end
local function is_connectable(name) return in_group("wall", name) or in_group("solid", name) end

-- Walls inside the box [0,sx) x [0,sy) x [0,sz) (offsets from pos) whose bits
-- disagree with their neighbours inside the box.
local function violations(pos, sx, sy, sz)
	local bad = 0
	for z = 0, sz - 1 do for y = 0, sy - 1 do for x = 0, sx - 1 do
		local n = world[key(pos.x + x, pos.y + y, pos.z + z)]
		if n and is_wall(n.name) then
			local bits = tonumber(n.name:match("_(%d+)$"))
			if bits == 16 then bits = 5 elseif bits == 21 then bits = 10 end
			for _, d in ipairs(DIRS) do
				local nx, nz = x + d[1], z + d[2]
				local q = nx >= 0 and nx < sx and nz >= 0 and nz < sz
					and world[key(pos.x + nx, pos.y + y, pos.z + nz)]
				local connected = bits % (d[3] * 2) >= d[3]
				if connected ~= (q and is_connectable(q.name) and true or false) then bad = bad + 1 end
			end
		end
	end end end
	return bad
end

local function load(rel)
	local path = "/m/" .. rel
	files[path] = read(rel)
	return {id = rel, path = rel}, files[path].size
end

local pos = {x = 100, y = 10, z = -20}
local function place(entry, rotation)
	world = {}
	eq(schematic.place(entry, pos, rotation, "/m", {initialize = false}), true, entry.id .. " placed at " .. rotation)
end
local function rotated_size(size, rotation)
	if rotation == 90 or rotation == 270 then return size.z, size.x end
	return size.x, size.z
end

-- Name computation on its own.
local at_none = function() return nil end
eq(schematic.wall_name("mcl_walls:cobble_9", at_none), "mcl_walls:cobble_0", "isolated wall is a post")
eq(schematic.wall_name("mcl_core:stone", at_none), "mcl_core:stone", "non-wall name untouched")
eq(schematic.wall_name("mcl_walls:cobble", at_none), "mcl_walls:cobble", "unsuffixed wall untouched")
local function neighbours(t) return function(dx, dy, dz) return t[dx .. "," .. dy .. "," .. dz] end end
local line = {["1,0,0"] = "mcl_walls:cobble_4", ["-1,0,0"] = "mcl_walls:cobble_1"}
eq(schematic.wall_name("mcl_walls:cobble_0", neighbours(line)), "mcl_walls:cobble_5", "straight along X")
line["0,1,0"] = "mcl_core:stone"
eq(schematic.wall_name("mcl_walls:cobble_0", neighbours(line)), "mcl_walls:cobble_16", "solid above a straight wall")
line["0,1,0"] = "mcl_torches:torch"
eq(schematic.wall_name("mcl_walls:cobble_0", neighbours(line)), "mcl_walls:cobble_16", "torch above a straight wall")
line["0,1,0"] = "mcl_stairs:stair_cobble"
eq(schematic.wall_name("mcl_walls:cobble_0", neighbours(line)), "mcl_walls:cobble_5", "stairs above do not make it tall")
local corner = {["1,0,0"] = "mcl_walls:cobble_0", ["0,1,0"] = "mcl_core:stone", ["0,0,1"] = "mcl_core:stone"}
eq(schematic.wall_name("mcl_walls:cobble_0", neighbours(corner)), "mcl_walls:cobble_3", "corner is not tall")

-- Real templates. Source schematics hold walls as the author's game left
-- them; the others are the shipped Roman imports and exported templates.
local authored = {
	"schematics/castle_workshop_edited.mts", "schematics/cathedral_monastery_working.mts",
	"schematics/imports/roman/arch.mts", "schematics/imports/roman/domus.mts",
	"schematics/templates/well.mts", "schematics/templates/mason_yard.mts",
}
local shipped = {
	"schematics/templates/castle.mts", "schematics/templates/cathedral.mts",
	"schematics/templates/tower.mts", "schematics/templates/tavern.mts",
	"schematics/templates/blacksmith.mts", "schematics/imports/roman/amphitheater.mts",
	"schematics/imports/roman/theatre.mts",
}
local all = {}
for _, p in ipairs(authored) do all[#all + 1] = p end
for _, p in ipairs(shipped) do all[#all + 1] = p end

for _, rel in ipairs(all) do
	local entry, size = load(rel)
	place(entry, 0)
	local at0 = {}
	local walls = 0
	for k, n in pairs(world) do
		if is_wall(n.name) then walls = walls + 1; at0[k] = n.name end
	end
	assert(walls > 0, rel .. " has no walls")
	local sx, sz = rotated_size(size, 0)
	eq(violations(pos, sx, size.y, sz), 0, rel .. " rot 0 every wall matches its neighbours")

	for _, rotation in ipairs({90, 180, 270}) do
		place(entry, rotation)
		local rsx, rsz = rotated_size(size, rotation)
		eq(violations(pos, rsx, size.y, rsz), 0, rel .. " rot " .. rotation .. " every wall matches its neighbours")
		-- The rotated building is the unrotated one turned: same walls, same
		-- places, connection names turned with them.
		local mismatched, count = 0, 0
		for k, name in pairs(at0) do
			local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
			local o = schematic.rotate_offset(size, {x = tonumber(x) - pos.x, y = tonumber(y) - pos.y, z = tonumber(z) - pos.z}, rotation)
			local n = world[key(pos.x + o.x, pos.y + o.y, pos.z + o.z)]
			count = count + 1
			if not (n and n.name == turned_name(name, rotation)) then mismatched = mismatched + 1 end
		end
		eq(count, walls, rel .. " rot " .. rotation .. " wall count")
		eq(mismatched, 0, rel .. " rot " .. rotation .. " is the unrotated walls turned")
	end
end

-- Walls the author's game computed itself are reproduced exactly, so the
-- recomputation matches mcl_walls' own update_wall on real data.
for _, rel in ipairs(authored) do
	local entry = load(rel)
	place(entry, 0)
	local f = files["/m/" .. rel]
	local changed = 0
	for z = 0, f.size.z - 1 do for y = 0, f.size.y - 1 do for x = 0, f.size.x - 1 do
		local name = f.at(x, y, z)
		if is_wall(name) and world[key(pos.x + x, pos.y + y, pos.z + z)].name ~= name then changed = changed + 1 end
	end end end
	eq(changed, 0, rel .. " authored wall names kept")
end

-- Non-wall nodes keep their param2 through place.
do
	local entry, size = load("schematics/imports/roman/arch.mts")
	place(entry, 90)
	local f = files["/m/schematics/imports/roman/arch.mts"]
	local bad = 0
	for z = 0, size.z - 1 do for y = 0, size.y - 1 do for x = 0, size.x - 1 do
		local name, param2 = f.at(x, y, z)
		local o = schematic.rotate_offset(size, {x = x, y = y, z = z}, 90)
		local n = world[key(pos.x + o.x, pos.y + o.y, pos.z + o.z)]
		if not is_wall(name) and (n.name ~= name or n.param2 ~= param2) then bad = bad + 1 end
		if is_wall(name) and n.param2 ~= param2 then bad = bad + 1 end
	end end end
	eq(bad, 0, "arch rot 90 non-wall nodes and param2 carried over")
end

_G.core = saved_core
_G.vector = saved_vector
