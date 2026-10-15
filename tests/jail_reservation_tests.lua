-- Jail reservation tests (ticket #69). Loaded by tests/run.lua:
--   loadfile("tests/jail_reservation_tests.lua")(eq, fails, planner, catalog, geometry)
local eq, fails, planner, catalog, geometry = ...

local SEEDS = {1, 2, 3, 4, 5, 6, 7, 8}

local function in_rect(r, x, z)
	return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2
end

local function overlaps(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

local base = assert(planner.landmark_profile(catalog.snapshot()))
eq(base.jail ~= nil, true, "catalog profile carries the jail")
eq(base.jail.id, "jail", "catalog jail id")
-- The street spacing depth comes from the content; the jail-less plan below
-- has none, so it is passed explicitly (ticket #86).
local depth_policy = planner.depth_policy(base)

local function dist2(plan, e)
	local m = plan.sites.market.rect
	local dx, dz = e.x - (m.x1 + m.x2) / 2, e.z - (m.z1 + m.z2) / 2
	return dx * dx + dz * dz
end

local function check(plan, label)
	eq(planner.validate(plan), true, label .. " validates")
	local j = plan.reservations and plan.reservations.jail
	eq(j ~= nil, true, label .. " has a jail")
	-- No chapel shortage on seeds 1-8 with the #126 town hall (seed 4 had one
	-- under #106, seed 3 before that; see the service tests).
	eq(#plan.shortages, 0, label .. " shortages")
	if not j then return end
	eq(j.role, "jail", label .. " role")
	local g = geometry.place({size = base.jail.size, entrance = base.jail.entrance},
		{x = j.rect.x1, y = 0, z = j.rect.z1}, j.rotation)
	eq(j.rect.x2 - j.rect.x1 + 1, g.size.x, label .. " box width")
	eq(j.rect.z2 - j.rect.z1 + 1, g.size.z, label .. " box depth")
	eq(j.entrance.x, g.entrance.x, label .. " entrance x")
	eq(j.entrance.z, g.entrance.z, label .. " entrance z")
	-- Wholly inside its block, ordinary street frontage, clear of all sites.
	local b = plan.blocks[j.block].rect
	eq(j.rect.x1 >= b.x1 and j.rect.x2 <= b.x2 and j.rect.z1 >= b.z1
		and j.rect.z2 <= b.z2, true, label .. " inside block")
	local f = plan.frontage[j.frontage]
	eq(f.street ~= nil and f.square == nil, true, label .. " ordinary street run")
	for name, s in pairs(plan.sites) do
		eq(overlaps(j.rect, s.rect), false, label .. " clear of " .. name)
	end
	for i, s in ipairs(plan.streets) do
		eq(overlaps(j.rect, s.rect), false, label .. " clear of street " .. i)
	end
	-- The box edge facing the street lies on the run; the node beyond is
	-- pavement of the street the run names.
	local px, pz = j.rect.x1, j.rect.z1
	if f.facing.x > 0 then px = j.rect.x2 end
	if f.facing.z > 0 then pz = j.rect.z2 end
	eq(in_rect(f.rect, px, pz), true, label .. " flush with run")
	local ax, az = px + f.facing.x, pz + f.facing.z
	eq(in_rect(plan.streets[f.street].rect, ax, az), true, label .. " faces pavement")
	-- Farthest-from-market rule: no nearest-biased choice is farther.
	local near = planner.plan(plan.center, plan.seed,
		{landmarks = base, constants = {JAIL_MARKET_BIAS = -1}})
	local nj = near and near.reservations.jail
	eq(nj ~= nil and dist2(plan, j.entrance) >= dist2(near, nj.entrance), true,
		label .. " at least as far as the nearest choice")
	eq(j.distance, dist2(plan, j.entrance), label .. " distance recorded")
end

for _, seed in ipairs(SEEDS) do
	local label = "jail seed " .. seed
	local plan, why = planner.plan({x = 10, z = -30}, seed, {landmarks = base})
	eq(plan ~= nil, true, label .. " planned: " .. tostring(why))
	if plan then
		check(plan, label)
		local again = planner.plan({x = 10, z = -30}, seed, {landmarks = base})
		local a, b = plan.reservations.jail, again and again.reservations.jail
		eq(b ~= nil and a.rect.x1 == b.rect.x1 and a.rect.z1 == b.rect.z1
			and a.rotation == b.rotation and a.frontage == b.frontage, true,
			label .. " reproduces")
		-- Reserving the jail leaves the rest of the plan alone.
		local plain = planner.plan({x = 10, z = -30}, seed,
			{landmarks = {cathedral = base.cathedral, castle = base.castle,
				city_hall = base.city_hall}, constants = depth_policy})
		eq(plain ~= nil and plain.reservations == nil and plain.shortages == nil, true,
			label .. " jail-less plan carries no reservation fields")
		if plain then
			eq(#plain.streets == #plan.streets and #plain.frontage == #plan.frontage
				and plain.attempts == plan.attempts, true, label .. " rest of plan unchanged")
		end
	end
end

-- No fit: a jail box larger than every block gives a diagnostic, not a
-- failed plan.
do
	local big = {id = "t_big", size = {x = 60, y = 8, z = 60},
		entrance = {x = 30, y = 1, z = 0}, ground_offset = 0}
	local prof = {cathedral = base.cathedral, castle = base.castle,
		city_hall = base.city_hall, jail = big}
	local plan, why = planner.plan({x = 0, z = 0}, 2, {landmarks = prof})
	eq(plan ~= nil, true, "no-fit plan still succeeds: " .. tostring(why))
	if plan then
		eq(planner.validate(plan), true, "no-fit plan validates")
		eq(plan.reservations.jail, nil, "no jail placed")
		eq(#plan.shortages, 1, "one shortage")
		local s = plan.shortages[1]
		eq(s.role == "jail" and s.wanted == 1 and s.placed == 0, true, "shortage record")
		eq(type(s.reason) == "string" and #s.reason > 0, true, "shortage reason")
	end
end

-- Legacy (no profile) output is untouched.
do
	local plan = planner.plan({x = 0, z = 0}, 3)
	eq(plan ~= nil and plan.reservations == nil and plan.shortages == nil, true,
		"legacy plan has no reservation fields")
end
