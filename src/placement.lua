-- Towns: pure terrain classification shared by site search and the builder.
-- No core.* dependency, so it can be tested with plain Lua 5.1.
--
-- Usage: local placement = dofile(".../placement.lua")

local M = {}

-- Node info for classify, from a registered_nodes table (core.registered_nodes).
-- Returns {walkable, liquid, clearable, vegetation} or nil for unregistered names.
function M.node_info(registered_nodes, name)
	local def = registered_nodes[name]
	if not def then return nil end
	local g = def.groups or {}
	local liquid = def.liquidtype ~= nil and def.liquidtype ~= "none"
	local function has_group(group)
		return tonumber(g[group]) ~= nil and tonumber(g[group]) > 0
	end
	-- The broad tree group also covers logs, which can belong to buildings.
	local vegetation = has_group("leaves") or has_group("plant") or has_group("vines")
		or has_group("flower") or has_group("dead_bush") or has_group("mushroom") or has_group("sapling")
		or name:find("^mcl_core:snow_?%d*$") ~= nil
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
		-- Wall generation may remove known vegetation, but must not infer this
		-- from buildable_to or deco_block: both can include useful structures.
		vegetation = vegetation and true or false,
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

return M
