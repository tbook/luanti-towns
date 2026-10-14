-- Towns: pure planning logic for the Phase 1 test command.
-- No core.* dependency, so it can be tested with plain Lua 5.1. The world
-- access lives in src/test_command.lua.
--
-- Site layout
-- -----------
-- ground = node the player stands on. The building's rotated minimum corner
-- is OFFSET_X nodes east of it. Its Y is ground Y minus the catalog entry's
-- ground_offset (zero for a foundation at ground level). A SQUARE x SQUARE paved square sits
-- immediately outside the building edge that holds the entrance, centred on
-- the entrance. The square is paved at ground level, flush with the floor.

-- Usage: local placement = dofile(".../placement.lua")(geometry)
return function(geometry)

local M = {}

M.OFFSET_X = 8
M.SQUARE = 5
-- Nodes below ground level included in the bounds (support fill).
M.SUPPORT_DEPTH = 1
-- Largest allowed difference between the highest and lowest surface node.
M.MAX_STEP = 1

-- Parses the /towns_test parameter string.
-- Returns id, rotation(number) on success or nil, message.
function M.parse_args(param)
	local tokens = {}
	for t in tostring(param or ""):gmatch("%S+") do tokens[#tokens + 1] = t end
	if #tokens ~= 2 then
		return nil, "Usage: /towns_test <building_id> <rotation 0|90|180|270>"
	end
	local id, rot = tokens[1], tokens[2]
	local n = (rot == "0" or rot == "90" or rot == "180" or rot == "270") and tonumber(rot)
	if not n then
		return nil, "Invalid rotation '" .. rot .. "': use 0, 90, 180 or 270"
	end
	return id, n
end

-- Returns a plan table or errors on bad input (use parse_args first).
--   entry    catalog entry {size, entrance}
--   ground   {x,y,z} node the player stands on
--   rotation 0/90/180/270
-- Plan fields:
--   rotation, ground_y
--   pos        min corner of the rotated footprint (place_schematic pos)
--   building   geometry.place() result
--   square     {min, max} inclusive paved square (y = ground_y)
--   bounds     {min, max} inclusive combined volume; the only nodes the build
--              may touch
function M.plan(entry, ground, rotation)
	local pos = {x = ground.x + M.OFFSET_X,
		y = ground.y - (entry.ground_offset or 0), z = ground.z}
	local b = geometry.place(entry, pos, rotation)
	local e, f, n = b.entrance, b.front, M.SQUARE
	local half = (n - 1) / 2

	-- The square starts at the footprint edge in the front direction (the
	-- entrance is on that edge for flush doors), centred on the entrance.
	local smin, smax = {y = ground.y}, {y = ground.y}
	if f.x == 0 then
		smin.x, smax.x = e.x - half, e.x + half
		if f.z < 0 then
			smin.z, smax.z = b.min.z - n, b.min.z - 1
		else
			smin.z, smax.z = b.max.z + 1, b.max.z + n
		end
	else
		smin.z, smax.z = e.z - half, e.z + half
		if f.x < 0 then
			smin.x, smax.x = b.min.x - n, b.min.x - 1
		else
			smin.x, smax.x = b.max.x + 1, b.max.x + n
		end
	end

	local bounds = {
		min = {
			x = math.min(b.min.x, smin.x),
			y = math.min(pos.y, ground.y - M.SUPPORT_DEPTH),
			z = math.min(b.min.z, smin.z),
		},
		max = {
			x = math.max(b.max.x, smax.x),
			y = b.max.y,
			z = math.max(b.max.z, smax.z),
		},
	}
	return {
		rotation = b.rotation,
		ground_y = ground.y,
		pos = pos,
		building = b,
		square = {min = smin, max = smax},
		bounds = bounds,
	}
end

function M.in_box(box, x, z)
	return x >= box.min.x and x <= box.max.x and z >= box.min.z and z <= box.max.z
end

-- "Building" or "square" for a column of the combined footprint, else nil
-- (the combined box is not always filled: bounding rectangle corners).
function M.column_kind(plan, x, z)
	if M.in_box(plan.building, x, z) then return "building" end
	if M.in_box(plan.square, x, z) then return "square" end
	return nil
end

-- Calls fn(x, z, kind) for every column of the building and the square.
function M.each_column(plan, fn)
	local bd = plan.bounds
	for x = bd.min.x, bd.max.x do
		for z = bd.min.z, bd.max.z do
			local kind = M.column_kind(plan, x, z)
			if kind then fn(x, z, kind) end
		end
	end
end

function M.format_bounds(bounds)
	return string.format("(%d,%d,%d) to (%d,%d,%d)",
		bounds.min.x, bounds.min.y, bounds.min.z,
		bounds.max.x, bounds.max.y, bounds.max.z)
end

-- Node info for classify, from a registered_nodes table (core.registered_nodes).
-- Returns {walkable, liquid, clearable} or nil for unregistered names.
function M.node_info(registered_nodes, name)
	local def = registered_nodes[name]
	if not def then return nil end
	local g = def.groups or {}
	local liquid = def.liquidtype ~= nil and def.liquidtype ~= "none"
	local clearable = def.buildable_to
		or g.tree or g.leaves or g.plant or g.vines or g.flower or g.deco_block
		or g.dead_bush or g.mushroom or g.sapling
		or name:find("^mcl_core:snow_?%d*$") ~= nil
	-- Ice is treated like water (never ground): product decision, ticket #15.
	local ice = (g.ice or g.slippery or g.frosted_ice) and true or false
	return {
		walkable = def.walkable ~= false,
		liquid = liquid,
		clearable = clearable and true or false,
		ice = ice,
		falling = g.falling_node and true or false,
		-- Doors and gates can be walked through (opened), even when closed.
		door = (g.door ~= nil or g.fence_gate ~= nil or name:find("_door_", 1, true) ~= nil
			or name:find("fence_gate", 1, true) ~= nil) and true or false,
	}
end

-- Classifies a node name. `info(name)` returns a table
-- {walkable=bool, liquid=bool, clearable=bool} or nil for unknown nodes.
--   "air"     nothing there
--   "clear"   vegetation/snow/leaves/trunks to remove, not ground
--   "water"   liquid (any) or ice (info.ice: ice, packed ice, frosted ice,
--             anything slippery); sites with such nodes in the way are rejected
--   "solid"   ground
--   "unknown" ignore / not emerged / unregistered
function M.classify(name, info)
	if name == "air" then return "air" end
	if name == "ignore" then return "unknown" end
	local i = info(name)
	if not i then return "unknown" end
	if i.liquid or i.ice then return "water" end
	if i.clearable then return "clear" end
	if i.walkable then return "solid" end
	-- Non-walkable, non-liquid nodes (torches, signs, plants) are airspace.
	return "clear"
end

-- Finds the surface of one column. `class_at(y)` returns a classify() result.
-- Scans from top down to bottom (inclusive). Returns:
--   height, nil              y of the topmost solid node
--   nil, "water"|"unknown"|"none", y   problem (and where)
function M.scan_column(class_at, top, bottom)
	for y = top, bottom, -1 do
		local c = class_at(y)
		if c == "solid" then
			return y
		elseif c == "water" or c == "unknown" then
			return nil, c, y
		end
	end
	return nil, "none", bottom
end

-- Decides whether a site is acceptable, given each column's surface height.
--   heights(x, z) -> height or nil, problem, y   (scan_column results)
-- Returns true, or false, reason. Pure; inspects only plan columns.
function M.check_site(plan, heights)
	local lo, hi
	local gy = plan.ground_y
	local reason
	M.each_column(plan, function(x, z)
		if reason then return end
		local h, problem, py = heights(x, z)
		if not h then
			if problem == "water" then
				reason = string.format("water or lava at (%d,%d,%d)", x, py, z)
			elseif problem == "unknown" then
				reason = string.format("unloaded or unknown terrain at (%d,%d,%d)", x, py, z)
			else
				reason = string.format("no solid ground at (%d,%d) between y=%d and y=%d",
					x, z, py, plan.bounds.max.y)
			end
			return
		end
		lo = (lo and math.min(lo, h)) or h
		hi = (hi and math.max(hi, h)) or h
	end)
	if reason then return false, reason end
	if hi - lo > M.MAX_STEP then
		return false, string.format("terrain too uneven: surface varies from y=%d to y=%d (max %d)",
			lo, hi, M.MAX_STEP)
	end
	if lo < gy - M.SUPPORT_DEPTH or hi > gy + M.MAX_STEP then
		return false, string.format("terrain surface y=%d..%d is too far from ground level y=%d",
			lo, hi, gy)
	end
	return true
end

return M

end
