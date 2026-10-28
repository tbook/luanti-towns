-- Plain Lua 5.1 tests for the pure modules. Run from the mod root:
--   lua5.1 tests/run.lua                      every group, small seed sets (CI)
--   TOWNS_TEST_FULL=1 lua5.1 tests/run.lua    also the broad seed/fuzz sweeps
--   TOWNS_TEST_ONLY=tests/x_tests.lua lua5.1 tests/run.lua   one group
-- Every group runs by default. Groups that sweep many generated towns read
-- TOWNS_TEST_FULL themselves and widen only their seed sweeps.
io.stdout:setvbuf("no")
local geometry = dofile("src/geometry.lua")
local catalog = dofile("src/catalog.lua")
local placement = dofile("src/placement.lua")

-- TOWNS_TEST_ONLY=tests/x_tests.lua runs just that group (for development).
local only_group = os.getenv("TOWNS_TEST_ONLY")
local only_group_ran = false
local failures, count = 0, 0
local function run_group(path, ...)
	if only_group and only_group ~= path then return end
	only_group_ran = true
	local started, started_count = os.clock(), count
	print("RUN " .. path)
	loadfile(path)(...)
	print(("DONE %s (%.2fs, %d checks)"):format(path, os.clock() - started, count - started_count))
end
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

-- The captured castle gate stays a six-node line on the outer wall in every
-- rotation. Canonical gate coordinates are X=21..26 on the -Z edge.
local canonical_gate = {x1 = 21, z1 = 0, x2 = 26, z2 = 0}
local rotated_gates = {
	[0] = {x1 = 21, z1 = 0, x2 = 26, z2 = 0},
	[90] = {x1 = 0, z1 = 23, x2 = 0, z2 = 28},
	[180] = {x1 = 23, z1 = 53, x2 = 28, z2 = 53},
	[270] = {x1 = 53, z1 = 21, x2 = 53, z2 = 26},
}
for _, rotation in ipairs(geometry.ROTATIONS) do
	local actual, expected = geometry.rotate_rect({x = 50, z = 54}, canonical_gate, rotation), rotated_gates[rotation]
	for _, k in ipairs({"x1", "z1", "x2", "z2"}) do
		eq(actual[k], expected[k], "castle gate rotation " .. rotation .. " " .. k)
	end
end
fails(function()
	geometry.rotate_rect({x = 50, z = 54}, {x1 = 21, z = 0, x2 = 50, z2 = 0}, 0)
end, "invalid local rectangle", "gate rotation rejects out-of-bounds span")

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
		-- The door bottom lies inside the file above row 0 (#87: captures that
		-- keep a ground row under the floor have entrance.y 2; the planner
		-- convention is checked against the real nodes in town_build_tests).
		eq(e.entrance.y >= 1 and e.entrance.y < e.size.y, true, id .. " exported entrance height")
		local ey = e.entrance.y
		for _, r in ipairs(geometry.ROTATIONS) do
			local b = geometry.place(e, {x = 0, y = 8 - (e.ground_offset or 0), z = 0}, r)
			eq(b.entrance.y, 8 + ey - (e.ground_offset or 0), id .. " rotated entrance Y " .. r)
		end
	end
end
for _, r in ipairs(geometry.ROTATIONS) do
	local b = geometry.place(castle, {x = 0, y = 8 - castle.ground_offset, z = 0}, r)
	eq(b.min.y, 3, "castle foundation Y " .. r)
	eq(b.entrance.y, 9, "castle rotated gate Y " .. r)
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
-- Metadata counts can change as workshop decorations are added; check authored
-- contents and door state below instead of pinning the count.
local cath_composters = 0
local cath_closed_doors = 0
for _, m in ipairs(cath_data.metadata or {}) do
	if m.name == "mcl_composters:composter" then cath_composters = cath_composters + 1 end
	if m.fields and m.fields.is_open == "0" then cath_closed_doors = cath_closed_doors + 1 end
end
eq(cath_composters, 2, "cathedral monastery farm has two composters (#93)")
eq(cath_closed_doors > 0, true, "cathedral preserves closed door state")
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
run_group("tests/catalog_tests.lua", eq, fails, geometry, catalog)
run_group("tests/roman_catalog_tests.lua", eq, fails, geometry, catalog, placement)

-- Single-frontage packer (ticket #40).
run_group("tests/frontage_packer_tests.lua", eq, fails, geometry)

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

-- Planner (ticket #12): boundary and civic sites.
run_group("tests/planner_tests.lua", eq, fails, dofile("src/planner.lua"))

-- Type-dispatched validation for authored non-medieval plans (issue #145).
run_group("tests/authored_plan_tests.lua", eq, fails, dofile("src/planner.lua"))
run_group("tests/roman_plan_tests.lua", eq, fails, dofile("src/planner.lua"))
run_group("tests/roman_population_tests.lua", eq, fails, dofile("src/planner.lua"), catalog, geometry)

-- Landmark profile reservations (ticket #38).
run_group("tests/landmark_profile_tests.lua", eq, fails, dofile("src/planner.lua"), catalog,
	geometry, dofile("src/site_search.lua")(placement, dofile("src/planner.lua")))

-- City hall reservation on the market (ticket #39).
run_group("tests/city_hall_tests.lua", eq, fails, dofile("src/planner.lua"), catalog, geometry)

-- Medieval variation: market quadrant, castle side, turn (issue #184).
run_group("tests/medieval_variation_tests.lua", eq, fails, dofile("src/planner.lua"), catalog)

-- Outskirts v1 contract: exits rule, worked example, Living Villages API (issue #226).
run_group("tests/outskirts_contract_tests.lua", eq, fails, dofile("src/planner.lua"), catalog, geometry)
run_group("tests/outskirts_terrain_tests.lua", eq)
run_group("tests/outskirts_planner_tests.lua", eq)
run_group("tests/outskirts_search_tests.lua", eq)
run_group("tests/outskirts_build_tests.lua", eq)
run_group("tests/outskirts_integration_tests.lua", eq)

-- Jail reservation on street frontage (ticket #69).
run_group("tests/jail_reservation_tests.lua", eq, fails, dofile("src/planner.lua"), catalog, geometry)

-- Service reservations: taverns, wells, chapels (ticket #41).
run_group("tests/service_reservation_tests.lua", eq, fails, dofile("src/planner.lua"), catalog, geometry)

-- Frontage content planning (ticket #42).
run_group("tests/content_planner_tests.lua", eq, fails, dofile("src/planner.lua"), catalog, geometry)

-- Site search (ticket #14): mocked-world search harness.
run_group("tests/open_space_tests.lua", eq)

run_group("tests/site_search_tests.lua", eq, fails, placement, dofile("src/planner.lua"),
	dofile("src/site_search.lua"))

-- Optional Living Villages city-margin adapter (#259); contract tested with a fake API.
run_group("tests/city_margins_tests.lua", eq, dofile("src/city_margins.lua"))
run_group("tests/city_margins_lv_integration.lua", eq)

-- Preflight and build-volume emergence (ticket #44).
run_group("tests/preflight_tests.lua", eq, fails, dofile("src/planner.lua"), catalog, geometry,
	dofile("src/site_search.lua"))

-- Town builder (tickets #15, #45): ground layout and terrain writes on a small authored plan.
run_group("tests/builder_tests.lua", eq, fails, placement, dofile("src/planner.lua"),
	dofile("src/site_search.lua"), dofile("src/builder.lua"))

-- Town placement (ticket #45): schematics, door routes, failures.
run_group("tests/town_build_tests.lua", eq, fails, dofile("src/planner.lua"), catalog, placement,
	dofile("src/site_search.lua"), dofile("src/builder.lua"))

-- Functional node initialization adapter (ticket #46).
run_group("tests/node_setup_tests.lua", eq, fails, catalog, dofile("src/node_setup.lua"))

-- Bed enumeration adapter (ticket #47).
run_group("tests/residents_tests.lua", eq, fails, catalog, dofile("src/residents.lua"))

-- /towns_generate command logic (ticket #16): args, seeds, report, fakes.
run_group("tests/generate_tests.lua", eq, fails, dofile("src/planner.lua"),
	dofile("src/generate.lua"))

-- Castle verification (ticket #30): dimensions, header parsing, placement at all rotations.
run_group("tests/shared_sites_tests.lua", eq)
run_group("tests/castle_verification_tests.lua", eq, fails, geometry)

-- Stock village tavern and well templates (tickets #35, #36).
run_group("tests/stock_templates_tests.lua", eq, catalog)
run_group("tests/outskirts_assets_tests.lua", eq, geometry, catalog, placement,
	dofile("src/planner.lua"), dofile("src/builder.lua"))

-- Rotated walls (#166): wall connections in the node name follow the rotation.
run_group("tests/wall_rotation_tests.lua", eq, dofile("src/schematic.lua"))
run_group("tests/medieval_walls_tests.lua", eq, dofile("src/planner.lua"), catalog)

-- Roman checker expectations (#188): wall names as schematic.place leaves them.
run_group("tests/roman_check_expect_tests.lua", eq, dofile("src/schematic.lua"))

-- Layout comparison tool (ticket #109): deterministic artifacts and metrics.
run_group("tests/layout_compare_tests.lua", eq, fails, dofile("src/planner.lua"), catalog)

if only_group and not only_group_ran then
	print("TOWNS_TEST_ONLY matched no group: " .. only_group)
	os.exit(2)
end
print(("%d checks, %d failures"):format(count, failures))
os.exit(failures == 0 and 0 or 1)
