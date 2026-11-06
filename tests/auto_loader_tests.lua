-- Center-first automatic town loading (#397).
local eq, placement, planner = ...
local loader_mod = dofile("src/auto_loader.lua")

local ORIGIN, SIZE = -32, 80
local site = {id = "site", center = {x = 20, z = 20}}
local trigger = {minp = {x = 48, y = 48, z = 48}, maxp = {x = 127, y = 127, z = 127}}

local function chunk_key(minp)
	return math.floor((minp.x - ORIGIN) / SIZE) .. ":" .. math.floor((minp.y - ORIGIN) / SIZE)
		.. ":" .. math.floor((minp.z - ORIGIN) / SIZE)
end

local function session_fixture()
	local s = {fresh = {}, ground = nil, states = {site = "inspecting"}}
	function s:center() return self.ground end
	function s:state(id) return self.states[id] end
	function s:covers(_, b)
		local x1, y1, z1 = math.floor((b.min.x - ORIGIN) / SIZE), math.floor((b.min.y - ORIGIN) / SIZE),
			math.floor((b.min.z - ORIGIN) / SIZE)
		local x2, y2, z2 = math.floor((b.max.x - ORIGIN) / SIZE), math.floor((b.max.y - ORIGIN) / SIZE),
			math.floor((b.max.z - ORIGIN) / SIZE)
		for z = z1, z2 do for y = y1, y2 do for x = x1, x2 do
			if not self.fresh[x .. ":" .. y .. ":" .. z] then return false, "not_fresh" end
		end end end
		return true
	end
	function s:decline(id) self.states[id] = "declined"; return "declined" end
	return s
end

local function box(x1, y1, z1, x2, y2, z2)
	return {min = {x = x1, y = y1, z = z1}, max = {x = x2, y = y2, z = z2}}
end

local function make_fixture(opts)
	opts = opts or {}
	local state, requests, pending = session_fixture(), {}, {}
	local active, max_active, inspections, done_calls = 0, 0, 0, {}
	local env = {
		after = function(_, fn) pending.timers = pending.timers or {}; pending.timers[#pending.timers + 1] = fn end,
		log = function() end,
		emerge = function(minp, maxp, cb)
			active = active + 1; max_active = math.max(max_active, active)
			requests[#requests + 1] = {min = minp, max = maxp}
			local k = chunk_key(minp)
			local function complete(ok)
				state.fresh[k] = opts.record_fresh ~= false and true or nil
				if k == "0:1:0" and opts.no_center ~= true then
					state.ground = {chunk = {minp = {x = -32, y = 48, z = -32}, maxp = {x = 47, y = 127, z = 47}},
						values = {63, 64, 65}, valid = 3, clipped = 0, ambiguous = 0, sentinel = 0}
				end
				active = active - 1
				cb(ok)
			end
			if opts.async then pending[#pending + 1] = complete else complete(opts.fail_first ~= true or #requests > 1) end
		end,
	}
	local search = {inspect_site = function(center, ref_y, seed, inspect_opts, done, inspect_env)
		inspections = inspections + 1
		eq(center.x, 20, "inspector receives explicit center x")
		eq(ref_y, opts.ref_y or 64, "center reference comes from copied values median")
		eq(seed, "world-seed", "seed is forwarded")
		local area = box(-32, 48, -32, 127, 127, 127)
		inspect_env.emerge(area.min, area.max, function(ok)
			if not ok then return done(nil, "urban request failed", {reason = "emerge_failed"}) end
			inspect_env.emerge(area.min, area.max, function(ok2)
				if not ok2 then return done(nil, "duplicate request failed") end
				done({center = center, ground_y = 65, inspection_volume = area})
			end)
		end)
	end}
	local outer = box(48, 48, 48, 127, 127, 127)
	local env_calc = function(result, _, ref_y)
		eq(ref_y, opts.ref_y or 64, "envelope receives center reference height")
		eq(result.reference_y, opts.ref_y or 64, "result carries center reference height")
		return {read = outer, write = outer, chunks = 5, snapshot_voxels = 5 * SIZE * SIZE * SIZE,
			stages = {
				urban_read = {kind = "read", box = outer},
				urban_build = {kind = "write", box = outer},
				walls = {kind = "write", box = box(128, 48, 48, 207, 127, 127)},
			}}
	end
	local loader = assert(loader_mod.new({session = state, site_search = search, envelope = env_calc,
		env = env, origin = ORIGIN, size = SIZE, seed = "world-seed", inspect_opts = {}, request_timeout = 3}))
	local function start()
		loader:start(site, trigger, function(result, reason, code)
			done_calls[#done_calls + 1] = {result = result, reason = reason, code = code}
		end)
	end
	return {state = state, requests = requests, pending = pending, loader = loader, start = start,
		inspections = function() return inspections end, done_calls = done_calls,
		max_active = function() return max_active end, active = function() return active end}
end

-- Center request is first and bounded to one trigger-height mapchunk. Urban requests are deduplicated,
-- serialized, and outer stages wait until exact acceptance.
do
	local f = make_fixture({async = true})
	f.start()
	eq(#f.requests, 1, "center is requested first")
	eq(f.requests[1].min.x, -32, "center x chunk aligned")
	eq(f.requests[1].min.y, 48, "center uses trigger vertical hint")
	eq(f.requests[1].min.z, -32, "center z chunk aligned")
	while #f.pending > 0 do table.remove(f.pending, 1)(true) end
	eq(f.inspections(), 1, "exact inspector called once")
	eq(f.done_calls[1] and f.done_calls[1].result ~= nil, true, "loader returns accepted inspection")
	eq(f.done_calls[1] and f.done_calls[1].result.read_envelope ~= nil, true, "read envelope is returned")
	eq(f.done_calls[1] and f.done_calls[1].result.write_envelope ~= nil, true, "write envelope is returned")
	eq(f.state:state("site"), "inspecting", "session remains inspecting for the later build handoff")
	local seen = {}
	for _, r in ipairs(f.requests) do
		eq(r.max.x - r.min.x + 1, SIZE, "requests stay one mapchunk wide")
		eq(r.max.y - r.min.y + 1, SIZE, "requests stay one mapchunk high")
		eq(r.max.z - r.min.z + 1, SIZE, "requests stay one mapchunk deep")
		local k = chunk_key(r.min)
		eq(seen[k], nil, "deduplicated scheduler requests each chunk once")
		seen[k] = true
	end
	eq(#f.requests, 5, "center, urban footprint and outer wall chunks are loaded")
	eq(chunk_key(f.requests[2].min), "1:1:0", "urban loading proceeds to the nearest chunk")
	eq(chunk_key(f.requests[3].min), "0:1:1", "distance ties use stable chunk coordinates")
	eq(chunk_key(f.requests[5].min), "2:1:1", "outer stage starts after urban acceptance")
end

-- Async callbacks keep one request in flight and ignore a late duplicate completion.
do
	local f = make_fixture({async = true})
	f.start()
	local active_job = f.loader.jobs.site
	eq(#f.pending, 1, "one request is in flight")
	while #f.pending > 0 do
		local cb = table.remove(f.pending, 1)
		cb(true)
		eq(f.max_active(), 1, "scheduler never has two requests in flight")
	end
	eq(#f.done_calls, 1, "async job completes once")
	eq(f.done_calls[1].result ~= nil, true, "async job accepts fresh site")
	eq(f.loader.jobs.site, true, "successful handoff keeps only a duplicate-suppression marker")
	eq(active_job.done, nil, "terminal job releases its completion closure")
	eq(active_job.site, nil, "terminal job releases its site descriptor")
	eq(active_job.requested, nil, "terminal job releases request history")
	eq(active_job.completed, nil, "terminal job releases completion history")
	local before = #f.requests
	local accepted, duplicate = f.loader:start(site, trigger, function() end)
	eq(accepted, false, "successful site cannot start twice")
	eq(duplicate, "already_started", "successful site reports duplicate start")
	eq(#f.requests, before, "duplicate start submits no terrain requests")
end

-- A copied center from ordinary exploration is reused without requesting that chunk again.
do
	local f = make_fixture({ref_y = 71})
	f.state.ground = {chunk = {minp = {x = -32, y = 48, z = -32}, maxp = {x = 47, y = 127, z = 47}},
		values = {70, 72, 71}, valid = 3}
	f.state.fresh["0:1:0"] = true
	f.start()
	eq(f.requests[1] and chunk_key(f.requests[1].min), "1:1:0", "explored center data skips center emerge")
	eq(f.inspections(), 1, "explored center still invokes exact inspection once")
	eq(f.done_calls[1] and f.done_calls[1].result ~= nil, true, "explored center can complete")
end

-- An exact urban rejection stops before requesting outer-stage chunks.
do
	local f = make_fixture()
	f.loader.site_search.inspect_site = function(_, _, _, _, done, inspect_env)
		local area = box(-32, 48, -32, 127, 127, 127)
		inspect_env.emerge(area.min, area.max, function(ok)
			if ok then done(nil, "urban terrain rejected", {reason = "too_uneven"}) end
		end)
	end
	f.start()
	eq(f.done_calls[1] and f.done_calls[1].result, nil, "urban rejection returns no result")
	eq(f.state.states.site, "declined", "urban rejection declines the site")
	for _, r in ipairs(f.requests) do
		eq(chunk_key(r.min) ~= "2:1:1", true, "outer stage chunk is untouched after urban rejection")
	end
end

-- Without copied center ground, the site declines and exact inspection never runs.
do
	local f = make_fixture({no_center = true})
	f.start()
	eq(f.inspections(), 0, "missing center ground does not invoke inspector")
	eq(f.done_calls[1] and f.done_calls[1].code, "center_ground_missing", "missing center ground is terminal")
	eq(f.state.states.site, "declined", "missing center ground declines session")
	eq(f.loader.jobs.site, nil, "failed job is removed from the loader")
	local before = #f.requests
	local accepted, duplicate = f.loader:start(site, trigger, function() end)
	eq(accepted, false, "declined site cannot start twice")
	eq(duplicate, "terminal", "declined site is suppressed by session state")
	eq(#f.requests, before, "terminal suppression submits no terrain requests")
end

-- Real site_search integration: sequential chunks may take longer than its ordinary 30-second
-- area watchdog while each request completes within the loader's per-chunk timeout.
do
	local search = dofile("src/site_search.lua")(placement, planner)
	local state = session_fixture()
	state.ground = {chunk = {minp = {x = -32, y = -32, z = -32}, maxp = {x = 47, y = 47, z = 47}},
		values = {20}, valid = 1}
	state.fresh["0:0:0"] = true
	local queue, timers, clock = {}, {}, 0
	local request_count, inspector_deadlines, calls = 0, {}, 0
	local catalog = dofile("src/catalog.lua")
	local profile = assert(planner.landmark_profile(catalog.snapshot()))
	local env = {
		emerge = function(_, _, cb) request_count = request_count + 1; queue[#queue + 1] = cb end,
		after = function(seconds, fn)
			timers[#timers + 1] = {at = clock + seconds, fn = fn}
			if seconds > 30 then inspector_deadlines[#inspector_deadlines + 1] = seconds end
		end,
		get_node_name = function() return "air" end,
		node_info = function() return {walkable = false, liquid = false, clearable = true} end,
		log = function() end,
	}
	local loader = assert(loader_mod.new({session = state, site_search = search,
		envelope = function() error("rejected terrain has no envelope") end,
		env = env, origin = ORIGIN, size = SIZE, seed = 1, request_timeout = 5,
		inspect_opts = {entries = catalog.entries, planner_opts = {landmarks = profile}}}))
	loader:start(site, trigger, function(result, reason, code, details)
		calls = calls + 1
		eq(result, nil, "real exact inspector rejects all-air terrain")
		eq(reason ~= nil, true, "real exact inspector reports its rejection")
		eq(code, "inspection_failed", "real exact inspector terminates through loader once")
		eq(details and details.rejections and details.rejections.no_ground, 1,
			"real exact inspector rejection code reaches loader caller")
		eq(type(details and details.examples and details.examples.no_ground), "string",
			"real exact inspector rejection example reaches loader caller")
	end)
	local guard = 0
	while (#queue > 0 or #timers > 0) and calls == 0 and guard < 500 do
		guard = guard + 1
		if #queue > 0 then
			local complete = table.remove(queue, 1)
			clock = clock + 2
			complete(true)
		else
			table.sort(timers, function(a, b) return a.at < b.at end)
			local timer = table.remove(timers, 1)
			clock = math.max(clock, timer.at)
			timer.fn()
		end
		local i = 1
		while i <= #timers do
			if timers[i].at <= clock then
				local timer = table.remove(timers, i)
				timer.fn()
			else
				i = i + 1
			end
		end
	end
	eq(calls, 1, "real site_search callback settles once")
	eq(clock > 30, true, "serialized urban loading takes over 30 simulated seconds")
	eq(request_count > 15, true, "real inspector volume spans enough chunks to exceed 30 seconds")
	eq(#inspector_deadlines > 0 and inspector_deadlines[1] > 30, true,
		"real inspector watchdog is extended to bound the serialized queue")
end

-- Old neighboring terrain can satisfy the emerge API but cannot authorize a possible write.
do
	local f = make_fixture({record_fresh = false})
	f.start()
	eq(f.done_calls[1] and f.done_calls[1].code, "not_fresh", "old terrain is rejected by session coverage")
	eq(f.state.states.site, "declined", "stale coverage declines")
end

-- A failed or timed-out request terminates once; subsequent callback delivery is ignored.
do
	local f = make_fixture({async = true})
	f.start()
	local active_job = f.loader.jobs.site
	local cb = table.remove(f.pending, 1)
	cb(false)
	eq(#f.done_calls, 1, "failed request completes once")
	eq(f.done_calls[1].result, nil, "failed request returns no inspection")
	cb(true)
	eq(#f.done_calls, 1, "late request callback is ignored")
	eq(f.inspections(), 0, "failed center request never inspects")
	eq(f.loader.jobs.site, nil, "failed job is removed from the loader")
	eq(active_job.done, nil, "failed job releases its completion closure")
	eq(active_job.requested, nil, "failed job releases request history")
end

-- Frozen cap checks reject a broad request before it reaches env.emerge.
do
	local f = make_fixture()
	f.loader.caps = {MAX_REQUEST_CHUNKS = 1, MAX_SNAPSHOT_VOXELS = SIZE * SIZE * SIZE}
	f.start()
	-- Center uses one chunk, then the inspector's multi-chunk urban box is rejected.
	eq(f.done_calls[1] and f.done_calls[1].code, "chunk_cap", "request cap is enforced")
	eq(f.inspections(), 1, "urban inspection callback request is checked before next chunk")
	-- Only the center request reached the environment.
	eq(#f.requests, 1, "cap rejection occurs before additional emerge requests")
end
