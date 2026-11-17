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

-- Unwalled-style medieval towns: six road crossings, two principal and four
-- secondary (graded 4 and 2 wide), for 28 exit columns in all.
for _, seed in ipairs({1, 101}) do
	local plan = assert(planner.plan({x = 0, z = 0}, seed, {landmarks = profile}))
	eq(plan.town_type, "medieval", "seed " .. seed .. " is a medieval plan")
	local exits = roads.exits(plan)
	eq(#exits, 28, "seed " .. seed .. " exit columns")
	local crossings = roads.crossings(exits)
	eq(#crossings, 6, "seed " .. seed .. " exits form six crossings")
	local w = widths(exits)
	eq(table.concat(w, ","), "2,2,2,2,4,4", "seed " .. seed .. " outside crossing widths")
	local rects = plan.boundary.rects
	for _, e in ipairs(exits) do
		local label = "seed " .. seed .. " exit " .. e.x .. "," .. e.z
		eq(inside(rects, e.x, e.z), false, label .. " lies outside the town")
		eq(inside(rects, e.x - e.direction.x, e.z - e.direction.z), true,
			label .. " is on the first column outside the town")
	end
end

-- Roman plans (issue #385): each arch's street continues out as a four-wide
-- exit strip, so the south, east and west arms give three crossings.
do
	local plan = assert(planner.plan({x = 0, z = 0}, 1, {town_type = "roman"}))
	eq(plan.town_type, "roman", "Roman plan type")
	local exits = roads.exits(plan)
	eq(#exits, 12, "Roman exit columns")
	eq(#roads.crossings(exits), 3, "Roman exits form three crossings")
	eq(table.concat(widths(exits), ","), "4,4,4", "Roman crossing widths")
	local dirs = {}
	for _, e in ipairs(exits) do
		dirs[e.direction.x .. "," .. e.direction.z] = true
		eq(inside(plan.boundary.rects, e.x, e.z), false, "Roman exit " .. e.x .. "," .. e.z .. " lies outside the town")
		eq(roads.street_at(plan, e.x - e.direction.x, e.z - e.direction.z, e.direction).exit, true,
			"Roman exit " .. e.x .. "," .. e.z .. " opens onto an exit street")
	end
	eq(dirs["0,-1"] and dirs["1,0"] and dirs["-1,0"], true, "Roman exits face south, east and west")
	eq(dirs["0,1"], nil, "no north exit")
	-- The east exit is a 4x4 square; street_at ties go to the first street.
	local east = roads.street_at(plan, 85, plan.center.z - 1, {x = 1, z = 0})
	eq(east and east.name, "decumanus_east_exit", "east 4x4 exit street_at")
end

-- Missing boundary or streets yields an empty list rather than an error.
eq(#roads.exits({streets = {}}), 0, "exits without a boundary is empty")
eq(#roads.exits({boundary = {rects = {}}}), 0, "exits without streets is empty")

-- Graded ramps report the node profile actually planned (Roads integration):
-- profile[n + 1] = {y, name, param2} for step n, identical in every column.
do
	local function info(name) return {walkable = name ~= "air"} end
	local function openings(width)
		local out = {}
		for t = 0, width - 1 do
			out[#out + 1] = {x = 10, z = 20 + t, direction = {x = 1, z = 0}, street = 1, kind = "secondary"}
		end
		return out
	end
	local function run(width, height)
		local region = {get = function(x, y, z)
			return y <= height(x - 10) and "mcl_core:stone" or "air"
		end}
		return roads.grade(openings(width), 0, region, info, function() return false end)
	end
	-- Flat terrain: a four step cobble profile at ground level.
	local changes, failures, _, graded = run(2, function() return 0 end)
	eq(#failures, 0, "flat grade has no failures")
	eq(#graded, 1, "flat grade reports one ramp")
	local g = graded[1]
	eq(g.length, 4, "flat ramp length")
	eq(#g.profile, 4, "flat profile has one entry per step")
	for n, step in ipairs(g.profile) do
		eq(step.y, 0, "flat step " .. n .. " y")
		eq(step.name, roads.RAMP_FULL, "flat step " .. n .. " is cobble")
		eq(step.param2, 0, "flat step " .. n .. " param2")
	end
	eq(#g.columns, 2, "flat ramp columns")
	eq(g.columns[1].x .. ":" .. g.columns[1].z, "10:20", "first column")
	eq(g.direction.x, 1, "direction x")
	-- Every profile node appears in the changes.
	local at = {}
	for _, c in ipairs(changes) do at[c.x .. ":" .. c.y .. ":" .. c.z] = c end
	for _, col in ipairs(g.columns) do
		for n, step in ipairs(g.profile) do
			local c = at[(col.x + n - 1) .. ":" .. step.y .. ":" .. col.z]
			eq(c and c.name, step.name, "profile node is a planned change")
			eq(c and c.param2, step.param2, "profile param2 is a planned change")
		end
	end
	-- Ascending: stairs first, ending on a full block at terrain level.
	_, _, _, graded = run(2, function(d) return d >= 1 and 4 or 0 end)
	g = graded[1]
	eq(g.profile[2].name, roads.RAMP_STAIR, "ascending first step is a stair")
	eq(g.profile[2].param2, 1, "ascending stair faces outward")
	eq(g.profile[2].y, 1, "ascending first step y")
	eq(g.profile[#g.profile].name, roads.RAMP_FULL, "ascending ramp ends in a full block")
	eq(g.profile[#g.profile].y, 4, "ascending ramp ends at terrain level")
	-- Descending: the stair rises toward town.
	_, _, _, graded = run(2, function(d) return d >= 1 and -2 or 0 end)
	g = graded[1]
	eq(g.profile[2].name, roads.RAMP_STAIR, "descending first step is a stair")
	eq(g.profile[2].param2, 3, "descending stair faces town")
	-- A failed crossing is absent from the graded list.
	local blocked = {get = function(x, y)
		if x == 12 and y == 0 then return "test:planks" end
		return y <= 0 and "mcl_core:stone" or "air"
	end}
	_, failures, _, graded = roads.grade(openings(2), 0, blocked, info, function() return false end)
	eq(#failures, 1, "blocked crossing fails")
	eq(#graded, 0, "failed crossing is not reported as graded")
end
