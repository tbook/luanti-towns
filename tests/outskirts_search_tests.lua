local eq = ...
local outskirts = dofile("src/outskirts.lua")
local urban_catalog = dofile("src/catalog.lua")
local rural = dofile("schematics/outskirts/catalog.lua")

local C = outskirts.CONSTANTS
local saved = {farm = C.FARM_COUNT, hut = C.HUT_COUNT, villa = C.VILLA_COUNT,
	chapel = C.CHAPEL_COUNT, attempts = C.ATTEMPTS_PER_BUILDING}
C.FARM_COUNT, C.HUT_COUNT, C.VILLA_COUNT, C.CHAPEL_COUNT = 1, 0, 0, 0
C.ATTEMPTS_PER_BUILDING = 2

-- This seed supplies two non-overlapping larger farms in the near band.
local plan = {town_type = "roman", seed = 1, center = {x = 500, z = 500},
	bounds = {x1 = 400, z1 = 400, x2 = 600, z2 = 600}}
local result = {plan = plan, center = plan.center, ground_y = 64, marker = "urban result"}
local before = {plan = result.plan, marker = result.marker, outskirts = result.outskirts}
local entries = outskirts.assets(urban_catalog.entries)
local _, conflict_code = outskirts.assets({farm = {class = "urban"}})
eq(conflict_code, "outskirts_error", "rural id collision is a programming error")

local function world(water_y)
	local calls = {volume = {}, emerge = 0, writes = 0}
	local terrain = {
		terraform = function() calls.writes = calls.writes + 1; return true, {} end,
		volume = function(got_plan, schematic, options)
			calls.volume[#calls.volume + 1] = {plan = got_plan, schematic = schematic, options = options}
			if got_plan[1].pos.y then
				return {minp = {x = got_plan[1].pos.x, y = got_plan[1].pos.y - 10, z = got_plan[1].pos.z},
					maxp = {x = got_plan[1].pos.x + 20, y = got_plan[1].pos.y + 20, z = got_plan[1].pos.z + 20}}
			end
			return {minp = {x = got_plan[1].pos.x, y = options.surface_y.min, z = got_plan[1].pos.z},
				maxp = {x = got_plan[1].pos.x + 20, y = options.surface_y.max, z = got_plan[1].pos.z + 20}}
		end,
	}
	local env = {
		emerge = function(_, _, cb) calls.emerge = calls.emerge + 1; cb(true) end,
		get_node_name = function(_, y)
			if water_y and y == water_y then return "water" end
			return y == 64 and "ground" or "air"
		end,
		node_info = function(name)
			if name == "ground" then return {walkable = true} end
			if name == "water" then return {walkable = false, liquid = true} end
			return {walkable = false}
		end,
		after = function(_, fn) fn() end,
	}
	return terrain, env, calls
end

C.FARM_COUNT, C.ATTEMPTS_PER_BUILDING = 2, 1
local terrain, env, calls = world()
local completed, out, message, kind = 0
outskirts.search(result, {assets = urban_catalog.entries, terrain = terrain}, function(a, b, c)
	completed, out, message, kind = completed + 1, a, b, c
end, env)
eq(completed, 1, "synchronous callbacks complete once")
eq(message, nil, "flat site succeeds")
eq(kind, nil, "success has no failure kind")
eq(out.status, "planned", "accepted flat plot is planned")
eq(out.plots[1].ground_y, 64, "surface row is site ground Y")
eq(out.plots[1].heights.min, 64, "footprint records minimum surface")
eq(#calls.volume, 4, "two candidates and two final accepted volumes are queried")
eq(calls.volume[1].plan[1].pos.y, nil, "unknown candidate height omits pos.y")
eq(calls.volume[1].options.surface_y.min, 16, "unknown surface interval reaches down 48")
eq(calls.volume[1].options.surface_y.max, 112, "unknown surface interval reaches up 48")
eq(calls.volume[2].plan[1].pos.y, nil, "all candidate volumes are queried before final emerges")
eq(calls.volume[3].plan[1].pos.y, 64, "final volume uses known ground Y")
eq(calls.volume[4].plan[1].pos.y, 64, "all final volumes follow the candidate pass")
eq(calls.writes, 0, "search never calls terrain.terraform")
eq(result.plan, before.plan, "urban plan identity is unchanged")
eq(result.marker, before.marker, "urban result fields are unchanged")
eq(result.outskirts, before.outskirts, "search does not attach outskirts itself")
C.FARM_COUNT, C.ATTEMPTS_PER_BUILDING = 1, 2

local missing_chapel = {}
for id, entry in pairs(urban_catalog.entries) do if id ~= "chapel" then missing_chapel[id] = entry end end
local medieval_plan = {town_type = "medieval", seed = 8, center = plan.center, bounds = plan.bounds}
local medieval_result = {plan = medieval_plan, center = plan.center, ground_y = 64}
local missing_done, missing_kind = 0
local missing_terrain, missing_env = world()
outskirts.search(medieval_result, {assets = missing_chapel, terrain = missing_terrain}, function(a, b, c)
	missing_done, missing_kind = missing_done + 1, c
end, missing_env)
eq(missing_done, 1, "missing shared asset completes once")
eq(missing_kind, "outskirts_dependency", "missing shared chapel is a dependency failure")

local conflicting_done, conflicting_kind = 0
local conflicting_terrain, conflicting_env = world()
outskirts.search(result, {assets = {farm = {class = "urban"}}, terrain = conflicting_terrain}, function(a, b, c)
	conflicting_done, conflicting_kind = conflicting_done + 1, c
end, conflicting_env)
eq(conflicting_done, 1, "asset collision completes once")
eq(conflicting_kind, "outskirts_error", "asset collision is reported as a programming error")

local bad_volume_done, bad_volume_kind = 0
local bad_volume, bad_volume_env = world()
bad_volume.volume = function() return {} end
outskirts.search(result, {assets = urban_catalog.entries, terrain = bad_volume}, function(a, b, c)
	bad_volume_done, bad_volume_kind = bad_volume_done + 1, c
end, bad_volume_env)
eq(bad_volume_done, 1, "malformed volume completes once")
eq(bad_volume_kind, "outskirts_error", "malformed volume is reported as an internal error")

local old_budget_count, old_budget_attempts = C.FARM_COUNT, C.ATTEMPTS_PER_BUILDING
C.FARM_COUNT, C.ATTEMPTS_PER_BUILDING = 10, 1
local schedule_error_done, schedule_error_kind = 0
local schedule_terrain, schedule_env = world()
schedule_env.after = function(seconds, fn)
	if seconds == 0 then error("cannot schedule deferred pump") end
	fn()
end
outskirts.search(result, {assets = urban_catalog.entries, terrain = schedule_terrain}, function(a, b, c)
	schedule_error_done, schedule_error_kind = schedule_error_done + 1, c
end, schedule_env)
eq(schedule_error_done, 1, "deferred-pump scheduling error completes once")
eq(schedule_error_kind, "outskirts_error", "deferred-pump scheduling error is contained")
C.FARM_COUNT, C.ATTEMPTS_PER_BUILDING = old_budget_count, old_budget_attempts

terrain, env, calls = world(66)
completed, out, message, kind = 0
outskirts.search(result, {assets = urban_catalog.entries, terrain = terrain}, function(a, b, c)
	completed, out, message, kind = completed + 1, a, b, c
end, env)
eq(completed, 1, "water omissions still complete once")
eq(out.status, "empty", "unsuitable terrain yields an empty result")
eq(out.counts.rejected.plot_water, 2, "exposed liquid rejects each bounded attempt")
eq(#calls.volume, 2, "rejected candidates have no final volume query")
eq(calls.writes, 0, "water check remains read only")

-- A failed final emerge rejects the pending candidate instead of accepting a
-- plot whose mapblocks may unload before the build.
local final_calls, callback_count = 0, 0
local sync_terrain, final_env = world()
sync_terrain.volume = function(got_plan, schematic, options)
	final_calls = final_calls + 1
	if got_plan[1].pos.y then
		return {minp = {x = 0, y = 0, z = 0}, maxp = {x = 1, y = 1, z = 1}}
	end
	return {minp = {x = 0, y = 0, z = 0}, maxp = {x = 1, y = 1, z = 1}}
end
local emerge_number = 0
final_env.emerge = function(_, _, cb)
	emerge_number = emerge_number + 1
	cb(emerge_number == 1)
end
outskirts.search(result, {assets = urban_catalog.entries, terrain = sync_terrain}, function(a, b, c)
	callback_count, out, message, kind = callback_count + 1, a, b, c
end, final_env)
eq(callback_count, 1, "final emerge failure completes once")
eq(out.status, "empty", "final emerge failure rejects the plot")
eq(out.counts.rejected.emerge_failed, 1, "final emerge failure is recorded")
eq(#out.plots, 0, "failed final volume is not retained")

-- Late success after the watchdog cannot complete or advance the search again.
local callbacks, timers, late_count = {}, {}, 0
local async_terrain, async_env, async_calls = world()
async_env.emerge = function(_, _, cb) callbacks[#callbacks + 1] = cb end
async_env.after = function(_, fn) timers[#timers + 1] = fn end
outskirts.search(result, {assets = urban_catalog.entries, terrain = async_terrain}, function(a, b, c)
	late_count, out, message, kind = late_count + 1, a, b, c
end, async_env)
eq(#callbacks, 1, "async emerge waits for its callback")
timers[1]() -- timeout first emerge; this also starts the bounded retry
eq(#callbacks, 2, "timeout advances to the next attempt")
callbacks[1](true) -- stale completion is ignored
eq(late_count, 0, "late callback cannot finish while retry waits")
callbacks[2](true)
eq(#callbacks, 3, "successful inspection schedules the final volume emerge")
callbacks[3](true)
eq(late_count, 1, "async callbacks finish once")
eq(out.plots[1].ground_y, 64, "async path accepts the inspected surface")
callbacks[2](false)
eq(late_count, 1, "duplicate completion is ignored")
eq(async_calls.writes, 0, "async path never writes terrain")

local timeout_callbacks, timeout_timers, timeout_done = {}, {}, 0
local timeout_terrain, timeout_env = world()
local previous_attempt_limit = C.ATTEMPTS_PER_BUILDING
C.ATTEMPTS_PER_BUILDING = 6
timeout_env.emerge = function(_, _, cb) timeout_callbacks[#timeout_callbacks + 1] = cb end
timeout_env.after = function(_, fn) timeout_timers[#timeout_timers + 1] = fn end
outskirts.search(result, {assets = urban_catalog.entries, terrain = timeout_terrain}, function(a, b, c)
	timeout_done, out, message, kind = timeout_done + 1, a, b, c
end, timeout_env)
timeout_timers[1]()
timeout_timers[2]()
timeout_timers[3]()
eq(timeout_done, 1, "three consecutive timeouts finish once")
eq(out, nil, "three consecutive timeouts return no outskirts result")
eq(kind, "outskirts_dependency", "three consecutive timeouts identify a dependency failure")
timeout_callbacks[1](true)
eq(timeout_done, 1, "late success after dependency failure is ignored")
C.ATTEMPTS_PER_BUILDING = previous_attempt_limit

C.FARM_COUNT, C.HUT_COUNT, C.VILLA_COUNT, C.CHAPEL_COUNT = saved.farm, saved.hut, saved.villa, saved.chapel
C.ATTEMPTS_PER_BUILDING = saved.attempts
