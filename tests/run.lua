-- Plain Lua 5.1 tests for the pure modules. Run from the mod root:
--   lua5.1 tests/run.lua
local geometry = dofile("src/geometry.lua")
local catalog = dofile("src/catalog.lua")

local failures, count = 0, 0
local function eq(actual, expected, label)
	count = count + 1
	if actual ~= expected then
		failures = failures + 1
		print(("FAIL %s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)))
	end
end
local function xz(t, x, z, label)
	eq(t.x, x, label .. ".x")
	eq(t.z, z, label .. ".z")
end
local function xyz(t, x, y, z, label)
	eq(t.x, x, label .. ".x")
	eq(t.y, y, label .. ".y")
	eq(t.z, z, label .. ".z")
end
local function fails(fn, pattern, label)
	count = count + 1
	local ok, err = pcall(fn)
	if ok or not tostring(err):find(pattern, 1, true) then
		failures = failures + 1
		print(("FAIL %s: expected error containing %q, got %s"):format(label, pattern, tostring(err)))
	end
end

-- Non-square fixture: 5 (x) by 4 (y) by 3 (z), door at x=1 on the north edge.
local box = {size = {x = 5, y = 4, z = 3}, entrance = {x = 1, z = 0}}
local pos = {x = 100, y = 10, z = -20}

local r = geometry.place(box, pos, 0)
xyz(r.size, 5, 4, 3, "0 size")
xyz(r.min, 100, 10, -20, "0 min")
xyz(r.max, 104, 13, -18, "0 max")
xyz(r.entrance, 101, 10, -20, "0 entrance")
xz(r.front, 0, -1, "0 front")
xyz(r.outside, 101, 10, -21, "0 outside")

r = geometry.place(box, pos, 90)
xyz(r.size, 3, 4, 5, "90 size")
xyz(r.max, 102, 13, -16, "90 max")
xyz(r.entrance, 100, 10, -17, "90 entrance")
xz(r.front, -1, 0, "90 front")
xyz(r.outside, 99, 10, -17, "90 outside")

r = geometry.place(box, pos, 180)
xyz(r.size, 5, 4, 3, "180 size")
xyz(r.max, 104, 13, -18, "180 max")
xyz(r.entrance, 103, 10, -18, "180 entrance")
xz(r.front, 0, 1, "180 front")
xyz(r.outside, 103, 10, -17, "180 outside")

r = geometry.place(box, pos, 270)
xyz(r.size, 3, 4, 5, "270 size")
xyz(r.max, 102, 13, -16, "270 max")
xyz(r.entrance, 102, 10, -19, "270 entrance")
xz(r.front, 1, 0, "270 front")
xyz(r.outside, 103, 10, -19, "270 outside")

-- Numeric strings are accepted (core.place_schematic uses strings).
eq(geometry.place(box, pos, "90").size.x, 3, "string rotation")

-- Entrance is inside the bounds; the outside node is outside them.
for _, rot in ipairs(geometry.ROTATIONS) do
	local p = geometry.place(box, pos, rot)
	local e, o = p.entrance, p.outside
	eq(e.x >= p.min.x and e.x <= p.max.x and e.z >= p.min.z and e.z <= p.max.z,
		true, rot .. " entrance in bounds")
	eq(o.x < p.min.x or o.x > p.max.x or o.z < p.min.z or o.z > p.max.z,
		true, rot .. " outside out of bounds")
end

-- Recessed entrance: 5x4x3 box, door at x=2, z=1 (one node in from the -Z edge).
local rec = {size = {x = 5, y = 4, z = 3}, entrance = {x = 2, z = 1}}
r = geometry.place(rec, pos, 0)
xyz(r.entrance, 102, 10, -19, "rec 0 entrance")
xyz(r.outside, 102, 10, -20, "rec 0 outside")
r = geometry.place(rec, pos, 90)
xyz(r.entrance, 101, 10, -18, "rec 90 entrance")
xz(r.front, -1, 0, "rec 90 front")
xyz(r.outside, 100, 10, -18, "rec 90 outside")
r = geometry.place(rec, pos, 180)
xyz(r.entrance, 102, 10, -19, "rec 180 entrance")
xyz(r.outside, 102, 10, -18, "rec 180 outside")
r = geometry.place(rec, pos, 270)
xyz(r.entrance, 101, 10, -18, "rec 270 entrance")
xz(r.front, 1, 0, "rec 270 front")
xyz(r.outside, 102, 10, -18, "rec 270 outside")

-- Strict rotation strings.
for _, bad_rot in ipairs({"0x5a", "9e1", " 90", "90 ", "+90", "090", "", "1.8e2", 90.5, 360, -90}) do
	fails(function() geometry.place(box, pos, bad_rot) end, "invalid rotation",
		"strict rotation " .. tostring(bad_rot))
end
eq(geometry.place(box, pos, "270").rotation, 270, "string 270")
eq(geometry.place(box, pos, "0").rotation, 0, "string 0")

-- Invalid rotation.
fails(function() geometry.place(box, pos, 45) end, "invalid rotation 45", "bad rotation")
fails(function() geometry.place(box, pos, nil) end, "invalid rotation", "nil rotation")
fails(function() geometry.place(box, pos, "random") end, "invalid rotation", "random rotation")

-- Catalog.
fails(function() catalog.get("nope") end, "unknown building id 'nope'", "unknown id")
eq(catalog.get("demo_house").id, "demo_house", "demo_house registered")

-- verify(): ok, missing, mismatch.
local d = catalog.get("demo_house")
local function reader(result) return function() return result end end
eq(next(catalog.verify(reader({size = d.size}), "/m")), nil, "verify ok")
local bad = catalog.verify(reader(nil), "/mod")
eq(bad.demo_house ~= nil
	and bad.demo_house:find("demo_house", 1, true) ~= nil
	and bad.demo_house:find("/mod/schematics/demo_house.mts", 1, true) ~= nil,
	true, "missing message has id and path")
bad = catalog.verify(reader({size = {x = 1, y = 1, z = 1}}), "/mod")
eq(bad.demo_house:find("size mismatch", 1, true) ~= nil, true, "mismatch message")

-- verify(): read raising, entrance outside the schematic.
bad = catalog.verify(function() error("boom") end, "/mod")
eq(bad.demo_house:find("read failed", 1, true) ~= nil, true, "read error reported")
local saved = d.entrance
d.entrance = {x = d.size.x, z = 0}
bad = catalog.verify(reader({size = d.size}), "/mod")
eq(bad.demo_house:find("entrance offset outside", 1, true) ~= nil, true, "entrance outside")
d.entrance = {x = 0, z = d.size.z}
bad = catalog.verify(reader({size = d.size}), "/mod")
eq(bad.demo_house:find("entrance offset outside", 1, true) ~= nil, true, "entrance z outside")
d.entrance = saved

print(("%d checks, %d failures"):format(count, failures))
os.exit(failures == 0 and 0 or 1)
