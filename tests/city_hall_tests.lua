-- City hall tests (tickets #39, #106, reworked for the row-grid planner of
-- issue #184): the hall stands on the market's far edge, outside the paved
-- market, its entrance facing across it. Loaded by tests/run.lua:
--   loadfile("tests/city_hall_tests.lua")(eq, fails, planner, catalog, geometry)
local eq, fails, planner, catalog, geometry = ...
local authored_plan = dofile("src/authored_plan.lua")

-- The default run plans the real tower on two seeds; seeds 1-8 run under
-- TOWNS_TEST_FULL=1.
local FULL = os.getenv("TOWNS_TEST_FULL") == "1"
local SEEDS = FULL and {1, 2, 3, 4, 5, 6, 7, 8} or {1, 2}

local function in_rect(r, x, z)
	return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2
end

local function overlaps(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

local base = assert(planner.landmark_profile(catalog.snapshot()))
eq(base.city_hall ~= nil, true, "catalog profile carries the city hall")
eq(base.city_hall.id, "tower", "catalog hall id")
eq(base.city_hall.size.x, 18, "town hall size x (#126)")
eq(base.city_hall.size.y, 50, "town hall size y (#126)")
eq(base.city_hall.size.z, 21, "town hall size z (#126)")

local function check(plan, hall, label)
	eq(authored_plan.validate(plan), true, label .. " validates")
	local h = plan.sites.city_hall
	eq(h ~= nil, true, label .. " has a hall")
	if not h then return end
	local mk = plan.sites.market.rect
	local g = geometry.place(catalog.entries[hall.id], {x = h.rect.x1, y = 0, z = h.rect.z1}, h.rotation)
	-- Complete rotated box, wholly OUTSIDE the paved market rectangle.
	eq(h.rect.x2 - h.rect.x1 + 1, g.size.x, label .. " box width")
	eq(h.rect.z2 - h.rect.z1 + 1, g.size.z, label .. " box depth")
	eq(overlaps(h.rect, mk), false, label .. " hall outside the paved market")
	-- On the market's far (east) edge, facing back across it, facade within it.
	eq(h.facing.x == -1 and h.facing.z == 0, true, label .. " faces the market")
	eq(h.rect.x1, mk.x2 + 1, label .. " touches the market edge it faces")
	eq(h.rect.z1 >= mk.z1 and h.rect.z2 <= mk.z2, true, label .. " facade within the market edge")
	-- Real (rotated) door and the pavement in front of it.
	eq(h.entrance.x, g.entrance.x, label .. " entrance x")
	eq(h.entrance.z, g.entrance.z, label .. " entrance z")
	eq(h.id, hall.id, label .. " id")
	eq(h.square, "market", label .. " names the market")
	local p = h.approach.pos
	eq(in_rect(mk, p.x, p.z), true, label .. " approach on market pavement")
	eq(in_rect(h.rect, p.x, p.z), false, label .. " approach outside hall")
	for k = 0, 4 do
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
	for _, nm in ipairs({"cathedral", "parvis", "castle"}) do
		eq(overlaps(h.rect, plan.sites[nm].rect), false, label .. " clear of " .. nm)
	end
	-- Ordinary buildings and reserved services keep off the footprint.
	for i, b in ipairs(plan.content and plan.content.buildings or {}) do
		eq(overlaps(b.rect, h.rect), false, label .. " building " .. i .. " clear of hall")
	end
	eq(#plan.site_order, 5, label .. " site_order lists the hall")
end

-- Real catalog tower.
local tower_plan
for _, seed in ipairs(SEEDS) do
	local label = "tower seed " .. seed
	local plan, why = planner.plan({x = 0, z = 0}, seed, {landmarks = base})
	eq(plan ~= nil, true, label .. " planned: " .. tostring(why))
	if plan then
		tower_plan = tower_plan or plan
		check(plan, base.city_hall, label)
		local plain = planner.plan({x = 0, z = 0}, seed,
			{landmarks = {cathedral = base.cathedral, castle = base.castle}})
		eq(plain ~= nil and plain.sites.city_hall == nil, true, label .. " hall-less plan has none")
	end
end

-- A facade deeper than an ordinary inner row makes the market row deeper.
-- (The castle stands in for a very large hall.)
do
	local big = {id = "castle", size = base.castle.size, entrance = base.castle.entrance,
		ground_offset = base.castle.ground_offset}
	local prof = {cathedral = base.cathedral, castle = base.castle, city_hall = big, content = base.content}
	local plan, why = planner.plan({x = 0, z = 0}, 2, {landmarks = prof})
	eq(plan ~= nil, true, "large hall planned: " .. tostring(why))
	if plan then
		check(plan, big, "large hall")
		local mk = plan.sites.market.rect
		eq(mk.z2 - mk.z1 + 1 >= plan.sites.city_hall.size.z, true, "market row as deep as the facade")
	end
	fails(function()
		planner.plan({x = 0, z = 0}, 1, {landmarks = {cathedral = base.cathedral, castle = base.castle,
			city_hall = {size = {x = 5, y = 5, z = 5}, entrance = {x = 9, z = 0}}}})
	end, "entrance lies outside", "bad hall entrance is an error")
end

-- Tampering is rejected.
do
	local function clone(v)
		if type(v) ~= "table" then return v end
		local out = {}
		for k, x in pairs(v) do out[k] = clone(x) end
		return out
	end
	local function fresh()
		eq(tower_plan ~= nil, true, "tamper base")
		return tower_plan and clone(tower_plan)
	end
	local function move_hall(plan, dx, dz)
		local h = plan.sites.city_hall
		local r = h.rect
		r.x1, r.x2, r.z1, r.z2 = r.x1 + dx, r.x2 + dx, r.z1 + dz, r.z2 + dz
		for _, q in ipairs({h.approach.pos, h.entrance}) do
			q.x, q.z = q.x + dx, q.z + dz
		end
	end
	local plan = fresh()
	if plan then
		move_hall(plan, 40, 0)
		eq(authored_plan.validate(plan), nil, "hall moved off the market rejected")
	end
	plan = fresh()
	if plan then
		-- One node along the facing axis: into the market.
		local f = plan.sites.city_hall.facing
		move_hall(plan, f.x, f.z)
		eq(authored_plan.validate(plan), nil, "hall shifted into the market rejected")
	end
	plan = fresh()
	if plan then
		local f = plan.sites.city_hall.facing
		move_hall(plan, -f.x, -f.z)
		eq(authored_plan.validate(plan), nil, "hall shifted off the market edge rejected")
	end
	plan = fresh()
	if plan then
		-- A street laid across the foundation is rejected.
		local h = plan.sites.city_hall.rect
		plan.streets[#plan.streets + 1] = {
			id = #plan.streets + 1, kind = "principal", width = 6, material = "mcl_core:cobble",
			rect = {x1 = h.x1, z1 = h.z1, x2 = h.x1 + 5, z2 = h.z1 + 5},
		}
		eq(authored_plan.validate(plan), nil, "street over the hall rejected")
	end
end

-- Builder-side pavement map: the whole paved market is paved, the hall
-- foundation (outside it) is not.
do
	local TL = dofile("src/town_layout.lua")
	local plan = tower_plan
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
		eq(paved, (mk.x2 - mk.x1 + 1) * (mk.z2 - mk.z1 + 1), "whole paved market paved")
	end
end
