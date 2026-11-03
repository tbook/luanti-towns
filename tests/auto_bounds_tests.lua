-- Automatic town envelopes (issue #393): src/auto_bounds.lua. Loaded by tests/run.lua:
--   loadfile("tests/auto_bounds_tests.lua")(eq, fails, planner, catalog)
-- Pure tests use fake volume providers with hand-computed reaches, plus the real
-- planner for medieval (walled and unwalled) and Roman plans. The optional Living
-- Villages check runs only with TOWNS_LIVING_VILLAGES set to an LV checkout.
local eq, fails, planner, catalog = ...
local ab = dofile("src/auto_bounds.lua")
local walls = dofile("src/medieval_walls.lua")
local features = dofile("src/medieval_wall_features.lua")
local roads = dofile("src/town_roads.lua")
local rural = dofile("schematics/outskirts/catalog.lua")

local SLACK = ab.SLACK
local S = SLACK

-- VoxeLibre settlements.schematic_table (mcl_villages/const.lua) and the Living
-- Villages planner config (living_villages/site_planner.lua M.config, 668c5fc).
local VILLAGE = {
	{name = "belltower", hwidth = 5, hdepth = 5, hheight = 9},
	{name = "large_house", hwidth = 12, hdepth = 12, hheight = 9},
	{name = "blacksmith", hwidth = 8, hdepth = 11, hheight = 13},
	{name = "butcher", hwidth = 12, hdepth = 8, hheight = 10},
	{name = "church", hwidth = 13, hdepth = 13, hheight = 14},
	{name = "farm", hwidth = 9, hdepth = 7, hheight = 13},
	{name = "lamp", hwidth = 3, hdepth = 4, hheight = 13},
	{name = "library", hwidth = 12, hdepth = 12, hheight = 8},
	{name = "medium_house", hwidth = 9, hdepth = 12, hheight = 8},
	{name = "small_house", hwidth = 9, hdepth = 8, hheight = 8},
	{name = "tavern", hwidth = 12, hdepth = 10, hheight = 10},
	{name = "well", hwidth = 6, hdepth = 8, hheight = 6},
}
local LV_VILLAGE = {cell = 16, max_cells = 5, relocate_step = 8, relocate_rings = 4, radius_jitter = 2}

local function outskirts_assets()
	local list = {}
	for _, id in ipairs({"farm", "shepherd_hut", "villa"}) do
		list[#list + 1] = {id = id, size = rural[id].size}
	end
	list[#list + 1] = {id = "chapel", size = catalog.entries.chapel.size}
	return list
end

local function wall_feature_assets()
	local list = {}
	for id, e in pairs(catalog.entries) do
		if id:match("^wall_") and e.size then list[#list + 1] = {id = id, size = e.size} end
	end
	table.sort(list, function(a, b) return a.id < b.id end)
	return list
end

-- Fake terrain volume: the footprint grown by Rx, Ry, Rz; rotation swaps the footprint.
local function fake_terrain(Rx, Ry, Rz)
	return function(plan, schematics)
		local e, s = plan[1], schematics[1]
		local w, d = s.hwidth, s.hdepth
		if e.rotat == "90" or e.rotat == "270" then w, d = d, w end
		return {minp = {x = e.pos.x - Rx, y = -Ry, z = e.pos.z - Rz},
			maxp = {x = e.pos.x + w - 1 + Rx, y = Ry, z = e.pos.z + d - 1 + Rz}}
	end
end

-- Fake boundary volume: the rectangles grown by 48 horizontally (radius 20 plus tree margin 28).
local function fake_boundary(rects)
	local minx, minz, maxx, maxz = math.huge, math.huge, -math.huge, -math.huge
	for _, r in ipairs(rects) do
		minx, minz = math.min(minx, r.x0), math.min(minz, r.z0)
		maxx, maxz = math.max(maxx, r.x1), math.max(maxz, r.z1)
	end
	return {minp = {x = minx - 48, y = -68, z = minz - 48}, maxp = {x = maxx + 48, y = 68, z = maxz + 48}}
end

local function providers(opts)
	opts = opts or {}
	local config = ab.default_config()
	config.village = LV_VILLAGE
	return {
		config = opts.config or config,
		assets = opts.assets or {outskirts = outskirts_assets(), village = VILLAGE, wall_features = wall_feature_assets()},
		volume = opts.volume or {terrain = fake_terrain(10, 60, 10), boundary = fake_boundary},
	}
end

-- Chunk alignment: chunk minp = -32 + 80k, including negative coordinates.
eq(ab.chunk_index(-32), 0, "chunk of -32 is 0")
eq(ab.chunk_index(-33), -1, "chunk of -33 is -1 (no zero alignment)")
eq(ab.chunk_index(-112), -1, "chunk of -112 is -1")
eq(ab.chunk_index(-113), -2, "chunk of -113 is -2")
eq(ab.chunk_index(47), 0, "chunk of 47 is 0")
eq(ab.chunk_index(48), 1, "chunk of 48 is 1")
eq(ab.chunk_index(0), 0, "chunk of 0 is 0")
local one = {min = {x = 0, y = 0, z = 0}, max = {x = 10, y = 10, z = 10}}
eq(ab.aligned_voxels(one), 80 * 80 * 80, "a box inside one chunk aligns to one chunk")
local straddle = {min = {x = -33, y = 0, z = 0}, max = {x = -32, y = 0, z = 0}}
eq(ab.aligned_voxels(straddle), 2 * 80 * 80 * 80, "a box across x = -32 spans two chunks")
local acc = ab.chunk_accounting({one, one, straddle})
eq(acc.chunks, 2, "duplicate boxes are counted once (distinct chunks)")
eq(acc.voxels, 2 * ab.CHUNK_VOXELS, "voxels follow distinct chunks")
eq(acc.per_box[1], 1, "per-box count for one chunk")
eq(acc.per_box[3], 2, "per-box count for a straddling box")

-- Containment helpers.
eq(ab.contains_box(one, {min = {x = 1, y = 1, z = 1}, max = {x = 9, y = 9, z = 9}}), true, "inner box contained")
eq(ab.contains_box(one, {min = {x = -1, y = 1, z = 1}, max = {x = 9, y = 9, z = 9}}), false, "box escaping on -x rejected")
eq(ab.contains_rect({x1 = -5, z1 = -5, x2 = 5, z2 = 5}, {x1 = -5, z1 = 0, x2 = 5, z2 = 5}), true, "rect on the edge is inside")
eq(ab.contains_rect({x1 = -5, z1 = -5, x2 = 5, z2 = 5}, {x1 = -6, z1 = 0, x2 = 5, z2 = 5}), false, "rect past the edge is outside")

-- Cell fit: 1024 nodes minus one mapchunk (80) on each edge leaves 864.
local fit = ab.fit(1024, {x1 = -432, z1 = -432, x2 = 431, z2 = 431}, 80)
eq(fit.fits, true, "864-wide rect fits the 1024 cell with one chunk of clearance")
eq(fit.usable, 864, "usable width is cell minus two chunks")
eq(fit.jitter, 0, "exact fit has no centre jitter")
fit = ab.fit(1024, {x1 = -433, z1 = -432, x2 = 431, z2 = 431}, 80)
eq(fit.fits, false, "865-wide rect does not fit")
eq(fit.excess, 1, "excess is the width over the usable span")
fit = ab.fit(1024, {x1 = -100, z1 = -100, x2 = 100, z2 = 100}, 80)
eq(fit.jitter, 331, "centre jitter is half the slack (864 - 201 = 663, floored to 331)")

-- Default config: constants read from their owning modules.
local cfg = ab.default_config()
eq(cfg.cut_fill_margin, 8, "cut/fill margin")
eq(cfg.outer_band_far, 58, "outskirts outer band")
eq(cfg.ramp_max, roads.RAMP_MAX, "ramp length comes from town_roads")
eq(cfg.wall_clearance, walls.CLEARANCE, "wall clearance comes from medieval_walls")
eq(cfg.foundation_depth, features.FOUNDATION_DEPTH, "foundation depth comes from medieval_wall_features")
eq(cfg.city_margin.radius, 20, "city margin radius")
eq(cfg.wet_ring, 0, "wet ring is off by default")

-- Missing or malformed providers decline with a reason, and never a partial environment.
local env, why = ab.new(nil)
eq(env, nil, "nil providers decline")
eq(type(why), "string", "decline carries a reason")
local p = providers()
p.config = nil
eq(ab.new(p), nil, "missing config declines")
p = providers()
p.config.village = nil
eq(ab.new(p), nil, "missing Living Villages values decline")
p = providers()
p.assets.outskirts = {}
eq(ab.new(p), nil, "empty outskirts assets decline")
p = providers()
p.assets.village = nil
eq(ab.new(p), nil, "missing village assets decline")
p = providers()
p.assets.wall_features = nil
eq(ab.new(p), nil, "missing wall feature assets decline")
p = providers()
p.volume.terrain = nil
eq(ab.new(p), nil, "missing terrain volume declines")
p = providers()
p.volume.boundary = nil
eq(ab.new(p), nil, "missing boundary volume declines")
p = providers()
p.volume.terrain = function() return nil, "unloaded" end
local failed_env, failed_why = ab.new(p)
eq(failed_env, nil, "a failing terrain query declines the environment")
eq(failed_why:find("unloaded", 1, true) ~= nil, true, "the query reason is reported")

-- Derived reaches with the fake volumes (hand-computed).
env = assert(ab.new(providers()))
eq(env.stage_reach.urban_build, 8, "urban build reach is the cut/fill margin")
eq(env.stage_reach.city_margins, 48 + S, "city margins reach is radius+tree margin plus slack")
eq(env.stage_reach.walls, 6, "walls reach is the wall line plus clearance")
eq(env.stage_reach.wall_approaches, 22, "wall approaches: wall line + 6 + ramp 15")
eq(env.stage_reach.outside_roads, 16, "outside roads: wall line + ramp 15")
eq(env.stage_reach.wall_features, 1 + 16 + 2 + 15, "features: wall line + largest feature + door + ramp")
eq(env.outskirts_reach.x_neg, 10 + S, "outskirts terrain reach on -x")
eq(env.outskirts_reach.y_max, 60 + S, "outskirts terrain reach upward")
eq(env.outskirts_reach.y_min, -60 - S, "outskirts terrain reach downward")
eq(env.stage_reach.outskirts, 58 + 10 + S, "outskirts reach is the band plus terrain reach")
eq(env.max_rect.x1, -132 - (58 + 10 + S), "max rect extends the planner extent by the largest stage reach")
eq(env.max_rect.x2, 132 + (58 + 10 + S), "max rect east side")
eq(env.village_reach, 33 + 83 + (13 - 1 + 10 + S), "village reach: relocation + ring + largest footprint and terrain")
eq(env.activation_rect.x1, env.max_rect.x1 - env.village_reach, "activation halo pads the max rect on -x")
eq(env.activation_rect.z2, env.max_rect.z2 + env.village_reach, "activation halo pads the max rect on +z")
eq(env.fit.width, env.activation_rect.x2 - env.activation_rect.x1 + 1, "fit uses the activation rect")

-- Rotated assets: each rotation uses the swapped footprint, so the reach is the same
-- for a rotation-consistent volume, and a non-square volume reports both axes.
local asym = providers({volume = {terrain = fake_terrain(5, 20, 30), boundary = fake_boundary}})
local aenv = assert(ab.new(asym))
eq(aenv.outskirts_reach.x_pos, 5 + S, "rotated outskirts: +x reach follows the footprint in every rotation")
eq(aenv.outskirts_reach.z_pos, 30 + S, "rotated outskirts: +z reach follows the footprint in every rotation")
eq(aenv.outskirts_reach.y_max, 20 + S, "vertical reach")

-- Plan envelopes from the real planner: medieval walled, medieval unwalled, Roman.
local profile = assert(planner.landmark_profile(catalog.snapshot()))
local function state_for(plan, wall, wf)
	local ground = 64
	return {plan = plan, center = plan.center, ground_y = ground, reference_y = ground, wall = wall,
		wall_features = wf,
		build_bounds = {min = {x = plan.bounds.x1, y = ground - 24, z = plan.bounds.z1},
			max = {x = plan.bounds.x2, y = ground + 40, z = plan.bounds.z2}}}
end
-- Multi-box stages are named stage[1], stage[2], ...
local function has_stage(e, prefix)
	for name in pairs(e.stages) do
		if name == prefix or name:sub(1, #prefix + 1) == prefix .. "[" then return true end
	end
	return false
end

local function check_envelope(label, e)
	eq(e ~= nil, true, label .. " envelope is produced")
	if not e then return end
	for name, s in pairs(e.stages) do
		eq(ab.contains_box(e.read, s.box), true, label .. " " .. name .. " is inside the read envelope")
		if s.kind == "write" then
			eq(ab.contains_box(e.write, s.box), true, label .. " " .. name .. " is inside the write envelope")
		end
	end
	eq(e.stages.urban_build ~= nil and e.stages.urban_read ~= nil, true, label .. " has urban stages")
	eq(ab.contains_box(e.read, e.stages.urban_read.box), true, label .. " urban read is covered")
	eq(e.chunks >= 1, true, label .. " counts chunks")
	eq(e.snapshot_voxels, e.chunks * ab.CHUNK_VOXELS, label .. " snapshot voxels follow distinct chunks")
end

for _, seed in ipairs({20260101, 7, -123456}) do
	local m = planner.plan({x = 0, z = 0}, seed, {landmarks = profile})
	m.center = {x = 0, z = 0}
	local wall = walls.plan(m, true)
	local wf = {}
	if wall then
		local cands = features.candidates(wall, 64, catalog.entries, walls, function() end)
		wf = features.select(cands, {}, m.streets, function() return false end) or {}
	end
	check_envelope("medieval walled " .. seed, select(1, env.plan_envelope(state_for(m, wall, wf))))
	local u = planner.plan({x = 0, z = 0}, seed + 1, {landmarks = profile})
	u.center = {x = 0, z = 0}
	check_envelope("medieval unwalled " .. seed, select(1, env.plan_envelope(state_for(u, nil, nil))))
	local r = planner.plan({x = 0, z = 0}, seed, {town_type = "roman"})
	r.center = {x = 0, z = 0}
	local re = select(1, env.plan_envelope(state_for(r, nil, nil)))
	check_envelope("roman " .. seed, re)
	if re then
		eq(has_stage(re, "outside_roads"), true, "roman has outside road stages")
		eq(re.stages.walls == nil, true, "roman has no wall stage")
	end
end

-- Walled medieval: the wall stages exist and the outside-road stage does not.
do
	local m = planner.plan({x = 0, z = 0}, 20260101, {landmarks = profile})
	m.center = {x = 0, z = 0}
	local wall = assert(walls.plan(m, true), "walled fixture")
	local e = env.plan_envelope(state_for(m, wall, {}))
	eq(e ~= nil and e.stages.walls ~= nil, true, "walled town has a wall stage")
	eq(e ~= nil and has_stage(e, "outside_roads") == false, true, "walled town grades roads at its openings instead")
	eq(e ~= nil and has_stage(e, "wall_approaches"), true, "walled town has gate approaches")
end

-- Negative coordinates: a site far in the -x/-z quadrant keeps aligned boxes.
do
	local centre = {x = -4000, z = -3000}
	local m = planner.plan(centre, 20260101, {landmarks = profile})
	local e = env.plan_envelope(state_for(m, nil, nil))
	eq(e ~= nil, true, "negative-coordinate site is accepted")
	if e then
		eq(e.stages.urban_read.box.min.x < 0 and e.stages.urban_read.box.min.z < 0, true,
			"negative site has negative boxes")
		eq(ab.contains_box(e.read, e.stages.urban_read.box), true, "negative read box is contained")
	end
end

-- Declines before any allocation: state, extent, build bounds and caps.
do
	local m = planner.plan({x = 0, z = 0}, 20260101, {landmarks = profile})
	m.center = {x = 0, z = 0}
	local st = state_for(m, nil, nil)
	local bad = {}
	for k, v in pairs(st) do bad[k] = v end
	bad.ground_y = 64.5
	local e, _, code = env.plan_envelope(bad)
	eq(e, nil, "non-integer ground declines")
	eq(code, "invalid_state", "non-integer ground is an invalid state")
	bad = {}
	for k, v in pairs(st) do bad[k] = v end
	bad.build_bounds = {min = {x = 0, y = 0, z = 0}, max = {x = 1, y = 1, z = 1}}
	e, _, code = env.plan_envelope(bad)
	eq(code, "invalid_state", "build bounds must match plan X/Z")
	bad = {}
	for k, v in pairs(st) do bad[k] = v end
	bad.plan = {bounds = {x1 = -300, z1 = 0, x2 = 0, z2 = 10}, center = {x = 0, z = 0}, streets = {}}
	bad.build_bounds = {min = {x = -300, y = 0, z = 0}, max = {x = 0, y = 1, z = 10}}
	e, _, code = env.plan_envelope(bad)
	eq(code, "plan_extent_exceeded", "a plan beyond the measured extent is declined")
	local saved_chunks = ab.CAPS.MAX_REQUEST_CHUNKS
	local saved_voxels = ab.CAPS.MAX_SNAPSHOT_VOXELS
	ab.CAPS.MAX_REQUEST_CHUNKS = 1
	ab.CAPS.MAX_SNAPSHOT_VOXELS = 1
	e, _, code = env.plan_envelope(st)
	ab.CAPS.MAX_REQUEST_CHUNKS = saved_chunks
	ab.CAPS.MAX_SNAPSHOT_VOXELS = saved_voxels
	eq(e, nil, "an envelope over the chunk cap is rejected before allocation")
	eq(code, "chunk_cap", "chunk cap reason")
	-- City margin failure declines the plan, never a partial envelope.
	local failing = providers({volume = {terrain = fake_terrain(10, 60, 10),
		boundary = function() return nil, "no ground" end}})
	local failing_env = ab.new(failing)
	eq(failing_env, nil, "a failing boundary query declines the environment (no fallback padding)")
end

-- Walled towns: missing wall parts decline; an empty feature list is accepted.
do
	local m = planner.plan({x = 0, z = 0}, 20260101, {landmarks = profile})
	m.center = {x = 0, z = 0}
	local wall = assert(walls.plan(m, true), "walled fixture")
	local e, _, code = env.plan_envelope(state_for(m, wall, nil))
	eq(e, nil, "walled town with nil wall_features declines")
	eq(code, "provider_failed", "nil wall_features is a provider failure")
	local no_openings = {}
	for k, v in pairs(wall) do no_openings[k] = v end
	no_openings.openings = nil
	e, _, code = env.plan_envelope(state_for(m, no_openings, {}))
	eq(e, nil, "walled town with nil wall.openings declines")
	eq(code, "provider_failed", "nil wall.openings is a provider failure")
	local no_cells = {}
	for k, v in pairs(wall) do no_cells[k] = v end
	no_cells.cells = nil
	e, _, code = env.plan_envelope(state_for(m, no_cells, {}))
	eq(code, "provider_failed", "nil wall.cells is a provider failure")
	e = env.plan_envelope(state_for(m, wall, {}))
	eq(e ~= nil, true, "walled town with an empty feature list is accepted")
end

-- Feature bounds are copied, not aliased: mutating the feature afterwards must not
-- change the envelope already returned (mutation test).
do
	local m = planner.plan({x = 0, z = 0}, 20260101, {landmarks = profile})
	m.center = {x = 0, z = 0}
	local wall = assert(walls.plan(m, true), "walled fixture for feature copy")
	local b = m.bounds
	local g = 64
	local feature = {min = {x = b.x2, y = g, z = b.z1}, max = {x = b.x2 + 2, y = g + 4, z = b.z1 + 2}}
	local e = env.plan_envelope(state_for(m, wall, {feature}))
	eq(e ~= nil, true, "walled town with a synthetic feature is accepted")
	if e then
		local found
		for name, s in pairs(e.stages) do
			if name:match("^wall_features") and s.box.min.y == g - 32 then found = s.box end
		end
		eq(found ~= nil, true, "feature foundation box is present")
		local before = found and found.max.x
		feature.max.x = 99999
		feature.max.y = 99999
		eq(found and found.max.x, before, "mutating feature.max after the call leaves the envelope unchanged")
		eq(found and found.max.y ~= 99999, true, "feature foundation max is not the mutated table")
	end
end

-- Optional real Living Villages volumes (TOWNS_LIVING_VILLAGES = checkout path).
local lv_path = os.getenv("TOWNS_LIVING_VILLAGES")
if not lv_path then
	print("SKIP auto_bounds Living Villages reach: TOWNS_LIVING_VILLAGES not set")
else
	local saved_minetest = rawget(_G, "minetest")
	minetest = {get_modpath = function() return lv_path end}
	local smoothing = dofile(lv_path .. "/village_smoothing.lua")
	local engine = {registered_nodes = {}}
	local lv = providers({volume = {
		terrain = function(p, s, o) return smoothing.volume(p, s, o, engine) end,
		boundary = function(r, g, o) return smoothing.boundary_volume(r, g, o) end,
	}})
	local lenv = assert(ab.new(lv))
	-- Measured with the installed Living Villages (668c5fc) and VoxeLibre schematic table, 2026-11-02.
	eq(lenv.village_reach, 178, "measured village reach (LV 668c5fc)")
	eq(lenv.max_rect.x2, 245, "measured max rect east edge (LV 668c5fc)")
	eq(lenv.fit.fits, true, "measured 1,024 cell fit (LV 668c5fc)")
	minetest = saved_minetest
end
