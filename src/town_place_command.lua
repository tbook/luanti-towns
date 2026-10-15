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
-- check (files, node registration) -> builder.build_town, which also
-- initializes the placed functional nodes (ticket #46, src/node_setup.lua).
-- Valid beds in the placed boxes are enumerated and reported (ticket #47).
-- Ticket #48: one villager is spawned and bed-claimed per valid bed, guarded
-- by a persistent per-bed record in mod storage (see residents.initialize).

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

local store = towns.residents.core_store(core.get_mod_storage())

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
		node_setup = towns.node_setup,
		globals = {itemframes = rawget(_G, "mcl_itemframes"), chests = rawget(_G, "mcl_chests")},
	})
	local summary, bmsg, bcode, extra = towns.builder.build_town(
		result, {entries = towns.catalog.entries}, env)
	if summary and summary.town then
		-- Ticket #47: read-only bed enumeration inside the placed boxes. It
		-- never fails the build; a problem is reported instead of the count.
		local ok, rep = pcall(towns.residents.enumerate, summary.town.structures,
			towns.residents.core_env(core))
		if ok then
			summary.town.beds = rep
			-- Ticket #48: spawn and claim, once per bed. Never fails the build.
			local ok2, res = pcall(towns.residents.initialize, rep.beds,
				towns.residents.core_env(core), store)
			if ok2 then
				summary.town.residents = res
				for _, f in ipairs(res.failures) do
					core.log("warning", ("towns: resident not spawned at %s (%s in %s): %s")
						:format(core.pos_to_string(f.pos), tostring(f.kind), tostring(f.id), f.reason))
				end
				for _, i in ipairs(res.interrupted_beds) do
					core.log("warning", ("towns: interrupted resident initialization at bed %s (%s); "
						.. "not retried, see mod storage key %s"):format(core.pos_to_string(i.pos),
						tostring(i.id), towns.residents.record_key(i.pos)))
				end
			else
				core.log("warning", "towns: resident initialization failed: " .. tostring(res))
				summary.town.residents_error = tostring(res)
			end
		else
			core.log("warning", "towns: bed enumeration failed: " .. tostring(rep))
			summary.town.beds_error = tostring(rep)
		end
	end
	return summary, bmsg, bcode, extra
end
towns.place_town = {search = search, build = build, store = store}

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
