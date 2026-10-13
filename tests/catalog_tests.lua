-- Focused tests for ticket #28: catalog roles and entrance height
-- Run from mod root: lua5.1 tests/catalog_tests.lua

local geometry = dofile("src/geometry.lua")
local catalog = dofile("src/catalog.lua")
local placement = dofile("src/placement.lua")(geometry)

local failures, count = 0, 0
local function eq(actual, expected, label)
	count = count + 1
	if actual ~= expected then
		failures = failures + 1
		print(("FAIL %s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)))
	end
end

print("Testing catalog roles and entrance height (ticket #28)...")

-- Every building has a valid role.
for _, id in ipairs(catalog.ids()) do
	local e = catalog.get(id)
	eq(e.role ~= nil, true, id .. " has a role")
	eq(catalog.VALID_ROLES[e.role] ~= nil, true, id .. " has a valid role: " .. tostring(e.role))
end

-- Role filtering.
local house_ids = catalog.ids_for_role("house")
eq(#house_ids > 0, true, "house filter has entries")
for _, id in ipairs(house_ids) do
	eq(catalog.get(id).role, "house", id .. " is in house filter")
end

local shop_ids = catalog.ids_for_role("shop")
eq(#shop_ids > 0, true, "shop filter has entries")

local workshop_ids = catalog.ids_for_role("workshop")
eq(#workshop_ids > 0, true, "workshop filter has entries")

-- Filter for role with no entries.
local well_ids = catalog.ids_for_role("well")
eq(#well_ids, 0, "well filter has no entries")

local tavern_ids = catalog.ids_for_role("tavern")
eq(#tavern_ids, 0, "tavern filter has no entries")

-- Role constants are correct.
eq(catalog.VALID_ROLES["house"], true, "house is a valid role")
eq(catalog.VALID_ROLES["workshop"], true, "workshop is a valid role")
eq(catalog.VALID_ROLES["invalid_role"], nil, "invalid_role is not a valid role")

-- Entrance height at all four rotations (non-square footprints).
local demo = catalog.get("demo_house")
local ground = {x = 100, y = 20, z = 50}
for _, rot in ipairs(geometry.ROTATIONS) do
	local p = placement.plan(demo, ground, rot)
	eq(p.building.entrance.y, 21, "demo_house entrance Y at rotation " .. rot)
end

-- Entrance height with ground offset (castle).
local castle = catalog.get("castle")
eq(castle.ground_offset, 5, "castle has ground offset 5")
for _, rot in ipairs(geometry.ROTATIONS) do
	local p = placement.plan(castle, {x = 0, y = 8, z = 0}, rot)
	eq(p.building.entrance.y, 11, "castle entrance Y at rotation " .. rot .. " with ground offset")
end

-- Entrance height validation in verify().
local d = catalog.get("demo_house")
local function reader(result) return function() return result end end
local function read_known(path)
	local id = path:match("([^/]+)%.mts$")
	return {size = catalog.get(id).size}
end
eq(next(catalog.verify(read_known, "/m")), nil, "verify ok with roles")

-- Role filtering returns sorted IDs within each role.
for role, _ in pairs(catalog.VALID_ROLES) do
	local ids = catalog.ids_for_role(role)
	for i = 2, #ids do
		eq(ids[i] >= ids[i-1], true, "role " .. role .. " IDs sorted")
	end
end

print(("%d checks, %d failures"):format(count, failures))
os.exit(failures == 0 and 0 or 1)
