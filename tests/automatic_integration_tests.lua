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

local function fixture()
	local f = {timers = {}, requests = {}, reports = {}, reads = 0, writes = 0, begins = 0}
	local current, height, locked
	local core = {settings = {get = function() return "survey" end},
		get_mapgen_setting = function(k) return ({mg_name = "flat", chunksize = "5", seed = "42"})[k] end,
		get_connected_players = function() return {} end, get_us_time = function() return 1000000 end,
		log = function() end, write_json = function(t) f.reports[#f.reports + 1] = t; return "result" end,
		register_on_generated = function(fn) f.generated = fn end,
		get_mapgen_object = function() f.reads = f.reads + 1; return height end,
		after = function(delay, fn) f.timers[#f.timers + 1] = {delay = delay, fn = fn} end,
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
	local env = {plan_envelope = function() return {read = box, write = box, chunks = 1,
		snapshot_voxels = 512000, stages = {urban = {kind = "write", box = box}}} end}
	local search = {WET_DEFAULTS = {}, core_env = function() return {
		after = core.after, emerge = function(minp, maxp, cb)
			f.requests[#f.requests + 1] = {minp = minp, maxp = maxp, cb = cb}
		end} end,
		inspect_site = function(center, ref, seed, opts, done, io)
			f.reference = ref
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
	f.complete = function(ok)
		local req = table.remove(f.requests, 1)
		if ok then emit(req.minp, req.maxp, 64) end
		req.cb(ok)
	end
	f.timeout = function() for _, timer in ipairs(f.timers) do if timer.delay == 30 then timer.fn(); return end end end
	return f
end

local min = {x = -32, y = 48, z = -32}
local max = {x = 47, y = 127, z = 47}
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
	eq(f.session:state("B"), "declined", "nearby activation declines during nested emergence")
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
