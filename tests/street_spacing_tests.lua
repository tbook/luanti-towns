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
	eq(#depths, 11, "eligible ordinary entries")
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
	eq(C.MIN_BLOCK_SIDE, 9, "minimum block side follows the row depth")
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

-- Stock plans: the accepted layouts keep no narrow run (gate), while the
-- same seeds planned without the policy do (it is not vacuous).
do
	local policy = planner.depth_policy(base)
	local civic = {cathedral = base.cathedral, castle = base.castle,
		city_hall = base.city_hall, jail = base.jail, services = base.services}
	local without_total = 0
	for _, seed in ipairs({1, 2, 3, 4, 5, 6}) do
		local plan = assert(planner.plan({x = 10, z = -30}, seed, {landmarks = base}))
		eq(#streets.narrow_gaps(plan, planner.resolve_constants({landmarks = base})), 0,
			"seed " .. seed .. " has no narrow run")
		local plain = assert(planner.plan({x = 10, z = -30}, seed, {landmarks = civic}))
		local Cp = planner.resolve_constants({landmarks = civic})
		for k, v in pairs(policy) do Cp[k] = v end
		without_total = without_total + #streets.narrow_gaps(plain, Cp)
	end
	eq(without_total > 0, true, "plans without the policy do keep narrow runs")
end
