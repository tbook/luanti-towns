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

-- Automatic towns deliberately ignore protection-mod claims. Commands retain
-- the existing pointwise checks for walls, roads and margins.
local function protection_check(context, pos)
	if context then return false end
	return core.is_protected(pos, "")
end

local function profile()
	return assert(towns.planner.landmark_profile(towns.catalog.snapshot()))
end

-- Use the same asset validation before population and again before placement.
local function valid_wall_entries()
 local valid_entries = {}
 for _, id in ipairs({"wall_gatehouse", "wall_postern", "wall_tower", "wall_tower_inline", "wall_tower_inline_alt"}) do
  local entry = towns.catalog.entries[id]
  local ok, valid = pcall(function()
   local sc = assert(core.read_schematic(towns.modpath .. "/" .. entry.path, {}))
   assert(sc.size.x == entry.size.x and sc.size.y == entry.size.y and sc.size.z == entry.size.z)
   return towns.schematic.validate(entry, towns.modpath)
  end)
  if ok and valid then valid_entries[id] = entry
  else core.log("warning", "towns: " .. id .. " asset unavailable; using ordinary walls") end
 end
 return valid_entries
end

-- Search and build halves, exposed for headless validation
-- (tools/place_check) as towns.populated. `town_type` is "medieval" (nil
-- means medieval) or "roman"; both share every stage after the plan.
local function search(pos, seed, town_type, done, force_walls)
	-- Ticket #104: wet sites (shallow ponds, rivers, ice) are landfilled under
	-- the conservative towns.site_search.WET_DEFAULTS.
	local opts = {}
	if town_type == "roman" then
		-- Authored plan (issue #148); composition needs the catalog entries.
		opts.planner_opts = {town_type = "roman"}
		opts.entries = towns.catalog.entries
	else
		opts.planner_opts = {landmarks = profile(), force_walls = force_walls,
			wall_feature_entries = valid_wall_entries()}
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

-- " blocker=(x,y,z) node=name" suffix for an omission blocker, or "".
local function blocker_text(b)
	if not b then return "" end
	if b.x and b.y and b.z then
		return (" blocker=(%d,%d,%d) node=%s"):format(b.x, b.y, b.z, tostring(b.node))
	end
	return " blocker=unknown node=" .. tostring(b.node or "unknown")
end

local function integer(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge and n == math.floor(n)
end

local function valid_box(box)
	return type(box) == "table" and type(box.min) == "table" and type(box.max) == "table"
		and integer(box.min.x) and integer(box.min.y) and integer(box.min.z)
		and integer(box.max.x) and integer(box.max.y) and integer(box.max.z)
		and box.min.x <= box.max.x and box.min.y <= box.max.y and box.min.z <= box.max.z
end

local function contains_box(outer, inner)
	return valid_box(outer) and valid_box(inner)
		and inner.min.x >= outer.min.x and inner.min.y >= outer.min.y and inner.min.z >= outer.min.z
		and inner.max.x <= outer.max.x and inner.max.y <= outer.max.y and inner.max.z <= outer.max.z
end

local function automatic_env(base, automatic_context)
	if not automatic_context then return base end
	local env = {}
	for k, v in pairs(base) do env[k] = v end
	env.emerge = function(minp, maxp, done)
		local box = {min = minp, max = maxp}
		if not contains_box(automatic_context.read_bounds, box) then
			return done(false)
		end
		local settled = false
		local function finish(ok)
			if settled then return end
			settled = true
			local called, err = pcall(done, ok == true)
			if not called and automatic_context.log then
				pcall(automatic_context.log, "error", "automatic stage callback failed: " .. tostring(err))
			end
			if not called and automatic_context.callback_failed then
				pcall(automatic_context.callback_failed, err)
			end
		end
		local ok, err = pcall(automatic_context.ensure_loaded, minp, maxp, finish)
		if not ok then
			if automatic_context.log then pcall(automatic_context.log, "error", "approved town load failed: " .. tostring(err)) end
			return finish(false)
		end
	end
	return env
end

local function automatic_context_ok(context)
	return context == nil or (type(context) == "table" and valid_box(context.read_bounds)
		and valid_box(context.write_bounds) and type(context.ensure_loaded) == "function"
		and type(context.before_write) == "function")
end

local function build_urban(result, automatic_context, done)
	local walls = towns.medieval_walls
	if automatic_context then result.automatic_wall_omission = nil end
	if walls and result.plan.town_type == "medieval" then
		result.wall = walls.plan(result.plan, result.force_walls)
		if result.wall and automatic_context then
			local b = walls.bounds(result.wall, result.ground_y)
			if not contains_box(automatic_context.read_bounds, b)
					or not contains_box(automatic_context.write_bounds, b) then
				core.log("warning", "towns: walls omitted: declared volume exceeds the approved automatic-town envelope")
				result.automatic_wall_omission = "declared volume exceeds the approved automatic-town envelope"
				result.wall = nil
			end
		end
		if result.wall then
			local wall_bounds = walls.bounds(result.wall, result.ground_y)
			if wall_bounds then
				-- A boundary wall sits one node beyond town; its five-node apron
				-- therefore needs six nodes of placement room.
				local b = result.plan.bounds
				local margin = towns.outskirts.CONSTANTS.PROTECT_MARGIN
				if wall_bounds.min.x < b.x1 - margin or wall_bounds.max.x > b.x2 + margin
						or wall_bounds.min.z < b.z1 - margin or wall_bounds.max.z > b.z2 + margin then
					return nil, "Wall clearance exceeds the town boundary margin", "inspection_failed"
				end
				for _, axis in ipairs({"x", "y", "z"}) do
					if math.abs(wall_bounds.min[axis]) > towns.preflight.LIMIT
							or math.abs(wall_bounds.max[axis]) > towns.preflight.LIMIT then
						return nil, "Wall envelope exceeds map limits", "inspection_failed"
					end
				end
			end
			if not automatic_context and type(core.is_protected) ~= "function" then
				return nil, "Wall protection API is unavailable", "inspection_failed"
			end
			for _, node in ipairs({walls.BRICK, walls.STAIR}) do
				if not core.registered_nodes[node] then
					return nil, "Wall node is not registered: " .. node, "inspection_failed"
				end
			end
			local ok, err = pcall(walls.reserve, result.wall, result.ground_y,
				function(pos) return protection_check(automatic_context, pos) end)
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
	if automatic_context then
		if not contains_box(automatic_context.write_bounds, pre.volume) then
			return nil, "Urban build volume exceeds the approved automatic-town write envelope.",
				"inspection_failed", {reason = "automatic_envelope"}
		end
		local read_box = bounds_union({pre.volume, towns.builder.read_bounds(result)})
		if not contains_box(automatic_context.read_bounds, read_box) then
			return nil, "Urban inspection exceeds the approved automatic-town read envelope.",
				"inspection_failed", {reason = "automatic_envelope"}
		end
		pre.automatic_read_bounds = read_box
	end
	if result.wall and towns.medieval_wall_features then
		local features = towns.medieval_wall_features
		local valid_entries = valid_wall_entries()
  local candidates = features.candidates(result.wall, result.ground_y, valid_entries, walls,
   function(candidate) core.log("warning", "towns: " .. candidate.asset
		.. " omitted: missing adjoining wall columns") end)
		if automatic_context then
			local bounded = {}
			for _, feature in ipairs(candidates) do
				local boxes = {{min = {x = feature.min.x,
					y = feature.min.y - features.FOUNDATION_DEPTH, z = feature.min.z}, max = feature.max},
					walls.feature_clearance_bounds(feature, result.ground_y)}
				if feature.outside_approach then
					boxes[#boxes + 1] = walls.approach_bounds(feature.outside_approach, result.ground_y)
				end
				local box = bounds_union(boxes)
				if contains_box(automatic_context.read_bounds, box)
						and contains_box(automatic_context.write_bounds, box) then bounded[#bounded + 1] = feature
				else core.log("warning", "towns: " .. feature.asset .. " omitted: automatic-town envelope") end
			end
			candidates = bounded
		end
		local rejected
		result.wall_features, result.wall_feature_footprints, rejected = features.select(candidates,
			pre.structures, result.plan.streets, function(pos) return protection_check(automatic_context, pos) end)
		for _, feature in ipairs(result.wall_features) do
			local apron = walls.feature_clearance_bounds(feature, result.ground_y)
			if apron then
				for _, axis in ipairs({"x", "y", "z"}) do
					if math.abs(apron.min[axis]) > towns.preflight.LIMIT or math.abs(apron.max[axis]) > towns.preflight.LIMIT then
						return nil, "Wall feature clearance exceeds map limits", "inspection_failed"
					end
				end
			end
			walls.reserve_feature_clearance(feature, result.ground_y, function(pos) return protection_check(automatic_context, pos) end)
		end
		for _, r in ipairs(rejected or {}) do
			core.log("warning", ("towns: %s at (%d,%d) omitted: %s"):format(
				r.candidate.asset, r.candidate.min.x, r.candidate.min.z, r.reason))
		end
	end
	local env = towns.builder.core_env(core, {
		schematic = towns.schematic, modpath = towns.modpath,
		node_setup = towns.node_setup,
		globals = {itemframes = rawget(_G, "mcl_itemframes"), chests = rawget(_G, "mcl_chests")},
	})
	if automatic_context then
		local get_node, open_region = env.get_node, env.open_region
		env.get_node = function(x, y, z)
			local p = {x = x, y = y, z = z}
			if not contains_box(automatic_context.read_bounds, {min = p, max = p}) then return "ignore" end
			return get_node(x, y, z)
		end
		if open_region then env.open_region = function(minp, maxp)
			if not contains_box(automatic_context.read_bounds, {min = minp, max = maxp}) then
				return nil, "region exceeds approved automatic-town read envelope"
			end
			return open_region(minp, maxp)
		end end
	end
	local write_started = false
	local function write_urban()
		local summary, bmsg, bcode, extra = towns.builder.build_town(
			result, {entries = towns.catalog.entries, before_write = automatic_context and function()
				local ok, why = automatic_context.before_write()
				if ok then write_started = true end
				return ok, why
			end}, env)
		if not summary then
			if bcode == "write_failed" then
				extra = extra or {}
				extra.urban_bounds = extra.bounds or result.write_bounds or result.build_bounds
				extra.bounds = extra.bounds or extra.urban_bounds
				extra.terrain_attempts, extra.placement_attempts = {}, {}
			end
			if done then done(nil, bmsg, bcode, extra) end
			return nil, bmsg, bcode, extra
		end
		local built = {summary = summary, message = bmsg, terrain = terrain, env = env,
			preflight_env = env_preflight}
		if done then done(built) end
		return built
	end
	if not automatic_context then return write_urban() end
	local settled = false
	local function after_load(ok)
		if settled then return end
		settled = true
		if ok ~= true then
			if done then done(nil, "Approved urban build volume could not be loaded.", "emerge_failed") end
			return
		end
		local called, err = pcall(write_urban)
		if not called and done then
			done(nil, "Urban build callback failed: " .. tostring(err), write_started and "write_failed" or "inspection_failed",
				write_started and {bounds = pre.volume, urban_bounds = pre.volume, reason = "urban_callback"} or nil)
		end
	end
	local box = pre.automatic_read_bounds
	local ok, err = pcall(automatic_context.ensure_loaded, box.min, box.max, after_load)
	if not ok then after_load(false) end
	if not settled then
		local timer_ok = pcall(core.after, 30, function() after_load(false) end)
		if not timer_ok then after_load(false) end
	end
	return nil, nil, nil, nil
end

-- Context for towns.aqueduct_step.run. Manual builds get a full environment:
-- no freshness or clearance checks (manual generation overwrites by design),
-- but protection is honoured per write position by the adapter. An automatic
-- town only builds an aqueduct when its context supplies the capability
-- `automatic_context.aqueduct = {authorize_strip = fn(box), emerge = fn(min,
-- max, cb) (optional), y_min, y_max (optional clamp), timeout (optional)}`
-- (step 4 of #417). Without it the aqueduct is skipped and nothing is written.
local function aqueduct_context(builder_env, automatic_context)
	local ctx = {log = function(level, msg) core.log(level, msg) end,
		after = function(seconds, fn) core.after(seconds, fn) end}
	local cap = automatic_context and automatic_context.aqueduct
	if automatic_context and (type(cap) ~= "table" or type(cap.authorize_strip) ~= "function"
			or type(automatic_context.check_ownership) ~= "function") then
		ctx.skip_reason = "automatic town has no aqueduct capability"
		return ctx
	end
	local base = towns.site_search.core_env(core)
	local emerge = cap and cap.emerge or base.emerge
	ctx.env = towns.aqueduct_step.make_env({
		emerge = emerge,
		open_region = builder_env.open_region,
		authorize_strip = cap and cap.authorize_strip,
		check_ownership = automatic_context and automatic_context.check_ownership or function() return true end,
		protected = function(pos) return protection_check(automatic_context, pos) end,
		after = function(seconds, fn) core.after(seconds, fn) end,
		set_node = function(pos, node) core.set_node(pos, node) end,
		registered_nodes = core.registered_nodes,
	})
	ctx.opts = cap and {y_min = cap.y_min, y_max = cap.y_max, timeout = cap.timeout} or nil
	return ctx
end

local function build(result, done, automatic_context)
	local completed = false
	local function finish(summary, message, code, extra)
		if completed then return end
		completed = true
		done(summary, message, code, extra)
	end
	if not automatic_context_ok(automatic_context) then
		return finish(nil, "Invalid automatic town build context.", "invalid_automatic_context")
	end
	local function continue_build(built, message, code, extra)
	if completed then return end
	if not built then finish(nil, message, code, extra); return end
	local summary, terrain, env = built.summary, built.terrain, built.env
	if automatic_context and result.automatic_wall_omission then
		warning(summary, "walls omitted: " .. result.automatic_wall_omission)
		summary.wall = {skipped = true, reason = result.automatic_wall_omission}
	end
	if automatic_context then
		local urban_box = summary.write_bounds or summary.town.bounds
		if not contains_box(automatic_context.write_bounds, urban_box) then
			finish(nil, "Urban builder exceeded the approved automatic-town write envelope.", "write_failed",
				{reason = "automatic_envelope", urban_bounds = urban_box, bounds = urban_box})
			return
		end
	end
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
		if summary.roads and summary.roads.attempted_bounds then boxes[#boxes + 1] = summary.roads.attempted_bounds end
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
		if automatic_context and not contains_box(automatic_context.write_bounds, summary.write_bounds) then
			summary.automatic_envelope_excess = summary.write_bounds
		end
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
		if extra.bounds then combined[#combined + 1] = extra.bounds end
		if urban_bounds then combined[#combined + 1] = urban_bounds end
		if extra.margin_bounds then combined[#combined + 1] = extra.margin_bounds end
		if rural_bounds then combined[#combined + 1] = rural_bounds end
		if summary.wall and summary.wall.attempted_bounds then
			extra.wall_bounds = summary.wall.attempted_bounds
			combined[#combined + 1] = extra.wall_bounds
		end
		if summary.roads and summary.roads.attempted_bounds then
			extra.road_bounds = summary.roads.attempted_bounds
			combined[#combined + 1] = extra.road_bounds
		end
		extra.bounds = bounds_union(combined) or urban_bounds
		finish(nil, reason, "write_failed", extra)
	end
	local aqueduct_started = false
	local function finish_build(message)
		if automatic_context and automatic_context.check_ownership then
			local allowed, why = automatic_context.check_ownership()
			if not allowed then return fail_writer("Write ownership check failed: " .. tostring(why), nil) end
		end
		if summary.automatic_envelope_excess then
			return fail_writer("Automatic town build exceeded its approved write envelope.", nil,
				{reason = "automatic_envelope", bounds = summary.automatic_envelope_excess})
		end
		local step = towns.aqueduct_step
		if not step or not result.plan or result.plan.town_type ~= "roman" then
			return finish(finalize(summary, result), message or "", nil)
		end
		if aqueduct_started then return end
		aqueduct_started = true
		-- The aqueduct (Roman towns only) is a cosmetic extra after the town is
		-- final: it never fails the town and the continuation runs exactly once.
		-- A finalize error may surface from a timer, outside any caller pcall, so
		-- it fails the build here with the combined bounds of everything written.
		local function proceed()
			if completed then return end
			local ok, err = pcall(function() finish(finalize(summary, result), message or "", nil) end)
			if not ok and not completed then
				core.log("error", "towns: finalizing the town failed: " .. tostring(err))
				fail_writer("Town finalization failed: " .. tostring(err), nil, {reason = "finalize"})
			end
		end
		local ok, err = pcall(function()
			step.run(result, summary, aqueduct_context(env, automatic_context), proceed)
		end)
		if not ok then
			core.log("warning", "towns: aqueduct step failed: " .. tostring(err))
			summary.aqueduct = summary.aqueduct or {status = "skipped", reason = "error: " .. tostring(err)}
			proceed()
		end
	end
	local function searched(out, search_message)
		if rural_called or completed then return end
		rural_called = true
		local ok, err = pcall(function()
		if not out then
			warning(summary, "outskirts search failed after urban build: " .. tostring(search_message))
			update_write_bounds()
			return finish_build("")
		end
		result.outskirts = out
		local ok, outskirts_pre, outskirts_msg = pcall(
			towns.preflight.check_outskirts, out, built.preflight_env, {
				entries = out.entries, plan = result.plan, player = result.player_pos,
				modpath = towns.modpath, feature_footprints = result.wall_feature_footprints,
			})
		if not ok or not outskirts_pre then
			warning(summary, "outskirts preflight failed after urban build: "
				.. tostring(ok and outskirts_msg or outskirts_pre))
			update_write_bounds()
			return finish_build("")
		end
		rural_structures = outskirts_pre.structures
		if automatic_context and automatic_context.check_ownership then
			local allowed, why = automatic_context.check_ownership()
			if not allowed then return fail_writer("Write ownership check failed: " .. tostring(why), nil) end
		end
		local apply_ok, outskirts_summary, outskirts_error, _, outskirts_extra = pcall(
			function()
				writer_started = true
				return towns.outskirts_build.apply(out, {
					terrain = terrain, place_structure = env.place_structure, get_node = env.get_node,
					node_info = env.node_info, check_door = towns.builder.check_door,
					setup_nodes = env.setup_nodes,
				}, {bounds = result.plan.bounds, structures = outskirts_pre.structures,
					feature_footprints = result.wall_feature_footprints,
					automatic_context = automatic_context})
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
		finish_build(built.message)
		end)
		if not ok and not completed then
			if writer_started then
				fail_writer("outskirts callback failed after writes began: " .. tostring(err),
					rural_structures, rural_write_summary)
			elseif automatic_context then
				fail_writer("outskirts callback failed after urban build: " .. tostring(err), nil)
			else
				warning(summary, "outskirts callback failed after urban build: " .. tostring(err))
				update_write_bounds()
				finish_build("")
			end
		end
	end
	local margin_called = false
	local function after_margin(margin)
		if margin_called or completed then return end
		margin_called = true
		local ok, err = pcall(function()
		summary.margins = margin
		if margin and margin.write_denied then
			return fail_writer("Write ownership check failed: " .. tostring(margin.reason), nil)
		end
		if not margin or margin.status ~= "smoothed" then
			warning(summary, "city margins " .. tostring(margin and margin.status or "failed")
				.. ": " .. tostring(margin and margin.reason or "margin attempt failed"))
		end
		local function start_outskirts()
			local search_ok, search_err = pcall(towns.outskirts.search, result, {
				assets = towns.catalog.entries, terrain = terrain, player_pos = result.player_pos,
				feature_footprints = result.wall_feature_footprints,
				automatic_context = automatic_context,
			}, searched, automatic_env(towns.site_search.core_env(core), automatic_context))
			if not search_ok then searched(nil, "outskirts search failed: " .. tostring(search_err)) end
		end
		local walls = towns.medieval_walls
		local wall = result.wall
		-- Unwalled towns (and Roman towns) grade their road exits down to natural
		-- terrain before the outskirts search, reserving the ramps.
		local roads = towns.town_roads
		result.exits = result.exits or (roads and result.plan and roads.exits(result.plan)) or {}
		if not wall and #result.exits > 0 then
			local boxes = {}
			for _, columns in ipairs(roads.crossings(result.exits)) do
				boxes[#boxes + 1] = roads.approach_bounds(columns, result.ground_y)
			end
			local bounds = bounds_union(boxes)
			if automatic_context and not contains_box(automatic_context.write_bounds, bounds) then
				local reason = "declared volume exceeds the approved automatic-town envelope"
				summary.roads = {skipped = true, reason = reason}
				warning(summary, "outside roads omitted: " .. reason)
				start_outskirts(); return
			end
			local settled = false
			local function graded_inner(success)
				if settled or completed then return end
				settled = true
				if not success then
					warning(summary, "road exit emerge failed or timed out")
					start_outskirts(); return
				end
				if automatic_context and automatic_context.check_ownership then
					local allowed, why = automatic_context.check_ownership()
					if not allowed then return fail_writer("Write ownership check failed: " .. tostring(why), nil) end
				end
				local report = {attempted_bounds = bounds, graded = 0, failed = 0}
				summary.roads = report
				local read_ok, changes, failures, footprints, region = pcall(function()
					local r = assert(env.open_region(bounds.min, bounds.max))
					local c, f, fp = roads.grade(result.exits, result.ground_y, r, env.node_info,
						function(pos) return protection_check(automatic_context, pos) end)
					return c, f, fp, r
				end)
				if not read_ok then
					warning(summary, "road exit inspection failed: " .. tostring(changes))
					start_outskirts(); return
				end
				report.graded, report.failed = #footprints, #failures
				for _, f in ipairs(failures) do
					warning(summary, ("road exit at (%d,%d) left ungraded: %s%s"):format(
						f.x, f.z, f.reason, blocker_text(f.blocker)))
				end
				local wrote, err = pcall(function()
					for _, c in ipairs(changes) do region.set(c.x, c.y, c.z, c.name, c.param2) end
					if #changes > 0 then region.commit() end
				end)
				if not wrote then
					return fail_writer("road exit write failed: " .. tostring(err), nil,
						{bounds = bounds, reason = "road_write"})
				end
				local meta_ok, meta_err = pcall(towns.medieval_walls.clear_metadata, core, changes)
				if not meta_ok then warning(summary, "road exit metadata cleanup failed: " .. tostring(meta_err)) end
				result.wall_feature_footprints = result.wall_feature_footprints or {}
				for _, rect in ipairs(footprints) do
					result.wall_feature_footprints[#result.wall_feature_footprints + 1] = rect
				end
				start_outskirts()
			end
			local function graded(success)
				local ok, err = pcall(graded_inner, success)
				if not ok and not completed then
					if not summary.roads then summary.roads = {attempted_bounds = bounds, graded = 0, failed = 0} end
					fail_writer("road exit callback failed: " .. tostring(err), nil,
						{bounds = bounds, reason = "road_callback"})
				end
			end
			local road_env = automatic_env(towns.site_search.core_env(core), automatic_context)
			local started, emerge_err = pcall(road_env.emerge, bounds.min, bounds.max, graded)
			if not started then warning(summary, "road exit emerge failed: " .. tostring(emerge_err)); graded(false)
			elseif not settled then
				-- `settled` makes a late emerge callback or a timer after completion a no-op.
				local timer_ok = pcall(road_env.after, 30, function() graded(false) end)
				if not timer_ok then graded(false) end
			end
			return
		end
		-- Wall columns inspect the actual post-margin terrain and independently
		-- reject protected, obstructed, or unsupported stretches. A partial
		-- boundary-smoothing result must not suppress the whole wall.
		local wall_bounds = wall and walls.bounds(wall, result.ground_y)
		local boxes = {wall_bounds}
		for _, columns in ipairs(wall and walls.bare_crossings(wall.openings) or {}) do
			boxes[#boxes + 1] = walls.approach_bounds(columns, result.ground_y)
		end
		for _, feature in ipairs(result.wall_features or {}) do
			boxes[#boxes + 1] = walls.feature_clearance_bounds(feature, result.ground_y)
			boxes[#boxes + 1] = {min = {x = feature.min.x,
				y = feature.min.y - towns.medieval_wall_features.FOUNDATION_DEPTH, z = feature.min.z}, max = feature.max}
			if feature.outside_approach then
				boxes[#boxes + 1] = walls.approach_bounds(feature.outside_approach, result.ground_y)
			end
		end
		local bounds = bounds_union(boxes)
		if not bounds then start_outskirts(); return end
		if automatic_context and not contains_box(automatic_context.write_bounds, bounds) then
			local reason = "declared volume exceeds the approved automatic-town envelope"
			summary.wall = {skipped = true, reason = reason}
			warning(summary, "walls and wall features omitted: " .. reason)
			result.wall, result.wall_features, result.wall_feature_footprints = nil, nil, nil
			start_outskirts(); return
		end
		local settled = false
		local function after_emerge_inner(success)
			if settled or completed then return end
			settled = true
			if not success then
				warning(summary, "wall emerge failed or timed out")
				result.wall_feature_footprints = {}
				start_outskirts(); return
			end
			if automatic_context and automatic_context.check_ownership then
				local allowed, why = automatic_context.check_ownership()
				if not allowed then return fail_writer("Write ownership check failed: " .. tostring(why), nil) end
			end
			local report = {attempted_bounds = bounds}
			summary.wall = report
			-- Apply the ordinary wall clearance before inspecting features. This
			-- only clears wall-owned cells; feature-specific cuts are committed
			-- after the entire feature passes inspection.
			local preclear = {}
			local stage_ok, stage_err = pcall(function()
				local region = assert(env.open_region(bounds.min, bounds.max))
				local changes = walls.inspect(wall, result.ground_y, region, env.node_info,
					function(pos) return protection_check(automatic_context, pos) end)
				for _, change in ipairs(changes) do
					if change.clearance then
						preclear[#preclear + 1] = change
						region.set(change.x, change.y, change.z, change.name, change.param2)
					end
				end
				if #preclear > 0 then region.commit() end
			end)
			if not stage_ok then
				return fail_writer("wall clearance failed: " .. tostring(stage_err), nil,
					{bounds = bounds, reason = "wall_clearance"})
			end
			local preclear_metadata_ok, preclear_metadata_err = pcall(walls.clear_metadata, core, preclear)
			if not preclear_metadata_ok then
				warning(summary, "wall clearance metadata cleanup failed: " .. tostring(preclear_metadata_err))
			end
			local placed_features, placed_footprints, wall_masks, placed_candidates = {}, {}, {}, {}
			local feature_api = towns.medieval_wall_features
			for _, feature in ipairs(result.wall_features or {}) do
				local entry = towns.catalog.entries[feature.asset]
				local read_ok, eligible, detail, feature_region, approach_changes, feature_clearance = pcall(function()
					local raw_region = assert(env.open_region(bounds.min, bounds.max))
					local r = raw_region
					local ok, detail, clearance = feature_api.inspect(feature, r, env.node_info,
						function(pos) return protection_check(automatic_context, pos) end, walls.natural)
					if ok and feature.outside_approach then
						local joins = feature_api.gate_join_cells(feature, wall)
						if not joins then return nil, "missing adjoining wall columns", r end
						local _, join_omissions = walls.inspect({cells = joins, openings = {}},
							result.ground_y, r, env.node_info, function(pos) return protection_check(automatic_context, pos) end)
						for _, omission in ipairs(join_omissions) do
							if not omission.reason:match("^decoration: ") then
								return nil, "wall join: " .. omission.reason .. blocker_text(omission.blocker), r
							end
						end
						local changes, omissions, length = walls.approach(feature.outside_approach,
							result.ground_y, r, env.node_info, function(pos) return protection_check(automatic_context, pos) end)
						if #omissions > 0 then
							return nil, "outside road: " .. omissions[1].reason .. blocker_text(omissions[1].blocker), r
						end
						feature.approach_length = length
						return ok, detail, raw_region, changes, clearance
					end
					return ok, detail, raw_region, nil, clearance
				end)
				if not read_ok or not eligible then
					warning(summary, ("%s at (%d,%d) omitted: %s"):format(feature.asset,
						feature.min.x, feature.min.z, tostring(read_ok and detail or eligible)))
				else
					-- Read overwritten cathedral/castle nodes before the tower writes them.
					local overwritten = feature_api.overwritten_nodes(feature, feature_region, detail)
					local foundation_ok, foundation_error = pcall(function()
						for _, p in ipairs(feature_clearance or {}) do feature_region.set(p.x, p.y, p.z, p.name, p.param2) end
						for _, p in ipairs(detail) do feature_region.set(p.x, p.y, p.z, walls.BRICK, 0) end
						for _, c in ipairs(approach_changes or {}) do feature_region.set(c.x, c.y, c.z, c.name, c.param2) end
						if #detail > 0 or (feature_clearance and #feature_clearance > 0)
								or (approach_changes and #approach_changes > 0) then feature_region.commit() end
					end)
					if not foundation_ok then
						return fail_writer("tower foundation failed: " .. tostring(foundation_error), nil,
							{bounds = bounds, reason = "wall_feature_foundation"})
					end
					if feature_clearance and #feature_clearance > 0 then
						local metadata_ok, metadata_err = pcall(walls.clear_metadata, core, feature_clearance)
						if not metadata_ok then warning(summary, "wall feature clearance metadata cleanup failed: " .. tostring(metadata_err)) end
					end
					if approach_changes and #approach_changes > 0 then
						local road_metadata_ok, road_metadata_err = pcall(walls.clear_metadata, core, approach_changes)
						if not road_metadata_ok then warning(summary, "wall approach metadata cleanup failed: " .. tostring(road_metadata_err)) end
					end
					local foundation_metadata_ok, foundation_metadata_err = pcall(walls.clear_metadata, core, detail)
					if not foundation_metadata_ok then warning(summary, "wall foundation metadata cleanup failed: " .. tostring(foundation_metadata_err)) end
					local st = towns.geometry.place(entry, feature.min, feature.rotation)
					st.id, st.kind, st.rect = feature.asset, "wall_feature", feature_api.footprint(feature)
					local called, success, place_error = pcall(env.place_structure, st, entry)
					if not called or not success then
						return fail_writer("tower placement failed: " .. tostring(called and place_error or success), nil,
							{bounds = bounds, reason = "wall_feature_write"})
					end
					-- Like wall clearance, VoxelManip writes skip node destruction callbacks.
					local meta_ok, meta_error = pcall(walls.clear_metadata, core, overwritten)
					if not meta_ok then warning(summary, "tower metadata cleanup failed: " .. tostring(meta_error)) end
					placed_candidates[#placed_candidates + 1] = feature
					placed_features[#placed_features + 1] = st
					wall_masks[#wall_masks + 1] = st.rect
					placed_footprints[#placed_footprints + 1] = feature.reserve_rect or st.rect
					if feature.approach_length then
						placed_footprints[#placed_footprints + 1] = walls.approach_rect(feature.outside_approach, feature.approach_length)
					end
					local apron = walls.feature_clearance_bounds(feature, result.ground_y)
					if apron then placed_footprints[#placed_footprints + 1] = {x1=apron.min.x,z1=apron.min.z,x2=apron.max.x,z2=apron.max.z} end
				end
			end
			if #placed_features > 0 then
				local ok, setup = pcall(env.setup_nodes, placed_features, towns.catalog.entries)
				if not ok or type(setup) ~= "table" or type(setup.failed) ~= "table"
						or #setup.failed > 0 or type(setup.unregistered) ~= "table" or #setup.unregistered > 0 then
					return fail_writer("tower node setup failed: " .. tostring(setup), nil,
						{bounds = bounds, reason = "wall_feature_setup"})
				end
				for _, st in ipairs(placed_features) do summary.town.structures[#summary.town.structures + 1] = st end
				summary.town.placed = summary.town.placed + #placed_features
			end
			report.features = placed_features
			result.wall_feature_footprints = placed_footprints
			local remaining = feature_api and feature_api.remaining_wall(wall, wall_masks) or wall
			remaining.placed_features = placed_candidates
			remaining.road_openings = wall.openings
			remaining.streets = result.plan.streets
			local read_ok, changes, omissions, region, ramp_footprints = pcall(function()
				local r = assert(env.open_region(bounds.min, bounds.max))
				local is_protected = function(pos) return protection_check(automatic_context, pos) end
				-- Openings left without a gatehouse/postern get the graded ramp.
				local c, o, ramp_failures, graded_footprints = walls.inspect_graded(remaining,
					result.ground_y, r, env.node_info, is_protected)
				for _, f in ipairs(ramp_failures) do
					warning(summary, ("wall opening at (%d,%d) left ungraded: %s%s"):format(
						f.x, f.z, f.reason, blocker_text(f.blocker)))
				end
				return c, o, r, graded_footprints
			end)
			if not read_ok then
				warning(summary, "wall inspection failed: " .. tostring(changes))
				start_outskirts(); return
			end
			report.omissions = omissions
			report.placed, report.clearance = 0, #preclear
			for _, change in ipairs(changes) do
				if change.clearance then report.clearance = report.clearance + 1
				elseif change.name == walls.BRICK or change.name == walls.STAIR then
					report.placed = report.placed + 1
				end
			end
			if #changes > 0 or #preclear > 0 then
				local first = changes[1] or preclear[1]
				report.write_bounds = {min = {x = first.x, y = first.y, z = first.z},
					max = {x = first.x, y = first.y, z = first.z}}
				local reported_changes = {}
				for _, c in ipairs(preclear) do reported_changes[#reported_changes + 1] = c end
				for _, c in ipairs(changes) do reported_changes[#reported_changes + 1] = c end
				for _, c in ipairs(reported_changes) do
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
			-- Graded bare openings keep their ramps reserved from outskirts terraforming.
			for _, rect in ipairs(ramp_footprints or {}) do
				result.wall_feature_footprints[#result.wall_feature_footprints + 1] = rect
			end
			-- VoxelManip writes bypass node destruction callbacks. Remove metadata
			-- and timers only after the map write succeeds, so cleared chests and
			-- other nodes cannot leave stale inventories behind.
			local metadata_ok, metadata_err = pcall(walls.clear_metadata, core, changes)
			if not metadata_ok then warning(summary, "wall clearance metadata cleanup failed: " .. tostring(metadata_err)) end
			local counts = {wall = 0, decoration = 0, approach = 0}
			for _, omission in ipairs(omissions) do
				local kind = omission.reason:match("^(decoration): ") or omission.reason:match("^(approach): ") or "wall"
				counts[kind] = counts[kind] + 1
			end
			if counts.wall > 0 then warning(summary, ("wall omitted %d columns due to terrain, obstructions or protection"):format(counts.wall)) end
			if counts.decoration > 0 then warning(summary, ("wall decorations omitted: %d due to obstructions or protection"):format(counts.decoration)) end
			if counts.approach > 0 then warning(summary, ("wall approach omitted %d columns due to terrain, obstructions or protection"):format(counts.approach)) end
			-- Keep the log useful for diagnosing the specific gap while bounding
			-- output for unusually rough town edges. Every record includes the
			-- omitted column and, where available, the exact blocking node.
			local diagnostic_limit = 24
			local diagnostic_order = {}
			for _, o in ipairs(omissions) do diagnostic_order[#diagnostic_order + 1] = o end
			local function priority(o)
				if o.reason:match("^decoration: ") then return 3 end
				if o.reason:match("^approach: ") then return 2 end
				return 1
			end
			table.sort(diagnostic_order, function(a, b)
				local ap, bp = priority(a), priority(b)
				if ap ~= bp then return ap < bp end
				if a.x ~= b.x then return a.x < b.x end
				if a.z ~= b.z then return a.z < b.z end
				return a.reason < b.reason
			end)
			for i = 1, math.min(#diagnostic_order, diagnostic_limit) do
				local o, b = diagnostic_order[i], diagnostic_order[i].blocker
				local kind = o.reason:match("^(decoration): ") or o.reason:match("^(approach): ") or "wall"
				local message = ("wall gap kind=%s column=(%d,%d) reason=%s")
					:format(kind, o.x, o.z, o.reason:gsub("^(decoration): ", ""):gsub("^(approach): ", ""))
				if b then
					if b.x and b.y and b.z then
						message = message .. (" blocker=(%d,%d,%d) node=%s")
							:format(b.x, b.y, b.z, tostring(b.node))
					else
						message = message .. " blocker=unknown node=" .. tostring(b.node or "unknown")
					end
					if b.search_limit_y then message = message .. " search_limit_y=" .. tostring(b.search_limit_y) end
				end
				core.log("warning", "towns: " .. message)
			end
			if #omissions > diagnostic_limit then
				local causes = {}
				for _, o in ipairs(omissions) do
					local reason = o.reason:gsub("^(decoration): ", ""):gsub("^(approach): ", "")
					local node = o.blocker and o.blocker.node or "unknown"
					local key = reason .. " node=" .. tostring(node)
					causes[key] = (causes[key] or 0) + 1
				end
				core.log("warning", ("towns: wall gap diagnostics capped at %d; %d additional omissions not listed")
					:format(diagnostic_limit, #omissions - diagnostic_limit))
				local sorted_causes = {}
				for cause in pairs(causes) do sorted_causes[#sorted_causes + 1] = cause end
				table.sort(sorted_causes)
				local cause_count = #sorted_causes
				for i = 1, math.min(cause_count, 12) do
					local cause = sorted_causes[i]
					core.log("warning", ("towns: wall gap cause summary count=%d %s"):format(causes[cause], cause))
				end
				if cause_count > 12 then
					core.log("warning", ("towns: %d additional wall gap cause groups not listed"):format(cause_count - 12))
				end
			end
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
		local wall_env = automatic_env(towns.site_search.core_env(core), automatic_context)
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
			elseif automatic_context then
				fail_writer("city-margin callback failed after urban build: " .. tostring(err), nil)
			else
				warning(summary, "city-margin callback failed: " .. tostring(err))
				update_write_bounds()
				finish_build("")
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
			api_env = automatic_env(api_env, automatic_context)
			api_env.is_protected = (automatic_context or type(core.is_protected) == "function") and function(pos)
				return protection_check(automatic_context, pos)
			end or nil
			if automatic_context then
				api_env.check_ownership = automatic_context.check_ownership
				api_env.authorize_write = function(box)
					return contains_box(automatic_context.write_bounds, box),
						"boundary volume exceeds the approved automatic-town write envelope"
				end
			end
			local ok, err = pcall(margin_api.attempt, result, after_margin, api_env, summary)
			if not ok then after_margin({status = "incomplete", reason = "city-margin attempt failed: " .. tostring(err)}) end
		end
	end
	end
	local built, message, code, extra = build_urban(result, automatic_context,
		automatic_context and continue_build or nil)
	if not automatic_context or built or message then continue_build(built, message, code, extra) end
end

towns.populated = {search = search, build = build, store = store}

local controller = towns.generate.new({
	lock = towns.generation_lock,
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
