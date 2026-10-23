-- Roman population through the shared medieval pipeline (issue #150).
-- Loaded by tests/run.lua:
--   loadfile("tests/roman_population_tests.lua")(eq, fails, planner, catalog, geometry)
local eq, fails, planner, catalog, geometry = ...

local packer = dofile("src/frontage_packer.lua")(geometry)
local jailmod = dofile("src/jail_reservation.lua")(packer)
local content = dofile("src/content_planner.lua")(geometry, packer, jailmod.occupied_rects)

-- Documented seed set: 1 and 2 are compared pairwise, 3 and 7 add coverage.
local SEEDS = {1, 2, 3, 7}
local EXCLUDED = {chapel = true, castle = true, cathedral = true, city_hall = true,
	landmark = true}

local snapshot = catalog.snapshot()
local function plan_at(x, z, seed)
	local plan, why = planner.plan({x = x, z = z}, seed, {town_type = "roman"})
	assert(plan, why)
	return plan
end
local function overlap(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end
local function signature(plan)
	local out = {}
	for _, b in ipairs(plan.content.buildings) do
		out[#out + 1] = ("%s@%d,%d,%d,%d/%d"):format(b.building_id, b.rect.x1, b.rect.z1,
			b.rect.x2, b.rect.z2, b.rotation)
	end
	return table.concat(out, ";")
end
local function monuments(plan)
	local out = {}
	for _, name in ipairs(plan.site_order) do
		local s = plan.sites[name]
		out[#out + 1] = ("%s:%s:%d,%d,%d,%d"):format(name, tostring(s.id), s.rect.x1,
			s.rect.z1, s.rect.x2, s.rect.z2)
	end
	return table.concat(out, ";")
end

-- The profile keeps ordinary content, tavern, well and jail only.
local profile = planner.roman_profile(snapshot)
eq(profile.cathedral, nil, "Roman profile has no cathedral")
eq(profile.castle, nil, "Roman profile has no castle")
eq(profile.city_hall, nil, "Roman profile has no city hall")
eq(profile.services.chapel, nil, "Roman profile has no chapel")
eq(profile.services.tavern ~= nil and profile.services.well ~= nil, true, "tavern and well stay")
eq(profile.service_variants.chapel, nil, "Roman profile has no chapel variants")
eq(profile.service_variants.tavern ~= nil and #profile.service_variants.tavern >= 1, true,
	"Roman tavern variants kept")
eq(profile.jail ~= nil, true, "jail stays")
for id, e in pairs(profile.content) do
	eq(e.role == "house" or e.role == "shop" or e.role == "workshop", true,
		id .. " is ordinary content")
end

local base = plan_at(0, 0, SEEDS[1])
local by_seed = {}
for _, seed in ipairs(SEEDS) do
	local plan = plan_at(0, 0, seed)
	by_seed[seed] = plan
	local tag = "seed " .. seed
	eq(planner.validate(plan), true, tag .. " validates")
	eq(monuments(plan), monuments(base), tag .. " keeps the fixed civic geometry")
	eq(#plan.site_order, 14, tag .. " retains exactly the fixed monuments")

	-- Only allowed roles anywhere in the automatic content.
	local roles = {}
	for _, b in ipairs(plan.content.buildings) do roles[b.role] = true end
	eq(next(roles) ~= nil, true, tag .. " has ordinary buildings")
	for role in pairs(roles) do
		eq(role == "house" or role == "shop" or role == "workshop", true, tag .. " role " .. role)
	end
	local reserved = {plan.reservations.jail}
	for _, s in ipairs(plan.reservations.services) do reserved[#reserved + 1] = s end
	eq(plan.reservations.jail.building_id, "jail", tag .. " keeps the jail")
	for _, r in ipairs(reserved) do
		eq(EXCLUDED[r.role], nil, tag .. " reserved role " .. r.role)
		eq(EXCLUDED[snapshot[r.building_id].role], nil, tag .. " reserved entry " .. r.building_id)
		local id_role = snapshot[r.building_id].role
		eq(id_role == "tavern" or id_role == "well" or id_role == "jail", true,
			tag .. " reserved " .. r.building_id .. " is a service")
	end

	-- Buildings stand on both street and forum frontage, inside their blocks.
	local street, forum = 0, 0
	for _, b in ipairs(plan.content.buildings) do
		eq(EXCLUDED[snapshot[b.building_id].role], nil, tag .. " " .. b.building_id .. " allowed")
		local run = plan.frontage[b.frontage]
		if run.square then forum = forum + 1 else street = street + 1 end
		local r, blk = b.rect, plan.blocks[b.block].rect
		eq(r.x1 >= blk.x1 and r.x2 <= blk.x2 and r.z1 >= blk.z1 and r.z2 <= blk.z2, true,
			tag .. " building inside its block")
		for _, name in ipairs(plan.site_order) do
			eq(overlap(r, plan.sites[name].rect), false, tag .. " clear of " .. name)
		end
		for _, r2 in ipairs(reserved) do
			eq(overlap(r, r2.rect), false, tag .. " clear of reserved " .. r2.building_id)
		end
	end
	eq(street > 0, true, tag .. " populates street frontage")
	eq(forum > 0, true, tag .. " populates forum frontage")

	-- Clearance and door approaches.
	eq(content.validate(plan, plan.content, snapshot), true, tag .. " content validates")

	eq(signature(plan_at(0, 0, seed)), signature(plan), tag .. " reproduces placements")
	-- A shifted centre translates the same packing.
	local moved = plan_at(40, -25, seed)
	eq(#moved.content.buildings, #plan.content.buildings, tag .. " translated count")
	for i, b in ipairs(plan.content.buildings) do
		local m = moved.content.buildings[i]
		eq(m.building_id == b.building_id and m.rect.x1 - 40 == b.rect.x1
			and m.rect.z1 + 25 == b.rect.z1, true, tag .. " translated building " .. i)
	end
	for _, sh in ipairs(plan.shortages) do
		eq(sh.role == "tavern" or sh.role == "well" or sh.role == "jail", true,
			tag .. " shortage role " .. sh.role)
	end
end

-- Ordinary placements vary with the seed while the civic geometry does not.
eq(signature(by_seed[1]) ~= signature(by_seed[2]), true, "seeds 1 and 2 differ in ordinary placement")
eq(monuments(by_seed[1]), monuments(by_seed[2]), "seeds 1 and 2 share civic geometry")
