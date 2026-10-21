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
	blocks = {{rect = {x1 = 0, z1 = 7, x2 = 1, z2 = 8}, frontage = {1}}},
	frontage = {{block = 1, square = "forum", material = "test:paving",
		rect = {x1 = 0, z1 = 6, x2 = 1, z2 = 6}}},
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
rejected(function(p) p.sites[1] = {} end, "site identities", "non-string site identity")

fails(function() planner.plan({x = 0, z = 0}, 1, {town_type = "unknown"}) end,
	"unknown town type", "planner rejects unknown explicit type")

return true
