-- Real persistent registry and lock around the automatic construction controller.
local eq = ...
local real_dofile = dofile
local records = real_dofile("src/auto_records.lua")
local lock_factory = real_dofile("src/generation_lock.lua")
local box = {min = {x = -1, y = 0, z = -1}, max = {x = 1, y = 10, z = 1}}
local function copy(value)
 if type(value) ~= "table" then return value end
 local out = {}; for k, v in pairs(value) do out[k] = copy(v) end; return out
end
local site = {id = "one", version = 1, seed = 10, town_type = "roman", cell = {x = 0, z = 0},
 center = {x = 0, z = 0}, max_rect = {x1 = -10, z1 = -10, x2 = 10, z2 = 10},
 activation_rect = {x1 = -10, z1 = -10, x2 = 10, z2 = 10}}
local function fixture(case, kind)
 local f = {writes = 0, reports = {}, timers = {}, saved = nil, begin_count = 0, build_count = 0}
 local saved_objects, serial = {}, 0
 local registry = records.new({store = {get = function() return f.saved end, set = function(_, v)
   if case == "storage" then return false end; f.saved = v end},
  serialize = function(v) serial = serial + 1; saved_objects[tostring(serial)] = v; return tostring(serial) end,
  deserialize = function(v) return copy(saved_objects[v]) end})
 f.reload = function() return records.new({store = {get = function() return f.saved end,
  set = function(_, v) f.saved = v end}, serialize = function(v) serial = serial + 1; saved_objects[tostring(serial)] = v; return tostring(serial) end,
  deserialize = function(v) return copy(saved_objects[v]) end}) end
 local state, covered = nil, true
 local session = {state = function() return state end, covers = function() return covered end,
  finish = function() state = "complete" end, decline = function() state = "declined" end,
  on_generated = function() if state then return {} end; state = "inspecting"; return {{site = site}} end}
 local result = {center = site.center, ground_y = 5, plan = {}, read_envelope = box, write_envelope = box,
  envelope = {stages = {urban = {kind = "write", box = box}}}}
 local generated, pending, gate, callback
 local player = false
 local core = {settings = {get = function() return "on" end}, get_mapgen_setting = function(k)
   return ({mg_name = "flat", chunksize = "5", seed = "42"})[k] end,
  get_connected_players = function() return player and {{get_pos = function() return {x = 17, z = 0} end}} or {} end,
  is_protected = function(p)
   if case == "protection_error" then error("provider failed") end
   return case == "protected" and p.x == 0 and p.y == 5 and p.z == 0
  end,
  get_us_time = function() return 0 end, log = function() end,
  write_json = function(v) f.reports[#f.reports + 1] = v; return "report" end,
  register_on_generated = function(fn) generated = fn end, get_mapgen_object = function() return {5} end,
  after = function(_, fn) f.timers[#f.timers + 1] = fn end}
 local mods = { ["src/auto_bounds.lua"] = {PLAN_EXTENT = {}, CHUNK_ORIGIN = -32, CHUNKSIZE = 80, CAPS = {}},
  ["src/auto_sites.lua"] = {new = function() return {lookup = function() return {site} end} end},
  ["src/auto_state.lua"] = {new = function() return session end, classify = function() return "valid" end},
  ["src/auto_loader.lua"] = {new = function() return {start = function(_, _, _, cb) pending = cb; return true end} end}}
 local towns = {modpath = ".", auto_environment = {}, auto_records = registry, auto_records_factory = records,
  auto_village_guard = {check = function() return true end, bind = function() return true end},
  generation_lock = lock_factory(), catalog = {entries = {}, snapshot = function() return {} end},
  planner = {landmark_profile = function() return {} end},
  site_search = {WET_DEFAULTS = {}, core_env = function() return {emerge = function(_, _, cb) cb(true) end} end},
  populated = {build = function(_, done, context)
   f.build_count = f.build_count + 1; gate, callback = context.before_write, done
   if case == "throw" then error("build failed") end
   if case == "late_clearance" then player = true end
   if case == "late_freshness" then covered = false end
   local ok = gate(); if not ok then return done(nil, "gate denied", "before_write_denied") end
   f.begin_count = f.begin_count + 1; f.writes = f.writes + 1
   if case == "crash" then return end
   local failures = case == "population" and {{reason = "failure"}} or {}
   done({town = {complete = case ~= "incomplete", residents = {failures = failures, interrupted_beds = {}}}, write_bounds = box})
  end}}
 site.town_type = kind or "roman"
 local env = setmetatable({dofile = function(path) return mods[path:gsub("^%./", "")] or real_dofile(path) end}, {__index = _G})
 local chunk = assert(loadfile("src/automatic.lua")); setfenv(chunk, env)
 chunk()(towns, core, {mg_overworld_min = -100, mg_overworld_max = 100, mg_end_max = -2000})
 generated({x = 0, y = 0, z = 0}, {x = 0, y = 10, z = 0}); table.remove(f.timers, 1)()
 if case == "old" then covered = false end
 if case == "clearance" then player = true end
 pending(result); f.pending = pending; f.result = result; f.callback = function(...) if callback then callback(...) end end
 f.state = function() return state end; f.lock = towns.generation_lock; f.registry = registry
 return f
end
for _, kind in ipairs({"roman", "medieval"}) do
 local f = fixture("success", kind)
 eq(f.writes, 1, kind .. " writes after gate"); eq(f.registry:lookup(site.cell).state, "complete", kind .. " completes")
 eq(f.lock.current(), nil, kind .. " releases lock")
 f.pending(nil, "late"); f.callback(nil, "late")
 eq(#f.reports, 1, kind .. " ignores duplicate callbacks")
end
for _, case in ipairs({"storage", "throw", "old", "clearance", "late_clearance", "late_freshness"}) do
 local f = fixture(case)
 eq(f.writes, 0, case .. " prevents writes"); eq(f.registry:lookup(site.cell), nil, case .. " has no accepted record")
 eq(f.lock.current(), nil, case .. " releases lock")
end
for _, case in ipairs({"protected", "protection_error"}) do
 local f = fixture(case)
 eq(f.writes, 1, case .. " does not block automatic construction")
 eq(f.registry:lookup(site.cell).state, "complete", case .. " completes")
end
local f = fixture("population")
eq(f.registry:lookup(site.cell).state, "interrupted", "population failure retains interrupted reservation")
eq(f.lock.current(), nil, "population failure releases lock")
local incomplete = fixture("incomplete")
eq(incomplete.registry:lookup(site.cell).state, "interrupted", "incomplete urban construction retains interrupted reservation")
local crash = fixture("crash")
eq(crash.registry:lookup(site.cell).state, "building", "record persisted before first write")
crash.pending(nil, "duplicate while building")
crash.pending(crash.result)
eq(crash.build_count, 1, "duplicate loader callback cannot start or settle a pending build")
eq(crash.lock.current() ~= nil, true, "duplicate loader callback retains the build lock")
eq(crash.registry:lookup(site.cell).state, "building", "duplicate callback keeps the building record")
eq(#crash.reports, 0, "duplicate callback does not report an unfinished build")
local reloaded = crash.reload()
eq(reloaded:lookup(site.cell).state, "interrupted", "restart marks unfinished build interrupted")
local state_mod = real_dofile("src/auto_state.lua")
local resumed = assert(state_mod.new({lookup = function() return {site} end,
	footprint = {x1 = 0, z1 = 0, x2 = 0, z2 = 0},
	adapter = {origin = -32, size = 80, accepts = function() return true end},
	accepted = function(d) return reloaded:lookup(d.cell) ~= nil end}))
local actions = assert(resumed:on_generated({minp = {x = -32, y = -32, z = -32},
	maxp = {x = 47, y = 47, z = 47}, heights = {[0] = {[0] = 5}}}))
eq(#actions, 0, "reloaded interrupted reservation does not start a second build")
eq(resumed:state(site.id), "accepted", "reloaded reservation remains protected")
crash.callback({town = {complete = true, residents = {failures = {}, interrupted_beds = {}}}, write_bounds = box})
eq(crash.registry:lookup(site.cell).state, "complete", "actual completion finishes the pending build")
eq(crash.lock.current(), nil, "actual completion releases the lock")
crash.pending(nil, "late")
crash.callback(nil, "late")
eq(#crash.reports, 1, "late callbacks cannot settle a completed build twice")
