-- Route consolidation and spacing along the combined pavement (issue #122).
-- Loaded by tests/run.lua:
--   loadfile("tests/route_consolidation_tests.lua")(eq, fails, planner, catalog)
-- Fixtures are hand-built plans (and one saved plan), so the checks do not
-- depend on the router. streets.narrow_gaps judges the exposed edges of the
-- combined road footprint; streets.wide_pavement counts road cells inside a
-- fully paved (STREET_WIDTH + 1) square, i.e. redundant parallel paving.
local eq, fails, planner, catalog = ...
local streets = dofile("src/streets.lua")

local base = assert(planner.landmark_profile(catalog.snapshot()))
local C = planner.resolve_constants({landmarks = base})
C.ENVELOPE = 64

local function R(x1, z1, x2, z2) return {x1 = x1, z1 = z1, x2 = x2, z2 = z2} end

-- Synthetic plan in a 64 x 64 envelope. `list` is {{x1, z1, x2, z2, kind?}}
-- street rectangles (a 4-wide rect is secondary unless kind says otherwise);
-- squares and the unused landmark sit out of the way at the far corner.
local function plan_of(list, opts)
	opts = opts or {}
	local ss = {}
	for i, q in ipairs(list) do
		local kind = q[5] or ((math.min(q[3] - q[1], q[4] - q[2]) + 1 == 4) and "secondary" or "principal")
		ss[i] = {id = i, kind = kind, rect = R(q[1], q[2], q[3], q[4]),
			axis = (q[4] - q[2] > q[3] - q[1]) and "z" or "x"}
	end
	return {
		envelope = R(0, 0, 63, 63),
		boundary = {rects = {opts.boundary or R(0, 0, 63, 49)}},
		sites = {
			parvis = {rect = R(60, 52, 63, 55), kind = "square"},
			market = opts.market and {rect = opts.market, kind = "square"}
				or {rect = R(60, 58, 63, 61), kind = "square"},
			cathedral = {rect = opts.cathedral or R(60, 60, 62, 62),
				approach = {pos = {x = 61, z = 59}, edge = R(61, 59, 61, 59)}},
			castle = {rect = R(58, 56, 59, 57)},
		},
		approaches = opts.approaches or {},
		streets = ss,
	}
end

local function wide(plan) return (streets.wide_pavement(plan, C)) end
local function narrow(plan) return streets.narrow_gaps(plan, C) end

-- The (position-only) runs of a verdict, to compare plans whose streets are
-- split differently.
local function shape(runs)
	local out = {}
	for _, r in ipairs(runs) do
		out[#out + 1] = ("%d,%d-%d,%d"):format(r.x1, r.z1, r.x2, r.z2)
	end
	table.sort(out)
	return table.concat(out, " ")
end

-- 1. Adjacent parallel routes are wide pavement; one corridor is not.
do
	eq(wide(plan_of({{20, 0, 24, 49}})), 0, "one corridor is not wide")
	eq(wide(plan_of({{20, 0, 24, 49}, {25, 0, 29, 49}})) > 0, true, "touching principals are wide")
	eq(wide(plan_of({{20, 0, 23, 49}, {24, 0, 27, 49}})) > 0, true, "touching secondaries are wide")
	eq(wide(plan_of({{20, 0, 24, 49}, {25, 0, 28, 49}})) > 0, true, "principal beside a secondary is wide")
	eq(wide(plan_of({{20, 0, 24, 49}, {26, 0, 30, 49}})), 0, "a one-node gap is not paving (spacing's job)")
	-- Equivalent pavement, one 10-wide rectangle, the same verdict.
	eq(wide(plan_of({{20, 0, 29, 49}})) > 0, true, "one wide rectangle is wide as well")
end

-- 2. Partial overlap: offset or only partly along the length.
do
	eq(wide(plan_of({{20, 0, 24, 49}, {22, 0, 26, 49}})) > 0, true, "offset overlap is wide")
	eq(wide(plan_of({{20, 0, 24, 30}, {25, 20, 29, 49}})) > 0, true, "side by side over part of their length")
	-- The wide cells are only where the roads run together.
	local plan = plan_of({{20, 0, 24, 30}, {25, 20, 29, 49}})
	local count, first = streets.wide_pavement(plan, C)
	eq(count, 10 * 11, "wide cells are the shared stretch")
	eq(first.z >= 20 and first.z <= 25, true, "first wide window lies in the shared stretch")
	-- A jog, a bend and a long lap joint are not wide (nothing 6x6 is paved).
	eq(wide(plan_of({{20, 0, 24, 20}, {20, 16, 40, 20}})), 0, "bend")
	eq(wide(plan_of({{0, 20, 40, 24}, {20, 0, 24, 40}})), 0, "crossing")
	eq(wide(plan_of({{0, 20, 63, 24}, {30, 25, 33, 49}})), 0, "T junction with a secondary")
end

-- 3. A real junction: exempt only close to the corner.
do
	-- Main road along z20..24, stem x30..33 below it, a landmark 4 east of the stem.
	local function t(lm_z2)
		return plan_of({{0, 20, 63, 24}, {30, 25, 33, 49}},
			{boundary = R(0, 0, 63, 49), cathedral = R(38, 25, 45, lm_z2)})
	end
	eq(shape(narrow(t(32))), "", "narrowness within one street width of the junction is exempt")
	local runs = narrow(t(40))
	eq(#runs, 1, "narrowness beyond the junction is reported")
	eq(runs[1] and runs[1].a1, 30, "the run starts where the exemption ends")
	eq(runs[1] and runs[1].a2, 40, "the run follows the landmark")
	-- The same landmark with no junction (the stem is a free-standing street
	-- from z25) is not exempt at its own end.
	local lone = plan_of({{30, 25, 33, 49}}, {cathedral = R(38, 25, 45, 32)})
	eq(shape(narrow(lone)), "33,25-33,32", "no junction, no exemption")
end

-- 4. Fragmented collinear routes get the verdict of the single rectangle.
do
	local lm = R(30, 10, 40, 40)
	local function with(list) return plan_of(list, {cathedral = lm}) end
	local whole = narrow(with({{20, 0, 24, 49}}))
	eq(#whole, 1, "the road beside the landmark is flagged")
	eq(whole[1] and whole[1].a1, 10, "flagged from the landmark's first row")
	eq(whole[1] and whole[1].a2, 40, "flagged to the landmark's last row")
	local pieces = {}
	for z = 0, 45, 5 do pieces[#pieces + 1] = {20, z, 24, z + 4} end
	local frag = with(pieces)
	eq(shape(narrow(frag)), shape(whole), "ten short fragments: same verdict (no exemption per piece)")
	eq(wide(frag), 0, "fragments are not wide")
	local overlapped = with({{20, 0, 24, 20}, {20, 15, 24, 35}, {20, 30, 24, 49}})
	eq(shape(narrow(overlapped)), shape(whole), "overlapping fragments: same verdict")
	eq(wide(overlapped), 0, "overlapping collinear fragments are not wide")
	-- Same cells, different splits, identical in every respect.
	eq(shape(narrow(with({{20, 0, 24, 49}}))), shape(narrow(with({{20, 0, 24, 25}, {20, 26, 24, 49}}))),
		"split in two: same verdict")
end

-- 5. A road too close to the boundary.
do
	local function edge(x1, x2) return plan_of({{x1, 0, x2, 49}}, {boundary = R(0, 0, 63, 49)}) end
	local close = narrow(edge(3, 7))
	eq(#close, 1, "three nodes from the edge is narrow")
	eq(close[1] and close[1].a1, 0, "the whole side is flagged, not just the middle")
	eq(close[1] and close[1].a2, 49, "to the last row")
	eq(#narrow(edge(9, 13)), 0, "one row from the edge passes")
	eq(#narrow(edge(8, 12)), 1, "one node less than a row fails")
	-- Hugging the edge in fragments is not saved by the fragment ends.
	local pieces = {}
	for z = 0, 45, 5 do pieces[#pieces + 1] = {3, z, 7, z + 4} end
	eq(shape(narrow(plan_of(pieces))), shape(close), "fragmented edge-hugging road: same verdict")
	-- A secondary 4-wide, same rule.
	eq(#narrow(plan_of({{3, 0, 6, 49}})), 1, "a secondary too close to the edge")
end

-- 6. Intentional squares, gate apron and exits are preserved.
do
	-- A road entering a square sideways forms no exposed edge at the contact.
	local sq = plan_of({{0, 22, 29, 26}}, {market = R(30, 20, 39, 29), boundary = R(0, 0, 63, 49)})
	eq(wide(sq), 0, "a square is not wide pavement")
	eq(#narrow(sq), 0, "road meeting a square")
	-- The gate apron next to a normal-width route is not wide pavement.
	local g = plan_of({{27, 0, 31, 30}}, {boundary = R(0, 0, 63, 49)})
	g.sites.castle = {rect = R(24, 36, 35, 45), gate_apron = R(26, 31, 31, 35),
		approach = {pos = {x = 29, z = 35}, edge = R(24, 35, 35, 35)}}
	eq(wide(g), 0, "gate apron is excluded from wide pavement")
	-- An exit transition: the entrance window grown by one street width is
	-- exempt, the road beyond it is not.
	local ex = plan_of({{0, 20, 40, 24}}, {boundary = R(0, 12, 63, 32),
		approaches = {{name = "a1", side = "-x", pos = {x = 0, z = 22}, edge = R(0, 20, 4, 24)}}})
	local runs = narrow(ex)
	eq(#runs, 2, "both sides of the road past the exit are narrow")
	for _, r in ipairs(runs) do
		eq(r.a1, 10, "exempt through the exit transition only")
		eq(r.a2, 40, "to the end of the road")
	end
end

-- 7. The saved pre-#122 plan (seed 99999): two adjacent pairs of secondary
-- streets run beside the castle (ids 17 + 20 and 18 + 19). The metric sees
-- both; one corridor per pair (the shared normal-width corridor) leaves no
-- wide pavement there, and the rest of the plan is unaffected.
do
	local saved = dofile("tests/route_consolidation_fixture.lua")
	local Cs = planner.resolve_constants({landmarks = base})
	local function subset(ids)
		local keep = {}
		for _, s in ipairs(saved.streets) do
			if ids[s.id] then keep[#keep + 1] = s end
		end
		return {envelope = saved.envelope, boundary = saved.boundary, sites = saved.sites,
			approaches = saved.approaches, streets = keep}
	end
	local function count(plan) return (streets.wide_pavement(plan, Cs)) end
	eq(count(saved) > 0, true, "the saved plan has redundant parallel paving")
	eq(count(subset({[8] = true, [17] = true, [20] = true})) > 0, true, "pair 17 + 20 is one 8-wide band")
	eq(count(subset({[8] = true, [18] = true, [19] = true})) > 0, true, "pair 18 + 19 is one 8-wide band")
	eq(count(subset({[8] = true, [17] = true, [18] = true})), 0, "one road per pair leaves no band")
end

-- 8. fill(): a route that would run beside an existing road is pulled into
-- the shared corridor. In this hand-built town the first approach enters at
-- z10..14, close to the second approach's road; without the router penalty
-- the two principals run side by side and the final gate rejects the attempt.
do
	local town = {
		envelope = R(0, 0, 79, 79),
		boundary = {rects = {R(0, 0, 59, 49)}},
		sites = {
			cathedral = {rect = R(2, 36, 12, 47), kind = "landmark",
				approach = {pos = {x = 7, z = 35}, edge = R(7, 35, 7, 35)}},
			castle = {rect = R(44, 36, 57, 47), kind = "landmark",
				approach = {pos = {x = 50, z = 35}, edge = R(50, 35, 50, 35)}},
			parvis = {rect = R(2, 14, 9, 25), kind = "square",
				approach = {pos = {x = 10, z = 20}, edge = R(10, 20, 10, 20)}},
			market = {rect = R(30, 20, 39, 29), kind = "square",
				approach = {pos = {x = 35, z = 25}, edge = R(35, 25, 35, 25)}},
		},
		approaches = {
			{name = "a1", side = "-x", pos = {x = 0, z = 12}, edge = R(0, 10, 4, 14)},
			{name = "a2", side = "+x", pos = {x = 59, z = 24}, edge = R(55, 22, 59, 26)},
		},
	}
	local rng = {int = function(a) return a end, pick = function(l) return l[1] end}
	local function consts(over)
		local c = planner.resolve_constants({landmarks = base})
		c.ENVELOPE, c.MAX_BLOCK_SCAN, c.MIN_BLOCKS, c.MAX_BLOCK_DEPTH = 80, 20, 1, 8
		for k, v in pairs(over or {}) do c[k] = v end
		return c
	end
	eq(consts().WIDE_PENALTY > 0, true, "the policy supplies a wide-pavement penalty")
	local plan, why = streets.fill(town, rng, consts())
	eq(plan ~= nil, true, "fill consolidates the routes: " .. tostring(why))
	if plan then
		eq(streets.wide_pavement(plan, consts()), 0, "no wide pavement after consolidation")
		eq(#streets.narrow_gaps(plan, consts()), 0, "no narrow run after consolidation")
		eq(#plan.blocks >= 1, true, "blocks are carved after consolidation")
	end
	local rejected, why2 = streets.fill(town, rng, consts({WIDE_PENALTY = 0}))
	eq(rejected, nil, "without the penalty the parallel routes are rejected")
	eq(tostring(why2):find("consolidated", 1, true) ~= nil, true, "gate reason")
end
