-- City hall reservation tests (tickets #39, #106): the hall stands beside the
-- open market, outside it, its entrance side facing across one market edge.
-- Loaded by tests/run.lua:
--   loadfile("tests/city_hall_tests.lua")(eq, fails, planner, catalog, geometry)
local eq, fails, planner, catalog, geometry = ...

local SEEDS = {1, 2, 3, 4, 5, 6, 7, 8}

local function in_rect(r, x, z)
	return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2
end

local function overlaps(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

local function gap_between(a, b)
	local gx = math.max(a.x1 - b.x2 - 1, b.x1 - a.x2 - 1)
	local gz = math.max(a.z1 - b.z2 - 1, b.z1 - a.z2 - 1)
	return math.max(gx, gz)
end

local base = assert(planner.landmark_profile(catalog.snapshot()))
eq(base.city_hall ~= nil, true, "catalog profile carries the city hall")
eq(base.city_hall.id, "tower", "catalog hall id")
eq(base.city_hall.size.x, 8, "tower size x")

-- Synthetic asymmetric halls: long with an off-centre door; deep with the
-- door near a corner; a larger one with a recessed off-centre door.
local HALLS = {
	wide = {id = "t_wide", size = {x = 18, y = 14, z = 9},
		entrance = {x = 13, y = 2, z = 3}, ground_offset = 1},
	deep = {id = "t_deep", size = {x = 7, y = 20, z = 16},
		entrance = {x = 1, y = 1, z = 2}, ground_offset = 0},
	grand = {id = "t_grand", size = {x = 26, y = 16, z = 16},
		entrance = {x = 20, y = 1, z = 3}, ground_offset = 0},
}
local SIDES_SEEN = {}

local function profile_with(hall)
	return {cathedral = base.cathedral, castle = base.castle, city_hall = hall}
end

local function check(plan, hall, label)
	eq(planner.validate(plan), true, label .. " validates")
	local h = plan.sites.city_hall
	eq(h ~= nil, true, label .. " has a hall")
	if not h then return end
	local mk = plan.sites.market.rect
	local sw = planner.CONSTANTS.STREET_WIDTH
	local g = geometry.place({size = hall.size, entrance = hall.entrance},
		{x = h.rect.x1, y = 0, z = h.rect.z1}, h.rotation)
	-- Complete rotated box, wholly OUTSIDE the open market rectangle.
	eq(h.rect.x2 - h.rect.x1 + 1, g.size.x, label .. " box width")
	eq(h.rect.z2 - h.rect.z1 + 1, g.size.z, label .. " box depth")
	eq(overlaps(h.rect, mk), false, label .. " hall outside the open market")
	-- Touches the market edge its entrance side faces, facade within it.
	local s = h.side
	SIDES_SEEN[s] = true
	local touch, within
	if s == "-z" then
		touch = h.rect.z1 == mk.z2 + 1; within = h.rect.x1 >= mk.x1 and h.rect.x2 <= mk.x2
	elseif s == "+z" then
		touch = h.rect.z2 == mk.z1 - 1; within = h.rect.x1 >= mk.x1 and h.rect.x2 <= mk.x2
	elseif s == "-x" then
		touch = h.rect.x1 == mk.x2 + 1; within = h.rect.z1 >= mk.z1 and h.rect.z2 <= mk.z2
	else
		touch = h.rect.x2 == mk.x1 - 1; within = h.rect.z1 >= mk.z1 and h.rect.z2 <= mk.z2
	end
	eq(touch, true, label .. " touches the market edge it faces")
	eq(within, true, label .. " facade within the market edge")
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
	for k = 0, sw - 1 do
		local x, z = p.x + h.facing.x * k, p.z + h.facing.z * k
		eq(in_rect(mk, x, z) and not in_rect(h.rect, x, z), true,
			label .. " market pavement in front of door " .. k)
	end
	-- No street or block on the foundation.
	for i, st in ipairs(plan.streets) do
		eq(overlaps(st.rect, h.rect), false, label .. " street " .. i .. " clear of hall")
	end
	for i, b in ipairs(plan.blocks) do
		eq(overlaps(b.rect, h.rect), false, label .. " block " .. i .. " clear of hall")
	end
	-- A street width clear of the other landmarks and the parvis.
	for _, nm in ipairs({"cathedral", "parvis", "castle"}) do
		eq(gap_between(h.rect, plan.sites[nm].rect) >= sw, true, label .. " clear of " .. nm)
	end
	-- Ordinary buildings and reserved services keep off the footprint.
	for i, b in ipairs(plan.content and plan.content.buildings or {}) do
		eq(overlaps(b.rect, h.rect), false, label .. " building " .. i .. " clear of hall")
	end
	-- The hall is outside site_order; the original four are unchanged.
	eq(#plan.site_order, 4, label .. " site_order unchanged")
end

for _, name in ipairs({"wide", "deep", "grand"}) do
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

-- Real catalog tower on several seeds. The open market is sized without
-- regard to the hall (no ring), so it stays in the ordinary market range.
for _, seed in ipairs(SEEDS) do
	local label = "tower seed " .. seed
	local plan, why = planner.plan({x = 0, z = 0}, seed, {landmarks = base})
	eq(plan ~= nil, true, label .. " planned: " .. tostring(why))
	if plan then
		check(plan, base.city_hall, label)
		local mk, C = plan.sites.market.rect, planner.CONSTANTS
		eq(mk.x2 - mk.x1 + 1 >= C.MARKET_MIN and mk.x2 - mk.x1 + 1 <= C.MARKET_MAX
			and mk.z2 - mk.z1 + 1 >= C.MARKET_MIN and mk.z2 - mk.z1 + 1 <= C.MARKET_MAX,
			true, label .. " market sized independently of the hall")
		local plain = planner.plan({x = 0, z = 0}, seed,
			{landmarks = {cathedral = base.cathedral, castle = base.castle}})
		eq(plain ~= nil and plain.sites.city_hall == nil, true, label .. " hall-less plan has none")
	end
end

-- Over the seeds the hall is not always on the same market side.
do
	local n = 0
	for _ in pairs(SIDES_SEEN) do n = n + 1 end
	eq(n >= 2, true, "hall entrance sides vary over the seeds")
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

-- The market only has to be as long as the facade; the hall depth adds nothing.
do
	local plan = planner.plan({x = 0, z = 0}, 2, {landmarks = profile_with(HALLS.grand)})
	eq(plan ~= nil, true, "grand hall plan")
	if plan then
		local mk = plan.sites.market.rect
		eq(mk.x2 - mk.x1 + 1 >= 26 and mk.z2 - mk.z1 + 1 >= 26, true,
			"market at least as long as the facade")
		eq(#plan.approaches, 2, "approaches kept")
		eq(planner.render(plan):find("H", 1, true) ~= nil, true, "render shows the hall")
	end
end

-- Tampering is rejected.
do
	local function fresh()
		local plan = planner.plan({x = 0, z = 0}, 2, {landmarks = base})
		eq(plan ~= nil, true, "tamper base")
		return plan
	end
	local function move_hall(plan, dx, dz)
		local h = plan.sites.city_hall
		local r, e = h.rect, h.approach.edge
		r.x1, r.x2, r.z1, r.z2 = r.x1 + dx, r.x2 + dx, r.z1 + dz, r.z2 + dz
		e.x1, e.x2, e.z1, e.z2 = e.x1 + dx, e.x2 + dx, e.z1 + dz, e.z2 + dz
		for _, q in ipairs({h.approach.pos, h.entrance, h.door.outside}) do
			q.x, q.z = q.x + dx, q.z + dz
		end
	end
	local plan = fresh()
	if plan then
		move_hall(plan, -40, 0)
		eq(planner.validate(plan), nil, "hall moved off the market rejected")
	end
	plan = fresh()
	if plan then
		-- One node along the facing axis: into the market.
		local f = plan.sites.city_hall.facing
		move_hall(plan, f.x, f.z)
		eq(planner.validate(plan), nil, "hall shifted into the market rejected")
	end
	plan = fresh()
	if plan then
		local f = plan.sites.city_hall.facing
		move_hall(plan, -f.x, -f.z)
		eq(planner.validate(plan), nil, "hall shifted off the market edge rejected")
	end
	plan = fresh()
	if plan then
		plan.sites.city_hall.square = "parvis"
		eq(planner.validate(plan), nil, "hall naming another square rejected")
	end
	plan = fresh()
	if plan then
		-- A street laid across the foundation is rejected.
		local h = plan.sites.city_hall.rect
		plan.streets[#plan.streets + 1] = {
			id = #plan.streets + 1, kind = "principal", width = planner.CONSTANTS.STREET_WIDTH, axis = "x",
			material = planner.CONSTANTS.PRINCIPAL_MATERIAL, route = "secondary",
			rect = {x1 = h.x1, z1 = h.z1, x2 = h.x1 + planner.CONSTANTS.STREET_WIDTH - 1,
				z2 = h.z1 + planner.CONSTANTS.STREET_WIDTH - 1},
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

-- Builder-side pavement map: the whole open market is paved, the hall
-- foundation (outside it) is not.
do
	local fake_bo = {MAX_HEIGHT = 40, names = function() return {} end}
	local TL = dofile("src/town_layout.lua")(fake_bo)
	local plan = planner.plan({x = 0, z = 0}, 2, {landmarks = base})
	eq(plan ~= nil, true, "pavement map plan")
	if plan then
		local map = TL.pavement_map(plan)
		local h, mk = plan.sites.city_hall.rect, plan.sites.market.rect
		local bad, paved = 0, 0
		for x = mk.x1, mk.x2 do
			for z = mk.z1, mk.z2 do
				if map[x] and map[x][z] ~= nil then paved = paved + 1 end
			end
		end
		for x = h.x1, h.x2 do
			for z = h.z1, h.z2 do
				if map[x] and map[x][z] ~= nil then bad = bad + 1 end
			end
		end
		eq(bad, 0, "no pavement under the hall")
		eq(paved, (mk.x2 - mk.x1 + 1) * (mk.z2 - mk.z1 + 1), "whole open market paved")
	end
end
