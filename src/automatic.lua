-- Survey-only automatic town coordinator. No builder or persistent begin is called.
return function(towns, core, vars)
	local mode = core.settings:get("towns_auto_mode") or "off"
	if mode ~= "survey" then
		if mode ~= "off" then core.log("warning", "[towns] automatic mode " .. mode .. " is disabled") end
		return
	end
	local function disabled(reason)
		towns.auto_disabled = reason
		core.log("error", "[towns] automatic survey disabled: " .. tostring(reason))
	end
	local env, guard = towns.auto_environment, towns.auto_village_guard
	local mg = core.get_mapgen_setting("mg_name")
	local size = tonumber(core.get_mapgen_setting("chunksize") or "5")
	local seed = core.get_mapgen_setting("seed")
	if towns.auto_disabled or not env or not guard or not guard:check() or not towns.auto_records:is_enabled()
		or (mg ~= "v7" and mg ~= "flat") or size ~= 5 or not seed or seed == ""
		or type(vars) ~= "table" or type(vars.mg_overworld_min) ~= "number"
		or type(vars.mg_overworld_max) ~= "number" then
		return disabled(towns.auto_disabled or "unsupported mapgen, dimension or village integration")
	end
	local bounds = dofile(towns.modpath .. "/src/auto_bounds.lua")
	local sites = assert(dofile(towns.modpath .. "/src/auto_sites.lua").new(env))
	local state_mod = dofile(towns.modpath .. "/src/auto_state.lua")
	local loader_mod = dofile(towns.modpath .. "/src/auto_loader.lua")
	local function lookup(rect) return sites.lookup(seed, rect) end
	local session = assert(state_mod.new({lookup = lookup, footprint = bounds.PLAN_EXTENT,
		adapter = {origin = bounds.CHUNK_ORIGIN, size = bounds.CHUNKSIZE, accepts = function(e)
			return e.maxp.y >= vars.mg_overworld_min and e.minp.y <= vars.mg_overworld_max
		end},
		accepted = function(d) return towns.auto_records:lookup(d.cell) ~= nil end}))
	local active
	if not guard:bind(session, lookup, function() return not towns.auto_disabled end, function(reason)
		if active and reason == "inspecting" then active.suppressed = active.suppressed + 1 end
	end) then return disabled("village guard binding failed") end
	local function clear(rect)
		for _, player in ipairs(core.get_connected_players()) do
			local p = player:get_pos()
			if p and p.x >= rect.x1 - 16 and p.x <= rect.x2 + 16
				and p.z >= rect.z1 - 16 and p.z <= rect.z2 + 16 then return false end
		end
		return true
	end
	local function now() return core.get_us_time() / 1000000 end
	local function start(site, trigger)
		local job = {site = site, started = now(), chunks = 0, suppressed = 0, clearance = false,
			load_seconds = 0, inspection_seconds = 0, snapshot_voxels = 0}
		local function settle(result, reason, code)
			if job.done then return end
			job.done = true
			if result then session:finish(site.id) else session:decline(site.id) end
			if active == job then active = nil end
			if job.token then towns.generation_lock.release(job.token) end
			core.log("action", "[towns] survey " .. core.write_json({id = site.id,
				outcome = result and "surveyed" or "declined", reason = code or reason or "ok",
				chunks = job.chunks, elapsed_seconds = now() - job.started, load_seconds = job.load_seconds,
				inspection_seconds = job.inspection_seconds, snapshot_voxels = job.snapshot_voxels,
				clearance = job.clearance, suppressed_villages = job.suppressed}, false))
		end
		job.token = towns.generation_lock.acquire(site.id, "loading", now())
		if not job.token then return settle(nil, nil, "busy") end
		active = job
		local guard_ok, healthy = pcall(guard.check, guard)
		if not guard_ok or not healthy then return settle(nil, nil, "village_guard") end
		local clear_ok, clearance = pcall(clear, site.max_rect)
		if not clear_ok then return settle(nil, tostring(clearance), "clearance_error") end
		job.clearance = clearance
		if not job.clearance then return settle(nil, nil, "player_clearance") end
		local function run()
		local opts = {planner_opts = {town_type = site.town_type}, entries = towns.catalog.entries}
		if site.town_type == "medieval" then
			opts.planner_opts.landmarks = assert(towns.planner.landmark_profile(towns.catalog.snapshot()))
			opts.planner_opts.wall_feature_entries = towns.catalog.entries
		end
		for k, v in pairs(towns.site_search.WET_DEFAULTS) do opts[k] = v end
		local world = towns.site_search.core_env(core)
		local emerge = world.emerge
		world.emerge = function(minp, maxp, cb)
			job.chunks = job.chunks + 1
			local started = now()
			emerge(minp, maxp, function(...) job.load_seconds = job.load_seconds + now() - started; cb(...) end)
		end
		local search = {inspect_site = function(...)
			local args = {...}
			local done, started = args[5], now()
			args[5] = function(...) job.inspection_seconds = now() - started; done(...) end
			return towns.site_search.inspect_site(unpack(args))
		end}
		local loader = assert(loader_mod.new({session = session, site_search = search,
			env = world, origin = bounds.CHUNK_ORIGIN, size = bounds.CHUNKSIZE,
			seed = site.seed, inspect_opts = opts, caps = bounds.CAPS,
			envelope = function(result, descriptor, ref_y)
				local st = {plan = result.plan, center = descriptor.center, ground_y = result.ground_y,
					reference_y = ref_y, build_bounds = result.build_bounds}
				if descriptor.town_type == "medieval" then
					st.wall = towns.medieval_walls.plan(result.plan, result.force_walls)
					if st.wall then st.wall_features = towns.medieval_wall_features.candidates(st.wall,
						result.ground_y, towns.catalog.entries, towns.medieval_walls) end
				end
				local envelope, why, code = env.plan_envelope(st)
				if envelope then job.snapshot_voxels = envelope.snapshot_voxels end
				return envelope, why, code
			end}))
		local ok, err = pcall(loader.start, loader, site, trigger, settle)
		if not ok or not err then settle(nil, tostring(err), "loader_start") end
		end
		local ok, err = pcall(core.after, 0, function()
			local success, why = pcall(run)
			if not success then settle(nil, tostring(why), "initialization_failed") end
		end)
		if not ok then settle(nil, tostring(err), "schedule_failed") end
	end
	core.register_on_generated(function(minp, maxp)
		if towns.auto_disabled then return end
		local heights, hm = {}, core.get_mapgen_object("heightmap")
		if hm then
			local i = 1
			for z = minp.z, maxp.z do
				local row = {}; heights[z] = row
				for x = minp.x, maxp.x do
					local h = hm[i]; i = i + 1
					if state_mod.classify(h, minp.y, maxp.y) == "valid" then row[x] = h end
				end
			end
		end
		local event = {minp = {x = minp.x, y = minp.y, z = minp.z},
			maxp = {x = maxp.x, y = maxp.y, z = maxp.z}, heights = heights}
		local actions, why = session:on_generated(event)
		if not actions then return disabled(why) end
		for _, action in ipairs(actions) do
			local site = action.site
			if active then
				session:decline(site.id)
				core.log("action", "[towns] survey " .. core.write_json({id = site.id, outcome = "declined",
					reason = "busy", chunks = 0, elapsed_seconds = 0, load_seconds = 0,
					inspection_seconds = 0, snapshot_voxels = 0, clearance = false, suppressed_villages = 0}, false))
			else
				-- Reserve and take ownership now; defer world requests until after mapgen returns.
				start(site, event)
			end
		end
	end)
	towns.auto_session = session
end
