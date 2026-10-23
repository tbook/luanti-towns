-- Planner tests (ticket #12): boundary and civic sites, on the small synthetic
-- town of tests/small_town.lua (a 96-node envelope and a hand-made landmark
-- profile; the real-catalog planner is tested in tests/landmark_profile_tests.lua).
-- Loaded by tests/run.lua, which passes its check helpers:
--   loadfile("tests/planner_tests.lua")(eq, fails, planner)
local eq, fails, planner = ...
local small = dofile("tests/small_town.lua")(planner)

local function deep_equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do
		if not deep_equal(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

-- Plain numbers/strings/booleans/tables only; no metatables, no sharing.
local function data_only(v, seen)
	local t = type(v)
	if t == "number" or t == "string" or t == "boolean" then return true end
	if t ~= "table" or getmetatable(v) ~= nil then return false end
	seen = seen or {}
	if seen[v] then return false end
	seen[v] = true
	for k, x in pairs(v) do
		if type(k) ~= "string" and type(k) ~= "number" then return false end
		if not data_only(x, seen) then return false end
	end
	seen[v] = nil
	return true
end

local function key(x, z) return (x + 50000) * 100000 + (z + 50000) end

local function cell_set(plan)
	local set, n = {}, 0
	for _, r in ipairs(plan.boundary.rects) do
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do
				local k = key(x, z)
				if not set[k] then set[k] = true; n = n + 1 end
			end
		end
	end
	return set, n
end

local function rect_inside(set, r)
	for z = r.z1, r.z2 do
		for x = r.x1, r.x2 do
			if not set[key(x, z)] then return false end
		end
	end
	return true
end

local function rect_outside(set, r)
	for z = r.z1, r.z2 do
		for x = r.x1, r.x2 do
			if set[key(x, z)] then return false end
		end
	end
	return true
end

-- Chebyshev gap in free nodes (< 0 when overlapping).
local function rgap(a, b)
	return math.max(math.max(a.x1 - b.x2 - 1, b.x1 - a.x2 - 1),
		math.max(a.z1 - b.z2 - 1, b.z1 - a.z2 - 1))
end

local function connected(set, total, plan)
	local r = plan.boundary.rects[1]
	local start = {r.x1, r.z1}
	local seen, stack, n = {[key(start[1], start[2])] = true}, {start}, 0
	while #stack > 0 do
		local c = table.remove(stack)
		n = n + 1
		for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
			local x, z = c[1] + d[1], c[2] + d[2]
			local k = key(x, z)
			if set[k] and not seen[k] then
				seen[k] = true
				stack[#stack + 1] = {x, z}
			end
		end
	end
	return n == total
end

-- Independent feature check: no internal row/column gap below 12, and no
-- left/right/top/bottom extent step below 12.
local function features_ok(plan, set)
	local b = plan.bounds
	local function scan(lo1, hi1, lo2, hi2, at)
		local prevL, prevR
		for a = lo1, hi1 do
			local first, last
			for c = lo2, hi2 do
				if set[at(a, c)] then
					if last and c - last - 1 > 0 and c - last - 1 < 12 then return false end
					first = first or c
					last = c
				end
			end
			if prevL and first ~= prevL and math.abs(first - prevL) < 12 then return false end
			if prevR and last ~= prevR and math.abs(last - prevR) < 12 then return false end
			prevL, prevR = first, last
		end
		return true
	end
	return scan(b.z1, b.z2, b.x1, b.x2, function(z, x) return key(x, z) end)
		and scan(b.x1, b.x2, b.z1, b.z2, function(x, z) return key(x, z) end)
end

local function set_size(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end


-- Independent route check (does not use planner internals): chains of free
-- STREET_WIDTH-square windows, cathedral and castle footprints as obstacles, squares open.
-- Returns a table of reached window top-left keys, given a start window.
local function route_reach(plan, set, start)
	local function blocked(x, z)
		for _, name in ipairs({"cathedral", "castle"}) do
			local r = plan.sites[name].rect
			if x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 then return true end
		end
		return false
	end
	local memo = {}
	local function free(x, z)
		local k = key(x, z)
		local v = memo[k]
		if v == nil then
			v = true
			for zz = z, z + planner.CONSTANTS.STREET_WIDTH - 1 do
				for xx = x, x + planner.CONSTANTS.STREET_WIDTH - 1 do
					if not set[key(xx, zz)] or blocked(xx, zz) then v = false end
				end
			end
			memo[k] = v
		end
		return v
	end
	local seen = {}
	local sx, sz = start.x1, start.z1
	if not free(sx, sz) then return seen, free end
	seen[key(sx, sz)] = true
	local stack = {{sx, sz}}
	while #stack > 0 do
		local c = table.remove(stack)
		for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
			local x, z = c[1] + d[1], c[2] + d[2]
			local k = key(x, z)
			if not seen[k] and free(x, z) then
				seen[k] = true
				stack[#stack + 1] = {x, z}
			end
		end
	end
	return seen, free
end

local function covered(seen, pos)
	local sw = planner.CONSTANTS.STREET_WIDTH
	for z = pos.z - sw + 1, pos.z do
		for x = pos.x - sw + 1, pos.x do
			if seen[key(x, z)] then return true end
		end
	end
	return false
end

local function check_routes(plan, set, label)
	local a1, a2 = plan.approaches[1], plan.approaches[2]
	local function window(a)
		local e, k = a.edge, planner.CONSTANTS.STREET_WIDTH - 1
		if a.side == "-z" then return {x1 = e.x1, z1 = e.z1, x2 = e.x2, z2 = e.z1 + k} end
		if a.side == "+z" then return {x1 = e.x1, z1 = e.z2 - k, x2 = e.x2, z2 = e.z2} end
		if a.side == "-x" then return {x1 = e.x1, z1 = e.z1, x2 = e.x1 + k, z2 = e.z2} end
		return {x1 = e.x2 - k, z1 = e.z1, x2 = e.x2, z2 = e.z2}
	end
	local w1, w2 = window(a1), window(a2)
	eq(w1.x2 < w2.x1 or w2.x2 < w1.x1 or w1.z2 < w2.z1 or w2.z2 < w1.z1, true,
		label .. " approach windows disjoint")
	local seen = route_reach(plan, set, w1)
	eq(seen[key(w1.x1, w1.z1)] == true, true, label .. " approach 1 window free")
	eq(seen[key(w2.x1, w2.z1)] == true, true, label .. " approach 2 reachable")
	for _, name in ipairs({"market", "parvis", "cathedral", "castle"}) do
		eq(covered(seen, plan.sites[name].approach.pos), true,
			label .. " " .. name .. " approach pos reachable")
	end
end

local OPPOSITE = {["-z"] = "+z", ["+z"] = "-z", ["-x"] = "+x", ["+x"] = "-x"}

-- The default run checks a small seed set (per-plan structure, routes,
-- determinism, translation); TOWNS_TEST_FULL=1 sweeps 38 seeds and also
-- checks variety across them (distinct layouts, all cathedral sides, ...).
local FULL = os.getenv("TOWNS_TEST_FULL") == "1"
local seeds = {}
if FULL then
	for i = 1, 30 do seeds[#seeds + 1] = i end
	for _, s in ipairs({0, -7, 99999, 7919, 123456789, 536870912, 1073741823, -1073741823}) do
		seeds[#seeds + 1] = s
	end
else
	seeds = {1, 2, 3, 4, 0, -1073741823}
end
local OTHER_CENTER_EVERY = FULL and 8 or 3
local centers = {{x = 0, z = 0}, {x = 1000, z = -2000}, {x = -317, z = 4096}}

local sig_bounds, sig_layout, cath_sides, castle_sides, castle_gaps = {}, {}, {}, {}, {}
local plans_checked = 0
local expected_plans = 0
for ci, c in ipairs(centers) do
	-- Every seed at the first centre; a subset at the others.
	for si, seed in ipairs(seeds) do
		if ci == 1 or si % OTHER_CENTER_EVERY == 0 then
		expected_plans = expected_plans + 1
		local label = ("seed %d centre %d"):format(seed, ci)
		local plan, reason = small.plan(c, seed)
		eq(plan ~= nil, true, label .. " planned (" .. tostring(reason) .. ")")
		if plan then
			plans_checked = plans_checked + 1
			if ci == 1 and si % 4 == 0 then
				local again = small.plan({x = c.x, z = c.z}, seed)
				eq(deep_equal(plan, again), true, label .. " deterministic")
			end
			eq(data_only(plan), true, label .. " data only")
			eq(plan.seed, seed, label .. " seed")
			eq(plan.center.x, c.x, label .. " centre x")
			eq(plan.center.z, c.z, label .. " centre z")
			eq(#plan.streets > 0 and #plan.blocks > 0 and #plan.frontage > 0, true,
				label .. " streets, blocks and frontage filled")

			local set, total = cell_set(plan)
			check_routes(plan, set, label)
			eq(small.validate(plan), true, label .. " validates")
			local b, env = plan.bounds, plan.envelope
			eq(b.x1 >= env.x1 and b.x2 <= env.x2 and b.z1 >= env.z1 and b.z2 <= env.z2,
				true, label .. " bounds inside envelope")
			local x1, z1, x2, z2 = math.huge, math.huge, -math.huge, -math.huge
			for _, r in ipairs(plan.boundary.rects) do
				x1, z1 = math.min(x1, r.x1), math.min(z1, r.z1)
				x2, z2 = math.max(x2, r.x2), math.max(z2, r.z2)
			end
			eq(x1 == b.x1 and z1 == b.z1 and x2 == b.x2 and z2 == b.z2, true,
				label .. " exact bounds")
			eq(plan.width, b.x2 - b.x1 + 1, label .. " width")
			eq(plan.depth, b.z2 - b.z1 + 1, label .. " depth")
			eq(math.max(plan.width, plan.depth) >= small.constants.MIN_LONG_SPAN, true, label .. " broad")
			eq(math.min(plan.width, plan.depth) >= small.constants.MIN_SHORT_SPAN, true, label .. " not tiny")
			eq(math.abs(plan.width - plan.depth) >= 12, true, label .. " non-square")
			eq(total < plan.width * plan.depth * 0.9, true, label .. " stepped, not a rectangle")
			eq(#plan.boundary.rects >= 2, true, label .. " multiple rects")
			eq(connected(set, total, plan), true, label .. " boundary connected")
			eq(features_ok(plan, set), true, label .. " no small notches or steps")
			eq(set[key(c.x, c.z)] == true, true, label .. " centre inside boundary")

			eq(#plan.site_order, 4, label .. " site count")
			for _, name in ipairs(plan.site_order) do
				local s = plan.sites[name]
				eq(s.name, name, label .. " " .. name .. " name")
				eq(rect_inside(set, s.rect), true, label .. " " .. name .. " contained")
				eq(s.size.x, s.rect.x2 - s.rect.x1 + 1, label .. " " .. name .. " size x")
				eq(s.size.z, s.rect.z2 - s.rect.z1 + 1, label .. " " .. name .. " size z")
				eq(s.facing.x * s.facing.x + s.facing.z * s.facing.z, 1,
					label .. " " .. name .. " facing")
				local e, p = s.approach.edge, s.approach.pos
				eq(e.x1 <= e.x2 and e.z1 <= e.z2, true, label .. " " .. name .. " approach edge")
				eq(p.x >= e.x1 and p.x <= e.x2 and p.z >= e.z1 and p.z <= e.z2,
					true, label .. " " .. name .. " approach pos on edge")
				eq(rgap(e, s.rect), 0, label .. " " .. name .. " approach touches site")
			end
			local cath, parvis, market, castle = plan.sites.cathedral, plan.sites.parvis,
				plan.sites.market, plan.sites.castle

			-- No overlaps; separate sites leave route room.
			local names = plan.site_order
			for i = 1, #names do
				for j = i + 1, #names do
					local g = rgap(plan.sites[names[i]].rect, plan.sites[names[j]].rect)
					if names[i] == "cathedral" and names[j] == "parvis" then
						eq(g, 0, label .. " cathedral/parvis touch")
					else
						eq(g >= planner.CONSTANTS.STREET_WIDTH, true, label .. " " .. names[i] .. "/" .. names[j] .. " gap")
					end
				end
			end

			-- Cathedral/parvis adjacency on the entrance side.
			local cr, pr = cath.rect, parvis.rect
			eq(parvis.facing.x, cath.facing.x, label .. " parvis facing x")
			eq(parvis.facing.z, cath.facing.z, label .. " parvis facing z")
			eq(cath.parvis, "parvis", label .. " cathedral parvis ref")
			-- The door is recessed behind the edge of the entrance side.
			local back = cath.door.recess
			if cath.side == "-z" then
				eq(pr.z2, cr.z1 - 1, label .. " parvis -z adjacent")
				eq(cath.entrance.z, cr.z1 + back, label .. " entrance behind the edge")
			elseif cath.side == "+z" then
				eq(pr.z1, cr.z2 + 1, label .. " parvis +z adjacent")
				eq(cath.entrance.z, cr.z2 - back, label .. " entrance behind the edge")
			elseif cath.side == "-x" then
				eq(pr.x2, cr.x1 - 1, label .. " parvis -x adjacent")
				eq(cath.entrance.x, cr.x1 + back, label .. " entrance behind the edge")
			else
				eq(pr.x1, cr.x2 + 1, label .. " parvis +x adjacent")
				eq(cath.entrance.x, cr.x2 - back, label .. " entrance behind the edge")
			end
			local PW, PD = planner.CONSTANTS.PARVIS_WIDTH, planner.CONSTANTS.PARVIS_FRONT_DEPTH
			if cath.side == "-z" or cath.side == "+z" then
				eq(pr.x2 - pr.x1 + 1, PW, label .. " parvis width")
				eq(pr.z2 - pr.z1 + 1, PD, label .. " parvis depth")
				eq(pr.x1, cath.entrance.x - math.floor(PW / 2), label .. " parvis centred on the door")
			else
				eq(pr.z2 - pr.z1 + 1, PW, label .. " parvis width")
				eq(pr.x2 - pr.x1 + 1, PD, label .. " parvis depth")
				eq(pr.z1, cath.entrance.z - math.floor(PW / 2), label .. " parvis centred on the door")
			end
			eq(cath.approach.side, cath.side, label .. " cathedral approach side")

			-- Market separate and near the centre.
			local mx = (market.rect.x1 + market.rect.x2) / 2
			local mz = (market.rect.z1 + market.rect.z2) / 2
			eq(math.abs(mx - c.x) <= 13 and math.abs(mz - c.z) <= 13, true,
				label .. " market near centre")

			-- Castle touches (or closely follows) an outer edge.
			local o = castle.outer_side
			eq(castle.edge_gap >= 0 and castle.edge_gap <= 2, true, label .. " castle gap range")
			local function row(d)
				local r = castle.rect
				if o == "-z" then return {x1 = r.x1, z1 = r.z1 - d, x2 = r.x2, z2 = r.z1 - d} end
				if o == "+z" then return {x1 = r.x1, z1 = r.z2 + d, x2 = r.x2, z2 = r.z2 + d} end
				if o == "-x" then return {x1 = r.x1 - d, z1 = r.z1, x2 = r.x1 - d, z2 = r.z2} end
				return {x1 = r.x2 + d, z1 = r.z1, x2 = r.x2 + d, z2 = r.z2}
			end
			for d = 1, castle.edge_gap do
				eq(rect_inside(set, row(d)), true, label .. " castle edge row inside")
			end
			eq(rect_outside(set, row(castle.edge_gap + 1)), true, label .. " castle edge outside")
			eq(castle.side, OPPOSITE[o], label .. " castle faces inward")

			-- Boundary approaches.
			eq(#plan.approaches, 2, label .. " approaches")
			eq(plan.approaches[1].side ~= plan.approaches[2].side, true,
				label .. " distinct approach sides")
			for _, a in ipairs(plan.approaches) do
				eq(rect_inside(set, a.edge), true, label .. " approach on boundary")
				local ex, ez = a.edge.x2 - a.edge.x1 + 1, a.edge.z2 - a.edge.z1 + 1
				eq(math.max(ex, ez), planner.CONSTANTS.STREET_WIDTH, label .. " approach width")
				eq(math.min(ex, ez), 1, label .. " approach depth")
				for _, name in ipairs(names) do
					eq(rgap(a.edge, plan.sites[name].rect) >= 0, true,
						label .. " approach clear of " .. name)
				end
			end

			if ci == 1 then
				sig_bounds[plan.width .. "x" .. plan.depth] = true
				local parts = {}
				for _, r in ipairs(plan.boundary.rects) do
					parts[#parts + 1] = ("%d,%d,%d,%d"):format(r.x1, r.z1, r.x2, r.z2)
				end
				parts[#parts + 1] = cath.rect.x1 .. "," .. cath.rect.z1 .. cath.side
				parts[#parts + 1] = castle.rect.x1 .. "," .. castle.rect.z1 .. castle.outer_side
				sig_layout[table.concat(parts, ";")] = true
				cath_sides[cath.side] = true
				castle_sides[castle.outer_side] = true
				castle_gaps[castle.edge_gap] = true
			end
		end
		end
	end
end

-- Regression: a castle once filled an arm so its door had no street-wide
-- approach (reviewer fuzz repro).
do
	local c = {x = -645, z = -195}
	for _, seed in ipairs(FULL and {45000135, 45, 48, 67, 75, 76, 87, 89, 107, 111}
			or {45000135, 48, 111}) do
		local plan = small.plan(c, seed)
		eq(plan ~= nil, true, "regression seed " .. seed .. " planned")
		if plan then
			local set = cell_set(plan)
			check_routes(plan, set, "regression seed " .. seed)
		end
	end
end

eq(plans_checked, expected_plans, "all fixed seeds planned")
if FULL then
	eq(set_size(sig_layout), #seeds, "every seed gives a distinct layout")
	eq(set_size(sig_bounds) >= 20, true, "varied bounding boxes")
	eq(set_size(cath_sides), 4, "all four cathedral entrance sides occur")
	eq(set_size(castle_sides) >= 3, true, "castle on varied edges")
	eq(castle_gaps[0], true, "castle touching the edge occurs")
else
	eq(set_size(sig_layout), #seeds, "every seed gives a distinct layout")
end

-- The centre translates the layout without changing it.
do
	local a = small.plan({x = 0, z = 0}, 17)
	local b = small.plan({x = 250, z = -90}, 17)
	local function norm(p, c)
		local out = {}
		local function add(r)
			out[#out + 1] = ("%d,%d,%d,%d"):format(r.x1 - c.x, r.z1 - c.z, r.x2 - c.x, r.z2 - c.z)
		end
		for _, r in ipairs(p.boundary.rects) do add(r) end
		add(p.bounds)
		for _, name in ipairs(p.site_order) do
			local s = p.sites[name]
			add(s.rect)
			add(s.approach.edge)
			out[#out + 1] = (s.approach.pos.x - c.x) .. ":" .. (s.approach.pos.z - c.z)
			out[#out + 1] = s.side
		end
		for _, a in ipairs(p.approaches) do
			add(a.edge)
			out[#out + 1] = a.side .. (a.pos.x - c.x) .. ":" .. (a.pos.z - c.z)
		end
		return table.concat(out, ";")
	end
	eq(norm(a, {x = 0, z = 0}), norm(b, {x = 250, z = -90}), "same seed, translated centre")
	eq(deep_equal(a, small.plan({x = 0, z = 0}, 18)), false, "different seed differs")
end

-- Invalid inputs fail clearly.
fails(function() planner.plan({x = 0, z = 0}, nil) end, "seed must be an integer", "nil seed")
fails(function() planner.plan({x = 0, z = 0}, 1.5) end, "seed must be an integer", "fractional seed")
fails(function() planner.plan({x = 0, z = 0}, "7") end, "seed must be an integer", "string seed")
fails(function() planner.plan({x = 0, z = 0}, 0 / 0) end, "seed must be an integer", "NaN seed")
fails(function() planner.plan({x = 0, z = 0}, math.huge) end, "seed must be an integer", "inf seed")
fails(function() planner.plan({x = 0, z = 0}, 2 ^ 60) end, "seed must be an integer", "huge seed")
fails(function() planner.plan({x = 0, z = 0}, 2147483647) end, "seed must be an integer", "seed past 2^30")
fails(function() planner.plan({x = 0, z = 0}, -1073741824) end, "seed must be an integer", "seed past -2^30")
fails(function() planner.plan(nil, 1) end, "site_center", "nil centre")
fails(function() planner.plan({x = 1}, 1) end, "site_center", "centre missing z")
fails(function() planner.plan({x = 1.5, z = 0}, 1) end, "site_center", "fractional centre")
fails(function() planner.plan({x = 0, z = "3"}, 1) end, "site_center", "string centre coord")
fails(function() planner.plan({x = 40000, z = 0}, 1) end, "site_center", "centre out of world")
fails(function() planner.plan("0,0", 1) end, "site_center", "non-table centre")
fails(function() small.plan({x = 0, z = 0}, 1, {max_attempts = -1}) end,
	"max_attempts", "bad max_attempts")
fails(function() small.plan({x = 0, z = 0}, 1, {constants = {NOPE = 1}}) end,
	"unknown constant", "unknown constant")
-- Medieval planning needs the catalog-derived landmark profile.
fails(function() planner.plan({x = 0, z = 0}, 1) end, "opts.landmarks", "no opts")
fails(function() planner.plan({x = 0, z = 0}, 1, {}) end, "opts.landmarks", "no landmark profile")
fails(function() planner.plan({x = 0, z = 0}, 1, {town_type = "medieval"}) end, "opts.landmarks",
	"medieval needs a profile")
fails(function() planner.plan({x = 0, z = 0}, 1, "x") end, "opts must be a table", "non-table opts")

-- Exhausted retries return nil plus a useful reason.
do
	local plan, reason, detail = small.plan({x = 0, z = 0}, 5, {max_attempts = 0})
	eq(plan, nil, "zero budget plan")
	eq(type(reason), "string", "zero budget reason is a string")
	eq(reason:find("no valid town plan for seed 5 after 0 attempts", 1, true) ~= nil, true,
		"zero budget message")
	eq(detail.code, "retries_exhausted", "zero budget code")
	eq(detail.attempts, 0, "zero budget attempts")

	-- An impossible constant (a boundary as wide as the whole envelope)
	-- exhausts a real budget and names the failing stage.
	local extra = {max_attempts = 6, constants = {MIN_LONG_SPAN = 96, MIN_SHORT_SPAN = 96}}
	plan, reason, detail = small.plan({x = 0, z = 0}, 5, extra)
	eq(plan, nil, "impossible boundary plan")
	eq(detail.code, "retries_exhausted", "impossible boundary code")
	eq(detail.attempts, 6, "impossible boundary attempts")
	local total = 0
	for _, v in pairs(detail.rejections) do total = total + v end
	eq(total, 6, "every attempt accounted for")
	eq((detail.rejections.boundary or 0) > 0, true, "boundary stage reported")
	eq(reason:find("boundary x", 1, true) ~= nil, true, "reason names boundary stage")
	eq(reason:find("after 6 attempts", 1, true) ~= nil, true, "reason names budget")
	local _, reason2 = small.plan({x = 0, z = 0}, 5, extra)
	eq(reason2, reason, "failure is deterministic")
	-- Caller options never leak into later calls.
	eq(small.plan({x = 0, z = 0}, 5) ~= nil, true, "defaults unaffected by opts")
end

-- ASCII renderer.
do
	local plan = small.plan({x = 0, z = 0}, 3)
	local text = planner.render(plan)
	eq(text:find("seed 3 center (0,0)", 1, true) ~= nil, true, "render header")
	for _, ch in ipairs({"C", "p", "M", "K", "A", "+", "e", "."}) do
		eq(text:find(ch, 1, true) ~= nil, true, "render has " .. ch)
	end
	local lines = 0
	for _ in text:gmatch("[^\n]+") do lines = lines + 1 end
	eq(lines, plan.depth + 1, "render line count")
	eq(planner.render(plan), text, "render deterministic")
end

-- Seeds that used to alias (7919 vs 2147483647) and the range extremes give
-- pairwise distinct layouts.
do
	local list = FULL and {7919, 0, 1, -1, 7920, 1073741823, -1073741823, 1073741823 - 7919,
		536870911, -536870911} or {7919, 7920, 1073741823, 1073741823 - 7919}
	local sigs, n = {}, 0
	for _, seed in ipairs(list) do
		local plan = small.plan({x = 0, z = 0}, seed)
		eq(plan ~= nil, true, "alias seed " .. seed .. " planned")
		if plan then
			local parts = {}
			for _, r in ipairs(plan.boundary.rects) do
				parts[#parts + 1] = ("%d,%d,%d,%d"):format(r.x1, r.z1, r.x2, r.z2)
			end
			for _, name in ipairs(plan.site_order) do
				local r = plan.sites[name].rect
				parts[#parts + 1] = ("%d,%d"):format(r.x1, r.z1)
			end
			sigs[table.concat(parts, ";")] = true
			n = n + 1
		end
	end
	eq(set_size(sigs), n, "aliasing-prone seeds give distinct layouts")
end

-- Validator rejects bad plans. Hand-built plan in a 96-node envelope at the
-- origin (centre 48,48): 60x40 boundary, cathedral wall on the right with
-- `wall_top` as its far Z edge, castle on the -Z edge, market near centre.
do
	local K = {MIN_LONG_SPAN = 50, MIN_SHORT_SPAN = 40, MAX_FILL = 1.0}
	local function R(x1, z1, x2, z2) return {x1 = x1, z1 = z1, x2 = x2, z2 = z2} end
	local function site(name, kind, r, side, extra)
		local e
		if side == "-z" then e = R(r.x1, r.z1 - 1, r.x2, r.z1 - 1)
		elseif side == "+z" then e = R(r.x1, r.z2 + 1, r.x2, r.z2 + 1)
		elseif side == "-x" then e = R(r.x1 - 1, r.z1, r.x1 - 1, r.z2)
		else e = R(r.x2 + 1, r.z1, r.x2 + 1, r.z2) end
		local s = {name = name, kind = kind, rect = r, side = side,
			size = {x = r.x2 - r.x1 + 1, z = r.z2 - r.z1 + 1},
			approach = {side = side, edge = e,
				pos = {x = e.x1 + math.floor((e.x2 - e.x1) / 2),
					z = e.z1 + math.floor((e.z2 - e.z1) / 2)}}}
		local F = {["-z"] = {0, -1, 0}, ["+z"] = {0, 1, 180}, ["-x"] = {-1, 0, 90}, ["+x"] = {1, 0, 270}}
		s.facing = {x = F[side][1], z = F[side][2]}
		s.rotation = F[side][3]
		if kind == "landmark" then
			local ent = {x = s.approach.pos.x, z = s.approach.pos.z}
			if side == "-z" then ent.z = r.z1 elseif side == "+z" then ent.z = r.z2
			elseif side == "-x" then ent.x = r.x1 else ent.x = r.x2 end
			s.entrance = ent
			s.door = {recess = 0, rise = 0, outside = {x = ent.x + s.facing.x, z = ent.z + s.facing.z}}
		end
		for k, v in pairs(extra or {}) do s[k] = v end
		return s
	end
	local function build(wall_top)
		local cath = R(60, 28, 66, wall_top)
		-- The parvis is PARVIS_WIDTH x PARVIS_FRONT_DEPTH, centred on the door.
		local lat = 28 + math.floor((wall_top - 28) / 2)
		local PW, PD = planner.CONSTANTS.PARVIS_WIDTH, planner.CONSTANTS.PARVIS_FRONT_DEPTH
		local plan = {
			seed = 1, center = {x = 48, z = 48}, envelope = R(0, 0, 95, 95),
			bounds = R(20, 28, 79, 67), width = 60, depth = 40,
			boundary = {rects = {R(20, 28, 79, 67)}},
			site_order = {"cathedral", "parvis", "market", "castle"},
			sites = {
				cathedral = site("cathedral", "landmark", cath, "+x", {parvis = "parvis"}),
				parvis = site("parvis", "square",
					R(67, lat - math.floor(PW / 2), 66 + PD, lat - math.floor(PW / 2) + PW - 1), "+x"),
				market = site("market", "square", R(36, 42, 46, 52), "+x"),
				castle = site("castle", "landmark", R(22, 28, 40, 35), "+z",
					{outer_side = "-z", edge_gap = 0}),
			},
			approaches = {
				{name = "approach_1", side = "-x", edge = R(20, 44, 20, 43 + planner.CONSTANTS.STREET_WIDTH), pos = {x = 20, z = 46}},
				{name = "approach_2", side = "+x", edge = R(79, 44, 79, 43 + planner.CONSTANTS.STREET_WIDTH), pos = {x = 79, z = 46}},
			},
			streets = {}, blocks = {}, frontage = {},
		}
		return plan
	end
	local ok, why = small.validate(build(55), K)
	-- Site/boundary/route checks pass; a plan with no streets is rejected.
	eq(ok, nil, "hand-built plan without streets rejected")
	eq(tostring(why):find("no streets", 1, true) ~= nil, true,
		"no-streets reason: " .. tostring(why))

	ok, why = small.validate(build(67), K)
	eq(ok, nil, "wall closes the route")
	eq(tostring(why):find("not connected by a street-wide route", 1, true) ~= nil, true,
		"blocked route reason: " .. tostring(why))

	-- Overlapping sites.
	local p = build(55)
	p.sites.market = site("market", "square", R(50, 40, 62, 50), "+x")
	ok, why = small.validate(p, K)
	eq(ok, nil, "overlapping sites rejected")
	eq(tostring(why):find("overlap", 1, true) ~= nil, true, "overlap reason: " .. tostring(why))

	-- Site outside the boundary.
	p = build(55)
	p.sites.castle = site("castle", "landmark", R(22, 20, 40, 27), "+z", {outer_side = "-z", edge_gap = 0})
	ok, why = small.validate(p, K)
	eq(ok, nil, "site outside boundary rejected")
	eq(tostring(why):find("not contained", 1, true) ~= nil, true, "containment reason: " .. tostring(why))

	-- Castle door blocked: moved far from the edge with no door room.
	p = build(55)
	p.approaches[2].edge = R(79, 44, 79, 49)
	p.approaches[1].edge = R(79, 40, 79, 45)
	p.approaches[1].side = "+x"
	ok, why = small.validate(p, K)
	eq(ok, nil, "same-side approaches rejected")

	-- Cut boundary: disconnected.
	p = build(55)
	p.boundary.rects = {R(20, 28, 40, 67), R(60, 28, 79, 67)}
	ok, why = small.validate(p, K)
	eq(ok, nil, "disconnected boundary rejected")

	-- Garbage in; no internal file:line text leaks.
	ok, why = small.validate({seed = 1, center = {x = 0, z = 0}, envelope = {x1 = -48, z1 = -48, x2 = 47, z2 = 47}})
	eq(ok, nil, "malformed plan rejected")
	eq(planner.validate({}), nil, "empty plan rejected")
	eq(planner.validate("x"), nil, "non-table plan rejected")
	eq(tostring(why):find("malformed", 1, true) ~= nil, true, "malformed reason")
	eq(tostring(why):find("planner.lua", 1, true) == nil, true, "no source location in reason: " .. tostring(why))
end

-- Schema fields consumers read are validated (mutations of a real plan).
do
	local function copy(v)
		if type(v) ~= "table" then return v end
		local o = {}
		for k, x in pairs(v) do o[k] = copy(x) end
		return o
	end
	local base = small.plan({x = 10, z = -20}, 31)
	eq(small.validate(base), true, "mutation base validates")
	local function bad(label, fn)
		local p = copy(base)
		fn(p)
		local ok, why = small.validate(p)
		eq(ok, nil, "validate rejects: " .. label)
		eq(type(why), "string", "validate gives reason: " .. label)
	end
	bad("approach pos at centre", function(p) p.approaches[1].pos = {x = p.center.x, z = p.center.z} end)
	bad("approach pos off by one", function(p) p.approaches[2].pos.x = p.approaches[2].pos.x + 1 end)
	bad("approach name", function(p) p.approaches[1].name = "x" end)
	bad("castle entrance (0,0)", function(p) p.sites.castle.entrance = {x = 0, z = 0} end)
	bad("cathedral entrance moved", function(p) p.sites.cathedral.entrance.x = p.sites.cathedral.entrance.x + 1 end)
	bad("square with entrance", function(p) p.sites.market.entrance = {x = 0, z = 0} end)
	bad("castle rotation", function(p) p.sites.castle.rotation = (p.sites.castle.rotation + 90) % 360 end)
	bad("castle facing", function(p) p.sites.castle.facing = {x = -p.sites.castle.facing.x, z = -p.sites.castle.facing.z} end)
	bad("size {1,1}", function(p) p.sites.castle.size = {x = 1, z = 1} end)
	bad("kind", function(p) p.sites.market.kind = "landmark" end)
	bad("cathedral parvis ref", function(p) p.sites.cathedral.parvis = "market" end)
	bad("site_order empty", function(p) p.site_order = {} end)
	bad("site_order swapped", function(p) p.site_order = {"parvis", "cathedral", "market", "castle"} end)
	bad("seed string", function(p) p.seed = "a" end)
	bad("seed fractional", function(p) p.seed = 1.5 end)
	bad("seed out of range", function(p) p.seed = 2 ^ 31 end)
	bad("envelope shifted", function(p)
		local e = p.envelope
		e.x1, e.x2 = e.x1 + 1, e.x2 + 1
	end)
	bad("centre moved", function(p) p.center.x = p.center.x + 1 end)
	bad("width wrong", function(p) p.width = p.width + 1 end)
end

-- Seed contract and the LCG fixed point (seed 70894448 used to lock up).
eq(planner.SEED_LIMIT, 1073741823, "SEED_LIMIT export")
eq(planner.check_seed(0), true, "check_seed ok")
eq(planner.check_seed(planner.SEED_LIMIT), true, "check_seed limit ok")
eq(planner.check_seed(-planner.SEED_LIMIT), true, "check_seed -limit ok")
do
	local ok, msg = planner.check_seed(planner.SEED_LIMIT + 1)
	eq(ok, nil, "check_seed past limit")
	eq(msg:find("between -1073741823 and 1073741823", 1, true) ~= nil, true, "check_seed message")
	eq(planner.check_seed("1"), nil, "check_seed string")
	eq(planner.check_seed(0.5), nil, "check_seed fractional")
	eq(planner.check_seed(nil), nil, "check_seed nil")
end
do
	local sigs = {}
	local function sig(plan)
		local parts = {}
		for _, r in ipairs(plan.boundary.rects) do
			parts[#parts + 1] = ("%d,%d,%d,%d"):format(r.x1 - plan.center.x, r.z1 - plan.center.z,
				r.x2 - plan.center.x, r.z2 - plan.center.z)
		end
		for _, name in ipairs(plan.site_order) do
			local r = plan.sites[name].rect
			parts[#parts + 1] = ("%d,%d"):format(r.x1 - plan.center.x, r.z1 - plan.center.z)
		end
		return table.concat(parts, ";")
	end
	for _, c in ipairs({{x = 0, z = 0}, {x = -800, z = 1234}}) do
		local first
		for _, seed in ipairs(FULL and {70894448, 70894447, 70894449} or {70894448}) do
			local plan, why = small.plan(c, seed)
			eq(plan ~= nil, true, "fixed-point seed " .. seed .. " planned: " .. tostring(why))
			if plan then
				eq(small.validate(plan), true, "fixed-point seed " .. seed .. " validates")
				if c.x == 0 then sigs[sig(plan)] = true end
			end
		end
	end
	if FULL then eq(set_size(sigs), 3, "fixed-point seed layout distinct from its neighbours") end
end
