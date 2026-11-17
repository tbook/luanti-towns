-- Cell job in src/automatic.lua (#431 T5): pre-screen, ranked sequential inspections, sibling
-- cleanup, lock handling and the per-cell log line. Real auto_state session, fake loader and engine.
local eq = ...
local real_dofile = dofile

local function candidates(cx, prefix)
	local list = {}
	for k = 0, 8 do
		list[#list + 1] = {id = prefix .. k, candidate = k, cell = {x = cx, z = 0}, seed = 7, town_type = "roman",
			center = {x = 10 * k, z = 0},
			max_rect = {x1 = -32, z1 = -32, x2 = 127, z2 = 127},
			activation_rect = {x1 = -32, z1 = -32, x2 = 127, z2 = 127}}
	end
	return list
end

-- opts.scores: candidate index -> dry points out of 9 (nil: no spawn level function).
local function fixture(opts)
	opts = opts or {}
	local f = {jobs = {}, reports = {}, warnings = 0, acquires = 0, clock = 0, pending = {}, emits = {},
		current = candidates(0, "C"), players = {}, updates = {}, published = {}}
	local lock
	local core = {
		settings = {get = function() return opts.mode or "survey" end},
		get_mapgen_setting = function(k) return ({mg_name = "flat", chunksize = "5", seed = "42"})[k] end,
		get_connected_players = function() return f.players end,
		get_us_time = function() return f.clock * 1000000 end,
		log = function(level) if level == "warning" then f.warnings = f.warnings + 1 end end,
		write_json = function(t) f.reports[#f.reports + 1] = t; return "json" end,
		register_on_generated = function(fn) f.generated = fn end,
		get_mapgen_object = function() local h = {}; for i = 1, 6400 do h[i] = 10 end; return h end,
		after = function(_, fn) f.pending[#f.pending + 1] = fn end,
	}
	local towns = {modpath = ".", auto_environment = {},
		auto_village_guard = {check = function() return true end, bind = function() return true end},
		auto_records = {is_enabled = function() return true end, lookup = function() end,
			begin = function() f.begins = (f.begins or 0) + 1; return true end,
			update = function(_, cell, outcome, published)
				f.updates[#f.updates + 1] = outcome
				f.published[#f.updates] = published
				if opts.update_result ~= nil then return unpack(opts.update_result) end
				return true
			end},
		catalog = {entries = {}}, site_search = {WET_DEFAULTS = {}, core_env = function()
			return {emerge = function(minp, maxp, cb) f.emits[#f.emits + 1] = {minp = minp, maxp = maxp, cb = cb} end} end},
		auto_records_factory = {record_for_site = function(site) return {cell = site.cell} end},
		populated = {build = function(result, cb, context) f.build = {result = result, cb = cb, context = context} end},
		generation_lock = {owns = function(t) return t ~= nil and lock == t end,
			set_phase = function() return true end, acquire = function() f.acquires = f.acquires + 1; if lock then return nil end; lock = {}; return lock end,
			release = function(token) if lock == token then lock = nil end end}}
	f.locked = function() return lock ~= nil end
	f.hold = function() lock = {} end
	if opts.scores then
		local calls = {}
		towns.auto_spawn_level = function(x)
			local k = math.floor(x / 10 + 0.5)
			calls[k] = (calls[k] or 0) + 1
			if calls[k] <= opts.scores[k] then return 20 + calls[k] end
			return nil
		end
	elseif opts.spawn_level then towns.auto_spawn_level = opts.spawn_level end
	local modules = {
		["src/auto_bounds.lua"] = {PLAN_EXTENT = {x1 = -1, z1 = -1, x2 = 1, z2 = 1}, CHUNK_ORIGIN = -32,
			CHUNKSIZE = 80, CAPS = {}},
		["src/auto_sites.lua"] = {new = function(_, o) f.site_opts = o
			return {lookup = function() return f.current end} end},
		["src/auto_loader.lua"] = {new = function(o) return {start = function(_, site, _, done)
			f.jobs[#f.jobs + 1] = {site = site, done = done, env = o.env}; return true end} end},
	}
	local env = setmetatable({dofile = function(path) return modules[path:gsub("^%./", "")] or real_dofile(path) end},
		{__index = _G})
	local chunk = assert(loadfile("src/automatic.lua")); setfenv(chunk, env)
	chunk()(towns, core, {mg_overworld_min = -100, mg_overworld_max = 100, mg_end_max = -2000})
	f.session = towns.auto_session
	f.activate = function()
		f.generated({x = -32, y = -32, z = -32}, {x = 47, y = 47, z = 47})
		while #f.pending > 0 do table.remove(f.pending, 1)() end
	end
	f.last = function() return f.reports[#f.reports] end
	f.terminal = function(list)
		for _, d in ipairs(list or f.current) do
			local s = f.session:state(d.id)
			if s ~= "declined" and s ~= "complete" then return false end
		end
		return next(f.session.cells) == nil
	end
	f.fail = function(n, code, details)
		f.jobs[n].done(nil, "failed " .. code, code, details)
		while #f.pending > 0 do table.remove(f.pending, 1)() end
	end
	return f
end

local function order(f)
	local ids = {}
	for _, j in ipairs(f.jobs) do ids[#ids + 1] = j.site.candidate end
	return table.concat(ids, ",")
end

-- Nine candidates, 3 of 9 minimum, 2 inspections.
do
	local f = fixture({scores = {[0] = 3, 5, 5, 9, 2, 2, 8, 0, 4}})
	eq(f.site_opts.candidates, 9, "automatic towns use nine candidates")
	f.activate()
	eq(order(f), "3", "highest score is inspected first")
	f.fail(1, "no_ground", {rejections = {no_ground = 1}, center_heights = {min = 1}})
	eq(order(f), "3,6", "second try is the next ranked candidate")
	f.fail(2, "too_deep_water", {rejections = {too_deep_water = 2}})
	eq(order(f), "3,6", "MAX_INSPECTIONS bounds the tries")
	eq(f.terminal(), true, "give-up declines every sibling and drops the chunk set (N = 9)")
	eq(f.locked(), false, "lock released after give-up")
	eq(f.acquires, 1, "lock taken once for the whole cell")
	eq(#f.reports, 1, "one log line per cell")
	local r = f.last()
	eq(r.outcome, "declined", "cell outcome")
	eq(r.reason, "too_deep_water", "cell reason is the last attempt's")
	eq(r.tries, 2, "tries logged")
	eq(r.winner, nil, "no winner")
	eq(r.cell.x, 0, "cell logged")
	eq(r.trigger.self_triggered, false, "trigger context logged")
	eq(r.trigger.minp.x, -32, "trigger minp logged")
	eq(type(r.activation), "table", "activation logged")
	eq(#r.candidates, 9, "all candidates logged")
	local by = {}
	for _, c in ipairs(r.candidates) do by[c.index] = c end
	eq(by[3].score, 9, "score logged")
	eq(by[3].min_level, 21, "min level logged")
	eq(by[3].max_level, 29, "max level logged")
	eq(by[3].reason, "no_ground", "first candidate reason")
	eq(by[3].inspection_rejections.no_ground, 1, "per-candidate rejections kept")
	eq(by[3].center_heights.min, 1, "per-candidate center heights kept")
	eq(by[6].inspection_rejections.too_deep_water, 2, "second candidate rejections kept")
	eq(by[1].reason, "inspections_exhausted", "ranked but untried candidate")
	eq(by[4].reason, "prescreen_wet", "below PRESCREEN_MIN is skipped")
	eq(by[0].outcome, "declined", "candidate with exactly PRESCREEN_MIN is not prescreened out")
	eq(by[0].reason, "inspections_exhausted", "PRESCREEN_MIN boundary passes")
	eq(r.inspection_rejections.too_deep_water, 2, "last attempt rejections stay on the line")
end

-- Ties break by seeded order.
do
	local f = fixture({scores = {[0] = 4, 6, 6, 6, 4, 4, 4, 4, 4}})
	f.activate()
	f.fail(1, "x")
	eq(order(f), "1,2", "tied scores follow the candidate index")
end

-- Nothing qualifies: decline the cell without loading anything.
do
	local f = fixture({scores = {[0] = 2, 2, 2, 2, 2, 2, 2, 1, 0}})
	f.activate()
	eq(#f.jobs, 0, "no candidate loads")
	eq(f.acquires, 0, "no lock taken")
	eq(f.terminal(), true, "cell terminal")
	eq(f.last().reason, "prescreen_wet", "whole cell declined as prescreen_wet")
	eq(#f.reports, 1, "one line")
end

-- Missing or failing spawn level API: no pre-screen, every candidate passes, warned once.
do
	local f = fixture()
	f.activate()
	eq(order(f), "0", "no API: seeded order")
	eq(f.warnings, 1, "missing API logged once")
	f.fail(1, "x"); f.fail(2, "x")
	eq(f.last().candidates[1].score, nil, "no score without pre-screen")
	local g = fixture({spawn_level = function() error("boom") end})
	g.activate()
	eq(order(g), "0", "erroring API: all pass")
	eq(g.warnings, 1, "erroring API logged once")
end

-- The first success completes the cell.
do
	local f = fixture({scores = {[0] = 9, 9, 9, 9, 9, 9, 9, 9, 9}})
	f.activate()
	f.jobs[1].done({})
	eq(order(f), "0", "success stops further tries")
	eq(f.session:state("C0"), "complete", "winner complete")
	eq(f.terminal(), true, "siblings declined")
	eq(f.last().winner, 0, "winner logged")
	eq(f.last().outcome, "surveyed", "survey outcome")
	eq(f.last().candidates[1].outcome, "surveyed", "winner outcome per candidate")
	eq(f.locked(), false, "lock released on success")
end

-- Expiry mid-cell: begin refuses, the cell gives up.
do
	local f = fixture({scores = {[0] = 9, 8, 7, 6, 5, 4, 3, 9, 9}})
	f.activate()
	f.clock = 61
	f.fail(1, "no_ground")
	eq(#f.jobs, 1, "no second try after the 60 s limit")
	eq(f.terminal(), true, "expired cell terminal")
	eq(f.locked(), false, "lock released on expiry")
	eq(f.last().reason, "cell_expired", "cell reason is the expiry")
	eq(f.last().candidates[1].reason, "no_ground", "failed attempt keeps its own reason")
	eq(f.last().candidates[3].reason, "cell_expired", "untried candidates record the expiry")
end

-- A village declines the next candidate mid-cell: the cell continues with the one after.
do
	local f = fixture({scores = {[0] = 9, 8, 7, 6, 5, 4, 3, 9, 9}})
	f.activate()
	-- ranking: 0 and 7 and 8 have 9 points, so 0,7,8 then 1.
	f.session:decline("C7")
	f.fail(1, "no_ground")
	eq(order(f), "0,8", "declined candidate is skipped without using an inspection")
	f.fail(2, "no_ground")
	eq(f.terminal(), true, "cell terminal")
	eq(f.last().tries, 2, "two tries")
	local by = {}
	for _, c in ipairs(f.last().candidates) do by[c.index] = c end
	eq(by[7].reason, "village_declined", "village decline logged")
end

-- begin refusing right after activation ends the cell.
do
	local f = fixture({scores = {[0] = 9, 9, 9, 9, 9, 9, 9, 9, 9}})
	f.session.begin = function() return nil, "no", "sibling_inspecting" end
	f.activate()
	eq(#f.jobs, 0, "no job when begin refuses")
	eq(f.terminal(), true, "cell terminal after refused begin")
	eq(f.locked(), false, "lock released after refused begin")
end

-- Early settles (player clearance) end the cell instead of trying siblings.
do
	local f = fixture({scores = {[0] = 9, 9, 9, 9, 9, 9, 9, 9, 9}})
	f.players = {{get_pos = function() return {x = 0, y = 0, z = 0} end}}
	f.activate()
	eq(#f.jobs, 0, "player nearby loads nothing")
	eq(f.terminal(), true, "cell terminal after clearance failure")
	eq(f.locked(), false, "lock released after clearance failure")
	eq(f.last().reason, "player_clearance", "clearance reason")
	eq(f.last().tries, 1, "one begin was used")
end

-- A failure that is not an inspection failure does not retry (no handoff here: lock busy).
do
	local f = fixture({scores = {[0] = 9, 9, 9, 9, 9, 9, 9, 9, 9}})
	f.hold()
	f.activate()
	eq(#f.jobs, 0, "busy lock loads nothing")
	eq(f.terminal(), true, "cell terminal when the lock is busy")
	eq(f.last().reason, "busy", "busy reason")
end

-- Busy declines every live candidate of another cell while a job runs.
do
	local f = fixture({scores = {[0] = 9, 9, 9, 9, 9, 9, 9, 9, 9}})
	f.activate()
	local other = candidates(1, "D")
	f.current = other
	f.generated({x = 48, y = -32, z = -32}, {x = 127, y = 47, z = 47})
	for _, d in ipairs(other) do eq(f.session:state(d.id), "declined", "busy declines " .. d.id) end
	eq(next(f.session.cells) ~= nil, true, "running cell stays active")
	eq(f.last().reason, "busy", "busy logged")
	f.fail(1, "x"); f.fail(2, "x")
	eq(f.locked(), false, "lock released at the end")
end

-- Straggler: a chunk requested by a failed attempt still counts as the cell's own while a later
-- attempt runs, so it cannot activate a neighbouring cell (which would be busy-declined for good).
do
	local f = fixture({scores = {[0] = 9, 9, 9, 9, 9, 9, 9, 9, 9}})
	f.activate()
	local far = candidates(1, "D")
	for _, d in ipairs(far) do d.activation_rect = {x1 = 130, z1 = -32, x2 = 400, z2 = 127} end
	local both = {}
	for _, d in ipairs(f.current) do both[#both + 1] = d end
	for _, d in ipairs(far) do both[#both + 1] = d end
	f.current = both
	local minp, maxp = {x = 128, y = -32, z = -32}, {x = 207, y = 47, z = 47}
	f.jobs[1].env.emerge(minp, maxp, function() end)
	f.fail(1, "no_ground")
	eq(#f.jobs, 2, "second attempt is running")
	f.generated(minp, maxp)
	eq(f.session:state("D0"), "contacted", "straggler of an earlier attempt does not activate the neighbour")
	f.fail(2, "no_ground")
	eq(f.locked(), false, "lock released")
end

-- Non-survey mode: accepted records, completion, interruption.
local function build_ready(f, n)
	f.jobs[n].done({envelope = {stages = {}},
		write_envelope = {min = {x = 0, y = 0, z = 0}, max = {x = 1, y = 1, z = 1}},
		read_envelope = {min = {x = 0, y = 0, z = 0}, max = {x = 1, y = 1, z = 1}}})
end
do
	local f = fixture({mode = "on", scores = {[0] = 9, 9, 9, 9, 9, 9, 9, 9, 9}})
	f.activate()
	build_ready(f, 1)
	eq(f.build.context.before_write(), true, "write gate accepts the record")
	eq(f.begins, 1, "record begun once")
	eq(f.build.context.before_write(), false, "a second accept in the same job is refused")
	f.build.cb({town = {complete = true, residents = {failures = {}, interrupted_beds = {}}}})
	eq(f.updates[1], "complete", "accepted then complete updates the record")
	eq(f.published[1], nil, "no published data when the build summary has none")
	eq(f.session:state("C0"), "complete", "winner complete")
	eq(f.terminal(), true, "siblings declined by finish")
	eq(f.session:begin("C1", 0), nil, "no second candidate can begin in the finished cell")
	eq(f.locked(), false, "lock released")
	eq(f.last().outcome, "complete", "complete logged")
	eq(f.last().winner, 0, "winner logged")
end
do
	local f = fixture({mode = "on", scores = {[0] = 9, 9, 9, 9, 9, 9, 9, 9, 9}})
	f.activate()
	build_ready(f, 1)
	f.build.context.before_write()
	f.build.cb(nil, "build broke", "build_failed")
	eq(f.updates[1], "interrupted", "accepted then interrupted updates the record")
	eq(#f.jobs, 1, "no retry after acceptance")
	eq(f.terminal(), true, "cell terminal after interruption")
	eq(f.locked(), false, "lock released")
	eq(f.last().outcome, "interrupted", "interrupted logged")
end
do
	local f = fixture({mode = "on", scores = {[0] = 9, 9, 9, 9, 9, 9, 9, 9, 9}})
	f.activate()
	build_ready(f, 1)
	f.build.cb(nil, "refused", "build_failed")
	eq(#f.jobs, 1, "a build failure before acceptance does not retry")
	eq(#f.updates, 0, "no record update without acceptance")
	eq(f.terminal(), true, "cell terminal")
end

-- Published exits ride along with the complete update (#458).
do
	local f = fixture({mode = "on", scores = {[0] = 9, 9, 9, 9, 9, 9, 9, 9, 9}})
	f.activate()
	build_ready(f, 1)
	f.build.context.before_write()
	local published = {format = 1}
	f.build.cb({published = published, town = {complete = true, residents = {failures = {}, interrupted_beds = {}}}})
	eq(f.updates[1], "complete", "complete update")
	eq(f.published[1], published, "published data passed to the record update")
	eq(f.last().outcome, "complete", "town complete")
end
-- A population failure interrupts the record and never publishes, even if the summary has exits.
do
	local f = fixture({mode = "on", scores = {[0] = 9, 9, 9, 9, 9, 9, 9, 9, 9}})
	f.activate()
	build_ready(f, 1)
	f.build.context.before_write()
	f.build.cb({published = {format = 1}, town = {complete = true,
		residents = {failures = {{}}, interrupted_beds = {}}}})
	eq(f.updates[1], "interrupted", "population_failed interrupts the record")
	eq(f.published[1], nil, "interrupted record gets no published data")
	eq(f.last().outcome, "interrupted", "interrupted logged")
end
-- A failed update leaves the cell interrupted in the log and publishes nothing.
do
	local f = fixture({mode = "on", scores = {[0] = 9, 9, 9, 9, 9, 9, 9, 9, 9}, update_result = {false, "disk full", "store_failed"}})
	f.activate()
	build_ready(f, 1)
	f.build.context.before_write()
	f.build.cb({published = {format = 1}, town = {complete = true, residents = {failures = {}, interrupted_beds = {}}}})
	eq(#f.updates, 1, "a store failure is not retried")
	eq(f.last().outcome, "interrupted", "update failure reports interrupted")
end
-- Rejected published data: complete without it rather than leaving the town building.
do
	local f = fixture({mode = "on", scores = {[0] = 9, 9, 9, 9, 9, 9, 9, 9, 9}, update_result = {false, "bad", "invalid_published"}})
	f.activate()
	build_ready(f, 1)
	f.build.context.before_write()
	f.build.cb({published = {format = 1}, town = {complete = true, residents = {failures = {}, interrupted_beds = {}}}})
	eq(#f.updates, 2, "invalid published data is retried once without it")
	eq(f.published[2], nil, "retry carries no published data")
end
