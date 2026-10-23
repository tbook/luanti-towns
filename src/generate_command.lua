-- Towns: /towns_generate, the privileged populated-town command (Phase 3,
-- ticket #49). Thin core.* layer; the command logic and report formatting
-- are in src/generate.lua (pure, tested).
--
-- WARNING: builds immediately on the chosen site, overwriting it with no
-- preview and no confirmation. For disposable Creative worlds only.
--
-- Flow: site search with structure bounds and the catalog landmark profile
-- (catalog, landmarks, jail, services, content plan) -> preflight check
-- (files, node registration; zero writes) -> builder.build_town (terrain,
-- schematics, door checks, node initialization, ticket #46) -> bed
-- enumeration (#47) -> resident spawning and claiming once per bed (#48,
-- guarded by a per-bed record in mod storage, see residents.initialize).
-- Bed and resident problems never fail the build; they appear in the report.

local towns = ...  -- the global table built by init.lua

local function profile()
	return assert(towns.planner.landmark_profile(towns.catalog.snapshot()))
end

-- Search and build halves, exposed for headless validation
-- (tools/place_check) as towns.populated. `town_type` is "medieval" (nil
-- means medieval) or "roman"; both share every stage after the plan.
local function search(pos, seed, town_type, done)
	-- Ticket #104: wet sites (shallow ponds, rivers, ice) are landfilled under
	-- the conservative towns.site_search.WET_DEFAULTS.
	local opts = {structure_bounds = true}
	if town_type == "roman" then
		-- Authored plan (issue #148); composition needs the catalog entries.
		opts.planner_opts = {town_type = "roman"}
		opts.entries = towns.catalog.entries
	else
		opts.planner_opts = {landmarks = profile()}
	end
	for k, v in pairs(towns.site_search.WET_DEFAULTS) do opts[k] = v end
	return towns.site_search.search(pos, seed, opts, done)
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
	if summary then
		summary.site = {wet = result.wet and {count = result.wet.count,
			max_depth = result.wet.max_depth}, rejections = result.rejections,
			candidates_tried = result.candidates_tried}
	end
	if summary and summary.town then
		-- Unmet jail/service targets from the plan, for the report.
		summary.town.shortages = result.plan.shortages
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
towns.populated = {search = search, build = build, store = store}

local controller = towns.generate.new({
	get_player_pos = function(name)
		local p = core.get_player_by_name(name)
		return p and p:get_pos() or nil
	end,
	search = search,
	build = build,
	send = function(name, msg)
		-- The player may have left during the asynchronous search.
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

-- Entry point shared by the chat command (and by headless validation).
towns.generate_run = controller.run

core.register_chatcommand("towns_generate", {
	params = "[medieval|roman] [seed]",
	description = towns.generate.HELP,
	privs = {server = true},
	func = function(name, param)
		return controller.run(name, param)
	end,
})
