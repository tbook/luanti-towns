-- Focused tests for ticket #28: catalog roles and entrance height.
-- Loaded by tests/run.lua, which passes its helpers:
--   loadfile("tests/catalog_tests.lua")(eq, fails, geometry, catalog, placement)
-- Also runnable alone from the mod root: lua5.1 tests/catalog_tests.lua
local eq, fails, geometry, catalog, placement = ...
local standalone = eq == nil
local failures, count = 0, 0
if standalone then
	geometry = dofile("src/geometry.lua")
	catalog = dofile("src/catalog.lua")
	placement = dofile("src/placement.lua")(geometry)
	eq = function(actual, expected, label)
		count = count + 1
		if actual ~= expected then
			failures = failures + 1
			print(("FAIL %s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)))
		end
	end
end

local function xyz(t, x, y, z, label)
	eq(t.x, x, label .. ".x")
	eq(t.y, y, label .. ".y")
	eq(t.z, z, label .. ".z")
end

-- Roles are optional for generated templates; assert only where present.
eq(catalog.get("demo_house").role, "house", "demo_house role")
eq(catalog.get("castle").role, "castle", "castle role")
for _, id in ipairs(catalog.ids()) do
	local role = catalog.get(id).role
	if role ~= nil then
		eq(catalog.VALID_ROLES[role], true, id .. " role is valid: " .. tostring(role))
	end
end
for _, role in ipairs({"house", "shop", "workshop", "tavern", "well", "cathedral",
		"castle", "city_hall", "chapel", "jail"}) do
	eq(catalog.VALID_ROLES[role], true, role .. " is a valid role")
end
eq(catalog.VALID_ROLES.landmark, nil, "landmark is no longer a role")
eq(catalog.VALID_ROLES.invalid_role, nil, "invalid_role is not a role")

-- Role filtering over the real catalog.
eq(table.concat(catalog.ids_for_role("house"), ","), "demo_house", "house filter")
eq(table.concat(catalog.ids_for_role("castle"), ","), "castle", "castle filter")
eq(#catalog.ids_for_role("tavern"), 0, "tavern filter empty")
eq(#catalog.ids_for_role("not_a_role"), 0, "unknown role filter empty")
for role in pairs(catalog.VALID_ROLES) do
	local ids = catalog.ids_for_role(role)
	for i, id in ipairs(ids) do
		eq(catalog.get(id).role, role, id .. " matches filter " .. role)
		if i > 1 then eq(ids[i] > ids[i - 1], true, role .. " ids sorted") end
	end
end
local all = catalog.ids()
for i = 2, #all do eq(all[i] > all[i - 1], true, "ids sorted") end

-- Role filtering with synthetic entries (restored afterwards).
do
	local function add(id, role)
		catalog.entries[id] = {id = id, path = "schematics/" .. id .. ".mts", role = role,
			size = {x = 3, y = 3, z = 3}, entrance = {x = 1, z = 0}}
	end
	add("zz_shop", "shop"); add("aa_shop", "shop"); add("mm_tavern", "tavern")
	add("no_role", nil)
	catalog.verify(function() return {size = {x = 3, y = 3, z = 3}} end, "/m")
	eq(table.concat(catalog.ids_for_role("shop"), ","), "aa_shop,zz_shop", "shop filter sorted")
	eq(table.concat(catalog.ids_for_role("tavern"), ","), "mm_tavern", "tavern filter")
	eq(catalog.snapshot().zz_shop.role, "shop", "snapshot carries role")
	eq(catalog.snapshot().no_role.role, nil, "snapshot of role-less entry")
	eq(catalog.snapshot().no_role.entrance.y, 1, "snapshot entrance.y default")
	local snap = catalog.snapshot()
	snap.aa_shop.size.x = 99
	eq(catalog.get("aa_shop").size.x, 3, "snapshot is a deep copy")
	for _, id in ipairs({"zz_shop", "aa_shop", "mm_tavern", "no_role"}) do
		catalog.entries[id] = nil
	end
	catalog.verify(function(path)
		return {size = catalog.get(path:match("([^/]+)%.mts$")).size}
	end, "/m")
end

-- Every real catalog entry (in-source and generated) passes validation.
do
	local inv = catalog.verify(function(path)
		return {size = catalog.get(path:match("([^/]+)%.mts$")).size}
	end, "/m")
	local n = 0
	for id, msg in pairs(inv) do n = n + 1; print("invalid: " .. id .. ": " .. msg) end
	eq(n, 0, "no real catalog entry is invalid")
	eq(#catalog.ids() >= 3, true, "real catalog has house, castle, cathedral")
end

-- Entrance height at all four rotations for the real entries.
local ground = {x = 100, y = 20, z = 50}
for _, rot in ipairs(geometry.ROTATIONS) do
	eq(placement.plan(catalog.get("demo_house"), ground, rot).building.entrance.y, 21,
		"demo_house entrance Y at " .. rot)
	eq(placement.plan(catalog.get("castle"), {x = 0, y = 8, z = 0}, rot).building.entrance.y, 11,
		"castle entrance Y (ground offset) at " .. rot)
end

-- Non-square footprint 6x4x5, entrance (2, 1, 0) at pos (0, 10, 0): X/Z/Y at
-- all four rotations (rotated-local mapping per src/geometry.lua).
local ns = {size = {x = 6, y = 4, z = 5}, entrance = {x = 2, y = 1, z = 0}}
local origin = {x = 0, y = 10, z = 0}
local expect = {
	[0]   = {size = {6, 5}, e = {2, 0}, front = {0, -1}},
	[90]  = {size = {5, 6}, e = {0, 3}, front = {-1, 0}},
	[180] = {size = {6, 5}, e = {3, 4}, front = {0, 1}},
	[270] = {size = {5, 6}, e = {4, 2}, front = {1, 0}},
}
for _, rot in ipairs(geometry.ROTATIONS) do
	local p, x = geometry.place(ns, origin, rot), expect[rot]
	local l = "non-square " .. rot
	eq(p.size.x, x.size[1], l .. " size x")
	eq(p.size.z, x.size[2], l .. " size z")
	eq(p.size.y, 4, l .. " size y")
	xyz(p.entrance, x.e[1], 11, x.e[2], l .. " entrance")
	xyz(p.outside, x.e[1] + x.front[1], 11, x.e[2] + x.front[2], l .. " outside")
	eq(p.entrance.x >= p.min.x and p.entrance.x <= p.max.x
		and p.entrance.z >= p.min.z and p.entrance.z <= p.max.z, true, l .. " entrance inside box")
end

-- Entrance without y defaults to 1 in geometry.place.
eq(geometry.place({size = {x = 3, y = 3, z = 3}, entrance = {x = 1, z = 0}}, origin, 0).entrance.y,
	11, "geometry default entrance y")

-- Boxes may touch but not overlap (inclusive bounds); tested on plain geometry.
local function overlaps(a, b)
	return a.min.x <= b.max.x and b.min.x <= a.max.x
		and a.min.y <= b.max.y and b.min.y <= a.max.y
		and a.min.z <= b.max.z and b.min.z <= a.max.z
end
local sq = {size = {x = 5, y = 3, z = 5}, entrance = {x = 2, z = 0}}
local base = geometry.place(sq, {x = 0, y = 0, z = 0}, 0)
local touch_x = geometry.place(sq, {x = 5, y = 0, z = 0}, 0)
local touch_z = geometry.place(sq, {x = 0, y = 0, z = 5}, 0)
local over_x = geometry.place(sq, {x = 4, y = 0, z = 0}, 0)
local over_z = geometry.place(sq, {x = 0, y = 0, z = 4}, 0)
eq(base.max.x + 1, touch_x.min.x, "touch in X adjacent")
eq(overlaps(base, touch_x), false, "touching in X does not overlap")
eq(base.max.z + 1, touch_z.min.z, "touch in Z adjacent")
eq(overlaps(base, touch_z), false, "touching in Z does not overlap")
eq(overlaps(base, over_x), true, "one-node overlap in X detected")
eq(overlaps(base, over_z), true, "one-node overlap in Z detected")

if standalone then
	print(("%d checks, %d failures"):format(count, failures))
	os.exit(failures == 0 and 0 or 1)
end
