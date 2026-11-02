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

-- The authored fountain is centered on the forum and keeps the enclosed
-- bell at the same height as the surrounding walking space.
local fountain_asset = dofile("schematics/objects/catalog.lua").roman_fountain
local fountain = dofile("tests/mts_reader.lua")(fountain_asset.path)
eq(fountain.at(2, 1, 2), "mcl_bells:bell", "fountain contains its hidden bell")
eq(fountain.at(2, 0, 2), "mcl_ocean:sea_lantern", "bell has its authored support")
eq(fountain.at(2, 2, 2), "mcl_core:diorite_smooth", "bell is enclosed above")
eq(fountain.at(2, 3, 2), "mcl_core:water_source", "fountain has a water source")
for _, center in ipairs({{x = 0, z = 0}, {x = -130, z = 77}}) do
	local p = plan_at(center.x, center.z, 1)
	local found
	for _, o in ipairs(p.objects) do if o.id == "roman_fountain" then
		eq(found, nil, "only one Roman fountain")
		found = o
	end end
	eq(found ~= nil, true, "Roman town contains fountain")
	local r = p.sites.forum.rect
	eq(found.rect.x1 + 2, math.floor((r.x1 + r.x2) / 2), "fountain center x")
	eq(found.rect.z1 + 2, math.floor((r.z1 + r.z2) / 2), "fountain center z")
	local comp = assert(dofile("src/preflight.lua").compose(p, catalog.snapshot(), 42))
	local placed
	for _, structure in ipairs(comp.structures) do
		if structure.id == "roman_fountain" then placed = structure end
	end
	eq(placed and placed.kind, "object", "fountain is placed without a building entrance")
	eq(placed and placed.min.y, 42, "fountain ground is level with forum pavement")
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
	eq(#plan.site_order, 21, tag .. " retains exactly the fixed monuments")

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

-- Issue #354: the neighbourhoods opened by #351..#353 (the outer northern and
-- south-eastern corners, the gaps beside the basilica and the western temple,
-- and the outer west, south-west and east blocks) each receive ordinary
-- buildings. Counts are per district, so a total cannot hide an empty one.
local NEW_DISTRICTS = {"outer_north_east", "outer_north_west", "ring_south_inner_east",
	"ring_north_inner_west", "ring_west_inner_north", "ring_east_inner_north",
	"ring_south_outer_east", "ring_south_outer_inner_east", "west_outer_west",
	"south_west_outer", "east_amph_north", "east_outer_east"}
local function per_district(plan)
	local counts = {}
	for _, b in ipairs(plan.content.buildings) do
		local name = plan.blocks[b.block].name
		counts[name] = (counts[name] or 0) + 1
	end
	return counts
end
local function on_pavement(plan, a)
	local node = {x1 = a.x, z1 = a.z, x2 = a.x, z2 = a.z}
	for _, st in ipairs(plan.streets) do
		if overlap(node, st.rect) then return true end
	end
	for _, name in ipairs(plan.site_order) do
		local s = plan.sites[name]
		if s.kind == "square" and overlap(node, s.rect) then return true end
	end
	return false
end
local function check_population(plan, tag)
	local counts = per_district(plan)
	local total = #plan.content.buildings
	eq(total >= 50, true, tag .. " at least 50 ordinary buildings (" .. total .. ")")
	for _, name in ipairs(NEW_DISTRICTS) do
		eq((counts[name] or 0) >= 1, true, tag .. " district " .. name .. " has buildings")
	end
	for _, b in ipairs(plan.blocks) do
		eq((counts[b.name] or 0) >= 1, true, tag .. " block " .. b.name .. " is used")
	end
	-- Every new district's door approaches are connected pavement.
	for _, b in ipairs(plan.content.buildings) do
		local name = plan.blocks[b.block].name
		for _, new in ipairs(NEW_DISTRICTS) do
			if name == new then
				eq(b.approach ~= nil and on_pavement(plan, b.approach), true,
					tag .. " " .. name .. " approach is connected pavement")
			end
		end
	end
	-- Services and jail stay valid: the fixed reservations, no shortage.
	eq(plan.reservations.jail.building_id, "jail", tag .. " jail reserved")
	eq(#plan.reservations.services, 6, tag .. " three taverns and three wells reserved")
	eq(#plan.shortages, 0, tag .. " no service or jail shortage")
	eq(planner.validate(plan), true, tag .. " validates")
	eq(content.validate(plan, plan.content, snapshot), true, tag .. " content validates")
	return counts, total
end
local total_buildings = 0
for _, seed in ipairs(SEEDS) do
	local tag = "seed " .. seed .. " (#354)"
	local plan = by_seed[seed]
	local _, total = check_population(plan, tag)
	total_buildings = total_buildings + total
	-- A translated centre reproduces the same per-district counts.
	local moved = plan_at(777, -333, seed)
	local moved_counts, moved_total = check_population(moved, tag .. " at (777,-333)")
	eq(moved_total, total, tag .. " translated total")
	for _, name in ipairs(NEW_DISTRICTS) do
		eq(moved_counts[name] or 0, (per_district(plan))[name] or 0,
			tag .. " translated district " .. name)
	end
end
eq(total_buildings >= 210, true, "at least 210 ordinary buildings over seeds 1, 2, 3 and 7 (" .. total_buildings .. ")")
