-- Coordinator with the real freshness session and bounded loader; fake engine I/O.
local eq = ...
local real_dofile = dofile
local a = {id = "A", center = {x = 0, z = 0}, cell = {x = 0, z = 0}, seed = 9, town_type = "roman",
	max_rect = {x1 = -32, z1 = -32, x2 = 127, z2 = 47},
	activation_rect = {x1 = -32, z1 = -32, x2 = 127, z2 = 47}}
local b = {id = "B", center = {x = 80, z = 0}, cell = {x = 1, z = 0}, seed = 10, town_type = "roman",
	max_rect = {x1 = 48, z1 = -32, x2 = 127, z2 = 47},
	activation_rect = {x1 = 48, z1 = -32, x2 = 127, z2 = 47}}
local box = {min = {x = 48, y = 48, z = -32}, max = {x = 127, y = 127, z = 47}}

local function fixture(mode)
	local f = {timers = {}, requests = {}, reports = {}, reads = 0, writes = 0, begins = 0}
	local current, height, locked
	local core = {settings = {get = function() return "survey" end},
		get_mapgen_setting = function(k) return ({mg_name = "flat", chunksize = "5", seed = "42"})[k] end,
		get_connected_players = function() return {} end, get_us_time = function() return 1000000 end,
		log = function() end, write_json = function(t) f.reports[#f.reports + 1] = t; return "result" end,
		register_on_generated = function(fn) f.generated = fn end,
		get_mapgen_object = function() f.reads = f.reads + 1; return height end,
		after = function(delay, fn)
			if mode == "scheduling" and delay == 0 then error("schedule failed") end
			f.timers[#f.timers + 1] = {delay = delay, fn = fn}
		end,
		set_node = function() f.writes = f.writes + 1 end}
	local function emit(minp, maxp, h)
		height = {}; for i = 1, 6400 do height[i] = h end
		f.generated(minp, maxp)
	end
	f.emit = emit
	local guard = {check = function() return true end, bind = function() return true end}
	local lock = {acquire = function() if locked then return nil end; locked = {}; return locked end,
		release = function(t) if t == locked then locked = nil end end}
	f.locked = function() return locked ~= nil end
	local env = {plan_envelope = function()
		if mode == "envelope" then return nil, "bad envelope", "envelope_failed" end
		return {read = box, write = box, chunks = mode == "cap" and 257 or 1,
		snapshot_voxels = 512000, stages = {urban = {kind = "write", box = box}}} end}
	local search = {WET_DEFAULTS = {}, AUTOMATIC_DEFAULTS = {max_range = 20, max_water_depth = 10,
		max_wet_fraction = 0.25}, core_env = function()
		if mode == "initialization" then error("environment failed") end
		return {
		after = core.after, emerge = function(minp, maxp, cb)
			f.requests[#f.requests + 1] = {minp = minp, maxp = maxp, cb = cb}
		end} end,
		inspect_site = function(center, ref, seed, opts, done, io)
			f.reference = ref
			f.inspection_opts = opts
			if mode == "inspection" then return done(nil, "inspection failed",
				{rejections = {too_deep_water = 1}, examples = {too_deep_water = "water at (12,20) deeper than 10 nodes"}}) end
			io.emerge(box.min, box.max, function(ok)
				if not ok then return done(nil, "failed") end
				done({plan = {}, ground_y = 64, build_bounds = box})
			end)
		end}
	local towns = {modpath = ".", auto_environment = env, auto_village_guard = guard,
		auto_records = {is_enabled = function() return true end, lookup = function() end,
			begin = function() f.begins = f.begins + 1 end}, generation_lock = lock,
		catalog = {entries = {}}, site_search = search}
	local bounds = {PLAN_EXTENT = {x1 = 0, z1 = 0, x2 = 0, z2 = 0}, CHUNK_ORIGIN = -32, CHUNKSIZE = 80,
		CAPS = {MAX_REQUEST_CHUNKS = 256, MAX_SNAPSHOT_VOXELS = 256 * 512000}}
	local env_lua = setmetatable({dofile = function(path)
		if path == "./src/auto_bounds.lua" then return bounds end
		if path == "./src/auto_sites.lua" then return {new = function() return {lookup = function() return {a, b} end} end} end
		return real_dofile(path)
	end}, {__index = _G})
	local chunk = assert(loadfile("src/automatic.lua")); setfenv(chunk, env_lua)
	chunk()(towns, core, {mg_overworld_min = 0, mg_overworld_max = 1000, mg_end_max = -2000})
	f.session = towns.auto_session
	f.start = function() local timer = table.remove(f.timers, 1); assert(timer.delay == 0); timer.fn() end
	f.complete = function(ok, record)
		local req = table.remove(f.requests, 1)
		if ok and record ~= false then emit(req.minp, req.maxp, 64) end
		f.last_complete = req.cb
		req.cb(ok)
	end
	f.timeout = function() for _, timer in ipairs(f.timers) do if timer.delay == 30 then timer.fn(); return end end end
	return f
end

local min = {x = -32, y = 48, z = -32}
local max = {x = 47, y = 127, z = 47}
-- Exercise the coordinator around real loader failures, checking site A.
for _, mode in ipairs({"missing_center", "inspection", "envelope", "cap", "freshness", "scheduling", "initialization"}) do
	local f = fixture(mode)
	if mode == "missing_center" then
		-- Activate A from its outer chunk, leaving its centre unavailable.
		f.emit({x = 48, y = 48, z = -32}, {x = 127, y = 127, z = 47}, 64)
	else
		f.emit(min, max, 64)
	end
	if mode ~= "scheduling" then f.start() end
	if mode == "inspection" then
		eq(f.inspection_opts.max_range, 20, "automatic site inspection uses relaxed slope range")
		eq(f.inspection_opts.max_water_depth, 10, "automatic site inspection uses relaxed water depth")
		eq(f.inspection_opts.max_wet_fraction, 0.25, "automatic site inspection keeps wet fraction")
	end
	if mode == "missing_center" or mode == "freshness" then
		f.complete(true, false)
	elseif mode == "envelope" or mode == "cap" then
		f.complete(true)
	end
	local matching, report = 0
	for _, r in ipairs(f.reports) do if r.id == "A" then matching = matching + 1; report = r end end
	eq(matching, 1, mode .. " reports site exactly once")
	eq(report and report.outcome, "declined", mode .. " reports decline")
	eq(report and report.trigger and report.trigger.self_triggered, false, mode .. " reports trigger context")
	local reasons = {missing_center = "center_ground_missing", inspection = "too_deep_water",
		envelope = "envelope_failed", cap = "envelope_cap", freshness = "not_fresh",
		scheduling = "schedule_failed", initialization = "initialization_failed"}
	eq(report and report.reason, reasons[mode], mode .. " reports its actual failure")
	if mode == "inspection" then
		eq(report and report.message, "inspection failed", "automatic report preserves the detailed inspection message")
		eq(report and report.inspection_rejections and report.inspection_rejections.too_deep_water, 1,
			"automatic report includes the exact terrain rejection code")
		eq(report and report.inspection_examples and report.inspection_examples.too_deep_water,
			"water at (12,20) deeper than 10 nodes", "automatic report includes the inspector example")
	end
	eq(f.session:state("A"), "declined", mode .. " releases reservation")
	eq(f.locked(), false, mode .. " releases lock")
	eq(f.writes + f.begins, 0, mode .. " performs no town writes or record begin")
	if f.last_complete then f.last_complete(true) end
	for _, timer in ipairs(f.timers) do if timer.delay == 30 then timer.fn() end end
	local after = 0
	for _, r in ipairs(f.reports) do if r.id == "A" then after = after + 1 end end
	eq(after, 1, mode .. " ignores late completions and watchdogs")
end

local function activated(f)
	f.emit({x = -32, y = 128, z = -32}, {x = 47, y = 207, z = 47}, 31000)
	eq(f.session:state("A"), "contacted", "sky first contacts real state")
	f.emit({x = -32, y = -112, z = -32}, {x = 47, y = -33, z = 47}, -64)
	eq(f.session:state("A"), "contacted", "underground height cannot activate a survey")
	eq(f.session:covers("A", {min = {x = 0, y = -80, z = 0}, max = {x = 0, y = -80, z = 0}}), true,
		"underground chunk below overworld floor remains fresh")
	f.emit(min, max, 64)
	eq(f.session:state("A"), "inspecting", "surface activates real state")
	eq(f.session:center("A").values[1], 64, "center height copied in callback")
	f.start()
	eq(f.reference, 64, "real loader uses copied center")
end

do
	local f = fixture()
	f.emit({x = 288, y = 48, z = 288}, {x = 367, y = 127, z = 367}, 64)
	eq(f.reads, 0, "irrelevant chunk does not fetch heightmap")
	activated(f)
	f.complete(true)
	eq(f.session:state("B"), "contacted", "the job's own request records B but does not activate or decline it")
	eq(f.session:state("A"), "complete", "real loader completes after nested freshness")
	eq(f.reports[#f.reports].outcome, "surveyed", "successful inspection reported")
	eq(f.locked(), false, "success releases lock")
	eq(f.writes, 0, "survey writes no nodes")
	eq(f.begins, 0, "survey begins no accepted record")
end
for _, mode in ipairs({"failed", "timeout"}) do
	local f = fixture(); activated(f)
	if mode == "failed" then f.complete(false) else f.timeout() end
	eq(f.session:state("A"), "declined", mode .. " releases session")
	eq(f.locked(), false, mode .. " releases lock")
	eq(f.reports[#f.reports].outcome, "declined", mode .. " reports decline")
	eq(f.writes + f.begins, 0, mode .. " performs no town writes or record begin")
	if mode == "timeout" then
		local count = #f.reports
		f.complete(true)
		eq(#f.reports, count, "late completion cannot settle twice")
		eq(f.session:state("A"), "declined", "late generated callback cannot reactivate terminal site")
	end
end

-- Roads coordination (#458): a Roads-like consumer next to deferred Towns generation. Real
-- session, real registry, real generation lock and the real towns_api; fake engine, loader and
-- clock. The engine fires on_generated before the emerge callback of the chunk it generated, which
-- is the order docs/roads_integration.md (G3) relies on.
do
	local records_mod = real_dofile("src/auto_records.lua")
	local api_mod = real_dofile("src/towns_api.lua")
	local function literal(v)
		if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
		if type(v) == "string" then return string.format("%q", v) end
		local fields = {}
		for k, x in pairs(v) do fields[#fields + 1] = "[" .. literal(k) .. "]=" .. literal(x) end
		table.sort(fields)
		return "{" .. table.concat(fields, ",") .. "}"
	end
	local sites = {
		{id = "2:0:0:0:roman:9:10:10", candidate = 0, cell = {x = 0, z = 0}, version = 2, seed = 9, town_type = "roman",
			center = {x = 10, z = 10}, max_rect = {x1 = -32, z1 = -32, x2 = 47, z2 = 47},
			activation_rect = {x1 = -32, z1 = -32, x2 = 47, z2 = 47}},
		{id = "2:1:0:0:roman:9:90:10", candidate = 0, cell = {x = 1, z = 0}, version = 2, seed = 9, town_type = "roman",
			center = {x = 90, z = 10}, max_rect = {x1 = 48, z1 = -32, x2 = 127, z2 = 47},
			activation_rect = {x1 = 48, z1 = -32, x2 = 127, z2 = 47}},
	}
	-- loader_mode: "manual" (the test completes the job) or "hung" (the loader's own 30 s timer fails it).
	local function fixture(loader_mode)
		local f = {timers = {}, clock = 0, jobs = {}, reports = {}, writes = 0, store = {}}
		local core = {
			settings = {get = function() return "on" end},
			get_mapgen_setting = function(k) return ({mg_name = "flat", chunksize = "5", seed = "42"})[k] end,
			get_connected_players = function() return {} end,
			get_us_time = function() return f.clock * 1000000 end,
			log = function() end,
			write_json = function(t) f.reports[#f.reports + 1] = t; return "json" end,
			register_on_generated = function(fn) f.generated = fn end,
			get_mapgen_object = function() local h = {}; for i = 1, 6400 do h[i] = 10 end; return h end,
			after = function(delay, fn) f.timers[#f.timers + 1] = {at = f.clock + delay, fn = fn, n = #f.timers} end,
		}
		local registry = records_mod.new({store = {get = function(k) return f.store[k] end,
			set = function(k, v) f.store[k] = v end}, serialize = literal,
			deserialize = function(s) return assert(loadstring("return " .. s))() end})
		local towns = {modpath = ".", auto_environment = {},
			auto_village_guard = {check = function() return true end, bind = function() return true end},
			auto_records = registry, auto_records_factory = records_mod, catalog = {entries = {}},
			site_search = {WET_DEFAULTS = {}, core_env = function() return {emerge = function(_, _, cb)
				f.engine_requests = (f.engine_requests or 0) + 1 end} end},
			populated = {build = function(result, cb, context) f.build = {result = result, cb = cb, context = context} end},
			generation_lock = real_dofile("src/generation_lock.lua")()}
		local modules = {
			["src/auto_bounds.lua"] = {PLAN_EXTENT = {x1 = -1, z1 = -1, x2 = 1, z2 = 1}, CHUNK_ORIGIN = -32,
				CHUNKSIZE = 80, CAPS = {}},
			["src/auto_sites.lua"] = {new = function() return {lookup = function() return sites end} end},
			["src/auto_loader.lua"] = {new = function() return {start = function(_, site, _, done)
				f.jobs[#f.jobs + 1] = {site = site, done = done}
				if loader_mode == "hung" then
					core.after(30, function() done(nil, "emerge timed out", "emerge_timeout") end)
				end
				return true
			end} end},
		}
		local env = setmetatable({dofile = function(path) return modules[path:gsub("^%./", "")] or real_dofile(path) end},
			{__index = _G})
		local chunk = assert(loadfile("src/automatic.lua")); setfenv(chunk, env)
		chunk()(towns, core, {mg_overworld_min = -100, mg_overworld_max = 100, mg_end_max = -2000})
		f.towns, f.session = towns, towns.auto_session
		f.api = api_mod.new({registry = function() return towns.auto_records end,
			session = function() return towns.auto_session end, lock = towns.generation_lock})
		-- Runs the earliest due timer (advancing the clock). False when none is pending.
		f.step = function()
			if #f.timers == 0 then return false end
			local best = 1
			for i, t in ipairs(f.timers) do
				local b = f.timers[best]
				if t.at < b.at or (t.at == b.at and t.n < b.n) then best = i end
			end
			local timer = table.remove(f.timers, best)
			if timer.at > f.clock then f.clock = timer.at end
			timer.fn()
			return true
		end
		-- The engine generates a chunk of the grid: on_generated first, then the emerge callback.
		f.emerge_chunk = function(cx, callback)
			local minp = {x = -32 + 80 * cx, y = -32, z = -32}
			local maxp = {x = minp.x + 79, y = 47, z = 47}
			f.generated(minp, maxp)
			if callback then callback() end
		end
		-- A Roads-like consumer. It emerges, then polls writer() until idle or its time limit, and
		-- re-checks writer() and exclusions in the callback that would write its slice.
		f.consumer = function(cx, slice, limit)
			local c = {writes = 0, polls = 0, state = "emerging"}
			f.emerge_chunk(cx, function()
				c.busy_at_callback = f.api.writer()
				c.exclusions_at_callback = f.api.exclusions(slice)
				local deadline = f.clock + limit
				local function poll()
					c.polls = c.polls + 1
					if f.api.writer() == nil then
						local items = f.api.exclusions(slice)
						if items and #items == 0 then
							c.writes = c.writes + 1; c.state = "wrote"
						else
							c.state = items and "excluded" or "unavailable"
							c.final_items = items
						end
					elseif f.clock >= deadline then
						c.state = "towns_busy"
					else
						core.after(1, poll)
					end
				end
				poll()
			end)
			return c
		end
		f.run_job = function(summary_published)
			f.step()   -- the deferred start (core.after 0)
			f.jobs[1].done({envelope = {stages = {}}, center = {x = 10, z = 10}, ground_y = 10,
				write_envelope = {min = {x = -20, y = 0, z = -20}, max = {x = 40, y = 40, z = 40}},
				read_envelope = {min = {x = -20, y = 0, z = -20}, max = {x = 40, y = 40, z = 40}}})
			assert(f.build.context.before_write(), "write gate")
			f.build.cb({published = summary_published, town = {complete = true,
				residents = {failures = {}, interrupted_beds = {}}}})
		end
		return f
	end
	local function published()
		local profile = {}
		for n = 1, 4 do profile[n] = {y = 10, name = "mcl_core:cobble", param2 = 0} end
		return {format = 1, core = {x1 = -10, z1 = -10, x2 = 30, z2 = 30}, structures = {},
			exits = {{id = "+x:31:10", source = "street", direction = {x = 1, z = 0},
				columns = {{x = 31, z = 10}, {x = 31, z = 11}}, length = 4, profile = profile}},
			omitted = {}}
	end
	local owner = sites[1].id

	-- Idle: nothing to wait for.
	do
		local f = fixture("manual")
		eq(f.api.writer(), nil, "idle before any chunk")
	end

	-- The consumer's emerge generates a chunk that triggers a cell: by the time its callback runs,
	-- writer() and exclusions() already show the job (G3).
	do
		local f = fixture("manual")
		local slice = {x1 = 48, z1 = 60, x2 = 60, z2 = 70}   -- beside the town, outside cell 0
		local c = f.consumer(0, slice, 100)
		eq(c.busy_at_callback ~= nil and c.busy_at_callback.kind, "automatic", "writer busy before the consumer callback")
		eq(c.busy_at_callback.phase, "loading", "phase reported while loading")
		local at_cb = c.exclusions_at_callback
		eq(#at_cb, 0, "slice outside the candidate reservation has no exclusion yet")
		local near = f.api.exclusions({x1 = 0, z1 = 0, x2 = 20, z2 = 20})
		eq(near[1] and near[1].kind, "candidate", "candidate visible as an exclusion while the job runs")
		eq(c.writes, 0, "consumer makes no writes while Towns is busy")
		eq(c.state, "emerging", "consumer is still waiting")
		-- Towns finishes: the consumer's next poll sees idle and the new settlement.
		f.run_job(published())
		eq(f.api.writer(), nil, "idle after the town completes")
		eq(f.session:state(owner), "complete", "town completed")
		local s = f.api.settlement("auto:0:0")
		eq(s and s.exits[1].id, "+x:31:10", "completed settlement and its exit are published")
		f.step()
		eq(c.state, "wrote", "consumer writes a slice that avoids the exclusions")
		eq(c.writes, 1, "one write after idle")
		-- A slice over the town core is refused even when idle.
		local f2 = fixture("manual")
		local blocked = f2.consumer(0, {x1 = 0, z1 = 0, x2 = 5, z2 = 5}, 100)
		f2.run_job(published())
		f2.step()
		eq(blocked.state, "excluded", "idle consumer sees the new core exclusion and does not write")
		eq(blocked.writes, 0, "no writes into the settlement core")
		eq(blocked.final_items[1].kind, "settlement", "the exclusion is the settlement")
	end

	-- A hung job: the consumer gives up with towns_busy and writes nothing, while Towns' own
	-- timer still ends the job and releases the lock without any help from the consumer.
	do
		local f = fixture("hung")
		local c = f.consumer(0, {x1 = 48, z1 = 60, x2 = 60, z2 = 70}, 10)
		local steps = 0
		while c.state == "emerging" and steps < 50 do f.step(); steps = steps + 1 end
		eq(c.state, "towns_busy", "consumer times out while Towns is busy")
		eq(c.writes, 0, "timed-out consumer wrote nothing")
		eq(f.api.writer() ~= nil, true, "the hung job still holds the lock when the consumer gives up")
		steps = 0
		while f.api.writer() ~= nil and steps < 50 do
			if not f.step() then break end
			steps = steps + 1
		end
		eq(f.api.writer(), nil, "Towns' own timer ends the hung job (no deadlock)")
		eq(f.towns.generation_lock.current(), nil, "lock released")
		eq(f.session:state(owner), "declined", "failed job is declined")
		eq(f.api.settlement("auto:0:0"), nil, "nothing was published")
		eq(#f.api.exclusions({x1 = 0, z1 = 0, x2 = 20, z2 = 20}), 0, "no exclusions remain after the failure")
	end

	-- A consumer emerge that triggers a second cell during an active job gets a busy decline: no
	-- second job, no second lock, and the first job is unaffected.
	do
		local f = fixture("manual")
		f.emerge_chunk(0)
		eq(f.api.writer() ~= nil, true, "first job holds the lock")
		local before = #f.reports
		f.emerge_chunk(1)   -- the consumer's emerge generates cell 1's chunk
		eq(f.api.writer() ~= nil, true, "still the first job's lock")
		eq(f.towns.generation_lock.current().owner, owner, "ownership is unchanged")
		eq(#f.reports, before + 1, "the second cell is reported")
		eq(f.reports[#f.reports].reason, "busy", "second cell declined as busy")
		eq(f.session:state(sites[2].id), "declined", "busy cell is declined, not queued")
		eq(#f.jobs, 0, "no second job started")
		f.run_job(published())
		eq(f.session:state(owner), "complete", "the first job still completes")
		eq(f.api.writer(), nil, "idle at the end")
	end

	-- The whole cycle finishes in a bounded number of timer steps.
	do
		local f = fixture("manual")
		local c = f.consumer(0, {x1 = 48, z1 = 60, x2 = 60, z2 = 70}, 100)
		f.run_job(published())
		local steps = 0
		while c.state == "emerging" and steps < 20 do f.step(); steps = steps + 1 end
		eq(c.state, "wrote", "consumer finishes")
		eq(steps <= 5, true, "within a handful of timer steps")
	end
end
