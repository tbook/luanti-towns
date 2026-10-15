-- Interior access validator tests (ticket #54). Loaded by tests/run.lua:
--   loadfile("tests/interior_access_tests.lua")(eq, fails, planner, catalog)
local eq, fails, planner, catalog = ...

local access = dofile("src/interior_access.lua")

local function R(x1, z1, x2, z2) return {x1 = x1, z1 = z1, x2 = x2, z2 = z2} end

-- Block 0..19 square, streets all round (pavement -4..23; grid adds a
-- 3-node open margin: 34x34 nodes).
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
	eq(r.free_cells, 34 * 34 - 100, "open free count")
	eq(r.reachable_cells, 34 * 34 - 100, "open reachable")
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

-- Blocked market path: the courtyard opens (gap at x = 10, z = 12..13) onto
-- the market side, and the city hall (a non-square site) stands in the gap.
do
	local p = fixture()
	ring(p)
	p.content.buildings[2] = {rect = R(6, 12, 9, 13)}
	p.content.buildings[5] = {rect = R(11, 12, 13, 13)}
	p.sites = {market = {kind = "square", rect = R(0, 14, 19, 19)},
		city_hall = {kind = "landmark", rect = R(10, 12, 10, 13)}}
	local r = assert(access.check(p))
	eq(r.ok, false, "blocked market: sealed")
	eq(r.components[1].size, 16, "blocked market: courtyard")
	p.sites.city_hall.rect = R(10, 2, 10, 3)
	eq(assert(access.check(p)).ok, true, "market path open past hall")
end

-- Ground outside blocks and pavement is walkable; the open margin is a
-- source, so a box on the grid edge does not seal anything.
do
	local p = fixture()
	p.blocks = {{id = 1, rect = R(0, 0, 9, 19)}}
	p.content.buildings = {{rect = R(0, 0, 9, 0)}, {rect = R(0, 19, 9, 19)}}
	eq(assert(access.check(p)).ok, true, "open ground ok")
end

-- All pavement cells are sources: pavement cut off from the street network
-- (here inside a sealed courtyard) is not reported and frees its neighbours.
do
	local p = fixture()
	ring(p)
	p.streets[#p.streets + 1] = {rect = R(9, 9, 10, 10)}
	local r = assert(access.check(p))
	eq(r.ok, true, "isolated pavement counts as source")
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

-- Stock catalog: pinned results, deterministic, plan unchanged. Sealed cells
-- are counted when the content is planned without the alley pass (#43),
-- which the planner runs by default. Re-pinned in #86 (catalog-derived
-- narrow-gap rules, minimum block side stays the #89 12): seeds 8, 14, 16
-- and 17 seal 20, 72, 24 and 47 cells, all others 0 (before: 3, 4, 18, 19,
-- 20 sealed 84, 546, 36, 97, 24; earlier re-pins #88/#89/#105).
do
	local geometry = dofile("src/geometry.lua")
	local packer = dofile("src/frontage_packer.lua")(geometry)
	local jailmod = dofile("src/jail_reservation.lua")(packer)
	local content = dofile("src/content_planner.lua")(geometry, packer,
		jailmod.occupied_rects, access)
	local base = assert(planner.landmark_profile(catalog.snapshot()))
	local pinned = {[8] = 20, [14] = 72, [16] = 24, [17] = 47}
	for seed = 1, 22 do pinned[seed] = pinned[seed] or 0 end
	local function inside(r, x, z)
		return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2
	end
	for seed = 1, 22 do
		local label = "access seed " .. seed
		local plan = assert(planner.plan({x = 10, z = -30}, seed, {landmarks = base}))
		plan.content = content.plan(plan, base.content, {seed = seed, alleys = false})
		local nb = #plan.content.buildings
		local a = assert(access.check(plan))
		local b = assert(access.check(plan))
		eq(#plan.content.buildings, nb, label .. " plan untouched")
		eq(a.sealed_cells, pinned[seed], label .. " sealed cells")
		eq(a.ok, pinned[seed] == 0, label .. " ok")
		eq(#a.components, #b.components, label .. " stable count")
		local solid = {}
		for _, s in pairs(plan.sites) do
			if s.kind ~= "square" then solid[#solid + 1] = s.rect end
		end
		solid[#solid + 1] = plan.reservations.jail.rect
		for _, s in ipairs(plan.reservations.services) do solid[#solid + 1] = s.rect end
		for _, c in ipairs(plan.content.buildings) do solid[#solid + 1] = c.rect end
		local n = 0
		for ci, c in ipairs(a.components) do
			n = n + c.size
			eq(c.first.x, b.components[ci].first.x, label .. " stable first")
			local cells = 0
			for _, sp in ipairs(c.rects) do
				for x = sp.x1, sp.x2 do
					cells = cells + 1
					for _, r in ipairs(solid) do
						eq(inside(r, x, sp.z1), false, label .. " cell outside boxes")
					end
				end
			end
			eq(cells, c.size, label .. " spans cover component")
		end
		eq(n, a.sealed_cells, label .. " sizes add up")
	end
end
