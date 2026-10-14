-- Towns: /towns_place_town, an EXPERIMENTAL opt-in entry point for ticket #45
-- (placing real schematics and paving alleys). It exists so the placement can
-- be checked in a disposable world before the production command (ticket #49)
-- is wired; it is only registered when the setting
--     towns_enable_place_town = true
-- is set (minetest.conf or world.mt-adjacent config). It is NOT /towns_generate:
-- that command is unchanged and still builds blockouts.
--
-- WARNING: like /towns_generate it overwrites the chosen site immediately,
-- with no preview and no confirmation. Disposable Creative worlds only.
--
-- Flow: search with structure bounds (real landmark profile) -> preflight
-- check (files, node registration) -> builder.build_town. No node setup
-- (ticket #46) and no residents (ticket #48) happen here.

local towns = ...  -- the global table built by init.lua

if not core.settings:get_bool("towns_enable_place_town", false) then
	return
end

local function profile()
	return assert(towns.planner.landmark_profile(towns.catalog.snapshot()))
end

-- Search and build halves, exposed for headless validation
-- (tools/place_check) as towns.place_town.
local function search(pos, seed, _, done)
	return towns.site_search.search(pos, seed, {
		structure_bounds = true,
		planner_opts = {landmarks = profile()},
	}, done)
end

local function build(result)
	local pre, msg, reason = towns.preflight.check({
		plan = result.plan,
		entries = towns.catalog.entries,
		ground_y = result.ground_y,
		build_bounds = result.build_bounds,
		build_volume = result.build_volume,
		modpath = towns.modpath,
	}, towns.preflight.core_env(core))
	if not pre then
		return nil, msg, "inspection_failed", {reason = reason}
	end
	local env = towns.builder.core_env(core, {
		schematic = towns.schematic, modpath = towns.modpath,
	})
	return towns.builder.build_town(result, {entries = towns.catalog.entries}, env)
end
towns.place_town = {search = search, build = build}

local controller = towns.generate.new({
	command_name = "/towns_place_town",
	get_player_pos = function(name)
		local p = core.get_player_by_name(name)
		return p and p:get_pos() or nil
	end,
	search = search,
	build = build,
	send = function(name, msg)
		if core.get_player_by_name(name) then
			core.chat_send_player(name, msg)
		end
	end,
	log = function(level, msg) core.log(level, msg) end,
	entropy = function()
		local seed = tonumber(core.get_mapgen_setting("seed")) or 0
		return os.time() * 1000 + (core.get_us_time() % 1000000) + math.abs(seed) % 1000003
	end,
	now = function() return os.time() end,
})

-- Entry point shared by the chat command and headless validation.
towns.place_town_run = controller.run

core.register_chatcommand("towns_place_town", {
	params = "[seed]",
	description = "EXPERIMENTAL (ticket #45): like /towns_generate but places the "
		.. "real cathedral, castle, city hall, jail, services and ordinary "
		.. "buildings and paves access alleys. Overwrites the site with no "
		.. "preview. Disposable Creative worlds only. Needs the 'server' privilege.",
	privs = {server = true},
	func = function(name, param)
		return controller.run(name, param)
	end,
})
