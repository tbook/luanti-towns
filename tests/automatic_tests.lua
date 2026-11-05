local eq = ...
local real_dofile = dofile
local registered, pending, reports, events, jobs = nil, {}, {}, {}, {}
local states, lock = {}, nil
local site = {id = "one", center = {x = 0, z = 0}, cell = {x = 0, z = 0}, seed = 12,
	town_type = "roman", max_rect = {x1 = -10, z1 = -10, x2 = 10, z2 = 10},
	activation_rect = {x1 = -20, z1 = -20, x2 = 20, z2 = 20}}
local session = {}
function session:state(id) return states[id] end
function session:on_generated(event)
	events[#events + 1] = event
	if event.heights[0] and event.heights[0][0] then
		if states[site.id] then return {} end
		states[site.id] = "inspecting"
		return {{kind = "activate", site = site}}
	end
	return {}
end
function session:decline(id) states[id] = "declined" end
function session:finish(id) states[id] = "complete" end
local modules = {
	["src/auto_bounds.lua"] = {PLAN_EXTENT = {}, CHUNK_ORIGIN = -32, CHUNKSIZE = 80, CAPS = {}},
	["src/auto_sites.lua"] = {new = function() return {lookup = function() return {site} end} end},
	["src/auto_state.lua"] = {new = function() return session end,
		classify = function(h, min, max) return h and h > min and h < max and "valid" or "sentinel" end},
	["src/auto_loader.lua"] = {new = function(opts) return {start = function(_, s, trigger, done)
		jobs[#jobs + 1] = {site = s, trigger = trigger, done = done, opts = opts}; return true
	end} end},
}
local core = {
	settings = {get = function() return "survey" end}, get_mapgen_setting = function(k)
		return ({mg_name = "flat", chunksize = "5", seed = "42"})[k] end,
	get_connected_players = function() return {} end, get_us_time = function() return 1000000 end,
	log = function(_, s) reports[#reports + 1] = s end, write_json = function(t) reports[#reports + 1] = t; return "result" end,
	register_on_generated = function(fn) registered = fn end,
	get_mapgen_object = function() return {5} end,
	after = function(_, fn) pending[#pending + 1] = fn end,
}
local suppressed
local guard = {check = function() return true end, bind = function(_, _, _, _, cb) suppressed = cb; return true end}
local towns = {modpath = ".", auto_environment = {}, auto_village_guard = guard,
	auto_records = {is_enabled = function() return true end, lookup = function() end},
	catalog = {entries = {}}, site_search = {WET_DEFAULTS = {}, core_env = function() return {emerge = function() end} end},
	generation_lock = {acquire = function() if lock then return nil end; lock = {}; return lock end,
		release = function(token) if lock == token then lock = nil end end}}
local env = setmetatable({dofile = function(path) return modules[path:gsub("^%./", "")] or real_dofile(path) end}, {__index = _G})
local chunk = assert(loadfile("src/automatic.lua")); setfenv(chunk, env)
chunk()(towns, core, {mg_overworld_min = -100, mg_overworld_max = 100, mg_end_max = -2000})
eq(type(registered), "function", "survey registers callback")
registered({x = 0, y = 0, z = 0}, {x = 0, y = 10, z = 0})
eq(events[1].heights[0][0], 5, "callback copies valid height")
eq(states.one, "inspecting", "site reserved immediately")
eq(#jobs, 0, "loading deferred out of generated callback")
pending[1]()
eq(#jobs, 1, "loader starts after callback")
jobs[1].done(nil, "failure", "test_failure")
eq(states.one, "declined", "failure releases reservation")
eq(lock, nil, "failure releases ownership")
jobs[1].done(nil, "late", "late")
eq(reports[#reports - 1].reason, "test_failure", "duplicate completion is ignored")
states.one = nil
lock = {}
registered({x = 0, y = 0, z = 0}, {x = 0, y = 10, z = 0})
eq(states.one, "declined", "busy command declines site")
eq(reports[#reports - 1].reason, "busy", "busy result is reported")
eq(#pending, 1, "busy site does not schedule loading")
lock, states.one = nil, nil
registered({x = 0, y = 0, z = 0}, {x = 0, y = 10, z = 0})
pending[2]()
suppressed("accepted")
suppressed("inspecting")
local first = site
site = {id = "two", center = {x = 50, z = 0}, cell = {x = 1, z = 0}, seed = 13,
	town_type = "roman", max_rect = {x1 = 40, z1 = -10, x2 = 60, z2 = 10},
	activation_rect = {x1 = -20, z1 = -20, x2 = 60, z2 = 20}}
registered({x = 0, y = 0, z = 0}, {x = 0, y = 10, z = 0})
eq(states.two, "declined", "nested activation is declined while survey is active")
eq(#events, 4, "nested callback is still recorded")
eq(#jobs, 2, "nested callback does not start another loader")
site = first
jobs[2].done({})
eq(states.one, "complete", "successful survey releases reservation")
eq(lock, nil, "successful survey releases ownership")
eq(reports[#reports - 1].outcome, "surveyed", "successful survey is reported")
eq(reports[#reports - 1].suppressed_villages, 1, "survey counts its own suppressed village")
registered = nil
core.settings.get = function() return "off" end
chunk()(towns, core, {})
eq(registered, nil, "off mode does not register generation")
