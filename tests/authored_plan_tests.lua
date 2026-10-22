-- Town-type dispatch and validation for hand-authored plans (issue #145).
local eq, fails, planner = ...
local function copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = copy(v) end
	return out
end

local plan = {
	town_type = "roman",
	envelope = {x1 = 0, z1 = 0, x2 = 15, z2 = 8},
	boundary = {rects = {{x1 = 0, z1 = 0, x2 = 15, z2 = 8}}},
	sites = {
		forum = {name = "forum", kind = "square", material = "test:paving",
			rect = {x1 = 0, z1 = 0, x2 = 2, z2 = 6},
			approach = {pos = {x = 2, z = 3}}},
		temple = {name = "temple", kind = "landmark", id = "demo_house", rotation = 90,
			rect = {x1 = 5, z1 = 0, x2 = 11, z2 = 8}, entrance = {x = 5, z = 4},
			approach = {pos = {x = 4, z = 4}}},
	},
	streets = {{kind = "principal", material = "test:road",
		rect = {x1 = 3, z1 = 0, x2 = 4, z2 = 6}}},
	blocks = {{id = 1, rect = {x1 = 0, z1 = 7, x2 = 1, z2 = 8}, frontage = {1}}},
	frontage = {{id = 1, block = 1, side = "-z", facing = {x = 0, z = -1},
		square = "forum", material = "test:paving", length = 2,
		rect = {x1 = 0, z1 = 7, x2 = 1, z2 = 7}}},
}

eq(planner.validate(plan), true, "Roman forum and landmark validate without medieval civic sites")

local function rejected(change, reason, label)
	local p = copy(plan)
	change(p)
	local ok, why = planner.validate(p)
	eq(ok, nil, label .. " rejected")
	eq(type(why), "string", label .. " has a useful reason")
	if reason then eq(why:find(reason, 1, true) ~= nil, true, label .. " reason") end
end

rejected(function(p) p.town_type = "atlantean" end, "unknown town type", "unknown type")
rejected(function(p) p.sites.temple.rect.x2 = 12 end, "footprint", "wrong rotated catalog footprint")
rejected(function(p) p.sites.temple.entrance.x = 6 end, "entrance", "wrong landmark entrance")
rejected(function(p) p.sites.forum.material = nil end, "material", "square without material")
rejected(function(p) p.streets[1].rect.x1 = 12; p.streets[1].rect.x2 = 16 end,
	"boundary", "street outside boundary")
rejected(function(p) p.streets[1].rect.z2 = 2 end,
	"disconnected", "disconnected landmark pavement")
rejected(function(p)
	p.streets[#p.streets + 1] = {kind = "secondary", material = "test:road",
		rect = {x1 = 14, z1 = 0, x2 = 15, z2 = 1}}
end, "disconnected", "disconnected extra street")
rejected(function(p)
	p.sites.annex = {name = "annex", kind = "square", material = "test:paving",
		rect = {x1 = 14, z1 = 7, x2 = 15, z2 = 8}, approach = {pos = {x = 14, z = 7}}}
end, "disconnected", "disconnected extra square")
rejected(function(p) p.blocks[1].frontage = {99} end,
	"frontage", "invalid frontage reference")
rejected(function(p) p.frontage[1].square = "missing" end, "reference", "unknown frontage square")
rejected(function(p)
	p.boundary.rects[1].x2 = 11
	p.blocks[2] = {id = 2, rect = {x1 = 14, z1 = 7, x2 = 15, z2 = 8}, frontage = {}}
end, "boundary", "block outside authored boundary")
rejected(function(p)
	p.frontage[1].square = "temple"
	p.frontage[1].material = nil
end, "invalid street or square", "frontage cannot reference a landmark as a square")
rejected(function(p) p.frontage[1].rect = {x1 = 0, z1 = 8, x2 = 1, z2 = 8} end,
	"edge", "run not on its block edge")
rejected(function(p) p.frontage[1].rect = {x1 = 0, z1 = 6, x2 = 1, z2 = 6} end,
	"edge", "run inside the surface rather than on the block")
rejected(function(p) p.frontage[1].side = "+z" end, "side and facing", "side and facing disagree")
rejected(function(p) p.frontage[1].facing = {x = 0, z = 1} end, "side and facing", "wrong facing")
rejected(function(p)
	p.frontage[1].side, p.frontage[1].facing = "-x", {x = -1, z = 0}
	p.frontage[1].rect = {x1 = 0, z1 = 7, x2 = 0, z2 = 8}
	p.frontage[1].length = 2
end, "does not face", "run not facing its surface")
rejected(function(p) p.frontage[1].length = 3 end, "length", "wrong length")
rejected(function(p) p.frontage[1].id = 2 end, "wrong id", "wrong frontage id")
rejected(function(p) p.blocks[1].id = 2 end, "wrong id", "wrong block id")
rejected(function(p) p.frontage[1].material = "test:road" end, "material", "wrong material")
rejected(function(p) p.blocks[1].rect = {x1 = 0, z1 = 6, x2 = 1, z2 = 8} end, "overlaps pavement",
	"block overlapping a square")
rejected(function(p) p.blocks[1].rect = {x1 = 3, z1 = 6, x2 = 4, z2 = 8} end, "overlaps pavement",
	"block overlapping a street")
rejected(function(p)
	p.blocks[1].rect = {x1 = 0, z1 = 7, x2 = 6, z2 = 8}
end, "overlaps landmark", "block overlapping a landmark")
rejected(function(p)
	p.blocks[2] = {id = 2, rect = {x1 = 1, z1 = 7, x2 = 2, z2 = 8}, frontage = {}}
end, "overlaps block", "overlapping blocks")
rejected(function(p) p.frontage[1] = 42 end, "frontage", "non-table frontage reference")
rejected(function(p)
	local f = copy(p.frontage[1])
	f.id, f.length, f.material = 4, 5, "test:road"
	p.frontage[4] = f
	p.blocks[1].frontage[2] = 4
end, "gap-free", "invalid run stored past a hole in the frontage array")
rejected(function(p) p.frontage.x = {} end, "gap-free", "string-keyed frontage entry")
rejected(function(p)
	p.streets[3] = {kind = "secondary", material = "test:road",
		rect = {x1 = 0, z1 = 5, x2 = 1, z2 = 6}}
	p.frontage[1].square, p.frontage[1].street, p.frontage[1].material = nil, 3, "test:road"
end, "gap-free", "frontage run facing a street stored past a hole in the street array")
rejected(function(p)
	p.blocks[3] = {id = 3, rect = {x1 = 14, z1 = 7, x2 = 15, z2 = 8}, frontage = {}}
end, "gap-free", "block stored past a hole in the block array")
rejected(function(p)
	local f = copy(p.frontage[1])
	f.id, f.length, f.rect = 2, 1, {x1 = 0, z1 = 7, x2 = 0, z2 = 7}
	p.frontage[2] = f
	p.blocks[1].frontage[2] = 2
end, "overlaps another run", "run sharing a single node with an existing run")
rejected(function(p)
	p.blocks[2] = {id = 2, rect = {x1 = 14, z1 = 7, x2 = 15, z2 = 8}, frontage = {}}
	p.frontage[1].block = 2
end, "invalid frontage", "block listing a run whose block field disagrees")
rejected(function(p)
	local f = copy(p.frontage[1])
	f.id = 2
	p.frontage[2] = f
	p.blocks[1].frontage[2] = 2
end, "overlaps", "duplicate copy of a run on the same block edge")
rejected(function(p) p.blocks[1].frontage = {1, 1} end, "twice", "duplicate frontage id in a block list")
rejected(function(p) p.boundary = 42 end, "boundary", "malformed boundary container")
rejected(function(p) p.sites[1] = {} end, "site identities", "non-string site identity")

local authored = dofile("src/authored_plan.lua")
eq(authored.validate(plan, {min_block_depth = 2}), true, "block deep enough for the row depth")
local shallow, why = authored.validate(plan, {min_block_depth = 3})
eq(shallow, nil, "block shallower than the row depth rejected")
eq(why:find("shallower", 1, true) ~= nil, true, "shallow block reason")

fails(function() planner.plan({x = 0, z = 0}, 1, {town_type = "unknown"}) end,
	"unknown town type", "planner rejects unknown explicit type")

return true
