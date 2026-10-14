-- City hall reservation tests (ticket #39). Loaded by tests/run.lua:
--   loadfile("tests/city_hall_tests.lua")(eq, fails, planner, catalog, geometry)
local eq, fails, planner, catalog, geometry = ...

local SEEDS = {1, 2, 3, 4, 5, 6, 7, 8}

local function in_rect(r, x, z)
	return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2
end

local function inside(inner, outer)
	return inner.x1 >= outer.x1 and inner.x2 <= outer.x2
		and inner.z1 >= outer.z1 and inner.z2 <= outer.z2
end

local function overlaps(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

local base = assert(planner.landmark_profile(catalog.snapshot()))
eq(base.city_hall ~= nil, true, "catalog profile carries the city hall")
eq(base.city_hall.id, "tower", "catalog hall id")
eq(base.city_hall.size.x, 8, "tower size x")

-- Synthetic asymmetric halls: long with an off-centre door; deep with the
-- door near a corner.
local HALLS = {
	wide = {id = "t_wide", size = {x = 18, y = 14, z = 9},
		entrance = {x = 13, y = 2, z = 3}, ground_offset = 1},
	deep = {id = "t_deep", size = {x = 7, y = 20, z = 16},
		entrance = {x = 1, y = 1, z = 2}, ground_offset = 0},
}

local function profile_with(hall)
	return {cathedral = base.cathedral, castle = base.castle, city_hall = hall}
end

local function check(plan, hall, label)
	eq(planner.validate(plan), true, label .. " validates")
	local h = plan.sites.city_hall
	eq(h ~= nil, true, label .. " has a hall")
	if not h then return end
	local mk = plan.sites.market.rect
	local g = geometry.place({size = hall.size, entrance = hall.entrance},
		{x = h.rect.x1, y = 0, z = h.rect.z1}, h.rotation)
	-- Complete rotated box, inside the market with the circulation margin.
	eq(h.rect.x2 - h.rect.x1 + 1, g.size.x, label .. " box width")
	eq(h.rect.z2 - h.rect.z1 + 1, g.size.z, label .. " box depth")
	eq(inside(h.rect, mk), true, label .. " hall inside market")
	local m = planner.CONSTANTS.CITY_HALL_MARGIN
	eq(h.rect.x1 - mk.x1 >= m and mk.x2 - h.rect.x2 >= m
		and h.rect.z1 - mk.z1 >= m and mk.z2 - h.rect.z2 >= m, true,
		label .. " circulation margin all round")
	-- Real (rotated) door and the pavement in front of it.
	eq(h.entrance.x, g.entrance.x, label .. " entrance x")
	eq(h.entrance.z, g.entrance.z, label .. " entrance z")
	eq(h.door.outside.x, g.outside.x, label .. " outside x")
	eq(h.door.outside.z, g.outside.z, label .. " outside z")
	eq(h.id, hall.id, label .. " id")
	eq(h.square, "market", label .. " names the market")
	local p = h.approach.pos
	eq(in_rect(mk, p.x, p.z), true, label .. " approach on market pavement")
	eq(in_rect(h.rect, p.x, p.z), false, label .. " approach outside hall")
	for k = 0, 5 do
		local x, z = p.x + h.facing.x * k, p.z + h.facing.z * k
		eq(in_rect(mk, x, z) and not in_rect(h.rect, x, z), true,
			label .. " free pavement in front of door " .. k)
	end
	-- No street or block on the foundation.
	for i, s in ipairs(plan.streets) do
		eq(overlaps(s.rect, h.rect), false, label .. " street " .. i .. " clear of hall")
	end
	for i, b in ipairs(plan.blocks) do
		eq(overlaps(b.rect, h.rect), false, label .. " block " .. i .. " clear of hall")
	end
	-- The hall is outside site_order; the original four are unchanged.
	eq(#plan.site_order, 4, label .. " site_order unchanged")
end

for _, name in ipairs({"wide", "deep"}) do
	local hall = HALLS[name]
	local prof = profile_with(hall)
	for _, seed in ipairs(SEEDS) do
		local label = name .. " seed " .. seed
		local plan, why = planner.plan({x = 50, z = 20}, seed, {landmarks = prof})
		eq(plan ~= nil, true, label .. " planned: " .. tostring(why))
		if plan then
			check(plan, hall, label)
			local again = planner.plan({x = 50, z = 20}, seed, {landmarks = prof})
			local a, b = plan.sites.city_hall, again and again.sites.city_hall
			eq(b ~= nil and a.rect.x1 == b.rect.x1 and a.rect.z1 == b.rect.z1
				and a.side == b.side and again.attempts == plan.attempts, true,
				label .. " reproduces")
		end
	end
end

-- Real catalog tower on several seeds, other sites unchanged from the
-- hall-less profile whenever the same attempt succeeds.
for _, seed in ipairs(SEEDS) do
	local label = "tower seed " .. seed
	local plan, why = planner.plan({x = 0, z = 0}, seed, {landmarks = base})
	eq(plan ~= nil, true, label .. " planned: " .. tostring(why))
	if plan then
		check(plan, base.city_hall, label)
		local plain = planner.plan({x = 0, z = 0}, seed,
			{landmarks = {cathedral = base.cathedral, castle = base.castle}})
		eq(plain ~= nil and plain.sites.city_hall == nil, true, label .. " hall-less plan has none")
		if plain and plain.attempts == plan.attempts then
			for _, nm in ipairs({"cathedral", "castle", "market"}) do
				local a, b = plan.sites[nm].rect, plain.sites[nm].rect
				eq(a.x1 == b.x1 and a.z1 == b.z1 and a.x2 == b.x2 and a.z2 == b.z2, true,
					label .. " " .. nm .. " unchanged by the hall")
			end
		end
	end
end

-- Translation keeps the shape.
do
	local prof = profile_with(HALLS.wide)
	local a = planner.plan({x = 0, z = 0}, 3, {landmarks = prof})
	local b = planner.plan({x = 300, z = -200}, 3, {landmarks = prof})
	eq(a ~= nil and b ~= nil, true, "translation plans")
	if a and b then
		eq(b.sites.city_hall.rect.x1 - a.sites.city_hall.rect.x1, 300, "hall translated x")
		eq(b.sites.city_hall.rect.z1 - a.sites.city_hall.rect.z1, -200, "hall translated z")
	end
end

-- The market grows only as far as the hall box needs.
do
	local plan = planner.plan({x = 0, z = 0}, 2, {landmarks = profile_with(HALLS.wide)})
	eq(plan ~= nil, true, "wide hall plan")
	if plan then
		local mk = plan.sites.market.rect
		local need = 18 + 2 * planner.CONSTANTS.CITY_HALL_MARGIN
		eq(mk.x2 - mk.x1 + 1 >= need and mk.z2 - mk.z1 + 1 >= need, true,
			"market enlarged for the hall box")
		eq(#plan.approaches, 2, "approaches kept")
		eq(planner.render(plan):find("H", 1, true) ~= nil, true, "render shows the hall")
	end
end

-- Tampering is rejected.
do
	local plan = planner.plan({x = 0, z = 0}, 2, {landmarks = base})
	eq(plan ~= nil, true, "tamper base")
	if plan then
		local h = plan.sites.city_hall
		local function shift(r) r.x1, r.x2 = r.x1 - 40, r.x2 - 40 end
		shift(h.rect)
		shift(h.approach.edge)
		h.approach.pos.x = h.approach.pos.x - 40
		h.entrance.x = h.entrance.x - 40
		h.door.outside.x = h.door.outside.x - 40
		eq(planner.validate(plan), nil, "hall moved off the market rejected")
	end
	plan = planner.plan({x = 0, z = 0}, 2, {landmarks = base})
	if plan then
		plan.sites.city_hall.square = "parvis"
		eq(planner.validate(plan), nil, "hall naming another square rejected")
	end
	plan = planner.plan({x = 0, z = 0}, 2, {landmarks = base})
	if plan then
		-- A street laid across the foundation is rejected.
		local h = plan.sites.city_hall.rect
		plan.streets[#plan.streets + 1] = {
			id = #plan.streets + 1, kind = "principal", width = 6, axis = "x",
			material = planner.CONSTANTS.PRINCIPAL_MATERIAL, route = "secondary",
			rect = {x1 = h.x1, z1 = h.z1, x2 = h.x1 + 5, z2 = h.z1 + 5},
		}
		eq(planner.validate(plan), nil, "street over the hall rejected")
	end
end

-- A hall that cannot fit fails clearly, immediately, without attempts.
do
	local huge = {id = "t_huge", size = {x = 70, y = 10, z = 12},
		entrance = {x = 3, y = 1, z = 0}, ground_offset = 0}
	local plan, why, detail = planner.plan({x = 0, z = 0}, 1,
		{landmarks = profile_with(huge)})
	eq(plan, nil, "oversize hall has no plan")
	eq(detail.code, "unsupported_fit", "oversize hall code")
	eq(detail.attempts, 0, "oversize hall attempts")
	eq(tostring(why):find("city hall", 1, true) ~= nil, true, "oversize reason names the hall")
	fails(function()
		planner.plan({x = 0, z = 0}, 1, {landmarks = profile_with(
			{size = {x = 5, y = 5, z = 5}, entrance = {x = 9, z = 0}})})
	end, "entrance lies outside", "bad hall entrance is an error")
end

-- Legacy (no profile) output carries no hall.
do
	local plan = planner.plan({x = 0, z = 0}, 3)
	eq(plan ~= nil and plan.sites.city_hall == nil, true, "legacy plan has no hall")
end
