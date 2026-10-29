local eq = ...
local features = dofile("src/medieval_wall_features.lua")
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
	wall.openings = {{x = 0, z = 0, direction = {x = t.dx, z = 0}}}
	eq(#features.corner_candidates(wall, 10, entry), 0, "road within footprint excludes tower")
	wall.openings = {}
	table.remove(wall.cells)
	eq(#features.corner_candidates(wall, 10, entry), 0, "missing wall join excludes tower")
end

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
local obstacle
local region = {get = function(x, y, z)
	if obstacle and obstacle.x == x and obstacle.y == y and obstacle.z == z then return obstacle.name end
	return y == 9 and "stone" or "air"
end}
local info = function(name) return {walkable = name == "stone"} end
local clear = function() return false end
local natural = function(name) return name == "stone" end
eq(features.inspect(feature, region, info, clear, natural), true, "clear supported tower passes")
obstacle = {x = 1, y = 11, z = 1, name = "building"}
local blocked, obstruction = features.inspect(feature, region, info, clear, natural)
eq(blocked, nil, "obstruction in schematic air volume blocks tower")
eq(obstruction, "obstruction building at (1,11,1)", "tower obstruction reports the exact blocking position")
obstacle = {x = 1, y = 11, z = 1, name = "tree"}
local tree_info = function(name) return {walkable = name == "stone", tree = name == "tree", vegetation = name == "tree"} end
eq(features.inspect(feature, region, tree_info, clear, natural), nil, "tree-group logs in the tower volume remain intact")
obstacle = {x = 0, y = 9, z = 0, name = "air"}
eq(features.inspect(feature, region, info, clear, natural), nil, "unsupported foundation blocks tower")
local lower = {get = function(_, y) return y == 7 and "stone" or "air" end}
local supported, foundations = features.inspect(feature, lower, info, clear, natural)
eq(supported, true, "tower can be supported below a two-node drop")
eq(#foundations, 8, "every footprint column receives two foundation nodes")
local protected_lower = function(p) return p.y == 8 end
eq(features.inspect(feature, lower, info, protected_lower, natural), nil,
	"protected terrain below the tower prevents foundation writes")
local tall_feature = {min = {x = 0, y = 10, z = 0}, max = {x = 1, y = 13, z = 1}}
local shallow_rise = {get = function(_, y) return y == 9 and "stone" or y == 12 and "dirt" or "air" end}
local natural_info = function(name)
	return {walkable = name == "stone" or name == "dirt"}
end
local natural_ground = function(name) return name == "stone" or name == "dirt" end
eq(features.inspect(tall_feature, shallow_rise, natural_info, clear, natural_ground), true,
	"natural terrain up to two nodes above the tower datum can be graded")
local tall_rise = {get = function(_, y) return y == 9 and "stone" or y == 13 and "dirt" or "air" end}
local high_ok, high_reason = features.inspect(tall_feature, tall_rise, natural_info, clear, natural_ground)
eq(high_ok, nil, "natural terrain above the bounded tower cut still blocks placement")
eq(high_reason, "obstruction dirt at (0,13,0)", "bounded-cut rejection reports the blocking position")
eq(features.inspect(tall_feature, shallow_rise, function(name) return {walkable = name == "stone" or name == "dirt"} end,
	function(p) return p.x == 0 and p.y == 11 and p.z == 0 end, natural_ground), nil,
	"protected natural terrain in the cut area prevents tower placement")
local liquid_rise = {get = function(_, y) return y == 9 and "stone" or y == 11 and "water" or "air" end}
local liquid_info = function(name)
	return {walkable = name == "stone", liquid = name == "water"}
end
local liquid_ok, liquid_reason = features.inspect(tall_feature, liquid_rise, liquid_info, clear, natural_ground)
eq(liquid_ok, nil, "water in the bounded natural cut area still blocks tower placement")
eq(liquid_reason, "obstruction water at (0,11,0)", "water obstruction reports the blocking position")
local crafted_rise = {get = function(_, y) return y == 9 and "stone" or y == 11 and "mcl_core:stonebrick" or "air" end}
local crafted_info = function(name)
	return {walkable = name == "stone" or name == "mcl_core:stonebrick"}
end
local crafted_ok, crafted_reason = features.inspect(tall_feature, crafted_rise, crafted_info, clear, natural_ground)
eq(crafted_ok, nil, "crafted masonry in the bounded cut area still blocks tower placement")
eq(crafted_reason, "obstruction mcl_core:stonebrick at (0,11,0)",
	"crafted-node obstruction reports the blocking position")
local sand = {get = function(_, y) return y == 9 and "sand" or y == 8 and "stone" or "air" end}
local sand_info = function(name) return {walkable = name == "sand" or name == "stone", falling = name == "sand"} end
local sand_natural = function(name) return name == "sand" or name == "stone" end
eq(features.inspect(feature, sand, sand_info, clear, sand_natural), true,
	"a falling surface resting on stable natural ground supports a tower")
local original = {cells = {{x = 0, z = 0}, {x = 2, z = 0}}, openings = {{x = 4, z = 0}}}
eq(#features.remaining_wall(original, {}).cells, 2, "failed towers retain every normal wall column")
local remaining = features.remaining_wall(original, {features.footprint(feature)})
eq(#remaining.cells, 1, "only successfully placed tower footprint suppresses wall columns")
eq(remaining.cells[1].x, 2, "wall outside tower remains")
eq(#original.cells, 2, "feature placement does not mutate original wall plan")
eq(remaining.openings, original.openings, "feature placement preserves road openings")
