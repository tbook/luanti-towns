-- Service reservation tests (ticket #41). Loaded by tests/run.lua:
--   loadfile("tests/service_reservation_tests.lua")(eq, fails, planner, catalog, geometry)
local eq, fails, planner, catalog, geometry = ...

local packer = dofile("src/frontage_packer.lua")(geometry)
local jailmod = dofile("src/jail_reservation.lua")(packer)
local svc = dofile("src/service_reservation.lua")(packer, jailmod.occupied_rects)

local function overlaps(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end
local function d2(a, b) return (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2 end

-- Pure fixture: one 100x12 block with one street run along z = 0.
local function fixture(extra_sites)
	local sites = {market = {rect = {x1 = 200, z1 = 200, x2 = 210, z2 = 210}}}
	for k, v in pairs(extra_sites or {}) do sites[k] = v end
	return {
		seed = 5, sites = sites,
		blocks = {{id = 1, rect = {x1 = 0, z1 = 0, x2 = 99, z2 = 11}}},
		frontage = {{id = 1, block = 1, street = 1, facing = {x = 0, z = -1},
			rect = {x1 = 0, z1 = 0, x2 = 99, z2 = 0}}},
	}
end
local function entry(id, w, d, ex)
	return {id = id, size = {x = w, y = 5, z = d}, entrance = {x = ex or 0, y = 1, z = 0}}
end

-- Separated choices: ten 10-wide slots, three taverns; after the seeded
-- first, the second is the farthest end slot.
do
	local plan = fixture()
	local pl, sh, counts = svc.reserve(plan, {tavern = entry("t", 10, 4)},
		{targets = {tavern = 3}})
	eq(#pl, 3, "three taverns placed")
	eq(#sh, 0, "no shortage")
	eq(counts.tavern.placed, 3, "count placed")
	eq(counts.tavern.wanted, 3, "count wanted")
	local first = pl[1].rect.x1
	eq(pl[2].rect.x1, first >= 50 and 0 or 90, "second tavern farthest from first")
	for i = 1, 3 do
		for j = i + 1, 3 do
			eq(overlaps(pl[i].rect, pl[j].rect), false, "taverns disjoint " .. i .. j)
		end
	end
	local pl2 = svc.reserve(fixture(), {tavern = entry("t", 10, 4)}, {targets = {tavern = 3}})
	for i = 1, 3 do eq(pl2[i].rect.x1, pl[i].rect.x1, "repeatable " .. i) end
end

-- Deterministic ties: cathedral entrance midway between the two end slots
-- of a three-slot run; both are equally far, the first in order wins.
do
	local plan = fixture()
	plan.blocks[1].rect.x2 = 29
	plan.frontage[1].rect.x2 = 29
	plan.sites.cathedral = {rect = {x1 = 10, z1 = 50, x2 = 19, z2 = 59},
		entrance = {x = 14, z = 0}}
	-- Middle slot entrance is at x = 10 (entrance offset 0); end slots at 0
	-- and 20 are 14 and 6 away... use entrance offset 5 so slots are at
	-- 5, 15, 25 and the cathedral at 15 makes 5 and 25 tie.
	plan.sites.cathedral.entrance = {x = 15, z = 0}
	local pl = svc.reserve(plan, {chapel = entry("c", 10, 4, 5)},
		{targets = {chapel = 1}, chapel_min_cathedral = 0, chapel_min_between = 0})
	eq(#pl, 1, "tie chapel placed")
	eq(pl[1].rect.x1, 0, "tie resolves to first in frontage order")
end

-- Narrow block: nothing fits, clear diagnostic and no placement.
do
	local pl, sh, counts = svc.reserve(fixture(), {well = entry("w", 10, 20)},
		{targets = {well = 3}})
	eq(#pl, 0, "narrow: none placed")
	eq(#sh, 1, "narrow: one shortage")
	eq(sh[1].role, "well", "narrow role")
	eq(sh[1].wanted, 3, "narrow wanted")
	eq(sh[1].placed, 0, "narrow placed")
	eq(type(sh[1].reason) == "string" and #sh[1].reason > 0, true, "narrow reason")
	eq(counts.well.placed, 0, "narrow count")
end

-- Partial: the run holds only two boxes, target three.
do
	local plan = fixture()
	plan.blocks[1].rect.x2 = 24
	plan.frontage[1].rect.x2 = 24
	local pl, sh = svc.reserve(plan, {tavern = entry("t", 10, 4)}, {targets = {tavern = 3}})
	eq(#pl, 2, "partial placed")
	eq(sh[1].placed, 2, "partial shortage placed")
end

-- Reserved geometry (site, jail reservation) is never overlapped.
do
	local plan = fixture({hall = {rect = {x1 = 0, z1 = 0, x2 = 39, z2 = 5}}})
	plan.reservations = {jail = {rect = {x1 = 40, z1 = 0, x2 = 59, z2 = 5}}}
	local pl, sh = svc.reserve(plan, {tavern = entry("t", 10, 4)}, {targets = {tavern = 5}})
	eq(#pl, 4, "four slots left outside hall and jail")
	eq(#sh, 1, "shortage when targets exceed space")
	for i, p in ipairs(pl) do
		eq(overlaps(p.rect, plan.sites.hall.rect), false, "clear of hall " .. i)
		eq(overlaps(p.rect, plan.reservations.jail.rect), false, "clear of jail " .. i)
	end
end

-- Chapel hard minimums.
do
	local plan = fixture()
	plan.sites.cathedral = {rect = {x1 = 0, z1 = 50, x2 = 5, z2 = 55},
		entrance = {x = 50, z = 0}}
	local pl, sh = svc.reserve(plan, {chapel = entry("c", 10, 4)},
		{targets = {chapel = 2}, chapel_min_cathedral = 500})
	eq(#pl, 0, "chapel minimum from cathedral rejects all")
	eq(sh[1].role, "chapel", "chapel shortage")
	-- Cathedral entrance at x = 0 makes the first chapel the far end (x = 90).
	local plan2 = fixture()
	plan2.sites.cathedral = {rect = {x1 = 0, z1 = 50, x2 = 5, z2 = 55},
		entrance = {x = 0, z = 0}}
	local pl2, sh2 = svc.reserve(plan2, {chapel = entry("c", 10, 4)},
		{targets = {chapel = 3}, chapel_min_cathedral = 0, chapel_min_between = 70})
	eq(#pl2, 2, "two chapels at 70 apart")
	eq(d2(pl2[1].entrance, pl2[2].entrance) >= 70 * 70, true, "chapels 70 apart")
	eq(#sh2, 1, "third chapel is a shortage")
end

-- Stock catalog plans.
local base = assert(planner.landmark_profile(catalog.snapshot()))
eq(base.services ~= nil, true, "profile carries services")
eq(base.services.tavern.id, "tavern", "tavern id")
eq(base.services.well.id, "well", "well id")
eq(base.services.chapel.id, "chapel", "chapel id")

for seed = 1, 8 do
	local label = "services seed " .. seed
	local plan = assert(planner.plan({x = 10, z = -30}, seed, {landmarks = base}))
	eq(planner.validate(plan), true, label .. " validates")
	local res = plan.reservations
	local counts = res.service_counts
	eq(counts.tavern.placed, 3, label .. " taverns")
	eq(counts.well.placed, 3, label .. " wells")
	-- Seeds 1-8 place both chapels with the #126 town hall (seed 4 had a
	-- reported shortage under #106, seed 3 under #86, when no frontage was left
	-- for a second chapel 70 away; a shortage is reported, never a failed plan).
	local want_chapels = 2
	eq(counts.chapel.placed, want_chapels, label .. " chapels")
	eq(#plan.shortages, 2 - want_chapels, label .. " shortages")
	local all = {}
	for _, s in pairs(plan.sites) do all[#all + 1] = s.rect end
	for _, s in ipairs(plan.streets) do all[#all + 1] = s.rect end
	all[#all + 1] = res.jail.rect
	for i, p in ipairs(res.services) do
		local b = plan.blocks[p.block].rect
		eq(p.rect.x1 >= b.x1 and p.rect.x2 <= b.x2 and p.rect.z1 >= b.z1
			and p.rect.z2 <= b.z2, true, label .. " in block " .. i)
		eq(plan.frontage[p.frontage].street ~= nil, true, label .. " street run " .. i)
		for _, r in ipairs(all) do
			eq(overlaps(p.rect, r), false, label .. " clear of reserved " .. i)
		end
		for j = i + 1, #res.services do
			eq(overlaps(p.rect, res.services[j].rect), false, label .. " disjoint " .. i .. j)
		end
	end
	local cath = plan.sites.cathedral.entrance
	local chapels = {}
	for _, p in ipairs(res.services) do
		if p.role == "chapel" then
			chapels[#chapels + 1] = p
			eq(d2(p.entrance, cath) >= 40 * 40, true, label .. " chapel >= 40 from cathedral")
		end
	end
	if #chapels == 2 then
		eq(d2(chapels[1].entrance, chapels[2].entrance) >= 70 * 70, true, label .. " chapels >= 70 apart")
	end
	local again = planner.plan({x = 10, z = -30}, seed, {landmarks = base})
	local a, b = res.services, again.reservations.services
	local same = #a == #b
	for i = 1, #a do
		same = same and a[i].rect.x1 == b[i].rect.x1 and a[i].rect.z1 == b[i].rect.z1
	end
	eq(same, true, label .. " reproduces")
end

-- Impossible chapel minimums are diagnostics, not failed plans.
do
	local plan = assert(planner.plan({x = 0, z = 0}, 2, {landmarks = base,
		constants = {CHAPEL_MIN_FROM_CATHEDRAL = 100000}}))
	eq(plan.reservations.service_counts.chapel.placed, 0, "impossible chapel unmet")
	eq(#plan.shortages, 1, "one shortage")
	eq(plan.shortages[1].role, "chapel", "chapel shortage role")
	eq(planner.validate(plan), true, "shortage plan validates")
end

-- Profiles without services (and legacy plans) carry no service fields.
do
	local prof = {cathedral = base.cathedral, castle = base.castle,
		city_hall = base.city_hall, jail = base.jail}
	local plan = assert(planner.plan({x = 0, z = 0}, 2, {landmarks = prof}))
	eq(plan.reservations.services, nil, "no services without profile entry")
	eq(plan.reservations.service_counts, nil, "no counts without profile entry")
	local legacy = assert(planner.plan({x = 0, z = 0}, 3))
	eq(legacy.reservations == nil and legacy.shortages == nil, true, "legacy untouched")
end
