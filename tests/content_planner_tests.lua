-- Frontage content tests (ticket #42). Loaded by tests/run.lua:
--   loadfile("tests/content_planner_tests.lua")(eq, fails, planner, catalog, geometry)
local eq, fails, planner, catalog, geometry = ...

local packer = dofile("src/frontage_packer.lua")(geometry)
local jailmod = dofile("src/jail_reservation.lua")(packer)
local content = dofile("src/content_planner.lua")(geometry, packer, jailmod.occupied_rects)

local function overlaps(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end
local function same_rect(a, b)
	return a.x1 == b.x1 and a.z1 == b.z1 and a.x2 == b.x2 and a.z2 == b.z2
end
local function entry(role, w, d, ex, ez)
	return {role = role, size = {x = w, y = 5, z = d}, entrance = {x = ex or 0, y = 1, z = ez or 0}}
end

-- Square block 0..19 with a street on every side.
local function square_fixture()
	local streets = {
		{rect = {x1 = -4, z1 = 0, x2 = -1, z2 = 19}},
		{rect = {x1 = 20, z1 = 0, x2 = 23, z2 = 19}},
	}
	return {
		seed = 7,
		sites = {
			market = {kind = "square", rect = {x1 = -4, z1 = -4, x2 = 23, z2 = -1}},
			parvis = {kind = "square", rect = {x1 = -4, z1 = 20, x2 = 23, z2 = 23}},
		},
		streets = streets,
		blocks = {{id = 1, rect = {x1 = 0, z1 = 0, x2 = 19, z2 = 19}}},
		frontage = {
			{id = 1, block = 1, square = "market", facing = {x = 0, z = -1}, rect = {x1 = 0, z1 = 0, x2 = 19, z2 = 0}},
			{id = 2, block = 1, square = "parvis", facing = {x = 0, z = 1}, rect = {x1 = 0, z1 = 19, x2 = 19, z2 = 19}},
			{id = 3, block = 1, street = 3, facing = {x = -1, z = 0}, rect = {x1 = 0, z1 = 0, x2 = 0, z2 = 19}},
			{id = 4, block = 1, street = 4, facing = {x = 1, z = 0}, rect = {x1 = 19, z1 = 0, x2 = 19, z2 = 19}},
		},
	}
end

-- Square block, four faces, one 6x5 recessed-door house: the first face wins
-- the corners, later faces respect them, everything validates.
do
	local plan = square_fixture()
	local entries = {h = entry("house", 6, 5, 2, 1)} -- door one node in
	local r = content.plan(plan, entries, {seed = 3})
	eq(#r.buildings > 4, true, "square: several buildings")
	eq(#r.rejected, 0, "square: none rejected")
	eq(content.validate(plan, r, entries), true, "square validates")
	for i, b in ipairs(r.buildings) do
		local run = plan.frontage[b.frontage]
		local g = geometry.place(entries.h, {x = b.rect.x1, y = 0, z = b.rect.z1}, b.rotation)
		local f = run.facing
		eq(g.front.x == f.x and g.front.z == f.z, true, "square facing " .. i)
		if run.square then
			local pavement = plan.sites[run.square].rect
			eq(b.approach.x >= pavement.x1 and b.approach.x <= pavement.x2
				and b.approach.z >= pavement.z1 and b.approach.z <= pavement.z2,
				true, "square door reaches named pavement " .. i)
		end
		-- Recessed door: the approach is not geometry.place().outside.
		eq(b.approach.x ~= g.outside.x or b.approach.z ~= g.outside.z, true, "square recessed " .. i)
		for j = i + 1, #r.buildings do
			eq(overlaps(b.rect, r.buildings[j].rect), false, "square disjoint " .. i .. "," .. j)
		end
	end
	local a = content.plan(square_fixture(), entries, {seed = 3})
	eq(#a.buildings, #r.buildings, "square repeat count")
	for i, b in ipairs(r.buildings) do
		eq(same_rect(a.buildings[i].rect, b.rect), true, "square repeat " .. i)
	end
	local owner
	for _, b in ipairs(r.buildings) do
		if b.rect.x1 == 0 and b.rect.z1 == 0 then owner = b.frontage end
	end
	eq(owner, 1, "square face owns the corner")
end

-- A reserved jail and service are never overlapped.
do
	local plan = square_fixture()
	plan.reservations = {jail = {rect = {x1 = 0, z1 = 0, x2 = 9, z2 = 4}},
		services = {{rect = {x1 = 10, z1 = 0, x2 = 19, z2 = 4}}}}
	local entries = {h = entry("house", 5, 5, 2)}
	local r = content.plan(plan, entries, {seed = 1})
	eq(#r.buildings > 0, true, "reserved: buildings")
	eq(content.validate(plan, r, entries), true, "reserved validates")
	for i, b in ipairs(r.buildings) do
		eq(overlaps(b.rect, plan.reservations.jail.rect), false, "clear of jail " .. i)
		eq(overlaps(b.rect, plan.reservations.services[1].rect), false, "clear of service " .. i)
	end
end

-- Missing ordinary content: empty frontage, no invalid geometry.
do
	local plan = square_fixture()
	local r = content.plan(plan, {t = entry("tavern", 5, 5)}, {seed = 1})
	eq(#r.buildings, 0, "no content: no buildings")
	eq(#r.empty_runs, 4, "no content: four empty runs")
	eq(r.empty_runs[1], 1, "no content: first square run reported empty")
	eq(r.empty_runs[2], 2, "no content: second square run reported empty")
	eq(#r.unused, 4, "no content: unused intervals")
	eq(type(r.reason), "string", "no content: reason")
	local big = content.plan(plan, {h = entry("house", 30, 5)}, {seed = 1})
	eq(#big.buildings, 0, "too big: none")
	eq(#big.empty_runs, 4, "too big: empty runs")
	eq(big.reason, nil, "too big: not a catalog shortage")
end

-- Counts add up and unused intervals are recorded.
do
	local plan = square_fixture()
	local r = content.plan(plan, {h = entry("house", 7, 3), s = entry("shop", 7, 3)}, {seed = 2})
	local sum = 0
	for _, n in pairs(r.counts) do sum = sum + n end
	eq(sum, #r.buildings, "counts add up")
	eq(#r.unused > 0, true, "unused intervals recorded")
end

-- Stock catalog across a fixed seed set; civic planning is unchanged.
local base = assert(planner.landmark_profile(catalog.snapshot()))
eq(base.content ~= nil, true, "profile carries content")
local civic = {cathedral = base.cathedral, castle = base.castle,
	city_hall = base.city_hall, jail = base.jail, services = base.services}

-- The street spacing depth (ticket #86) is derived from the catalog content,
-- so a profile without content plans without it. Pass the derived values
-- explicitly to isolate "content leaves civic planning alone".
local depth_policy = planner.depth_policy(base)
local square_placed = false

for _, seed in ipairs({1, 2, 3, 4, 5, 6, 7, 8}) do
	local label = "content seed " .. seed
	local plan = assert(planner.plan({x = 10, z = -30}, seed, {landmarks = base}))
	local without = assert(planner.plan({x = 10, z = -30}, seed,
		{landmarks = civic, constants = depth_policy}))
	eq(planner.validate(plan), true, label .. " validates")
	eq(without.content, nil, label .. " no content without profile entry")
	eq(#plan.blocks, #without.blocks, label .. " blocks")
	eq(#plan.frontage, #without.frontage, label .. " frontage")
	for i, b in ipairs(plan.blocks) do
		eq(same_rect(b.rect, without.blocks[i].rect), true, label .. " block rect " .. i)
	end
	eq(#plan.reservations.services, #without.reservations.services, label .. " services")
	for i, s in ipairs(plan.reservations.services) do
		eq(same_rect(s.rect, without.reservations.services[i].rect), true, label .. " service " .. i)
	end
	eq(same_rect(plan.reservations.jail.rect, without.reservations.jail.rect), true, label .. " jail")
	eq(#plan.shortages, #without.shortages, label .. " shortages")

	local c = plan.content
	eq(#c.buildings > 0, true, label .. " has buildings")
	eq(#c.rejected, 0, label .. " no rejected picks")
	eq(content.validate(plan, c, base.content), true, label .. " content validates")
	for _, b in ipairs(c.buildings) do
		if plan.frontage[b.frontage].square then square_placed = true end
	end
	local again = assert(planner.plan({x = 10, z = -30}, seed, {landmarks = base}))
	eq(#again.content.buildings, #c.buildings, label .. " repeat count")
	for i, b in ipairs(c.buildings) do
		eq(same_rect(b.rect, again.content.buildings[i].rect), true, label .. " repeat " .. i)
		eq(b.building_id, again.content.buildings[i].building_id, label .. " repeat id " .. i)
	end
	local civic_rects = {}
	for _, s in pairs(plan.sites) do civic_rects[#civic_rects + 1] = s.rect end
	civic_rects[#civic_rects + 1] = plan.reservations.jail.rect
	for _, s in ipairs(plan.reservations.services) do civic_rects[#civic_rects + 1] = s.rect end
	for i, b in ipairs(c.buildings) do
		for _, r in ipairs(civic_rects) do
			eq(overlaps(b.rect, r), false, label .. " clear of civic " .. i)
		end
	end
end
eq(square_placed, true, "fixed catalog seeds place square-facing content")

-- Rejection path: picks whose door approach is not on pavement are dropped
-- and the frontage they would have covered is reported as unused.
do
	local plan = square_fixture()
	plan.streets = {}
	plan.sites = {}
	local entries = {h = entry("house", 6, 5, 2)}
	local r = content.plan(plan, entries, {seed = 3})
	eq(#r.buildings, 0, "rejected: no buildings")
	eq(#r.rejected > 0, true, "rejected: recorded")
	eq(next(r.counts), nil, "rejected: no counts")
	eq(#r.empty_runs, 4, "rejected: empty runs")
	local total = 0
	for _, u in ipairs(r.unused) do total = total + u.length end
	eq(total, 80, "rejected: whole frontage unused")
end

-- opts.landmarks.content is validated.
do
	local function with(c)
		return function()
			planner.plan({x = 0, z = 0}, 2, {landmarks = {cathedral = base.cathedral,
				castle = base.castle, content = c}})
		end
	end
	fails(with(5), "content must be a table", "content non-table")
	fails(with({h = {role = "tavern", size = {x = 5, y = 5, z = 5}, entrance = {x = 0, z = 0}}}),
		"role must be house", "content bad role")
	fails(with({h = {role = "house", size = {x = 5, y = 5, z = 5}, entrance = {x = 9, z = 0}}}),
		"entrance lies outside", "content bad entrance")
	fails(with({h = 3}), "not a table", "content bad entry")
end

-- Profiles without content (and legacy plans) carry no content field.
do
	local plan = assert(planner.plan({x = 0, z = 0}, 2, {landmarks = civic}))
	eq(plan.content, nil, "no content field without profile entry")
	local legacy = assert(planner.plan({x = 0, z = 0}, 3))
	eq(legacy.content == nil and legacy.reservations == nil, true, "legacy untouched")
end

-- A profile with no ordinary entries reports empty frontage on a valid plan.
do
	local prof = {cathedral = base.cathedral, castle = base.castle, content = {}}
	local plan = assert(planner.plan({x = 0, z = 0}, 2, {landmarks = prof}))
	eq(#plan.content.buildings, 0, "empty content: none")
	eq(type(plan.content.reason), "string", "empty content: reason")
	eq(#plan.content.empty_runs > 0, true, "empty content: empty runs")
	eq(planner.validate(plan), true, "empty content validates")
end
