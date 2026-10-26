-- Towns: /towns_generate, the privileged populated-town command (Phase 3,
-- ticket #49). Thin core.* layer; the command logic and report formatting
-- are in src/generate.lua (pure, tested).
--
-- WARNING: builds immediately on the chosen site, overwriting it with no
-- preview and no confirmation. For disposable Creative worlds only.
--
-- Flow: urban site search -> outskirts search -> urban and outskirts preflight
-- (zero writes) -> builder.build_town -> outskirts terrain and structures -> bed
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
	local opts = {}
	if town_type == "roman" then
		-- Authored plan (issue #148); composition needs the catalog entries.
		opts.planner_opts = {town_type = "roman"}
		opts.entries = towns.catalog.entries
	else
		opts.planner_opts = {landmarks = profile()}
	end
	for k, v in pairs(towns.site_search.WET_DEFAULTS) do opts[k] = v end
	return towns.site_search.search(pos, seed, opts, function(result, message, details)
		if not result then return done(nil, message, details) end
		local lv = rawget(_G, "living_villages")
		local terrain = type(lv) == "table" and lv.terrain or nil
		return towns.outskirts.search(result, {
			assets = towns.catalog.entries, terrain = terrain, player_pos = pos,
		}, function(out, outskirts_message, kind)
			if not out then return done(nil, outskirts_message, kind) end
			result.outskirts = out
			result.player_pos = pos
			return done(result, nil, details)
		end, towns.site_search.core_env(core))
	end)
end

local store = towns.residents.core_store(core.get_mod_storage())

local function bounds_union(boxes)
	local out
	for _, b in ipairs(boxes) do
		if type(b) == "table" and type(b.minp) == "table" and type(b.maxp) == "table" then
			b = {min = b.minp, max = b.maxp}
		end
		if type(b) == "table" and type(b.min) == "table" and type(b.max) == "table" then
			if not out then
				out = {min = {x = b.min.x, y = b.min.y, z = b.min.z},
					max = {x = b.max.x, y = b.max.y, z = b.max.z}}
			else
				for _, axis in ipairs({"x", "y", "z"}) do
					out.min[axis] = math.min(out.min[axis], b.min[axis])
					out.max[axis] = math.max(out.max[axis], b.max[axis])
				end
			end
		end
	end
	return out
end

local function build_now(result)
	local env_preflight = towns.preflight.core_env(core)
	local lv = rawget(_G, "living_villages")
	local terrain = type(lv) == "table" and lv.terrain or nil
	if type(terrain) ~= "table" or type(terrain.volume) ~= "function"
			or type(terrain.terraform) ~= "function" then
		return nil, "Living Villages terrain API requires volume and terraform",
			"outskirts_dependency", {reason = "outskirts_dependency"}
	end
	local pre, msg, reason = towns.preflight.check({
		plan = result.plan,
		entries = towns.catalog.entries,
		ground_y = result.ground_y,
		build_bounds = result.build_bounds,
		build_volume = result.build_volume,
		modpath = towns.modpath,
	}, env_preflight)
	if not pre then
		return nil, msg, "inspection_failed", {reason = reason}
	end
	local outskirts_pre, outskirts_msg, outskirts_code = towns.preflight.check_outskirts(
		result.outskirts, env_preflight, {
			entries = result.outskirts and result.outskirts.entries,
			plan = result.plan, player = result.player_pos, modpath = towns.modpath,
		})
	if not outskirts_pre then return nil, outskirts_msg, outskirts_code, {reason = outskirts_code} end
	local env = towns.builder.core_env(core, {
		schematic = towns.schematic, modpath = towns.modpath,
		node_setup = towns.node_setup,
		globals = {itemframes = rawget(_G, "mcl_itemframes"), chests = rawget(_G, "mcl_chests")},
	})
	local summary, bmsg, bcode, extra = towns.builder.build_town(
		result, {entries = towns.catalog.entries}, env)
	if not summary then
		if bcode == "write_failed" then
			extra = extra or {}
			extra.urban_bounds = extra.bounds or result.write_bounds or result.build_bounds
			extra.bounds = extra.bounds or extra.urban_bounds
			extra.terrain_attempts, extra.placement_attempts = {}, {}
		end
		return nil, bmsg, bcode, extra
	end
	local outskirts_summary, outskirts_error, outskirts_code, outskirts_extra =
		towns.outskirts_build.apply(result.outskirts, {
			terrain = terrain,
			place_structure = env.place_structure, get_node = env.get_node,
			node_info = env.node_info, check_door = towns.builder.check_door,
			setup_nodes = env.setup_nodes,
		}, {bounds = result.plan.bounds, structures = outskirts_pre.structures})
	if not outskirts_summary then
		outskirts_extra = outskirts_extra or {}
		outskirts_extra.reason = outskirts_extra.reason or "outskirts_write"
		outskirts_extra.urban_bounds = summary.write_bounds or summary.town.bounds
		outskirts_extra.bounds = outskirts_extra.bounds or outskirts_extra.urban_bounds
		outskirts_extra.terrain_attempts = outskirts_extra.attempted or {}
		outskirts_extra.placement_attempts = outskirts_extra.placement_attempted or {}
		local possible = {outskirts_extra.urban_bounds}
		for _, b in ipairs(outskirts_extra.terrain_attempts) do possible[#possible + 1] = b end
		for _, b in ipairs(outskirts_extra.placement_attempts) do possible[#possible + 1] = b end
		for _, b in ipairs(outskirts_extra.boxes or {}) do possible[#possible + 1] = b end
		outskirts_extra.bounds = bounds_union(possible) or outskirts_extra.bounds
		-- The urban town is already complete, so any later failure can leave a
		-- partially written combined site, even if the rural failure is a runtime
		-- dependency error.
		return nil, outskirts_error, "write_failed", outskirts_extra
	end
	summary.outskirts = outskirts_summary
	-- Keep the planner's requested/planned counts beside the build results so
	-- the player report can distinguish omissions from placement/terraform skips.
	summary.outskirts.counts = result.outskirts and result.outskirts.counts or nil
	summary.town.urban_structure_count = #summary.town.structures
	for _, structure in ipairs(outskirts_summary.structures) do
		summary.town.structures[#summary.town.structures + 1] = structure
	end
	summary.town.urban_placed = summary.town.placed
	summary.town.placed = summary.town.placed + outskirts_summary.placed
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

-- The public populated builder is callback-based. Its work is synchronous for
-- now; later stages may defer completion without changing the controller API.
local function build(result, done)
	done(build_now(result))
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
