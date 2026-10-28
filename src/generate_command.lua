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
		-- Rural placement must inspect the post-margin terrain, so retain only
		-- the accepted player's original position here.
		result.player_pos = pos
		return done(result, nil, details)
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

local function finalize(summary, result)
	if not summary or not summary.town then return summary end
	if summary.site == nil then
		summary.site = {wet = result.wet and {count = result.wet.count,
			max_depth = result.wet.max_depth}, rejections = result.rejections,
			candidates_tried = result.candidates_tried}
	end
	summary.town.shortages = result.plan.shortages
	local ok, rep = pcall(towns.residents.enumerate, summary.town.structures,
		towns.residents.core_env(core))
	if ok then
		summary.town.beds = rep
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
	return summary
end

local function warning(summary, message)
	summary.warnings = summary.warnings or {}
	summary.warnings[#summary.warnings + 1] = message
	core.log("warning", "towns: " .. message)
end

local function build_urban(result)
	local walls = towns.medieval_walls
	if walls and result.plan.town_type == "medieval" then
		result.wall = walls.plan(result.plan, result.force_walls)
		if result.wall then
			local wall_bounds = walls.bounds(result.wall, result.ground_y)
			if wall_bounds then
				-- Wall overhangs and three-node approaches reach at most four
				-- nodes past the urban footprint. Outskirts candidate and
				-- terraform protection both use this same margin.
				local b, margin = result.plan.bounds, towns.outskirts.CONSTANTS.PROTECT_MARGIN
				if wall_bounds.min.x < b.x1 - margin or wall_bounds.max.x > b.x2 + margin
						or wall_bounds.min.z < b.z1 - margin or wall_bounds.max.z > b.z2 + margin then
					return nil, "Wall footprint exceeds outskirts protection", "inspection_failed"
				end
				for _, axis in ipairs({"x", "y", "z"}) do
					if math.abs(wall_bounds.min[axis]) > towns.preflight.LIMIT
							or math.abs(wall_bounds.max[axis]) > towns.preflight.LIMIT then
						return nil, "Wall envelope exceeds map limits", "inspection_failed"
					end
				end
			end
			if type(core.is_protected) ~= "function" then
				return nil, "Wall protection API is unavailable", "inspection_failed"
			end
			for _, node in ipairs({walls.BRICK, walls.STAIR}) do
				if not core.registered_nodes[node] then
					return nil, "Wall node is not registered: " .. node, "inspection_failed"
				end
			end
			local ok, err = pcall(walls.reserve, result.wall, result.ground_y,
				function(pos) return core.is_protected(pos, "") end)
			if not ok then return nil, "Wall protection check failed: " .. tostring(err), "inspection_failed" end
		end
	end
	local env_preflight = towns.preflight.core_env(core)
	local lv = rawget(_G, "living_villages")
	local terrain = type(lv) == "table" and lv.terrain or nil
	if type(terrain) ~= "table" or type(terrain.volume) ~= "function"
			or type(terrain.terraform) ~= "function" then
		return nil, "Living Villages terrain API requires volume and terraform",
			"outskirts_dependency", {reason = "outskirts_dependency"}
	end
	local rural_assets, assets_message, assets_code = towns.outskirts.assets(towns.catalog.entries)
	if not rural_assets then
		return nil, assets_message, assets_code == "outskirts_dependency"
			and "outskirts_dependency" or "inspection_failed", {reason = assets_code}
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
	return {summary = summary, message = bmsg, terrain = terrain, env = env,
		preflight_env = env_preflight}
end

local function build(result, done)
	local completed = false
	local function finish(summary, message, code, extra)
		if completed then return end
		completed = true
		done(summary, message, code, extra)
	end
	local built, message, code, extra = build_urban(result)
	if not built then finish(nil, message, code, extra); return end
	local summary, terrain, env = built.summary, built.terrain, built.env
	local margin_api
	local margin_ok, margin_err = pcall(function()
		margin_api = towns.city_margins and towns.city_margins(terrain)
	end)
	if not margin_ok then margin_api = nil end
	local urban_bounds = summary.write_bounds or summary.town.bounds
	summary.urban_write_bounds = urban_bounds
	local function update_write_bounds(rural)
		local boxes = {urban_bounds}
		if summary.wall and summary.wall.attempted_bounds then boxes[#boxes + 1] = summary.wall.attempted_bounds end
		local margins = summary.margins
		if margins then
			if margins.attempted_bounds then boxes[#boxes + 1] = margins.attempted_bounds end
			if margins.stats and margins.stats.written then boxes[#boxes + 1] = margins.stats.written end
		end
		if rural then
			for _, b in ipairs(rural.attempted or {}) do boxes[#boxes + 1] = b end
			for _, b in ipairs(rural.placement_attempted or {}) do boxes[#boxes + 1] = b end
			for _, b in ipairs(rural.boxes or {}) do boxes[#boxes + 1] = b end
		end
		summary.write_bounds = bounds_union(boxes) or urban_bounds
	end
	local rural_called = false
	local writer_started = false
	local rural_structures, rural_write_summary
	local function fail_writer(reason, structures, writer_extra)
		local rural_boxes = {}
		for _, b in ipairs(writer_extra and writer_extra.attempted or {}) do rural_boxes[#rural_boxes + 1] = b end
		for _, b in ipairs(writer_extra and writer_extra.placement_attempted or {}) do rural_boxes[#rural_boxes + 1] = b end
		for _, b in ipairs(writer_extra and writer_extra.boxes or {}) do rural_boxes[#rural_boxes + 1] = b end
		for _, b in ipairs(rural_write_summary and rural_write_summary.attempted or {}) do rural_boxes[#rural_boxes + 1] = b end
		for _, b in ipairs(rural_write_summary and rural_write_summary.placement_attempted or {}) do rural_boxes[#rural_boxes + 1] = b end
		for _, b in ipairs(rural_write_summary and rural_write_summary.boxes or {}) do rural_boxes[#rural_boxes + 1] = b end
		for _, st in ipairs(structures or rural_structures or {}) do
			if st.min and st.max then rural_boxes[#rural_boxes + 1] = {min = st.min, max = st.max} end
		end
		local rural_bounds = bounds_union(rural_boxes)
		local margin = summary.margins
		local extra = writer_extra or {}
		extra.reason = extra.reason or "outskirts_write"
		extra.urban_bounds = urban_bounds
		local margin_boxes = {}
		if margin and margin.attempted_bounds then margin_boxes[#margin_boxes + 1] = margin.attempted_bounds end
		if margin and margin.stats and margin.stats.written then
			margin_boxes[#margin_boxes + 1] = margin.stats.written
		end
		extra.margin_bounds = bounds_union(margin_boxes)
		extra.rural_bounds = rural_bounds
		extra.terrain_attempts = extra.attempted or {}
		extra.placement_attempts = extra.placement_attempted or {}
		local combined = {}
		if urban_bounds then combined[#combined + 1] = urban_bounds end
		if extra.margin_bounds then combined[#combined + 1] = extra.margin_bounds end
		if rural_bounds then combined[#combined + 1] = rural_bounds end
		if summary.wall and summary.wall.attempted_bounds then
			extra.wall_bounds = summary.wall.attempted_bounds
			combined[#combined + 1] = extra.wall_bounds
		end
		extra.bounds = bounds_union(combined) or urban_bounds
		finish(nil, reason, "write_failed", extra)
	end
	local function searched(out, search_message)
		if rural_called or completed then return end
		rural_called = true
		local ok, err = pcall(function()
		if not out then
			warning(summary, "outskirts search failed after urban build: " .. tostring(search_message))
			update_write_bounds()
			return finish(finalize(summary, result), "", nil)
		end
		result.outskirts = out
		local ok, outskirts_pre, outskirts_msg = pcall(
			towns.preflight.check_outskirts, out, built.preflight_env, {
				entries = out.entries, plan = result.plan, player = result.player_pos,
				modpath = towns.modpath,
			})
		if not ok or not outskirts_pre then
			warning(summary, "outskirts preflight failed after urban build: "
				.. tostring(ok and outskirts_msg or outskirts_pre))
			update_write_bounds()
			return finish(finalize(summary, result), "", nil)
		end
		rural_structures = outskirts_pre.structures
		local apply_ok, outskirts_summary, outskirts_error, _, outskirts_extra = pcall(
			function()
				writer_started = true
				return towns.outskirts_build.apply(out, {
					terrain = terrain, place_structure = env.place_structure, get_node = env.get_node,
					node_info = env.node_info, check_door = towns.builder.check_door,
					setup_nodes = env.setup_nodes,
				}, {bounds = result.plan.bounds, structures = outskirts_pre.structures})
			end)
		if not apply_ok or not outskirts_summary then
			return fail_writer(apply_ok and outskirts_error or outskirts_summary,
				outskirts_pre.structures, apply_ok and outskirts_extra or nil)
		end
		rural_write_summary = outskirts_summary
		summary.outskirts = outskirts_summary
		summary.outskirts.counts = out.counts
		summary.town.urban_structure_count = #summary.town.structures
		for _, structure in ipairs(outskirts_summary.structures) do
			summary.town.structures[#summary.town.structures + 1] = structure
		end
		summary.town.urban_placed = summary.town.placed
		summary.town.placed = summary.town.placed + outskirts_summary.placed
		update_write_bounds(outskirts_summary)
		finish(finalize(summary, result), built.message, nil)
		end)
		if not ok and not completed then
			if writer_started then
				fail_writer("outskirts callback failed after writes began: " .. tostring(err),
					rural_structures, rural_write_summary)
			else
				warning(summary, "outskirts callback failed after urban build: " .. tostring(err))
				update_write_bounds()
				finish(finalize(summary, result), "", nil)
			end
		end
	end
	local margin_called = false
	local function after_margin(margin)
		if margin_called or completed then return end
		margin_called = true
		local ok, err = pcall(function()
		summary.margins = margin
		if not margin or margin.status ~= "smoothed" then
			warning(summary, "city margins " .. tostring(margin and margin.status or "failed")
				.. ": " .. tostring(margin and margin.reason or "margin attempt failed"))
		end
		local function start_outskirts()
			local search_ok, search_err = pcall(towns.outskirts.search, result, {
				assets = towns.catalog.entries, terrain = terrain, player_pos = result.player_pos,
			}, searched, towns.site_search.core_env(core))
			if not search_ok then searched(nil, "outskirts search failed: " .. tostring(search_err)) end
		end
		local walls = towns.medieval_walls
		local wall = result.wall
		-- Wall columns inspect the actual post-margin terrain and independently
		-- reject protected, obstructed, or unsupported stretches. A partial
		-- boundary-smoothing result must not suppress the whole wall.
		local bounds = wall and walls.bounds(wall, result.ground_y)
		if not bounds then start_outskirts(); return end
		local settled = false
		local function after_emerge_inner(success)
			if settled or completed then return end
			settled = true
			if not success then
				warning(summary, "wall emerge failed or timed out")
				start_outskirts(); return
			end
			local report = {attempted_bounds = bounds}
			summary.wall = report
			local read_ok, changes, omissions, region = pcall(function()
				local r = assert(env.open_region(bounds.min, bounds.max))
				local c, o = walls.inspect(wall, result.ground_y, r, env.node_info,
					function(pos) return core.is_protected(pos, "") end)
				return c, o, r
			end)
			if not read_ok then
				warning(summary, "wall inspection failed: " .. tostring(changes))
				start_outskirts(); return
			end
			report.omissions, report.placed = omissions, #changes
			if #changes > 0 then
				local first = changes[1]
				report.write_bounds = {min = {x = first.x, y = first.y, z = first.z},
					max = {x = first.x, y = first.y, z = first.z}}
				for _, c in ipairs(changes) do
					for _, axis in ipairs({"x", "y", "z"}) do
						report.write_bounds.min[axis] = math.min(report.write_bounds.min[axis], c[axis])
						report.write_bounds.max[axis] = math.max(report.write_bounds.max[axis], c[axis])
					end
				end
			end
			local wrote, err = pcall(function()
				for _, c in ipairs(changes) do region.set(c.x, c.y, c.z, c.name, c.param2) end
				if #changes > 0 then region.commit() end
			end)
			if not wrote then
				return fail_writer("wall write failed: " .. tostring(err), nil, {bounds = bounds, reason = "wall_write"})
			end
			if #omissions > 0 then warning(summary, ("wall omitted %d columns on difficult terrain or protection"):format(#omissions)) end
			start_outskirts()
		end
		local function after_emerge(success)
			local ok, err = pcall(after_emerge_inner, success)
			if not ok and not completed then
				if not summary.wall then summary.wall = {attempted_bounds = bounds} end
				fail_writer("wall callback failed: " .. tostring(err), nil,
					{bounds = bounds, reason = "wall_callback"})
			end
		end
		local wall_env = towns.site_search.core_env(core)
		local started, emerge_err = pcall(wall_env.emerge, bounds.min, bounds.max, after_emerge)
		if not started then warning(summary, "wall emerge failed: " .. tostring(emerge_err)); after_emerge(false)
		elseif not settled then
			local timer_ok = pcall(wall_env.after, 30, function() after_emerge(false) end)
			if not timer_ok then after_emerge(false) end
		end
		end)
		if not ok and not completed then
			if writer_started then
				fail_writer("city-margin callback failed after rural writes began: " .. tostring(err), nil)
			else
				warning(summary, "city-margin callback failed: " .. tostring(err))
				update_write_bounds()
				finish(finalize(summary, result), "", nil)
			end
		end
	end
	if not margin_api or type(margin_api.attempt) ~= "function" then
		after_margin({status = "skipped", reason = margin_err and ("city-margin adapter failed: " .. tostring(margin_err))
			or "Living Villages city-margin API is unavailable"})
	else
		local env_ok, api_env = pcall(towns.site_search.core_env, core)
		if not env_ok then
			after_margin({status = "incomplete", reason = "city-margin environment failed: " .. tostring(api_env)})
		else
			local ok, err = pcall(margin_api.attempt, result, after_margin, api_env)
			if not ok then after_margin({status = "incomplete", reason = "city-margin attempt failed: " .. tostring(err)}) end
		end
	end
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
