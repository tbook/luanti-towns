-- Roman civic plan: counts, separation, connectivity and invariance (issue #148).
local eq, fails, planner = ...
local roman = dofile("src/roman_planner.lua")
local medieval_profile = assert(planner.landmark_profile(dofile("src/catalog.lua").snapshot()))

local row_depth = planner.row_depth(roman.content_profile())
local function copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = copy(v) end
	return out
end
local function plan_at(x, z, seed)
	local plan, why = planner.plan({x = x, z = z}, seed, {town_type = "roman"})
	assert(plan, why)
	return plan
end
local function overlap(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end
local function landmarks(plan)
	local list = {}
	for _, name in ipairs(plan.site_order) do
		if plan.sites[name].kind == "landmark" then list[#list + 1] = plan.sites[name] end
	end
	return list
end

local plan = plan_at(100, -50, 7)
eq(plan.town_type, "roman", "Roman plan carries its town type")
eq(planner.validate(plan), true, "selected Roman plan passes authored validation")

-- Exact monument census: 16 placements from seven templates.
local list = landmarks(plan)
eq(#list, 16, "16 monument placements")
local counts, names, n = {}, {}, 0
for _, s in ipairs(list) do
	counts[s.id] = (counts[s.id] or 0) + 1
	eq(names[s.name], nil, s.name .. " name is unique")
	names[s.name] = true
	eq(plan.sites[s.name], s, s.name .. " is keyed by its own name")
end
for id, want in pairs({arch = 4, temple = 2, domus = 4, theatre = 1, amphitheater = 1, bath = 1, insula = 3}) do
	eq(counts[id], want, id .. " count")
	n = n + 1
end
eq(n, 7, "seven templates")
eq(#plan.site_order, 17, "forum plus 16 monuments in site order")

-- Arms: the theatre and amphitheater differ, and the bath uses the south arm.
eq(plan.sites.theatre.arm, "west", "theatre on the west arm")
eq(plan.sites.amphitheater.arm, "east", "amphitheater on the east arm, outside the ring")
eq(plan.sites.bath.arm, "south", "bath on the south arm")
for _, name in ipairs({"temple_east", "temple_west"}) do
	eq(plan.sites[name].arm, "north", name .. " beside the cardo")
	local r, f = plan.sites[name].rect, plan.sites.forum.rect
	eq(r.z1 - f.z2 <= 5, true, name .. " is near the forum")
end

-- No overlaps among monuments, forum and streets; all inside the boundary.
local solids = {}
for _, name in ipairs(plan.site_order) do solids[#solids + 1] = plan.sites[name] end
for i = 1, #solids do
	local r = solids[i].rect
	local b = plan.boundary.rects[1]
	eq(r.x1 >= b.x1 and r.z1 >= b.z1 and r.x2 <= b.x2 and r.z2 <= b.z2, true,
		solids[i].name .. " inside the construction boundary")
	for j = i + 1, #solids do
		eq(overlap(r, solids[j].rect), false, solids[i].name .. " / " .. solids[j].name .. " disjoint")
	end
end
-- Streets: four principal arms, then the six ring bands (issues #164, #202).
eq(#plan.streets, 10, "four arms and six ring bands")
local arm_streets, ring_streets = {}, {}
for i, st in ipairs(plan.streets) do
	eq(st.kind, i <= 4 and "principal" or "secondary", st.name .. " kind")
	if i <= 4 then arm_streets[st.arm] = st else ring_streets[st.ring] = st end
end
for _, st in ipairs(plan.streets) do
	for _, s in ipairs(list) do
		eq(overlap(st.rect, s.rect), false, st.name .. " does not enter " .. s.name)
	end
end
-- Streets meet only at designed junctions. Crossings (overlap): the north
-- bands cross the cardo, the north and north_outer bands cross the east and
-- west bands, and the east arm crosses the east band. Abutments (touching, no
-- overlap): the south and south_outer bands end against the east band, and the
-- south and west bands end beside their arms (T-junctions).
local function abuts(a, b)
	if overlap(a, b) then return false end
	local side_x = a.x2 + 1 == b.x1 or b.x2 + 1 == a.x1
	local side_z = a.z2 + 1 == b.z1 or b.z2 + 1 == a.z1
	if side_x then return b.z1 <= a.z2 and a.z1 <= b.z2 end
	if side_z then return b.x1 <= a.x2 and a.x1 <= b.x2 end
	return false
end
local crossings = {
	["cardo_north/ring_north"] = true, ["cardo_north/ring_north_outer"] = true,
	["decumanus_east/ring_east"] = true,
	["ring_north/ring_east"] = true, ["ring_north/ring_west"] = true,
	["ring_north_outer/ring_east"] = true, ["ring_north_outer/ring_west"] = true,
}
local abutments = {
	["ring_south/ring_east"] = true, ["ring_south_outer/ring_east"] = true,
	["cardo_south/ring_south"] = true, ["decumanus_west/ring_west"] = true,
}
for i = 1, #plan.streets do for j = i + 1, #plan.streets do
	local a, b = plan.streets[i], plan.streets[j]
	local name = a.name .. "/" .. b.name
	eq(overlap(a.rect, b.rect), crossings[name] == true, name .. " overlap only at designed crossings")
	eq(abuts(a.rect, b.rect), abutments[name] == true, name .. " abuts only at designed junctions")
end end
local R = {n = ring_streets.north.rect, e = ring_streets.east.rect,
	s = ring_streets.south.rect, w = ring_streets.west.rect}
-- Declared band spans (issue #200): each band's compass extent across its arm.
for _, band in ipairs(roman.layout.bands) do
	local r = ring_streets[band.name].rect
	local x_axis = band.arm == "north" or band.arm == "south"
	local c = x_axis and plan.center.x or plan.center.z
	local lo, hi = x_axis and r.x1 or r.z1, x_axis and r.x2 or r.z2
	eq(lo, band.span[1] + c, band.name .. " band starts at its declared span")
	eq(hi, band.span[2] + c, band.name .. " band ends at its declared span")
end
-- Literal pins (issues #200, #202): the ring at the origin, as x1, z1, x2, z2.
-- The depth is the arm axis: north z 33..38 (from 18..23), north_outer z 66..71
-- (51..56), south z -47..-42 (26..31), south_outer z -80..-75 (59..64), east
-- x 38..43 (23..28), west x -44..-39 (23..28).
do
	local p0 = assert(planner.plan({x = 0, z = 0}, 1, {town_type = "roman"}))
	local pins = {
		north = {-44, 33, 43, 38}, north_outer = {-44, 66, 43, 71},
		south = {3, -47, 37, -42}, south_outer = {6, -80, 37, -75},
		east = {38, -80, 43, 71}, west = {-44, 3, -39, 71},
	}
	for name, want in pairs(pins) do
		local r
		for _, st in ipairs(p0.streets) do if st.ring == name then r = st.rect end end
		assert(r, "ring band " .. name .. " is planned")
		local got = {r.x1, r.z1, r.x2, r.z2}
		for i, k in ipairs({"x1", "z1", "x2", "z2"}) do
			eq(got[i], want[i], "ring " .. name .. " " .. k .. " at the origin")
		end
	end
end
eq(R.n.z2 - R.n.z1 + 1, 6, "ring is one street wide")
-- Bands are one street wide each; the outer north and south bands are too.
eq(ring_streets.north_outer.rect.z2 - ring_streets.north_outer.rect.z1 + 1, 6, "north outer band is one street wide")
eq(ring_streets.south_outer.rect.z2 - ring_streets.south_outer.rect.z1 + 1, 6, "south outer band is one street wide")
-- Crossings: the north and east arms pass through the ring.
for _, arm in ipairs({"north", "east"}) do
	local a, band = arm_streets[arm].rect, ring_streets[arm].rect
	local beyond = arm == "north" and a.z2 > band.z2 or a.x2 > band.x2
	eq(beyond, true, arm .. " arm continues past the ring")
	eq(overlap(a, band), true, arm .. " arm crosses its ring band")
end
-- T-junctions: south and west bands abut their arm's side and do not cross it.
local sa, wa = arm_streets.south.rect, arm_streets.west.rect
eq(R.s.x1, sa.x2 + 1, "south band starts beside the south arm")
eq(R.s.z1 >= sa.z1 and R.s.z2 <= sa.z2, true, "south band meets the south arm")
eq(overlap(R.s, sa), false, "south band does not cross the south arm")
eq(R.w.z1, wa.z2 + 1, "west band starts beside the west arm")
eq(R.w.x1 >= wa.x1 and R.w.x2 <= wa.x2, true, "west band meets the west arm")
eq(overlap(R.w, wa), false, "west band does not cross the west arm")
-- The bath quadrant (south-west) is left out: no ring street, and clearance.
local bath = plan.sites.bath.rect
local cx0, cz0 = plan.center.x, plan.center.z
for name, st in pairs(ring_streets) do
	eq(overlap(st.rect, {x1 = bath.x1 - 3, z1 = bath.z1 - 3, x2 = bath.x2 + 3, z2 = bath.z2 + 3}), false,
		"ring " .. name .. " keeps 3 nodes clear of the bath")
	eq(st.rect.x2 >= cx0 - 3 or st.rect.z2 >= cz0 - 3, true, "ring " .. name .. " is outside the south-west quadrant")
end

-- Domus: domus_2 inside the ring, the others and the amphitheater outside.
local function inside_ring(r)
	return r.x1 > R.w.x2 and r.x2 < R.e.x1 and r.z1 > R.s.z2 and r.z2 < R.n.z1
end
local function outside_ring(r)
	for _, b in pairs(R) do if overlap(r, b) then return false end end
	return not inside_ring(r)
end
eq(inside_ring(plan.sites.domus_2.rect), true, "domus_2 is inside the ring")
for _, name in ipairs({"domus_1", "domus_3", "domus_4", "amphitheater"}) do
	eq(outside_ring(plan.sites[name].rect), true, name .. " is outside the ring")
end
eq(plan.sites.domus_1.ring, "east", "domus_1 flush against the east band")
eq(plan.sites.domus_1.arm, nil, "domus_1 has no arm")
eq(plan.sites.domus_2.arm, "east", "domus_2 on the east arm")
eq(plan.sites.domus_3.arm, "east", "domus_3 on the east arm")
eq(plan.sites.domus_4.arm, "west", "domus_4 on the west arm")
-- The amphitheater stands in the north-east, beyond the ring's east band.
local amph = plan.sites.amphitheater.rect
eq(amph.x1 > R.e.x2 and amph.z1 > cz0, true, "amphitheater is in the north-east outside the ring")
-- Arms are 59 nodes from the forum edge to the arch's near face.
for arm, st in pairs(arm_streets) do
	local r = st.rect
	eq(math.max(r.x2 - r.x1 + 1, r.z2 - r.z1 + 1), 59, arm .. " arm is 59 nodes long")
end

-- Pavement: every approach node is paved and connected to the forum.
local paved = {}
local function pave(r)
	for z = r.z1, r.z2 do for x = r.x1, r.x2 do paved[x .. "," .. z] = true end end
end
pave(plan.sites.forum.rect)
for _, st in ipairs(plan.streets) do pave(st.rect) end
local seen, queue = {}, {{plan.sites.forum.approach.pos.x, plan.sites.forum.approach.pos.z}}
seen[queue[1][1] .. "," .. queue[1][2]] = true
local qi = 1
while qi <= #queue do
	local p = queue[qi]; qi = qi + 1
	for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
		local x, z = p[1] + d[1], p[2] + d[2]
		local k = x .. "," .. z
		if paved[k] and not seen[k] then seen[k] = true; queue[#queue + 1] = {x, z} end
	end
end
for _, s in ipairs(list) do
	local k = s.approach.pos.x .. "," .. s.approach.pos.z
	eq(paved[k], true, s.name .. " approach is paved")
	eq(seen[k], true, s.name .. " approach reaches the forum")
end

-- Each street ends at its arch's near face with the opening on the centreline.
local cx, cz = plan.center.x, plan.center.z
local by_arm = {}
for _, st in ipairs(plan.streets) do if st.arm then by_arm[st.arm] = st end end
for arm, st in pairs(by_arm) do
	local arch = plan.sites[roman.layout.arms[arm].arch]
	local a = arch.approach.pos
	eq(st.rect.x1 <= a.x and a.x <= st.rect.x2 and st.rect.z1 <= a.z and a.z <= st.rect.z2, true,
		arm .. " arch approach lies on its street")
	local step = ({north = {0, 1}, south = {0, -1}, east = {1, 0}, west = {-1, 0}})[arm]
	eq(paved[(a.x + step[1]) .. "," .. (a.z + step[2])], nil, arm .. " street stops at the arch")
	eq(arch.facing.x, -step[1], arm .. " arch faces the forum x")
	eq(arch.facing.z, -step[2], arm .. " arch faces the forum z")
	local lateral = step[1] == 0 and a.x - cx or a.z - cz
	eq(lateral == -1 or lateral == 0, true, arm .. " arch opening sits mid-street")
	local entry = dofile("src/catalog.lua").entries.arch
	eq(arch.size.x * arch.size.z, entry.size.x * entry.size.z, arm .. " arch uses the full catalog box")
end

-- Doors face their streets, including the recessed bath door.
for _, name in ipairs({"bath"}) do
	local s = plan.sites[name]
	local e, a = s.entrance, s.approach.pos
	eq(overlap(s.rect, {x1 = a.x, z1 = a.z, x2 = a.x, z2 = a.z}), false,
		name .. " approach is outside its box")
	eq((a.x - e.x) * s.facing.x + (a.z - e.z) * s.facing.z > 1, true, name .. " door is recessed")
end

-- Temple doors face the forum (-z from the north arm) and their approach is
-- forum pavement; the recessed door still sits inside its box.
for _, name in ipairs({"temple_east", "temple_west"}) do
	local s = plan.sites[name]
	local e, a = s.entrance, s.approach.pos
	local f = plan.sites.forum.rect
	eq(s.rotation, 270, name .. " rotation turns the door to the forum")
	eq(s.facing.x == 0 and s.facing.z == -1, true, name .. " door faces -z, the forum")
	eq(overlap(f, {x1 = a.x, z1 = a.z, x2 = a.x, z2 = a.z}), true, name .. " approach lies on the forum")
	eq(overlap(s.rect, {x1 = a.x, z1 = a.z, x2 = a.x, z2 = a.z}), false,
		name .. " approach is outside its box")
	eq(overlap(s.rect, {x1 = e.x, z1 = e.z, x2 = e.x, z2 = e.z}), true, name .. " entrance is inside its box")
	eq((a.x - e.x) * s.facing.x + (a.z - e.z) * s.facing.z > 1, true, name .. " door is recessed")
end

-- Lanes (issue #172): each principal arm carries a central lane of cobble
-- slabs, two nodes narrower than the street, from the forum edge to the node
-- before its arch. Edge nodes stay blocks, the arch approach stays a block.
for _, arm in ipairs({"north", "south", "east", "west"}) do
	local st = arm_streets[arm]
	local lane = st.lane
	eq(lane ~= nil and lane.material, "mcl_stairs:slab_cobble", arm .. " arm has a cobble slab lane")
	local r = st.rect
	local along = (arm == "north" or arm == "south") and "z" or "x"
	local across = along == "z" and "x" or "z"
	local arch_far = arm == "north" or arm == "east" -- the arch sits at the far end
	local e = {x1 = r.x1, z1 = r.z1, x2 = r.x2, z2 = r.z2}
	e[across .. "1"] = r[across .. "1"] + 1
	e[across .. "2"] = r[across .. "2"] - 1
	if arch_far then e[along .. "2"] = r[along .. "2"] - 1 else e[along .. "1"] = r[along .. "1"] + 1 end
	eq(lane.rect.x1 == e.x1 and lane.rect.z1 == e.z1 and lane.rect.x2 == e.x2 and lane.rect.z2 == e.z2, true,
		arm .. " lane is the central four nodes up to the arch approach")
	eq(overlap(lane.rect, plan.sites.forum.rect), false, arm .. " lane stays off the forum")
	for _, s in ipairs(list) do
		eq(overlap(lane.rect, s.rect), false, arm .. " lane stays off " .. s.name)
	end
	eq(lane.rect[across .. "2"] - lane.rect[across .. "1"] + 1, 4, arm .. " lane is four nodes across")
	local ap = plan.sites[roman.layout.arms[arm].arch].approach.pos
	eq(overlap(lane.rect, {x1 = ap.x, z1 = ap.z, x2 = ap.x, z2 = ap.z}), false, arm .. " arch approach is not laned")
end
for _, st in ipairs(plan.streets) do
	if st.kind == "secondary" then eq(st.lane, nil, st.name .. " (ring) has no lane") end
end
eq(plan.sites.forum.lane, nil, "forum has no lane")
for _, s in ipairs(list) do eq(s.lane, nil, s.name .. " has no lane") end
local medieval_lanes = 0
for _, st in ipairs(planner.plan({x = 0, z = 0}, 1, {landmarks = medieval_profile}).streets) do
	if st.lane then medieval_lanes = medieval_lanes + 1 end
end
eq(medieval_lanes, 0, "medieval streets have no lanes")
local lane_layout = copy(roman.layout)
lane_layout.profiles.lane.width = 6
local no_lane, lane_why = roman.plan({x = 0, z = 0}, 1, lane_layout, row_depth)
eq(no_lane, nil, "a lane as wide as the street is rejected")
eq(lane_why:find("does not fit", 1, true) ~= nil, true, "lane width reason")
lane_layout = copy(roman.layout)
lane_layout.arms.north.profile = "missing"
no_lane, lane_why = roman.plan({x = 0, z = 0}, 1, lane_layout, row_depth)
eq(no_lane, nil, "an unknown street profile is rejected")
eq(lane_why:find("unknown profile", 1, true) ~= nil, true, "unknown profile reason")

-- Blocks and frontage (issue #149).
eq(#plan.blocks > 0 and #plan.frontage > 0, true, "plan has blocks and frontage")
eq(row_depth, 9, "catalog row depth for ordinary templates")
local function in_rect(r, x, z) return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 end
local function owner_rect(f)
	if f.square then return plan.sites[f.square].rect, plan.sites[f.square].material end
	return plan.streets[f.street].rect, plan.streets[f.street].material
end
local arms_faced, ring_faced, forum_runs = {}, {}, 0
for i, b in ipairs(plan.blocks) do
	eq(b.id, i, "block " .. i .. " id is contiguous")
	for _, s in ipairs(list) do
		eq(overlap(b.rect, s.rect), false, b.name .. " avoids " .. s.name)
		local a = s.approach.pos
		eq(in_rect(b.rect, a.x, a.z), false, b.name .. " leaves " .. s.name .. " approach open")
	end
	eq(overlap(b.rect, plan.sites.forum.rect), false, b.name .. " avoids the forum")
	for _, st in ipairs(plan.streets) do eq(overlap(b.rect, st.rect), false, b.name .. " avoids " .. st.name) end
	for j = 1, i - 1 do eq(overlap(b.rect, plan.blocks[j].rect), false, b.name .. " disjoint from block " .. j) end
	for _, fid in ipairs(b.frontage) do eq(plan.frontage[fid].block, i, "frontage " .. fid .. " belongs to " .. b.name) end
end
for i, f in ipairs(plan.frontage) do
	eq(f.id, i, "frontage " .. i .. " id is contiguous")
	local b = plan.blocks[f.block]
	local dx, dz = f.facing.x, f.facing.z
	eq(f.side, ({["0,-1"] = "-z", ["0,1"] = "+z", ["-1,0"] = "-x", ["1,0"] = "+x"})[dx .. "," .. dz],
		"frontage " .. i .. " side matches facing")
	eq((f.rect.x2 - f.rect.x1 + 1) * (f.rect.z2 - f.rect.z1 + 1), f.length, "frontage " .. i .. " length")
	local depth = dx == 0 and b.size.z or b.size.x
	eq(depth >= row_depth, true, "frontage " .. i .. " block is at least one row deep")
	local sr, material = owner_rect(f)
	eq(f.material, material, "frontage " .. i .. " material")
	for z = f.rect.z1, f.rect.z2 do for x = f.rect.x1, f.rect.x2 do
		eq(in_rect(b.rect, x, z), true, "frontage " .. i .. " lies in its block")
		eq(in_rect(sr, x + dx, z + dz), true, "frontage " .. i .. " faces its pavement")
		eq((dx == 0 and (z == (dz < 0 and b.rect.z1 or b.rect.z2)))
			or (dz == 0 and (x == (dx < 0 and b.rect.x1 or b.rect.x2))), true,
			"frontage " .. i .. " is on the block edge")
	end end
	if f.square then
		eq(f.square, "forum", "square frontage names the forum")
		forum_runs = forum_runs + 1
	else
		local st = plan.streets[f.street]
		if st.arm then arms_faced[st.arm] = true else ring_faced[st.ring] = true end
	end
end
for _, arm in ipairs({"south", "east", "west"}) do
	eq(arms_faced[arm], true, arm .. " arm has street frontage")
end
-- Issue #202: the authored block list gives the north arm no block frontage.
eq(arms_faced.north, nil, "north arm has no block frontage")
for _, band in ipairs({"north", "north_outer", "east", "south", "west"}) do
	eq(ring_faced[band], true, band .. " ring band has frontage")
end
-- Ring-relative blocks stand flush against the ring's outer and inner sides.
local ring_blocks = {}
for _, b in ipairs(plan.blocks) do
	if b.ring then
		ring_blocks[#ring_blocks + 1] = b
		local band = ring_streets[b.ring].rect
		local side = b.side
		local flush = (side == "+z" and b.rect.z1 == band.z2 + 1) or (side == "-z" and b.rect.z2 == band.z1 - 1)
			or (side == "+x" and b.rect.x1 == band.x2 + 1) or (side == "-x" and b.rect.x2 == band.x1 - 1)
		eq(flush, true, b.name .. " is flush against the ring")
		local faces = false
		for _, fid in ipairs(b.frontage) do
			if plan.frontage[fid].street_name == "ring_" .. b.ring then faces = true end
		end
		eq(faces, true, b.name .. " has frontage facing the ring")
	end
end
eq(#ring_blocks, 5, "five ring-relative blocks")
local ring_sides = {"-z", "+z", "+z", "-x", "+x"}
for i, want in ipairs(ring_sides) do
	eq(ring_blocks[i] and ring_blocks[i].side, want, "ring block " .. i .. " uses the expected side")
end
eq(forum_runs >= 4, true, "forum edges carry frontage")
local forum_sides = {}
for _, f in ipairs(plan.frontage) do if f.square then forum_sides[f.side] = true end end
eq(forum_sides["-x"] and forum_sides["+x"] and forum_sides["+z"], true,
	"east, west and south forum edges carry frontage")
eq(plan_at(5, 5, 1).blocks[1].rect.x1 - 5, plan.blocks[1].rect.x1 - 100, "blocks translate with the centre")
local none0, why0 = roman.plan({x = 0, z = 0}, 1)
eq(none0, nil, "blocks need a catalog row depth")
eq(why0:find("row depth", 1, true) ~= nil, true, "missing row depth reason")
local shallow = roman.plan({x = 0, z = 0}, 1, nil, row_depth - 1)
-- Depth is the axis perpendicular to the block's side: x for east/west sides,
-- z for north/south sides. blocks[1] is east_forum_north, on a +z side.
local sb = shallow.blocks[1]
local depth = (sb.side == "+x" or sb.side == "-x") and sb.size.x or sb.size.z
eq(sb.side, "+z", "first block is on a +z side")
eq(depth, row_depth - 1, "block depth follows the row depth policy")

-- Same civic arrangement for every seed; a different centre only translates it.
-- Population (issue #150) is seeded and is compared in roman_population_tests.
local function normalise(p, dx, dz)
	local out = copy(p)
	out.seed, out.center = nil, nil
	out.reservations, out.shortages, out.content = nil, nil, nil
	local function shift(t)
		if type(t) ~= "table" then return end
		for _, k in ipairs({"x", "x1", "x2"}) do if t[k] then t[k] = t[k] - dx end end
		for _, k in ipairs({"z", "z1", "z2"}) do if t[k] then t[k] = t[k] - dz end end
		for k, v in pairs(t) do
			if k ~= "size" and k ~= "facing" and k ~= "width" and k ~= "depth" then shift(v) end
		end
	end
	shift(out)
	return out
end
local function same(a, b, path, bad)
	if type(a) ~= "table" or type(b) ~= "table" then
		if a ~= b then bad[#bad + 1] = path end
		return
	end
	for k, v in pairs(a) do same(v, b[k], path .. "." .. tostring(k), bad) end
	for k in pairs(b) do if a[k] == nil then bad[#bad + 1] = path .. "." .. tostring(k) end end
end
local base = normalise(plan, 100, -50)
for _, c in ipairs({{100, -50, 123456}, {100, -50, 1}, {-3000, 777, 42}, {0, 0, 0}}) do
	local other = normalise(plan_at(c[1], c[2], c[3]), c[1], c[2])
	local bad = {}
	same(base, other, "plan", bad)
	eq(#bad, 0, ("civic geometry identical at (%d,%d) seed %d %s"):format(c[1], c[2], c[3], bad[1] or ""))
end
eq(plan_at(0, 0, 9).seed, 9, "seed is recorded")

-- Bad layouts are reported, not built.
local bad_layout = copy(roman.layout)
bad_layout.landmarks[1].rotation = 90
local none, why = roman.plan({x = 0, z = 0}, 1, bad_layout, row_depth)
eq(none, nil, "a door turned away from its street is rejected")
eq(why:find("does not face its street", 1, true) ~= nil, true, "rotation mismatch reason")
bad_layout = copy(roman.layout)
bad_layout.landmarks[1].at = bad_layout.landmarks[4].at
none, why = roman.plan({x = 0, z = 0}, 1, bad_layout, row_depth)
eq(none, nil, "overlapping monuments fail validation")
eq(why:find("overlap", 1, true) ~= nil, true, "overlap reason")
bad_layout = copy(roman.layout)
bad_layout.landmarks[2].name = bad_layout.landmarks[1].name
local detail
none, why, detail = roman.plan({x = 0, z = 0}, 1, bad_layout, row_depth)
eq(none, nil, "duplicate monument names are rejected")
eq(detail and detail.code, "invalid_layout", "duplicate monument name reports invalid_layout")
eq(why:find("duplicate site name", 1, true) ~= nil, true, "duplicate name reason")
-- Ring bands (issue #200): an unknown arm, a missing or malformed span and a
-- duplicate band name are rejected.
local function band_edit(edit)
	local l = copy(roman.layout)
	edit(l.bands)
	return roman.plan({x = 0, z = 0}, 1, l, row_depth)
end
none, why = band_edit(function(b) b[1].arm = "up" end)
eq(none, nil, "a ring band on an unknown arm is rejected")
eq(why:find("unknown arm", 1, true) ~= nil, true, "unknown band arm reason")
none, why = band_edit(function(b) b[2].span = nil end)
eq(none, nil, "a ring band without a span is rejected")
eq(why:find("malformed span", 1, true) ~= nil, true, "missing band span reason")
none, why = band_edit(function(b) b[3].span = {38, -47} end)
eq(none, nil, "a ring band with a reversed span is rejected")
eq(why:find("malformed span", 1, true) ~= nil, true, "reversed band span reason")
none, why = band_edit(function(b) b[4].span = {3} end)
eq(none, nil, "a ring band with a one-element span is rejected")
none, why, detail = band_edit(function(b) b[2].name = b[1].name end)
eq(none, nil, "duplicate ring band names are rejected")
eq(detail and detail.code, "invalid_layout", "duplicate band name reports invalid_layout")
eq(why:find("duplicate band name", 1, true) ~= nil, true, "duplicate band name reason")
none, why = band_edit(function(b) b[1] = 5 end)
eq(none, nil, "a band entry that is not a table is rejected")
eq(why:find("band entries must be tables", 1, true) ~= nil, true, "non-table band reason")
none, why = band_edit(function(b) b[1].from = "18" end)
eq(none, nil, "a non-numeric band from is rejected")
eq(why:find("malformed from..to", 1, true) ~= nil, true, "non-numeric band from reason")
none, why = band_edit(function(b) b[2].to = nil end)
eq(none, nil, "a missing band to is rejected")
eq(why:find("malformed from..to", 1, true) ~= nil, true, "missing band to reason")
none, why = band_edit(function(b) b[1].to = 17 end)
eq(none, nil, "a band with from past to is rejected")
eq(why:find("from past to", 1, true) ~= nil, true, "reversed band from/to reason")
none, why = band_edit(function(b) b[3].from = 22.5 end)
eq(none, nil, "a fractional band from is rejected")
eq(why:find("whole nodes", 1, true) ~= nil, true, "fractional band from/to reason")

-- Input checks are shared with the medieval entry point; medieval stays default.
fails(function() planner.plan({x = 0.5, z = 0}, 1, {town_type = "roman"}) end,
	"site_center", "Roman planning checks the centre")
fails(function() planner.plan({x = 0, z = 0}, 2 ^ 40, {town_type = "roman"}) end,
	"seed", "Roman planning checks the seed")
local medieval = planner.plan({x = 0, z = 0}, 1, {landmarks = medieval_profile})
eq(medieval.town_type, "medieval", "default town type remains medieval")
eq(medieval.sites.cathedral ~= nil, true, "default plan keeps medieval civic sites")

-- Lane invariants (issue #172). These run in the quick group, unlike the
-- builder tests. A door approach must never lie on a lane cell: the floor of
-- an approach must be a full block, because preflight.check_door rejects a
-- door whose approach floor is a partial (slab) node. Only arms carry lanes.
do
	local function in_r(r, x, z) return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 end
	local function lane_cells_of(plan)
		local out = {}
		for _, st in ipairs(plan.streets) do if st.lane then out[#out + 1] = st.lane.rect end end
		return out
	end
	for _, seed in ipairs({1, 2, 3, 7, 11, 23}) do
		local p, why = planner.plan({x = 0, z = 0}, seed, {town_type = "roman"})
		assert(p, why)
		local lanes = lane_cells_of(p)
		eq(#lanes, 4, "seed " .. seed .. " has four arm lanes")
		local cells = {}
		for _, name in ipairs(p.site_order) do cells[#cells + 1] = {p.sites[name].approach.pos, name} end
		for _, b in ipairs(p.content.buildings) do cells[#cells + 1] = {b.approach, b.building_id} end
		local res = {p.reservations.jail}
		for _, s in ipairs(p.reservations.services) do res[#res + 1] = s end
		for _, r in ipairs(res) do
			if r.approach then cells[#cells + 1] = {r.approach, r.building_id} end
		end
		eq(#p.content.buildings > 0, true, "seed " .. seed .. " is populated")
		for _, c in ipairs(cells) do
			for _, lr in ipairs(lanes) do
				eq(in_r(lr, c[1].x, c[1].z), false,
					"seed " .. seed .. " approach of " .. c[2] .. " is not on a lane cell")
			end
		end
	end
end

-- Crossing precedence (issue #172): where a ring band crosses an arm's lane,
-- the lane cell is a slab (beats the gravel ring and the cobble street); ring
-- cells beside the arm are gravel; the street's edge columns stay cobble.
do
	local function in_r(r, x, z) return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 end
	local TL = dofile("src/town_layout.lua")
	local p = planner.plan({x = 0, z = 0}, 1, {town_type = "roman"})
	assert(p)
	local pav = TL.pavement_map(p)
	local function at(x, z) return pav[x] and pav[x][z] end
	local ring_of = {}
	for _, st in ipairs(p.streets) do if st.ring then ring_of[st.ring] = st end end
	for _, arm in ipairs({"north", "east"}) do
		local st = nil
		for _, s in ipairs(p.streets) do if s.arm == arm then st = s end end
		local lane, band = st.lane.rect, ring_of[arm].rect
		-- along: the arm's axis, the band's thin axis; across: the other one.
		local along = (arm == "north" or arm == "south") and "z" or "x"
		local across = along == "z" and "x" or "z"
		local function cell(a, c)
			if along == "z" then return c, a end
			return a, c
		end
		local a = band[along .. "1"]
		local lx, lz = cell(a, lane[across .. "1"])
		eq(in_r(lane, lx, lz) and in_r(band, lx, lz), true, arm .. " crossing lane cell lies in the ring band")
		eq(at(lx, lz), "mcl_stairs:slab_cobble", arm .. " crossing lane cell is a slab")
		local gx, gz = cell(a, st.rect[across .. "1"] - 1)
		eq(in_r(band, gx, gz) and not in_r(st.rect, gx, gz), true, arm .. " gravel probe lies in the ring beside the arm")
		eq(at(gx, gz), ring_of[arm].material, arm .. " ring cell beside the arm is gravel")
		local ex, ez = cell(a, st.rect[across .. "1"])
		eq(at(ex, ez), "mcl_core:cobble", arm .. " crossing edge column stays cobble")
	end
end

-- Ring landmarks (issue #201): ring, side ("inner" or "outer") and at (the
-- compass coordinate of the low edge along the band) replace arm and side. The
-- fixture widens the four bands so one insula fits on each side, and it drops
-- the other monuments and the blocks. Rects are pinned: an offset by one node
-- along the band, or a flipped side, must fail here.
do
	local FIX = {
		{name = "north_outer", ring = "north", side = "outer", at = 6, rotation = 0,
			rect = {6, 61, 40, 87}, facing = {0, -1}},
		{name = "south_outer", ring = "south", side = "outer", at = 6, rotation = 180,
			rect = {6, -88, 40, -62}, facing = {0, 1}},
		{name = "west_outer", ring = "west", side = "outer", at = -42, rotation = 270,
			rect = {-88, -42, -62, -8}, facing = {1, 0}},
		{name = "east_outer", ring = "east", side = "outer", at = -42, rotation = 90,
			rect = {61, -42, 87, -8}, facing = {-1, 0}},
		{name = "north_inner", ring = "north", side = "inner", at = -38, rotation = 180,
			rect = {-38, 28, -4, 54}, facing = {0, 1}},
		{name = "south_inner", ring = "south", side = "inner", at = 3, rotation = 0,
			rect = {3, -55, 37, -29}, facing = {0, -1}},
		{name = "west_inner", ring = "west", side = "inner", at = -38, rotation = 90,
			rect = {-55, -38, -29, -4}, facing = {-1, 0}},
		{name = "east_inner", ring = "east", side = "inner", at = 3, rotation = 270,
			rect = {28, 3, 54, 37}, facing = {1, 0}},
	}
	local function ring_plan_with(edit)
		local specs = {}
		for i, w in ipairs(FIX) do
			specs[i] = {name = w.name, id = "insula", ring = w.ring, side = w.side, at = w.at, rotation = w.rotation}
		end
		if edit then edit(specs) end
		local l = copy(roman.layout)
		l.blocks, l.landmarks = {}, specs
		l.bands = {
			{name = "north", arm = "north", from = 40, to = 45, span = {-54, 54}},
			{name = "south", arm = "south", from = 40, to = 45, span = {-54, 54}},
			{name = "east", arm = "east", from = 40, to = 45, span = {-54, 54}},
			{name = "west", arm = "west", from = 40, to = 45, span = {-54, 54}},
		}
		return roman.plan({x = 0, z = 0}, 1, l, row_depth)
	end

	local ring_plan, why = ring_plan_with()
	assert(ring_plan, why)
	eq(planner.validate(ring_plan), true, "ring landmark fixture passes authored validation")
	for _, w in ipairs(FIX) do
		local s = ring_plan.sites[w.name]
		eq(s ~= nil and s.kind == "landmark", true, w.name .. " is planned as a landmark")
		local r = s.rect
		eq(r.x1 == w.rect[1] and r.z1 == w.rect[2] and r.x2 == w.rect[3] and r.z2 == w.rect[4], true,
			w.name .. " stands flush against its band at the pinned rect")
		eq(s.facing.x == w.facing[1] and s.facing.z == w.facing[2], true, w.name .. " door faces the band")
		eq(s.ring, w.ring, w.name .. " records its ring")
		eq(s.arm, nil, w.name .. " has no arm")
		local band
		for _, st in ipairs(ring_plan.streets) do if st.ring == w.ring then band = st end end
		local a = s.approach.pos
		eq(in_rect(band.rect, a.x, a.z), true, w.name .. " approach lies on its ring band")
	end

	-- Every wrong rotation is rejected: the door must turn toward the band.
	for i, w in ipairs(FIX) do
		for _, delta in ipairs({90, 180}) do
			local bad, reason = ring_plan_with(function(s)
				s[i].rotation = (w.rotation + delta) % 360
			end)
			eq(bad, nil, w.name .. " rotation +" .. delta .. " is rejected")
			eq(reason:find("does not face its street", 1, true) ~= nil, true, w.name .. " wrong rotation reason")
		end
	end
	-- A flipped side (outer for inner) turns the door away from the band.
	for i, w in ipairs(FIX) do
		local bad, reason = ring_plan_with(function(s)
			s[i].side = w.side == "outer" and "inner" or "outer"
		end)
		eq(bad, nil, w.name .. " with the other side is rejected")
		eq(reason:find("does not face its street", 1, true) ~= nil, true, w.name .. " flipped side reason")
	end

	-- Malformed ring landmarks are reported, not built.
	local bad, reason, detail = ring_plan_with(function(s) s[1].ring = "missing" end)
	eq(bad, nil, "an unknown ring is rejected")
	eq(detail and detail.code, "invalid_layout", "unknown ring reports invalid_layout")
	eq(reason:find("invalid ring or side", 1, true) ~= nil, true, "unknown ring reason")
	bad, reason = ring_plan_with(function(s) s[2].side = "+x" end)
	eq(bad, nil, "a compass side on a ring landmark is rejected")
	eq(reason:find("invalid ring or side", 1, true) ~= nil, true, "compass side on ring reason")
	bad, reason = ring_plan_with(function(s) s[3].at = "-42" end)
	eq(bad, nil, "a non-numeric at is rejected")
	eq(reason:find("malformed at", 1, true) ~= nil, true, "non-numeric at reason")
	bad, reason = ring_plan_with(function(s) s[4].at = -41.5 end)
	eq(bad, nil, "a fractional at is rejected")
	eq(reason:find("malformed at", 1, true) ~= nil, true, "fractional at reason")
	bad, reason = ring_plan_with(function(s) s[5].arm = "north" end)
	eq(bad, nil, "a landmark with both ring and arm is rejected")
	eq(reason:find("sets both ring and arm", 1, true) ~= nil, true, "ring and arm reason")
	bad, reason = ring_plan_with(function(s) s[6].faces = "forum" end)
	eq(bad, nil, "a ring landmark with faces is rejected")
	eq(reason:find("sets faces on a ring landmark", 1, true) ~= nil, true, "ring faces reason")
end

-- Insulae and the authored layout (issue #202). Side coverage counts the
-- outside nodes of each insula side that are paved; `paved` above is built
-- from the forum and the streets alone, not from the planner's own numbers.
do
	local function side_nodes(r, side)
		local out = {}
		if side == "-z" then for x = r.x1, r.x2 do out[#out + 1] = {x, r.z1 - 1} end
		elseif side == "+z" then for x = r.x1, r.x2 do out[#out + 1] = {x, r.z2 + 1} end
		elseif side == "-x" then for z = r.z1, r.z2 do out[#out + 1] = {r.x1 - 1, z} end
		else for z = r.z1, r.z2 do out[#out + 1] = {r.x2 + 1, z} end end
		return out
	end
	-- Expected paved nodes per side: the south insula's south side loses three
	-- nodes at x 3..5, where the south outer band starts at x 6.
	local want = {
		insula_north_east = {["-z"] = 35, ["+z"] = 35, ["-x"] = 27, ["+x"] = 27},
		insula_north_west = {["-z"] = 35, ["+z"] = 35, ["-x"] = 27, ["+x"] = 27},
		insula_south = {["-z"] = 32, ["+z"] = 35, ["-x"] = 27, ["+x"] = 27},
	}
	for _, name in ipairs({"insula_north_east", "insula_north_west", "insula_south"}) do
		local r = plan.sites[name].rect
		eq(plan.sites[name].id, "insula", name .. " is an insula")
		for _, side in ipairs({"-z", "+z", "-x", "+x"}) do
			local nodes = side_nodes(r, side)
			local n = 0
			for _, c in ipairs(nodes) do if paved[c[1] .. "," .. c[2]] then n = n + 1 end end
			eq(#nodes, (side == "-z" or side == "+z") and 35 or 27, name .. " " .. side .. " side length")
			eq(n, want[name][side], name .. " " .. side .. " side paved nodes")
		end
	end

	-- No monument overlaps an arch: the north and south arches stand clear.
	for _, s in ipairs(list) do
		if s.id ~= "arch" then
			for _, arch in ipairs({"arch_north", "arch_south"}) do
				eq(overlap(s.rect, plan.sites[arch].rect), false, s.name .. " clear of " .. arch)
			end
		end
	end

	-- Boundary: 181 by 172 nodes.
	local b = plan.boundary.rects[1]
	eq(b.x2 - b.x1 + 1, 181, "construction boundary is 181 nodes across")
	eq(b.z2 - b.z1 + 1, 172, "construction boundary is 172 nodes deep")
	-- Site-search reach: 320 + (edge - REACH_EDGE 48) = 367, so the edge is 95.
	local c = plan.center
	eq(math.max(c.x - b.x1, b.x2 - c.x, c.z - b.z1, b.z2 - c.z), 95, "boundary edge is 95 from the centre (reach 367)")

	-- Literal rects at the origin (seed 1): a one-node slip in any of these fails.
	local origin = assert(planner.plan({x = 0, z = 0}, 1, {town_type = "roman"}))
	local pins = {
		{"domus_1", 44, 39, 81, 60}, {"domus_2", 15, -41, 36, -4},
		{"domus_3", 44, -41, 65, -4}, {"domus_4", -66, 3, -45, 40},
		{"amphitheater", 44, 3, 72, 31},
		{"insula_north_east", 3, 39, 37, 65}, {"insula_north_west", -38, 39, -4, 65},
		{"insula_south", 3, -74, 37, -48},
	}
	local function rect_pin(r, pin, label)
		eq(r.x1, pin[2], label .. " x1")
		eq(r.z1, pin[3], label .. " z1")
		eq(r.x2, pin[4], label .. " x2")
		eq(r.z2, pin[5], label .. " z2")
	end
	for _, pin in ipairs(pins) do
		rect_pin(origin.sites[pin[1]].rect, pin, pin[1] .. " rect at the origin")
	end
	local block_pins = {
		{"east_forum_north", 15, 3, 37, 11}, {"east_end_south", 66, -12, 73, -4},
		{"south_east_inner", 3, -41, 11, -16}, {"west_forum_south", -25, -12, -16, -4},
		{"west_end_south", -74, -12, -47, -4}, {"west_forum_north", -38, 3, -16, 11},
		{"west_end_north", -74, 3, -67, 11}, {"ring_north_inner_east", 15, 24, 37, 32},
		{"outer_north_east", 6, 72, 43, 80}, {"outer_north_west", -44, 72, -7, 80},
		{"ring_west_outer_north", -53, 42, -45, 71}, {"ring_east_outer_south", 44, -80, 52, -42},
	}
	eq(#origin.blocks, #block_pins, "block count matches the authored list")
	local by_name = {}
	for _, b in ipairs(origin.blocks) do by_name[b.name] = b end
	for _, pin in ipairs(block_pins) do
		eq(by_name[pin[1]] ~= nil, true, pin[1] .. " block is planned")
		if by_name[pin[1]] then rect_pin(by_name[pin[1]].rect, pin, pin[1] .. " block rect at the origin") end
	end

	-- Many seeds and several centres validate.
	for _, c in ipairs({{0, 0}, {100, -50}, {-3000, 777}}) do
		for seed = 1, 100 do
			local p = planner.plan({x = c[1], z = c[2]}, seed, {town_type = "roman"})
			eq(p ~= nil and planner.validate(p) == true, true,
				("seed %d at (%d,%d) validates"):format(seed, c[1], c[2]))
		end
	end
end
