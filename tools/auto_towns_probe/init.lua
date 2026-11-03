-- Scratch-world observer for the automatic-towns frontier probe (#391, slice 0).
--
-- Only tools/auto_towns_probe/run.py installs this, into a disposable copy of
-- a world. It observes natural generation, the public village functions and
-- one connected player. It never writes nodes, never loads Towns, and emerges
-- only the bounded fixture boxes it is given. Every record is one JSON line
-- with an id "p<phase>-<seq>". Scripted fixture demand is a proxy for load,
-- not evidence of real player request latency.
--
-- Wrapped (and restored on exit): core.emerge_area, settlements.evaluate_heightmap,
-- settlements.create_site_plan and settlements.place_schematics. The on_generated
-- callback cannot be unregistered; it stops recording once the observer finishes.
local core = minetest
local settings = core.settings

local PHASE = tonumber(settings:get("auto_towns_probe_phase")) or 1
local DURATION = tonumber(settings:get("auto_towns_probe_duration")) or 60
local START_DELAY = tonumber(settings:get("auto_towns_probe_start_delay")) or 2
local FIXTURE_TEXT = settings:get("auto_towns_probe_fixture") or ""
local SCENARIO = settings:get("auto_towns_probe_scenario") or ""
local INVOCATION = settings:get("auto_towns_probe_invocation") or ""
-- Forceloading activates fixture blocks so their LBMs (village planning) run
-- without a player nearby. It is opt-in and only after every fixture completes.
local FORCELOAD = settings:get_bool("auto_towns_probe_forceload", false)
local forceloaded, forceload_done, forceload_ms = 0, false, nil
-- Longest main-loop step seen (dtime) and when, to expose stalls on the server thread.
local max_step = {s = 0, at_s = nil}
local BLOCK = 16 -- mapblock edge in nodes
local MAX_FIXTURE_BLOCKS = 1024
local MAX_ROUTE_SPEED = 30
local HEIGHT_LIMIT = 30000
local SAMPLES = 7 -- per axis; samples per generated chunk are (SAMPLES+1)^3
local EVENTS_NAME = ("auto-towns-probe-phase%d.jsonl"):format(PHASE)
local REPORT_NAME = ("auto-towns-probe-phase%d.json"):format(PHASE)

local t0 = core.get_us_time()
local function elapsed()
	return (core.get_us_time() - t0) / 1000000
end

-- Write-through log (#392): each wt record is written and flushed by the callback that
-- produced it, so records from late completions and engine shutdown are not lost.
-- The queued events file is still drained by the main thread and stops at finish().
local WT_NAME = ("auto-towns-probe-writethrough-phase%d.jsonl"):format(PHASE)
local wt_file = io.open(core.get_worldpath() .. "/" .. WT_NAME, "w")
local function wt(rec)
	if not wt_file then return end
	rec.t_ms = math.floor((core.get_us_time() - t0) / 1000)
	wt_file:write(core.write_json(rec), "\n")
	wt_file:flush()
end

local finished = false
local active = true
local queue = {}
local seq = 0
local events_file
local errors, error_total = {}, 0
local counts = {
	generated = 0, by_class = {}, opportunity = 0, heightmap_with_surface = 0,
	emerge_requests = {}, emerge_blocks = {}, terrain = {}, village = {},
	route = {}, player_samples = 0, max_connected = 0, nearest_player_samples = 0,
}

local function bump(t, k)
	t[k] = (t[k] or 0) + 1
end

local function emit(rec)
	queue[#queue + 1] = rec
end

local function observer_error(where, err)
	emit({kind = "error", where = where, message = tostring(err)})
end

-- Writes queued records on the main thread (also drains on_generated records).
local function account(rec)
	local k = rec.kind
	if k == "generated" then
		counts.generated = counts.generated + 1
		bump(counts.by_class, rec.class)
		if rec.opportunity then counts.opportunity = counts.opportunity + 1 end
		if rec.heightmap and rec.heightmap.valid and rec.heightmap.valid > 0 then
			counts.heightmap_with_surface = counts.heightmap_with_surface + 1
		end
		if rec.nearest_player_status == "sampled" then
			counts.nearest_player_samples = counts.nearest_player_samples + 1
		end
	elseif k == "emerge_request" then
		bump(counts.emerge_requests, rec.source)
	elseif k == "emerge_block" then
		bump(counts.emerge_blocks, rec.action)
	elseif k == "terrain" then
		bump(counts.terrain, rec.passed == nil and "unknown" or (rec.passed and "passed" or "rejected"))
	elseif k == "village" then
		bump(counts.village, rec.outcome)
	elseif k == "route" then
		bump(counts.route, rec.status)
	elseif k == "error" then
		error_total = error_total + 1
		if #errors < 20 then errors[#errors + 1] = rec end
	end
end

local function drain()
	if #queue == 0 then return end
	local batch = queue
	queue = {}
	for _, rec in ipairs(batch) do
		seq = seq + 1
		rec.seq = seq
		rec.id = ("p%d-%06d"):format(PHASE, seq)
		account(rec)
		if events_file then events_file:write(core.write_json(rec), "\n") end
	end
	if events_file then events_file:flush() end
end

-- Fixtures: "id:x1,y1,z1,x2,y2,z2;..." (inclusive node boxes), bounded by blocks.
local function block_count(minp, maxp)
	local function n(a, b)
		return math.floor(b / BLOCK) - math.floor(a / BLOCK) + 1
	end
	return n(minp.x, maxp.x) * n(minp.y, maxp.y) * n(minp.z, maxp.z)
end

local function parse_fixtures(text)
	local list, total = {}, 0
	for item in text:gmatch("[^;]+") do
		local id, rest = item:match("^%s*([%w_%-]+):(.-)%s*$")
		assert(id, "bad fixture (want id:x1,y1,z1,x2,y2,z2): " .. item)
		local v = {}
		for num in rest:gmatch("[^,]+") do v[#v + 1] = assert(tonumber(num), "bad fixture number in " .. item) end
		assert(#v == 6, "fixture needs six integers: " .. item)
		local minp = {x = math.min(v[1], v[4]), y = math.min(v[2], v[5]), z = math.min(v[3], v[6])}
		local maxp = {x = math.max(v[1], v[4]), y = math.max(v[2], v[5]), z = math.max(v[3], v[6])}
		local blocks = block_count(minp, maxp)
		total = total + blocks
		list[#list + 1] = {id = id, minp = minp, maxp = maxp, blocks = blocks, done = 0, final = false, actions = {}}
	end
	assert(total <= MAX_FIXTURE_BLOCKS, ("fixtures request %d mapblocks, cap is %d"):format(total, MAX_FIXTURE_BLOCKS))
	return list, total
end
local fixtures, fixture_blocks = parse_fixtures(FIXTURE_TEXT)

-- Route (optional): route.json in the scratch world, mode walk|fly.
local function load_route()
	local f = io.open(core.get_worldpath() .. "/route.json", "r")
	if not f then return nil end
	local body = f:read("*a")
	f:close()
	local r = assert(core.parse_json(body), "route.json is not JSON")
	assert(r.mode == "walk" or r.mode == "fly", "route mode must be walk or fly")
	local speed = tonumber(r.speed)
	assert(speed and speed > 0 and speed <= MAX_ROUTE_SPEED, "route speed must be in (0, " .. MAX_ROUTE_SPEED .. "]")
	assert(type(r.points) == "table" and #r.points >= 2 and #r.points <= 200, "route needs 2 to 200 points")
	return r
end
local route = load_route()
local route_status = route and "no_player" or "absent"
local route_started, route_done, route_index, route_pos = false, false, 1, nil
local route_last_sample = -1
local route_ungrounded = 0

-- Connected-player samples, refreshed on the main thread; read by on_generated.
local player_cache, player_sample_at = {}, -1

local function refresh_players()
	local list = {}
	for _, p in ipairs(core.get_connected_players()) do
		local pos = p:get_pos()
		list[#list + 1] = {x = pos.x, y = pos.y, z = pos.z}
	end
	player_cache = list
	player_sample_at = elapsed()
	counts.player_samples = counts.player_samples + 1
	if #list > counts.max_connected then counts.max_connected = #list end
end

local function nearest_distance(p)
	local best
	for _, q in ipairs(player_cache) do
		local d = math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2 + (p.z - q.z) ^ 2)
		if not best or d < best then best = d end
	end
	return best
end

-- Generated-chunk classification, read inside the callback from the mapgen
-- VoxelManip. Samples non-air nodes on a coarse grid: none = sky, all = underground.
local function sample_class(minp, maxp)
	local vm, emin, emax = core.get_mapgen_object("voxelmanip")
	if not vm then return "unavailable" end
	local data = vm:get_data()
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local air, ignore = core.get_content_id("air"), core.CONTENT_IGNORE
	local solid, empty = 0, 0
	for i = 0, SAMPLES do
		for j = 0, SAMPLES do
			for k = 0, SAMPLES do
				local x = math.floor(minp.x + i * (maxp.x - minp.x) / SAMPLES)
				local y = math.floor(minp.y + j * (maxp.y - minp.y) / SAMPLES)
				local z = math.floor(minp.z + k * (maxp.z - minp.z) / SAMPLES)
				local c = data[area:indexp({x = x, y = y, z = z})]
				if c == air then empty = empty + 1
				elseif c ~= ignore then solid = solid + 1 end
			end
		end
	end
	if solid + empty == 0 then return "unavailable" end
	if solid == 0 then return "sky" end
	if empty == 0 then return "underground" end
	return "surface"
end

-- Copies the heightmap summary during the callback; no table outlives it.
local function heightmap_summary()
	local hm = core.get_mapgen_object("heightmap")
	if type(hm) ~= "table" then return {status = "unavailable"} end
	local vals, n = {}, 0
	for i = 1, #hm do
		n = n + 1
		local v = hm[i]
		if type(v) == "number" and v > -HEIGHT_LIMIT and v < HEIGHT_LIMIT then vals[#vals + 1] = v end
	end
	table.sort(vals)
	local out = {n = n, valid = #vals, invalid = n - #vals}
	if #vals > 0 then
		out.min, out.max = vals[1], vals[#vals]
		out.median = vals[math.ceil(#vals / 2)]
	end
	return out
end

-- Center column (#392, A9): the heightmap value the design would copy for the center
-- column, under two candidate index layouts, next to the top solid node found by
-- scanning this chunk's VoxelManip. The scan is verification only; it is never part of
-- a runtime path. Returns nil when no heightmap or VoxelManip is available.
local function center_check(mn, mx)
	local hm = core.get_mapgen_object("heightmap")
	local vm, emin, emax = core.get_mapgen_object("voxelmanip")
	if type(hm) ~= "table" or not vm then return nil end
	local side_x, side_z = mx.x - mn.x + 1, mx.z - mn.z + 1
	local cx, cz = math.floor((mn.x + mx.x) / 2), math.floor((mn.z + mx.z) / 2)
	local ix, iz = cx - mn.x, cz - mn.z
	local out = {
		x = cx, z = cz,
		hm_x_fastest = hm[iz * side_x + ix + 1],
		hm_z_fastest = hm[ix * side_z + iz + 1],
	}
	local data = vm:get_data()
	local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
	local air, ignore = core.get_content_id("air"), core.CONTENT_IGNORE
	for y = mx.y, mn.y, -1 do
		local c = data[area:indexp({x = cx, y = y, z = cz})]
		if c ~= air and c ~= ignore then out.vm_top = y; break end
	end
	return out
end

-- on_generated runs in the emerge thread: no world queries beyond mapgen objects.
core.register_on_generated(function(minp, maxp, blockseed)
	if not active then
		-- After finish the queued observer stops, but generation continues during shutdown.
		-- The write-through record still notes it (#392, A13), so the gap is visible, not silent.
		pcall(function()
			wt({kind = "wt_generated", after_finish = true, minp = {x = minp.x, y = minp.y, z = minp.z},
				maxp = {x = maxp.x, y = maxp.y, z = maxp.z}, valid = heightmap_summary().valid})
		end)
		return
	end
	local ok, err = pcall(function()
		local mn = {x = minp.x, y = minp.y, z = minp.z}
		local mx = {x = maxp.x, y = maxp.y, z = maxp.z}
		local rec = {
			kind = "generated",
			t_ms = math.floor((core.get_us_time() - t0) / 1000),
			minp = mn, maxp = mx,
			class = sample_class(mn, mx),
			heightmap = heightmap_summary(),
			-- VoxelManip of villages.lua's seed gate (mcl_villages: blockseed % 77 == 17, maxp.y >= 0).
			opportunity = mx.y >= 0 and blockseed % 77 == 17,
		}
		local center = {x = (mn.x + mx.x) / 2, y = (mn.y + mx.y) / 2, z = (mn.z + mx.z) / 2}
		local d = nearest_distance(center)
		rec.nearest_player_status = player_sample_at < 0 and "never_sampled" or (d and "sampled" or "none")
		rec.nearest_player_distance = d -- key absent = null (no connected player at the last sample)
		emit(rec)
		wt({kind = "wt_generated", minp = mn, maxp = mx, class = rec.class,
			valid = rec.heightmap.valid, center = center_check(mn, mx), blockseed = blockseed})
	end)
	if not ok then observer_error("on_generated", err) end
end)

-- Emerge instrumentation: requests, per-block completions and their source.
local real_emerge = core.emerge_area
local request_count = 0
local pending_fixture
local ACTION = {}
for name, value in pairs({
	generated = core.EMERGE_GENERATED, from_memory = core.EMERGE_FROM_MEMORY,
	from_disk = core.EMERGE_FROM_DISK, cancelled = core.EMERGE_CANCELLED, errored = core.EMERGE_ERRORED,
}) do
	if value ~= nil then ACTION[value] = name end
end

local function vec_table(v)
	return {x = v.x, y = v.y, z = v.z}
end

local function caller_name()
	if not debug or not debug.getinfo then return "unknown" end
	local info = debug.getinfo(3, "S")
	return info and info.short_src and info.short_src:match("([^/\\]+)$") or "unknown"
end

local emerge_wrapper
emerge_wrapper = function(minp, maxp, callback, param)
	local fixture = pending_fixture
	pending_fixture = nil
	request_count = request_count + 1
	local rid = ("r%d"):format(request_count)
	local source = fixture and "fixture" or "other"
	emit({kind = "emerge_request", request = rid, source = source,
		fixture = fixture and fixture.id or nil, caller = not fixture and caller_name() or nil,
		minp = vec_table(minp), maxp = vec_table(maxp)})
	wt({kind = "wt_request", request = rid, source = source, minp = vec_table(minp), maxp = vec_table(maxp)})
	local wrapped = function(blockpos, action, calls_remaining, cb_param)
		local name = ACTION[action] or tostring(action)
		emit({kind = "emerge_block", request = rid, source = source, fixture = fixture and fixture.id or nil,
			block = vec_table(blockpos), action = name, calls_remaining = calls_remaining})
		wt({kind = "wt_emerge", request = rid, source = source, block = vec_table(blockpos), action = name,
			calls_remaining = calls_remaining,
			-- Bundled API says the mapgen heightmap is nil outside on_generated; recorded as observed,
			-- with its summary, so a stale or foreign heightmap would show up as a mismatch (#392, A9).
			mapgen_heightmap_in_callback = core.get_mapgen_object("heightmap") ~= nil,
			hm = core.get_mapgen_object("heightmap") and heightmap_summary() or nil})
		if fixture then
			fixture.done = fixture.done + 1
			bump(fixture.actions, name)
			if calls_remaining == 0 then fixture.final = true end
		end
		if callback then callback(blockpos, action, calls_remaining, cb_param) end
	end
	return real_emerge(minp, maxp, wrapped, param)
end
core.emerge_area = emerge_wrapper

-- Village observations through the public settlements functions (wrapped and
-- restored). The planner wrapper of Living Villages is already installed when
-- this mod loads (optional_depends), so the chain here is observer -> LV -> VoxeLibre.
local settlements = rawget(_G, "settlements")
local orig = {}
local our = {} -- the observer's own wrapper functions, to tell at exit whether they are still installed
if settlements then
	orig.heights = settlements.evaluate_heightmap
	orig.plan = settlements.create_site_plan
	orig.place = settlements.place_schematics

	-- Each wrapper returns exactly what the wrapped function returned.
	local heights_wrapper = function(...)
		local h = orig.heights(...)
		local limit = rawget(_G, "max_height_difference")
		local passed
		if type(h) == "number" and type(limit) == "number" then passed = h <= limit end
		emit({kind = "terrain", height_difference = h, limit = limit, passed = passed})
		return h
	end
	settlements.evaluate_heightmap = heights_wrapper

	local plan_wrapper = function(maxp, minp, pr)
		wt({kind = "wt_planner", state = "enter", minp = vec_table(minp), maxp = vec_table(maxp)})
		local plan, why = orig.plan(maxp, minp, pr)
		wt({kind = "wt_planner", state = "exit", planned = type(plan) == "table" and #plan > 0})
		if type(plan) == "table" and #plan > 0 then
			emit({kind = "village", outcome = "planned", buildings = #plan,
				minp = vec_table(minp), maxp = vec_table(maxp)})
		else
			emit({kind = "village", outcome = "no_plan", reason = type(why) == "string" and why or nil,
				minp = vec_table(minp), maxp = vec_table(maxp)})
		end
		return plan, why
	end
	settlements.create_site_plan = plan_wrapper

	-- pcall only to record a failure; the error is rethrown unchanged and results pass through.
	local function after_place(info, ok, ...)
		if ok then
			emit({kind = "village", outcome = "placed", buildings = type(info) == "table" and #info or 0})
			return ...
		end
		emit({kind = "village", outcome = "place_error"})
		observer_error("place_schematics", (...))
		error((...), 0)
	end
	local place_wrapper = function(info, pr)
		return after_place(info, pcall(orig.place, info, pr))
	end
	settlements.place_schematics = place_wrapper

	our = {heights = heights_wrapper, plan = plan_wrapper, place = place_wrapper}
end

-- Checks which wrappers are still the observer's own (before restoring), puts every
-- wrapped global back and reports whether all of them now hold their originals.
local function restore()
	local still_ours = {emerge = core.emerge_area == emerge_wrapper}
	if settlements then
		still_ours.evaluate_heightmap = settlements.evaluate_heightmap == our.heights
		still_ours.create_site_plan = settlements.create_site_plan == our.plan
		still_ours.place_schematics = settlements.place_schematics == our.place
	end
	core.emerge_area = real_emerge
	if settlements then
		settlements.evaluate_heightmap = orig.heights
		settlements.create_site_plan = orig.plan
		settlements.place_schematics = orig.place
	end
	active = false
	local restored = core.emerge_area == real_emerge
	if settlements then
		restored = restored and settlements.evaluate_heightmap == orig.heights
			and settlements.create_site_plan == orig.plan and settlements.place_schematics == orig.place
	end
	return restored, still_ours
end

-- Route driver: needs a connected client; without one the route stays no_player.
local function ground_y(x, y, z)
	for yy = y + 24, y - 80, -1 do
		local n = core.get_node_or_nil({x = x, y = yy, z = z})
		if not n then return nil end
		if n.name ~= "air" then return yy + 1 end
	end
	return nil
end

local function step_route(dtime, now)
	if not route or route_done or now < START_DELAY then return end
	local p = core.get_connected_players()[1]
	if not p then return end
	if not route_started then
		route_started = true
		route_status = "driven"
		local a = route.points[1]
		route_pos = {x = a[1], y = a[2], z = a[3]}
	end
	local speed = tonumber(route.speed)
	local fly = route.mode == "fly"
	local budget = speed * dtime
	while budget > 0 and route_index < #route.points do
		local b = route.points[route_index + 1]
		local dx, dy, dz = b[1] - route_pos.x, fly and (b[2] - route_pos.y) or 0, b[3] - route_pos.z
		local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
		if dist <= budget then
			budget = budget - dist
			route_pos = {x = b[1], y = fly and b[2] or route_pos.y, z = b[3]}
			route_index = route_index + 1
		else
			local f = budget / dist
			route_pos = {x = route_pos.x + dx * f, y = fly and (route_pos.y + dy * f) or route_pos.y, z = route_pos.z + dz * f}
			budget = 0
		end
	end
	if not fly then
		local g = ground_y(route_pos.x, route_pos.y, route_pos.z)
		if g then route_pos.y = g else route_ungrounded = route_ungrounded + 1 end
	end
	p:set_pos({x = route_pos.x, y = route_pos.y, z = route_pos.z})
	if route_index >= #route.points then route_done = true end
	if route_done then route_status = "completed" end
	if route_done or now - route_last_sample >= 1 then
		route_last_sample = now
		emit({kind = "route", status = route_done and "completed" or "driven", t_ms = math.floor(now * 1000),
			pos = {x = math.floor(route_pos.x), y = math.floor(route_pos.y), z = math.floor(route_pos.z)},
			players = #core.get_connected_players()})
	end
end

local issued = false
local function issue_fixtures()
	for _, f in ipairs(fixtures) do
		pending_fixture = f
		core.emerge_area(f.minp, f.maxp, nil, nil)
		pending_fixture = nil
		emit({kind = "fixture_requested", fixture = f.id, blocks = f.blocks,
			minp = vec_table(f.minp), maxp = vec_table(f.maxp)})
	end
end

local function fixtures_complete()
	for _, f in ipairs(fixtures) do
		if not (f.done == f.blocks and f.final) then return false end
	end
	return true
end

local function forceload_fixtures()
	forceload_done = true
	local started = core.get_us_time()
	for _, f in ipairs(fixtures) do
		for bx = math.floor(f.minp.x / BLOCK), math.floor(f.maxp.x / BLOCK) do
			for by = math.floor(f.minp.y / BLOCK), math.floor(f.maxp.y / BLOCK) do
				for bz = math.floor(f.minp.z / BLOCK), math.floor(f.maxp.z / BLOCK) do
					if core.forceload_block({x = bx * BLOCK, y = by * BLOCK, z = bz * BLOCK}, true) then
						forceloaded = forceloaded + 1
					end
				end
			end
		end
	end
	forceload_ms = (core.get_us_time() - started) / 1000
	emit({kind = "forceload", blocks = forceloaded, ms = forceload_ms})
end

local function build_report(reason, restored, still_ours)
	local fixture_report = {}
	local all_complete = true
	for _, f in ipairs(fixtures) do
		local complete = f.done == f.blocks and f.final
		all_complete = all_complete and complete
		fixture_report[#fixture_report + 1] = {id = f.id, minp = f.minp, maxp = f.maxp, blocks = f.blocks,
			reported = f.done, final_seen = f.final, actions = f.actions, complete = complete}
	end
	local mg = function(name)
		return core.get_mapgen_setting(name)
	end
	local checks = {}
	local function check(ok, label)
		checks[#checks + 1] = {ok = ok and true or false, label = label}
	end
	check(restored, "callback instrumentation restored on exit")
	check(error_total == 0, "observer reported no errors (" .. error_total .. ")")
	for _, f in ipairs(fixture_report) do
		check(f.reported == f.blocks, ("fixture %s reported every block (%d of %d)"):format(f.id, f.reported, f.blocks))
		check(f.final_seen, ("fixture %s final callback seen"):format(f.id))
	end
	local ok = true
	for _, c in ipairs(checks) do ok = ok and c.ok end
	return {
		probe = "auto_towns_probe", issue = 391, slice = 0,
		scenario = SCENARIO, phase = PHASE, invocation = INVOCATION,
		reason = reason,
		engine = core.get_version and core.get_version() or nil,
		game = core.get_game_info and core.get_game_info() or nil,
		modpaths = {living_villages = core.get_modpath("living_villages"), mcl_villages = core.get_modpath("mcl_villages")},
		mapgen = {mg_name = mg("mg_name"), seed = mg("seed"), chunksize = tonumber(mg("chunksize")),
			mapgen_limit = tonumber(mg("mapgen_limit")), water_level = tonumber(mg("water_level"))},
		duration_s = elapsed(), configured_duration_s = DURATION, start_delay_s = START_DELAY,
		fixtures = fixture_report, fixture_blocks = fixture_blocks,
		forceload = {requested = FORCELOAD, done = forceload_done, blocks = forceloaded, ms = forceload_ms},
		main_loop = {longest_step_s = max_step.s, longest_step_at_s = max_step.at_s},
		route = {status = route_status, mode = route and route.mode or nil, speed = route and route.speed or nil,
			completed = route_done, ungrounded_steps = route_ungrounded},
		observations = counts,
		errors = {total = error_total, first = errors},
		events = {file = EVENTS_NAME, count = seq},
		instrumentation_restored = restored,
		wrappers_still_ours_at_exit = still_ours,
		checks = checks,
		ok = ok and all_complete,
	}
end

local function finish(reason, from_shutdown)
	if finished then return end
	finished = true
	wt({kind = "wt_finish", reason = reason, from_shutdown = from_shutdown and true or false})
	local restored, still_ours = restore()
	drain()
	local report = build_report(reason, restored, still_ours)
	if events_file then
		events_file:close()
		events_file = nil
	end
	local f = assert(io.open(core.get_worldpath() .. "/" .. REPORT_NAME, "w"))
	f:write(core.write_json(report, true))
	f:close()
	if not from_shutdown then core.request_shutdown("auto towns probe done", false, 0) end
end

events_file = assert(io.open(core.get_worldpath() .. "/" .. EVENTS_NAME, "w"))

core.register_globalstep(function(dtime)
	if finished then return end
	local now = elapsed()
	if dtime > max_step.s then max_step = {s = dtime, at_s = now} end
	if not issued and now >= START_DELAY then
		issued = true
		issue_fixtures()
	end
	if now - player_sample_at >= 0.5 then refresh_players() end
	if FORCELOAD and not forceload_done and issued and fixtures_complete() then forceload_fixtures() end
	local ok, err = pcall(step_route, dtime, now)
	if not ok then observer_error("route", err) end
	drain()
	if now >= DURATION then finish("duration reached", false) end
end)

core.register_on_shutdown(function()
	finish("engine shutdown", true)
end)
