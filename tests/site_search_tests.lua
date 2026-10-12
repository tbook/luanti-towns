-- Site search tests (ticket #14), a small mocked Luanti world. Loaded by
-- tests/run.lua, which passes its check helpers:
--   loadfile("tests/site_search_tests.lua")(eq, fails, placement, planner, factory)
local eq, fails, placement, planner, factory = ...
local ss = factory(placement, planner)

local SEED = 20260101

------------------------------------------------------------------------
-- Pure helpers
------------------------------------------------------------------------
local offs = ss.candidate_offsets(16, 160)
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
	if o.d2 > 160 * 160 then within = false end
	if o.dx % 16 ~= 0 or o.dz % 16 ~= 0 then mult = false end
end
eq(sorted, true, "offsets nearest first")
eq(within, true, "offsets within radius")
eq(mult, true, "offsets multiples of step")
eq(#offs, 317, "offsets count (lattice points in radius 160)")
local offs2 = ss.candidate_offsets(16, 160)
eq(#offs2, #offs, "offsets deterministic count")
local same = true
for i, o in ipairs(offs) do
	if offs2[i].dx ~= o.dx or offs2[i].dz ~= o.dz then same = false end
end
eq(same, true, "offsets deterministic order")
eq(offs[#offs].d2 <= 160 * 160, true, "offsets last within radius")

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
	}
	local env = {}
	env.node_info = function(name) return names[name] end
	env.get_node_name = function(x, y, z)
		w.reads = w.reads + 1
		if spec.unloaded and spec.unloaded(x, z) then return "ignore" end
		local h = surface(x, z)
		if y <= h then return "default:stone" end
		local wl = spec.water and spec.water(x, z)
		if wl and y <= wl then return "default:water" end
		return "air"
	end
	env.emerge = function(minpos, maxpos, cb)
		w.emerges[#w.emerges + 1] = {min = minpos, max = maxpos}
		local ok = true
		if spec.emerge_ok then ok = spec.emerge_ok(minpos, maxpos) end
		if spec.deferred then
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

-- The first candidate (in search order) whose bounds are clear of the player,
-- computed independently from the search.
local function expected_first_clear(opts)
	opts = opts or {}
	local list = ss.candidate_offsets(opts.step or 16, opts.max_radius or 160)
	local base = planner.plan({x = 0, z = 0}, SEED)
	for i, o in ipairs(list) do
		-- (translation only; the test of the real plan is the final check)
		local bb = base.bounds
		local bounds = {x1 = bb.x1 + o.dx, z1 = bb.z1 + o.dz, x2 = bb.x2 + o.dx, z2 = bb.z2 + o.dz}
		if not ss.player_inside(bounds, 0, 0, opts.player_margin or 4) then
			local plan = planner.plan({x = o.dx, z = o.dz}, SEED)
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
eq(#w.emerges, 1, "flat: only the clear candidate emerged")
eq(#w.writes, 0, "flat: no writes")

local bd = r.plan.bounds
eq(bd.x1, eplan.bounds.x1, "flat: plan bounds are the planner's")
eq(r.build_bounds.min.x, bd.x1, "flat: build min x")
eq(r.build_bounds.max.x, bd.x2, "flat: build max x")
eq(r.build_bounds.min.z, bd.z1, "flat: build min z")
eq(r.build_bounds.max.z, bd.z2, "flat: build max z")
eq(r.build_bounds.min.y, 20, "flat: build min y")
eq(r.build_bounds.max.y, 20 + ss.CONSTANTS.LANDMARK_BLOCKOUT_HEIGHT
	+ ss.CONSTANTS.BLOCKOUT_MARGIN, "flat: build max y includes blockout clearance")
local iv = r.inspection_volume
eq(w.emerges[1].min.x, iv.min.x, "flat: emerged volume min x")
eq(w.emerges[1].max.y, iv.max.y, "flat: emerged volume max y")
eq(iv.min.x, bd.x1 - ss.CONSTANTS.CUT_FILL_MARGIN, "flat: volume has cut/fill margin")
eq(iv.max.y >= r.build_bounds.max.y, true, "flat: volume covers blockout")
eq(iv.min.y <= r.build_bounds.min.y, true, "flat: volume covers cut/fill")

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
eq(r.build_bounds.max.y, 20 + 44, "median: top is ground + clearance")

-- Whole site sits at 30 (high but inside the window): ground is 30.
r = run(new_world({surface = function() return 30 end}), {x = 0, y = 31, z = 0}, nil)
eq(r.ground_y, 30, "relative to the player's level")

-- Range of exactly 8 is accepted, 9 rejected everywhere.
local function striped(delta)
	return function(x) return x % 2 == 0 and 20 or 20 + delta end
end
r = run(new_world({surface = striped(8)}), PLAYER, nil)
eq(r ~= nil, true, "range 8 accepted")
local fw = new_world({surface = striped(9)})
local r9, s9, d9, c9 = run(fw, PLAYER, SMALL)
eq(r9, nil, "range 9: rejected")
eq(c9, 1, "range 9: done once")
eq(d9.rejections.too_uneven ~= nil and d9.rejections.too_uneven > 0, true, "range 9: too_uneven counted")
eq(s9:find("too_uneven", 1, true) ~= nil, true, "range 9: summary names the reason")
eq(s9:find("Nothing was changed", 1, true) ~= nil, true, "range 9: summary says nothing changed")
eq(#fw.writes, 0, "range 9: no writes")

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
r9, s9, d9, c9 = run(lw, {x = 0, y = 21, z = 0}, SMALL)
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
		return (x >= lplan.bounds.x1 + 20 and x <= lplan.bounds.x1 + 22) and 10 or 20
	end,
	water = function(x, z)
		if x >= lplan.bounds.x1 + 20 and x <= lplan.bounds.x1 + 22 then return 20 end
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
r9, s9, d9 = run(uw, PLAYER, SMALL)
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
eq(ew.reads, 0, "emerge failure: nothing read after a failed emerge")

-- Plan failure: no emerge, counted, not accepted.
local pw = new_world({})
r9, s9, d9 = run(pw, PLAYER, {max_radius = 48, planner_opts = {max_attempts = 0}})
eq(r9, nil, "plan failure: not accepted")
eq(d9.rejections.plan_failed, 1, "plan failure: fails fast, counted once")
eq(d9.candidates_tried, 1, "plan failure: no scan of other candidates")
eq(#pw.emerges, 0, "plan failure: no emerge")
eq(s9:find("No town plan for seed", 1, true) ~= nil, true, "plan failure: summary")
eq(s9:find("no valid town plan", 1, true) ~= nil, true, "plan failure: planner reason surfaced")

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
eq(s9:find("within 160 nodes", 1, true) ~= nil, true, "exhaustion: summary names the radius")
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
	if p.y <= 20 then return {name = "default:water"} end
	return {name = "air"}
end
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
