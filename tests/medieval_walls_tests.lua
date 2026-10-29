local eq, planner, catalog = ...
do
	local walls = dofile("src/medieval_walls.lua")
	local plan = {town_type = "medieval", seed = 42,
		boundary = {rects = {{x1 = 0, z1 = 0, x2 = 9, z2 = 9},
			{x1 = 3, z1 = 10, x2 = 6, z2 = 13}}},
		streets = {{id = 1, kind = "principal", rect = {x1 = 4, z1 = 0, x2 = 5, z2 = 9}}}}
	local wall = walls.plan(plan, true)
	local function has(list, x, z)
		for _, c in ipairs(list) do if c.x == x and c.z == z then return true end end
		return false
	end
	eq(has(wall.openings, 4, -1), true, "external road crossing has an opening")
	eq(has(wall.cells, 4, -1), false, "crossing contains no wall")
	eq(has(wall.cells, 4, 10), false, "compound join is not walled")
	eq(has(wall.cells, -1, -1), true, "outer corner joins both runs")
	eq(walls.plan(plan, false), nil, "wall can be forced off")
	plan.town_type = "roman"
	eq(walls.plan(plan, true), nil, "Roman towns never get walls")
	local sample = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}},
		{x = 0, z = 3, direction = {x = 1, z = 0}}}, openings = {}}
	local region = {get = function(x, y, z)
		if z == 0 and y == 0 then return "mcl_core:stone" end
		return "air"
	end}
	local changes, omissions = walls.inspect(sample, 0, region, function(name)
		if name == "mcl_core:stone" then return {walkable = true} end
		return {walkable = false}
	end, function() return false end)
	eq(#omissions, 0, "a deep unobstructed drop gets a floating wall section")
	eq(#changes > 0, true, "supported and floating columns are built independently")
	local floating_low, floating_high
	for _, change in ipairs(changes) do
		if change.x == 0 and change.z == 3 then
			floating_low = math.min(floating_low or change.y, change.y)
			floating_high = math.max(floating_high or change.y, change.y)
		end
	end
	eq(floating_low, -walls.DEPTH + 1, "floating wall hangs to the documented depth limit")
	eq(floating_high, 4, "floating wall keeps the level cap")
	local deep_supported, deep_omissions = walls.inspect({cells = {{x = 0, z = 0,
		direction = {x = 1, z = 0}}}, openings = {}}, 0, {get = function(_, y)
		if y == -30 then return "mcl_core:stone" end
		return "air"
	end}, function(name) return {walkable = name == "mcl_core:stone"} end, function() return false end)
	eq(#deep_omissions, 0, "natural support within the tall-wall bound is accepted")
	local deep_low
	for _, change in ipairs(deep_supported) do
		if change.x == 0 then deep_low = math.min(deep_low or change.y, change.y) end
	end
	eq(deep_low, -29, "tall supported foundation reaches the deep terrain")
	local water_column, water_omissions = walls.inspect({cells = {{x = 0, z = 0,
		direction = {x = 1, z = 0}}}, openings = {}}, 0, {get = function(_, y)
		if y == -12 or y == -11 or y == -10 then return "test:water_source" end
		if y == -13 then return "mcl_core:stone" end
		return "air"
	end}, function(name) return {liquid = name == "test:water_source", walkable = name == "mcl_core:stone"} end,
	function() return false end)
	eq(#water_omissions, 0, "water above a natural bottom supports the wall")
	local water_bottom
	for _, change in ipairs(water_column) do
		if change.x == 0 then water_bottom = math.min(water_bottom or change.y, change.y) end
	end
	eq(water_bottom, -12, "wall fills water down to the bottom")
	local deep_water, deep_water_omissions = walls.inspect({cells = {{x = 0, z = 0,
		direction = {x = 1, z = 0}}}, openings = {}}, 0, {get = function(_, y)
		if y < 0 then return "test:water_source" end
		return "air"
	end}, function(name) return {liquid = name == "test:water_source"} end, function() return false end)
	eq(#deep_water, 0, "water deeper than the foundation search is left untouched")
	eq(deep_water_omissions[1].reason, "water bottom beyond reach", "deep water fallback is reported")
	eq(deep_water_omissions[1].blocker.node, "test:water_source", "deep water diagnostic names the water node")
	eq(deep_water_omissions[1].blocker.y, -walls.DEPTH, "deep water diagnostic points to the search limit")
	local protected_water, protected_water_omissions = walls.inspect({cells = {{x = 0, z = 0,
		direction = {x = 1, z = 0}, protected = true}}, openings = {}}, 0, {get = function(_, y)
		if y < 0 then return "test:water_source" end
		return "air"
	end}, function(name) return {liquid = name == "test:water_source"} end, function() return false end)
	eq(#protected_water, 0, "protected water column is untouched")
	eq(protected_water_omissions[1].reason, "protected", "protected water column is reported")
	local falling_bottom, falling_omissions = walls.inspect({cells = {{x = 0, z = 0,
		direction = {x = 1, z = 0}}}, openings = {}}, 0, {get = function(_, y)
		if y == -10 or y == -11 then return "test:water_source" end
		if y == -12 then return "mcl_core:sand" end
		if y == -13 then return "mcl_core:stone" end
		return "air"
	end}, function(name)
		return {liquid = name == "test:water_source", walkable = name ~= "test:water_source" and name ~= "air",
			falling = name == "mcl_core:sand"}
	end, function() return false end)
	eq(#falling_omissions, 0, "falling natural bottom is supported by stable ground")
	local falling_min
	for _, change in ipairs(falling_bottom) do
		if change.x == 0 then falling_min = math.min(falling_min or change.y, change.y) end
	end
	eq(falling_min, -11, "wall replaces water above a supported falling bottom")
	local lava_column, lava_omissions = walls.inspect({cells = {{x = 0, z = 0,
		direction = {x = 1, z = 0}}}, openings = {}}, 0, {get = function(_, y)
		if y == -12 then return "test:lava_source" end
		if y == -13 then return "mcl_core:stone" end
		return "air"
	end}, function(name) return {liquid = name == "test:lava_source", walkable = name == "mcl_core:stone"} end,
	function() return false end)
	eq(#lava_column, 0, "lava is never replaced by wall masonry")
	eq(#lava_omissions, 1, "lava still blocks a wall column")
	local obstructed_water, obstructed_water_omissions = walls.inspect({cells = {{x = 0, z = 0,
		direction = {x = 1, z = 0}}}, openings = {}}, 0, {get = function(_, y)
		if y == -10 then return "test:water_source" end
		if y == -11 then return "test:tree" end
		return y == -12 and "mcl_core:stone" or "air"
	end}, function(name)
		return {liquid = name == "test:water_source", walkable = name == "mcl_core:stone" or name == "test:tree"}
	end, function() return false end)
	eq(#obstructed_water, 0, "structure in a water foundation column is preserved")
	eq(obstructed_water_omissions[1].reason, "water or obstruction", "obstructed water foundation is reported")
	eq(obstructed_water_omissions[1].blocker.x, 0, "obstruction diagnostic gives world x")
	eq(obstructed_water_omissions[1].blocker.y, -11, "obstruction diagnostic gives blocker height")
	eq(obstructed_water_omissions[1].blocker.z, 0, "obstruction diagnostic gives world z")
	eq(obstructed_water_omissions[1].blocker.node, "test:tree", "obstruction diagnostic names the blocking node")
	local submerged_approach = {cells = {}, openings = {{x = 0, z = 0,
		direction = {x = 1, z = 0}, material = "road"}}}
	local submerged_changes, submerged_omissions = walls.inspect(submerged_approach, 0,
		{get = function(_, y) return y == 1 and "test:water_source" or y == -1 and "mcl_core:stone" or "air" end},
		function(name) return {liquid = name == "test:water_source", walkable = name == "mcl_core:stone"} end,
		function() return false end)
	eq(#submerged_changes, 0, "water in approach headroom is preserved")
	eq(submerged_omissions[1].blocker.node, "test:water_source", "approach diagnostic names the water node")
	eq(submerged_omissions[1].blocker.y, 1, "approach diagnostic gives water height")
	eq(submerged_omissions[1].reason, "approach: water in approach headroom", "submerged approach omission is reported")
	local deep_water_approach = {cells = {}, openings = {{x = 0, z = 0,
		direction = {x = 1, z = 0}, material = "road"}}}
	local _, deep_approach_omissions = walls.inspect(deep_water_approach, 0, {get = function(_, y)
		return y < 0 and "test:water_source" or "air"
	end}, function(name) return {liquid = name == "test:water_source"} end, function() return false end)
	eq(deep_approach_omissions[1].blocker.node, "test:water_source", "deep approach reports water instead of air at the limit")
	eq(deep_approach_omissions[1].blocker.search_limit_y, -walls.DEPTH, "deep approach diagnostic states the search limit")
	local deep_reservation = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}}}, openings = {}}
	local reserved_deep = false
	walls.reserve(deep_reservation, 0, function(p)
		if p.x == 0 and p.y == -walls.DEPTH then reserved_deep = true end
		return false
	end)
	eq(reserved_deep, true, "protection reservation covers the full tall-wall depth")
	eq(walls.bounds(deep_reservation, 0).min.y, -walls.DEPTH,
		"reported wall envelope covers the full tall-wall depth")
	local cardinal_corbel = {cells = {
		{x = 0, z = 0, direction = {x = 1, z = 0}},
		{x = 0, z = 4, direction = {x = -1, z = 0}},
		{x = 10, z = 0, direction = {x = 0, z = 1}},
		{x = 14, z = 0, direction = {x = 0, z = -1}},
	}, openings = {}}
	local corbels = walls.inspect(cardinal_corbel, 0, {get = function(_, y)
		return y == 0 and "mcl_core:stone" or "air"
	end}, function(name) return {walkable = name == "mcl_core:stone"} end, function() return false end)
	local corbel_param2 = {}
	for _, change in ipairs(corbels) do
		if change.name == walls.STAIR then corbel_param2[change.x .. ":" .. change.z] = change.param2 end
	end
	eq(corbel_param2["1:0"], 21, "+X corbel rises toward the wall")
	eq(corbel_param2["-1:4"], 23, "-X corbel rises toward the wall")
	eq(corbel_param2["10:1"], 22, "+Z corbel rises toward the wall")
	eq(corbel_param2["14:-1"], 20, "-Z corbel rises toward the wall")
	local selected = 0
	plan.town_type = "medieval"
	for seed = 1, 1000 do plan.seed = seed; if walls.selected(plan) then selected = selected + 1 end end
	eq(selected >= 750 and selected <= 850, true, "selection covers approximately 80 percent of seeds")
	local approach = {cells = {}, openings = {{x = 0, z = 0, direction = {x = 1, z = 0}, material = "road"}}}
	walls.reserve(approach, 0, function(p) return p.x == 3 and p.y == 0 end)
	local _, protected = walls.inspect(approach, 0, {get = function(_, y)
		return y == 0 and "mcl_core:stone" or "air"
	end}, function(name) return {walkable = name == "mcl_core:stone"} end, function() return false end)
	eq(#protected, 4, "reservation preserves protection across the full crossing approach")
	eq(protected[1].blocker.x, 3, "reserved approach diagnostic reports the actual protected column")
	local multi_approach = {cells = {}, openings = {{x = 0, z = 0, direction = {x = 1, z = 0}, material = "road"}}}
	walls.reserve(multi_approach, 0, function(p)
		return (p.x == 1 and p.y == -2) or (p.x == 3 and p.y == 1)
	end)
	local _, multi_protected = walls.inspect(multi_approach, 0, {get = function(x, y)
		if x == 1 and y == -2 then return "test:first" end
		if x == 3 and y == 1 then return "test:second" end
		return y == -1 and "mcl_core:stone" or "air"
	end}, function(name) return {walkable = name == "mcl_core:stone"} end, function() return false end)
	eq(#multi_protected, 4, "any opening reservation preserves whole-approach protection")
	eq(multi_protected[1].blocker.x, 1, "first protected approach reports its own position")
	eq(multi_protected[1].blocker.y, -2, "first protected approach reports its own height")
	eq(multi_protected[1].blocker.node, "test:first", "first protected approach reports its own node")
	eq(multi_protected[2].blocker.x, 1, "whole-approach omission retains the actual protected position")
	local legacy_opening = {cells = {}, openings = {{x = 5, z = 0,
		direction = {x = 1, z = 0}, material = "road", protected = true}}}
	local _, legacy_protected = walls.inspect(legacy_opening, 0, {get = function() return "air" end},
		function() return {} end, function() return false end)
	eq(#legacy_protected, 4, "legacy boolean opening reservation remains supported")
	eq(legacy_protected[1].blocker.node, "unknown", "legacy boolean reservation reports unknown blocker details")
	local already_reserved = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}, protected = true}}, openings = {}}
	local legacy_reserve_ok = pcall(function()
		walls.reserve(already_reserved, 0, function(p) return p.x == 0 and p.y == 2 end)
	end)
	eq(legacy_reserve_ok, true, "reserve safely preserves a preexisting boolean protection marker")
	local _, legacy_core_protected = walls.inspect(already_reserved, 0, {get = function() return "air" end},
		function() return {} end, function() return false end)
	eq(legacy_core_protected[1].blocker.node, "unknown", "legacy core protection avoids a fabricated position")
	approach.openings[1].protected = false
	local built, missing = walls.inspect(approach, 0, {get = function(_, y)
		return y == -2 and "mcl_core:stone" or "air"
	end}, function(name) return {walkable = name == "mcl_core:stone"} end, function() return false end)
	eq(#missing, 0, "supported road approach is accepted")
	eq(#built, 8, "road approach fills all four columns down to support")
	local placement = dofile("src/placement.lua")
	local wall_nodes = {
		["mcl_mushrooms:mushroom_brown"] = {walkable = true, groups = {mushroom = 1}},
		["mcl_flowers:grass"] = {walkable = false, groups = {plant = 1}},
		["mcl_chests:chest"] = {walkable = true, groups = {deco_block = 1}},
		["mcl_core:crafting_table"] = {walkable = true, groups = {deco_block = 1}},
		["test:buildable_structure"] = {walkable = true, buildable_to = true},
		["mcl_core:tree"] = {walkable = true, groups = {tree = 1, building_block = 1}},
		["test:liquid_plant"] = {walkable = false, liquidtype = "source", groups = {plant = 1}},
		["test:icy_plant"] = {walkable = true, groups = {plant = 1, ice = 1}},
	}
	local function wall_node_info(name)
		if name == "mcl_core:stone" then return {walkable = true} end
		return placement.node_info(wall_nodes, name)
	end
	local vegetated_wall = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}}}, openings = {}}
	for _, blocked_y in ipairs({4, 5}) do
		local placed, skipped = walls.inspect(vegetated_wall, 0, {get = function(x, y)
			if y == 0 then return "mcl_core:stone" end
			if x == 1 and y == blocked_y then return "mcl_core:tree" end
			return "air"
		end}, wall_node_info, function() return false end)
		local core_count, decoration_count = 0, 0
		for _, change in ipairs(placed) do
			if change.x == 0 then core_count = core_count + 1 else decoration_count = decoration_count + 1 end
		end
		eq(core_count, 4, "roof at overhang height " .. blocked_y .. " leaves wall core intact")
		eq(decoration_count, 0, "blocked overhang is omitted as a unit")
		eq(skipped[1].reason, "decoration: water or obstruction", "blocked overhang is reported")
	end
	local reserved_wall = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}}}, openings = {}}
	walls.reserve(reserved_wall, 0, function(p) return p.x == 1 and p.y == 4 end)
	local reserved_changes, reserved_omissions = walls.inspect(reserved_wall, 0, {get = function(_, y)
		return y == 0 and "mcl_core:stone" or "air"
	end}, wall_node_info, function() return false end)
	eq(#reserved_changes, 4, "reserved protected overhang does not omit the core")
	eq(reserved_omissions[1].reason, "decoration: protected", "reserved overhang protection is reported")
	eq(reserved_omissions[1].blocker.x, 1, "reserved decoration reports protected x")
	eq(reserved_omissions[1].blocker.y, 4, "reserved decoration reports protected y")
	eq(reserved_omissions[1].blocker.node, "air", "reserved decoration reports the node at protection position")
	local runtime_changes, runtime_omissions = walls.inspect(vegetated_wall, 0, {get = function(_, y)
		return y == 0 and "mcl_core:stone" or "air"
	end}, wall_node_info, function(p) return p.x == 1 and p.y == 5 end)
	eq(#runtime_changes, 4, "new protection on overhang leaves the core intact")
	eq(runtime_omissions[1].reason, "decoration: protected", "new overhang protection is reported")
	local core_changes, core_omissions = walls.inspect(vegetated_wall, 0, {get = function(x, y)
		if y == 0 then return "mcl_core:stone" end
		if x == 0 and y == 3 then return "mcl_core:tree" end
		return "air"
	end}, wall_node_info, function() return false end)
	eq(#core_changes, 0, "roof overlapping core is preserved without partial wall placement")
	eq(#core_omissions, 1, "core overlap is reported as a wall gap")
	eq(core_omissions[1].reason, "water or obstruction", "core obstruction has a wall omission reason")
	local vegetation_changes, vegetation_omissions = walls.inspect(vegetated_wall, 0,
		{get = function(x, y)
			if y == -1 then return "mcl_core:stone" end
			if y == 0 then return x == 0 and "mcl_mushrooms:mushroom_brown" or "mcl_core:stone" end
			if x == 0 and y == 2 then return "mcl_flowers:grass" end
			return "air"
		end}, wall_node_info, function() return false end)
	eq(#vegetation_omissions, 0, "mushrooms and plants do not omit wall columns")
	local replaced_mushroom, replaced_plant = false, false
	for _, change in ipairs(vegetation_changes) do
		if change.x == 0 and change.y == 0 and change.name == walls.BRICK then replaced_mushroom = true end
		if change.x == 0 and change.y == 2 and change.name == walls.BRICK then replaced_plant = true end
	end
	eq(replaced_mushroom, true, "wall replaces a mushroom in its foundation footprint")
	eq(replaced_plant, true, "wall replaces a plant above its foundation")
	local vegetated_approach = {cells = {}, openings = {{x = 0, z = 0, direction = {x = 1, z = 0}, material = "road"}}}
	local approach_changes, approach_omissions = walls.inspect(vegetated_approach, 0,
		{get = function(x, y)
			if y == -1 and x == 0 then return "mcl_core:stone" end
			if y == 0 and x == 0 then return "mcl_mushrooms:mushroom_brown" end
			if y == 0 and x ~= 0 then return "mcl_core:stone" end
			if x == 1 and y == 1 then return "mcl_flowers:grass" end
			return "air"
		end}, wall_node_info, function() return false end)
	eq(#approach_omissions, 0, "vegetation does not block an approach")
	local paved_mushroom, cleared_plant = false, false
	for _, change in ipairs(approach_changes) do
		if change.x == 0 and change.y == 0 and change.name == "road" then paved_mushroom = true end
		if change.x == 1 and change.y == 1 and change.name == "air" then cleared_plant = true end
	end
	eq(paved_mushroom, true, "approach paving replaces a mushroom")
	eq(cleared_plant, true, "approach clears overhead plants")
	for _, structure in ipairs({"mcl_chests:chest", "mcl_core:crafting_table", "test:buildable_structure",
			"mcl_core:tree"}) do
		local structure_changes, structure_omissions = walls.inspect(vegetated_wall, 0,
			{get = function(_, y)
				if y == -1 then return "mcl_core:stone" end
				if y == 2 then return structure end
				return "air"
			end}, wall_node_info, function() return false end)
		eq(#structure_changes, 0, structure .. " is preserved in wall columns")
		eq(#structure_omissions, 1, structure .. " blocks its wall column")
	end
	for _, obstruction in ipairs({"test:liquid_plant", "test:icy_plant", "test:unknown"}) do
		local unsafe_changes, unsafe_omissions = walls.inspect(vegetated_wall, 0,
			{get = function(_, y)
				if y == 0 then return "mcl_core:stone" end
				return y == 2 and obstruction or "air"
			end}, wall_node_info,
			function() return false end)
		eq(#unsafe_changes, 0, obstruction .. " is never replaced")
		eq(#unsafe_omissions, 1, obstruction .. " remains an obstruction")
	end
	local protected_changes, protected_omissions = walls.inspect(vegetated_wall, 0,
		{get = function(_, y)
			if y == -1 then return "mcl_core:stone" end
			if y == 0 then return "mcl_mushrooms:mushroom_brown" end
			return "air"
		end}, wall_node_info, function(p) return p.x == 0 and p.y == 0 and p.z == 0 end)
	eq(#protected_changes, 0, "protected vegetation is not replaced")
	eq(#protected_omissions, 1, "protected vegetation omits its wall column")
	local obstructed, blocked = walls.inspect(sample, 0, {get = function(_, y)
		return y == 0 and "mcl_core:stonebrick" or "air"
	end}, function() return {walkable = true} end, function() return false end)
	eq(#obstructed, 0, "existing masonry is not treated as terrain support")
	eq(#blocked, 2, "existing structures cause local omissions")
	local terrain_sample = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}},
		{x = 0, z = 3, direction = {x = 1, z = 0}},
		{x = 0, z = 6, direction = {x = 1, z = 0}},
		{x = 0, z = 9, direction = {x = 1, z = 0}}}, openings = {}}
	local terrain_changes, terrain_omissions = walls.inspect(terrain_sample, 0, {get = function(_, y, z)
		if y == 0 and z == 0 then return "mcl_core:dirt_with_grass_snow" end
		if y == 0 and (z == 3 or z == 6) then return "mcl_core:sand" end
		if y == 0 and z == 9 then return "mcl_core:gravel" end
		if y == -1 and (z == 3 or z == 9) then return "mcl_core:stone" end
		return "air"
	end}, function(name)
		return {walkable = name ~= "air", falling = name == "mcl_core:sand" or name == "mcl_core:gravel"}
	end, function() return false end)
	eq(#terrain_omissions, 1, "only the unsupported falling surface is omitted")
	eq(terrain_omissions[1].z, 6, "falling sand above air is not accepted as support")
	local built_at = {}
	for _, c in ipairs(terrain_changes) do built_at[c.z] = true end
	eq(built_at[0], true, "snowy grass supports the wall")
	eq(built_at[3], true, "sand supported by natural stone supports the wall")
	eq(built_at[9], true, "gravel supported by natural stone supports the wall")
	-- VoxeLibre badlands use these real hardened-clay node names. A wall may
	-- stand on natural terracotta while crafted masonry remains an obstruction.
	for _, substrate in ipairs({"mcl_colorblocks:hardened_clay",
			"mcl_colorblocks:hardened_clay_orange", "mcl_colorblocks:hardened_clay_yellow"}) do
		local clay_wall = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}}}, openings = {}}
		local clay_changes, clay_omissions = walls.inspect(clay_wall, 0, {get = function(_, y)
			if y == 0 then return substrate end
			return y < 0 and "mcl_core:stone" or "air"
		end}, function(name)
			return {walkable = name ~= "air", falling = name == "mcl_core:sand"}
		end, function() return false end)
		eq(#clay_omissions, 0, substrate .. " supports a wall")
		local above_substrate = false
		for _, change in ipairs(clay_changes) do
			if change.x == 0 and change.y == 1 and change.name == walls.BRICK then above_substrate = true end
		end
		eq(above_substrate, true, substrate .. " remains beneath the wall")
	end
	-- Natural badlands place red sand over hardened-clay strata. This used to
	-- fail even though sand itself was in NATURAL: support stopped at the
	-- unrecognized hardened-clay block beneath it.
	for _, surface in ipairs({"mcl_core:sand", "mcl_core:redsand"}) do
		local mesa_wall = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}}}, openings = {}}
		local mesa_changes, mesa_omissions = walls.inspect(mesa_wall, 0, {get = function(_, y)
			if y == 0 then return surface end
			if y == -1 then return "mcl_colorblocks:hardened_clay_orange" end
			return y < -1 and "mcl_core:stone" or "air"
		end}, function(name)
			return {walkable = name ~= "air", falling = name == "mcl_core:sand" or name == "mcl_core:redsand"}
		end, function() return false end)
		eq(#mesa_omissions, 0, surface .. " over natural hardened clay supports a wall")
		local wall_above_sand = false
		for _, change in ipairs(mesa_changes) do
			if change.x == 0 and change.y == 1 and change.name == walls.BRICK then wall_above_sand = true end
		end
		eq(wall_above_sand, true, surface .. " remains beneath the wall")
	end
	local loose_sand, loose_sand_omissions = walls.inspect({cells = {{x = 0, z = 0,
		direction = {x = 1, z = 0}}}, openings = {}}, 0, {get = function(_, y)
		if y == 0 then return "mcl_core:sand" end
		return "air"
	end}, function(name)
		return {walkable = name ~= "air", falling = name == "mcl_core:sand"}
	end, function() return false end)
	eq(#loose_sand, 0, "unsupported natural sand is never replaced by a floating wall")
	eq(#loose_sand_omissions, 1, "unsupported natural sand is reported")
	eq(loose_sand_omissions[1].blocker.y, -1, "unsupported sand diagnostic points below the falling stack")
	eq(loose_sand_omissions[1].blocker.node, "air", "unsupported sand diagnostic names the failed support node")
	local reserved_core = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}}}, openings = {}}
	walls.reserve(reserved_core, 0, function(p) return p.x == 0 and p.y == -7 end)
	local _, protected_omissions = walls.inspect(reserved_core, 0, {get = function(_, y)
		return y == -7 and "mcl_core:chest" or "air"
	end}, function() return {} end, function() return false end)
	eq(protected_omissions[1].blocker.y, -7, "reserved wall reports exact protected height")
	eq(protected_omissions[1].blocker.node, "mcl_core:chest", "reserved wall reports protected node")
	-- Wall columns can sit on an outside edge above or below the town's
	-- planned ground. Masonry rises from the found surface to a fixed top.
	for _, surface in ipairs({-2, -1, 0, 1, 3}) do
		local terrain_wall = {cells = {{x = 0, z = surface, direction = {x = 1, z = 0}}}, openings = {}}
		local placed, skipped = walls.inspect(terrain_wall, 0, {get = function(_, y, z)
			if z == surface and y <= surface then return y == surface
				and "mcl_core:dirt_with_grass" or "mcl_core:stone" end
			return "air"
		end}, function(name)
			return {walkable = name ~= "air"}
		end, function() return false end)
		eq(#skipped, 0, "wall supported at outside height " .. surface)
		local tops = {}
		for _, change in ipairs(placed) do
			if change.x == 0 and change.z == surface and change.name == walls.BRICK then
				tops[change.y] = true
			end
		end
		eq(tops[4], true, "wall keeps its level top at outside height " .. surface)
	end
	for _, surface in ipairs({4, 5}) do
		local cap_wall = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}}}, openings = {}}
		local placed, skipped = walls.inspect(cap_wall, 0, {get = function(_, y, z)
			if z == 0 and y <= surface then return y == surface
				and "mcl_core:dirt_with_grass" or "mcl_core:stone" end
			return "air"
		end}, function(name) return {walkable = name ~= "air"} end, function() return false end)
		eq(#placed, 0, "terrain at wall cap " .. surface .. " is not overwritten")
		eq(#skipped, 1, "terrain at wall cap " .. surface .. " is reported")
		eq(skipped[1].reason, "water or obstruction", "wall cap obstruction reason " .. surface)
	end
	local raised_opening = {cells = {}, openings = {{x = 0, z = 0,
		direction = {x = 1, z = 0}, material = "road"}}}
	local approach_changes, approach_omissions = walls.inspect(raised_opening, 0,
		{get = function(x, y)
			local surface = x < 2 and 1 or 2
			if y <= surface then return y == surface
				and "mcl_core:dirt_with_grass" or "mcl_core:stone" end
			return "air"
		end}, function(name) return {walkable = name ~= "air"} end, function() return false end)
	eq(#approach_changes, 0, "raised road approaches are left intact")
	eq(#approach_omissions, 4, "raised road approaches are reported locally")
	eq(approach_omissions[1].reason, "approach: raised terrain", "raised approach reason")
	local medieval = dofile("src/medieval_planner.lua")
	local profile = assert(planner.landmark_profile(catalog.snapshot()))
	for turn = 0, 270, 90 do
		local rng = {int = function(a) return a end}
		local town = assert(medieval.plan({x = 0, z = 0}, 1, profile, rng,
			{quadrant = 0, castle_east = true, turn = turn}))
		local actual = walls.plan(town, true)
		local envelope = walls.bounds(actual, 0)
		local margin = dofile("src/outskirts.lua").CONSTANTS.PROTECT_MARGIN
		eq(envelope.min.x >= town.bounds.x1 - margin and envelope.max.x <= town.bounds.x2 + margin
			and envelope.min.z >= town.bounds.z1 - margin and envelope.max.z <= town.bounds.z2 + margin,
			true, "rotation " .. turn .. " wall and approach fit the outskirts protection envelope")
		local kinds = {}
		for _, gap in ipairs(actual.openings) do kinds[gap.kind] = true end
		eq(kinds.principal, true, "rotation " .. turn .. " retains a principal exit")
		eq(kinds.secondary, true, "rotation " .. turn .. " retains secondary exits")
		for _, c in ipairs(actual.cells) do
			for _, r in ipairs(town.boundary.rects) do
				assert(not (c.x >= r.x1 and c.x <= r.x2 and c.z >= r.z1 and c.z <= r.z2),
					"wall must not overlap the town footprint")
			end
		end
	end
end
