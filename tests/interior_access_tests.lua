-- Interior access validator tests (ticket #54). Loaded by tests/run.lua:
--   loadfile("tests/interior_access_tests.lua")(eq, fails, planner, catalog)
local eq, fails, planner, catalog = ...

local access = dofile("src/interior_access.lua")

local function R(x1, z1, x2, z2) return {x1 = x1, z1 = z1, x2 = x2, z2 = z2} end

-- Block 0..19 square, streets all round (grid -4..23 = 28x28 nodes).
local function fixture()
	return {
		sites = {},
		streets = {{rect = R(-4, -4, 23, -1)}, {rect = R(-4, 20, 23, 23)},
			{rect = R(-4, 0, -1, 19)}, {rect = R(20, 0, 23, 19)}},
		blocks = {{id = 1, rect = R(0, 0, 19, 19)}},
		reservations = {services = {}},
		content = {buildings = {}},
	}
end
-- Ring of boxes around an interior 8..11 x 8..11.
local function ring(plan)
	local b = plan.content.buildings
	b[#b + 1] = {rect = R(6, 6, 13, 7)}
	b[#b + 1] = {rect = R(6, 12, 13, 13)}
	b[#b + 1] = {rect = R(6, 8, 7, 11)}
	b[#b + 1] = {rect = R(12, 8, 13, 11)}
end

-- No leftover interior: nothing built.
do
	local r = assert(access.check(fixture()))
	eq(r.ok, true, "empty ok")
	eq(#r.components, 0, "empty comps")
	eq(r.sealed_cells, 0, "empty sealed")
end

-- Already open interior: a box in the middle, ground flows around it.
do
	local p = fixture()
	p.content.buildings[1] = {rect = R(5, 5, 14, 14)}
	local r = assert(access.check(p))
	eq(r.ok, true, "open ok")
	eq(r.free_cells, 28 * 28 - 100, "open free count")
	eq(r.reachable_cells, 28 * 28 - 100, "open reachable")
end

-- Sealed courtyard.
do
	local p = fixture()
	ring(p)
	local r = assert(access.check(p))
	eq(r.ok, false, "sealed not ok")
	eq(#r.components, 1, "sealed one comp")
	local c = r.components[1]
	eq(c.size, 16, "sealed size")
	eq(c.first.x, 8, "sealed first x")
	eq(c.first.z, 8, "sealed first z")
	eq(c.bbox.x2, 11, "sealed bbox")
	eq(#c.blocks, 1, "sealed block count")
	eq(c.blocks[1], 1, "sealed block id")
	eq(#c.rects, 4, "sealed row spans")
	eq(r.sealed_cells, 16, "sealed cells")
	local r2 = assert(access.check(p))
	eq(r2.components[1].first.x, c.first.x, "sealed repeat")
	eq(#p.content.buildings, 4, "plan untouched")
end

-- A one-node alley (a gap in the ring) opens it.
do
	local p = fixture()
	ring(p)
	p.content.buildings[2] = {rect = R(6, 12, 9, 13)}
	p.content.buildings[5] = {rect = R(11, 12, 13, 13)} -- gap at x = 10
	eq(assert(access.check(p)).ok, true, "alley opens courtyard")
end

-- Touching sub-blocks: one courtyard spans two block rectangles.
do
	local p = fixture()
	p.blocks = {{id = 1, rect = R(0, 0, 9, 19)}, {id = 2, rect = R(10, 0, 19, 19)}}
	ring(p)
	local r = assert(access.check(p))
	eq(#r.components, 1, "touching: one component across blocks")
	eq(#r.components[1].blocks, 2, "touching: both blocks named")
	p.content.buildings[4] = {rect = R(12, 8, 13, 9)}
	eq(assert(access.check(p)).ok, true, "touching: gap opens both blocks")
end

-- Blocked market path: the block's only free route runs past the market,
-- and the city hall (a non-square site) stands across it.
do
	local p = fixture()
	p.streets = {}
	p.sites = {market = {kind = "square", rect = R(0, 20, 19, 25)},
		city_hall = {kind = "landmark", rect = R(0, 20, 19, 20)}}
	local r = assert(access.check(p))
	eq(r.ok, false, "blocked market: sealed")
	eq(r.components[1].size, 400, "blocked market: whole block")
	p.sites.city_hall.rect = R(0, 20, 8, 20)
	eq(assert(access.check(p)).ok, true, "market path open past hall")
end

-- Jail, services and non-square sites are obstacles; bad input is refused.
do
	local p = fixture()
	p.sites.castle = {kind = "landmark", rect = R(6, 6, 13, 7)}
	p.reservations.jail = {rect = R(6, 12, 13, 13)}
	p.reservations.services = {{rect = R(6, 8, 7, 11)}}
	local r = assert(access.check(p, {occupied = {R(12, 8, 13, 11)}}))
	eq(#r.components, 1, "obstacle kinds seal")
	local nr, why = access.check({})
	eq(nr, nil, "no blocks refused")
	eq(type(why), "string", "reason text")
	eq(access.check(fixture(), {max_cells = 10}), nil, "oversized grid refused")
end

-- Stock catalog across seeds: deterministic, plan unchanged, books balance.
do
	local base = assert(planner.landmark_profile(catalog.snapshot()))
	for _, seed in ipairs({1, 2, 3, 4, 5, 6, 7, 8}) do
		local label = "access seed " .. seed
		local plan = assert(planner.plan({x = 10, z = -30}, seed, {landmarks = base}))
		local nb = #plan.content.buildings
		local a = assert(access.check(plan))
		local b = assert(access.check(plan))
		eq(#plan.content.buildings, nb, label .. " plan untouched")
		eq(#a.components, #b.components, label .. " stable count")
		eq(a.sealed_cells, b.sealed_cells, label .. " stable cells")
		eq(a.ok, #a.components == 0, label .. " ok matches")
		local n = 0
		for _, c in ipairs(a.components) do n = n + c.size end
		eq(n, a.sealed_cells, label .. " sizes add up")
		eq(a.free_cells - a.reachable_cells, a.sealed_cells, label .. " accounting")
	end
end
