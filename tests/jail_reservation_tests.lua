-- Jail reservation tests (ticket #69). Loaded by tests/run.lua:
--   loadfile("tests/jail_reservation_tests.lua")(eq, fails, planner, catalog, geometry)
--
-- The reservation rules run on a small explicit plan (tests/frontage_plan_fixture.lua)
-- with the real catalog jail. A generated medieval plan is used only for the
-- integration cases at the end; TOWNS_TEST_FULL=1 sweeps seeds 1-8.
local eq, fails, planner, catalog, geometry = ...
local authored_plan = dofile("src/authored_plan.lua")

local FULL = os.getenv("TOWNS_TEST_FULL") == "1"
local row_plan = dofile("tests/frontage_plan_fixture.lua")
local packer = dofile("src/frontage_packer.lua")(geometry)
local jailmod = dofile("src/jail_reservation.lua")(packer)

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

-- Geometry shared by the fixture and the generated plans: the box is the
-- rotated catalog box, wholly inside its block, flush with an ordinary street
-- run whose pavement it faces, and clear of every site and street.
local function check_placement(plan, j, label)
	eq(j.role, "jail", label .. " role")
	local g = geometry.place({size = base.jail.size, entrance = base.jail.entrance},
		{x = j.rect.x1, y = 0, z = j.rect.z1}, j.rotation)
	eq(j.rect.x2 - j.rect.x1 + 1, g.size.x, label .. " box width")
	eq(j.rect.z2 - j.rect.z1 + 1, g.size.z, label .. " box depth")
	eq(j.entrance.x, g.entrance.x, label .. " entrance x")
	eq(j.entrance.z, g.entrance.z, label .. " entrance z")
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
	eq(j.distance, dist2(plan, j.entrance), label .. " distance recorded")
end

------------------------------------------------------------------------
-- Reservation rules on the small fixture
------------------------------------------------------------------------
local WEST_MARKET = {x1 = -40, z1 = -30, x2 = -30, z2 = -20}

do
	local plan = row_plan{market = WEST_MARKET}
	local j, short = jailmod.reserve(plan, base.jail)
	eq(short, nil, "fixture: no shortage")
	eq(j ~= nil, true, "fixture: jail placed")
	check_placement(plan, j, "fixture")
	-- Farthest-from-market rule: the nearest choice (bias -1) is no farther,
	-- and on this row it is on the market side.
	local near = jailmod.reserve(plan, base.jail, {bias = -1})
	eq(dist2(plan, j.entrance) >= dist2(plan, near.entrance), true,
		"fixture: at least as far as the nearest choice")
	eq(j.rect.x1 > near.rect.x1, true, "fixture: farthest jail is on the far end")
	eq(jailmod.JAIL_MARKET_BIAS, 1, "fixture: default bias prefers far")

	-- Reproducible for a seed, and the plan is not modified.
	local again = jailmod.reserve(row_plan{market = WEST_MARKET}, base.jail)
	eq(again.rect.x1 == j.rect.x1 and again.rect.z1 == j.rect.z1
		and again.rotation == j.rotation and again.frontage == j.frontage, true,
		"fixture: reproduces")
	eq(plan.reservations, nil, "fixture: plan untouched")

	-- Every other site and earlier reservation is avoided: occupy the far end
	-- and the jail moves in from it.
	local blocked = row_plan{market = WEST_MARKET, sites = {hall = {kind = "landmark",
		rect = {x1 = 60, z1 = 0, x2 = 99, z2 = 11}}}}
	local jb = jailmod.reserve(blocked, base.jail)
	eq(jb ~= nil and overlaps(jb.rect, blocked.sites.hall.rect), false, "fixture: clear of hall")
	eq(jb ~= nil and jb.rect.x2 < 60, true, "fixture: jail uses the remaining space")
	local extra = jailmod.reserve(plan, base.jail, {occupied = {{x1 = 40, z1 = 0, x2 = 99, z2 = 11}}})
	eq(extra ~= nil and extra.rect.x2 < 40, true, "fixture: opts.occupied is avoided")

	-- The forum serves as the market of a Roman plan.
	local roman = row_plan{market = WEST_MARKET}
	roman.sites.forum, roman.sites.market = roman.sites.market, nil
	local jr = jailmod.reserve(roman, base.jail)
	eq(jr ~= nil and jr.rect.x1 == j.rect.x1, true, "fixture: forum acts as the market")
end

-- Square-facing frontage is never used for the jail.
do
	local jp, short = jailmod.reserve(row_plan{square_face = true}, base.jail)
	eq(jp, nil, "square-only frontage: no jail")
	eq(short.role == "jail" and short.wanted == 1 and short.placed == 0, true,
		"square-only frontage: shortage record")
	eq(short.reason:find("no ordinary street frontage", 1, true) ~= nil, true,
		"square-only frontage: reason")
end

-- No market: a diagnostic, not an error.
do
	local plan = row_plan{}
	plan.sites.market = nil
	local jp, short = jailmod.reserve(plan, base.jail)
	eq(jp, nil, "no market: no jail")
	eq(short.reason, "plan has no market square", "no market: reason")
end

-- No fit: a jail box larger than every block gives a diagnostic.
do
	local big = {id = "t_big", size = {x = 60, y = 8, z = 60},
		entrance = {x = 30, y = 1, z = 0}, ground_offset = 0}
	local jp, short = jailmod.reserve(row_plan{}, big)
	eq(jp, nil, "no fit: none placed")
	eq(short.role == "jail" and short.wanted == 1 and short.placed == 0, true, "no fit: shortage record")
	eq(type(short.reason) == "string" and #short.reason > 0, true, "no fit: shortage reason")
end

------------------------------------------------------------------------
-- Integration: reservation inside a generated medieval plan
------------------------------------------------------------------------
local function check_planned(seed)
	local label = "jail seed " .. seed
	local plan, why = planner.plan({x = 10, z = -30}, seed, {landmarks = base})
	eq(plan ~= nil, true, label .. " planned: " .. tostring(why))
	if not plan then return end
	eq(authored_plan.validate(plan), true, label .. " validates")
	eq(#plan.shortages, 0, label .. " shortages")
	local j = plan.reservations and plan.reservations.jail
	eq(j ~= nil, true, label .. " has a jail")
	if j then check_placement(plan, j, label) end
	return plan
end

local plan1 = check_planned(1)
if FULL then
	for seed = 2, 8 do check_planned(seed) end
end

-- Reserving the jail leaves the rest of the plan alone.
if plan1 then
	local plain = planner.plan({x = 10, z = -30}, 1,
		{landmarks = {cathedral = base.cathedral, castle = base.castle,
			city_hall = base.city_hall}, constants = depth_policy})
	eq(plain ~= nil and plain.reservations == nil and plain.shortages == nil, true,
		"jail-less plan carries no reservation fields")
	if plain then
		eq(#plain.streets == #plan1.streets and #plain.frontage == #plan1.frontage
			and plain.attempts == plan1.attempts, true, "rest of plan unchanged")
	end
end

-- An unplaceable jail is a shortage on a valid plan, not a failed plan.
do
	local big = {id = "t_big", size = {x = 60, y = 8, z = 60},
		entrance = {x = 30, y = 1, z = 0}, ground_offset = 0}
	local prof = {cathedral = base.cathedral, castle = base.castle,
		city_hall = base.city_hall, jail = big}
	local plan, why = planner.plan({x = 0, z = 0}, 2, {landmarks = prof})
	eq(plan ~= nil, true, "no-fit plan still succeeds: " .. tostring(why))
	if plan then
		eq(authored_plan.validate(plan), true, "no-fit plan validates")
		eq(plan.reservations.jail, nil, "no jail placed")
		eq(#plan.shortages, 1, "one shortage")
		local s = plan.shortages[1]
		eq(s.role == "jail" and s.wanted == 1 and s.placed == 0, true, "shortage record")
	end
end
