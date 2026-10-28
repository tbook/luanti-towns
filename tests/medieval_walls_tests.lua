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
	eq(#omissions, 1, "unsupported column is omitted locally")
	eq(omissions[1].reason, "unsupported drop", "unsupported reason is reported")
	eq(#changes > 0, true, "supported neighbour is still built")
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
