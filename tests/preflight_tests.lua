-- Preflight and build-volume tests (ticket #44). Loaded by tests/run.lua:
--   loadfile("tests/preflight_tests.lua")(eq, fails, planner, catalog, geometry, site_search)
local eq, fails, planner, catalog, geometry, site_search = ...
local preflight = dofile("src/preflight.lua")

local function copy(t)
	if type(t) ~= "table" then return t end
	local o = {}
	for k, v in pairs(t) do o[k] = copy(v) end
	return o
end

-- Strict recording env: only reads and emerge exist, any other access (a
-- write) raises. `spec` hooks: missing = {[path]=true}, wrong_size = {[path]=size},
-- nodes = {[data path] = {names}}, unknown = {[node]=true}, emerge_ok,
-- hang (emerge never calls back until fired).
local function new_env(entries, spec)
	spec = spec or {}
	local w = {emerges = {}, timers = {}, reads = 0}
	local by_path = {}
	for id, e in pairs(entries) do
		by_path[e.path] = e
		if e.data_path then by_path[e.data_path] = e end
	end
	local env = {}
	env.read_schematic = function(path)
		w.reads = w.reads + 1
		if spec.missing and spec.missing[path] then return nil end
		local e = by_path[path]
		if not e then return nil end
		local s = spec.wrong_size and spec.wrong_size[path] or e.size
		return {size = {x = s.x, y = s.y, z = s.z}}
	end
	env.read_data = function(path)
		if spec.missing and spec.missing[path] then return nil end
		return {required_nodes = spec.nodes and spec.nodes[path] or {"default:stone"}}
	end
	env.node_registered = function(name)
		return not (spec.unknown and spec.unknown[name])
	end
	env.emerge = function(minp, maxp, cb)
		w.emerges[#w.emerges + 1] = {min = minp, max = maxp}
		if spec.emerge_raises then error("engine exploded") end
		if spec.hang then w.cbs = w.cbs or {}; w.cbs[#w.cbs + 1] = cb; return end
		cb(not (spec.emerge_ok == false))
	end
	env.after = function(seconds, fn) w.timers[#w.timers + 1] = {seconds = seconds, fn = fn} end
	setmetatable(env, {
		__index = function(_, k) error("preflight touched env." .. tostring(k)) end,
		__newindex = function(_, k) error("preflight set env." .. tostring(k)) end,
	})
	w.env = env
	return w
end

local function run(params, w)
	local calls, report, msg, code, extra = 0
	preflight.run(params, w.env, function(r, m, c, e)
		calls = calls + 1
		report, msg, code, extra = r, m, c, e
	end)
	return report, msg, code, extra, calls
end

local function ent(path, x, y, z, go)
	return {path = path, data_path = path .. ".lua", size = {x = x, y = y, z = z},
		entrance = {x = 1, y = 1, z = 0}, ground_offset = go}
end

------------------------------------------------------------------------
-- Hand-made fixture: a rotated and a very tall building
------------------------------------------------------------------------
local function fixture()
	local entries = {
		tall = ent("s/tall.mts", 10, 70, 4, 2),
		low = ent("s/low.mts", 6, 5, 6),
	}
	local plan = {
		sites = {},
		bounds = {x1 = 0, z1 = 0, x2 = 59, z2 = 59},
		content = {buildings = {
			-- rotation 90 swaps X/Z: a 10x4 file is a 4 (x) by 10 (z) box.
			{building_id = "tall", role = "house", rotation = 90,
				rect = {x1 = 10, z1 = 10, x2 = 13, z2 = 19}},
			{building_id = "low", role = "house", rotation = 0,
				rect = {x1 = 30, z1 = 10, x2 = 35, z2 = 15}},
		}},
	}
	local bb = {min = {x = 0, y = 18, z = 0}, max = {x = 59, y = 87, z = 59}}
	local vol = {min = {x = -8, y = 10, z = -8}, max = {x = 67, y = 87, z = 67}}
	return entries, plan, {plan = plan, entries = entries, ground_y = 20,
		build_bounds = bb, build_volume = vol, player = {x = 200, y = 21, z = 200}}
end

do
	local entries, plan, params = fixture()
	local comp = assert(preflight.compose(plan, entries, 20))
	eq(#comp.structures, 2, "compose: two structures")
	local t = comp.structures[1]
	eq(t.id, "tall", "compose: order")
	eq(t.size.x, 4, "rotated footprint x")
	eq(t.size.z, 10, "rotated footprint z")
	eq(t.min.y, 18, "foundation at ground - ground_offset")
	eq(t.max.y, 87, "true schematic height beyond the old 40-node limit")
	eq(t.max.x, 13, "rotated max x")
	eq(t.max.z, 19, "rotated max z")
	eq(comp.min_y, 18, "compose min_y")
	eq(comp.max_y, 87, "compose max_y")

	local w = new_env(entries)
	local report, msg, code, _, calls = run(params, w)
	eq(calls, 1, "ok: done once")
	eq(report ~= nil, true, "ok: report " .. tostring(msg))
	eq(#w.emerges, 1, "ok: one emerge of the complete volume")
	eq(w.emerges[1].min.x, -8, "ok: emerged min x")
	eq(w.emerges[1].max.y, 87, "ok: emerged max y covers the tall building")
	eq(report.files, 2, "ok: files checked")
	eq(report.nodes[1], "default:stone", "ok: node list")
	local cov = true
	for _, st in ipairs(report.structures) do
		if st.min.y < w.emerges[1].min.y or st.max.y > w.emerges[1].max.y
				or st.min.x < w.emerges[1].min.x or st.max.x > w.emerges[1].max.x
				or st.min.z < w.emerges[1].min.z or st.max.z > w.emerges[1].max.z then
			cov = false
		end
	end
	eq(cov, true, "ok: every box inside the emerged volume")

	-- Rotated rect that is the unrotated footprint is geometry failure.
	local p2 = copy(plan)
	p2.content.buildings[1].rect = {x1 = 10, z1 = 10, x2 = 19, z2 = 13}
	local c2, why = preflight.compose(p2, entries, 20)
	eq(c2, nil, "unrotated rect rejected")
	eq(why:find("rotated", 1, true) ~= nil, true, "rotated rect reason")
	w = new_env(entries)
	local pr = copy(params)
	pr.plan = p2
	report, msg, code, extra = run(pr, w)
	eq(report, nil, "geometry: no report")
	eq(code, "inspection_failed", "geometry: code")
	eq(extra.reason, "geometry", "geometry: reason")
	eq(#w.emerges, 0, "geometry: nothing emerged")

	-- Structure above the reported bounds.
	pr = copy(params)
	pr.build_bounds.max.y = 60
	pr.build_volume.max.y = 60
	w = new_env(entries)
	report, msg, code, extra = run(pr, w)
	eq(report, nil, "bounds: rejected")
	eq(extra.reason, "out_of_bounds", "bounds: reason")
	eq(#w.emerges, 0, "bounds: nothing emerged")

	-- Placement outside the plan bounds.
	pr = copy(params)
	pr.plan.content.buildings[2].rect = {x1 = 58, z1 = 10, x2 = 63, z2 = 15}
	w = new_env(entries)
	report, msg, code, extra = run(pr, w)
	eq(report, nil, "outside plan: rejected")
	eq(extra.reason, "out_of_bounds", "outside plan: reason")

	-- Missing catalog entry.
	pr = copy(params)
	pr.plan.content.buildings[2].building_id = "ghost"
	w = new_env(entries)
	report, msg, code, extra = run(pr, w)
	eq(extra.reason, "missing_entry", "missing entry: reason")

	-- Overlap.
	pr = copy(params)
	pr.plan.content.buildings[2].rect = {x1 = 12, z1 = 12, x2 = 17, z2 = 17}
	w = new_env(entries)
	report, msg, code, extra = run(pr, w)
	eq(extra.reason, "geometry", "overlap: reason")

	-- Missing file.
	w = new_env(entries, {missing = {["s/low.mts"] = true}})
	report, msg, code, extra = run(params, w)
	eq(report, nil, "missing file: rejected")
	eq(extra.reason, "missing_file", "missing file: reason")
	eq(msg:find("Nothing was changed", 1, true) ~= nil, true, "missing file: nothing changed")
	eq(#w.emerges, 0, "missing file: nothing emerged")

	-- Missing data file.
	w = new_env(entries, {missing = {["s/low.mts.lua"] = true}})
	report, msg, code, extra = run(params, w)
	eq(extra.reason, "missing_file", "missing data: reason")

	-- Dimension mismatch.
	w = new_env(entries, {wrong_size = {["s/tall.mts"] = {x = 10, y = 60, z = 4}}})
	report, msg, code, extra = run(params, w)
	eq(extra.reason, "size_mismatch", "size mismatch: reason")
	eq(#w.emerges, 0, "size mismatch: nothing emerged")

	-- Unregistered node.
	w = new_env(entries, {nodes = {["s/low.mts.lua"] = {"default:stone", "mod:gone"}},
		unknown = {["mod:gone"] = true}})
	report, msg, code, extra = run(params, w)
	eq(extra.reason, "missing_node", "missing node: reason")
	eq(msg:find("mod:gone", 1, true) ~= nil, true, "missing node: named")
	eq(#w.emerges, 0, "missing node: nothing emerged")

	-- Failed emerge.
	w = new_env(entries, {emerge_ok = false})
	report, msg, code, extra = run(params, w)
	eq(report, nil, "emerge failed: no report")
	eq(code, "inspection_failed", "emerge failed: code")
	eq(extra.reason, "emerge_failed", "emerge failed: reason")

	-- Emerge that never answers: the watchdog fails it.
	w = new_env(entries, {hang = true})
	local calls2 = 0
	local rep2, _, c2b, e2
	preflight.run(params, w.env, function(r, m, c, e) calls2 = calls2 + 1; rep2, c2b, e2 = r, c, e end)
	eq(calls2, 0, "timeout: pending")
	w.timers[1].fn()
	eq(calls2, 1, "timeout: done once")
	eq(e2.reason, "emerge_timeout", "timeout: reason")
	w.timers[1].fn()
	eq(calls2, 1, "timeout: late settle ignored")
	w.cbs[1](true)
	eq(calls2, 1, "timeout: late emerge callback ignored")
	eq(rep2, nil, "timeout: no report from late callback")

	-- Emerge raising.
	w = new_env(entries, {emerge_raises = true})
	report, msg, code, extra, calls = run(params, w)
	eq(calls, 1, "emerge raises: done once")
	eq(report, nil, "emerge raises: no report")
	eq(extra.reason, "emerge_failed", "emerge raises: reason")

	-- Right size, wrong for rotation 270 (and right for it when swapped).
	local p3 = copy(plan)
	p3.content.buildings[1].rotation = 270
	p3.content.buildings[1].rect = {x1 = 10, z1 = 10, x2 = 19, z2 = 13}
	local c3, why3, code3 = preflight.compose(p3, entries, 20)
	eq(c3, nil, "270: unswapped rect rejected")
	eq(code3, "geometry", "270: reason code from compose")
	p3.content.buildings[1].rect = {x1 = 10, z1 = 10, x2 = 13, z2 = 19}
	eq(preflight.compose(p3, entries, 20) ~= nil, true, "270: swapped rect accepted")
	local _, _, code4 = preflight.compose({sites = {}, bounds = plan.bounds,
		content = {buildings = {{building_id = "x", role = "house", rotation = 0,
			rect = {x1 = 0, z1 = 0, x2 = 1, z2 = 1}}}}}, entries, 20)
	eq(code4, "missing_entry", "compose reports missing_entry code")

	-- Player inside the footprint (or its margin).
	pr = copy(params)
	pr.player = {x = 30.4, y = 21, z = 30.2}
	w = new_env(entries)
	report, msg, code, extra = run(pr, w)
	eq(extra.reason, "player_inside", "player inside: reason")
	pr.player = {x = -3, y = 21, z = 30}
	report, msg, code, extra = run(pr, new_env(entries))
	eq(extra.reason, "player_inside", "player in margin: reason")
	pr.player = {x = -4, y = 21, z = 30}
	report, msg, code, extra = run(pr, new_env(entries))
	eq(extra.reason, "player_inside", "player exactly at margin: reason")
	pr.player = {x = 63, y = 21, z = 30}
	report, msg, code, extra = run(pr, new_env(entries))
	eq(extra.reason, "player_inside", "player at far margin: reason")
	pr.player = {x = -5, y = 21, z = 30}
	report = run(pr, new_env(entries))
	eq(report ~= nil, true, "player at margin+1 accepted")
	pr.player = {x = 64, y = 21, z = 30}
	report = run(pr, new_env(entries))
	eq(report ~= nil, true, "player at far margin+1 accepted")

	-- Beyond the world limit.
	pr = copy(params)
	pr.build_volume.max.y = 31001
	report, msg, code, extra = run(pr, new_env(entries))
	eq(extra.reason, "out_of_bounds", "world limit: reason")
end

------------------------------------------------------------------------
-- Real catalog plan: composition and site_search bounds
------------------------------------------------------------------------
local snapshot = catalog.snapshot()
local profile = assert(planner.landmark_profile(snapshot))
local SEED = 1

local function flat_env(top)
	top = top or 20
	local env = {emerges = 0}
	local names = {["default:stone"] = {walkable = true}}
	env.node_info = function(name) return names[name] end
	env.get_node_name = function(_, y) return y <= top and "default:stone" or "air" end
	env.after = function() end
	env.emerge = function(_, _, cb) env.emerges = env.emerges + 1; cb(true) end
	return env
end

local ss = site_search(dofile("src/placement.lua"), planner)
local function search(planner_opts, top, radius, search_ss)
	local result, summary
	top = top or 20
	;(search_ss or ss).search({x = 0.4, y = top + 1, z = 0.4}, SEED, {planner_opts = planner_opts,
		max_radius = radius or 160},
		function(r, s) result, summary = r, s end, flat_env(top))
	return result, summary
end

do
	-- The one real-generation case: a populated medieval plan through the
	-- search, composed and preflighted. (The limit and failure cases below
	-- use a small authored plan.)
	local r, why = search({landmarks = profile})
	eq(r ~= nil, true, "structure bounds: result " .. tostring(why))
	local comp = assert(preflight.compose(r.plan, catalog.entries, r.ground_y))
	eq(#comp.structures > 2, true, "real plan: landmarks plus content composed")
	eq(#r.structures, #comp.structures, "result.structures matches compose")
	local tallest = 0
	for _, st in ipairs(comp.structures) do
		if st.max.y > tallest then tallest = st.max.y end
		eq(st.min.y, r.ground_y - st.ground_offset, "foundation at ground " .. st.id)
		local e = catalog.entries[st.id]
		local g = geometry.place(e, {x = st.rect.x1, y = r.ground_y - (e.ground_offset or 0),
			z = st.rect.z1}, st.rotation)
		eq(g.max.x, st.max.x, "box max x " .. st.id)
		eq(g.max.y, st.max.y, "box max y " .. st.id)
		eq(g.max.z, st.max.z, "box max z " .. st.id)
	end
	eq(r.build_bounds.max.y, math.max(r.max_height, tallest), "top is the tallest structure")
	local expect_top = 0
	for _, st in ipairs(comp.structures) do
		local e = catalog.entries[st.id]
		expect_top = math.max(expect_top, e.size.y - (e.ground_offset or 0))
	end
	eq(r.build_bounds.max.y, r.ground_y + expect_top - 1, "exact top of tallest structure")
	eq(r.build_bounds.min.y <= r.ground_y - 5, true, "bounds include the castle foundation")
	eq(r.build_volume.max.y, r.build_bounds.max.y, "volume covers the top")

	-- Preflight accepts the real site and emerges the build volume.
	local w = new_env(catalog.entries)
	local report, msg = run({plan = r.plan, entries = catalog.entries, ground_y = r.ground_y,
		build_bounds = r.build_bounds, build_volume = r.build_volume,
		player = {x = 0.4, y = 21, z = 0.4}}, w)
	eq(report ~= nil, true, "real site preflight: " .. tostring(msg))
	eq(#w.emerges, 1, "real site: one emerge")
	eq(w.emerges[1].max.y, r.build_volume.max.y, "real site: emerges the whole volume")
end

-- Small authored plan (tests/authored_plan_fixture.lua) for the bounds and
-- failure cases: no medieval generation, explicit catalog entries.
local make_authored_plan = dofile("tests/authored_plan_fixture.lua")
local small_planner = setmetatable({
	plan = function(center, seed) return make_authored_plan(center, seed) end,
}, {__index = planner})
local small_ss = site_search(dofile("src/placement.lua"), small_planner)
local house = catalog.get("demo_house")
local function small_entries(height)
	return {demo_house = {size = {x = house.size.x, y = height or house.size.y, z = house.size.z},
		entrance = house.entrance, ground_offset = 5}}
end
local function search_small(entries, top, radius)
	local result, summary
	top = top or 20
	small_ss.search({x = 0.4, y = top + 1, z = 0.4}, SEED, {entries = entries,
		max_radius = radius or 48},
		function(r, s) result, summary = r, s end, flat_env(top))
	return result, summary
end

-- A taller landmark than the old 40-node limit raises the bounds.
do
	local r, why = search_small(small_entries(120))
	eq(r ~= nil, true, "tall structure: result " .. tostring(why))
	eq(r and r.build_bounds.max.y, r and r.ground_y - 5 + 120 - 1,
		"tall structure: top is the real height above its foundation")
end

-- Option errors and site_search failure paths.
fails(function() search(nil) end, "opts.entries or opts.planner_opts.landmarks is required",
	"no profile and no entries")

do
	-- An entry missing for a composed structure ends the search clearly.
	local r, why = search_small({})
	eq(r, nil, "invalid content: no result")
	eq(tostring(why):find("Town content is invalid", 1, true) ~= nil, true,
		"invalid content: message " .. tostring(why))
	eq(tostring(why):find("Nothing was changed", 1, true) ~= nil, true, "invalid content: nothing changed")
end

do
	local r, why = search_small(small_entries(31500), 20, 40)
	eq(r, nil, "top beyond the limit: no result")
	eq(tostring(why):find("out_of_range", 1, true) ~= nil, true,
		"top beyond the limit: out_of_range " .. tostring(why))
	-- Bottom: the cut/fill margin below the foundation passes -31000.
	r, why = search_small(small_entries(), -30990, 40)
	eq(r, nil, "bottom beyond the limit: no result")
	eq(tostring(why):find("out_of_range", 1, true) ~= nil, true,
		"bottom beyond the limit: out_of_range " .. tostring(why))
	-- Exactly at the limit is accepted: the surface at -30987 leaves the
	-- cut/fill margin inside -31000.
	r, why = search_small(small_entries(), -30987, 40)
	eq(r ~= nil, true, "bottom exactly at the limit accepted " .. tostring(why))
end
