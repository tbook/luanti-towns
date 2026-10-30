local eq = ...
local features = dofile("src/medieval_wall_features.lua")
local walls = dofile("src/medieval_walls.lua")
local function check_apron(candidate, dx, dz, label)
 local found = {}
 for _, p in ipairs(walls.feature_clearance_positions(candidate)) do
  found[p.x .. ":" .. p.z] = true
  eq(p.x < candidate.min.x or p.x > candidate.max.x or p.z < candidate.min.z or p.z > candidate.max.z,
   true, label .. " apron does not overlap schematic")
 end
 local x = dx > 0 and candidate.max.x + 5 or dx < 0 and candidate.min.x - 5 or candidate.min.x
 local z = dz > 0 and candidate.max.z + 5 or dz < 0 and candidate.min.z - 5 or candidate.min.z
 eq(found[x .. ":" .. z], true, label .. " apron follows candidate outward direction")
 if dx ~= 0 and dz ~= 0 then
  eq(found[x .. ":" .. candidate.min.z], true, label .. " apron includes X face")
  eq(found[candidate.min.x .. ":" .. z], true, label .. " apron includes Z face")
 end
end
local entry = {size = {x = 8, y = 17, z = 8}}
local cases = {
	{dx = -1, dz = 1, rotation = 0, a = {0, -5}, b = {5, 0}},
	{dx = 1, dz = 1, rotation = 90, a = {-5, 0}, b = {0, -5}},
	{dx = 1, dz = -1, rotation = 180, a = {0, 5}, b = {-5, 0}},
	{dx = -1, dz = -1, rotation = 270, a = {5, 0}, b = {0, 5}},
}
for _, t in ipairs(cases) do
	local corner = {x = 0, z = 0, corner = true, direction = {x = t.dx, z = t.dz}}
	local wall = {corners = {corner}, cells = {corner}, openings = {}}
	for distance = 1, 8 do
		wall.cells[#wall.cells + 1] = {x = math.floor(t.a[1] * distance / 5), z = math.floor(t.a[2] * distance / 5)}
		wall.cells[#wall.cells + 1] = {x = math.floor(t.b[1] * distance / 5), z = math.floor(t.b[2] * distance / 5)}
	end
	local candidates = features.corner_candidates(wall, 10, entry)
	eq(#candidates, 1, "eligible corner yields a candidate")
	eq(candidates[1].rotation, t.rotation, "corner rotation follows wall directions")
	eq(candidates[1].min.y, 10, "corner ground datum")
	check_apron(candidates[1], t.dx, t.dz, "corner")
	wall.openings = {{x = 0, z = 0, direction = {x = t.dx, z = 0}}}
	eq(#features.corner_candidates(wall, 10, entry), 0, "road within footprint excludes tower")
	wall.openings = {}
	table.remove(wall.cells)
	eq(#features.corner_candidates(wall, 10, entry), 0, "missing wall join excludes tower")
end

-- Inline towers use the separate 7x7 straight-run asset. A 40-node run gets
-- one centered tower; a 60-node run gets two with equal spacing.
local inline_entry = {size = {x = 7, y = 17, z = 7}, ground_offset = 1}
local inline = features.inline_candidates({runs = {
	{direction = {x = 1, z = 0}, fixed = 12, first = 0, last = 39},
	{direction = {x = 0, z = -1}, fixed = -4, first = 100, last = 159},
	{direction = {x = -1, z = 0}, fixed = 25, first = 200, last = 218},
}}, 50, inline_entry)
eq(#inline, 3, "inline towers follow the floor(length / 20) - 1 count")
eq(inline[1].asset, "wall_tower_inline", "straight runs use the inline tower asset")
eq(inline[1].min.x, 9, "inline tower centers its wall core on a vertical wall run")
eq(inline[1].min.z, 17, "one inline tower is centered on a 40-node run")
eq(inline[1].rotation, 180, "positive X-facing wall turns the parapet outward")
eq(inline[1].min.y, 49, "inline tower honors captured foundation datum")
eq(inline[2].min.x, 117, "two inline towers are evenly distributed along a 60-node run")
eq(inline[3].min.x, 137, "second inline tower uses the same even interval")
eq(inline[2].min.z, -7, "inline tower centers its core on a horizontal wall run")
eq(inline[2].rotation, 270, "negative Z-facing wall rotates the inline sample")
eq(#features.inline_candidates({runs = {
	{direction = {x = 0, z = 1}, fixed = 0, first = 0, last = 18},
}}, 0, inline_entry), 0, "runs shorter than 20 nodes do not receive inline towers")

-- External four-wide secondary openings reserve a postern before any towers.
do
	local walls = dofile("src/medieval_walls.lua")
	local entry = {id = "wall_postern", size = {x = 3, y = 8, z = 10}, ground_offset = 1}
	local wall = {cells = {{x = 20, z = 4, direction = {x = 1, z = 0}},
		{x = 20, z = 15, direction = {x = 1, z = 0}}}, openings = {}}
	for z = 10, 13 do
		wall.openings[#wall.openings + 1] = {x = 20, z = z, direction = {x = 1, z = 0},
			street = 9, kind = "secondary", material = "road",
			street_rect = {x1 = 12, z1 = 10, x2 = 20, z2 = 13}}
	end
	local candidates = features.candidates(wall, 12, {wall_postern = entry}, walls)
	eq(#candidates, 1, "shared wall feature planning includes the postern")
	eq(candidates[1].asset, "wall_postern", "secondary crossing selects the postern asset")
	eq(candidates[1].reserve_rect.x2 >= 25 and candidates[1].reserve_rect.z1 <= 4
		and candidates[1].reserve_rect.z2 >= 15, true,
		"postern reservation includes its full capture and outside road")
	local selected = features.select(candidates, {}, {}, nil)
	eq(#selected, 1, "eligible postern survives shared footprint selection")
	local remaining = features.remaining_wall({cells = wall.cells, openings = wall.openings},
		{features.footprint(selected[1])})
	eq(#remaining.openings, 0, "placed postern masks the full four-wide wall opening")
end

-- The real inline MTS has its outer parapet/corbel facing canonical -X.
-- Check the candidate rotation for each wall normal and that the captured
-- corbel remains on that outward side after the rotation.
do
	local read_mts = dofile("tests/mts_reader.lua")
	local schematic = read_mts("schematics/templates/wall_tower_inline.mts")
	local directions = {
		{x = 1, z = 0, rotation = 180}, {x = -1, z = 0, rotation = 0},
		{x = 0, z = 1, rotation = 90}, {x = 0, z = -1, rotation = 270},
	}
	local function rotate(x, z, rotation)
		if rotation == 90 then return z, 6 - x end
		if rotation == 180 then return 6 - x, 6 - z end
		if rotation == 270 then return 6 - z, x end
		return x, z
	end
	local outward = {
		[0] = {x = -1, z = 0}, [90] = {x = 0, z = 1},
		[180] = {x = 1, z = 0}, [270] = {x = 0, z = -1},
	}
	local corbel = schematic.at(0, 13, 1)
	eq(corbel, "mcl_stairs:stair_stonebrick", "MTS has a parapet corbel on canonical -X")
	for _, direction in ipairs(directions) do
		local run = {direction = {x = direction.x, z = direction.z},
			fixed = 10, first = 0, last = 39}
		local candidate = features.inline_candidates({runs = {run}}, 20, inline_entry)[1]
		eq(candidate.rotation, direction.rotation, "inline tower rotates its outer parapet toward the wall exterior")
		check_apron(candidate, direction.x, direction.z, "inline")
		eq(outward[candidate.rotation].x, direction.x, "rotated parapet faces wall exterior X")
		eq(outward[candidate.rotation].z, direction.z, "rotated parapet faces wall exterior Z")
		local corbel_x, corbel_z = rotate(0, 1, candidate.rotation)
		local core_x, core_z = rotate(3, 3, candidate.rotation)
		local world_corbel = {x = candidate.min.x + corbel_x, z = candidate.min.z + corbel_z}
		local world_core = {x = candidate.min.x + core_x, z = candidate.min.z + core_z}
		eq(schematic.at(0, 13, 1), corbel, "source MTS corbel occupies canonical -X parapet")
		local outward_dot = (world_corbel.x - world_core.x) * direction.x
			+ (world_corbel.z - world_core.z) * direction.z
		eq(outward_dot > 0, true, "rotated source corbel occupies the actual outward side")
		for _, source_z in ipairs({0, 6}) do
			for dy = 1, 4 do
				local source_y = inline_entry.ground_offset + dy
				eq(schematic.at(3, source_y, source_z), "mcl_core:stonebrick",
					"source MTS has both wall tie-in stubs")
			end
			local tie_x, tie_z = rotate(3, source_z, candidate.rotation)
			local world_x, world_z = candidate.min.x + tie_x, candidate.min.z + tie_z
			if direction.x ~= 0 then
				eq(world_x, run.fixed, "rotated tie-in stays on wall X centerline")
				eq(world_z >= run.first and world_z <= run.last, true,
					"both rotated tie-ins land on the uninterrupted run")
			else
				eq(world_z, run.fixed, "rotated tie-in stays on wall Z centerline")
				eq(world_x >= run.first and world_x <= run.last, true,
					"both rotated tie-ins land on the uninterrupted run")
			end
		end
	end
end

-- A primary road opening removes wall cells and splits the real planned run;
-- inline towers are candidates only on the two continuous flanking sections.
do
	local walls = dofile("src/medieval_walls.lua")
	local catalog = dofile("src/catalog.lua")
	local plan = {town_type = "medieval", seed = 3,
		boundary = {rects = {{x1 = 0, x2 = 19, z1 = 0, z2 = 99}}},
		streets = {{id = "main", kind = "principal", material = "road",
			rect = {x1 = -10, x2 = 0, z1 = 45, z2 = 50}}}}
	local wall = walls.plan(plan, true)
	local flanks = {}
	for _, run in ipairs(wall.runs) do
		if run.direction.x == -1 and run.fixed == -1 then flanks[#flanks + 1] = run end
	end
	eq(#flanks, 2, "road opening splits the west wall into two runs")
	local candidates = features.inline_candidates(wall, 0, catalog.entries.wall_tower_inline)
	local west = {}
	for _, candidate in ipairs(candidates) do
		if candidate.min.x == -4 then west[#west + 1] = candidate end
	end
	eq(#west, 2, "each long uninterrupted flank gets an inline tower")
	for _, candidate in ipairs(west) do
		for _, opening in ipairs(wall.openings) do
			for depth = 0, 3 do
				local x = opening.x + opening.direction.x * depth
				local z = opening.z + opening.direction.z * depth
				eq(x >= candidate.min.x and x <= candidate.max.x
					and z >= candidate.min.z and z <= candidate.max.z, false,
					"inline tower footprint avoids every road opening node")
			end
		end
	end
end

-- In a narrow neck, a tower's footprint reaches the opposite wall run. Reject
-- those candidates so masking a tower never removes unrelated wall columns.
do
	local walls = dofile("src/medieval_walls.lua")
	local plan = {town_type = "medieval", seed = 4,
		boundary = {rects = {{x1 = 0, x2 = 1, z1 = 0, z2 = 99}}}, streets = {}}
	local wall = walls.plan(plan, true)
	eq(#features.inline_candidates(wall, 0, inline_entry), 0,
		"narrow boundary rejects towers whose footprints touch the opposite wall")
end
local inline_plan_candidates = features.candidates({runs = {
	{direction = {x = 1, z = 0}, fixed = 12, first = 0, last = 39},
}, cells = {}, openings = {}, corners = {}}, 50,
	{wall_tower_inline = inline_entry}, {gatehouse_candidates = function() return {} end})
eq(#inline_plan_candidates, 1, "shared planning and placement candidates include inline towers")
eq(#features.select(inline_plan_candidates, {{rect = {x1 = 9, x2 = 15, z1 = 17, z2 = 23}}}, {}), 0,
	"inline tower reservations avoid authored building footprints")

local outskirts = dofile("src/outskirts.lua")
local protected = {x0 = 0, x1 = 10, z0 = 0, z1 = 10, margin = 4,
	features = {{x1 = 15, x2 = 20, z1 = 0, z2 = 5}}}
local fits, reason = outskirts.fits({x1 = 20, x2 = 21, z1 = 3, z2 = 4}, {}, protected)
eq(fits, false, "outskirts plots respect actual wall feature footprint")
eq(reason, "plot_protected", "feature collision reports protected plot")
local adapter = dofile("src/outskirts_terrain.lua")
local seen
local terrain = {volume = function() end, terraform = function(_, _, options)
	seen = options.protected
	return true, {}
end}
local ok = adapter.terraform(terrain, {}, {}, protected, {feature_footprints = protected.features})
eq(ok, true, "terrain adapter accepts feature exclusions")
eq(#seen, 2, "terrain protects both town and feature")
eq(seen[2].x0, 15, "feature terrain exclusion starts at actual footprint")
eq(seen[2].x1, 20, "feature terrain exclusion ends at actual footprint")

local feature = {min = {x = 0, y = 10, z = 0}, max = {x = 1, y = 11, z = 1}}
local chosen = features.select({feature}, {{rect = {x1 = 1, x2 = 3, z1 = 1, z2 = 3}}}, {})
eq(#chosen, 0, "tower footprint cannot overlap a building")
chosen = features.select({feature}, {}, {{rect = {x1 = 1, x2 = 3, z1 = 1, z2 = 3}}})
eq(#chosen, 0, "tower footprint cannot overlap a street")
chosen = features.select({feature, feature}, {}, {}, function() return false end)
eq(#chosen, 1, "overlapping candidates are reserved only once")
chosen = features.select({feature}, {}, {}, function(p) return p.y == 11 and p.x == 1 end)
eq(#chosen, 0, "protection anywhere in full height prevents reservation")
do
	local function reason(structures, streets, protected, list, ignore_limits)
		local _, _, rejected = features.select(list or {feature}, structures, streets, protected, ignore_limits)
		return rejected[1] and rejected[1].reason, rejected
	end
	eq(reason({{rect = {x1 = 1, x2 = 3, z1 = 1, z2 = 3}, kind = "house"}}, {}), "structure:house", "structure reason")
	eq(reason({{rect = {x1 = 1, x2 = 3, z1 = 1, z2 = 3}, name = "castle"}}, {}), "structure:castle", "named structure reason")
	eq(reason({}, {{id = 7, rect = {x1 = 1, x2 = 3, z1 = 1, z2 = 3}}}), "street:7", "street reason")
	local r, rejected = reason({}, {}, nil, {feature, feature})
	eq(r, "feature", "overlapping prior feature reason")
	eq(rejected[1].candidate, feature, "rejection names the candidate")
	eq(reason({}, {}, function(p) return p.y == 11 end), "protected", "protected reason")
	local far = {min = {x = 40000, y = 10, z = 0}, max = {x = 40001, y = 11, z = 1}}
	eq(reason({}, {}, nil, {far}), "limits", "limits reason")
	eq(reason({}, {}, nil, {far}, true), nil, "limits ignored when requested")
end
local obstacle
local region = {get = function(x, y, z)
	if obstacle and obstacle.x == x and obstacle.y == y and obstacle.z == z then return obstacle.name end
	return y == 9 and "stone" or "air"
end}
local info = function(name) return {walkable = name ~= "air"} end
local clear = function() return false end
local natural = function(name) return name == "stone" end
eq(features.inspect(feature, region, info, clear, natural), true, "clear supported tower passes")
local registered_ignore = function(name)
	if name == "ignore" then return {walkable = true} end
	return info(name)
end
eq(features.inspect(feature, {get = function(_, y) return y == 9 and "ignore" or "air" end},
	registered_ignore, clear, natural), nil, "registered walkable ignore remains an unsafe foundation blocker")
eq(features.inspect(feature, {get = function(_, y) return y == 11 and "ignore" or y == 9 and "stone" or "air" end},
	registered_ignore, clear, natural), nil, "registered walkable ignore remains an unsafe structure blocker")
obstacle = {x = 1, y = 11, z = 1, name = "building"}
local staged_ok, _, staged_clearance = features.inspect(feature, region, info, clear, natural)
eq(staged_ok, true, "registered obstruction in schematic air volume is staged for clearing")
local staged_building = false
for _, p in ipairs(staged_clearance) do
	if p.x == 1 and p.y == 11 and p.z == 1 and p.name == "air" then staged_building = true end
end
eq(staged_building, true, "staged clearance includes the blocking building voxel")
obstacle = {x = 1, y = 11, z = 1, name = "tree"}
local tree_info = function(name) return {walkable = name == "stone", tree = name == "tree", vegetation = false} end
eq(features.inspect(feature, region, tree_info, clear, natural), true, "every feature may clear tree-group logs in its authored volume")
local placement = dofile("src/placement.lua")
local tower_log_nodes = {
	stone = {walkable = true},
	["mcl_core:tree"] = {walkable = true, groups = {tree = 1, building_block = 1}},
}
local tower_log_info = function(name) return placement.node_info(tower_log_nodes, name) end
local tower_feature = {asset = "wall_tower", min = feature.min, max = feature.max}
obstacle = {x = 1, y = 11, z = 1, name = "mcl_core:tree"}
eq(tower_log_info("mcl_core:tree").vegetation, false, "game tree-group log is not generic vegetation")
eq(tower_log_info("mcl_core:tree").tree, true, "game tree-group log is recognized as a log")
eq(features.inspect(tower_feature, region, tower_log_info, clear, natural), true,
	"tower clears tree-group logs in its authored volume")
local log_foundation = {get = function(x, y, z)
	if x == 0 and z == 0 and y == 9 then return "mcl_core:tree" end
	return y == 8 and "stone" or "air"
end}
local tower_foundation_ok, tower_foundations = features.inspect(tower_feature, log_foundation,
	tower_log_info, clear, natural)
eq(tower_foundation_ok, true, "tower clears a tree-group log above stable foundation support")
local log_foundation_cleared = false
for _, p in ipairs(tower_foundations) do
	if p.x == 0 and p.y == 9 and p.z == 0 then log_foundation_cleared = true end
end
eq(log_foundation_cleared, true, "tree-group log is included in tower foundation clearing")
eq(features.inspect(tower_feature, log_foundation, tower_log_info, function(p)
	return p.x == 0 and p.y == 9 and p.z == 0
end, natural), nil, "protected tower log remains a blocker")
local gatehouse_feature = {asset = "wall_gatehouse", min = feature.min, max = feature.max}
eq(features.inspect(gatehouse_feature, region, tower_log_info, clear, natural), true,
	"gatehouse may clear tree-group logs in its authored volume")
local dirt_gatehouse = {asset = "wall_gatehouse", min = {x = 0, y = 10, z = 0}, max = {x = 1, y = 13, z = 1}}
local dirt_gate_region = {get = function(_, y) return y == 9 and "stone" or y == 12 and "mcl_core:dirt" or "air" end}
eq(features.inspect(dirt_gatehouse, dirt_gate_region, function(name)
	return {walkable = name == "stone" or name == "mcl_core:dirt"}
end, clear, function(name) return name == "stone" or name == "mcl_core:dirt" end), true,
	"gatehouse keeps its prior shallow natural terrain cut")
local dual_group_info = function(name)
	if name == "mcl_core:tree" then return {walkable = true, tree = true, vegetation = true} end
	return tower_log_info(name)
end
eq(features.inspect(gatehouse_feature, region, dual_group_info, clear, natural), true,
	"registered tree and vegetation nodes stage for gatehouse clearance")
eq(features.inspect(tower_feature, region, dual_group_info, clear, natural), true,
	"tower may clear a node tagged as both tree and vegetation")
local vine_nodes = {
	["stone"] = {walkable = true},
	-- Mineclonia's mcl_core:vine definition uses vinelike_node and deco_block,
	-- with buildable_to=true; it has no plant/vines/leaves group.
	["mcl_core:vine"] = {walkable = false, buildable_to = true,
		groups = {deco_block = 1, vinelike_node = 4}},
	["test:other_vinelike_attachment"] = {walkable = false, buildable_to = true,
		groups = {deco_block = 1, vinelike_node = 4}},
}
local vine_info = function(name) return placement.node_info(vine_nodes, name) end
obstacle = {x = 0, y = 9, z = 0, name = "mcl_core:vine"}
eq(vine_info("mcl_core:vine").vegetation, true,
	"Mineclonia's vine is explicitly recognized as vegetation")
eq(vine_info("test:other_vinelike_attachment").vegetation, false,
	"generic vinelike attachments are not assumed to be vegetation")
local vine_foundation = {get = function(x, y, z)
	if obstacle and obstacle.x == x and obstacle.y == y and obstacle.z == z then return obstacle.name end
	if y == 8 or (y == 9 and (x ~= 0 or z ~= 0)) then return "stone" end
	return "air"
end}
eq(features.inspect(feature, vine_foundation, vine_info, clear, natural), true,
	"a vine in the foundation above stable support is safely replaceable")
eq(features.inspect(feature, vine_foundation, vine_info, function(p)
	return p.x == 0 and p.y == 9 and p.z == 0
end, natural), nil, "protected vine foundation prevents tower placement")
obstacle = {x = 0, y = 9, z = 0, name = "air"}
eq(features.inspect(feature, region, info, clear, natural), nil, "unsupported foundation blocks tower")
local lower = {get = function(_, y) return y == 7 and "stone" or "air" end}
local supported, foundations = features.inspect(feature, lower, info, clear, natural)
eq(supported, true, "tower can be supported below a two-node drop")
eq(#foundations, 8, "every footprint column receives two foundation nodes")
local protected_lower = function(p) return p.y == 8 end
eq(features.inspect(feature, lower, info, protected_lower, natural), nil,
	"protected terrain below the tower prevents foundation writes")
local tall_feature = {asset = "wall_tower", min = {x = 0, y = 10, z = 0}, max = {x = 1, y = 13, z = 1}}
local shallow_rise = {get = function(_, y) return y == 9 and "stone" or y == 13 and "mcl_core:dirt" or "air" end}
local natural_info = function(name)
	return {walkable = name == "stone" or name == "mcl_core:dirt" or name == "mcl_core:dirt_with_grass"}
end
local natural_ground = function(name) return name == "stone" or name == "mcl_core:dirt" end
eq(features.inspect(tall_feature, shallow_rise, natural_info, clear, natural_ground), true,
	"tower can replace dirt at the top of its full authored footprint")
local raised_dirt = {get = function(_, y) return y == 9 and "stone" or y == 12 and "mcl_core:dirt_with_grass" or "air" end}
eq(features.inspect(tall_feature, raised_dirt, natural_info, clear, natural_ground), true,
	"tower can replace grass-covered dirt three nodes above its ground datum")
local natural_surface = {get = function(_, y) return y == 9 and "stone" or y == 10 and "stone" or "air" end}
eq(features.inspect(tall_feature, natural_surface, natural_info, clear, natural_ground), true,
	"tower may replace natural ground at its authored floor row")
eq(features.inspect(tall_feature, shallow_rise, function(name) return {walkable = name == "stone" or name == "dirt"} end,
	function(p) return p.x == 0 and p.y == 13 and p.z == 0 end, natural_ground), nil,
	"protected dirt in the tower footprint prevents placement")
local shallow_stone = {get = function(_, y) return y == 9 and "stone" or y == 12 and "mcl_core:stone" or "air" end}
eq(features.inspect(tall_feature, shallow_stone,
	function(name) return {walkable = name == "stone" or name == "mcl_core:stone"} end,
	clear, function(name) return name == "stone" or name == "mcl_core:stone" end), true,
	"tower retains its prior shallow natural stone cut")
local stone_rise = {get = function(_, y) return y == 9 and "stone" or y == 13 and "mcl_core:stone" or "air" end}
local stone_ok, _, stone_reason = features.inspect(tall_feature, stone_rise,
	function(name) return {walkable = name == "stone" or name == "mcl_core:stone"} end,
	clear, function(name) return name == "stone" or name == "mcl_core:stone" end)
eq(stone_ok, true, "tower stages stone in its footprint for clearance")
eq(stone_reason[1].x, 0, "staged stone clearance records the blocked column")
eq(stone_reason[1].y, 13, "staged stone clearance records the blocked height")
local liquid_rise = {get = function(_, y) return y == 9 and "stone" or y == 11 and "water" or "air" end}
local liquid_info = function(name)
	return {walkable = name == "stone", liquid = name == "water"}
end
local liquid_ok, liquid_reason = features.inspect(tall_feature, liquid_rise, liquid_info, clear, natural_ground)
eq(liquid_ok, nil, "water in the feature footprint still blocks placement")
eq(liquid_reason, "unsafe obstruction water at (0,11,0)", "water obstruction reports the blocking position")
local crafted_rise = {get = function(_, y) return y == 9 and "stone" or y == 11 and "mcl_core:stonebrick" or "air" end}
local crafted_info = function(name)
	return {walkable = name == "stone" or name == "mcl_core:stonebrick"}
end
local crafted_ok, _, crafted_reason = features.inspect(tall_feature, crafted_rise, crafted_info, clear, natural_ground)
eq(crafted_ok, true, "crafted masonry in the tower footprint is staged for clearance")
eq(crafted_reason[1].name, "air", "crafted masonry clearance replaces the occupied node with air")
local sand = {get = function(_, y) return y == 9 and "sand" or y == 8 and "stone" or "air" end}
local sand_info = function(name) return {walkable = name == "sand" or name == "stone", falling = name == "sand"} end
local sand_natural = function(name) return name == "sand" or name == "stone" end
eq(features.inspect(feature, sand, sand_info, clear, sand_natural), true,
	"a falling surface resting on stable natural ground supports a tower")

-- Every authored feature type uses registered solid support, even when the
-- terrain is not in the old natural-material allowlist. Falling sand may be
-- cleared only when its stack reaches a stable solid node.
do
	local feature_types = {"wall_tower", "wall_tower_inline", "wall_gatehouse", "wall_postern"}
	local solids = {"mcl_core:andesite", "mcl_core:stone_with_coal", "mcl_core:stonebrick"}
	local function make_region(nodes)
		return {get = function(_, y) return nodes[y] or "air" end}
	end
	local function has_pos(list, x, y, z)
		for _, p in ipairs(list or {}) do
			if p.x == x and p.y == y and p.z == z then return true end
		end
		return false
	end
	local function node_info(name)
		local falling = name == "mcl_core:sand" or name == "mcl_core:gravel"
		return {walkable = name ~= "air" and name ~= "ignore" and name ~= "water"
			and name ~= "lava" and name ~= "test:plant",
			falling = falling, liquid = name == "water" or name == "lava",
			ice = name == "mcl_core:ice", vegetation = name == "test:plant"}
	end
	local no_material_allowlist = function() return false end
	for _, asset in ipairs(feature_types) do
		local candidate = {asset = asset, min = {x = 0, y = 10, z = 0},
			max = {x = 1, y = 11, z = 1}}
		for _, support in ipairs(solids) do
			local ok = features.inspect(candidate, make_region({[9] = support}), node_info, clear,
				no_material_allowlist)
			eq(ok, true, asset .. " accepts solid support " .. support)
		end
		eq(features.inspect(candidate, make_region({[9] = "mcl_core:ice"}), node_info, clear,
			no_material_allowlist), true, asset .. " accepts walkable Mineclonia ice as support")
		local sand_ok, foundation = features.inspect(candidate,
			make_region({[9] = "mcl_core:sand", [8] = "mcl_core:gravel", [7] = "mcl_core:andesite"}),
			node_info, clear, no_material_allowlist)
		eq(sand_ok, true, asset .. " accepts falling sand and gravel over stable andesite")
		local included_sand, included_gravel = false, false
		for _, p in ipairs(foundation or {}) do
			if p.y == 9 then included_sand = true end
			if p.y == 8 then included_gravel = true end
		end
		eq(included_sand and included_gravel, true,
			asset .. " replaces the complete falling stack beneath its footprint")
		-- Falling stacks over a cavity or plant are filled with brick down to the
		-- first stable support (#337). Previously these were rejected (#327).
		local cavity_ok, cavity_fill = features.inspect(candidate,
			make_region({[9] = "mcl_core:sand", [8] = "air", [7] = "mcl_core:andesite"}),
			node_info, clear, no_material_allowlist)
		eq(cavity_ok, true, asset .. " fills falling sand over an unsupported cavity")
		eq(has_pos(cavity_fill, 0, 8, 0), true, asset .. " fills the cavity beneath falling sand")
		local plant_ok, plant_fill = features.inspect(candidate,
			make_region({[9] = "mcl_core:sand", [8] = "test:plant", [7] = "mcl_core:andesite"}),
			node_info, clear, no_material_allowlist)
		eq(plant_ok, true, asset .. " fills falling sand above a non-solid plant")
		eq(has_pos(plant_fill, 0, 8, 0), true, asset .. " replaces the plant beneath falling sand")
		eq(features.inspect(candidate, make_region({[9] = "mcl_core:sand"}),
			node_info, clear, no_material_allowlist), nil,
			asset .. " rejects falling sand with no stable support in depth")
		-- Water below the ground level (ground_offset) is fill; water at ground level blocks.
		local ground_candidate = {asset = asset, min = {x = 0, y = 10, z = 0},
			max = {x = 1, y = 12, z = 1}, ground_offset = 1}
		local water_ok, water_fill = features.inspect(ground_candidate,
			make_region({[9] = "mcl_core:andesite", [10] = "water"}), node_info, clear, no_material_allowlist)
		eq(water_ok, true, asset .. " accepts water below its ground level")
		eq(has_pos(water_fill, 0, 10, 0), true, asset .. " fills water below its ground level")
		eq(features.inspect(ground_candidate, make_region({[9] = "mcl_core:andesite", [11] = "water"}),
			node_info, clear, no_material_allowlist), nil, asset .. " rejects water at its ground level")
		-- Non-water liquids stay unsafe below ground (volume) and in the foundation layer.
		eq(features.inspect(ground_candidate, make_region({[9] = "mcl_core:andesite", [10] = "lava"}),
			node_info, clear, no_material_allowlist), nil, asset .. " rejects lava below its ground level")
		eq(features.inspect(ground_candidate, make_region({[9] = "lava", [8] = "mcl_core:andesite"}),
			node_info, clear, no_material_allowlist), nil, asset .. " rejects lava in the foundation layer")
		-- Water without a ground offset is still at ground level, so it blocks.
		local flat_candidate = {asset = asset, min = {x = 0, y = 10, z = 0}, max = {x = 1, y = 11, z = 1}}
		eq(features.inspect(flat_candidate, make_region({[9] = "mcl_core:andesite", [10] = "water"}),
			node_info, clear, no_material_allowlist), nil, asset .. " rejects water at min.y without ground_offset")
		-- A column may take water fill below ground, but a non-water obstruction above it still blocks.
		eq(features.inspect(ground_candidate,
			make_region({[9] = "mcl_core:andesite", [10] = "water", [11] = "lava"}),
			node_info, clear, no_material_allowlist), nil,
			asset .. " rejects a water-fill column with lava at ground level")
		for _, protected_y in ipairs({9, 8, 7}) do
			local allowed = features.inspect(candidate,
				make_region({[9] = "mcl_core:sand", [8] = "mcl_core:gravel", [7] = "mcl_core:andesite"}),
				node_info, function(p) return p.x == 0 and p.z == 0 and p.y == protected_y end,
				no_material_allowlist)
			eq(allowed, nil, asset .. " respects protection throughout falling stack/support")
		end
		eq(features.inspect(candidate, make_region({[9] = "mcl_core:andesite"}), node_info,
			function(p) return p.x == 0 and p.y == 9 and p.z == 0 end, no_material_allowlist), nil,
			asset .. " respects protection on a solid foundation")
		eq(features.inspect(candidate, make_region({[9] = "water", [8] = "mcl_core:andesite"}),
			node_info, clear, no_material_allowlist), true,
			asset .. " may fill water above a stable foundation")
		eq(features.inspect(candidate, make_region({[9] = "lava", [8] = "mcl_core:andesite"}),
			node_info, clear, no_material_allowlist), nil,
			asset .. " rejects non-water liquid foundations")
		eq(features.inspect(candidate, make_region({[9] = "ignore"}), node_info, clear,
			no_material_allowlist), nil, asset .. " rejects unloaded foundation nodes")
		eq(features.inspect(candidate, make_region({[-23] = "mcl_core:andesite"}), node_info,
			clear, no_material_allowlist), nil, asset .. " respects the bounded foundation depth")
	end
end
local original = {cells = {{x = 0, z = 0}, {x = 2, z = 0}}, openings = {{x = 4, z = 0}}}
eq(#features.remaining_wall(original, {}).cells, 2, "failed towers retain every normal wall column")
local remaining = features.remaining_wall(original, {features.footprint(feature)})
eq(#remaining.cells, 1, "only successfully placed tower footprint suppresses wall columns")
eq(remaining.cells[1].x, 2, "wall outside tower remains")
eq(#original.cells, 2, "feature placement does not mutate original wall plan")
eq(#remaining.openings, 1, "feature placement preserves road openings outside its footprint")
local gate = {min = {x = 0, y = 10, z = 0}, max = {x = 15, y = 24, z = 8},
	street = "main", material = "road", street_rect = {x1 = 5, x2 = 10, z1 = -10, z2 = 3},
	direction = {x = 0, z = 1}, wall_plane = {x = 5, z = 3}}
eq(#features.select({gate}, {}, {{id = "main", rect = gate.street_rect}}), 1,
	"gate may overlap its own planned street")
eq(#features.select({gate}, {}, {{id = "other", rect = gate.street_rect}}), 0,
	"gate cannot overlap another street")
eq(features.gate_joins(gate, {cells = {{x = -1, z = 3}, {x = 16, z = 3}}}), true,
	"gate joins both adjacent wall ends")
eq(features.gate_joins(gate, {cells = {{x = -1, z = 3}}}), false,
	"gate requires both wall joins")
local gate_region = {get = function(x, y, z)
	if y == 9 then return "stone" end
	if y == 10 and x == 5 and z == 2 then return "road" end
	return "air"
end}
eq(features.inspect(gate, gate_region, info, clear, natural), true,
	"gate can replace its own paved street surface")
local blocked_gate = {get = function(x, y, z)
	if y == 9 then return "stone" end
	if y == 10 and x == 5 and z == 2 then return "building" end
	return "air"
end}
eq(features.inspect(gate, blocked_gate, info, clear, natural), true,
	"gate may clear a building occupying its planned passage")
local gap = {cells = {}, openings = {{x = 7, z = 3}, {x = 30, z = 3}}}
eq(#features.remaining_wall(gap, {features.footprint(gate)}).openings, 1,
	"placed gate suppresses approaches only inside its footprint")
eq(#features.remaining_wall(gap, {}).openings, 2, "omitted gate retains original approaches")

-- A full town must reserve the same footprints that placement will select,
-- before all categories of building and open-space objects are populated.
do
 local planner = dofile("src/planner.lua")
 local catalog = dofile("src/catalog.lua")
 local walls = dofile("src/medieval_walls.lua")
 local profile = assert(planner.landmark_profile(catalog.snapshot()))
 local function overlap(a, b)
  return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
 end
 for _, center in ipairs({{x = 0, z = 0}, {x = 120, z = -90}}) do
  local plan = assert(planner.plan(center, 2, {landmarks = profile, force_walls = true}))
  local sites = {}
  for _, site in pairs(plan.sites) do sites[#sites + 1] = site end
  local candidates = features.candidates(walls.plan(plan, true), 0, catalog.entries, walls)
  local selected, reserved = features.select(candidates, sites, plan.streets)
  eq(#selected > 0, true, "eligible wall features are reserved")
  local selected_inline = {}
  for _, feature in ipairs(selected) do
   if feature.asset == "wall_tower_inline" then selected_inline[#selected_inline + 1] = feature end
  end
  eq(#selected_inline > 0, true, "real planner reserves eligible inline tower plots before population")
  local occupants = {}
  if plan.reservations.jail then occupants[#occupants + 1] = plan.reservations.jail end
  for _, b in ipairs(plan.reservations.services or {}) do occupants[#occupants + 1] = b end
  for _, b in ipairs(plan.content.buildings or {}) do occupants[#occupants + 1] = b end
  for _, b in ipairs(plan.objects or {}) do occupants[#occupants + 1] = b end
  local clear = true
  for _, b in ipairs(occupants) do for _, r in ipairs(reserved) do
   if overlap(b.reserved_rect or b.rect, r) then clear = false end
  end end
  eq(clear, true, "populated buildings and objects avoid reserved wall features")
  local all_structures = {}
  for _, site in pairs(plan.sites) do all_structures[#all_structures + 1] = site end
  for _, b in ipairs(occupants) do all_structures[#all_structures + 1] = b end
  local actual = features.select(candidates, all_structures, plan.streets, nil, true)
  eq(#actual, #selected, "actual eligible features match the planning reservations")
  local actual_inline = {}
  for _, feature in ipairs(actual) do
   if feature.asset == "wall_tower_inline" then actual_inline[#actual_inline + 1] = feature end
  end
  eq(#actual_inline, #selected_inline, "runtime selection retains prepopulation inline tower reservations")
  for i, candidate in ipairs(selected_inline) do
   eq(actual_inline[i] and actual_inline[i].min.x, candidate.min.x,
    "inline tower runtime reservation x matches prepopulation")
   eq(actual_inline[i] and actual_inline[i].min.z, candidate.min.z,
    "inline tower runtime reservation z matches prepopulation")
  end
  for i, candidate in ipairs(selected) do
   eq(actual[i] and actual[i].min.x, candidate.min.x, "reserved feature x agrees with placement")
   eq(actual[i] and actual[i].min.z, candidate.min.z, "reserved feature z agrees with placement")
  end
 end
	-- Real planner layouts exercise every boundary turn. The postern must
	-- preserve the authored pair's alignment, facing and end joins each time.
	local rotations = {}
	for seed = 1, 4 do
		local plan = assert(planner.plan({x = 0, z = 0}, seed,
			{landmarks = profile, force_walls = true}))
		local wall = walls.plan(plan, true)
		local posts = walls.postern_candidates(wall, 0, catalog.entries.wall_postern)
		local joins = 0
		eq(#posts, 4, "real-planner seed " .. seed .. " finds four secondary crossings")
		for _, postern in ipairs(posts) do
			rotations[postern.rotation] = true
			if features.gate_joins(postern, wall) then joins = joins + 1 end
			local low = math.huge
			for _, opening in ipairs(postern.openings) do
				local transverse = postern.direction.x ~= 0 and opening.z or opening.x
				low = math.min(low, transverse)
			end
			local pair = {}
			for _, door in ipairs(postern.door_cells) do
				pair[#pair + 1] = postern.direction.x ~= 0 and door.z or door.x
			end
			table.sort(pair)
			eq(pair[1], low + 1, "real-planner postern centers its first door, seed " .. seed)
			eq(pair[2], low + 2, "real-planner postern centers its second door, seed " .. seed)
		end
		eq(joins, 3, "real-planner seed " .. seed .. " retains three posterns with both wall joins")
	end
	for _, rotation in ipairs({0, 90, 180, 270}) do
		eq(rotations[rotation], true, "real-planner postern covers wall turn " .. rotation)
	end
end

-- Empty asset availability produces precisely the same population as walls=off.
do
 local planner = dofile("src/planner.lua")
 local catalog = dofile("src/catalog.lua")
 local profile = assert(planner.landmark_profile(catalog.snapshot()))
 local empty = assert(planner.plan({x=0,z=0}, 2, {landmarks=profile, force_walls=true, wall_feature_entries={}}))
 local off = assert(planner.plan({x=0,z=0}, 2, {landmarks=profile, force_walls=false}))
 eq(#empty.content.buildings, #off.content.buildings, "missing assets do not reserve population plots")
 for i, b in ipairs(off.content.buildings) do
  local a = empty.content.buildings[i]
  eq(a and a.rect.x1, b.rect.x1, "missing assets preserve off layout x")
  eq(a and a.rect.z1, b.rect.z1, "missing assets preserve off layout z")
 end
end

do
 local at_limit = {min={x=30999,y=0,z=0}, max={x=31001,y=1,z=1}}
 eq(#features.select({at_limit}, {}, {}, nil, true), 1,
  "planning reserves feature across map limit consistently with origin planning")
 eq(#features.select({at_limit}, {}, {}, nil), 0,
  "placement still rejects feature beyond map limit")
end

do
 -- Cathedral and castle landmarks may be overwritten by wall towers (#320).
 local tower = {asset = "wall_tower", min = {x = 0, y = 10, z = 0}, max = {x = 7, y = 11, z = 7}}
 local gatehouse = {asset = "wall_gatehouse", min = tower.min, max = tower.max}
 local rect = {x1 = 5, x2 = 9, z1 = 5, z2 = 9}
 local plan_cathedral = {name = "cathedral", kind = "landmark", rect = rect}
 local composed_castle = {kind = "castle", rect = rect}
 local office = {kind = "content", role = "office", rect = rect}
 eq(#features.select({tower}, {plan_cathedral}, {}), 1, "tower is accepted over a planned cathedral")
 eq(#features.select({tower}, {composed_castle}, {}), 1, "tower is accepted over a composed castle")
 eq(#features.select({tower}, {plan_cathedral, office}, {}), 0,
  "tower over a cathedral still rejects an overlapping office")
 eq(#features.select({tower}, {office}, {}), 0, "tower is rejected over an office")
 eq(#features.select({gatehouse}, {plan_cathedral}, {}), 0, "gatehouse is still rejected over a cathedral")

 local chosen = features.select({tower}, {plan_cathedral}, {})[1]
 local cathedral_node = {get = function(x, y, z)
  if x == 6 and y == 11 and z == 6 then return "cathedral:wall" end
  return y == 9 and "stone" or "air"
 end}
 -- Unknown nodes are unsafe obstructions; known non-liquid ones are cleared (#328).
 local info = function(name)
  if name == "cathedral:wall" then return nil end
  return {walkable = name == "stone"}
 end
 local clear = function() return false end
 local natural = function(name) return name == "stone" end
 eq(features.inspect(chosen, cathedral_node, info, clear, natural), true,
  "intruding tower overwrites cathedral nodes in its volume")
 -- select records intrudes on the candidate it accepts, so use a fresh table here.
 local blocked = features.select({{asset = "wall_tower", min = tower.min, max = tower.max}}, {}, {})[1]
 eq(features.inspect(blocked, cathedral_node, info, clear, natural), nil,
  "tower without a cathedral intrusion still treats cathedral nodes as obstructions")

 -- A non-walkable cathedral block (door, torch) in the foundation column is
 -- overwritten by an intruding tower but still obstructs a non-intruding one.
 local door_foundation = {get = function(x, y, z)
  if x == 6 and y == 9 and z == 6 then return "cathedral:door" end
  return y == 8 and "stone" or "air"
 end}
 local door_info = function(name) return {walkable = name == "stone"} end
 local ok_foundation, foundations = features.inspect(chosen, door_foundation, door_info, clear, natural)
 eq(ok_foundation, true, "intruding tower fills over a non-walkable cathedral foundation block")
 local filled = false
 for _, p in ipairs(foundations) do
  if p.x == 6 and p.y == 9 and p.z == 6 then filled = true end
 end
 eq(filled, true, "intruded foundation block is filled by the tower")
 local stale = features.overwritten_nodes(chosen, door_foundation, foundations)
 eq(#stale, 1, "overwritten cathedral block is reported for metadata cleanup")
 eq(stale[1] and stale[1].clear_metadata, true, "overwritten block requests metadata cleanup")
 eq(features.inspect(blocked, door_foundation, door_info, clear, natural), nil,
  "same non-walkable block outside an intruded rect still rejects the tower")
end
