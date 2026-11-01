-- Medieval town square fountain (#344): a workshop-imported outdoor object
-- standing at the centre of the market square of every medieval plan.
local eq, fails, planner, catalog = ...
local medieval = dofile("src/medieval_planner.lua")
local preflight = dofile("src/preflight.lua")
local read_mts = dofile("tests/mts_reader.lua")

local entry = catalog.get("town_square_fountain")
eq(entry ~= nil, true, "fountain is catalogued")
eq(entry.size.x == 5 and entry.size.y == 5 and entry.size.z == 5, true, "fountain is 5x5x5")
eq(entry.role, nil, "fountain has no role, so no random pool uses it")
eq(read_mts(entry.path).size.y, 5, "fountain schematic file matches the catalog")

local profile = assert(planner.landmark_profile(catalog.snapshot()))
eq(profile.content.town_square_fountain, nil, "fountain is not ordinary content")
for _, list in pairs(profile.service_variants or {}) do
	for _, v in ipairs(list) do eq(v.id ~= "town_square_fountain", true, "fountain is not a service variant") end
end

local function overlap(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end
local function fountains(plan)
	local list = {}
	for _, o in ipairs(plan.objects or {}) do
		if o.id == "town_square_fountain" then list[#list + 1] = o end
	end
	return list
end

local function check(plan, label)
	local list = fountains(plan)
	eq(#list, 1, label .. ": exactly one fountain")
	local f = list[1]
	if not f then return end
	local m = plan.sites.market.rect
	eq(f.rect.x2 - f.rect.x1 + 1 == 5 and f.rect.z2 - f.rect.z1 + 1 == 5, true, label .. ": fountain footprint")
	eq(f.rect.x1 >= m.x1 and f.rect.x2 <= m.x2 and f.rect.z1 >= m.z1 and f.rect.z2 <= m.z2, true,
		label .. ": fountain inside the market")
	-- centred (within one node on each axis for an even-sized square)
	eq(math.abs((f.rect.x1 + f.rect.x2) - (m.x1 + m.x2)) <= 1, true, label .. ": centred in x")
	eq(math.abs((f.rect.z1 + f.rect.z2) - (m.z1 + m.z2)) <= 1, true, label .. ": centred in z")
	local function avoid(r, what) eq(overlap(f.rect, r), false, label .. ": fountain avoids " .. what) end
	if plan.sites.city_hall then avoid(plan.sites.city_hall.rect, "the hall") end
	avoid(plan.sites.cathedral.rect, "the cathedral")
	avoid(plan.sites.castle.rect, "the castle")
	for i, s in ipairs(plan.streets) do avoid(s.rect, "street " .. i) end
	for i, b in ipairs(plan.blocks) do avoid(b.rect, "block " .. i) end
	for i, fr in ipairs(plan.frontage) do avoid(fr.rect, "frontage " .. i) end
	for _, s in ipairs((plan.reservations or {}).services or {}) do avoid(s.rect, "a service") end
	if plan.reservations and plan.reservations.jail then avoid(plan.reservations.jail.rect, "the jail") end
	for _, b in ipairs((plan.content or {}).buildings or {}) do avoid(b.rect, "a building") end
	for _, o in ipairs(plan.objects) do
		if o ~= f then eq(overlap(f.rect, o.clearing or o.rect), false, label .. ": fountain avoids other objects") end
	end
end

-- Every arrangement (no population needed for the geometry rules).
local function fixed_rng(seed)
	local n = seed
	return {int = function(a, b) n = (n * 1103515245 + 12345) % 2147483648; return a + n % (b - a + 1) end}
end
for quadrant = 0, 3 do
	for _, east in ipairs({false, true}) do
		for turn = 0, 270, 90 do
			local label = ("q%d east=%s turn=%d"):format(quadrant, tostring(east), turn)
			local plan = assert(medieval.plan({x = 100, z = -40}, 2, profile, fixed_rng(2),
				{quadrant = quadrant, castle_east = east, turn = turn}))
			check(plan, label)
		end
	end
end

-- Fully populated plans, and the fountain is composed for building.
for _, seed in ipairs({1, 7, 42, 101, 256}) do
	local plan = assert(planner.plan({x = 0, z = 0}, seed, {landmarks = profile}))
	check(plan, "seed " .. seed)
	local comp = assert(preflight.compose(plan, catalog.entries, 40))
	local found
	for _, s in ipairs(comp.structures) do
		if s.id == "town_square_fountain" then
			found = s
			eq(s.kind, "object", "seed " .. seed .. ": fountain composed as an object")
			eq(s.min.y, 39, "seed " .. seed .. ": fountain foundation row is below ground")
			eq(s.max.y, 43, "seed " .. seed .. ": fountain top")
		end
	end
	eq(found ~= nil, true, "seed " .. seed .. ": fountain is in the built structures")
end
