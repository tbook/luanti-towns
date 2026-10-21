-- Access alley tests (ticket #43). Loaded by tests/run.lua:
--   loadfile("tests/access_alley_tests.lua")(eq, fails, planner, catalog, geometry)
local eq, fails, planner, catalog, geometry = ...

local packer = dofile("src/frontage_packer.lua")(geometry)
local jailmod = dofile("src/jail_reservation.lua")(packer)
local access = dofile("src/interior_access.lua")
local content = dofile("src/content_planner.lua")(geometry, packer,
	jailmod.occupied_rects, access)

local function R(x1, z1, x2, z2) return {x1 = x1, z1 = z1, x2 = x2, z2 = z2} end
local function entry(w, d)
	return {role = "house", size = {x = w, y = 5, z = d}, entrance = {x = 1, y = 1, z = 0}}
end
local function overlaps(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

-- Block 0..19 square, a street on every side.
local function square()
	return {
		seed = 7,
		sites = {market = {kind = "square", rect = R(-4, -4, 23, -1)},
			parvis = {kind = "square", rect = R(-4, 20, 23, 23)}},
		streets = {{rect = R(-4, 0, -1, 19)}, {rect = R(20, 0, 23, 19)}},
		reservations = {services = {}},
		blocks = {{id = 1, rect = R(0, 0, 19, 19)}},
		frontage = {
			{id = 1, block = 1, square = "market", facing = {x = 0, z = -1}, rect = R(0, 0, 19, 0)},
			{id = 2, block = 1, square = "parvis", facing = {x = 0, z = 1}, rect = R(0, 19, 19, 19)},
			{id = 3, block = 1, street = 3, facing = {x = -1, z = 0}, rect = R(0, 0, 0, 19)},
			{id = 4, block = 1, street = 4, facing = {x = 1, z = 0}, rect = R(19, 0, 19, 19)},
		},
	}
end

local function sealed(plan, r)
	plan.content = r
	return assert(access.check(plan)).sealed_cells
end

-- A 5x5 house fully packs the ring and seals the courtyard: one two-wide
-- alley opens it, no schematic is cut, and the plan is deterministic.
do
	local entries = {h = entry(5, 5)}
	local plan = square()
	local before = content.plan(square(), entries, {seed = 3, alleys = false})
	eq(sealed(square(), before) > 0, true, "alley: fixture is sealed without alleys")
	eq(before.alleys, nil, "alley: disabled pass leaves no fields")
	local r = content.plan(plan, entries, {seed = 3})
	eq(#r.alleys, 1, "alley: one alley")
	local a = r.alleys[1]
	eq(a.width, 2, "alley: two nodes wide")
	eq(sealed(plan, r), 0, "alley: nothing sealed")
	eq(content.validate(plan, r, entries), true, "alley: validates")
	for i, b in ipairs(r.buildings) do
		eq(overlaps(a.rect, b.rect), false, "alley: clear of building " .. i)
	end
	eq(#r.removed >= 1, true, "alley: a whole building was removed")
	eq(r.removed[1].reason, "alley", "alley: removal reason")
	local again = content.plan(square(), entries, {seed = 3})
	eq(#again.buildings, #r.buildings, "alley: repeat count")
	eq(again.alleys[1].rect.x1, a.rect.x1, "alley: repeat position")
	local covered = false
	for _, u in ipairs(r.unused) do
		if overlaps(u.rect, a.rect) then covered = true end
	end
	eq(covered, false, "alley: cells are not reported unused")
end

-- Width-1 alley: wall boxes (opts.occupied, fixed) leave one house column as
-- the only way into the pocket below it, so only a one-node alley fits.
do
	local plan = square()
	plan.blocks[1].rect = R(0, 0, 8, 8)
	plan.streets = {{rect = R(-4, -4, 12, -1)}}
	plan.frontage = {{id = 1, block = 1, street = 1, facing = {x = 0, z = -1},
		rect = R(0, 0, 8, 0)}}
	local walls = {R(0, 0, 3, 2), R(5, 0, 8, 2), R(0, 3, 2, 6), R(6, 3, 8, 6),
		R(0, 5, 8, 8)}
	local entries = {h = {role = "house", size = {x = 1, y = 5, z = 3},
		entrance = {x = 0, y = 1, z = 0}}}
	local off = content.plan(plan, entries, {seed = 1, occupied = walls, alleys = false})
	eq(#off.buildings, 1, "width1: one house")
	local r = content.plan(plan, entries, {seed = 1, occupied = walls})
	eq(#r.alleys, 1, "width1: one alley")
	eq(r.alleys[1].width, 1, "width1: one node wide")
	eq(r.alleys[1].rect.x1, 4, "width1: column")
	eq(#r.buildings, 0, "width1: house removed")
	plan.content = r
	eq(assert(access.check(plan, {occupied = walls})).sealed_cells, 0, "width1: opened")
end

-- Whole-building removal fallback: with no alleys allowed the buildings that
-- border the sealed component are dropped instead.
do
	local entries = {h = entry(5, 5)}
	local cap = content.MAX_ALLEYS_PER_AREA
	content.MAX_ALLEYS_PER_AREA = 0
	local plan = square()
	local r = content.plan(plan, entries, {seed = 3})
	content.MAX_ALLEYS_PER_AREA = cap
	eq(#r.alleys, 0, "fallback: no alley")
	eq(#r.removed >= 1, true, "fallback: buildings removed")
	eq(r.removed[1].reason, "sealed", "fallback: reason")
	eq(sealed(plan, r), 0, "fallback: opened")
	eq(content.validate(plan, r, entries), true, "fallback validates")
end

-- Per-area cap: with one alley allowed, a courtyard needing more is finished
-- by the removal fallback and the cap is never exceeded.
do
	local entries = {h = entry(5, 5)}
	local cap = content.MAX_ALLEYS_PER_AREA
	content.MAX_ALLEYS_PER_AREA = 1
	local plan = square()
	local r = content.plan(plan, entries, {seed = 3})
	content.MAX_ALLEYS_PER_AREA = cap
	eq(#r.alleys <= 1, true, "cap: at most one alley")
	eq(sealed(plan, r), 0, "cap: opened")
end

-- Already accessible interior: identical to the pass being disabled.
do
	local entries = {h = entry(6, 6)}
	local on = content.plan(square(), entries, {seed = 3})
	local off = content.plan(square(), entries, {seed = 3, alleys = false})
	eq(#on.alleys, 0, "open: no alleys")
	eq(#on.removed, 0, "open: nothing removed")
	eq(#on.buildings, #off.buildings, "open: same buildings")
	eq(#on.unused, #off.unused, "open: same unused")
end

-- Shallow block with no interior: nothing to open.
do
	local plan = square()
	plan.blocks[1].rect = R(0, 0, 19, 5)
	plan.frontage = {{id = 1, block = 1, street = 1, facing = {x = 0, z = -1}, rect = R(0, 0, 19, 0)}}
	local r = content.plan(plan, {h = entry(5, 5)}, {seed = 1})
	eq(#r.alleys, 0, "shallow: no alleys")
	eq(#r.buildings > 0, true, "shallow: buildings")
end

-- Fixed services alone seal ground: the content plan is rejected.
do
	local plan = square()
	plan.reservations.services = {{rect = R(6, 6, 13, 7)}, {rect = R(6, 12, 13, 13)},
		{rect = R(6, 8, 7, 11)}, {rect = R(12, 8, 13, 11)}}
	local r = content.plan(plan, {h = entry(5, 5)}, {seed = 1})
	eq(#r.buildings, 0, "fixed seal: no buildings")
	eq(type(r.reason), "string", "fixed seal: reason")
	eq(#r.empty_runs, 4, "fixed seal: runs empty")
end

-- Touching sub-blocks: the courtyard spans both rectangles; the shared edge
-- is no street, so there is no frontage along it.
do
	local plan = square()
	plan.blocks = {{id = 1, rect = R(0, 0, 19, 9)}, {id = 2, rect = R(0, 10, 19, 19)}}
	plan.frontage = {
		{id = 1, block = 1, street = 1, facing = {x = 0, z = -1}, rect = R(0, 0, 19, 0)},
		{id = 2, block = 2, street = 2, facing = {x = 0, z = 1}, rect = R(0, 19, 19, 19)},
		{id = 3, block = 1, street = 3, facing = {x = -1, z = 0}, rect = R(0, 0, 0, 9)},
		{id = 4, block = 1, street = 4, facing = {x = 1, z = 0}, rect = R(19, 0, 19, 9)},
		{id = 5, block = 2, street = 3, facing = {x = -1, z = 0}, rect = R(0, 10, 0, 19)},
		{id = 6, block = 2, street = 4, facing = {x = 1, z = 0}, rect = R(19, 10, 19, 19)},
	}
	local entries = {h = entry(5, 5)}
	local off = content.plan(plan, entries, {seed = 3, alleys = false})
	eq(sealed(plan, off) > 0, true, "touching: sealed across blocks")
	local r = content.plan(plan, entries, {seed = 3})
	eq(sealed(plan, r), 0, "touching: opened")
	eq(#r.alleys >= 1 and #r.alleys <= 2, true, "touching: at most two alleys")
	for _, a in ipairs(r.alleys) do eq(a.area, 1, "touching: one area") end
	eq(content.validate(plan, r, entries), true, "touching validates")
end

-- Stock catalog: every seed 1..22 ends with nothing sealed and a valid plan.
do
	local access_mod = dofile("src/interior_access.lua")
	local base = assert(planner.landmark_profile(catalog.snapshot()))
	local total = 0
	for seed = 1, 22 do
		local plan = assert(planner.plan({x = 10, z = -30}, seed, {landmarks = base}))
		local c = plan.content
		eq(assert(access_mod.check(plan)).sealed_cells, 0, "stock sealed " .. seed)
		eq(c.reason, nil, "stock not rejected " .. seed)
		eq(#c.alleys <= 2 * #plan.blocks, true, "stock alley bound " .. seed)
		eq(content.validate(plan, c, base.content), true, "stock validates " .. seed)
		total = total + #c.alleys
	end
	eq(total > 0, true, "stock: some alleys were needed")
end
