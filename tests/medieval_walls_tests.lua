local eq, planner, catalog = ...
do
	local walls = dofile("src/medieval_walls.lua")
	for _, d in ipairs({{x=1,z=0},{x=-1,z=0},{x=0,z=1},{x=0,z=-1},
		{x=1,z=1},{x=1,z=-1},{x=-1,z=1},{x=-1,z=-1}}) do
		local feature = {min={x=0,y=0,z=0},max={x=2,y=9,z=2},direction=d}
		local bounds = walls.feature_clearance_bounds(feature, 0)
		local x = d.x > 0 and 7 or d.x < 0 and -5 or 1
		local z = d.z > 0 and 7 or d.z < 0 and -5 or 1
		eq(x >= bounds.min.x and x <= bounds.max.x and z >= bounds.min.z and z <= bounds.max.z,
			true, "feature apron extends five nodes in its outward direction")
		local found = false
		for _, pos in ipairs(walls.feature_clearance_positions(feature)) do
			if pos.x == x and pos.z == z then found = true end
			eq(pos.x < 0 or pos.x > 2 or pos.z < 0 or pos.z > 2, true, "apron excludes feature footprint")
		end
		eq(found, true, "feature apron includes outward edge and corner quadrant")
	end
	-- Accepted features clear above ground, but preserve the reserved road,
	-- protection snapshot, liquids and their own schematic footprint.
	do
		local f = {min={x=0,y=0,z=0},max={x=2,y=9,z=2},direction={x=0,z=1},
			street_rect={x1=1,x2=1,z1=0,z2=8}}
		walls.reserve_feature_clearance(f, 0, function(p) return p.x==0 and p.z==3 and p.y==1 end)
		local region = {get=function(x,y,z) return y==1 and (x==2 and z==3 and "water" or "dirt") or "air" end}
		local changes = walls.inspect({cells={},openings={},placed_features={f},
			feature_footprints={{x1=0,x2=2,z1=0,z2=2}}},0,region,
			function(name) return {walkable=name=="dirt", liquid=name=="water"} end, function() return false end)
		local seen = {}
		for _, c in ipairs(changes) do seen[c.x..":"..c.y..":"..c.z]=true end
		eq(seen["0:1:4"],true,"feature apron clears obstructions")
		eq(seen["0:1:3"],nil,"pre-urban protection snapshot survives")
		eq(seen["1:1:3"],nil,"gate road is preserved")
		eq(seen["2:1:3"],nil,"liquid is preserved")
		eq(seen["0:0:4"],nil,"ground surface is preserved")
	end
	local metadata_cleared, timers_stopped = {}, 0
	walls.clear_metadata({
		get_meta = function(pos)
			return {from_table = function(_, value) metadata_cleared[pos.x .. ":" .. pos.y .. ":" .. pos.z] = value end}
		end,
		get_node_timer = function() return {stop = function() timers_stopped = timers_stopped + 1 end} end,
	}, {{x=1,y=2,z=3,name="air",clearance=true},
		{x=2,y=2,z=3,name=walls.BRICK,clear_metadata=true}, {x=3,y=2,z=3,name=walls.BRICK}})
	eq(metadata_cleared["1:2:3"] ~= nil, true, "clearing a voxel removes its metadata and inventory")
	eq(metadata_cleared["2:2:3"] ~= nil, true, "overwriting a structure removes its metadata and inventory")
	eq(timers_stopped, 2, "clearing or overwriting a voxel stops its node timer")
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
	eq(wall.openings[1].street_rect ~= nil, true, "road opening retains its street rectangle")
	local gate_entry = {id = "wall_gatehouse", size = {x = 16, y = 15, z = 9}}
	local outward_cases = {
		{direction = {x = 0, z = 1}, rotation = 0, plane = {x = 20, z = 30}},
		{direction = {x = 1, z = 0}, rotation = 90, plane = {x = 30, z = 20}},
		{direction = {x = 0, z = -1}, rotation = 180, plane = {x = 20, z = 30}},
		{direction = {x = -1, z = 0}, rotation = 270, plane = {x = 30, z = 20}},
	}
	local function gate_openings(case, count, kind)
		local out = {}
		for i = 0, count - 1 do
			local c = {x = case.plane.x, z = case.plane.z,
				direction = case.direction, street = 4, kind = kind or "principal",
				material = "road", street_rect = {x1 = 8, z1 = 8, x2 = 23, z2 = 23}}
			if case.direction.x == 0 then c.x = 10 + i else c.z = 10 + i end
			out[#out + 1] = c
		end
		return out
	end
	local function rotated_local(x, z, sx, sz, rotation)
		if rotation == 0 then return x, z
		elseif rotation == 90 then return z, sx - 1 - x
		elseif rotation == 180 then return sx - 1 - x, sz - 1 - z
		else return sz - 1 - z, x end
	end
	for _, case in ipairs(outward_cases) do
		local openings = gate_openings(case, 6)
		local candidate = walls.gatehouse_candidates({openings = openings}, 12, gate_entry)[1]
		-- Candidate APIs expose bounds before M.candidates normalizes min/max.
		candidate.min, candidate.max = candidate.bounds.min, candidate.bounds.max
		local apron = {}
		for _, p in ipairs(walls.feature_clearance_positions(candidate)) do
			apron[p.x .. ":" .. p.z] = true
			eq(p.x < candidate.min.x or p.x > candidate.max.x or p.z < candidate.min.z or p.z > candidate.max.z,
				true, "gate apron does not overlap schematic")
		end
		local dx, dz = case.direction.x, case.direction.z
		local x = dx > 0 and candidate.max.x + 5 or dx < 0 and candidate.min.x - 5 or candidate.min.x
		local z = dz > 0 and candidate.max.z + 5 or dz < 0 and candidate.min.z - 5 or candidate.min.z
		eq(apron[x .. ":" .. z], true, "gate apron extends from outward face")
		eq(candidate ~= nil, true, "gatehouse candidate exists for rotation " .. case.rotation)
		eq(candidate.rotation, case.rotation, "gatehouse faces outward for rotation " .. case.rotation)
		eq(candidate.road_width_inside, 6, "gatehouse preserves six-node inside road")
		eq(candidate.road_width_gate, 4, "gatehouse passage narrows to four nodes")
		eq(#candidate.openings, 6, "gatehouse candidate owns the full six-cell wall opening")
		local passage_low, passage_high
		for local_x = 6, 9 do
			local rx, rz = rotated_local(local_x, 3, gate_entry.size.x, gate_entry.size.z, case.rotation)
			local x, z = candidate.pos.x + rx, candidate.pos.z + rz
			local transverse = case.direction.x == 0 and x or z
			local normal = case.direction.x ~= 0 and x or z
			passage_low = math.min(passage_low or transverse, transverse)
			passage_high = math.max(passage_high or transverse, transverse)
			eq(normal, case.direction.x ~= 0 and case.plane.x or case.plane.z,
				"passage lies on the wall plane for rotation " .. case.rotation)
		end
		eq(passage_low, 11, "passage begins centered within six-node road for rotation " .. case.rotation)
		eq(passage_high, 14, "passage ends centered within six-node road for rotation " .. case.rotation)
		eq(candidate.bounds.min.y, 12, "gatehouse bounds include foundation datum")
		eq(candidate.bounds.max.y, 26, "gatehouse bounds include full roof height")
	end
	eq(#walls.gatehouse_candidates({openings = gate_openings(outward_cases[1], 5)}, 12, gate_entry),
		0, "partial primary crossing stays a safe road gap")
	eq(#walls.gatehouse_candidates({openings = gate_openings(outward_cases[1], 6, "secondary")}, 12, gate_entry),
		0, "secondary crossing stays reserved for posterns")
	local disjoint = gate_openings(outward_cases[1], 6)
	for _, c in ipairs(gate_openings(outward_cases[1], 6)) do
		c.x = c.x + 10
		disjoint[#disjoint + 1] = c
	end
	local disjoint_candidates = walls.gatehouse_candidates({openings = disjoint}, 12, gate_entry)
	eq(#disjoint_candidates, 2, "disjoint six-node crossings on one wall plane form separate gates")
	eq(#disjoint_candidates[1].openings, 6, "first disjoint gate claims only its own crossing")
	eq(#disjoint_candidates[2].openings, 6, "second disjoint gate claims only its own crossing")
	local postern_entry = {id = "wall_postern", size = {x = 3, y = 8, z = 10}, ground_offset = 1}
	local postern_cases = {
		{direction = {x = 1, z = 0}, rotation = 0, plane = {x = 20, z = 30}},
		{direction = {x = 0, z = 1}, rotation = 270, plane = {x = 30, z = 20}},
		{direction = {x = -1, z = 0}, rotation = 180, plane = {x = 20, z = 30}},
		{direction = {x = 0, z = -1}, rotation = 90, plane = {x = 30, z = 20}},
	}
	for _, case in ipairs(postern_cases) do
		local openings = {}
		for i = 0, 3 do
			openings[#openings + 1] = {x = case.plane.x, z = case.plane.z,
				direction = case.direction, street = 8, kind = "secondary", material = "road",
				street_rect = {x1 = 10, z1 = 10, x2 = 30, z2 = 30}}
			if case.direction.x ~= 0 then openings[#openings].z = 10 + i
			else openings[#openings].x = 10 + i end
		end
		local candidates = walls.postern_candidates({openings = openings}, 12, postern_entry)
		eq(#candidates, 1, "four-wide external secondary crossing yields one postern")
		local postern = candidates[1]
		eq(postern.rotation, case.rotation, "postern rotates along the crossing axis")
		eq(postern.road_width_inside, 4, "postern keeps four-wide road inside")
		eq(postern.road_width_gate, 2, "postern narrows the gate to two")
		eq(postern.road_width_outside, 2, "postern keeps two-wide road outside")
		eq(postern.min.y, 11, "postern honors its captured foundation datum")
		eq(#postern.door_cells, 2, "postern keeps both authored door leaves")
		eq(#postern.outside_approach, 2, "postern extends only its two door columns outside")
		local transverse = {}
		for _, cell in ipairs(postern.door_cells) do
			transverse[#transverse + 1] = case.direction.x ~= 0 and cell.z or cell.x
			eq(case.direction.x ~= 0 and cell.x or cell.z,
				case.direction.x ~= 0 and case.plane.x or case.plane.z,
				"postern doors align with the wall plane")
		end
		table.sort(transverse)
		eq(transverse[1], 11, "postern door pair begins at the crossing center")
		eq(transverse[2], 12, "postern door pair ends at the crossing center")
		local facings = {
			[0] = {x = -1, z = 0}, [90] = {x = 0, z = 1},
			[180] = {x = 1, z = 0}, [270] = {x = 0, z = -1},
		}
		local facing = facings[postern.rotation]
		eq(facing.x * case.direction.x + facing.z * case.direction.z, -1,
			"authored door faces toward town after rotation")
		for _, approach in ipairs(postern.outside_approach) do
			eq((approach.x - postern.door_cells[1].x) * case.direction.x
				+ (approach.z - postern.door_cells[1].z) * case.direction.z, 2,
				"postern outside approach starts beyond its outer face")
		end
		local paved = walls.inspect({cells = {}, openings = postern.outside_approach}, 12,
			{get = function(_, y) return y <= 12 and "mcl_core:stone" or "air" end},
			function(name) return {walkable = name == "mcl_core:stone"} end, function() return false end)
		eq(#paved, 8, "postern paves four outside nodes on each of two road columns")
	end
	eq(#walls.postern_candidates({openings = gate_openings(postern_cases[1], 4, "principal")}, 12, postern_entry),
		0, "principal crossings stay reserved for gatehouses")
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
	eq(#obstructed_water_omissions, 0, "a solid node can support a water-crossing wall")
	local above_structure = false
	for _, change in ipairs(obstructed_water) do
		if change.y == -10 and change.name == walls.BRICK then above_structure = true end
	end
	eq(above_structure, true, "water-crossing wall starts above its solid support")
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
		["test:lava_source"] = {walkable = false, liquidtype = "source"},
		["test:icy_plant"] = {walkable = true, groups = {plant = 1, ice = 1}},
		-- VoxeLibre shape: a "source" whose flowing alternative is itself (not liquid).
		["test:sweet_berry_bush"] = {walkable = false, liquidtype = "source",
			liquid_alternative_flowing = "test:sweet_berry_bush", liquid_range = 0, groups = {plant = 1}},
		["test:real_water_source"] = {walkable = false, liquidtype = "source",
			liquid_alternative_flowing = "test:real_water_flowing"},
		["test:real_water_flowing"] = {walkable = false, liquidtype = "flowing"},
	}
	local function wall_node_info(name)
		if name == "mcl_core:stone" then return {walkable = true} end
		return placement.node_info(wall_nodes, name)
	end
	eq(wall_node_info("test:sweet_berry_bush").liquid, false, "self-referencing VoxeLibre bush is not liquid")
	eq(wall_node_info("test:sweet_berry_bush").vegetation, true, "sweet berry bush counts as vegetation")
	eq(wall_node_info("test:real_water_source").liquid, true, "real water source with a flowing alternative is liquid")
	eq(wall_node_info("test:lava_source").liquid, true, "lava source without a flowing alternative is still liquid")
	local vegetated_wall = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}}}, openings = {}}
	local clearance_wall = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}}}, openings = {}}
	local clearance_changes = walls.inspect(clearance_wall, 0, {get = function(x, y)
		if x == 0 and y == 0 then return "mcl_core:stone" end
		if x == 3 and y == 0 then return "mcl_chests:chest" end
		if x == 3 and y == 1 then return "mcl_chests:chest" end
		if x == 3 and y == 8 then return "mcl_chests:chest" end
		if x == 4 and y == 1 then return "mcl_core:dirt" end
		if x == 3 and y == -1 then return "mcl_core:stone" end
		if x == 5 and y == 10 then return "mcl_core:tree" end
		return "air"
	end}, wall_node_info, function() return false end)
	local cleared_roof, cleared_tree, cleared_raised_terrain = false, false, false
	local preserved_subsurface, preserved_ground_level, cleared_first_clearance_level = true, true, false
	for _, change in ipairs(clearance_changes) do
		if change.x == 3 and change.y == 8 and change.name == "air" then cleared_roof = true end
		if change.x == 5 and change.y == 10 and change.name == "air" then cleared_tree = true end
		if change.x == 4 and change.y == 1 and change.name == "air" then cleared_raised_terrain = true end
		if change.x == 3 and change.y == -1 and change.name == "air" then preserved_subsurface = false end
		if change.x == 3 and change.y == 0 and change.name == "air" then preserved_ground_level = false end
		if change.x == 3 and change.y == 1 and change.name == "air" then cleared_first_clearance_level = true end
	end
	eq(cleared_roof, true, "clearance removes buildings five nodes outside the wall")
	eq(cleared_tree, true, "clearance reaches five nodes above the wall top")
	eq(cleared_raised_terrain, true, "raised natural terrain is cleared from the wall core")
	eq(preserved_subsurface, true, "exterior clearance preserves terrain below the wall base")
	eq(preserved_ground_level, true, "exterior clearance preserves town ground")
	eq(cleared_first_clearance_level, true, "exterior clearance starts one node above town ground")
	local safe_clearance = walls.inspect(clearance_wall, 0, {get = function(x, y)
		if x == 0 and y == 0 then return "mcl_core:stone" end
		if x == 2 and y == 7 then return "test:water_source" end
		if x == 3 and y == 7 then return "ignore" end
		if x == 4 and y == 7 then return "mcl_core:sand" end
		return "air"
	end}, function(name)
		if name == "test:water_source" then return {liquid = true} end
		if name == "mcl_core:sand" then return {walkable = true, falling = true} end
		return wall_node_info(name)
	end, function() return false end)
	local kept_water, kept_unloaded, cleared_falling = false, false, false
	for _, change in ipairs(safe_clearance) do
		if change.x == 2 and change.y == 7 and change.name == "air" then kept_water = true end
		if change.x == 3 and change.y == 7 and change.name == "air" then kept_unloaded = true end
		if change.x == 4 and change.y == 7 and change.name == "air" then cleared_falling = true end
	end
	eq(kept_water, false, "clearance preserves liquids")
	eq(kept_unloaded, false, "clearance preserves unloaded ignore cells")
	eq(cleared_falling, true, "clearance removes falling blocks inside its bounded strip")
	local clearance_bounds = walls.bounds(clearance_wall, 0)
	eq(clearance_bounds.max.x, 5, "wall bounds include the five-node outer strip")
	eq(clearance_bounds.max.y, 10, "wall bounds include clearance above the profile")
	local protected_clearance_wall = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}}}, openings = {}}
	walls.reserve(protected_clearance_wall, 0, function(p) return p.x == 3 and (p.y == 0 or p.y == 1 or p.y == 8) end)
	eq(protected_clearance_wall.cells[1].clearance_protected["3:0:0"], nil,
		"clearance does not reserve town-ground nodes for removal")
	eq(protected_clearance_wall.cells[1].clearance_protected["3:1:0"] ~= nil, true,
		"clearance reserves from one node above town ground")
	local protected_clearance_changes = walls.inspect(protected_clearance_wall, 0, {get = function(x, y)
		if x == 0 and y == 0 then return "mcl_core:stone" end
		if x == 3 and y == 8 then return "mcl_chests:chest" end
		return "air"
	end}, wall_node_info, function() return false end)
	local preserved_protected = true
	for _, change in ipairs(protected_clearance_changes) do
		if change.x == 3 and change.y == 8 then preserved_protected = false end
	end
	eq(preserved_protected, true, "reserved protected nodes remain untouched in the clearance")
	local feature_clearance = {cells = clearance_wall.cells, openings = {},
		feature_footprints = {{x1 = 3, z1 = 0, x2 = 3, z2 = 0}}}
	local feature_changes = walls.inspect(feature_clearance, 0, {get = function(x, y)
		if x == 0 and y == 0 then return "mcl_core:stone" end
		if x == 3 and y == 8 then return "mcl_chests:chest" end
		return "air"
	end}, wall_node_info, function() return false end)
	local feature_preserved = true
	for _, change in ipairs(feature_changes) do
		if change.x == 3 and change.y == 8 then feature_preserved = false end
	end
	eq(feature_preserved, true, "clearance preserves selected tower and gate footprints")
	local road_clearance = walls.inspect({cells = {}, openings = {{x = 0, z = 0,
		direction = {x = 1, z = 0}}}}, 0, {get = function() return "mcl_core:tree" end},
		wall_node_info, function() return false end)
	eq(#road_clearance, 0, "road openings stay outside the wall clearance strip")
	for _, blocked_y in ipairs({4, 5}) do
		local placed, skipped = walls.inspect(vegetated_wall, 0, {get = function(x, y)
			if y == 0 then return "mcl_core:stone" end
			if x == 1 and y == blocked_y then return "mcl_chests:chest" end
			return "air"
		end}, wall_node_info, function() return false end)
		local core_count, decoration_count = 0, 0
		for _, change in ipairs(placed) do
			if change.x == 0 then core_count = core_count + 1 else decoration_count = decoration_count + 1 end
		end
		eq(core_count, 4, "roof at overhang height " .. blocked_y .. " leaves wall core intact")
		eq(decoration_count >= 2, true, "clearance removes the overhang obstruction")
		eq(#skipped, 0, "cleared overhang obstruction is not reported")
	end
	local reserved_wall = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}}}, openings = {}}
	walls.reserve(reserved_wall, 0, function(p) return p.x == 1 and p.y == 4 end)
	local reserved_changes, reserved_omissions = walls.inspect(reserved_wall, 0, {get = function(_, y)
		return y == 0 and "mcl_core:stone" or "air"
	end}, wall_node_info, function() return false end)
	local reserved_core_count = 0
	for _, change in ipairs(reserved_changes) do
		if change.x == 0 and change.name == walls.BRICK then reserved_core_count = reserved_core_count + 1 end
	end
	eq(reserved_core_count, 4, "reserved protected overhang does not omit the core")
	eq(reserved_omissions[1].reason, "decoration: protected", "reserved overhang protection is reported")
	eq(reserved_omissions[1].blocker.x, 1, "reserved decoration reports protected x")
	eq(reserved_omissions[1].blocker.y, 4, "reserved decoration reports protected y")
	eq(reserved_omissions[1].blocker.node, "air", "reserved decoration reports the node at protection position")
	local runtime_changes, runtime_omissions = walls.inspect(vegetated_wall, 0, {get = function(_, y)
		return y == 0 and "mcl_core:stone" or "air"
	end}, wall_node_info, function(p) return p.x == 1 and p.y == 5 end)
	local runtime_core_count = 0
	for _, change in ipairs(runtime_changes) do
		if change.x == 0 and change.name == walls.BRICK then runtime_core_count = runtime_core_count + 1 end
	end
	eq(runtime_core_count, 4, "new protection on overhang leaves the core intact")
	eq(runtime_omissions[1].reason, "decoration: protected", "new overhang protection is reported")
	local core_changes, core_omissions = walls.inspect(vegetated_wall, 0, {get = function(x, y)
		if y == 0 then return "mcl_core:stone" end
		if x == 0 and y == 3 then return "mcl_chests:chest" end
		return "air"
	end}, wall_node_info, function() return false end)
	eq(#core_omissions, 0, "core obstruction is cleared before wall placement")
	local core_overwrite = false
	for _, change in ipairs(core_changes) do
		if change.x == 0 and change.y == 3 and change.name == walls.BRICK then core_overwrite = true end
	end
	eq(core_overwrite, true, "wall replaces an obstruction in its core")
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
	local berry_wall = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}}}, openings = {}}
	local berry_changes, berry_omissions = walls.inspect(berry_wall, 0, {get = function(_, y)
		if y == -1 then return "mcl_core:stone" end
		if y == 0 then return "test:berry" end
		return "air"
	end}, function(name)
		if name == "test:berry" then return {walkable = false} end
		return wall_node_info(name)
	end, function() return false end)
	eq(#berry_omissions, 0, "non-walkable berry at ground does not block wall support")
	local berry_removed = false
	for _, change in ipairs(berry_changes) do
		if change.x == 0 and change.y == 0 and change.name == "air" and change.clearance then berry_removed = true end
	end
	eq(berry_removed, true, "wall clears non-walkable core blockers before placement")
	local deep_water_wall = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}}}, openings = {}}
	local deep_water_changes, deep_water_omissions = walls.inspect(deep_water_wall, 0,
		{get = function(x, y)
			if x == 0 and y >= -32 and y <= 0 then return "test:water_source" end
			if x == 3 and y == 5 then return "mcl_chests:chest" end
			return "air"
		end}, function(name)
		if name == "test:water_source" then return {liquid = true} end
		return wall_node_info(name)
	end, function() return false end)
	eq(#deep_water_omissions, 1, "unsupported water column is omitted")
	local chest_cleared_for_omitted_column = false
	for _, change in ipairs(deep_water_changes) do
		if change.x == 3 and change.y == 5 and change.clearance then chest_cleared_for_omitted_column = true end
	end
	eq(chest_cleared_for_omitted_column, false, "omitted wall column does not clear its apron")
	local overlap_wall = {cells = {
		{x = 0, z = 0, direction = {x = 0, z = 1}},
		{x = -1, z = 0, direction = {x = 1, z = 0}},
	}, openings = {}}
	local overlap_changes = walls.inspect(overlap_wall, 0, {get = function(x, y)
		if y == 0 and (x == -1 or x == 0) then return "mcl_core:stone" end
		if x == 0 and y == 5 then return "mcl_chests:chest" end
		return "air"
	end}, wall_node_info, function(p) return p.x == 0 and p.z == 0 and p.y == 0 end)
	local protected_apron_cleared = false
	for _, change in ipairs(overlap_changes) do
		if change.x == 0 and change.z == 0 and change.y == 5 and change.name == "air" and change.clearance then
			protected_apron_cleared = true
		end
	end
	eq(protected_apron_cleared, false, "neighbor apron preserves a protected wall-core column")
	for _, blocker_name in ipairs({"ignore", "test:lava_source"}) do
		local blocked_wall = {cells = {{x = 0, z = 0, direction = {x = 1, z = 0}}}, openings = {}}
		local blocked_changes, blocked_omissions = walls.inspect(blocked_wall, 0, {get = function(_, y)
			if y == 0 then return "mcl_core:stone" end
			if y == 4 then return blocker_name end
			return "air"
		end}, wall_node_info, function() return false end)
		local blocker_replaced = false
		for _, change in ipairs(blocked_changes) do
			if change.x == 0 and change.y == 4 and change.name == walls.BRICK then blocker_replaced = true end
		end
		eq(#blocked_omissions, 1, blocker_name .. " at wall cap safely omits the column")
		eq(blocker_replaced, false, blocker_name .. " at wall cap is never overwritten")
	end
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
	local log_approach_changes, log_approach_omissions = walls.inspect(vegetated_approach, 0,
		{get = function(x, y)
			if y == -1 and x == 0 then return "mcl_core:stone" end
			if y == 0 and x == 0 then return "mcl_core:tree" end
			if y == 1 and x == 1 then return "mcl_core:tree" end
			if y == 0 and x ~= 0 then return "mcl_core:stone" end
			return "air"
		end}, wall_node_info, function() return false end)
	local paved_log, cleared_overhead_log = false, false
	for _, change in ipairs(log_approach_changes) do
		if change.x == 0 and change.y == 0 and change.name == "road" then paved_log = true end
		if change.x == 1 and change.y == 1 and change.name == "air" then cleared_overhead_log = true end
	end
	eq(#log_approach_omissions, 0, "tree-group logs do not block an approach")
	eq(paved_log, true, "approach paving replaces a ground-level log")
	eq(cleared_overhead_log, true, "approach clears an overhead log")
	local bush_approach_changes, bush_approach_omissions = walls.inspect(vegetated_approach, 0,
		{get = function(x, y)
			if y == -1 and x == 0 then return "mcl_core:stone" end
			if y == 0 and x ~= 0 then return "mcl_core:stone" end
			if x == 1 and y == 1 then return "test:sweet_berry_bush" end
			return "air"
		end}, wall_node_info, function() return false end)
	local cleared_bush = false
	for _, change in ipairs(bush_approach_changes) do
		if change.x == 1 and change.y == 1 and change.name == "air" then cleared_bush = true end
	end
	eq(#bush_approach_omissions, 0, "sweet berry bush does not block an approach as water")
	eq(cleared_bush, true, "approach clears an overhead sweet berry bush")
	do
		local features = dofile("src/medieval_wall_features.lua")
		local bush_tower = {asset = "wall_tower", min = {x = 0, y = 10, z = 0}, max = {x = 1, y = 13, z = 1}}
		local bush_region = {get = function(x, y, z)
			if y == 9 then return "mcl_core:stone" end
			if x == 0 and y == 10 and z == 0 then return "test:sweet_berry_bush" end
			return "air"
		end}
		local bush_ok, _, bush_clearance = features.inspect(bush_tower, bush_region, wall_node_info,
			function() return false end, function(name) return name == "mcl_core:stone" end)
		eq(bush_ok, true, "wall feature inspection accepts a sweet berry bush in its footprint")
		local bush_feature_cleared = false
		for _, change in ipairs(bush_clearance or {}) do
			if change.x == 0 and change.y == 10 and change.z == 0 and change.name == "air" then
				bush_feature_cleared = true
			end
		end
		eq(bush_feature_cleared, true, "wall feature clears the sweet berry bush")
	end
	for _, structure in ipairs({"mcl_chests:chest", "mcl_core:crafting_table", "test:buildable_structure"}) do
	local structure_changes, structure_omissions = walls.inspect(vegetated_wall, 0,
			{get = function(_, y)
				if y == -1 then return "mcl_core:stone" end
				if y == 2 then return structure end
				return "air"
			end}, wall_node_info, function() return false end)
		local replaced = false
		for _, change in ipairs(structure_changes) do
			if change.x == 0 and change.y == 2 and change.name == walls.BRICK then replaced = true end
		end
		eq(replaced, true, structure .. " is cleared from the wall core")
		eq(#structure_omissions, 0, structure .. " no longer blocks its wall column")
	end
	local log_changes, log_omissions = walls.inspect(vegetated_wall, 0, {get = function(_, y)
		if y == -1 then return "mcl_core:stone" end
		if y == 2 then return "mcl_core:tree" end
		return "air"
	end}, wall_node_info, function() return false end)
	local replaced_log = false
	for _, change in ipairs(log_changes) do
		if change.x == 0 and change.y == 2 and change.name == walls.BRICK then replaced_log = true end
	end
	eq(#log_omissions, 0, "tree-group logs do not leave wall-core gaps")
	eq(replaced_log, true, "wall replaces a log inside its footprint")
	local protected_log_changes, protected_log_omissions = walls.inspect(vegetated_wall, 0,
		{get = function(_, y) return y == -1 and "mcl_core:stone" or y == 2 and "mcl_core:tree" or "air" end},
		wall_node_info, function(p) return p.x == 0 and p.y == 2 end)
	eq(#protected_log_changes, 0, "protected log is preserved")
	eq(protected_log_omissions[1].reason, "protected", "protected log keeps its wall column omitted")
	for _, obstruction in ipairs({"test:liquid_plant", "test:icy_plant", "test:unknown", "test:sweet_berry_bush"}) do
		local unsafe_changes, unsafe_omissions = walls.inspect(vegetated_wall, 0,
			{get = function(_, y)
				if y == 0 then return "mcl_core:stone" end
				return y == 2 and obstruction or "air"
			end}, wall_node_info,
			function() return false end)
		if obstruction == "test:liquid_plant" then
			eq(#unsafe_changes, 0, "liquid is preserved in the wall core")
			eq(#unsafe_omissions, 1, "liquid remains a wall obstruction")
		else
			local cleared = false
			for _, change in ipairs(unsafe_changes) do
				if change.x == 0 and change.y == 2 and change.name == walls.BRICK then cleared = true end
			end
			eq(cleared, true, obstruction .. " is cleared from the wall core")
			eq(#unsafe_omissions, 0, obstruction .. " no longer blocks its wall column")
		end
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
	eq(#blocked, 0, "existing masonry can support a wall")
	local masonry_on_existing = false
	for _, change in ipairs(obstructed) do if change.name == walls.BRICK then masonry_on_existing = true end end
	eq(masonry_on_existing, true, "wall masonry is built above any solid support")
	local buildable_support, buildable_support_omissions = walls.inspect({cells = {{x = 0, z = 0,
		direction = {x = 1, z = 0}}}, openings = {}}, 0, {get = function(_, y)
			if y == 0 then return "test:buildable_structure" end
			return "air"
		end}, wall_node_info, function() return false end)
	eq(#buildable_support_omissions, 0, "walkable buildable_to solid supports wall placement")
	local masonry_above_buildable_solid = false
	for _, change in ipairs(buildable_support) do
		if change.x == 0 and change.z == 0 and change.y == 1 and change.name == walls.BRICK then
			masonry_above_buildable_solid = true
		end
	end
	eq(masonry_above_buildable_solid, true, "walkable buildable_to block can support a wall")
	local tree_support, tree_support_omissions = walls.inspect({cells = {{x = 0, z = 0,
		direction = {x = 1, z = 0}}}, openings = {}}, 0, {get = function(_, y)
		if y == 0 then return "mcl_core:tree" end
		return "air"
	end}, wall_node_info, function() return false end)
	eq(#tree_support_omissions, 0, "walkable log block can support a wall")
	local masonry_above_log = false
	for _, change in ipairs(tree_support) do
		if change.x == 0 and change.y == 1 and change.name == walls.BRICK then masonry_above_log = true end
	end
	eq(masonry_above_log, true, "wall masonry is placed above a walkable log support")
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
	-- Reproduce the reported y=27 town edge with natural granite at y=29.
	-- Rough granite generates as terrain; crafted variants remain blockers.
	local function inspect_surface(surface)
		return walls.inspect({cells = {{x = 0, z = 0, direction = {x = 1, z = 0}}}, openings = {}}, 27,
			{get = function(_, y)
				if y == 29 then return surface end
				return y < 29 and "mcl_core:stone" or "air"
			end}, function(name)
			return {walkable = name ~= "air"}
		end, function() return false end)
	end
	local granite_changes, granite_omissions = inspect_surface("mcl_core:granite")
	eq(#granite_omissions, 0, "natural granite at y=29 supports a wall at town ground y=27")
	local masonry_above_granite = false
	for _, change in ipairs(granite_changes) do
		if change.y == 30 and change.name == walls.BRICK then masonry_above_granite = true end
	end
	eq(masonry_above_granite, true, "wall masonry is placed above the granite surface")
	for _, structure in ipairs({"mcl_core:granite_smooth", "mcl_core:stonebrick"}) do
		local blocked_changes, blocked_omissions = inspect_surface(structure)
		eq(#blocked_omissions, 0, structure .. " in the clearance is removed")
		local cleared = false
		for _, change in ipairs(blocked_changes) do
			if change.y == 29 and change.name == "air" then cleared = true end
		end
		eq(cleared, true, structure .. " is cleared above the wall support")
	end
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
		eq(#skipped, 0, "terrain at wall cap " .. surface .. " is cleared")
		local masonry = false
		for _, change in ipairs(placed) do
			if change.x == 0 and change.z == 0 and change.y == 4 and change.name == walls.BRICK then masonry = true end
		end
		eq(masonry, true, "wall cap is rebuilt after clearing terrain " .. surface)
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
		local margin = math.max(dofile("src/outskirts.lua").CONSTANTS.PROTECT_MARGIN,
			walls.CLEARANCE + 1)
		eq(envelope.min.x >= town.bounds.x1 - margin and envelope.max.x <= town.bounds.x2 + margin
			and envelope.min.z >= town.bounds.z1 - margin and envelope.max.z <= town.bounds.z2 + margin,
			true, "rotation " .. turn .. " clearance fits the town boundary envelope")
		local kinds = {}
		for _, gap in ipairs(actual.openings) do kinds[gap.kind] = true end
		eq(kinds.principal, true, "rotation " .. turn .. " retains a principal exit")
		eq(kinds.secondary, true, "rotation " .. turn .. " retains secondary exits")
		local gates = walls.gatehouse_candidates(actual, 0, gate_entry)
		eq(#gates > 0, true, "rotation " .. turn .. " has an external primary gate candidate")
		for _, gate in ipairs(gates) do
			eq(gate.kind, "principal", "rotation " .. turn .. " gate candidate is a primary road")
			eq(#gate.outside_approach, 4, "outside approach has four columns")
			local approach, omissions = walls.inspect({cells = {}, openings = gate.outside_approach}, 0,
				{get = function(_, y) return y <= 0 and "mcl_core:stone" or "air" end},
				function(name) return {walkable = name == "mcl_core:stone"} end, function() return false end)
			eq(#omissions, 0, "outside approach fits flat natural terrain")
			eq(#approach, 16, "four by four outside road is paved at ground level")
			for _, opening in ipairs(gate.openings) do
				local boundary_x = opening.x - opening.direction.x
				local boundary_z = opening.z - opening.direction.z
				local touches_boundary = false
				for _, r in ipairs(town.boundary.rects) do
					if boundary_x >= r.x1 and boundary_x <= r.x2
							and boundary_z >= r.z1 and boundary_z <= r.z2 then
						touches_boundary = true
					end
				end
				eq(touches_boundary, true, "rotation " .. turn .. " gate opens at external boundary only")
			end
		end
		for _, c in ipairs(actual.cells) do
			for _, r in ipairs(town.boundary.rects) do
				assert(not (c.x >= r.x1 and c.x <= r.x2 and c.z >= r.z1 and c.z <= r.z2),
					"wall must not overlap the town footprint")
			end
		end
	end
	-- Outside gate/postern roads slope to meet the surrounding terrain.
	do
		local function columns()
			local out = {}
			for z = 0, 3 do out[#out + 1] = {x = 0, z = z, direction = {x = 1, z = 0}} end
			return out
		end
		local function info(name)
			if name == "test:water" then return {liquid = true, walkable = false} end
			return {walkable = name ~= "air"}
		end
		local function ramp(height, special, protected)
			local region = {get = function(x, y, z)
				if special and special(x, y, z) then return special(x, y, z) end
				return y <= height(x) and "mcl_core:stone" or "air"
			end}
			local changes, omissions, length = walls.approach(columns(), 0, region, info,
				protected or function() return false end)
			local at = {}
			for _, c in ipairs(changes) do at[c.x .. ":" .. c.y .. ":" .. c.z] = c end
			return changes, omissions, length, at
		end
		local changes, omissions, length = ramp(function() return 0 end)
		eq(#omissions, 0, "flat approach is accepted")
		eq(length, 4, "flat approach keeps the minimum length")
		eq(#changes, 16, "flat approach paves four by four")
		local _, o, len, at = ramp(function(x) return x >= 2 and 1 or 0 end)
		eq(#o, 0, "gentle rise is accepted")
		eq(len, 4, "gentle rise meets terrain at the minimum length")
		eq(at["2:1:0"].name, walls.RAMP_SLAB, "half-node rise starts with a slab")
		eq(at["3:1:0"].name, walls.RAMP_FULL, "full block follows the slab")
		_, o, len, at = ramp(function(x) return x >= 1 and 4 or 0 end)
		eq(#o, 0, "steep rise is accepted")
		eq(at["1:1:0"].name, walls.RAMP_STAIR, "large rise uses stairs")
		eq(at["1:1:0"].param2, 1, "rising stair faces outward")
		eq(at["3:3:0"].name, walls.RAMP_STAIR, "stairs climb one node per column")
		eq(at["1:4:2"].name, "air", "higher terrain is trenched above the road")
		eq(at["4:4:0"].name, walls.RAMP_SLAB, "stairs finish with a half-node slab")
		eq(at["5:4:0"].name, walls.RAMP_FULL, "road meets terrain with a full block")
		eq(len, 6, "ramp ends as soon as it meets terrain")
		_, o, len, at = ramp(function(x) return x >= 1 and -2 or 0 end)
		eq(#o, 0, "descent is accepted")
		eq(at["1:0:0"].name, walls.RAMP_STAIR, "large drop uses stairs")
		eq(at["1:0:0"].param2, 3, "descending stair rises toward town")
		eq(at["1:-1:0"].name, walls.RAMP_FULL, "lower terrain gets a causeway fill")
		eq(at["2:-1:0"].name, walls.RAMP_STAIR, "a descending stair is not followed by a slab a node lower")
		_, o = ramp(function(x) return x >= 1 and 40 or 0 end)
		eq(o[1].reason, "approach: terrain not met within 16 blocks", "unreachable terrain omits the approach")
		_, o = ramp(function() return 0 end, function(x, y)
			if x == 2 and y == 0 then return "test:water" end
		end)
		eq(o[1].reason, "approach: water in approach", "fluids are never replaced")
		_, o = ramp(function() return 0 end, function(x, y)
			if x == 2 and y == 0 then return "test:planks" end
		end)
		eq(o[1].reason, "approach: water or obstruction", "buildings are never replaced")
		eq(o[1].blocker.x, 2, "obstruction diagnostic names the column")
		_, o = ramp(function() return 0 end, nil, function(p) return p.x == 1 and p.y == 0 end)
		eq(o[1].reason, "approach: protected", "protected nodes omit the approach")
		local b = walls.approach_bounds(columns(), 0)
		eq(b.max.x, walls.RAMP_MAX - 1, "approach bounds cover the maximum ramp length")
	end
	-- Direction, width, differing column heights, and the exact length cap.
	do
		local function info(name)
			if name == "test:water" then return {liquid = true, walkable = false} end
			return {walkable = name ~= "air"}
		end
		-- height(d, t): terrain surface at distance d along the road, transverse t.
		local function ramp(dir, width, height)
			local cols = {}
			for t = 0, width - 1 do
				cols[#cols + 1] = {x = 10 * dir.x + t * dir.z, z = 10 * dir.z + t * dir.x, direction = dir}
			end
			local region = {get = function(x, y, z)
				local d = (x - 10 * dir.x) * dir.x + (z - 10 * dir.z) * dir.z
				local t = dir.x ~= 0 and z or x
				return y <= height(d, t) and "mcl_core:stone" or "air"
			end}
			local changes, omissions, length = walls.approach(cols, 0, region, info, function() return false end)
			local at = {}
			for _, c in ipairs(changes) do at[c.x .. ":" .. c.y .. ":" .. c.z] = c end
			return at, omissions, length
		end
		local cases = {
			{{x = -1, z = 0}, 3, 1}, {{x = 0, z = 1}, 0, 2}, {{x = 0, z = -1}, 2, 0}}
		for _, case in ipairs(cases) do
			local dir, up, down = case[1], case[2], case[3]
			local function pos(d, y) return (10 * dir.x + d * dir.x) .. ":" .. y .. ":" .. (10 * dir.z + d * dir.z) end
			local at, o = ramp(dir, 1, function(d) return d >= 1 and 4 or 0 end)
			eq(#o, 0, "rise accepted in direction " .. dir.x .. "," .. dir.z)
			eq(at[pos(1, 1)].name, walls.RAMP_STAIR, "stair offset follows direction")
			eq(at[pos(1, 1)].param2, up, "rising stair param2 in direction " .. dir.x .. "," .. dir.z)
			eq(at[pos(3, 3)].name, walls.RAMP_STAIR, "stair column offset follows direction")
			at, o = ramp(dir, 1, function(d) return d >= 1 and -2 or 0 end)
			eq(#o, 0, "drop accepted in direction " .. dir.x .. "," .. dir.z)
			eq(at[pos(1, 0)].param2, down, "descending stair param2 in direction " .. dir.x .. "," .. dir.z)
			eq(at[pos(1, -1)].name, walls.RAMP_FULL, "causeway fill follows direction")
		end
		-- Width-2 postern road: column 0 sits on a hill, column 1 in a hollow.
		local at, o = ramp({x = 1, z = 0}, 2, function(d, t) return t == 0 and 2 or (d >= 1 and -2 or 0) end)
		eq(#o, 0, "two-wide road with differing terrain is accepted")
		local top = 0
		for k, c in pairs(at) do
			local x, y, z = k:match("(-?%d+):(-?%d+):(-?%d+)")
			if tonumber(z) == 0 and c.name == "air" then top = math.max(top, tonumber(y)) end
		end
		eq(top > 0, true, "higher column is trenched")
		local fill = false
		for k, c in pairs(at) do
			local x, y, z = k:match("(-?%d+):(-?%d+):(-?%d+)")
			if tonumber(z) == 1 and tonumber(y) < 0 and c.name == walls.RAMP_FULL then fill = true end
		end
		eq(fill, true, "lower column gets a causeway")
		-- Exact cap: stairs gain two levels per column, so a wall of H nodes is
		-- first met at column H + 2.
		local wall14 = function(d) return d >= 1 and 14 or 0 end
		local _, o16, length = ramp({x = 1, z = 0}, 1, wall14)
		eq(#o16, 0, "terrain first met at column 16 is accepted")
		eq(length, walls.RAMP_MAX, "ramp meeting terrain at column 16 has length 16")
		local _, o17 = ramp({x = 1, z = 0}, 1, function(d) return d >= 1 and 15 or 0 end)
		eq(#o17, 1, "terrain first met at column 17 is omitted")
	end
	-- Regression: adjacent ramp columns are always walkable. A descending stair
	-- followed by a slab once left a 1.5 node climb when walking back to town.
	do
		local function info(name) return {walkable = name ~= "air"} end
		local dirs = {{{x = 1, z = 0}, 1}, {{x = -1, z = 0}, 3}, {{x = 0, z = 1}, 0}, {{x = 0, z = -1}, 2}}
		local function check(dir, up, height, label)
			local region = {get = function(x, y, z)
				local d = x * dir.x + z * dir.z
				return y <= height(d) and "mcl_core:stone" or "air"
			end}
			local changes, omissions, length = walls.approach({{x = 0, z = 0, direction = dir}}, 0, region, info,
				function() return false end)
			if #omissions > 0 then return end
			local top = {}
			for _, c in ipairs(changes) do
				local d = c.x * dir.x + c.z * dir.z
				if c.name ~= "air" and (not top[d] or c.y > top[d].y) then top[d] = c end
			end
			local prev, worst = 1, 0
			for d = 0, length - 1 do
				local c, inner, outer = top[d]
				if c.name == walls.RAMP_SLAB then inner, outer = c.y + 0.5, c.y + 0.5
				elseif c.name == walls.RAMP_STAIR and c.param2 == up then inner, outer = c.y + 0.5, c.y + 1
				elseif c.name == walls.RAMP_STAIR then inner, outer = c.y + 1, c.y + 0.5
				else inner, outer = c.y + 1, c.y + 1 end
				worst = math.max(worst, math.abs(inner - prev))
				prev = outer
			end
			eq(worst <= 0.5, true, label .. " has only half-node steps between columns")
		end
		local profiles = {
			function(d) return d >= 1 and -3 or 0 end, -- exact failing sequence: stair, stair, slab
			function(d) return d >= 1 and -2 or 0 end,
			function(d) return d >= 1 and 5 or 0 end,
			function(d) return d >= 2 and 1 or 0 end,
			function(d) return d >= 2 and -1 or 0 end,
			function(d) return d < 4 and 2 * d or 12 - d end, -- rise then fall
			function(d) return d < 4 and -d or d - 8 end, -- fall then rise
		}
		local seed = 12345
		for _ = 1, 40 do
			local h, heights = 0, {}
			for d = 0, 20 do
				seed = (seed * 1103515245 + 12345) % 2147483648
				h = math.max(-8, math.min(8, h + math.floor(seed / 65536) % 7 - 3))
				heights[d] = h
			end
			heights[0] = 0
			profiles[#profiles + 1] = function(d) return heights[d] or heights[20] end
		end
		for i, height in ipairs(profiles) do
			for _, dd in ipairs(dirs) do check(dd[1], dd[2], height, "profile " .. i .. " direction " .. dd[1].x .. "," .. dd[1].z) end
		end
	end
end
