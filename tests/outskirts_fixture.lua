-- Outskirts v1 worked example (issue #226). Pure data. docs/outskirts_design.md
-- quotes these records; tests/outskirts_contract_tests.lua checks that they agree
-- with each other, with src/geometry.lua, with the real planners, with the
-- installed VoxeLibre schematics and (when installed) with Living Villages.
--
-- Scenario: a Roman town at centre (1000, -2000), seed 8, urban ground Y 62.
-- Two of its planned outskirts buildings are shown: a farm in the near band
-- (north of the town) and a shepherd's hut in the far band (east of it). The
-- asset ids and the hut's canonical entrance FACING are provisional until the
-- imports of #227 measure them; sizes, door/loom/bed/composter positions are
-- measured from the installed VoxeLibre 0.92.3 mcl_villages schematics.
--
-- Rects are inclusive {x1, z1, x2, z2}; boxes are {min = {x, y, z}, max = {...}}.

local F = {}

-- Frozen first-version constants. The document quotes every one verbatim
-- (checked by the test). Everything here is a placeholder that is meant to be
-- retuned by editing one number.
F.constants = {
	VERSION = 1,
	FARM_COUNT = 18,
	HUT_COUNT = 6,
	VILLA_COUNT = 2,
	CHAPEL_COUNT = 1,
	FARM_BAND_NEAR = 10,
	FARM_BAND_FAR = 24,
	OUTER_BAND_NEAR = 24,
	OUTER_BAND_FAR = 58,
	MIN_SPACING = 20,
	PROTECT_MARGIN = 4,
	TERRAFORM_REACH = 10,
	PLAYER_MARGIN = 16,
	ATTEMPTS_PER_BUILDING = 6,
	SAMPLE_LIMIT = 50,
	MAX_SPREAD = 4,
	SCAN_UP = 48,
	SCAN_DOWN = 48,
	SALT = 226,
}

-- Rejection codes (ordinary omissions); the document lists the same set.
F.rejection_codes = {
	"no_site", "plot_protected", "plot_spacing", "plot_player", "plot_out_of_range",
	"plot_unloaded", "plot_water", "plot_uneven", "emerge_failed",
	"terraform_declined", "terraform_incomplete", "door_unreachable", "placement_failed",
}

F.town = {type = "roman", seed = 8, center = {x = 1000, z = -2000}, ground_y = 62}

-- Private random stream: state = (seed * 31 + SALT) % 2147483646 + 1;
-- next: state = state * 48271 % 2147483647; int(a, b) = a + next() % (b - a + 1).
F.rng = {seed = 8, first = {22928725, 838406270, 1379731455, 1106719894}}

-- Rural catalog entries (illustrative ids; measured geometry). Stock templates
-- keep the dirt layer (file y 0) as the ground row, so ground_offset is 0 and
-- the floor stands on file y 1 (as the tavern and well do).
F.assets = {
	farm = {
		id = "farm", class = "farm", size = {x = 9, y = 8, z = 7}, ground_offset = 0,
		entrance = nil,                              -- no door: composed as an object
		composter = {x = 4, y = 2, z = 0},           -- the farmer's jobsite
	},
	shepherd_hut = {
		id = "shepherd_hut", class = "hut", size = {x = 9, y = 9, z = 8}, ground_offset = 0,
		entrance = {x = 4, y = 2, z = 2},            -- door bottom node; facing -Z assumed (#227 confirms)
		loom = {x = 3, y = 2, z = 5}, bed = {x = 4, y = 2, z = 5},
	},
}

-- Living Villages protected rectangle spelling: inclusive x0..z1 plus margin.
F.protected = {x0 = 905, z0 = -2086, x1 = 1085, z1 = -1915, margin = 4}   -- plan.bounds
F.bounds = {x1 = 905, z1 = -2086, x2 = 1085, z2 = -1915}      -- Roman plan.bounds at this centre

-- Accepted plots. distance = Chebyshev gap between rect and plan.bounds.
-- heights = min/max natural height under the footprint; ground_y = lower median.
F.plots = {
	{id = "f01", class = "farm", asset = "farm", rotation = 90, band = "near",
		rect = {x1 = 1000, z1 = -1895, x2 = 1006, z2 = -1887}, distance = 20,
		heights = {min = 60, max = 62}, ground_y = 61},
	{id = "h01", class = "hut", asset = "shepherd_hut", rotation = 0, band = "far",
		rect = {x1 = 1135, z1 = -2010, x2 = 1143, z2 = -2003}, distance = 50,
		heights = {min = 63, max = 65}, ground_y = 64},
}

-- Composed structures (preflight.compose shape; the farm has no entrance).
F.structures = {
	{id = "farm", kind = "object", role = "farm", plot = "f01", rotation = 90,
		rect = {x1 = 1000, z1 = -1895, x2 = 1006, z2 = -1887},
		min = {x = 1000, y = 61, z = -1895}, max = {x = 1006, y = 68, z = -1887},
		size = {x = 7, y = 8, z = 9}, ground_offset = 0, site_ground_y = 61},
	{id = "shepherd_hut", kind = "outskirts", role = "hut", plot = "h01", rotation = 0,
		rect = {x1 = 1135, z1 = -2010, x2 = 1143, z2 = -2003},
		min = {x = 1135, y = 64, z = -2010}, max = {x = 1143, y = 72, z = -2003},
		size = {x = 9, y = 9, z = 8}, ground_offset = 0, site_ground_y = 64,
		entrance = {x = 1139, y = 66, z = -2008}, front = {x = 0, z = -1}},
}

-- Example of the public terrain API call shape: terraform(plan, pr, options),
-- one call per plot, with a settlement-style plan entry and protected rectangle.
F.lv_calls = {
	{plot_id = "f01",
		plan = {{name = "farm", pos = {x = 1000, y = 61, z = -1895}, rotat = "90"}},
		opts = {schematic_table = {{name = "farm", hwidth = 9, hdepth = 7, hheight = 8}},
			protected = {F.protected}}},
	{plot_id = "h01",
		plan = {{name = "shepherd_hut", pos = {x = 1135, y = 64, z = -2010}, rotat = "0"}},
		opts = {schematic_table = {{name = "shepherd_hut", hwidth = 9, hdepth = 8, hheight = 9}},
			protected = {F.protected}}},
}

-- Illustrative result of the farm's terraform call (`true, stats`; the numbers
-- are invented but consistent; `written` is the inclusive box of changed columns).
F.lv_result = {
	ok = true,
	stats = {changed = 152, cut = 40, filled = 112, steepest = 2, violations = 0, unloaded_blocks = 0,
		written = {minp = {x = 988, y = 41, z = -1905}, maxp = {x = 1018, y = 85, z = -1877}}},
}

-- Result counts of the example town (shortfalls are normal).
F.counts = {
	requested = {farm = 18, hut = 6, villa = 2, chapel = 0},
	planned = {farm = 16, hut = 6, villa = 1, chapel = 0},
	rejected = {plot_water = 5, plot_uneven = 3, no_site = 1},
}

return F
