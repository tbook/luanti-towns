-- Plain Lua 5.1 tests for the pure modules. Run from the mod root:
--   lua5.1 tests/run.lua
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
xyz(r.entrance, 101, 11, -20, "0 entrance")
xz(r.front, 0, -1, "0 front")
xyz(r.outside, 101, 11, -21, "0 outside")

r = geometry.place(box, pos, 90)
xyz(r.size, 3, 4, 5, "90 size")
xyz(r.max, 102, 13, -16, "90 max")
xyz(r.entrance, 100, 11, -17, "90 entrance")
xz(r.front, -1, 0, "90 front")
xyz(r.outside, 99, 11, -17, "90 outside")

r = geometry.place(box, pos, 180)
xyz(r.size, 5, 4, 3, "180 size")
xyz(r.max, 104, 13, -18, "180 max")
xyz(r.entrance, 103, 11, -18, "180 entrance")
xz(r.front, 0, 1, "180 front")
xyz(r.outside, 103, 11, -17, "180 outside")

r = geometry.place(box, pos, 270)
xyz(r.size, 3, 4, 5, "270 size")
xyz(r.max, 102, 13, -16, "270 max")
xyz(r.entrance, 102, 11, -19, "270 entrance")
xz(r.front, 1, 0, "270 front")
xyz(r.outside, 103, 11, -19, "270 outside")

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
xyz(r.entrance, 102, 11, -19, "rec 0 entrance")
xyz(r.outside, 102, 11, -20, "rec 0 outside")
r = geometry.place(rec, pos, 90)
xyz(r.entrance, 101, 11, -18, "rec 90 entrance")
xz(r.front, -1, 0, "rec 90 front")
xyz(r.outside, 100, 11, -18, "rec 90 outside")
r = geometry.place(rec, pos, 180)
xyz(r.entrance, 102, 11, -19, "rec 180 entrance")
xyz(r.outside, 102, 11, -18, "rec 180 outside")
r = geometry.place(rec, pos, 270)
xyz(r.entrance, 101, 11, -18, "rec 270 entrance")
xz(r.front, 1, 0, "rec 270 front")
xyz(r.outside, 102, 11, -18, "rec 270 outside")

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
eq(catalog.get("castle").id, "castle", "castle registered")

-- verify(): ok, missing, mismatch.
local d = catalog.get("demo_house")
local function reader(result) return function() return result end end
local function read_known(path)
	local id = path:match("([^/]+)%.mts$")
	return {size = catalog.get(id).size}
end
eq(next(catalog.verify(read_known, "/m")), nil, "verify ok")
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
local function has_id_path(msg, id, path)
	return msg ~= nil and msg:find(id, 1, true) ~= nil and msg:find(path, 1, true) ~= nil
end
local saved = d.entrance
d.entrance = {x = d.size.x, z = 0}
bad = catalog.verify(read_known, "/mod")
eq(bad.demo_house:find("entrance offset outside", 1, true) ~= nil, true, "entrance outside")
eq(has_id_path(bad.demo_house, "demo_house", "/mod/schematics/demo_house.mts"), true, "entrance outside id/path")
d.entrance = {x = 0, z = d.size.z}
bad = catalog.verify(read_known, "/mod")
eq(bad.demo_house:find("entrance offset outside", 1, true) ~= nil, true, "entrance z outside")
eq(has_id_path(bad.demo_house, "demo_house", "/mod/schematics/demo_house.mts"), true, "entrance z outside id/path")
d.entrance = saved
local castle = catalog.get("castle")
local saved_height = castle.entrance.y
castle.entrance.y = castle.size.y
bad = catalog.verify(read_known, "/mod")
eq(bad.castle:find("entrance height outside", 1, true) ~= nil, true, "castle entrance y outside")
eq(has_id_path(bad.castle, "castle", "/mod/schematics/templates/castle.mts"), true, "castle entrance y id/path")
castle.entrance.y = saved_height
local saved_ground_offset = castle.ground_offset
castle.ground_offset = castle.size.y
bad = catalog.verify(read_known, "/mod")
eq(bad.castle:find("ground offset outside", 1, true) ~= nil, true, "castle ground offset outside")
eq(has_id_path(bad.castle, "castle", "/mod/schematics/templates/castle.mts"), true, "castle ground offset id/path")
castle.ground_offset = saved_ground_offset
eq(next(catalog.verify(read_known, "/m")), nil, "verify ok after restoring entries")

-- Synthetic invalid entries (ticket #28): rejected with building id and path.
do
	local function test_bad_entry(entry, expect, label)
		entry.id = "test_bad"
		entry.path = "schematics/test_bad.mts"
		catalog.entries.test_bad = entry
		local res = catalog.verify(function() return {size = {x = 5, y = 5, z = 5}} end, "/mod")
		catalog.entries.test_bad = nil
		local msg = res.test_bad
		eq(msg ~= nil and msg:find(expect, 1, true) ~= nil, true, label)
		eq(has_id_path(msg, "test_bad", "/mod/schematics/test_bad.mts"), true, label .. " id/path")
	end
	test_bad_entry({size = {x = 5, y = 5}, entrance = {x = 2, z = 0}}, "size", "size incomplete")
	test_bad_entry({size = {x = 0, y = 5, z = 5}, entrance = {x = 2, z = 0}}, "size", "size zero")
	test_bad_entry({size = {x = 5, y = 5, z = 5}, entrance = {z = 0}}, "entrance missing", "entrance missing x")
	test_bad_entry({size = {x = 5, y = 5, z = 5}, entrance = {x = 2}}, "entrance missing", "entrance missing z")
	test_bad_entry({size = {x = 5, y = 5, z = 5}, entrance = {x = 2, y = 5, z = 0}}, "entrance height outside", "entrance y at boundary")
	test_bad_entry({size = {x = 5, y = 5, z = 5}, entrance = {x = 2, y = 0, z = 0}, role = "invalid"}, "invalid role", "invalid role rejected")
end
catalog.verify(read_known, "/m")
-- Invalid entries are excluded from ids(), ids_for_role() and snapshot().
do
	local inv = catalog.verify(function() return {size = {x = 9, y = 9, z = 9}} end, "/mod")
	eq(inv.castle ~= nil, true, "castle invalid when file size differs")
	local listed = false
	for _, id in ipairs(catalog.ids()) do if id == "castle" then listed = true end end
	eq(listed, false, "invalid entry not in ids()")
	eq(#catalog.ids_for_role("castle"), 0, "invalid entry not in ids_for_role()")
	eq(catalog.snapshot().castle, nil, "invalid entry not in snapshot()")
	catalog.verify(read_known, "/m")
end

-- verify() with entrance.y absent defaults to 1.
do
	local saved_y = d.entrance.y
	d.entrance.y = nil
	eq(catalog.verify(read_known, "/mod").demo_house, nil, "entrance.y absent defaults to 1 and validates")
	d.entrance.y = saved_y
end

-- Generated assets must remain in sync with their catalog and metadata.
for _, id in ipairs(catalog.ids()) do
	local e = catalog.get(id)
	local f = assert(io.open(e.path, "rb"))
	local h = f:read(12); f:close()
	eq(h:sub(1, 4), "MTSM", id .. " schematic signature")
	local function u16(i) return h:byte(i) * 256 + h:byte(i + 1) end
	eq(u16(7), e.size.x, id .. " file width")
	eq(u16(9), e.size.y, id .. " file height")
	eq(u16(11), e.size.z, id .. " file depth")
	if e.data_path then
		local data = dofile(e.data_path)
		for _, m in ipairs(data.metadata or {}) do
			local p = m.offset
			eq(p.x >= 0 and p.x < e.size.x and p.y >= 0 and p.y < e.size.y
				and p.z >= 0 and p.z < e.size.z, true, id .. " metadata inside file")
		end
	end
end

-- Every imported template retains its real door height through rotations.
for _, id in ipairs(catalog.ids()) do
	local e = catalog.get(id)
	if e.data_path then
		eq(e.entrance.y, (id == "castle" and 8) or (id == "cathedral" and 5) or 1, id .. " exported entrance height")
		for _, r in ipairs(geometry.ROTATIONS) do
			local p = placement.plan(e, {x = 0, y = 8, z = 0}, r)
			eq(p.building.entrance.y, (id == "castle" and 11) or (id == "cathedral" and 12) or 9, id .. " rotated entrance Y " .. r)
		end
	end
end
for _, r in ipairs(geometry.ROTATIONS) do
	local p = placement.plan(castle, {x = 0, y = 8, z = 0}, r)
	eq(p.pos.y, 3, "castle foundation Y " .. r)
	eq(p.building.entrance.y, 11, "castle rotated gate Y " .. r)
end

-- Cathedral verification (ticket #31): file header, entrance at all rotations, required nodes.
local cathedral = catalog.get("cathedral")
-- 1. Verify MTS file header matches catalog declaration.
local cath_file = assert(io.open(cathedral.path, "rb"))
local cath_h = cath_file:read(14); cath_file:close()
local function u16_be(s, i) return s:byte(i) * 256 + s:byte(i + 1) end
eq(cath_h:sub(1, 4), "MTSM", "cathedral file magic")
local cath_sx = u16_be(cath_h, 7)
local cath_sy = u16_be(cath_h, 9)
local cath_sz = u16_be(cath_h, 11)
eq(cath_sx, cathedral.size.x, "cathedral file width vs catalog")
eq(cath_sy, cathedral.size.y, "cathedral file height vs catalog")
eq(cath_sz, cathedral.size.z, "cathedral file depth vs catalog")
-- 2. Verify entrance at all four rotations with exact coordinates (non-zero position).
local cath_pos = {x = 100, y = 20, z = 50}
local cath_expected = {
	[0]   = {lx = 35, lz = 8, sx = 55, sz = 59},
	[90]  = {lx = 8, lz = 19, sx = 59, sz = 55},
	[180] = {lx = 19, lz = 50, sx = 55, sz = 59},
	[270] = {lx = 50, lz = 35, sx = 59, sz = 55},
}
for _, rot in ipairs(geometry.ROTATIONS) do
	local exp = cath_expected[rot]
	local p = geometry.place(cathedral, cath_pos, rot)
	-- Entrance Y should be pos.y + entrance.y.
	eq(p.entrance.y, cath_pos.y + cathedral.entrance.y, "cathedral rot " .. rot .. " entrance Y")
	-- Entrance X/Z derived from rotate_local.
	eq(p.entrance.x, cath_pos.x + exp.lx, "cathedral rot " .. rot .. " entrance X")
	eq(p.entrance.z, cath_pos.z + exp.lz, "cathedral rot " .. rot .. " entrance Z")
	-- Size swaps at 90/270.
	eq(p.size.x, exp.sx, "cathedral rot " .. rot .. " size X")
	eq(p.size.z, exp.sz, "cathedral rot " .. rot .. " size Z")
	-- Outside is entrance + front vector.
	eq(p.outside.x - p.entrance.x, p.front.x, "cathedral rot " .. rot .. " outside X offset")
	eq(p.outside.z - p.entrance.z, p.front.z, "cathedral rot " .. rot .. " outside Z offset")
end
-- 3. Verify metadata and required nodes.
local cath_data = dofile(cathedral.data_path)
eq(#(cath_data.metadata or {}), 36, "cathedral metadata entries")
-- Check for duplicate required nodes.
local cath_node_set = {}
local cath_dupes = false
for _, n in ipairs(cath_data.required_nodes or {}) do
	if cath_node_set[n] then cath_dupes = true end
	cath_node_set[n] = true
end
eq(cath_dupes, false, "cathedral required_nodes has no duplicates")
eq(cath_node_set["living_villages:pulpit"] ~= nil, true, "cathedral has pulpit")
eq(cath_node_set["mcl_books:bookshelf"] ~= nil, true, "cathedral has bookshelf")
eq(cath_node_set["mcl_jukebox:jukebox"] ~= nil, true, "cathedral has jukebox")

-- Role, snapshot, non-square and touching-box tests live in
-- tests/catalog_tests.lua (ticket #28).
loadfile("tests/catalog_tests.lua")(eq, fails, geometry, catalog, placement)

-- Single-frontage packer (ticket #40).
loadfile("tests/frontage_packer_tests.lua")(eq, fails, geometry)

-- placement.parse_args: valid, bad count, bad rotation.
local id, rot = placement.parse_args("demo_house 90")
eq(id, "demo_house", "parse id")
eq(rot, 90, "parse rotation")
id, rot = placement.parse_args("  demo_house   0 ")
eq(rot, 0, "parse rotation 0 with spaces")
for _, bad_param in ipairs({"", "demo_house", "a b c", "demo_house 45", "demo_house -90",
		"demo_house 360", "demo_house 90.0", "demo_house 0x5A", "demo_house north"}) do
	local i, msg = placement.parse_args(bad_param)
	eq(i, nil, "rejects '" .. bad_param .. "'")
	eq(type(msg), "string", "message for '" .. bad_param .. "'")
end
eq(placement.parse_args(nil), nil, "nil param")

-- placement.plan: demo_house (9x8x7, entrance (4,1,0)), player ground (100,20,50).
local demo = catalog.get("demo_house")
local ground = {x = 100, y = 20, z = 50}
local castle_plan = placement.plan(castle, {x = 100, y = 8, z = 100}, 0)
xyz(castle_plan.pos, 108, 3, 100, "castle origin below ground")
xyz(castle_plan.bounds.min, 108, 3, 95, "castle full foundation emerged")
xyz(castle_plan.bounds.max, 161, 41, 149, "castle full height")
xyz(castle_plan.building.entrance, 138, 11, 106, "castle gate height and offset")
xz(castle_plan.building.front, 0, -1, "castle gate faces -Z")
local function check_plan(rot_, maxx, maxz, entx, entz, smin, smax, bmin, bmax)
	local p = placement.plan(demo, ground, rot_)
	local l = rot_ .. " "
	xyz(p.pos, 108, 20, 50, l .. "pos")
	xyz(p.building.min, 108, 20, 50, l .. "building min")
	eq(p.building.max.x, maxx, l .. "building max x")
	eq(p.building.max.z, maxz, l .. "building max z")
	eq(p.building.max.y, 27, l .. "building max y")
	xyz(p.building.entrance, entx, 21, entz, l .. "entrance")
	xyz(p.square.min, smin[1], 20, smin[2], l .. "square min")
	xyz(p.square.max, smax[1], 20, smax[2], l .. "square max")
	xyz(p.bounds.min, bmin[1], 19, bmin[2], l .. "bounds min")
	xyz(p.bounds.max, bmax[1], 27, bmax[2], l .. "bounds max")
	-- Square is 5x5, adjacent to the building and not overlapping it.
	eq(p.square.max.x - p.square.min.x, 4, l .. "square width")
	eq(p.square.max.z - p.square.min.z, 4, l .. "square depth")
	local o = p.building.outside
	eq(placement.in_box(p.square, o.x, o.z), true, l .. "square holds outside node")
	local overlap, n = false, 0
	placement.each_column(p, function(x, z, kind)
		n = n + 1
		if kind == "square" and placement.in_box(p.building, x, z) then overlap = true end
	end)
	eq(overlap, false, l .. "square does not overlap building")
	eq(n, 9 * 7 + 25, l .. "column count")
end
check_plan(0,   116, 56, 112, 50, {110, 45}, {114, 49}, {108, 45}, {116, 56})
check_plan(90,  114, 58, 108, 54, {103, 52}, {107, 56}, {103, 50}, {114, 58})
check_plan(180, 116, 56, 112, 56, {110, 57}, {114, 61}, {108, 50}, {116, 61})
check_plan(270, 114, 58, 114, 54, {115, 52}, {119, 56}, {108, 50}, {119, 58})

-- Entrance at the edge columns: the 5-wide square overhangs the building
-- side, and the bounds must include the overhang.
local synth = {size = {x = 9, y = 8, z = 7}}
for _, ex in ipairs({0, 8}) do
	synth.entrance = {x = ex, z = 0}
	for _, r_ in ipairs(geometry.ROTATIONS) do
		local p = placement.plan(synth, ground, r_)
		local l = "edge x=" .. ex .. " rot " .. r_ .. " "
		local e = p.building.entrance
		-- Square is centred on the entrance along the edge, 5 wide.
		if p.building.front.x == 0 then
			eq(p.square.min.x, e.x - 2, l .. "square min x")
			eq(p.square.max.x, e.x + 2, l .. "square max x")
		else
			eq(p.square.min.z, e.z - 2, l .. "square min z")
			eq(p.square.max.z, e.z + 2, l .. "square max z")
		end
		-- Square always inside the combined bounds, building too.
		eq(p.bounds.min.x <= math.min(p.square.min.x, p.building.min.x), true, l .. "bounds min x")
		eq(p.bounds.max.x >= math.max(p.square.max.x, p.building.max.x), true, l .. "bounds max x")
		eq(p.bounds.min.z <= math.min(p.square.min.z, p.building.min.z), true, l .. "bounds min z")
		eq(p.bounds.max.z >= math.max(p.square.max.z, p.building.max.z), true, l .. "bounds max z")
		local overlap = false
		placement.each_column(p, function(x, z, kind)
			if kind == "square" and placement.in_box(p.building, x, z) then overlap = true end
		end)
		eq(overlap, false, l .. "no overlap")
	end
end
-- Concrete: x=0, rot 0 -> entrance x=108, square x 106..110 (overhangs west).
synth.entrance = {x = 0, z = 0}
local ps = placement.plan(synth, ground, 0)
eq(ps.square.min.x, 106, "edge0 rot0 square min x")
eq(ps.bounds.min.x, 106, "edge0 rot0 bounds min x")
-- x=8, rot 90: entrance z = sx-1-8 = 0 -> square z 48..52, bounds min z 48.
synth.entrance = {x = 8, z = 0}
ps = placement.plan(synth, ground, 90)
eq(ps.square.min.z, 48, "edge8 rot90 square min z")
eq(ps.bounds.min.z, 48, "edge8 rot90 bounds min z")

-- Nothing in any plan lies within 3 nodes of the player's column.
for _, r_ in ipairs(geometry.ROTATIONS) do
	local p = placement.plan(demo, ground, r_)
	eq(p.bounds.min.x >= ground.x + 3, true, r_ .. " clear of the player")
	eq(p.bounds.min.y, ground.y - 1, r_ .. " support layer")
end
fails(function() placement.plan(demo, ground, 45) end, "invalid rotation", "plan rejects bad rotation")

-- classify
local infos = {
	["mcl_core:stone"] = {walkable = true},
	["mcl_core:water_source"] = {liquid = true},
	["mcl_core:leaves"] = {walkable = true, clearable = true},
	["mcl_flowers:poppy"] = {walkable = false},
}
local function info(name) return infos[name] end
eq(placement.classify("air", info), "air", "classify air")
eq(placement.classify("ignore", info), "unknown", "classify ignore")
eq(placement.classify("nope:node", info), "unknown", "classify unregistered")
eq(placement.classify("mcl_core:stone", info), "solid", "classify stone")
eq(placement.classify("mcl_core:water_source", info), "water", "classify water")
eq(placement.classify("mcl_core:leaves", info), "clear", "classify leaves")
eq(placement.classify("mcl_flowers:poppy", info), "clear", "classify plant")

-- scan_column: skips air/vegetation, stops at ground, reports water/unknown.
local function col(t, top) return function(y) return t[top - y + 1] or "solid" end end
local h = placement.scan_column(col({"air", "clear", "air", "solid"}, 10), 10, 0)
eq(h, 7, "scan finds first solid")
local hh, prob, py = placement.scan_column(col({"air", "clear", "water", "solid"}, 10), 10, 0)
eq(hh, nil, "scan water height")
eq(prob, "water", "scan water problem")
eq(py, 8, "scan water y")
hh, prob = placement.scan_column(col({"air", "unknown"}, 10), 10, 0)
eq(prob, "unknown", "scan unknown")
hh, prob = placement.scan_column(function() return "air" end, 10, 5)
eq(prob, "none", "scan no ground")

-- check_site
local plan0 = placement.plan(demo, ground, 0)
local function flat(y) return function() return y end end
local ok, reason = placement.check_site(plan0, flat(20))
eq(ok, true, "flat site ok")
eq((placement.check_site(plan0, flat(19))), true, "flat site one below ok")
eq((placement.check_site(plan0, flat(21))), true, "flat site one above ok")
ok, reason = placement.check_site(plan0, flat(22))
eq(ok, false, "site two above rejected")
eq(reason:find("too far from ground", 1, true) ~= nil, true, "far reason")
eq((placement.check_site(plan0, flat(17))), false, "site far below rejected")
-- Step of one is fine; step of two is not.
eq((placement.check_site(plan0, function(x) return x < 112 and 20 or 21 end)), true, "one-node step ok")
ok, reason = placement.check_site(plan0, function(x) return x < 112 and 19 or 21 end)
eq(ok, false, "two-node step rejected")
eq(reason:find("uneven", 1, true) ~= nil, true, "uneven reason")
-- Water in a single square column rejects the whole site.
ok, reason = placement.check_site(plan0, function(x, z)
	if x == 110 and z == 45 then return nil, "water", 20 end
	return 20
end)
eq(ok, false, "water rejected")
eq(reason:find("water or lava at (110,20,45)", 1, true) ~= nil, true, "water reason")
-- Only the plan's columns are consulted.
local seen = 0
placement.check_site(plan0, function() seen = seen + 1; return 20 end)
eq(seen, 9 * 7 + 25, "only plan columns inspected")
-- Missing ground and unloaded terrain.
ok, reason = placement.check_site(plan0, function() return nil, "none", 10 end)
eq(ok, false, "no ground rejected")
ok, reason = placement.check_site(plan0, function() return nil, "unknown", 20 end)
eq(reason:find("unloaded", 1, true) ~= nil, true, "unknown reason")

eq(placement.format_bounds(plan0.bounds), "(108,19,45) to (116,27,56)", "format_bounds")

-- Planner (ticket #12): boundary and civic sites.
loadfile("tests/planner_tests.lua")(eq, fails, dofile("src/planner.lua"))

-- Streets, blocks and frontage (ticket #13).
loadfile("tests/streets_tests.lua")(eq, fails, dofile("src/planner.lua"))

-- Site search (ticket #14): mocked-world search harness.
loadfile("tests/site_search_tests.lua")(eq, fails, placement, dofile("src/planner.lua"),
	dofile("src/site_search.lua"))

-- Town builder (ticket #15): blockouts, layout and the recording fake world.
loadfile("tests/builder_tests.lua")(eq, fails, placement, dofile("src/planner.lua"),
	dofile("src/site_search.lua"), dofile("src/builder.lua"))

-- /towns_generate command logic (ticket #16): args, seeds, report, fakes.
loadfile("tests/generate_tests.lua")(eq, fails, dofile("src/planner.lua"),
	dofile("src/generate.lua"))

-- Castle verification (ticket #30): dimensions, header parsing, placement at all rotations.
loadfile("tests/castle_verification_tests.lua")(eq, fails, geometry)

print(("%d checks, %d failures"):format(count, failures))
os.exit(failures == 0 and 0 or 1)
