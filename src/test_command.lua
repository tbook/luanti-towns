-- Towns: /towns_test, the privileged Phase 1 placement command.
-- Thin core.* layer around the pure logic in placement.lua / geometry.lua.
--
-- WARNING: placement overwrites the chosen site immediately, with no preview
-- and no confirmation. For disposable Creative worlds only.

local towns = ...  -- the global table built by init.lua

local placement = towns.placement

local PAVING = "mcl_core:stonebrick"
local FILL = "mcl_core:dirt"

local HELP = "WARNING: overwrites the chosen site immediately (no preview, no "
	.. "confirmation); for disposable Creative worlds only. "
	.. "Places <building_id> rotated 0, 90, 180 or 270 with its minimum corner "
	.. placement.OFFSET_X .. " nodes east of the node you stand on, plus a "
	.. placement.SQUARE .. "x" .. placement.SQUARE
	.. " paved square outside its entrance. Rejects water, a surface that varies by "
	.. "more than one node, and a surface more than one node above or below your "
	.. "ground level. Reports the combined bounds. "
	.. "Requires the 'server' privilege. Usage: /towns_test <building_id> <rotation>"

-- Node info for placement.classify, from the game's registrations.
local function node_info(name)
	local def = core.registered_nodes[name]
	if not def then return nil end
	local g = def.groups or {}
	local liquid = def.liquidtype ~= nil and def.liquidtype ~= "none"
	local clearable = def.buildable_to
		or g.tree or g.leaves or g.plant or g.vines or g.flower or g.deco_block
		or g.dead_bush or g.mushroom or g.sapling
		or name:find("^mcl_core:snow_?%d*$") ~= nil
	return {
		walkable = def.walkable ~= false,
		liquid = liquid,
		clearable = clearable and true or false,
	}
end

local function class_at(x, y, z)
	return placement.classify(core.get_node({x = x, y = y, z = z}).name, node_info)
end

-- Reads the whole plan; returns ok, reason, fills. Writes nothing.
-- fills: list of positions at support depth that need filling.
local function inspect(plan)
	local top = plan.bounds.max.y
	local bottom = plan.bounds.min.y
	local fills = {}
	local heights = {}
	local function column_height(x, z)
		local key = x .. "," .. z
		local r = heights[key]
		if not r then
			local h, problem, py = placement.scan_column(function(y)
				return class_at(x, y, z)
			end, top, bottom)
			r = {h, problem, py}
			heights[key] = r
		end
		return r[1], r[2], r[3]
	end
	local ok, reason = placement.check_site(plan, column_height)
	if not ok then return false, reason end
	placement.each_column(plan, function(x, z)
		local y = plan.ground_y - placement.SUPPORT_DEPTH
		if class_at(x, y, z) ~= "solid" then
			fills[#fills + 1] = {x = x, y = y, z = z}
		end
	end)
	return true, nil, fills
end

-- Performs the writes. Everything is inside plan.bounds.
local function build(plan, entry, fills)
	local gy, top = plan.ground_y, plan.bounds.max.y
	local air, paving = {}, {}
	placement.each_column(plan, function(x, z, kind)
		for y = gy + 1, top do air[#air + 1] = {x = x, y = y, z = z} end
		if kind == "square" then
			paving[#paving + 1] = {x = x, y = gy, z = z}
		else
			air[#air + 1] = {x = x, y = gy, z = z}
		end
	end)
	core.bulk_set_node(air, {name = "air"})
	if #fills > 0 then core.bulk_set_node(fills, {name = FILL}) end
	core.bulk_set_node(paving, {name = PAVING})
	local path = towns.modpath .. "/" .. entry.path
	core.place_schematic(plan.pos, path, tostring(plan.rotation), nil, true)
end

-- Validates, emerges the combined volume, then inspects and (if suitable)
-- builds. `done(ok, message, plan)` is called exactly once, possibly after
-- the emerge callbacks. Nothing is written unless the whole site passed.
--   ground: {x,y,z} node the player stands on
function towns.place_test(building_id, rotation, ground, done)
	local id, rot = building_id, rotation
	local entry = towns.catalog.entries[id]
	if not entry then
		return done(false, "Unknown building '" .. tostring(id) .. "'. Known: "
			.. table.concat(towns.catalog.ids(), ", "))
	end
	if towns.catalog.invalid[id] then
		return done(false, "Building '" .. id .. "' is not usable: " .. towns.catalog.invalid[id])
	end
	local n = (rot == 0 or rot == 90 or rot == 180 or rot == 270) and rot
		or ((rot == "0" or rot == "90" or rot == "180" or rot == "270") and tonumber(rot))
	if not n then
		return done(false, "Invalid rotation " .. tostring(rot) .. ": use 0, 90, 180 or 270")
	end
	for _, name in ipairs({PAVING, FILL}) do
		if not core.registered_nodes[name] then
			return done(false, "Required node '" .. name .. "' is not registered")
		end
	end

	local plan = placement.plan(entry, ground, n)
	local bounds_str = placement.format_bounds(plan.bounds)
	local errored = false
	core.emerge_area(plan.bounds.min, plan.bounds.max, function(_, action, remaining)
		if action == core.EMERGE_CANCELLED or action == core.EMERGE_ERRORED then
			errored = true
		end
		if remaining > 0 then return end
		if errored then
			return done(false, "Could not load the site " .. bounds_str, plan)
		end
		local ok, reason, fills = inspect(plan)
		if not ok then
			return done(false, string.format("Rejected %s rotation %d at %s: %s. Nothing was changed.",
				id, plan.rotation, bounds_str, reason), plan)
		end
		build(plan, entry, fills)
		done(true, string.format("Placed %s rotation %d. Combined bounds: %s. Entrance at (%d,%d,%d) facing (%d,%d). Paved square %s.",
			id, plan.rotation, bounds_str,
			plan.building.entrance.x, plan.building.entrance.y + 1, plan.building.entrance.z,
			plan.building.front.x, plan.building.front.z,
			placement.format_bounds(plan.square)), plan)
	end)
end

core.register_chatcommand("towns_test", {
	params = "<building_id> <rotation 0|90|180|270>",
	description = HELP,
	privs = {server = true},
	func = function(name, param)
		local id, rot = placement.parse_args(param)
		if not id then
			return false, rot
		end
		local player = core.get_player_by_name(name)
		if not player then
			return false, "You must be in game to use this command."
		end
		local p = player:get_pos()
		local ground = {x = math.floor(p.x + 0.5), y = math.floor(p.y + 0.5) - 1, z = math.floor(p.z + 0.5)}
		local under = core.get_node(ground)
		if placement.classify(under.name, node_info) ~= "solid" then
			return false, "You must be standing on solid ground (found '" .. under.name .. "' below you)."
		end
		-- Validation failures call back synchronously; world results arrive
		-- later, after the emerge, as chat messages.
		local returning, sync_ok, sync_msg = true
		towns.place_test(id, rot, ground, function(ok, msg)
			if returning then
				sync_ok, sync_msg = ok, msg
			else
				core.chat_send_player(name, (ok and "" or "Error: ") .. msg)
			end
		end)
		returning = false
		if sync_msg then
			return sync_ok, sync_msg
		end
		return true, "Placing " .. id .. " (rotation " .. rot .. ")..."
	end,
})
