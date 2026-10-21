-- Street spacing / row depth tests (ticket #86). Loaded by tests/run.lua:
--   loadfile("tests/street_spacing_tests.lua")(eq, fails, planner, catalog)
-- Fixtures are hand-built plans, so the checks do not depend on the router.
local eq, fails, planner, catalog = ...
local streets = dofile("src/streets.lua")

local base = assert(planner.landmark_profile(catalog.snapshot()))

-- Derived depth policy: the lower median of the eligible entries' depth
-- (file Z side behind the street), not the smallest sample house.
do
	local depths = {}
	for _, e in pairs(base.content) do depths[#depths + 1] = e.size.z end
	table.sort(depths)
	eq(#depths, 15, "eligible ordinary entries")
	eq(depths[1], 7, "smallest depth is the demo house")
	eq(planner.row_depth(base), 9, "row depth is the lower median")
	-- At least half of the eligible entries fit a block this deep.
	local fit = 0
	for _, d in ipairs(depths) do if d <= 9 then fit = fit + 1 end end
	eq(fit * 2 >= #depths, true, "half of the catalog fits the row depth")
	eq(planner.row_depth({}), nil, "no content, no depth")
	eq(planner.row_depth({content = {a = {size = {z = 4}}, b = {size = {z = 10}}}}), 4,
		"lower median of two")
	local C = planner.resolve_constants({landmarks = base})
	eq(C.ROW_DEPTH, 9, "constant ROW_DEPTH")
	eq(C.ROAD_GAP, 18, "road to road needs two opposing rows")
	eq(C.SQUARE_GAP, 9, "square to road needs one row")
	eq(C.BOUNDARY_GAP, 9, "boundary gap is a named constant")
	eq(C.MIN_BLOCK_SIDE, 12, "minimum block side is the larger of row depth and #89 value")
	eq(planner.depth_policy({content = {a = {size = {z = 20}}}}).MIN_BLOCK_SIDE, 20,
		"a deeper catalog raises the minimum block side")
	local legacy = planner.resolve_constants({})
	eq(legacy.ROW_DEPTH, nil, "no policy without a profile")
	eq(legacy.MIN_BLOCK_SIDE, 8, "legacy block side unchanged")
	local over = planner.resolve_constants({landmarks = base, constants = {ROW_DEPTH = 12}})
	eq(over.ROW_DEPTH, 12, "explicit constant wins")
end

-- The reported shape with the current constants: parvis, 1 node, a 4-wide
-- road, 3 nodes, a 5-wide road, the town boundary.
local C = planner.resolve_constants({landmarks = base})
C.ENVELOPE = 64

local function fixture(parvis, secondary, principal, edge)
	return {
		envelope = {x1 = 0, z1 = 0, x2 = 63, z2 = 63},
		boundary = {rects = {{x1 = 0, z1 = 0, x2 = edge, z2 = 49}}},
		sites = {
			parvis = {rect = parvis, kind = "square"},
			market = {rect = {x1 = 60, z1 = 60, x2 = 61, z2 = 61}, kind = "square"},
			cathedral = {rect = {x1 = 60, z1 = 0, x2 = 62, z2 = 2}},
			castle = {rect = {x1 = 60, z1 = 10, x2 = 62, z2 = 12}},
		},
		streets = {
			{id = 1, kind = "secondary", axis = "z", rect = secondary},
			{id = 2, kind = "principal", axis = "z", rect = principal},
		},
	}
end

do
	-- parvis x 0..7, gap x 8, road x 9..12, gap x 13..15, road x 16..20 = edge.
	local bad = fixture({x1 = 0, z1 = 15, x2 = 7, z2 = 26},
		{x1 = 9, z1 = 0, x2 = 12, z2 = 49}, {x1 = 16, z1 = 0, x2 = 20, z2 = 49}, 20)
	local runs = streets.narrow_gaps(bad, C)
	local by_street = {0, 0}
	for _, r in ipairs(runs) do by_street[r.street] = by_street[r.street] + 1 end
	-- Secondary: parvis side (1 node) and principal side (3 nodes).
	eq(by_street[1], 2, "secondary has two narrow runs")
	-- Principal: the 3-node gap and the empty outer side at the boundary.
	eq(by_street[2], 2, "principal has two narrow runs")
	local parvis_run
	for _, r in ipairs(runs) do
		if r.street == 1 and r.a1 == 15 then parvis_run = r end
	end
	eq(parvis_run ~= nil and parvis_run.a2 == 26, true, "parvis gap run covers its face")

	-- The same sequence with derived gaps: one row from the parvis, two
	-- opposing rows between roads, one row to the boundary.
	local good = fixture({x1 = 0, z1 = 15, x2 = 7, z2 = 26},
		{x1 = 17, z1 = 0, x2 = 20, z2 = 49}, {x1 = 39, z1 = 0, x2 = 43, z2 = 49}, 52)
	eq(#streets.narrow_gaps(good, C), 0, "derived gaps pass")
	local apron_plan = fixture({x1 = 0, z1 = 15, x2 = 7, z2 = 26},
		{x1 = 17, z1 = 0, x2 = 20, z2 = 49}, {x1 = 39, z1 = 0, x2 = 43, z2 = 49}, 63)
	eq(#streets.narrow_gaps(apron_plan, C), 0, "far boundary leaves enough room without an apron")
	apron_plan.sites.castle.gate_apron = {x1 = 52, z1 = 20, x2 = 57, z2 = 24}
	local apron_runs = streets.narrow_gaps(apron_plan, C)
	local sees_apron = false
	for _, run in ipairs(apron_runs) do if run.street == 2 then sees_apron = true end end
	eq(sees_apron, true, "spacing metric treats the gate apron as pavement")

	-- Boundary exactly one row from a street passes, one node less is narrow.
	local edge_ok = fixture({x1 = 0, z1 = 15, x2 = 7, z2 = 26},
		{x1 = 17, z1 = 0, x2 = 20, z2 = 49}, {x1 = 39, z1 = 0, x2 = 43, z2 = 49}, 43 + 9)
	eq(#streets.narrow_gaps(edge_ok, C), 0, "one row to the edge passes")
	edge_ok.boundary.rects[1].x2 = 43 + 8
	eq(#streets.narrow_gaps(edge_ok, C), 1, "one node short of a row to the edge fails")

	-- Without the policy constants nothing is flagged.
	eq(#streets.narrow_gaps(bad, planner.resolve_constants({})), 0, "no policy, no runs")
end

-- Junctions and street ends are exempt: a street joining a road does not
-- count the ground beside the joint.
do
	local p = fixture({x1 = 0, z1 = 40, x2 = 7, z2 = 49},
		{x1 = 30, z1 = 0, x2 = 33, z2 = 49}, {x1 = 30, z1 = 0, x2 = 63, z2 = 4}, 63)
	p.boundary.rects[1] = {x1 = 0, z1 = 0, x2 = 63, z2 = 49}
	local runs = streets.narrow_gaps(p, C)
	for _, r in ipairs(runs) do eq(r.street ~= 1, true, "joined street has no narrow run") end
end

-- Stock plans: accepted layouts keep no narrow run, including around the
-- gate apron (which uses the square-like one-row gap rule), while the
-- same seeds planned without the policy do (it is not vacuous).
do
	local policy = planner.depth_policy(base)
	local civic = {cathedral = base.cathedral, castle = base.castle,
		city_hall = base.city_hall, jail = base.jail, services = base.services}
	local without_total = 0
	for _, seed in ipairs({1, 2, 3, 4, 5, 6}) do
		local plan = assert(planner.plan({x = 10, z = -30}, seed, {landmarks = base}))
			eq(#streets.narrow_gaps(plan, planner.resolve_constants({landmarks = base})), 0,
			"seed " .. seed .. " has no narrow run with gate apron")
		local plain = assert(planner.plan({x = 10, z = -30}, seed, {landmarks = civic}))
		local Cp = planner.resolve_constants({landmarks = civic})
		for k, v in pairs(policy) do Cp[k] = v end
		without_total = without_total + #streets.narrow_gaps(plain, Cp)
	end
	eq(without_total > 0, true, "plans without the policy do keep narrow runs")
end

-- streets.fill() level: a hand-built town where unconstrained secondaries
-- leave narrow runs. With the policy fill() shifts/shortens/rejects them and
-- the finished plan has no narrow run; without it the same town does.
do
	local function town(approach_z)
		return {
			envelope = {x1 = 0, z1 = 0, x2 = 79, z2 = 79},
			boundary = {rects = {{x1 = 0, z1 = 0, x2 = 59, z2 = 49}}},
			sites = {
				cathedral = {rect = {x1 = 2, z1 = 36, x2 = 12, z2 = 47}, kind = "landmark",
					approach = {pos = {x = 7, z = 35}, edge = {x1 = 7, z1 = 35, x2 = 7, z2 = 35}}},
				castle = {rect = {x1 = 44, z1 = 36, x2 = 57, z2 = 47}, kind = "landmark",
					approach = {pos = {x = 50, z = 35}, edge = {x1 = 50, z1 = 35, x2 = 50, z2 = 35}}},
				parvis = {rect = {x1 = 2, z1 = 14, x2 = 9, z2 = 25}, kind = "square",
					approach = {pos = {x = 10, z = 20}, edge = {x1 = 10, z1 = 20, x2 = 10, z2 = 20}}},
				market = {rect = {x1 = 30, z1 = 20, x2 = 39, z2 = 29}, kind = "square",
					approach = {pos = {x = 35, z = 25}, edge = {x1 = 35, z1 = 25, x2 = 35, z2 = 25}}},
			},
			approaches = {
				{name = "a1", side = "-x", pos = {x = 0, z = approach_z + 2},
					edge = {x1 = 0, z1 = approach_z, x2 = 4, z2 = approach_z + 4}},
				{name = "a2", side = "+x", pos = {x = 59, z = 24},
					edge = {x1 = 55, z1 = 22, x2 = 59, z2 = 26}},
			},
		}
	end
	local rng = {int = function(a) return a end, pick = function(l) return l[1] end}
	local function consts(over)
		local c = planner.resolve_constants({landmarks = base})
		c.ENVELOPE, c.MAX_BLOCK_SCAN, c.MIN_BLOCKS, c.MAX_BLOCK_DEPTH = 80, 20, 1, 8
		for k, v in pairs(over or {}) do c[k] = v end
		return c
	end
	local policy = consts()
	local plan, why = streets.fill(town(22), rng, consts())
	eq(plan ~= nil, true, "fill with policy plans: " .. tostring(why))
	if plan then
		eq(#streets.narrow_gaps(plan, policy), 0, "fill leaves no narrow run")
		for _, s in ipairs(plan.streets) do
			eq(s.rect.x1 >= 0 and s.rect.x2 <= 59, true, "street stays in the boundary")
		end
	end
	local off = consts()
	off.ROW_DEPTH = nil
	local plain = streets.fill(town(22), rng, off)
	eq(plain ~= nil and #streets.narrow_gaps(plain, policy) > 0, true,
		"without the policy fill keeps narrow runs")
	-- Router: a principal route that hugs the edge is penalised away; with no
	-- penalty the same town is rejected by the final gate.
	local hug, hug_why = streets.fill(town(4), rng, consts({NARROW_PENALTY = 0}))
	eq(hug, nil, "unpenalised edge-hugging route is rejected")
	eq(tostring(hug_why):find("too narrow", 1, true) ~= nil, true, "gate reason")
	local ok = streets.fill(town(4), rng, consts())
	eq(ok ~= nil and #streets.narrow_gaps(ok, policy) == 0, true,
		"penalised route plans without narrow runs")
end
