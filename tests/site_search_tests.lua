-- Site search tests (ticket #14), a small mocked Luanti world. Loaded by
-- tests/run.lua, which passes its check helpers:
--   loadfile("tests/site_search_tests.lua")(eq, fails, placement, planner, factory)
--
-- Search behaviour is tested against a small authored plan (the notched
-- variant of tests/authored_plan_fixture.lua) standing in for the planner, so
-- no medieval town is generated per search; the real planner is only asked to
-- fail (an unknown catalog id) and for the one populated-catalog integration case.
local eq, fails, placement, planner, factory = ...
local medieval_profile = assert(planner.landmark_profile(dofile("src/catalog.lua").snapshot()))
local make_authored_plan = dofile("tests/authored_plan_fixture.lua")
local small_planner = setmetatable({
	plan = function(center, seed, popts)
		if type(popts) == "table" and popts.landmarks ~= nil then
			return planner.plan(center, seed, popts)
		end
		return make_authored_plan(center, seed, {notched = true})
	end,
}, {__index = planner})
local ss_raw = factory(placement, small_planner)
local ss_real = factory(placement, planner)
local catalog = dofile("src/catalog.lua")

-- Search always composes the plan's buildings, which needs catalog entries:
-- these tests give the authored plan's catalog ids unless a test says otherwise.
local ss = setmetatable({
	search = function(player_pos, seed, opts, done, env)
		if opts == nil then
			opts = {entries = catalog.entries}
		elseif type(opts) == "table" and opts.entries == nil then
			local o = {entries = catalog.entries}
			for k, v in pairs(opts) do o[k] = v end
			opts = o
		end
		return ss_raw.search(player_pos, seed, opts, done, env)
	end,
}, {__index = ss_raw})

local SEED = 20260101

------------------------------------------------------------------------
-- Pure helpers
------------------------------------------------------------------------
local offs = ss.candidate_offsets(16, 320)
eq(offs[1].dx, 0, "offsets first dx")
eq(offs[1].dz, 0, "offsets first dz")
-- Distance 16 ties are ordered by dz then dx.
eq(offs[2].dx .. "," .. offs[2].dz, "0,-16", "offsets 2nd")
eq(offs[3].dx .. "," .. offs[3].dz, "-16,0", "offsets 3rd")
eq(offs[4].dx .. "," .. offs[4].dz, "16,0", "offsets 4th")
eq(offs[5].dx .. "," .. offs[5].dz, "0,16", "offsets 5th")
local sorted, within, mult = true, true, true
for i, o in ipairs(offs) do
	if i > 1 and o.d2 < offs[i - 1].d2 then sorted = false end
	if o.d2 > 320 * 320 then within = false end
	if o.dx % 16 ~= 0 or o.dz % 16 ~= 0 then mult = false end
end

eq(sorted, true, "offsets nearest first")
eq(within, true, "offsets within radius")
eq(mult, true, "offsets multiples of step")
eq(#offs, 1257, "offsets count (lattice points in radius 320)")
local offs2 = ss.candidate_offsets(16, 320)
eq(#offs2, #offs, "offsets deterministic count")
local same = true
for i, o in ipairs(offs) do
	if offs2[i].dx ~= o.dx or offs2[i].dz ~= o.dz then same = false end
end
eq(same, true, "offsets deterministic order")
eq(offs[#offs].d2 <= 320 * 320, true, "offsets last within radius")

eq(ss.median({5}), 5, "median single")
eq(ss.median({9, 1, 5}), 5, "median odd")
eq(ss.median({4, 1, 3, 2}), 2, "median even takes the lower middle")
eq(ss.median({20, 20, 22, 22}), 20, "median even tie lower")
eq(ss.median({}), nil, "median empty")

local b = {x1 = 10, z1 = 20, x2 = 30, z2 = 40}
eq(ss.player_inside(b, 20, 30, 4), true, "player inside")
eq(ss.player_inside(b, 8, 30, 4), true, "player inside margin")
eq(ss.player_inside(b, 5, 30, 4), false, "player outside margin")
eq(ss.player_inside(b, 34, 44, 4), true, "player inside corner margin")
eq(ss.player_inside(b, 35, 30, 4), false, "player outside east")

local cols = ss.boundary_columns({
	{x1 = 0, z1 = 0, x2 = 3, z2 = 1},
	{x1 = 2, z1 = 1, x2 = 4, z2 = 2},
})
eq(#cols, 8 + 6 - 2, "boundary columns are the union")
eq(cols[1].x .. "," .. cols[1].z, "0,0", "boundary columns first")
eq(cols[#cols].x .. "," .. cols[#cols].z, "4,2", "boundary columns last")

eq(ss.format_rejections({water = 3, too_uneven = 10, unknown = 3}),
	"too_uneven x10, unknown x3, water x3", "rejection format order")

-- inspect_columns: range limit is inclusive at 8.
local function reader(map)
	return function(x) return map[x], nil, 0 end
end
local columns = {{x = 1, z = 0}, {x = 2, z = 0}}
local info = ss.inspect_columns(columns, reader({[1] = 20, [2] = 28}), 100, 8)
eq(info ~= nil, true, "range 8 accepted")
local none, code = ss.inspect_columns(columns, reader({[1] = 20, [2] = 29}), 100, 8)
eq(none, nil, "range 9 rejected")
eq(code, "too_uneven", "range 9 code")
_, code = ss.inspect_columns(columns, reader({[1] = 20, [2] = 100}), 100, 8)
eq(code, "too_high", "surface at window top")

-- Small pits and piles may be trimmed, but their actual heights are retained.
local terrain_cols, terrain_heights = {}, {}
for i = 1, 100 do
	terrain_cols[i] = {x = i, z = 0}
	terrain_heights[i] = 20
end
local function inspect_terrain()
	return ss.inspect_columns(terrain_cols, reader(terrain_heights), 100, 16, 5, 24)
end
terrain_heights[1], terrain_heights[2] = -4, -4
terrain_heights[99], terrain_heights[100] = 44, 44
local terrain = inspect_terrain()
eq(terrain ~= nil, true, "outliers: small pits and piles accepted at cut/fill cap")
eq(terrain.ground_y, 20, "outliers: median unchanged")
eq(terrain.min_height, -4, "outliers: actual minimum retained")
eq(terrain.max_height, 44, "outliers: actual maximum retained")
eq(terrain.heights[1][0], -4, "outliers: pit height retained for filling")
terrain_heights[3] = -4
local rejected, reason = inspect_terrain()
eq(rejected, nil, "outliers: more than 2.5 percent in one tail rejected")
eq(reason, "too_uneven", "outliers: excessive tail reason")
terrain_heights[3], terrain_heights[1] = 20, -5
rejected, reason = inspect_terrain()
eq(rejected, nil, "outliers: pit beyond cut/fill cap rejected")
eq(reason, "too_uneven", "outliers: deep pit reason")
terrain_heights[1], terrain_heights[100] = -4, 45
eq(inspect_terrain(), nil, "outliers: pile beyond cut/fill cap rejected")

------------------------------------------------------------------------
-- Mock world
------------------------------------------------------------------------
-- spec = {
--   surface = function(x, z) -> y of topmost solid node (default 20)
--   water   = function(x, z) -> water level or nil (water fills above the
--             surface up to this y)
--   unloaded = function(x, z) -> true for "ignore" columns
--   emerge_ok = function(minpos, maxpos) -> bool (default true)
--   deferred = true to queue emerge callbacks until pump()
-- }
local function new_world(spec)
	local w = {emerges = {}, writes = {}, reads = 0, queue = {}}
	local surface = spec.surface or function() return 20 end
	local names = {
		["default:stone"] = {walkable = true},
		["default:water"] = {liquid = true},
		["default:ice"] = {walkable = true, ice = true},
	}
	local env = {}
	env.node_info = function(name) return names[name] end
	env.get_node_name = function(x, y, z)
		w.reads = w.reads + 1
		if spec.unloaded and spec.unloaded(x, z) then return "ignore" end
		local h = surface(x, z)
		if spec.ice and spec.ice(x, z) and y == h then return "default:ice" end
		if y <= h then return "default:stone" end
		local wl = spec.water and spec.water(x, z)
		if wl and y <= wl then return "default:water" end
		return "air"
	end
	w.timers, w.hung = {}, {}
	env.after = function(seconds, fn)
		w.timers[#w.timers + 1] = {seconds = seconds, fn = fn}
	end
	env.emerge = function(minpos, maxpos, cb)
		w.emerges[#w.emerges + 1] = {min = minpos, max = maxpos}
		local ok = true
		if spec.emerge_ok then ok = spec.emerge_ok(minpos, maxpos) end
		if spec.hang and spec.hang(#w.emerges, minpos, maxpos) then
			w.hung[#w.hung + 1] = function() cb(ok) end -- never called by itself
		elseif spec.deferred then
			w.queue[#w.queue + 1] = function() cb(ok) end
		else
			cb(ok)
		end
	end
	-- Anything else on env (writes included) is a bug in the search.
	setmetatable(env, {
		__index = function(_, k) error("search touched env." .. tostring(k)) end,
		__newindex = function(_, k) error("search set env." .. tostring(k)) end,
	})
	w.env = env
	w.pump = function()
		while #w.queue > 0 do table.remove(w.queue, 1)() end
	end
	return w
end

-- Runs a search, returns result, summary, details, number of done calls.
local function run(world, ppos, opts, seed)
	local calls, result, summary, details = 0
	ss.search(ppos, seed or SEED, opts, function(r, s, d)
		calls = calls + 1
		result, summary, details = r, s, d
	end, world.env)
	if world.pump then world.pump() end
	return result, summary, details, calls
end

local PLAYER = {x = 0.4, y = 21, z = -0.3}  -- node (0,0), standing on y=20
local SMALL = {max_radius = 64}               -- keep failure runs quick

-- Medieval content buildings store approach as a direct {x, z} point,
-- unlike named sites' approach.pos. Search must recognize both layouts as
-- translated copies of the seed plan.
do
	local catalog = dofile("src/catalog.lua")
	local profile = assert(planner.landmark_profile(catalog.snapshot()))
	local opts = {step = 160, max_radius = 160,
		planner_opts = {landmarks = profile}}
	local content_plan = assert(planner.plan({x = 0, z = 0}, 101, opts.planner_opts))
	eq(content_plan.content and #content_plan.content.buildings > 0, true,
		"populated catalog fixture includes content buildings")
	local result, summary, details
	ss_real.search({x = 0, y = 21, z = 0}, 101, opts, function(r, s, d)
		result, summary, details = r, s, d
	end, new_world({}).env)
	eq(result ~= nil, true, "populated catalog search accepts translated plan")
	if result then
		eq(result.candidate.dx ~= 0 or result.candidate.dz ~= 0, true,
			"populated catalog search excludes player-overlapping origin")
		eq(result.plan.content and #result.plan.content.buildings > 0, true,
			"populated catalog result retains content buildings")
	else
		eq(type(summary), "string", "populated catalog search failure summary")
		eq(details.rejections.plan_failed or 0, 0,
			"populated catalog translation does not reject plans")
	end
end

-- The first candidate (in search order) whose bounds are clear of the player,
-- computed independently from the search.
local function expected_first_clear(opts)
	opts = opts or {}
	local list = ss.candidate_offsets(opts.step or 16, opts.max_radius or 320)
	local base = small_planner.plan({x = 0, z = 0}, SEED)
	for i, o in ipairs(list) do
		-- (translation only; the test of the real plan is the final check)
		local bb = base.bounds
		local bounds = {x1 = bb.x1 + o.dx, z1 = bb.z1 + o.dz, x2 = bb.x2 + o.dx, z2 = bb.z2 + o.dz}
		if not ss.player_inside(bounds, 0, 0, opts.player_margin or 4) then
			local plan = small_planner.plan({x = o.dx, z = o.dz}, SEED)
			eq(plan.bounds.x1, bounds.x1, "planner layout translates with the centre")
			return i, o, plan
		end
	end
end

------------------------------------------------------------------------
-- Flat world: first clear candidate wins
------------------------------------------------------------------------
local ei, eo, eplan = expected_first_clear()
local w = new_world({})
local r, summary, d, calls = run(w, PLAYER, nil)
eq(calls, 1, "flat: done called once")
eq(summary, nil, "flat: no failure summary")
eq(r ~= nil, true, "flat: result")
eq(r.candidate.index, ei, "flat: first clear candidate index")
eq(r.center.x, eo.dx, "flat: centre x")
eq(r.center.z, eo.dz, "flat: centre z")
eq(r.ground_y, 20, "flat: ground level")
eq(r.min_height, 20, "flat: min height")
eq(r.max_height, 20, "flat: max height")
eq(d.rejections.player_inside, ei - 1, "flat: skipped candidates were player_inside")
eq(#w.emerges, 2, "flat: read volume then build volume, accepted candidate only")
eq(#w.writes, 0, "flat: no writes")

local bd = r.plan.bounds
eq(bd.x1, eplan.bounds.x1, "flat: plan bounds are the planner's")
eq(r.build_bounds.min.x, bd.x1, "flat: build min x")
eq(r.build_bounds.max.x, bd.x2, "flat: build max x")
eq(r.build_bounds.min.z, bd.z1, "flat: build min z")
eq(r.build_bounds.max.z, bd.z2, "flat: build max z")
eq(r.build_bounds.min.y, 20, "flat: build min y")
eq(r.build_bounds.max.y, 20 + catalog.get("demo_house").size.y - 1,
	"flat: build max y is the top of the tallest placed structure")
eq(#r.structures, 1, "flat: composed structures reported")
local iv = r.inspection_volume
eq(w.emerges[1].min.x, iv.min.x, "flat: emerged read volume min x")
eq(w.emerges[1].max.y, iv.max.y, "flat: emerged read volume max y")
eq(iv.min.x, bd.x1, "flat: read volume is the plan bounds in X")
eq(iv.min.y, 20 - ss.CONSTANTS.SCAN_DOWN, "flat: read volume bottom")
eq(iv.max.y, 20 + ss.CONSTANTS.SCAN_UP + 1, "flat: read volume top (window + sentinel)")
local bv = r.build_volume
eq(w.emerges[2].min.x, bv.min.x, "flat: emerged build volume min x")
eq(w.emerges[2].max.y, bv.max.y, "flat: emerged build volume max y")
eq(bv.min.x, bd.x1 - ss.CONSTANTS.CUT_FILL_MARGIN, "flat: build volume has cut/fill margin")
eq(bv.max.y, r.build_bounds.max.y, "flat: build volume covers the structures")
eq(bv.min.y, r.build_bounds.min.y - ss.CONSTANTS.CUT_FILL_MARGIN, "flat: build volume covers cut/fill")

-- Every boundary column is in the height map, and nothing else.
local union = ss.boundary_columns(r.plan.boundary.rects)
eq(r.columns, #union, "flat: every boundary column inspected")
local all = true
for _, c in ipairs(union) do
	if ss.height_at(r, c.x, c.z) ~= 20 then all = false end
end
eq(all, true, "flat: height map covers every column")
local mapped = 0
for _, col in pairs(r.heights) do
	for _ in pairs(col) do mapped = mapped + 1 end
end
eq(mapped, #union, "flat: height map has no extra columns")

-- Determinism: same inputs, same answer.
local r2 = run(new_world({}), PLAYER, nil)
eq(r2.center.x, r.center.x, "deterministic centre x")
eq(r2.center.z, r.center.z, "deterministic centre z")

-- Reads happen only after the emerge and only inside the inspection volume.
local oob = 0
local w2 = new_world({})
local inner = w2.env.get_node_name
local volume
w2.env.get_node_name = nil
rawset(w2.env, "get_node_name", function(x, y, z)
	if volume and (x < volume.min.x or x > volume.max.x or y < volume.min.y
			or y > volume.max.y or z < volume.min.z or z > volume.max.z) then
		oob = oob + 1
	end
	return inner(x, y, z)
end)
local inner_emerge = w2.env.emerge
rawset(w2.env, "emerge", function(minpos, maxpos, cb)
	volume = {min = minpos, max = maxpos}
	return inner_emerge(minpos, maxpos, cb)
end)
run(w2, PLAYER, nil)
eq(oob, 0, "reads stay inside the emerged volume")
eq(w2.reads > 0, true, "reads happened")

------------------------------------------------------------------------
-- Median and range
------------------------------------------------------------------------
-- Mostly 20 with a quarter of the columns at 24: median 20, range 4.
local w3 = new_world({surface = function(x) return x % 4 == 0 and 24 or 20 end})
r = run(w3, {x = 0, y = 21, z = 0}, nil)
eq(r ~= nil, true, "median: accepted")
eq(r.ground_y, 20, "median: median of heights, not mean/max")
eq(r.min_height, 20, "median: min")
eq(r.max_height, 24, "median: max")
eq(r.build_bounds.max.y, 27, "median: top is the tallest placed structure, above the highest surface")

-- Whole site sits at 30 (high but inside the window): ground is 30.
r = run(new_world({surface = function() return 30 end}), {x = 0, y = 31, z = 0}, nil)
eq(r.ground_y, 30, "relative to the player's level")

-- Range of exactly 16 is accepted, 17 rejected everywhere.
local function striped(delta)
	return function(x) return x % 2 == 0 and 20 or 20 + delta end
end
r = run(new_world({surface = striped(16)}), PLAYER, nil)
eq(r ~= nil, true, "range 16 accepted")
local fw = new_world({surface = striped(17)})
local r9, s9, d9, c9 = run(fw, PLAYER, SMALL)
eq(r9, nil, "range 17: rejected")
eq(c9, 1, "range 17: done once")
eq(d9.rejections.too_uneven ~= nil and d9.rejections.too_uneven > 0, true, "range 17: too_uneven counted")
eq(s9:find("too_uneven", 1, true) ~= nil, true, "range 17: summary names the reason")
eq(s9:find("Nothing was changed", 1, true) ~= nil, true, "range 17: summary says nothing changed")
eq(#fw.writes, 0, "range 17: no writes")

-- A 20-node cliff through every candidate.
local cw = new_world({surface = function(x) return x % 2 == 0 and 20 or 40 end})
r9, s9, d9 = run(cw, PLAYER, SMALL)
eq(r9, nil, "cliff: rejected")
eq((d9.rejections.too_uneven or 0) + (d9.rejections.too_high or 0) > 0, true, "cliff: terrain reasons")

------------------------------------------------------------------------
-- Water, unloaded, emerge failure, plan failure
------------------------------------------------------------------------
-- Lake everywhere: only water reasons; summary says so.
local lw = new_world({surface = function() return 15 end, water = function() return 20 end})
r9, s9, d9, c9 = run(lw, {x = 0, y = 16, z = 0}, SMALL)
eq(r9, nil, "lake: no site")
eq(d9.rejections.water ~= nil, true, "lake: water counted")
eq(s9:find("water", 1, true) ~= nil, true, "lake: summary mentions water")
eq(d9.candidates_tried, d9.candidates_total, "lake: whole order exhausted")
eq(#lw.writes, 0, "lake: no writes")

-- Lava counts the same (any liquid): classified through node_info.
-- Local lake: the first clear candidate overlaps it, a later one does not.
local li, lo, lplan = expected_first_clear()
local function lake_in(plan)
	local x = (plan.bounds.x1 + plan.bounds.x2) / 2
	return function(px) return math.abs(px - x) <= 100 and px >= plan.bounds.x1 - 1 and 0 or nil end
end
local partial = new_world({
	surface = function(x, z)
		return (x >= lplan.bounds.x1 + 5 and x <= lplan.bounds.x1 + 7) and 10 or 20
	end,
	water = function(x, z)
		if x >= lplan.bounds.x1 + 5 and x <= lplan.bounds.x1 + 7 then return 20 end
	end,
})
r = run(partial, {x = 0, y = 21, z = 0}, nil)
eq(r ~= nil, true, "partial lake: a dry candidate is found")
if r then
	eq(r.candidate.index > li, true, "partial lake: wet candidate skipped")
	eq(partial.env.get_node_name(r.center.x, 20, r.center.z) ~= "default:water", true, "partial lake: centre dry")
end

-- Unloaded terrain somewhere in every candidate.
local uw = new_world({unloaded = function(x, z) return x % 7 == 0 and z % 5 == 0 end})
r9, s9, d9 = run(uw, {x = 1, y = 21, z = 1}, SMALL)
eq(r9, nil, "unloaded: rejected")
eq(d9.rejections.unknown ~= nil, true, "unloaded: unknown counted")
eq(s9:find("unknown", 1, true) ~= nil, true, "unloaded: summary")

-- Emerge failure is never accepted even though the terrain reads fine.
local ew = new_world({emerge_ok = function() return false end})
r9, s9, d9, c9 = run(ew, PLAYER, SMALL)
eq(r9, nil, "emerge failure: not accepted")
eq(c9, 1, "emerge failure: done once")
eq(d9.rejections.emerge_failed ~= nil and d9.rejections.emerge_failed > 0, true, "emerge failure: counted")
eq(s9:find("emerge_failed", 1, true) ~= nil, true, "emerge failure: summary")
eq(#ew.emerges > 0, true, "emerge failure: emerge attempted")
eq(ew.reads, 1, "emerge failure: only the player's ground node was read")

-- Plan failure: no emerge, counted, not accepted.
local pw = new_world({})
local broken_landmarks = {}
for k, v in pairs(medieval_profile) do broken_landmarks[k] = v end
broken_landmarks.cathedral = {id = "no_such_cathedral", size = medieval_profile.cathedral.size,
	entrance = medieval_profile.cathedral.entrance}
r9, s9, d9 = run(pw, PLAYER, {max_radius = 48, planner_opts = {landmarks = broken_landmarks}})
eq(r9, nil, "plan failure: not accepted")
eq(d9.rejections.plan_failed, 1, "plan failure: fails fast, counted once")
eq(d9.candidates_tried, 1, "plan failure: no scan of other candidates")
eq(#pw.emerges, 0, "plan failure: no emerge")
eq(s9:find("No town plan for seed", 1, true) ~= nil, true, "plan failure: summary")
eq(s9:find("no_such_cathedral", 1, true) ~= nil, true, "plan failure: planner reason surfaced")

-- Asynchronous emerge: nothing completes until the callbacks fire.
local aw = new_world({deferred = true})
local acalls, ares = 0
ss.search(PLAYER, SEED, nil, function(rr) acalls = acalls + 1; ares = rr end, aw.env)
eq(acalls, 0, "async: not done before emerge returns")
eq(#aw.emerges, 1, "async: one emerge outstanding")
aw.pump()
eq(acalls, 1, "async: done once after emerge")
eq(ares ~= nil and ares.ground_y, 20, "async: result")

------------------------------------------------------------------------
-- Exhaustion and nothing-written guarantee
------------------------------------------------------------------------
local xw = new_world({surface = striped(30)})
r9, s9, d9, c9 = run(xw, PLAYER, nil)
eq(r9, nil, "exhaustion: no site")
eq(c9, 1, "exhaustion: done once")
eq(d9.candidates_tried, #offs, "exhaustion: full order tried (default radius)")
eq(s9:find("within 320 nodes", 1, true) ~= nil, true, "exhaustion: summary names the radius")
eq(#xw.writes, 0, "exhaustion: no writes")

------------------------------------------------------------------------
-- core adapter: single callback at the end, no writes at all
------------------------------------------------------------------------
local function fake_core()
	local c = {
		EMERGE_CANCELLED = 1, EMERGE_ERRORED = 2,
		registered_nodes = {
			["default:stone"] = {walkable = true},
			["default:water"] = {liquidtype = "source"},
			["default:grass"] = {walkable = false, groups = {plant = 1}, buildable_to = true},
			["mcl_core:snow_2"] = {walkable = true},
		},
		writes = {}, emerged = 0,
	}
	for _, fn in ipairs({"set_node", "bulk_set_node", "swap_node", "place_schematic",
			"add_node", "remove_node", "set_node_level", "fix_light"}) do
		c[fn] = function() c.writes[#c.writes + 1] = fn end
	end
	c.get_node = function(p)
		if p.y <= 20 then return {name = "default:stone"} end
		return {name = "air"}
	end
	c.emerge_area = function(a, b, cb)
		c.emerged = c.emerged + 1
		c.last_cb = cb
	end
	return c
end

local fc = fake_core()
local cenv = ss.core_env(fc)
local fired, fok = 0
cenv.emerge({x = 0, y = 0, z = 0}, {x = 1, y = 1, z = 1}, function(ok) fired = fired + 1; fok = ok end)
fc.last_cb(nil, 0, 2)
fc.last_cb(nil, 0, 1)
eq(fired, 0, "core emerge: waits for calls_remaining == 0")
fc.last_cb(nil, 0, 0)
eq(fired, 1, "core emerge: fires once at the end")
eq(fok, true, "core emerge: ok")
fired = 0
cenv.emerge({x = 0, y = 0, z = 0}, {x = 1, y = 1, z = 1}, function(ok) fired = fired + 1; fok = ok end)
fc.last_cb(nil, fc.EMERGE_ERRORED, 1)
fc.last_cb(nil, 0, 0)
eq(fired, 1, "core emerge error: fires once")
eq(fok, false, "core emerge error: failed")
fired = 0
cenv.emerge({x = 0, y = 0, z = 0}, {x = 1, y = 1, z = 1}, function(ok) fired = fired + 1; fok = ok end)
fc.last_cb(nil, fc.EMERGE_CANCELLED, 0)
eq(fok, false, "core emerge cancelled: failed")

eq(cenv.get_node_name(0, 20, 0), "default:stone", "core env get_node_name")
local ni = cenv.node_info("default:water")
eq(ni.liquid, true, "core node_info liquid")
eq(cenv.node_info("default:grass").clearable, true, "core node_info clearable")
eq(cenv.node_info("mcl_core:snow_2").clearable, true, "core node_info snow")
eq(cenv.node_info("nope:nothing"), nil, "core node_info unknown")

-- End to end through core_env with an immediately-completing fake emerge.
fc.emerge_area = function(a, b, cb)
	fc.emerged = fc.emerged + 1
	cb(nil, 0, 1)
	cb(nil, 0, 0)
end
local cres, ccalls = nil, 0
ss.search(PLAYER, SEED, nil, function(rr) ccalls = ccalls + 1; cres = rr end, cenv)
eq(ccalls, 1, "core env search: done once")
eq(cres ~= nil and cres.ground_y, 20, "core env search: result")
eq(#fc.writes, 0, "core env search: no world writes")

-- A failing search through core_env also writes nothing.
fc.get_node = function(p)
	if p.y <= 10 then return {name = "default:stone"} end
	if p.y <= 20 and (p.x ~= 0 or p.z ~= 0) then return {name = "default:water"} end
	if p.y <= 20 then return {name = "default:stone"} end
	return {name = "air"}
end
fc.after = function() end
cres, ccalls = nil, 0
ss.search(PLAYER, SEED, SMALL, function(rr) ccalls = ccalls + 1; cres = rr end, cenv)
eq(ccalls, 1, "core env failure: done once")
eq(cres, nil, "core env failure: no site")
eq(#fc.writes, 0, "core env failure: no world writes")

-- Invalid arguments raise clear errors instead of reaching the planner.
fails(function() ss.search(PLAYER, 2 ^ 30, nil, function() end, new_world({}).env) end,
	"seed must be an integer", "seed out of range")
fails(function() ss.search(PLAYER, 1.5, nil, function() end, new_world({}).env) end,
	"seed must be an integer", "non-integer seed")
fails(function() ss.search({x = 0}, 1, nil, function() end, new_world({}).env) end,
	"player_pos", "bad player_pos")

------------------------------------------------------------------------
-- Review fixes: containment, watchdog, windows, boundary cells
------------------------------------------------------------------------
-- Player must stand on solid ground.
do
	local fly = new_world({})
	local rr, ss_, dd, cc = run(fly, {x = 0, y = 40, z = 0}, nil)
	eq(rr, nil, "flying: no site")
	eq(cc, 1, "flying: done once")
	eq(ss_:find("standing on solid ground", 1, true) ~= nil, true, "flying: clear message")
	eq(#fly.emerges, 0, "flying: nothing emerged")
	local onwater = new_world({surface = function() return 15 end, water = function() return 20 end})
	rr, ss_ = run(onwater, {x = 0, y = 21, z = 0}, nil)
	eq(rr, nil, "on water: no site")
	eq(ss_:find("standing on solid ground", 1, true) ~= nil, true, "on water: clear message")
end

-- Bad opts cannot loop forever.
fails(function() ss.search(PLAYER, SEED, {step = 0}, function() end, new_world({}).env) end,
	"step must be", "step 0 rejected")
fails(function() ss.search(PLAYER, SEED, {step = -16}, function() end, new_world({}).env) end,
	"finite number >= 0", "negative step rejected")
fails(function() ss.search(PLAYER, SEED, {max_radius = -1}, function() end, new_world({}).env) end,
	"max_radius", "negative radius rejected")
eq(ss.MAX_SEED, planner.SEED_LIMIT, "MAX_SEED aliases the planner limit")

-- Throwing env functions end the search through done, exactly once.
do
	local tw = new_world({})
	local base_get = tw.env.get_node_name
	local n = 0
	rawset(tw.env, "get_node_name", function(x, y, z)
		n = n + 1
		if n > 5 then error("boom in get_node") end
		return base_get(x, y, z)
	end)
	local ok, rr, ss_, dd, cc = pcall(run, tw, PLAYER, nil)
	eq(ok, true, "throwing get_node: search does not raise")
	eq(rr, nil, "throwing get_node: no site")
	eq(cc, 1, "throwing get_node: done once")
	eq(ss_:find("internal error", 1, true) ~= nil and ss_:find("boom in get_node", 1, true) ~= nil,
		true, "throwing get_node: internal error summary")

	local ew2 = new_world({})
	rawset(ew2.env, "emerge", function() error("boom in emerge") end)
	ok, rr, ss_, dd, cc = pcall(run, ew2, PLAYER, nil)
	eq(ok, true, "throwing emerge: search does not raise")
	eq(cc, 1, "throwing emerge: done once")
	eq(ss_:find("internal error", 1, true) ~= nil, true, "throwing emerge: summary")

	-- Error inside a deferred emerge callback is contained as well.
	local dw = new_world({deferred = true})
	local g = dw.env.get_node_name
	local first = true
	rawset(dw.env, "get_node_name", function(x, y, z)
		if first then first = false; return g(x, y, z) end
		error("late boom")
	end)
	local calls_ = 0
	local msg_
	ss.search(PLAYER, SEED, nil, function(r_, s_) calls_ = calls_ + 1; msg_ = s_ end, dw.env)
	ok = pcall(dw.pump)
	eq(ok, true, "deferred throw: callback does not raise into the engine")
	eq(calls_, 1, "deferred throw: done once")
	eq(msg_ and msg_:find("late boom", 1, true) ~= nil, true, "deferred throw: message")
end

-- Candidates beyond the planner's centre limit are skipped, not thrown.
for _, px in ipairs({30900, -30900}) do
	local big = {x = px, y = 21, z = 0}
	-- With radius 320 candidates reach |x| = 31220.
	local ok, rr, ss_, dd, cc = pcall(run, new_world({surface = striped(30)}), big, nil)
	eq(ok, true, "near limit full radius " .. px .. ": no raise")
	eq(cc, 1, "near limit " .. px .. ": done once")
	eq(dd and (dd.rejections.out_of_range or 0) > 0, true, "near limit " .. px .. ": out_of_range counted")
	eq(rr ~= nil or (ss_ and ss_:find("out_of_range", 1, true) ~= nil), true,
		"near limit " .. px .. ": found site or reported out_of_range")
end

-- Watchdog: an emerge that never completes is timed out, the late callback
-- is ignored, and the search carries on.
do
	local hw = new_world({hang = function(n) return n == 1 end})
	local calls_, res_ = 0
	ss.search(PLAYER, SEED, nil, function(r_) calls_ = calls_ + 1; res_ = r_ end, hw.env)
	eq(calls_, 0, "hang: waiting")
	eq(#hw.timers, 1, "hang: one watchdog armed")
	eq(hw.timers[1].seconds, ss.CONSTANTS.EMERGE_TIMEOUT, "hang: watchdog uses EMERGE_TIMEOUT")
	hw.timers[1].fn()
	eq(calls_, 1, "hang: continued after timeout and finished")
	eq(res_ ~= nil and res_.candidate.index > ei, true, "hang: later candidate chosen")
	hw.hung[1]() -- late callback
	eq(calls_, 1, "hang: late callback ignored")
	hw.timers[1].fn()
	eq(calls_, 1, "hang: repeated timer ignored")
end
do
	-- Never completes at all: gives up after MAX_CONSECUTIVE_TIMEOUTS.
	local hw = new_world({hang = function() return true end})
	local calls_, res_, sum_, det_ = 0
	ss.search(PLAYER, SEED, nil, function(r_, s_, d_) calls_ = calls_ + 1; res_, sum_, det_ = r_, s_, d_ end, hw.env)
	local fired = 0
	while calls_ == 0 and fired < 20 do
		fired = fired + 1
		hw.timers[fired].fn()
	end
	eq(calls_, 1, "hang forever: done once")
	eq(res_, nil, "hang forever: no site")
	eq(fired, ss.CONSTANTS.MAX_CONSECUTIVE_TIMEOUTS, "hang forever: gives up after N timeouts")
	eq(sum_ and sum_:find("timed out", 1, true) ~= nil, true, "hang forever: summary")
	eq(det_ and det_.rejections.emerge_timeout, fired, "hang forever: timeouts counted")
	for _, cb in ipairs(hw.hung) do cb() end
	eq(calls_, 1, "hang forever: late callbacks ignored")
end

-- Second (build volume) emerge failing rejects the candidate.
do
	local inspection_bottom = 20 - ss.CONSTANTS.SCAN_DOWN
	local bw = new_world({emerge_ok = function(minp) return minp.y == inspection_bottom end})
	local rr, ss_, dd, cc = run(bw, PLAYER, SMALL)
	eq(rr, nil, "build emerge failure: not accepted")
	eq(cc, 1, "build emerge failure: done once")
	eq(dd.rejections.emerge_failed ~= nil, true, "build emerge failure: counted")
	eq(#bw.emerges >= 2, true, "build emerge failure: second emerge attempted")
end

-- Window edges: surface exactly ref+48 / ref-48 accepted, one more rejected.
do
	local function edge(s)
		return new_world({surface = function(x, z)
			if x == 0 and z == 0 then return 20 end
			return s
		end})
	end
	local rr = run(edge(20 + ss.CONSTANTS.SCAN_UP), PLAYER, SMALL)
	eq(rr ~= nil and rr.ground_y, 68, "window: surface at ref+48 accepted")
	local r_, _, dd = run(edge(20 + ss.CONSTANTS.SCAN_UP + 1), PLAYER, SMALL)
	eq(r_, nil, "window: surface at ref+49 rejected")
	eq(dd.rejections.too_high ~= nil, true, "window: ref+49 is too_high")
	rr = run(edge(20 - ss.CONSTANTS.SCAN_DOWN), PLAYER, SMALL)
	eq(rr ~= nil and rr.ground_y, -28, "window: surface at ref-48 accepted")
	r_, _, dd = run(edge(20 - ss.CONSTANTS.SCAN_DOWN - 1), PLAYER, SMALL)
	eq(r_, nil, "window: surface at ref-49 rejected")
	eq(dd.rejections.no_ground ~= nil, true, "window: ref-49 is no_ground")
end

-- A bad cell anywhere in a rect (not only at the bbox) rejects; bbox cells
-- outside the rect union are ignored.
do
	local rects = eplan.boundary.rects
	local inunion = {}
	for _, c in ipairs(ss.boundary_columns(rects)) do inunion[c.x .. "," .. c.z] = true end
	local r1 = rects[1]
	local ix, iz = math.floor((r1.x1 + r1.x2) / 2), math.floor((r1.z1 + r1.z2) / 2)
	local bb = eplan.bounds
	eq(ix > bb.x1 and ix < bb.x2 and iz > bb.z1 and iz < bb.z2, true, "interior cell is off the bbox edge")
	local rr, _, dd = run(new_world({
		surface = function(x, z) if x == ix and z == iz then return 15 end return 20 end,
		water = function(x, z) if x == ix and z == iz then return 20 end end,
	}), PLAYER, nil)
	eq(rr ~= nil and rr.candidate.index == ei, false, "interior bad cell rejects the first candidate")
	eq(dd.rejections.water ~= nil, true, "interior bad cell: water counted")

	-- A cell inside the bbox but outside every rect is never read.
	local hole
	for x = bb.x1, bb.x2 do
		for z = bb.z1, bb.z2 do
			if not hole and not inunion[x .. "," .. z] then hole = {x, z} end
		end
	end
	eq(hole ~= nil, true, "fixture boundary has a notch inside its bounding box")
	if hole then
		rr = run(new_world({
			surface = function(x, z) if x == hole[1] and z == hole[2] then return 15 end return 20 end,
			water = function(x, z) if x == hole[1] and z == hole[2] then return 30 end end,
		}), PLAYER, nil)
		eq(rr ~= nil and rr.candidate.index, ei, "bbox cell outside the rects is ignored")
		eq(rr ~= nil and ss.height_at(rr, hole[1], hole[2]), nil, "bbox hole has no height")
	end
end

------------------------------------------------------------------------
-- Final cleanups: node_info throw, throwing done, input validation, limits
------------------------------------------------------------------------
do
	-- Throwing env.node_info during the initial ground check.
	local nw = new_world({})
	rawset(nw.env, "node_info", function() error("boom in node_info") end)
	local ok, rr, ss_, dd, cc = pcall(run, nw, PLAYER, nil)
	-- (name "default:stone" is unregistered for classify only when info throws)
	eq(ok, true, "throwing node_info: search does not raise")
	eq(cc, 1, "throwing node_info: done once")
	eq(rr, nil, "throwing node_info: no site")
	eq(ss_ ~= nil and ss_:find("internal error", 1, true) ~= nil, true, "throwing node_info: summary")
end

do
	-- done raising: swallowed and logged, never rethrown (async and timer).
	local logged = {}
	local function with_log(w)
		rawset(w.env, "log", function(level, msg) logged[#logged + 1] = level .. ": " .. msg end)
		return w
	end
	local dw = with_log(new_world({deferred = true}))
	local calls_ = 0
	local ok = pcall(function()
		ss.search(PLAYER, SEED, nil, function() calls_ = calls_ + 1; error("done blew up") end, dw.env)
	end)
	eq(ok, true, "throwing done (sync start): search returns")
	ok = pcall(dw.pump)
	eq(ok, true, "throwing done (async callback): not rethrown")
	eq(calls_, 1, "throwing done (async callback): called once")
	eq(#logged >= 1 and logged[1]:find("done blew up", 1, true) ~= nil, true, "throwing done: logged")

	logged = {}
	local hw = with_log(new_world({hang = function() return true end}))
	calls_ = 0
	ss.search(PLAYER, SEED, nil, function() calls_ = calls_ + 1; error("done blew up 2") end, hw.env)
	ok = true
	for i = 1, ss.CONSTANTS.MAX_CONSECUTIVE_TIMEOUTS do
		local okk = pcall(hw.timers[i].fn)
		ok = ok and okk
	end
	eq(ok, true, "throwing done (timer): not rethrown")
	eq(calls_, 1, "throwing done (timer): called once")
	eq(#logged >= 1 and logged[1]:find("done blew up 2", 1, true) ~= nil, true, "throwing done (timer): logged")

	-- Early synchronous failure (not on solid ground) with a throwing done.
	ok = pcall(ss.search, {x = 0, y = 90, z = 0}, SEED, nil, function() error("sync done") end,
		with_log(new_world({})).env)
	eq(ok, true, "throwing done (sync failure): swallowed")
end

-- Input validation.
fails(function() ss.search(PLAYER, SEED, {scan_up = 1.5}, function() end, new_world({}).env) end,
	"scan_up must be an integer", "fractional scan_up")
fails(function() ss.search(PLAYER, SEED, {scan_down = 2.5}, function() end, new_world({}).env) end,
	"scan_down must be an integer", "fractional scan_down")
fails(function() ss.search(PLAYER, SEED, {stpe = 8}, function() end, new_world({}).env) end,
	"unknown option 'stpe'", "typo'd option")
fails(function() ss.search(PLAYER, SEED, {max_radius = math.huge}, function() end, new_world({}).env) end,
	"finite number", "infinite radius")
fails(function() ss.search({x = 0 / 0, y = 21, z = 0}, SEED, nil, function() end, new_world({}).env) end,
	"player_pos.x must be finite", "NaN player x")
fails(function() ss.search({x = 0, y = math.huge, z = 0}, SEED, nil, function() end, new_world({}).env) end,
	"player_pos.y must be finite", "inf player y")
fails(function() ss.search({x = 0, y = 21, z = -math.huge}, SEED, nil, function() end, new_world({}).env) end,
	"player_pos.z must be finite", "-inf player z")
fails(function() ss.search(PLAYER, SEED, "x", function() end, new_world({}).env) end,
	"opts must be a table", "non-table opts")
-- Real structure bounds are the only bounds: the old switch is gone and the
-- search needs entries (or a landmark profile) to compose them.
fails(function() ss.search(PLAYER, SEED, {structure_bounds = true}, function() end, new_world({}).env) end,
	"unknown option 'structure_bounds'", "structure_bounds option removed")
fails(function() ss_raw.search(PLAYER, SEED, {}, function() end, new_world({}).env) end,
	"opts.entries or opts.planner_opts.landmarks is required", "no entries, no profile")
fails(function() ss_raw.search(PLAYER, SEED, {entries = "x"}, function() end, new_world({}).env) end,
	"opts.entries must be a catalog-entry table", "entries must be a table")
do
	-- planner_opts and upper-case constant names remain accepted.
	local ok = pcall(run, new_world({}), PLAYER, {STEP = 16, planner_opts = {}, max_radius = 48})
	eq(ok, true, "known option spellings accepted")
end

-- No emerge volume may extend beyond +/-31000, margins included.
do
	for _, px in ipairs({30990, -30990}) do
		local mw = new_world({surface = striped(30)})
		local ok, rr, ss_, dd = pcall(run, mw, {x = px, y = 21, z = 30990}, nil)
		eq(ok, true, "limit volumes " .. px .. ": no raise")
		local worst = 0
		for _, e in ipairs(mw.emerges) do
			worst = math.max(worst, math.abs(e.min.x), math.abs(e.max.x), math.abs(e.min.z), math.abs(e.max.z))
		end
		eq(worst <= 31000, true, "limit volumes " .. px .. ": every emerged volume within +/-31000")
		eq((dd.rejections.out_of_range or 0) > 0, true, "limit volumes " .. px .. ": out_of_range counted")
		eq(dd.rejections.emerge_timeout, nil, "limit volumes " .. px .. ": no emerge timeouts")
	end
end

-- Frozen lake: ice is never ground (water-like), so every candidate touching
-- it is rejected as water and nothing is written.
local fw2 = new_world({ice = function(x, z) return math.abs(x) > 8 or math.abs(z) > 8 end})
local rf, sf, df = run(fw2, PLAYER, SMALL)
eq(rf, nil, "frozen lake: no site")
eq(df.rejections.water ~= nil and df.rejections.water > 0, true, "frozen lake: rejected as water")
eq(#fw2.writes, 0, "frozen lake: no writes")

------------------------------------------------------------------------
-- Wet sites (ticket #104)
------------------------------------------------------------------------
do
	local WET = ss.WET_DEFAULTS
	eq(WET.max_water_depth, 6, "wet defaults: depth")
	eq(WET.max_wet_fraction, 0.25, "wet defaults: fraction")
	eq(ss.CONSTANTS.MAX_WATER_DEPTH, 0, "legacy default: no wet columns")

	-- scan_column_wet
	local col = {}
	local function cls(y) return col[y] or "air" end
	col = {[30] = "water", [29] = "water", [28] = "solid"}
	local bed, prob, _, surf = ss.scan_column_wet(cls, 40, 0, 6)
	eq(bed, 28, "scan wet: bed")
	eq(surf, 30, "scan wet: surface")
	eq(prob, nil, "scan wet: no problem")
	col = {[25] = "clear", [24] = "solid"}
	bed, prob, _, surf = ss.scan_column_wet(cls, 40, 0, 6)
	eq(bed, 24, "scan dry: bed")
	eq(surf, nil, "scan dry: no surface")
	col = {[30] = "water", [29] = "clear", [28] = "water", [27] = "solid"}
	bed, _, _, surf = ss.scan_column_wet(cls, 40, 0, 6)
	eq(bed == 27 and surf == 30, true, "scan wet: plants under water are passed")
	col = {}
	for y = 30, 20, -1 do col[y] = "water" end
	col[19] = "solid"
	_, prob = ss.scan_column_wet(cls, 40, 0, 6)
	eq(prob, "too_deep_water", "scan wet: deeper than the limit")
	col = {[30] = "water", [29] = "air", [28] = "solid"}
	_, prob = ss.scan_column_wet(cls, 40, 0, 6)
	eq(prob, "no_ground", "scan wet: air gap under ice/water rejects")
	col = {[30] = "water", [29] = "lava"}
	_, prob = ss.scan_column_wet(cls, 40, 0, 6)
	eq(prob, "lava", "scan wet: lava under water rejects")
	col = {[30] = "lava"}
	_, prob = ss.scan_column_wet(cls, 40, 0, 6)
	eq(prob, "lava", "scan wet: top lava rejects")
	col = {}
	for y = 30, 0, -1 do col[y] = "water" end
	_, prob = ss.scan_column_wet(cls, 40, 0, 6)
	eq(prob, "too_deep_water", "scan wet: bottomless water")

	-- inspect_columns wet rules
	local cols = {}
	for i = 1, 100 do cols[i] = {x = i, z = 0} end
	local function rd(bed_of, surf_of)
		return function(x) return bed_of(x), nil, 0, surf_of and surf_of(x) or nil end
	end
	local cfg = {max_depth = 6, max_fraction = 0.25}
	local function pond_cols(n, bed, surf, dry)
		return rd(function(x) return x <= n and bed or dry end,
			function(x) return x <= n and surf or nil end)
	end
	local i1 = ss.inspect_columns(cols, pond_cols(10, 16, 20, 20), 100, 16, 5, 24, cfg)
	eq(i1 ~= nil and i1.ground_y, 20, "wet inspect: ground at the water surface")
	eq(i1 and i1.wet.count, 10, "wet inspect: count")
	eq(i1 and i1.wet.max_depth, 4, "wet inspect: depth (surface - bed)")
	eq(i1 and i1.heights[1][0], 16, "wet inspect: heights keep the bed")
	eq(i1 and i1.min_height, 16, "wet inspect: min height is the bed")
	eq(i1 and i1.wet.surfaces[1][0], 20, "wet inspect: surfaces kept")
	local _, code2 = ss.inspect_columns(cols, pond_cols(30, 16, 20, 20), 100, 16, 5, 24, cfg)
	eq(code2, "too_wet", "wet inspect: too many wet columns")
	local i3 = ss.inspect_columns(cols, pond_cols(25, 16, 20, 20), 100, 16, 5, 24, cfg)
	eq(i3 ~= nil, true, "wet inspect: exactly the fraction accepted")
	local i4 = ss.inspect_columns(cols, pond_cols(5, 22, 26, 20), 100, 16, 5, 24, cfg)
	eq(i4 ~= nil and i4.ground_y, 26, "wet inspect: ground never below a wet surface")
	local ring_cfg = {max_depth = 6, max_fraction = 0.25, ring = {{x = 0, z = 0}},
		read_ring = function() return 23 end}
	local i5 = ss.inspect_columns(cols, rd(function() return 20 end), 100, 16, 5, 24, ring_cfg)
	eq(i5 ~= nil and i5.ground_y, 23, "wet inspect: ring water raises the ground")
	eq(i5 and i5.wet, nil, "wet inspect: ring water is not a wet column")
	ring_cfg.read_ring = function() return 50 end
	local _, code5 = ss.inspect_columns(cols, rd(function() return 20 end), 100, 16, 5, 24, ring_cfg)
	eq(code5, "too_uneven", "wet inspect: ring water beyond cut/fill")
	local _, code6 = ss.inspect_columns(cols, function() return nil, "water", 5 end, 100, 16)
	eq(code6, "water", "legacy water code unchanged")
	local _, code7, msg7 = ss.inspect_columns(cols, function() return nil, "lava", 5 end, 100, 16, 5, 24, cfg)
	eq(code7 == "lava" and msg7:find("lava", 1, true) ~= nil, true, "lava code")

	-- Whole searches on the mock world: a 4x4 pond inside the first
	-- candidate that is clear of the player.
	local big = eplan.boundary.rects[1]
	local px1, pz1 = big.x1 + 2, big.z1 + 2
	local function in_pond(x, z) return x >= px1 and x <= px1 + 3 and z >= pz1 and z <= pz1 + 3 end
	local function pond_world(bed, level)
		return new_world({
			surface = function(x, z) return in_pond(x, z) and bed or 20 end,
			water = function(x, z) if in_pond(x, z) then return level end end,
		})
	end
	local P0 = {x = 0, y = 21, z = 0}
	local lr = run(pond_world(16, 20), P0, nil)
	eq(lr ~= nil and lr.candidate.index > ei, true, "pond legacy: first candidate skipped")
	local opts = {max_water_depth = WET.max_water_depth, max_wet_fraction = WET.max_wet_fraction}
	local wr = run(pond_world(16, 20), P0, opts)
	eq(wr ~= nil and wr.candidate.index, ei, "pond wet: first clear candidate accepted")
	eq(wr and wr.ground_y, 20, "pond wet: ground at water level")
	eq(wr and wr.wet and wr.wet.count, 16, "pond wet: 16 landfilled columns")
	eq(wr and wr.wet and wr.wet.max_depth, 4, "pond wet: depth")
	eq(wr and wr.min_height, 16, "pond wet: lowest bed in min_height")
	eq(wr and wr.heights[px1][pz1], 16, "pond wet: height is the bed")
	eq(wr and wr.build_bounds.min.y <= 16, true, "pond wet: build bounds reach the bed")
	-- bed 12 under water level 20: depth 9 > 6.
	local _, _, dd2 = run(pond_world(12, 20), P0,
		{max_water_depth = 6, max_wet_fraction = 0.25, max_radius = 128})
	eq(dd2.rejections.too_deep_water ~= nil, true, "pond deep: too_deep_water counted")
	local _, _, td = run(pond_world(16, 20), P0,
		{max_water_depth = 6, max_wet_fraction = 0.001, max_radius = 128})
	eq(td.rejections.too_wet ~= nil, true, "pond: too_wet counted")
	-- A pond whose level is below the dry ground (water 19, depth 3).
	local ir = run(pond_world(16, 19), P0, opts)
	eq(ir ~= nil and ir.wet ~= nil and ir.wet.max_depth, 3, "pond wet: depth counted to the top water node")
	eq(ir and ir.ground_y, 20, "pond wet: ground is the dry level (median)")
end

-- The default reach beyond the town edge follows the plan's actual extent: a
-- plan reaching farther than REACH_EDGE from its centre searches that much
-- farther; an explicit max_radius is taken as given.
do
	local wide = setmetatable({
		plan = function(center, seed)
			local plan = make_authored_plan(center, seed)
			plan.bounds = {x1 = center.x - 100, z1 = center.z, x2 = center.x + 15, z2 = center.z + 8}
			return plan
		end,
	}, {__index = small_planner})
	local wide_ss = factory(placement, wide)
	local function total(opts)
		local out
		opts.entries = catalog.entries
		wide_ss.search(PLAYER, SEED, opts, function(_, _, d) out = d.candidates_total end,
			new_world({}).env)
		return out
	end
	local grown = ss.CONSTANTS.MAX_RADIUS + 100 - ss.REACH_EDGE
	eq(total({}), #ss.candidate_offsets(ss.CONSTANTS.STEP, grown), "reach grows with the plan's extent")
	eq(total({max_radius = 320}), #ss.candidate_offsets(ss.CONSTANTS.STEP, 320),
		"explicit max_radius is not grown")
	-- A medieval town's reach follows its plan bounds like any other plan's
	-- (the fixed 208-node envelope that used to floor it at 376 is gone): a
	-- compact plan with edge 60 reaches 320 + (60 - 48) = 332, not 376.
	local compact = setmetatable({
		plan = function(center, seed)
			local plan = make_authored_plan(center, seed)
			plan.bounds = {x1 = center.x - 60, z1 = center.z, x2 = center.x + 15, z2 = center.z + 8}
			return plan
		end,
	}, {__index = small_planner})
	local compact_ss = factory(placement, compact)
	local function compact_total(opts)
		local out
		opts.planner_opts = {landmarks = medieval_profile}
		compact_ss.search(PLAYER, SEED, opts, function(_, _, d) out = d.candidates_total end,
			new_world({}).env)
		return out
	end
	eq(compact_total({entries = catalog.entries}),
		#ss.candidate_offsets(ss.CONSTANTS.STEP, ss.CONSTANTS.MAX_RADIUS + 60 - ss.REACH_EDGE),
		"compact medieval plan reaches by its own extent")
	eq(compact_total({entries = catalog.entries, max_radius = 320}),
		#ss.candidate_offsets(ss.CONSTANTS.STEP, 320), "explicit max_radius wins for medieval")
	-- The real medieval planner: the reach is the plan's own extent.
	for _, seed in ipairs({1, 2}) do
		local real = assert(planner.plan({x = 0, z = 0}, seed, {landmarks = medieval_profile}))
		local b = real.bounds
		local edge = math.max(-b.x1, b.x2, -b.z1, b.z2)
		local out
		ss.search(PLAYER, seed, {entries = catalog.entries, planner_opts = {landmarks = medieval_profile}},
			function(_, _, d) out = d.candidates_total end, new_world({}).env)
		eq(out, #ss.candidate_offsets(ss.CONSTANTS.STEP, ss.CONSTANTS.MAX_RADIUS + edge - ss.REACH_EDGE),
			"real medieval plan seed " .. seed .. " reaches by its bounds")
	end
end

-- Lava is matched by exact node name (ticket #104).
eq(ss.LAVA_NODES["mcl_core:lava_source"], true, "lava source listed")
eq(ss.LAVA_NODES["mcl_decor:lava_lamp"], nil, "unrelated lava-named node is not lava")

-- Authored plans use their actual extent and explicit catalog entries for
-- composition; tall and below-ground structures expand the accepted volume.
do
	local make_authored_plan = dofile("tests/authored_plan_fixture.lua")
	local selected = {
		SEED_LIMIT = planner.SEED_LIMIT,
		check_seed = planner.check_seed,
		CONSTANTS = planner.CONSTANTS,
		validate = planner.validate,
		plan = function(center, seed) return make_authored_plan(center, seed) end,
	}
	local authored_search = factory(placement, selected)
	local house = dofile("src/catalog.lua").get("demo_house")
	eq(planner.validate(make_authored_plan({x = 0, z = 0}, SEED)), true,
		"authored search fixture passes real planner validation")
	local entry = {size = {x = house.size.x, y = 90, z = house.size.z},
		entrance = house.entrance, ground_offset = 12}
	local result, failure, _, done_calls = (function(world, opts)
		local calls, found, why, details = 0
		authored_search.search(PLAYER, SEED, opts, function(r, s, d)
			calls, found, why, details = calls + 1, r, s, d
		end, world.env)
		return found, why, details, calls
	end)(new_world({}), {max_radius = 16, entries = {demo_house = entry}})
	eq(done_calls, 1, "authored search: callback once")
	eq(failure, nil, "authored search: accepted")
	eq(result and result.plan.town_type, "roman", "authored search: preserves selected plan")
	eq(result and result.structures[1].min.y, 8, "authored search: basement included")
	eq(result and result.build_bounds.max.y, 97, "authored search: tall structure included")
	eq(result and result.plan.sites.temple.rect.x1, result and 5 + result.center.x,
		"authored search: translated landmark geometry retained")
	local failed_result, failed_summary, _, failed_calls = (function(world)
		local calls, found, why, details = 0
		authored_search.search(PLAYER, SEED, {max_radius = 16, entries = {}}, function(r, s, d)
			calls, found, why, details = calls + 1, r, s, d
		end, world.env)
		return found, why, details, calls
	end)(new_world({}))
	eq(failed_calls, 1, "authored preflight: callback once")
	eq(failed_result, nil, "authored preflight: missing entry rejected")
	eq(type(failed_summary), "string", "authored preflight: useful failure")
end
