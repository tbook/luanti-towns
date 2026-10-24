-- Outskirts v1 contract checks (issue #226). Loaded by tests/run.lua:
--   loadfile("tests/outskirts_contract_tests.lua")(eq, fails, planner, catalog, geometry)
--
-- Not production code. It checks that
--   * docs/outskirts_design.md quotes every frozen constant and rejection code;
--   * the exits rule in the document, written once here as a reference
--     implementation, yields exactly the exits of the real Roman plan and of
--     all 32 medieval arrangements;
--   * the worked example (tests/outskirts_fixture.lua) is internally
--     consistent and agrees with src/geometry.lua;
--   * when the Living Villages mod is installed, village_smoothing.targets
--     really behaves as the document says (skipped otherwise).
local eq, fails, planner, catalog, geometry = ...
local F = dofile("tests/outskirts_fixture.lua")
local medieval = dofile("src/medieval_planner.lua")
local C = F.constants

local function slurp(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

------------------------------------------------------------------------
-- The document quotes the frozen constants and the rejection codes.
------------------------------------------------------------------------
local doc = slurp("docs/outskirts_design.md")
eq(doc ~= nil, true, "docs/outskirts_design.md exists")
doc = doc or ""
local names = {}
for k in pairs(C) do names[#names + 1] = k end
table.sort(names)
for _, k in ipairs(names) do
	local v = C[k]
	local want = type(v) == "string" and ("%s = %q"):format(k, v) or ("%s = %s"):format(k, tostring(v))
	eq(doc:find(want, 1, true) ~= nil, true, "document freezes " .. want)
end
for _, code in ipairs(F.rejection_codes) do
	eq(doc:find("`" .. code .. "`", 1, true) ~= nil, true, "document lists rejection code " .. code)
end

-- Constants agree with each other.
eq(C.TARGET_GROUPS * C.GROUP_PLOTS_MIN, C.ORDINARY_MIN, "two minimal groups reach the lower visual target")
eq(C.TARGET_GROUPS * C.GROUP_PLOTS_MAX, C.ORDINARY_MAX, "two full groups reach the upper visual target")
eq(C.SLOT_FIRST + (C.SLOTS_PER_EXIT - 1) * C.SLOT_STEP + C.GROUP_WINDOW - 1 <= C.ROAD_MAX_LENGTH, true,
	"the last slot window ends inside the maximum road length")
eq(C.SLOT_STEP >= C.GROUP_WINDOW, true, "slot windows do not overlap")
eq(C.SLOT_FIRST - (C.TERRAIN_MARGIN + C.TERRAIN_RADIUS) >= 2, true,
	"the first window's smoothing reach starts at least at the second road column")
eq(C.CUT_FILL_CAP < C.SUPPORT_ROWS and C.ROAD_CAP < C.SUPPORT_ROWS, true,
	"no fill is deeper than the dirt support rows, so no stone fill is ever needed")
eq(C.PATH_WIDTH % 2, 1, "an odd path width centres on a node")

------------------------------------------------------------------------
-- Reference implementation of the exits rule (document, "Exits").
------------------------------------------------------------------------
local PASS_THROUGH = {arch = true}
local DIR_RANK = {["0,1"] = 1, ["1,0"] = 2, ["0,-1"] = 3, ["-1,0"] = 4}

local function in_rect(r, x, z) return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 end
local function in_union(plan, x, z)
	for _, r in ipairs(plan.boundary.rects) do
		if in_rect(r, x, z) then return true end
	end
	return false
end

-- "outside" | "pass" | "free" | "blocked", plus the blocker's name.
local function classify(plan, own, x, z)
	if not in_union(plan, x, z) then return "outside" end
	local names = {}
	for name in pairs(plan.sites) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local s = plan.sites[name]
		if in_rect(s.rect, x, z) then
			if s.kind == "landmark" and PASS_THROUGH[s.id] then return "pass", name end
			return "blocked", name
		end
	end
	for _, b in ipairs(plan.blocks) do
		if in_rect(b.rect, x, z) then return "blocked", "block" end
	end
	for _, s in ipairs(plan.streets) do
		if s ~= own and in_rect(s.rect, x, z) then return "blocked", "street" end
	end
	return "free"
end

local function derive_exits(plan)
	local exits, blocked = {}, {}
	for _, s in ipairs(plan.streets) do
		if s.kind == "principal" then
			local r = s.rect
			local axis = (r.x2 - r.x1 > r.z2 - r.z1) and "x" or "z"
			local c1, c2 = r[(axis == "x") and "z1" or "x1"], r[(axis == "x") and "z2" or "x2"]
			for _, sign in ipairs({1, -1}) do
				local last = (sign > 0) and r[axis .. "2"] or r[axis .. "1"]
				local via, found, why = nil, nil, nil
				for k = 1, 400 do
					local along = last + sign * k
					local seen, who = {}, nil
					for c = c1, c2 do
						local x, z = along, c
						if axis == "z" then x, z = c, along end
						local st, name = classify(plan, s, x, z)
						seen[st] = true
						who = who or name
					end
					local n = 0
					for _ in pairs(seen) do n = n + 1 end
					if seen.outside and n == 1 then found = along; break end
					if n ~= 1 or seen.blocked then why = who or "mixed"; break end
					if seen.pass then via = who end
				end
				if found then
					local inset = math.floor((s.width - C.PATH_WIDTH) / 2)
					local dir = (axis == "x") and {x = sign, z = 0} or {x = 0, z = sign}
					local lane1 = c1 + inset
					local centre = lane1 + (C.PATH_WIDTH - 1) / 2
					local join, start
					if axis == "x" then
						join, start = {x = found - sign, z = centre}, {x = found, z = centre}
					else
						join, start = {x = centre, z = found - sign}, {x = centre, z = found}
					end
					local b = plan.bounds
					if not in_rect(b, start.x, start.z) then
						exits[#exits + 1] = {street_id = s.id, via = via, dir = dir, axis = axis,
							width = s.width, cross = {c1 = c1, c2 = c2},
							lane = {c1 = lane1, c2 = lane1 + C.PATH_WIDTH - 1}, centre = centre,
							join = join, start = start}
					end
				else
					blocked[#blocked + 1] = why or "unknown"
				end
			end
		end
	end
	table.sort(exits, function(a, b)
		local ra, rb = DIR_RANK[a.dir.x .. "," .. a.dir.z], DIR_RANK[b.dir.x .. "," .. b.dir.z]
		if ra ~= rb then return ra < rb end
		return a.street_id < b.street_id
	end)
	for i, e in ipairs(exits) do e.id = "e" .. i end
	return exits, blocked
end

local function same_xz(a, b) return a.x == b.x and a.z == b.z end

------------------------------------------------------------------------
-- Real Roman plan at the fixture's centre equals the fixture's exits.
------------------------------------------------------------------------
local roman = assert(planner.plan(F.town.center, F.town.seed, {town_type = "roman"}))
local exits = derive_exits(roman)
eq(#exits, 4, "Roman plan: one exit per arm")
for i, want in ipairs(F.exits) do
	local got = exits[i] or {}
	local label = "Roman exit " .. want.id
	eq(got.id, want.id, label .. " id")
	eq(got.street_id, want.street_id, label .. " street")
	eq(got.via, want.via, label .. " passes the arch")
	eq(same_xz(got.dir or {}, want.dir), true, label .. " direction")
	eq(got.axis, want.axis, label .. " axis")
	eq(got.width, want.width, label .. " width")
	eq(got.cross and got.cross.c1, want.cross.c1, label .. " cross c1")
	eq(got.cross and got.cross.c2, want.cross.c2, label .. " cross c2")
	eq(got.lane and got.lane.c1, want.lane.c1, label .. " lane c1")
	eq(got.lane and got.lane.c2, want.lane.c2, label .. " lane c2")
	eq(got.centre, want.centre, label .. " centre")
	eq(same_xz(got.join or {}, want.join), true, label .. " join")
	eq(same_xz(got.start or {}, want.start), true, label .. " start")
	eq(in_union(roman, want.join.x, want.join.z), true, label .. " join is inside the union")
	eq(in_union(roman, want.start.x, want.start.z), false, label .. " start is outside the union")
end

-- A bounding-box edge alone is not an exit: the Roman box has four edges but
-- the south-west quadrant's bath stands near the west one, and a ray that is
-- merely adjacent to an arch is not enough. The rule needs street + passage.
for _, e in ipairs(F.exits) do
	eq(e.width, 6, "Roman principals are six wide")
	eq(e.lane.c2 - e.lane.c1 + 1, C.PATH_WIDTH, "lane is PATH_WIDTH wide")
	eq(e.lane.c1 >= e.cross.c1 and e.lane.c2 <= e.cross.c2, true, "lane lies inside the street")
end

-- Translation: moving the centre moves every exit by the same offset.
do
	local a = assert(planner.plan({x = 0, z = 0}, 8, {town_type = "roman"}))
	local ea = derive_exits(a)
	for i, e in ipairs(ea) do
		eq(e.start.x + 1000, exits[i].start.x, "exit " .. i .. " translates in x")
		eq(e.start.z - 2000, exits[i].start.z, "exit " .. i .. " translates in z")
	end
end

------------------------------------------------------------------------
-- All 32 medieval arrangements: exactly two exits, the other two principal
-- ends are the cathedral approach and the castle.
------------------------------------------------------------------------
do
	local profile = assert(planner.landmark_profile(catalog.snapshot()))
	local function fixed_rng(seed)
		local n = seed
		return {int = function(a, b) n = (n * 1103515245 + 12345) % 2147483648; return a + n % (b - a + 1) end}
	end
	local count = 0
	for quadrant = 0, 3 do
		for _, east in ipairs({false, true}) do
			for turn = 0, 270, 90 do
				local label = ("medieval q%d east=%s turn=%d"):format(quadrant, tostring(east), turn)
				local plan = medieval.plan({x = 100, z = -40}, 1, profile, fixed_rng(1),
					{quadrant = quadrant, castle_east = east, turn = turn})
				eq(plan ~= nil, true, label .. " plans")
				if plan then
					count = count + 1
					local ex, blocked = derive_exits(plan)
					eq(#ex, 2, label .. ": two exits")
					table.sort(blocked)
					eq(table.concat(blocked, ","), "castle,parvis", label .. ": castle and parvis end the other two")
					local seen = {}
					for _, e in ipairs(ex) do
						eq(e.via, nil, label .. ": medieval exits pass no arch")
						eq(in_union(plan, e.join.x, e.join.z), true, label .. " " .. e.id .. " join inside")
						eq(in_union(plan, e.start.x, e.start.z), false, label .. " " .. e.id .. " start outside")
						eq(in_rect(plan.bounds, e.start.x, e.start.z), false, label .. " " .. e.id .. " outside bounds")
						eq(e.width, 6, label .. " principals are six wide")
						local key = e.dir.x .. "," .. e.dir.z
						eq(seen[key], nil, label .. ": exit directions differ")
						seen[key] = true
					end
					-- Translation by the centre: same arrangement at another centre.
					local moved = medieval.plan({x = -317, z = 4096}, 1, profile, fixed_rng(1),
						{quadrant = quadrant, castle_east = east, turn = turn})
					local ex2 = derive_exits(moved)
					eq(#ex2, 2, label .. ": moved plan has two exits")
					for i, e in ipairs(ex2) do
						eq(ex[i] and e.start.x - ex[i].start.x, -417, label .. " exit " .. i .. " dx")
						eq(ex[i] and e.start.z - ex[i].start.z, 4136, label .. " exit " .. i .. " dz")
					end
				end
			end
		end
	end
	eq(count, 32, "all 32 medieval arrangements were checked")
end

------------------------------------------------------------------------
-- The worked example is internally consistent.
------------------------------------------------------------------------
local cottage = F.cottage
local g = F.town.ground_y
local e1 = F.exits[1]
local road, group, region = F.road, F.group, F.region
local plan_bounds = roman.bounds

-- Road profile: starts at the urban ground, moves at most one node per
-- column, never strays further than ROAD_CAP from the natural height.
eq(road.exit_id, e1.id, "road belongs to e1")
eq(#road.y, road.length, "one finished height per road column")
eq(#road.natural, road.length, "one natural height per road column")
eq(road.length <= road.reach and road.reach <= C.ROAD_MAX_LENGTH, true, "built length <= reach <= the limit")
eq(road.join_y, g, "road joins the leveled urban ground")
for k = 1, road.length do
	local prev = (k == 1) and road.join_y or road.y[k - 1]
	eq(math.abs(road.y[k] - prev) <= 1, true, "road step " .. k .. " is walkable")
	eq(math.abs(road.y[k] - road.natural[k]) <= C.ROAD_CAP, true, "road column " .. k .. " is within the cap")
	eq(F.natural(e1.centre, e1.start.z + k - 1), road.natural[k], "road column " .. k .. " natural height")
end
eq(road.y[1] ~= road.natural[1], true, "the join forces a clamp on the first column")

-- Group.
eq(group.exit_id, e1.id, "group is on e1")
eq(group.window.k1, C.SLOT_FIRST + (group.slot - 1) * C.SLOT_STEP, "window starts at its slot")
eq(group.window.k2 - group.window.k1 + 1, C.GROUP_WINDOW, "window length")
eq(group.window.k2 <= road.reach, true, "the road could serve the whole window")
local need = 0
for _, ap in ipairs(F.approaches) do need = math.max(need, ap.road_k + (C.PATH_WIDTH - 1) / 2) end
eq(road.length, need, "the road is built only as far as the farthest approach needs")
local wz1, wz2 = e1.start.z + group.window.k1 - 1, e1.start.z + group.window.k2 - 1
eq(#group.plots >= C.MIN_ACCEPTED_PLOTS and #group.plots <= C.GROUP_PLOTS_MAX, true, "plot count")

local function grow(r, m) return {x1 = r.x1 - m, z1 = r.z1 - m, x2 = r.x2 + m, z2 = r.z2 + m} end
local function overlap(a, b) return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2 end

for i, plot in ipairs(group.plots) do
	local label = plot.id
	local st, pad, ap = F.structures[i], F.pads[i], F.approaches[i]
	-- Plot rect = rotated footprint at the schematic origin (ground - ground_offset).
	local origin = {x = plot.rect.x1, y = group.ground_y - cottage.ground_offset, z = plot.rect.z1}
	local p = geometry.place(cottage, origin, plot.rotation)
	eq(p.max.x, plot.rect.x2, label .. " rect x2 = rotated footprint")
	eq(p.max.z, plot.rect.z2, label .. " rect z2 = rotated footprint")
	eq(st.plot, plot.id, label .. " structure plot")
	eq(st.rotation, plot.rotation, label .. " structure rotation")
	eq(st.min.y, p.min.y, label .. " structure min y")
	eq(st.max.y, p.max.y, label .. " structure max y")
	eq(st.max.x, p.max.x, label .. " structure max x")
	eq(st.max.z, p.max.z, label .. " structure max z")
	eq(same_xz(st.entrance, p.entrance), true, label .. " entrance x/z")
	eq(st.entrance.y, p.entrance.y, label .. " entrance feet y")
	eq(same_xz(st.front, p.front), true, label .. " front")
	eq(st.size.x, p.size.x, label .. " size x")
	eq(st.size.z, p.size.z, label .. " size z")
	eq(st.site_ground_y, group.ground_y, label .. " site ground")

	-- Three different Ys.
	eq(st.min.y, group.ground_y - cottage.ground_offset, label .. " schematic origin y = ground - ground_offset")
	eq(st.entrance.y, st.min.y + cottage.entrance.y, label .. " feet y = origin + entrance.y")
	eq(st.entrance.y, group.ground_y + 1, label .. " feet stand one above the ground row")
	eq(st.min.y < group.ground_y and group.ground_y < st.entrance.y, true, label .. " origin < ground < feet")

	-- Lateral position, window and the urban boundary.
	if plot.side < 0 then
		eq(plot.rect.x2, e1.lane.c1 - 1 - C.SETBACK, label .. " west plot keeps the setback")
	else
		eq(plot.rect.x1, e1.lane.c2 + 1 + C.SETBACK, label .. " east plot keeps the setback")
	end
	eq(plot.rect.z1 >= wz1 and plot.rect.z2 <= wz2, true, label .. " lies in the window")
	eq(overlap(plot.rect, plan_bounds), false, label .. " lies outside plan.bounds")

	-- Pad.
	eq(pad.plot_id, plot.id, label .. " pad plot")
	eq(pad.x0, plot.rect.x1, label .. " pad x0")
	eq(pad.z1, plot.rect.z2, label .. " pad z1")
	local y = grow(plot.rect, C.TERRAIN_MARGIN)
	eq(pad.yx0 == y.x1 and pad.yz0 == y.z1 and pad.yx1 == y.x2 and pad.yz1 == y.z2, true, label .. " yard = footprint + margin")
	eq(pad.y, group.ground_y, label .. " pad.y is the site ground, not the schematic origin")
	eq(pad.height, cottage.size.y, label .. " pad height")
	eq(pad.surface, C.SURFACE_NODE, label .. " pad surface")
	for z = y.z1, y.z2 do
		for x = y.x1, y.x2 do
			local nat = F.natural(x, z)
					if math.abs(nat - group.ground_y) > C.CUT_FILL_CAP then
				eq(true, false, label .. " footprint/yard column (" .. x .. "," .. z .. ") exceeds the cap")
			end
		end
	end

	-- Approach.
	eq(ap.plot_id, plot.id, label .. " approach plot")
	eq(same_xz(ap.from, p.outside), true, label .. " approach starts at the node outside the door")
	eq(same_xz(ap.dir, p.front), true, label .. " approach runs along the front")
	eq(ap.width, C.PATH_WIDTH, label .. " approach width")
	eq(ap.length, C.SETBACK, label .. " approach spans the setback")
	eq(#ap.y, ap.length, label .. " one height per approach cell")
	eq(ap.y[1], group.ground_y, label .. " first approach cell is at the group ground")
	for n = 2, ap.length do
		eq(math.abs(ap.y[n] - ap.y[n - 1]) <= 1, true, label .. " approach step " .. n)
	end
	local last = {x = ap.from.x + ap.dir.x * (ap.length - 1), z = ap.from.z + ap.dir.z * (ap.length - 1)}
	local edge_x = (plot.side < 0) and (e1.lane.c1 - 1) or (e1.lane.c2 + 1)
	eq(last.x, edge_x, label .. " approach ends beside the lane")
	eq(ap.road_k, ap.from.z - e1.start.z + 1, label .. " attaches at its road column")
	eq(ap.road_y, road.y[ap.road_k], label .. " road height at the attachment")
	eq(ap.y[ap.length], ap.road_y, label .. " approach meets the road height")
	eq(math.abs(group.ground_y - ap.road_y) <= C.CUT_FILL_CAP, true, label .. " group/road mismatch is within the cap")
end

-- Group ground = median natural height under all footprints.
do
	local vals = {}
	for _, plot in ipairs(group.plots) do
		for z = plot.rect.z1, plot.rect.z2 do
			for x = plot.rect.x1, plot.rect.x2 do vals[#vals + 1] = F.natural(x, z) end
		end
	end
	table.sort(vals)
	eq(vals[math.floor(#vals / 2) + 1], group.ground_y, "group ground is the (upper) median of the footprints")
end

-- Plots do not overlap each other or their yards' structures.
eq(overlap(group.plots[1].rect, group.plots[2].rect), false, "plots are independent")

-- Region bounds.
do
	local t = region.targets
	local x1, z1, x2, z2
	for _, pad in ipairs(F.pads) do
		local reach = C.TERRAIN_MARGIN + C.TERRAIN_RADIUS
		x1 = math.min(x1 or pad.x0 - reach, pad.x0 - reach)
		z1 = math.min(z1 or pad.z0 - reach, pad.z0 - reach)
		x2 = math.max(x2 or pad.x1 + reach, pad.x1 + reach)
		z2 = math.max(z2 or pad.z1 + reach, pad.z1 + reach)
	end
	eq(t.bbox.x1 == x1 and t.bbox.z1 == z1 and t.bbox.x2 == x2 and t.bbox.z2 == z2, true,
		"targets bbox = pads grown by margin + radius")
	local owned = 0
	for _, k in pairs(t.by_kind) do owned = owned + k.n end
	eq(owned, t.owned, "owned columns add up")
	eq(t.by_kind.footprint1.n, 8 * 7, "footprint column count")
	eq(t.by_kind.yard1.n, 12 * 11 - 8 * 7, "yard ring column count")

	local lane_z2 = e1.start.z + road.length - 1
	local bx1, bx2 = math.min(x1, e1.lane.c1), math.max(x2, e1.lane.c2)
	local bz1, bz2 = math.min(z1, e1.start.z), math.max(z2, lane_z2)
	eq(region.bounds.min.x, bx1, "region min x")
	eq(region.bounds.max.x, bx2, "region max x")
	eq(region.bounds.min.z, bz1, "region min z")
	eq(region.bounds.max.z, bz2, "region max z")
	eq(overlap({x1 = bx1, z1 = bz1, x2 = bx2, z2 = bz2}, plan_bounds), false, "region lies outside plan.bounds")

	local lowest = math.huge
	for _, y in ipairs(road.y) do lowest = math.min(lowest, y) end
	local nat_min, nat_max = math.huge, -math.huge
	for z = z1, z2 do
		for x = x1, x2 do
			nat_min = math.min(nat_min, F.natural(x, z))
			nat_max = math.max(nat_max, F.natural(x, z))
		end
	end
	eq(lowest <= nat_min - 0, true, "the road column is the lowest finished surface (cap keeps the rest above)")
	eq(region.bounds.min.y, lowest - C.SUPPORT_ROWS, "region min y = lowest surface - support rows")
	local top = 0
	for _, st in ipairs(F.structures) do top = math.max(top, st.max.y) end
	eq(region.bounds.max.y, math.max(top, nat_max) + C.CLEAR_ABOVE, "region max y = highest of structures/surfaces + clear")
	for _, st in ipairs(F.structures) do
		eq(st.min.x >= region.bounds.min.x and st.max.x <= region.bounds.max.x
			and st.min.y >= region.bounds.min.y and st.max.y <= region.bounds.max.y
			and st.min.z >= region.bounds.min.z and st.max.z <= region.bounds.max.z, true,
			st.plot .. " box lies inside the region")
	end
	local m = C.CUT_FILL_MARGIN
	local v, b = region.volume, region.bounds
	eq(v.min.x == b.min.x - m and v.min.y == b.min.y - m and v.min.z == b.min.z - m
		and v.max.x == b.max.x + m and v.max.y == b.max.y and v.max.z == b.max.z + m, true,
		"volume = bounds + CUT_FILL_MARGIN around and below (as site_search.build_volume)")
	eq(b.min.y >= g - C.SCAN_DOWN and b.max.y <= g + C.SCAN_UP + 1 + C.CLEAR_ABOVE + 20, true,
		"region heights relate to the scan window")
end

-- Sample columns agree with the natural terrain and the caps.
for _, c in ipairs(region.columns) do
	local nat = F.natural(c.x, c.z)
	eq(c.was, nat, ("sample column (%d,%d) was"):format(c.x, c.z))
	eq(math.abs(c.at - c.was) <= C.CUT_FILL_CAP, true, ("sample column (%d,%d) within the cap"):format(c.x, c.z))
	if c.kind == "road" then eq(road.y[c.road_k], c.at, "road sample matches the profile") end
end

-- Rejection records.
do
	local known = {}
	for _, code in ipairs(F.rejection_codes) do known[code] = true end
	for _, r in ipairs(F.rejections) do
		eq(known[r.code], true, "rejection code " .. r.code .. " is documented")
		eq(type(r.stage) == "string" and type(r.subject) == "string" and type(r.detail) == "string", true,
			"rejection record shape")
	end
end

------------------------------------------------------------------------
-- Living Villages (optional): the API facts the document states.
------------------------------------------------------------------------
do
	-- Beside the mod, or beside the main checkout when run from a worktree.
	local candidates = {"../living_villages", "../../../../living_villages"}
	local from_env = os.getenv("TOWNS_LIVING_VILLAGES")
	if from_env then table.insert(candidates, 1, from_env) end
	local lv
	for _, path in ipairs(candidates) do
		if slurp(path .. "/village_smoothing.lua") then lv = path; break end
	end
	if not lv then
		print("SKIP outskirts contract: Living Villages not found (set TOWNS_LIVING_VILLAGES)")
		return
	end
	local saved = rawget(_G, "minetest")
	rawset(_G, "minetest", {get_modpath = function(name)
		assert(name == "living_villages")
		return lv
	end})
	local ok, smoothing = pcall(dofile, lv .. "/village_smoothing.lua")
	rawset(_G, "minetest", saved)
	eq(ok, true, "village_smoothing.lua loads headless with a stubbed minetest.get_modpath")
	if not ok then return end
	eq(type(smoothing.targets), "function", "village_smoothing.targets exists")

	local cfg = {margin = C.TERRAIN_MARGIN, radius = C.TERRAIN_RADIUS, cap = C.CUT_FILL_CAP, wall = C.TERRAIN_WALL}
	local pads = {}
	for i, p in ipairs(F.pads) do
		pads[i] = {x0 = p.x0, z0 = p.z0, x1 = p.x1, z1 = p.z1, yx0 = p.yx0, yz0 = p.yz0,
			yx1 = p.yx1, yz1 = p.yz1, y = p.y, surface = p.surface, height = p.height}
	end
	local t = smoothing.targets(pads, F.natural, cfg)
	local want = region.targets
	eq(t.x0 == want.bbox.x1 and t.z0 == want.bbox.z1 and t.x1 == want.bbox.x2 and t.z1 == want.bbox.z2, true,
		"targets box = pads grown by margin + radius")
	eq(t.violations, want.violations, "no steps over one node")
	eq(t.walls, want.walls, "no walls")
	local stats, owned = {}, 0
	for z = t.z0, t.z1 do
		for x = t.x0, t.x1 do
			local n = t.pad(x, z)
			local kind = n and t.kind(x, z)
			if kind then
				owned = owned + 1
				local s = stats[kind .. n] or {n = 0, changed = 0, cut = 0, fill = 0}
				stats[kind .. n] = s
				s.n = s.n + 1
				local d = t.at(x, z) - t.was(x, z)
				if d ~= 0 then s.changed = s.changed + 1 end
				if d > 0 then s.fill = s.fill + d elseif d < 0 then s.cut = s.cut - d end
				if kind == "footprint" or kind == "yard" then
					eq(t.at(x, z), group.ground_y, "pad and yard columns end at the pad's y")
				end
			end
		end
	end
	eq(owned, want.owned, "owned column count")
	for key, w in pairs(want.by_kind) do
		local s = stats[key] or {}
		eq(s.n == w.n and s.changed == w.changed and s.cut == w.cut and s.fill == w.fill, true,
			"targets statistics for " .. key)
	end
	for _, c in ipairs(region.columns) do
		if c.kind == "footprint" or c.kind == "yard" or c.kind == "skirt" then
			eq(t.kind(c.x, c.z), c.kind, ("sample (%d,%d) kind"):format(c.x, c.z))
			eq(t.was(c.x, c.z), c.was, ("sample (%d,%d) was"):format(c.x, c.z))
			eq(t.at(c.x, c.z), c.at, ("sample (%d,%d) at"):format(c.x, c.z))
		end
	end

	-- The footprint is not capped: targets() sets it to pad.y however far away.
	local far = {x0 = 0, z0 = 0, x1 = 3, z1 = 3, yx0 = -2, yz0 = -2, yx1 = 5, yz1 = 5, y = 100,
		surface = C.SURFACE_NODE, height = 5}
	local tf = smoothing.targets({far}, function() return 50 end, cfg)
	eq(tf.at(1, 1), 100, "a footprint column is set to pad.y even 50 nodes above the terrain")
	eq(tf.at(-2, -2), 52, "a yard column is clamped to natural + cap")

	-- The config table is not merged with defaults.
	local bad = pcall(smoothing.targets, pads, F.natural, {margin = 2, cap = 2, wall = 4})
	eq(bad, false, "a config without radius raises an error")

	-- A column without a height is left alone (no kind, no target).
	local holey = smoothing.targets(pads, function(x, z)
		if x == 990 and z == -1902 then return nil end
		return F.natural(x, z)
	end, cfg)
	eq(holey.kind(990, -1902), nil, "a footprint column without a height has no kind")
	eq(holey.at(990, -1902), nil, "...and no target")
end
