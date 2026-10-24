-- Outskirts v1 worked example (issue #226). Pure data, no code under test:
-- docs/outskirts_design.md section "Worked example" quotes these records, and
-- tests/outskirts_contract_tests.lua checks that they agree with each other,
-- with src/geometry.lua and (when installed) with Living Villages.
--
-- Scenario: a Roman town at centre (1000, -2000), seed 8, finished urban
-- ground Y 62. The north exit leaves through arch_north. The terrain beyond the
-- town rises one node per six nodes northward, and the ground east of the road
-- (x > 1000) is one node higher (natural() below). One village group of two
-- cottages, one on each side, stands beside the extended road. The cottage asset is
-- ILLUSTRATIVE: no cottage exists in any catalog until issue #227; its
-- size/entrance/ground_offset only exercise a nonzero ground_offset.
--
-- Every rectangle is an inclusive X/Z rect {x1, z1, x2, z2}; every box is
-- {min = {x, y, z}, max = {x, y, z}} inclusive.

local F = {}

-- Frozen first-version constants. docs/outskirts_design.md quotes every one of
-- them verbatim (checked by tests/outskirts_contract_tests.lua); production
-- code (src/outskirts.lua) will define the same names and values.
F.constants = {
	VERSION = 1,
	TARGET_GROUPS = 2,
	ORDINARY_MIN = 8,
	ORDINARY_MAX = 12,
	GROUP_PLOTS_MIN = 4,
	GROUP_PLOTS_MAX = 6,
	MIN_ACCEPTED_PLOTS = 2,
	MAX_VILLAS = 2,
	MAX_CHAPELS = 1,
	PATH_WIDTH = 3,
	CUT_FILL_CAP = 2,
	VILLA_CAP = 1,
	ROAD_CAP = 2,
	ROAD_MAX_LENGTH = 100,
	SLOT_FIRST = 10,
	SLOT_STEP = 26,
	SLOTS_PER_EXIT = 2,
	GROUP_WINDOW = 24,
	SETBACK = 3,
	ATTEMPTS_PER_EXIT = 4,
	LANDMARK_GAP = 2,
	PLAYER_MARGIN = 4,
	SERVICE_WELL_RADIUS = 42,
	SERVICE_JUKEBOX_RADIUS = 48,
	ENVELOPE_LATERAL = 56,
	ENVELOPE_ALONG_END = 16,
	TERRAIN_MARGIN = 2,
	TERRAIN_RADIUS = 6,
	TERRAIN_WALL = 4,
	SUPPORT_ROWS = 3,
	CLEAR_ABOVE = 12,
	SCAN_UP = 24,
	SCAN_DOWN = 24,
	CUT_FILL_MARGIN = 8,
	SALT = 226,
	PATH_NODE = "mcl_core:grass_path",
	SURFACE_NODE = "mcl_core:dirt_with_grass",
}

-- Rejection codes (ordinary omissions); the document lists the same set.
F.rejection_codes = {
	"no_exits", "exit_inside_bounds",
	"road_unloaded", "road_water", "road_steep", "road_short",
	"plot_unloaded", "plot_water", "plot_overlap", "plot_inside_town",
	"plot_player", "plot_structure", "approach_blocked", "approach_steep",
	"pad_cut_fill", "yard_not_level", "skirt_steep", "group_small",
	"services_missing", "emerge_failed", "out_of_range",
}

F.town = {type = "roman", seed = 8, center = {x = 1000, z = -2000}, ground_y = 62}

-- Natural surface height (topmost solid ground, trees excluded).
function F.natural(x, z) return 64 + math.floor((z + 1919) / 6) + (x > 1000 and 1 or 0) end

-- The illustrative rural-only catalog entry (see header).
F.cottage = {
	id = "village_cottage_a", role = "house",
	size = {x = 7, y = 7, z = 8},
	entrance = {x = 3, y = 2, z = 0},   -- file-local; y = ground_offset + 1
	ground_offset = 1,
}

-- The Roman arch's clear corridor (schematics/imports/roman/README.md): file-local
-- X=5..6, Z=0..7 (wall posts at X=4 and X=7, Z=2 and Z=5; floor a half slab
-- at Y=1). Rotated through geometry.rotate_rect it is world -1..0 across
-- every arch at centre offset 0, so the lane centre -1 lies inside it.
F.arch_corridor = {x1 = 5, z1 = 0, x2 = 6, z2 = 7}

-- 1. Exits of the Roman plan at this centre, in canonical order (N, E, S, W).
-- cross = the principal street's extent across its axis; lane = the
-- PATH_WIDTH nodes used by the extended road (floor((width - 3) / 2) = 1 node
-- inset from the lower coordinate); join = last node inside the boundary union
-- on the lane's centre line; start = first node outside it.
F.exits = {
	{id = "e1", street_id = 1, via = "arch_north", dir = {x = 0, z = 1}, axis = "z", width = 6,
		cross = {c1 = 997, c2 = 1002}, lane = {c1 = 998, c2 = 1000}, centre = 999,
		join = {x = 999, z = -1915}, start = {x = 999, z = -1914}},
	{id = "e2", street_id = 3, via = "arch_east", dir = {x = 1, z = 0}, axis = "x", width = 6,
		cross = {c1 = -2003, c2 = -1998}, lane = {c1 = -2002, c2 = -2000}, centre = -2001,
		join = {x = 1085, z = -2001}, start = {x = 1086, z = -2001}},
	{id = "e3", street_id = 2, via = "arch_south", dir = {x = 0, z = -1}, axis = "z", width = 6,
		cross = {c1 = 997, c2 = 1002}, lane = {c1 = 998, c2 = 1000}, centre = 999,
		join = {x = 999, z = -2086}, start = {x = 999, z = -2087}},
	{id = "e4", street_id = 4, via = "arch_west", dir = {x = -1, z = 0}, axis = "x", width = 6,
		cross = {c1 = -2003, c2 = -1998}, lane = {c1 = -2002, c2 = -2000}, centre = -2001,
		join = {x = 905, z = -2001}, start = {x = 904, z = -2001}},
}
-- Trial order: the canonical list rotated to start at index seed % #exits + 1
-- (8 % 4 + 1 = 1 here, so the order is unchanged).
F.order = {"e1", "e2", "e3", "e4"}

-- 2. Road along e1. y[k] is the finished surface of lane column k (k = 1 is
-- the start column, z = start.z + k - 1). Start from the urban ground (62) and
-- move at most one node per column toward the natural height, with the landing rule. reach = how far
-- the road could run before a column failed (here the limit of the data we
-- scanned); length = what is built: only as far as the farthest accepted
-- approach needs (road_k + (PATH_WIDTH - 1) / 2).
-- Landing rule: y may change after a column only if the previous column was
-- level (y[k-1] == y[k-2]; the urban join counts as level), so steps are
-- separated by at least one level column.
F.road = {
	exit_id = "e1", reach = 33, length = 14, join_y = 62,
	natural = {64, 65, 65, 65, 65, 65, 65, 66, 66, 66, 66, 66, 66, 67},
	y       = {63, 63, 64, 64, 65, 65, 65, 66, 66, 66, 66, 66, 66, 67},
}

-- 3. One accepted group. Window k = 10..33 (slot 1); the candidate listed six
-- plots (g1p1..g1p3 west, g1p4..g1p6 east, each side from the window start,
-- one node between neighbours) and only the first plot on each side survived
-- its pad check. ground_y is the median natural height under the surviving
-- footprints, so every pad stays inside the cut/fill cap.
F.group = {
	id = "g1", kind = "village", exit_id = "e1", slot = 1, attempt = 1,
	window = {k1 = 10, k2 = 33}, ground_y = 67,
	plots = {
		{id = "g1p1", class = "cottage", asset = "village_cottage_a", side = -1, rotation = 270,
			rect = {x1 = 987, z1 = -1905, x2 = 994, z2 = -1899}},
		{id = "g1p4", class = "cottage", asset = "village_cottage_a", side = 1, rotation = 90,
			rect = {x1 = 1004, z1 = -1905, x2 = 1011, z2 = -1899}},
	},
}

-- 4. Entrance approaches. cells run from the node outside the door outward to
-- the lane edge; width is centred on the entrance coordinate across the
-- approach. y steps one node per cell from the group ground toward the road.
F.approaches = {
	{plot_id = "g1p1", from = {x = 995, z = -1902}, dir = {x = 1, z = 0}, length = 3, width = 3,
		y = {67, 66, 66}, road_k = 13, road_y = 66},
	{plot_id = "g1p4", from = {x = 1003, z = -1902}, dir = {x = -1, z = 0}, length = 3, width = 3,
		y = {67, 66, 66}, road_k = 13, road_y = 66},
}

-- 5. Pads (the Living Villages pad fields plus Towns bookkeeping). y is the
-- SITE GROUND Y, never the schematic origin.
F.pads = {
	{plot_id = "g1p1", x0 = 987, z0 = -1905, x1 = 994, z1 = -1899,
		yx0 = 985, yz0 = -1907, yx1 = 996, yz1 = -1897, y = 67,
		surface = "mcl_core:dirt_with_grass", height = 7},
	{plot_id = "g1p4", x0 = 1004, z0 = -1905, x1 = 1011, z1 = -1899,
		yx0 = 1002, yz0 = -1907, yx1 = 1013, yz1 = -1897, y = 67,
		surface = "mcl_core:dirt_with_grass", height = 7},
}

-- 6. Composed structures (preflight.compose shape plus site_ground_y, group,
-- plot). origin_y = ground_y - ground_offset = 66; feet = origin_y + entrance.y.
F.structures = {
	{id = "village_cottage_a", kind = "outskirts", role = "cottage", group = "g1", plot = "g1p1",
		rotation = 270, rect = {x1 = 987, z1 = -1905, x2 = 994, z2 = -1899},
		min = {x = 987, y = 66, z = -1905}, max = {x = 994, y = 72, z = -1899},
		size = {x = 8, y = 7, z = 7},
		entrance = {x = 994, y = 68, z = -1902}, front = {x = 1, z = 0},
		ground_offset = 1, site_ground_y = 67},
	{id = "village_cottage_a", kind = "outskirts", role = "cottage", group = "g1", plot = "g1p4",
		rotation = 90, rect = {x1 = 1004, z1 = -1905, x2 = 1011, z2 = -1899},
		min = {x = 1004, y = 66, z = -1905}, max = {x = 1011, y = 72, z = -1899},
		size = {x = 8, y = 7, z = 7},
		entrance = {x = 1004, y = 68, z = -1902}, front = {x = -1, z = 0},
		ground_offset = 1, site_ground_y = 67},
}

-- 7. Region (one per arm: the road and everything attached to it). Y runs from
-- the lowest finished surface - SUPPORT_ROWS (63 - 3) to the highest of
-- (structure top 72, natural/finished surface 69) + CLEAR_ABOVE (12).
-- volume = bounds + CUT_FILL_MARGIN (8) around and below.
F.region = {
	id = "r1", exit_id = "e1",
	-- X/Z = box of the WRITTEN columns: footprints, yards, changed skirt
	-- columns, lane and approaches (unchanged skirt columns are not written).
	written_box = {x1 = 985, z1 = -1914, x2 = 1013, z2 = -1897},
	bounds = {min = {x = 985, y = 60, z = -1914}, max = {x = 1013, y = 84, z = -1897}},
	volume = {min = {x = 977, y = 52, z = -1922}, max = {x = 1021, y = 84, z = -1889}},
	-- Living Villages targets() over the two pads (config margin 2, radius 6,
	-- cap 2, wall 4): columns owned per kind, and how many changed.
	targets = {
		bbox = {x1 = 979, z1 = -1913, x2 = 1019, z2 = -1891},
		owned = 807, written = 276, violations = 0, walls = 0,
		by_kind = {
			footprint1 = {n = 56, changed = 32, cut = 0, fill = 32},
			footprint2 = {n = 56, changed = 24, cut = 24, fill = 0},
			yard1 = {n = 76, changed = 40, cut = 0, fill = 40},
			yard2 = {n = 76, changed = 36, cut = 36, fill = 0},
			skirt1 = {n = 282, changed = 12, cut = 0, fill = 12},
			skirt2 = {n = 261, changed = 0, cut = 0, fill = 0},
		},
	},
	-- Sample finished columns (the real list holds every owned column).
	columns = {
		{x = 990, z = -1902, kind = "footprint", was = 66, at = 67, pad = "g1p1"},
		{x = 1008, z = -1899, kind = "footprint", was = 68, at = 67, pad = "g1p4"},
		{x = 985, z = -1907, kind = "yard", was = 66, at = 67, pad = "g1p1"},
		{x = 985, z = -1908, kind = "skirt", was = 65, at = 66, pad = "g1p1"},
		{x = 999, z = -1901, kind = "road", was = 67, at = 67, road_k = 14},
		{x = 996, z = -1902, kind = "approach", was = 66, at = 66, pad = "g1p1"},
	},
}

-- 8. Rejections (omissions) for the exits that produced nothing. subject is
-- "<exit>" or "<exit>:a<attempt>".
F.rejections = {
	{stage = "accept", code = "plot_water", subject = "g1p2",
		detail = "footprint column (987, -1897) is water"},
	{stage = "road", code = "road_water", subject = "e2",
		detail = "lane column (1090, -2001) is water; road reach 4"},
	{stage = "candidate", code = "road_short", subject = "e2:a1",
		detail = "road reach 4 does not cover window end k=33"},
	{stage = "accept", code = "pad_cut_fill", subject = "e3:a1",
		detail = "candidate plot 2 column (1001, -2100) needs 3 nodes of fill (cap 2)"},
}

return F
