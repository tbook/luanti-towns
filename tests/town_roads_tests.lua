-- Outside-road exits (issue #357, ticket T1): src/town_roads.lua. Loaded by
-- tests/run.lua with the shared check helpers, the planner and the catalog:
--   loadfile("tests/town_roads_tests.lua")(eq, planner, catalog)
local eq, planner, catalog = ...
local roads = dofile("src/town_roads.lua")
local profile = assert(planner.landmark_profile(catalog.snapshot()))

-- Each exit is the first column outside the boundary, with the boundary
-- directly on its inner side.
local function inside(rects, x, z)
	for _, r in ipairs(rects) do
		if x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 then return true end
	end
	return false
end

local function widths(exits)
	local out = {}
	for _, columns in ipairs(roads.crossings(exits)) do out[#out + 1] = #columns end
	table.sort(out)
	return out
end

-- Unwalled-style medieval towns: six road crossings, two six-wide and four
-- four-wide, for 28 exit columns in all.
for _, seed in ipairs({1, 101}) do
	local plan = assert(planner.plan({x = 0, z = 0}, seed, {landmarks = profile}))
	eq(plan.town_type, "medieval", "seed " .. seed .. " is a medieval plan")
	local exits = roads.exits(plan)
	eq(#exits, 28, "seed " .. seed .. " exit columns")
	local crossings = roads.crossings(exits)
	eq(#crossings, 6, "seed " .. seed .. " exits form six crossings")
	local w = widths(exits)
	eq(table.concat(w, ","), "4,4,4,4,6,6", "seed " .. seed .. " crossing widths")
	local rects = plan.boundary.rects
	for _, e in ipairs(exits) do
		local label = "seed " .. seed .. " exit " .. e.x .. "," .. e.z
		eq(inside(rects, e.x, e.z), false, label .. " lies outside the town")
		eq(inside(rects, e.x - e.direction.x, e.z - e.direction.z), true,
			label .. " is on the first column outside the town")
	end
end

-- Roman plans have no outside-road exits yet.
do
	local plan = assert(planner.plan({x = 0, z = 0}, 1, {town_type = "roman"}))
	eq(plan.town_type, "roman", "Roman plan type")
	eq(#roads.exits(plan), 0, "Roman plan yields no exits")
end

-- Missing boundary or streets yields an empty list rather than an error.
eq(#roads.exits({streets = {}}), 0, "exits without a boundary is empty")
eq(#roads.exits({boundary = {rects = {}}}), 0, "exits without streets is empty")
