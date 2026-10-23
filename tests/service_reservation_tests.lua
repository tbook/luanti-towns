-- Service reservation tests (ticket #41). Loaded by tests/run.lua:
--   loadfile("tests/service_reservation_tests.lua")(eq, fails, planner, catalog, geometry)
local eq, fails, planner, catalog, geometry = ...
local authored_plan = dofile("src/authored_plan.lua")

local packer = dofile("src/frontage_packer.lua")(geometry)
local jailmod = dofile("src/jail_reservation.lua")(packer)
local svc = dofile("src/service_reservation.lua")(packer, jailmod.occupied_rects)

local function overlaps(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end
local function d2(a, b) return (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2 end

-- Pure fixture: one 100x12 block with one street run along z = 0.
local row_plan = dofile("tests/frontage_plan_fixture.lua")
local function fixture(extra_sites, square_face)
	return row_plan{sites = extra_sites, square_face = square_face}
end
local function mixed_frontage_fixture()
	return {
		seed = 1,
		sites = {market = {kind = "square", rect = {x1 = 0, z1 = -4, x2 = 11, z2 = -1}}},
		blocks = {{id = 1, rect = {x1 = 0, z1 = 0, x2 = 11, z2 = 11}}},
		frontage = {
			{id = 1, block = 1, square = "market", facing = {x = 0, z = -1},
				rect = {x1 = 0, z1 = 0, x2 = 11, z2 = 0}},
			{id = 2, block = 1, street = 1, facing = {x = -1, z = 0},
				rect = {x1 = 0, z1 = 0, x2 = 0, z2 = 11}},
		},
	}
end
local function entry(id, w, d, ex)
	return {id = id, size = {x = w, y = 5, z = d}, entrance = {x = ex or 0, y = 1, z = 0}}
end

-- Square candidates win shared corner space even when the seeded draw over
-- all candidates would otherwise select the street-facing placement.
do
	local plan = mixed_frontage_fixture()
	local pl = svc.reserve(plan, {tavern = entry("t", 12, 6)},
		{seed = 1, targets = {tavern = 1}})
	eq(#pl, 1, "mixed frontage service placed")
	eq(plan.frontage[pl[1].frontage].square, "market", "mixed frontage prefers square")
end

-- Services can reserve an eligible square frontage when no street run exists.
do
	local plan = fixture(nil, true)
	local pl, sh = svc.reserve(plan, {tavern = entry("t", 10, 4)},
		{targets = {tavern = 2}})
	eq(#pl, 2, "square services placed")
	eq(#sh, 0, "square services no shortage")
	for i, p in ipairs(pl) do
		local run = plan.frontage[p.frontage]
		eq(run.square, "market", "square service face")
		local placed = geometry.place(entry("t", 10, 4),
			{x = p.rect.x1, y = 0, z = p.rect.z1}, p.rotation)
		eq(placed.front.x, run.facing.x, "square service faces pavement x " .. i)
		eq(placed.front.z, run.facing.z, "square service faces pavement z " .. i)
		eq(placed.outside.z, -1, "square service reaches pavement " .. i)
	end
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

-- Variants (#114): every id of a role shares its slots. Over seeds 1-8 both
-- tavern templates are chosen, each placement is a variant, and a fixed seed
-- repeats exactly.
do
	local pool = {entry("ta", 10, 4), entry("tb", 10, 4)}
	local seen = {}
	for seed = 1, 8 do
		local label = "variant seed " .. seed
		local pl, sh = svc.reserve(fixture(), {tavern = pool[1]},
			{seed = seed, targets = {tavern = 3}, variants = {tavern = pool}})
		eq(#pl, 3, label .. " placed")
		eq(#sh, 0, label .. " no shortage")
		local again = svc.reserve(fixture(), {tavern = pool[1]},
			{seed = seed, targets = {tavern = 3}, variants = {tavern = pool}})
		for i, p in ipairs(pl) do
			seen[p.building_id] = true
			eq(p.role, "tavern", label .. " role " .. i)
			eq(p.building_id == "ta" or p.building_id == "tb", true, label .. " variant " .. i)
			eq(again[i].building_id == p.building_id and again[i].rect.x1 == p.rect.x1, true,
				label .. " repeatable " .. i)
		end
	end
	eq(seen.ta and seen.tb, true, "both variants appear across seeds")
end

-- Pattern balance (#114): over seeds 1-300 all eight variant patterns of two
-- variants across three slots occur, none dominating (expected 37.5 each).
do
	local pool = {entry("ta", 10, 4), entry("tb", 10, 4)}
	local count = {}
	for seed = 1, 300 do
		local pl = svc.reserve(fixture(), {tavern = pool[1]},
			{seed = seed, targets = {tavern = 3}, variants = {tavern = pool}})
		local code = {}
		for i, p in ipairs(pl) do code[i] = p.building_id == "ta" and "a" or "b" end
		local key = table.concat(code)
		count[key] = (count[key] or 0) + 1
	end
	for _, pat in ipairs({"aaa", "aab", "aba", "abb", "baa", "bab", "bba", "bbb"}) do
		local c = count[pat] or 0
		eq(c >= 15 and c <= 60, true, "pattern " .. pat .. " rate " .. c)
	end
end

-- Fallback (#114): the preferred variant may be too wide for the only block;
-- the other variant fills the slots before any shortage is reported.
do
	local pool = {entry("big", 30, 4), entry("small", 10, 4)}
	for seed = 1, 8 do
		local plan = fixture()
		plan.blocks[1].rect.x2 = 24
		plan.frontage[1].rect.x2 = 24
		local pl, sh = svc.reserve(plan, {tavern = pool[2]},
			{seed = seed, targets = {tavern = 2}, variants = {tavern = pool}})
		eq(#pl, 2, "fallback seed " .. seed .. " placed")
		eq(#sh, 0, "fallback seed " .. seed .. " no shortage")
		for _, p in ipairs(pl) do eq(p.building_id, "small", "fallback uses small") end
	end
end

-- No variant fits: one shortage naming the role, nothing placed.
do
	local pool = {entry("big", 30, 4), entry("wide", 40, 4)}
	local plan = fixture()
	plan.blocks[1].rect.x2 = 24
	plan.frontage[1].rect.x2 = 24
	local pl, sh = svc.reserve(plan, {tavern = pool[1]},
		{seed = 1, targets = {tavern = 1}, variants = {tavern = pool}})
	eq(#pl, 0, "no variant fits: none placed")
	eq(#sh, 1, "no variant fits: one shortage")
	eq(sh[1].role, "tavern", "no variant fits: role")
	eq(sh[1].placed, 0, "no variant fits: placed")
	eq(type(sh[1].reason) == "string" and sh[1].reason:find("has room for the tavern") ~= nil,
		true, "no variant fits: reason")
end

-- Stock catalog profile: the real service entries on the small fixture.
local base = assert(planner.landmark_profile(catalog.snapshot()))
eq(#base.service_variants.tavern, 2, "stock tavern variants")
eq(base.service_variants.tavern[1].id, "tavern", "first tavern variant is services.tavern")
eq(base.service_variants.tavern[2].id, "tavern_2", "second tavern variant")
eq(base.services.tavern.id, "tavern", "services.tavern stays the first variant")
local one = assert(planner.landmark_profile(catalog.snapshot(), {tavern = "tavern"}))
eq(#one.service_variants.tavern, 1, "explicit tavern id is the only variant")
eq(base.services ~= nil, true, "profile carries services")
eq(base.services.tavern.id, "tavern", "tavern id")
eq(base.services.well.id, "well", "well id")
eq(base.services.chapel.id, "chapel", "chapel id")

-- Across seeds both stock tavern templates are placed as tavern slots, and
-- the three taverns, three wells and two chapels of the stock catalog fit a
-- 200-node street run (the chapels' hard distances apply).
do
	local seen = {}
	for seed = 1, 8 do
		local plan = row_plan{length = 200, depth = 20, seed = seed,
			sites = {cathedral = {rect = {x1 = 90, z1 = 50, x2 = 100, z2 = 60},
				entrance = {x = 95, z = 50}}}}
		local pl, sh, counts = svc.reserve(plan, base.services,
			{variants = base.service_variants})
		eq(counts.tavern.placed, 3, "stock taverns seed " .. seed)
		eq(counts.well.placed, 3, "stock wells seed " .. seed)
		eq(counts.chapel.placed, 2, "stock chapels seed " .. seed)
		eq(#sh, 0, "stock no shortage seed " .. seed)
		for _, p in ipairs(pl) do
			if p.role == "tavern" then seen[p.building_id] = true end
			for _, q in ipairs(pl) do
				if p ~= q then eq(overlaps(p.rect, q.rect), false, "stock disjoint seed " .. seed) end
			end
		end
	end
	eq(seen.tavern and seen.tavern_2, true, "stock both tavern templates appear")
end

-- Real planner integration: services reserved in a generated medieval plan.
-- The default run checks seed 1 (and a no-services profile); the full run
-- sweeps seeds 1-8.
local FULL = os.getenv("TOWNS_TEST_FULL") == "1"
local function check_planned(seed)
	local label = "services seed " .. seed
	local plan = assert(planner.plan({x = 10, z = -30}, seed, {landmarks = base}))
	eq(authored_plan.validate(plan), true, label .. " validates")
	local res = plan.reservations
	local counts = res.service_counts
	eq(counts.tavern.placed, 3, label .. " taverns")
	eq(counts.well.placed, 3, label .. " wells")
	-- Seeds 1-8 place both chapels with the #126 town hall; a shortage is
	-- reported, never a failed plan.
	eq(counts.chapel.placed, 2, label .. " chapels")
	eq(#plan.shortages, 0, label .. " shortages")
	local all = {}
	for _, s in pairs(plan.sites) do all[#all + 1] = s.rect end
	for _, s in ipairs(plan.streets) do all[#all + 1] = s.rect end
	all[#all + 1] = res.jail.rect
	for i, p in ipairs(res.services) do
		local b = plan.blocks[p.block].rect
		eq(p.rect.x1 >= b.x1 and p.rect.x2 <= b.x2 and p.rect.z1 >= b.z1
			and p.rect.z2 <= b.z2, true, label .. " in block " .. i)
		eq(plan.frontage[p.frontage].street ~= nil or plan.frontage[p.frontage].square ~= nil,
			true, label .. " eligible frontage run " .. i)
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
end
for seed = 1, FULL and 8 or 1 do check_planned(seed) end

-- Impossible chapel minimums are diagnostics, not failed plans.
do
	-- populate reads planner.CONSTANTS when it runs; restore straight after.
	local saved = planner.CONSTANTS.CHAPEL_MIN_FROM_CATHEDRAL
	planner.CONSTANTS.CHAPEL_MIN_FROM_CATHEDRAL = 100000
	local plan = assert(planner.plan({x = 0, z = 0}, 2, {landmarks = base}))
	planner.CONSTANTS.CHAPEL_MIN_FROM_CATHEDRAL = saved
	eq(plan.reservations.service_counts.chapel.placed, 0, "impossible chapel unmet")
	eq(#plan.shortages, 1, "one shortage")
	eq(plan.shortages[1].role, "chapel", "chapel shortage role")
	eq(authored_plan.validate(plan), true, "shortage plan validates")
end

-- Profiles without services carry no service fields.
do
	local prof = {cathedral = base.cathedral, castle = base.castle,
		city_hall = base.city_hall, jail = base.jail}
	local plan = assert(planner.plan({x = 0, z = 0}, 2, {landmarks = prof}))
	eq(plan.reservations.services, nil, "no services without profile entry")
	eq(plan.reservations.service_counts, nil, "no counts without profile entry")
end
