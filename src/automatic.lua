-- First-touch automatic town coordinator.
return function(towns, core, vars)
	local mode = core.settings:get("towns_auto_mode") or "on"
	if mode ~= "survey" and mode ~= "on" then
		if mode ~= "off" then core.log("warning", "[towns] automatic mode " .. mode .. " is disabled") end
		return
	end
	local function disabled(reason)
		towns.auto_disabled = reason
		core.log("error", "[towns] automatic towns disabled: " .. tostring(reason))
	end
	local env, guard = towns.auto_environment, towns.auto_village_guard
	local mg = core.get_mapgen_setting("mg_name")
	local size = tonumber(core.get_mapgen_setting("chunksize") or "5")
	local seed = core.get_mapgen_setting("seed")
	if towns.auto_disabled or not env or not guard or not guard:check() or not towns.auto_records:is_enabled()
		or (mg ~= "v7" and mg ~= "flat") or size ~= 5 or not seed or seed == ""
		or type(vars) ~= "table" or type(vars.mg_overworld_min) ~= "number"
		or type(vars.mg_overworld_max) ~= "number" or type(vars.mg_end_max) ~= "number"
		or vars.mg_end_max >= vars.mg_overworld_min then
		return disabled(towns.auto_disabled or "unsupported mapgen, dimension or village integration")
	end
	local bounds = dofile(towns.modpath .. "/src/auto_bounds.lua")
	-- Candidates per cell (#431): 9 is the multi-candidate lattice, 1 the legacy single candidate.
	local CANDIDATES = 9
	-- Pre-screen (core.get_spawn_level at 9 points over the urban footprint): a candidate with fewer
	-- than PRESCREEN_MIN points returning a height is skipped as prescreen_wet. UNCERTAIN: the design
	-- doc said 5, but the T2 probe (docs/automatic_towns_spawn_level_probe.md) showed 5-of-9 also
	-- rejects dry low land, so 3 is a deliberately conservative starting point, to be tuned at T7.
	local PRESCREEN_MIN = 3
	-- Full inspections per cell (each costs 3-8 s of loading). UNCERTAIN: the PM start value; raise
	-- only if playtests show the town rate below target.
	local MAX_INSPECTIONS = 2
	local sites = assert(dofile(towns.modpath .. "/src/auto_sites.lua").new(env, {candidates = CANDIDATES}))
	local state_mod = dofile(towns.modpath .. "/src/auto_state.lua")
	local loader_mod = dofile(towns.modpath .. "/src/auto_loader.lua")
	local function lookup(rect) return sites.lookup(seed, rect) end
	local session = assert(state_mod.new({lookup = lookup, footprint = bounds.PLAN_EXTENT,
		adapter = {origin = bounds.CHUNK_ORIGIN, size = bounds.CHUNKSIZE, accepts = function(e)
			return e.maxp.y > vars.mg_end_max and e.minp.y <= vars.mg_overworld_max
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
	-- Log context for the chunk whose callback is being handled. self_triggered is true when the
	-- chunk lies inside a box the active job itself asked the engine to emerge (see requested_by).
	local function trigger_info(event, self_triggered)
		return {minp = event.minp, maxp = event.maxp, self_triggered = self_triggered}
	end
	-- True when the callback chunk lies inside a box the job requested and has not yet received.
	local function requested_by(job, minp, maxp)
		for request in pairs(job.requests) do
			local a, b = request.minp, request.maxp
			if minp.x >= a.x and maxp.x <= b.x and minp.y >= a.y and maxp.y <= b.y
				and minp.z >= a.z and maxp.z <= b.z then return true end
		end
		return false
	end
	-- Pre-screen one candidate: returns score (points that returned a height), min, max level; or nil
	-- when core.get_spawn_level is missing or errors (no pre-screen: every candidate passes). The
	-- function is injectable as towns.auto_spawn_level for tests.
	local prescreen_warned = false
	local function prescreen_unavailable(why)
		if prescreen_warned then return end
		prescreen_warned = true
		core.log("warning", "[towns] automatic pre-screen unavailable, all candidates pass: " .. tostring(why))
	end
	local function prescreen(site)
		local fn = towns.auto_spawn_level or core.get_spawn_level
		if type(fn) ~= "function" then return prescreen_unavailable("core.get_spawn_level is missing") end
		local e = bounds.PLAN_EXTENT
		local xs = {e.x1, math.floor((e.x1 + e.x2) / 2), e.x2}
		local zs = {e.z1, math.floor((e.z1 + e.z2) / 2), e.z2}
		local score, lo, hi = 0, nil, nil
		for _, dz in ipairs(zs) do
			for _, dx in ipairs(xs) do
				local ok, h = pcall(fn, site.center.x + dx, site.center.z + dz)
				if not ok then return prescreen_unavailable(h) end
				if type(h) == "number" and h == h then
					score = score + 1
					if lo == nil or h < lo then lo = h end
					if hi == nil or h > hi then hi = h end
				end
			end
		end
		return score, lo, hi
	end

	-- One cell job. It owns the generation lock for the whole cell: the lock is taken once, kept
	-- across every inspection (releasing between candidates would let /towns_generate or another
	-- job interleave and invalidate the cell's fresh chunk set), and released exactly once, in
	-- end_cell. Every exit path goes through end_cell, which also declines every candidate that is
	-- still live so the cell becomes terminal and its chunk set is dropped (the T4 sibling leak).
	local function run_cell(action, trigger, own)
		local list = action.sites or {action.site}
		-- requests is shared by every attempt: a chunk requested by an earlier attempt still counts as
		-- the cell's own until its callback returns, and the set is dropped when the cell ends.
		local cell = {started = now(), tries = 0, entries = {}, queue = {}, event = trigger, requests = {},
			trigger = trigger_info(trigger, own), done = false}
		cell.activation = {time = cell.started, candidates = #list}
		for i, site in ipairs(list) do
			local score, lo, hi = prescreen(site)
			local entry = {index = site.candidate or (i - 1), id = site.id, center = site.center,
				score = score, min_level = lo, max_level = hi, site = site}
			cell.entries[#cell.entries + 1] = entry
			if score ~= nil and score < PRESCREEN_MIN then
				entry.outcome, entry.reason = "declined", "prescreen_wet"
			else
				cell.queue[#cell.queue + 1] = entry
			end
		end
		-- Highest score first; ties (and the no pre-screen case) by the seeded candidate order.
		table.sort(cell.queue, function(p, q)
			local ps, qs = p.score or 0, q.score or 0
			if ps ~= qs then return ps > qs end
			return p.index < q.index
		end)

		local function end_cell(outcome, reason, message, winner, untried_reason)
			if cell.done then return end
			cell.done = true
			local logged = {}
			for _, entry in ipairs(cell.entries) do
				if entry.outcome == nil then
					entry.outcome, entry.reason = "declined", untried_reason or reason
				end
				-- Anything still live (pre-screened out, never tried, or the cell gave up) is declined.
				if not entry.settled then session:decline(entry.id) end
				local copy = {}
				for k, v in pairs(entry) do if k ~= "site" and k ~= "settled" then copy[k] = v end end
				logged[#logged + 1] = copy
			end
			active = nil
			for request in pairs(cell.requests) do cell.requests[request] = nil end
			if cell.token then towns.generation_lock.release(cell.token) end
			local d = cell.last or {}
			local first = list[1]
			core.log("action", "[towns] " .. (mode == "survey" and "survey " or "automatic ") .. core.write_json({
				id = winner and winner.id or cell.last_id or first.id, cell = first.cell,
				outcome = outcome, reason = reason, message = message,
				trigger = cell.trigger, activation = cell.activation, candidates = logged,
				winner = winner and winner.index or nil, tries = cell.tries,
				center_heights = d.center_heights, inspection_rejections = d.inspection_rejections,
				inspection_examples = d.inspection_examples,
				chunks = d.chunks or 0, elapsed_seconds = now() - cell.started, load_seconds = d.load_seconds or 0,
				inspection_seconds = d.inspection_seconds or 0, snapshot_voxels = d.snapshot_voxels or 0,
				clearance = d.clearance or false, suppressed_villages = d.suppressed_villages or 0,
				aqueduct = d.aqueduct, aqueduct_reason = d.aqueduct_reason,
				write_bounds = d.write_bounds, approved_write_bounds = d.approved_write_bounds}, false))
		end

		local attempt
		-- Begins the next ranked candidate. Ends the cell when none is left, the inspection budget is
		-- spent, the 60 s limit passed, or begin refuses for any other reason.
		local function advance(last_outcome, last_reason, last_message)
			while true do
				local entry = cell.queue[1]
				if entry == nil then
					return end_cell(last_outcome or "declined", last_reason or "no_candidates", last_message)
				end
				if cell.tries >= MAX_INSPECTIONS then
					return end_cell(last_outcome or "declined", last_reason or "inspections_exhausted",
						last_message, nil, "inspections_exhausted")
				end
				table.remove(cell.queue, 1)
				local began, why, code = session:begin(entry.id, now())
				if began then
					cell.tries = cell.tries + 1
					return attempt(entry)
				elseif code == "not_contacted" then
					-- Declined meanwhile (a village overlapped it): the cell continues with the next one.
					entry.outcome, entry.reason = "declined", "village_declined"
				else
					-- cell_expired (begin already declined the cell) or any other refusal: give up.
					entry.outcome, entry.reason = "declined", code or "begin_failed"
					return end_cell("declined", code or "begin_failed", why, nil, code or "begin_failed")
				end
			end
		end

		-- Called when an attempt settles. continue is true after any failure before acceptance.
		local function attempt_done(entry, outcome, code, message, d, won, continue)
			entry.outcome, entry.reason, entry.message, entry.settled = outcome, code, message, true
			for k, v in pairs(d) do entry[k] = v end
			cell.last, cell.last_id = d, entry.id
			if won then return end_cell(outcome, code, message, entry) end
			if continue then
				local ok, err = pcall(advance, outcome, code, message)
				if not ok then end_cell("declined", "cell_exception", tostring(err)) end
				return
			end
			end_cell(outcome, code, message, nil, code)
		end

		attempt = function(entry)
		local site, trigger = entry.site, cell.event
		-- start runs only when no job is active, so no pending request can own this trigger.
		local job = {site = site, started = now(), chunks = 0, suppressed = 0, clearance = false,
			load_seconds = 0, inspection_seconds = 0, snapshot_voxels = 0, requests = cell.requests,
			trigger = cell.trigger}
		local function settle(result, reason, code, summary, extra, inspection_details)
			if job.done then return end
			job.done = true
			local outcome = result and (mode == "survey" and "surveyed" or "complete") or "declined"
			if job.accepted then
				outcome = result and "complete" or "interrupted"
				local ok, saved, why = pcall(towns.auto_records.update, towns.auto_records, site.cell, outcome)
				if not ok or not saved then
					outcome = "interrupted"
					core.log("error", "[towns] automatic record update failed: " .. tostring(why or saved))
				end
				session:finish(site.id)
			elseif result then session:finish(site.id) else session:decline(site.id) end
			if active == job then active = nil end
			local d = {
				center_heights = inspection_details and inspection_details.center_heights,
				inspection_rejections = inspection_details and inspection_details.rejections,
				inspection_examples = inspection_details and inspection_details.examples,
				chunks = job.chunks, elapsed_seconds = now() - job.started, load_seconds = job.load_seconds,
				inspection_seconds = job.inspection_seconds, snapshot_voxels = job.snapshot_voxels,
				clearance = job.clearance, suppressed_villages = job.suppressed,
				aqueduct = summary and summary.aqueduct and summary.aqueduct.status or nil,
				aqueduct_reason = summary and summary.aqueduct and summary.aqueduct.status == "skipped"
					and summary.aqueduct.reason or nil,
				write_bounds = summary and summary.write_bounds or extra and extra.bounds,
				approved_write_bounds = job.write_bounds}
			-- Any loader or inspection failure before acceptance moves on to the next candidate (while
			-- inspections and the 60 s limit allow); guard, clearance,
			-- build and record failures end the cell. The lock stays with the cell (see run_cell).
			attempt_done(entry, outcome, code or reason or "ok", reason, d, result and true,
				job.retryable and not job.accepted)
		end
		job.token = cell.token
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
		for k, v in pairs(towns.site_search.AUTOMATIC_DEFAULTS or towns.site_search.WET_DEFAULTS) do opts[k] = v end
		local world = towns.site_search.core_env(core)
		local emerge = world.emerge
		world.emerge = function(minp, maxp, cb)
			job.chunks = job.chunks + 1
			local started = now()
			local request = {minp = minp, maxp = maxp}
			job.requests[request] = true
			emerge(minp, maxp, function(...)
				job.requests[request] = nil
				job.load_seconds = job.load_seconds + now() - started; cb(...)
			end)
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
		local function loaded(result, reason, code, inspection_details)
			if job.done then return end
			if not result then job.retryable = true end
			if not result or mode == "survey" then return settle(result, reason, code, nil, nil, inspection_details) end
			local function checked()
				if job.done or not towns.generation_lock.owns(job.token) or towns.auto_disabled
						or not guard:check() then return false, "ownership or village guard lost" end
				for _, stage in pairs(result.envelope.stages) do
					if stage.kind == "write" and not session:covers(site.id, stage.box) then
						return false, "fresh coverage lost"
					end
				end
				local w = result.write_envelope
				if not clear({x1 = w.min.x, z1 = w.min.z, x2 = w.max.x, z2 = w.max.z}) then
					return false, "player clearance lost"
				end
				return true
			end
			local ok, good, why = pcall(checked)
			if not ok or not good then return settle(nil, tostring(why or good), "pre_build_check") end
			if not towns.generation_lock.set_phase(job.token, "build") then return settle(nil, nil, "ownership_lost") end
			job.write_bounds = result.write_envelope
			local context = {read_bounds = result.read_envelope, write_bounds = result.write_envelope,
				log = function(level, msg) core.log(level, "[towns] " .. msg) end}
			context.callback_failed = function(err) settle(nil, tostring(err), "build_callback_failed") end
			context.check_ownership = function()
				if job.done or not towns.generation_lock.owns(job.token) then return false, "ownership lost" end
				return true
			end
			context.before_write = function()
				if job.accepted then return false, "write gate already used" end
				local passed, allowed, message = pcall(checked)
				if not passed or not allowed then return false, tostring(message or allowed) end
				local record, err = towns.auto_records_factory.record_for_site(site, result)
				if not record then return false, err end
				local saved, failure = towns.auto_records:begin(record)
				if not saved then return false, failure end
				job.accepted = true
				return true
			end
			context.ensure_loaded = function(minp, maxp, done)
				if job.done or not towns.generation_lock.owns(job.token) then return done(false) end
				local called = false
				local function finish(success)
					if called or job.done then return end
					called = true
					local success_call, failure = pcall(done, success == true and towns.generation_lock.owns(job.token))
					if not success_call then settle(nil, tostring(failure), "build_callback_failed") end
				end
				local requested, failure = pcall(world.emerge, minp, maxp, finish)
				if not requested then return finish(false) end
				if not called then
					local scheduled = pcall(core.after, 30, function() finish(false) end)
					if not scheduled then finish(false) end
				end
			end
			-- Capability for the cosmetic Roman aqueduct (#417). It runs inside the build, while the
			-- session is still inspecting, so session:covers is meaningful. Its writes are outside the
			-- approved write envelope accounting by design; max_rect (checked by covers) is what the
			-- accepted record reserves against villages. Any failure just skips the aqueduct.
			local read = result.read_envelope
			local function strip_authorized(box)
				if job.done or not towns.generation_lock.owns(job.token) then return false end
				if type(box) ~= "table" or type(box.min) ~= "table" or type(box.max) ~= "table" then return false end
				if not session:covers(site.id, box) then return false end
				return clear({x1 = box.min.x, z1 = box.min.z, x2 = box.max.x, z2 = box.max.z})
			end
			context.aqueduct = {
				authorize_strip = function(box)
					local ok, allowed = pcall(strip_authorized, box)
					return ok and allowed == true
				end,
				-- Horizontal reservation check shared by emerge and the region the aqueduct opens.
				in_reservation = function(minp, maxp)
					local m = site.max_rect
					return type(minp) == "table" and type(maxp) == "table"
						and minp.x >= m.x1 and maxp.x <= m.x2 and minp.z >= m.z1 and maxp.z <= m.z2
				end,
				-- Same ensure_loaded as the town build. Unlike the town's stage emerge (automatic_env) it is
				-- not clipped to read_bounds; it is limited to max_rect instead. Newly generated chunks there
				-- are recorded fresh by on_generated and villages are suppressed while the site inspects.
				emerge = function(minp, maxp, cb)
					if not context.aqueduct.in_reservation(minp, maxp) then return cb(false) end
					return context.ensure_loaded(minp, maxp, cb)
				end,
				y_min = read and read.min and read.min.y,
				y_max = read and read.max and read.max.y,
			}
			local function built(summary, message, build_code, extra)
				if job.done then return end
				local town = summary and summary.town
				local residents = town and town.residents
				local population_ok = town and town.complete == true and not town.beds_error and not town.residents_error and residents
					and #(residents.failures or {}) == 0 and #(residents.interrupted_beds or {}) == 0
				if not job.accepted or not towns.generation_lock.owns(job.token) or not summary or not population_ok then
					return settle(nil, message, build_code or (summary and "population_failed" or "build_failed"), summary, extra)
				end
				settle(true, nil, nil, summary, extra)
			end
			local built_ok, failure = pcall(towns.populated.build, result, built, context)
			if not built_ok then settle(nil, tostring(failure), "build_exception") end
		end
		local function handoff(...)
			if job.handed_off or job.done then return end
			job.handed_off = true
			local ok, err = pcall(loaded, ...)
			if not ok then settle(nil, tostring(err), "handoff_exception") end
		end
		local ok, err = pcall(loader.start, loader, site, trigger, handoff)
		if not ok or not err then settle(nil, tostring(err), "loader_start") end
		end
		local ok, err = pcall(core.after, 0, function()
			local success, why = pcall(run)
			if not success then settle(nil, tostring(why), "initialization_failed") end
		end)
		if not ok then settle(nil, tostring(err), "schedule_failed") end
	end
		if #cell.queue == 0 then return end_cell("declined", "prescreen_wet") end
		-- Lock first, then the first begin; a busy lock (e.g. /towns_generate) declines the whole cell.
		cell.token = towns.generation_lock.acquire(cell.queue[1].id, "loading", now())
		if not cell.token then return end_cell("declined", "busy") end
		advance()
	end
	core.register_on_generated(function(minp, maxp)
		if towns.auto_disabled then return end
		if maxp.y <= vars.mg_end_max or minp.y > vars.mg_overworld_max then return end
		local rect = {x1 = minp.x, z1 = minp.z, x2 = maxp.x, z2 = maxp.z}
		local candidates, why = lookup(rect)
		if not candidates then return disabled(why) end
		local relevant = false
		for _, site in ipairs(candidates) do
			local a = site.activation_rect
			local state = session:state(site.id)
			if state ~= "declined" and state ~= "complete" and state ~= "accepted"
				and a and rect.x1 <= a.x2 and a.x1 <= rect.x2 and rect.z1 <= a.z2 and a.z1 <= rect.z2 then
				relevant = true
				break
			end
		end
		if not relevant then return end
		local own = active ~= nil and requested_by(active, minp, maxp)
		local heights, hm = {}, core.get_mapgen_object("heightmap")
		if hm then
			local i = 1
			for z = minp.z, maxp.z do
				local row = {}; heights[z] = row
				for x = minp.x, maxp.x do
					local h = hm[i]; i = i + 1
					if state_mod.classify(h, minp.y, maxp.y) == "valid"
						and h >= vars.mg_overworld_min and h <= vars.mg_overworld_max then row[x] = h end
				end
			end
		end
		local event = {minp = {x = minp.x, y = minp.y, z = minp.z},
			maxp = {x = maxp.x, y = maxp.y, z = maxp.z}, heights = heights,
			self_triggered = own or nil}
		local actions, why = session:on_generated(event, now())
		if not actions then return disabled(why) end
		for _, action in ipairs(actions) do
			local site = action.site
			if active then
				for _, sibling in ipairs(action.sites or {site}) do session:decline(sibling.id) end
				core.log("action", "[towns] " .. (mode == "survey" and "survey " or "automatic ") .. core.write_json({id = site.id, outcome = "declined",
					reason = "busy", trigger = trigger_info(event, own), chunks = 0, elapsed_seconds = 0, load_seconds = 0,
					inspection_seconds = 0, snapshot_voxels = 0, clearance = false, suppressed_villages = 0}, false))
			else
				-- Reserve and take ownership now; world requests are deferred until after mapgen returns.
				run_cell(action, event, own)
			end
		end
	end)
	towns.auto_session = session
end
