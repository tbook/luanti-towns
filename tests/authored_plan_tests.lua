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
	bounds = {x1 = 0, z1 = 0, x2 = 15, z2 = 8},
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

-- Containment is checked against plan.bounds; the envelope is no longer read.
rejected(function(p) p.bounds = {x1 = 0, z1 = 0, x2 = 14, z2 = 8} end,
	"outside bounds", "boundary outside bounds")
rejected(function(p) p.bounds = nil end, "invalid bounds", "missing bounds")
rejected(function(p) p.bounds = {x1 = 0, z1 = 0, x2 = 15, z2 = 8.5} end,
	"invalid bounds", "non-integer bounds")
do
	local p = copy(plan)
	p.envelope = {x1 = 0, z1 = 0, x2 = 1, z2 = 1}
	eq(authored.validate(p), true, "stray envelope is ignored")
end

-- landmark_site: real catalog footprints. The cathedral and castle entrances
-- are off-centre; the approach is the first node past the box on the front.
local function check_site(label, id, rotation, rect, size, entrance, facing, approach)
	local s = authored.landmark_site(label, id, rotation, rect)
	eq(s.name, label, label .. " name")
	eq(s.kind, "landmark", label .. " kind")
	eq(s.id, id, label .. " catalog id")
	eq(s.rotation, rotation, label .. " rotation")
	eq(s.rect, rect, label .. " rect is the given table")
	eq(s.size.x, size[1], label .. " size.x")
	eq(s.size.z, size[2], label .. " size.z")
	eq(s.entrance.x, entrance[1], label .. " entrance.x")
	eq(s.entrance.z, entrance[2], label .. " entrance.z")
	eq(s.facing.x, facing[1], label .. " facing.x")
	eq(s.facing.z, facing[2], label .. " facing.z")
	eq(s.approach.pos.x, approach[1], label .. " approach.x")
	eq(s.approach.pos.z, approach[2], label .. " approach.z")
end
check_site("cathedral_north", "cathedral", 0, {x1 = 100, z1 = 200, x2 = 154, z2 = 258},
	{55, 59}, {135, 208}, {0, -1}, {135, 199})
check_site("cathedral_east", "cathedral", 90, {x1 = 100, z1 = 200, x2 = 158, z2 = 254},
	{59, 55}, {108, 219}, {-1, 0}, {99, 219})
check_site("castle_east", "castle", 270, {x1 = 100, z1 = 200, x2 = 153, z2 = 249},
	{54, 50}, {150, 224}, {1, 0}, {154, 224})
check_site("tower_south", "tower", 180, {x1 = 100, z1 = 200, x2 = 117, z2 = 220},
	{18, 21}, {108, 212}, {0, 1}, {108, 221})
fails(function() authored.landmark_site("ghost", "no_such_building", 0,
	{x1 = 0, z1 = 0, x2 = 1, z2 = 1}) end, "unknown catalog id", "landmark_site rejects unknown id")
fails(function() authored.landmark_site("small", "cathedral", 0,
	{x1 = 0, z1 = 0, x2 = 9, z2 = 9}) end, "does not match the placed size", "landmark_site rejects a wrong-sized rect")

-- derive_frontage on a hand-built plan: a 5-wide square to the south of an
-- E-W street, with blocks on either side. Block "south" (x -2..6) gets one run
-- on its +z edge, only the stretch facing the square; block "north" gets one
-- run on its -z edge facing the street.
local function hand_plan()
	return {
		sites = {forum = {name = "forum", kind = "square", material = "test:paving",
			rect = {x1 = 0, z1 = 0, x2 = 4, z2 = 2}, approach = {pos = {x = 2, z = 1}}}},
		streets = {{kind = "principal", name = "east_road", material = "test:road",
			rect = {x1 = 0, z1 = 3, x2 = 4, z2 = 3}}},
		blocks = {
			{id = 1, name = "south", rect = {x1 = -2, z1 = -4, x2 = 6, z2 = -1}, frontage = {}},
			{id = 2, name = "north", rect = {x1 = 0, z1 = 4, x2 = 4, z2 = 6}, frontage = {}},
		},
		frontage = {},
	}
end
do
	local p = hand_plan()
	eq(authored.derive_frontage(p), true, "derive_frontage accepts a plan with frontage")
	eq(#p.frontage, 2, "two frontage runs derived")
	eq(p.blocks[1].frontage[1], 1, "south block lists its run")
	eq(p.blocks[2].frontage[1], 2, "north block lists its run")
	local sq = p.frontage[1]
	eq(sq.block, 1, "square run belongs to the south block")
	eq(sq.side, "+z", "square run is on the +z edge")
	eq(sq.facing.x, 0, "square run facing x")
	eq(sq.facing.z, 1, "square run facing z")
	eq(sq.rect.x1, 0, "square run starts at the square's first column")
	eq(sq.rect.x2, 4, "square run stops at the square's last column")
	eq(sq.rect.z1, -1, "square run on the block edge z")
	eq(sq.rect.z2, -1, "square run is one node thick")
	eq(sq.length, 5, "square run length")
	eq(sq.square, "forum", "square run names the square")
	eq(sq.street, nil, "square run has no street")
	eq(sq.material, "test:paving", "square run material")
	local st = p.frontage[2]
	eq(st.block, 2, "street run belongs to the north block")
	eq(st.side, "-z", "street run is on the -z edge")
	eq(st.street, 1, "street run names the street by index")
	eq(st.street_name, "east_road", "street run carries the street name")
	eq(st.square, nil, "street run has no square")
	eq(st.length, 5, "street run length")
	eq(st.material, "test:road", "street run material")
	-- The derived plan is a valid authored plan on its own.
	local valid = hand_plan()
	valid.bounds = {x1 = -2, z1 = -4, x2 = 6, z2 = 6}
	valid.boundary = {rects = {valid.bounds}}
	valid.sites.forum.approach = {pos = {x = 2, z = 1}}
	authored.derive_frontage(valid)
	eq(authored.validate(valid), true, "derived frontage validates as an authored plan")
end
do
	local p = hand_plan()
	p.blocks[3] = {id = 3, name = "far", rect = {x1 = 10, z1 = 10, x2 = 11, z2 = 11}, frontage = {}}
	local ok, why = authored.derive_frontage(p)
	eq(ok, nil, "block without frontage rejected by derive_frontage")
	eq(why, "block far has no frontage", "block without frontage reason")
end

-- derive_frontage corner cases. `block` is the one block under test, edges
-- are read off the neighbouring squares and streets.
local function square(name, x1, z1, x2, z2)
	return {name = name, kind = "square", material = "test:" .. name,
		rect = {x1 = x1, z1 = z1, x2 = x2, z2 = z2}, approach = {pos = {x = x1, z = z1}}}
end
local function street(name, x1, z1, x2, z2)
	return {kind = "secondary", name = name, material = "test:" .. name,
		rect = {x1 = x1, z1 = z1, x2 = x2, z2 = z2}}
end
local function one_block(sites, streets, rect)
	local p = {sites = {}, streets = streets or {},
		blocks = {{id = 1, name = "b", rect = rect, frontage = {}}}, frontage = {}}
	for _, s in ipairs(sites) do p.sites[s.name] = s end
	return p
end
local function run_summary(p)
	local out = {}
	for _, f in ipairs(p.frontage) do
		out[#out + 1] = ("%d:%s:%s:%d-%d:%d"):format(f.id, f.side, tostring(f.square or f.street),
			f.rect.x1 + f.rect.z1, f.rect.x2 + f.rect.z2, f.length)
	end
	return table.concat(out, " ")
end

-- Two adjacent squares along one block side: one run each, in coordinate order.
do
	local p = one_block({square("a_sq", 0, 6, 4, 8), square("b_sq", 5, 6, 9, 8)}, {},
		{x1 = 0, z1 = 0, x2 = 9, z2 = 5})
	eq(authored.derive_frontage(p), true, "adjacent squares derive")
	eq(#p.frontage, 2, "adjacent squares make two runs")
	eq(p.frontage[1].square, "a_sq", "first run is the west square")
	eq(p.frontage[1].rect.x1 == 0 and p.frontage[1].rect.x2 == 4 and p.frontage[1].rect.z1 == 5, true,
		"first run covers the west square's columns")
	eq(p.frontage[2].square, "b_sq", "second run is the east square")
	eq(p.frontage[2].rect.x1 == 5 and p.frontage[2].rect.x2 == 9, true, "second run covers the east square's columns")
	eq(p.frontage[1].material .. p.frontage[2].material, "test:a_sqtest:b_sq", "each run takes its own material")
	eq(#p.blocks[1].frontage, 2, "the block lists both runs")
end

-- A square wins over a street where their rectangles overlap.
do
	local p = one_block({square("plaza", 0, 6, 4, 8)}, {street("lane", 0, 6, 9, 6)},
		{x1 = 0, z1 = 0, x2 = 9, z2 = 5})
	eq(authored.derive_frontage(p), true, "overlapping square and street derive")
	eq(run_summary(p), "1:+z:plaza:5-9:5 2:+z:1:10-14:5", "square covers its columns, the street the rest")
	eq(p.frontage[2].material, "test:lane", "the street run keeps the street material")
end

-- Several runs on one side, separated by open ground.
do
	local p = one_block({}, {street("s1", 0, 6, 1, 6), street("s2", 4, 6, 5, 6), street("s3", 8, 6, 9, 6)},
		{x1 = 0, z1 = 0, x2 = 9, z2 = 5})
	eq(authored.derive_frontage(p), true, "several runs derive")
	eq(#p.frontage, 3, "three runs on one side")
	for i, f in ipairs(p.frontage) do
		eq(f.id, i, "run " .. i .. " id")
		eq(f.street, i, "run " .. i .. " street")
		eq(f.length, 2, "run " .. i .. " length")
		eq(f.side, "+z", "run " .. i .. " side")
	end
	eq(p.frontage[2].rect.x1, 4, "second run starts after the gap")
	eq(p.blocks[1].frontage[3], 3, "the block lists the runs in order")
end

-- A one-node gap between two streets splits the frontage into two runs.
do
	local p = one_block({}, {street("long", 0, 6, 4, 6), street("long2", 6, 6, 9, 6)},
		{x1 = 0, z1 = 0, x2 = 9, z2 = 5})
	authored.derive_frontage(p)
	eq(#p.frontage, 2, "a one-node gap splits the frontage")
end

-- Sides other than +/-z: the run is the block's edge column, numbered -x
-- before +x, ascending in z.
do
	local p = one_block({}, {street("west", -1, 2, -1, 6), street("east", 6, 0, 6, 9)},
		{x1 = 0, z1 = 0, x2 = 5, z2 = 9})
	eq(authored.derive_frontage(p), true, "x-side runs derive")
	eq(#p.frontage, 2, "one run per x side")
	local w, e = p.frontage[1], p.frontage[2]
	eq(w.side, "-x", "west run side")
	eq(w.facing.x == -1 and w.facing.z == 0, true, "west run facing")
	eq(w.rect.x1 == 0 and w.rect.x2 == 0 and w.rect.z1 == 2 and w.rect.z2 == 6, true, "west run rect")
	eq(w.length, 5, "west run length")
	eq(e.side, "+x", "east run side")
	eq(e.facing.x == 1 and e.facing.z == 0, true, "east run facing")
	eq(e.rect.x1 == 5 and e.rect.x2 == 5 and e.rect.z1 == 0 and e.rect.z2 == 9, true, "east run rect")
	eq(e.length, 10, "east run length")
end

fails(function() planner.plan({x = 0, z = 0}, 1, {town_type = "unknown"}) end,
	"unknown town type", "planner rejects unknown explicit type")

return true
