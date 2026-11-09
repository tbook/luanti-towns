-- Roman aqueduct planner (issue #417, step 1): src/aqueduct.lua on synthetic
-- height fields. Loaded by tests/run.lua with the shared check helper:
--   loadfile("tests/aqueduct_tests.lua")(eq)
local eq = ...
local aq = dofile("src/aqueduct.lua")
local C = aq.CONSTANTS

local BOUNDS = {x1 = 0, z1 = 0, x2 = 20, z2 = 40}
local plan = {bounds = BOUNDS, boundary = {rects = {BOUNDS}}}

-- Every cell is solid terrain unless `fn` says otherwise.
local function field(fn)
	return function(x, z)
		local y, kind = fn(x, z)
		return y, kind or "solid"
	end
end

-- Ground at 10 that rises `rise` blocks over `run` blocks east of the town
-- (x > 20). The edge column x = 21 is the aqueduct's town end (line column 0)
-- and the peak is the highest column, x = 20 + run (line column run - 1).
local function east(rise, run)
	return field(function(x)
		local d = math.min(math.max(x - 20, 0), run)
		return 10 + math.floor(d * rise / run)
	end)
end

local function inside_bounds(x, z)
	return x >= BOUNDS.x1 and x <= BOUNDS.x2 and z >= BOUNDS.z1 and z <= BOUNDS.z2
end

local function index(list)
	local map = {}
	for _, c in ipairs(list) do map[c.x .. ":" .. c.y .. ":" .. c.z] = c end
	return map
end

local function max_pier(profile)
	local m = 0
	for _, col in ipairs(profile.columns) do
		if col.pier then m = math.max(m, col.bottom_y - 1 - col.ground) end
	end
	return m
end

-- Constants: the values from issue #417 (pier-and-channel redesign).
eq(C.MAX_LENGTH, 100, "max length")
eq(C.MIN_LENGTH, 24, "min length")
eq(C.MIN_RISE, 6, "min rise")
eq(C.PIER_PITCH, 10, "pier pitch")
eq(C.PIER_SIZE, 3, "pier size")
eq(C.PIER_GAP, 7, "pier gap")
eq(C.DROP_EVERY, C.PIER_PITCH, "drop every equals the pier pitch")
eq(C.SOURCE_COUNT, 4, "source count")
eq(C.SIDE_SLAB_LENGTH, 5, "side slab length")
eq(C.MAX_PIER, 22, "max pier")
eq(C.WIDTH, 3, "width")
eq(C.PIER_SPACING, nil, "old pier spacing is gone")

-- Candidates: one line per side and lateral offset alongside the edge.
-- The 20 x 40 town has 39 offsets on the east and west edges, 19 on north and south.
local lines = aq.candidates(plan)
eq(#lines, 2 * 39 + 2 * 19, "candidate count")
local east_first
for _, line in ipairs(lines) do
	if line.side == "+x" and line.offset == 0 then east_first = line end
end
eq(east_first.start, 21, "east line starts outside the town")
eq(east_first.length, C.MAX_LENGTH, "candidate length")
eq(east_first.rect.x1, 21, "east strip rect x1")
eq(east_first.rect.x2, 120, "east strip rect x2")
eq(east_first.rect.z1, 0, "east strip rect z1")
eq(east_first.rect.z2, C.WIDTH - 1, "east strip rect z2")

-- A hill on one side is chosen: the east ramp rises 14 blocks, all other sides are flat.
local ranked = aq.choose(lines, east(14, 50))
eq(ranked[1].line.side, "+x", "hill side is chosen")
eq(ranked[1].rise, 14, "rise of the best line")
eq(ranked[1].peak, 49, "peak column of the best line")
eq(ranked[1].line.offset, 0, "ties rank by lateral offset")

-- Rise below MIN_RISE is skipped; exactly MIN_RISE is kept.
eq(#aq.choose(lines, east(5, 50)), 0, "rise below MIN_RISE is skipped")
eq(aq.choose(lines, east(6, 50))[1].line.side, "+x", "rise of MIN_RISE is kept")
local none, why_none = aq.plan_aqueduct(plan, east(5, 50))
eq(none, nil, "no aqueduct for a small rise")
eq(type(why_none), "string", "small rise gives a reason")

-- Off-centre line: a footprint beside the hill blocks the centred strip
-- (offsets 15..23 with the margin), so a line further along the edge is used.
local blocker = {{x1 = 60, z1 = 16, x2 = 70, z2 = 22}}
local centre
for _, line in ipairs(lines) do
	if line.side == "+x" and line.offset == 18 then centre = line end
end
eq(aq.profile(centre, east(14, 50), blocker), nil, "centred line is blocked by the footprint")
local off = aq.plan_aqueduct(plan, east(14, 50), blocker)
eq(off.side, "+x", "off-centre line is chosen")
eq(off.offset ~= 18, true, "chosen line is not centred")
eq(off.offset, 0, "first unblocked offset is chosen")

-- Valley: tall piers where the ground drops below the channel. A 7-block dip
-- between x = 30 and x = 36 makes the piers there taller than on flat ground
-- (a deeper dip pushes them past MAX_PIER and trims the line instead).
local flat = aq.plan_aqueduct(plan, east(14, 50))
local valley = aq.plan_aqueduct(plan, field(function(x)
	local y = 10 + math.floor(math.min(math.max(x - 20, 0), 50) * 14 / 50)
	if x >= 30 and x <= 36 then y = y - 7 end
	return y
end))
eq(valley ~= nil, true, "valley aqueduct is planned")
-- Peak 49 has r = 9, so the end moves to column 4 (r = 5): a half arch.
eq(valley.profile.town_n, 4, "valley end moves to a whole pier or half arch")
eq(max_pier(valley.profile) > max_pier(flat.profile), true, "valley piers are taller")
eq(max_pier(valley.profile) >= 12, true, "valley piers reach down into the dip")

-- Piers taller than MAX_PIER trim the town end; the result still stays within MAX_PIER.
local steep = aq.plan_aqueduct(plan, east(40, 60))
eq(steep ~= nil, true, "steep hill is planned after trimming")
eq(steep.profile.town_n > 0, true, "steep hill trims the town end")
eq(max_pier(steep.profile) <= C.MAX_PIER, true, "trimmed piers stay within MAX_PIER")

-- Water rejects: at the source end it blocks the line, next to the town it trims.
local function water_at(xs)
	return field(function(x)
		local y = 10 + math.floor(math.min(math.max(x - 20, 0), 50) * 14 / 50)
		if xs[x] then return y, "water" end
		return y
	end)
end
local water_hill = aq.plan_aqueduct(plan, water_at({[70] = true}))
eq(water_hill, nil, "water at the hill end rejects the line")
local water_town, why_water = aq.plan_aqueduct(plan, water_at({[21] = true}))
eq(water_town ~= nil, true, "water next to the town is trimmed, not rejected")
-- Water trims to column 1 (r = 8), then the end moves outward to column 4 (r = 5).
eq(water_town and water_town.profile.town_n, 4, "water at the town end moves the end to r = 5")
eq(why_water, nil, "a trimmed result has no reason")

-- Footprint trims the town end. The footprint sits on the first columns of
-- the offset-0 strip; the margin pushes the town end past it.
local trimmed = aq.plan_aqueduct(plan, east(14, 50), {{x1 = 22, z1 = 0, x2 = 23, z2 = 4}})
eq(trimmed.side, "+x", "footprint near the town keeps the side")
eq(trimmed.profile.town_n, 4, "footprint trims the town end past its margin")
eq(trimmed.spout.x, 25, "spout moves with the trimmed town end")

-- Channel drops 1 block every DROP_EVERY blocks toward the town.
local base = aq.plan_aqueduct(plan, east(14, 50)).profile
local cols = base.columns
local drops_ok = true
for i = 1, #cols - C.DROP_EVERY do
	if cols[i + C.DROP_EVERY].channel_y - cols[i].channel_y ~= 1 then drops_ok = false end
end
eq(drops_ok, true, "channel drops 1 per DROP_EVERY")
eq(cols[#cols].channel_y - cols[1].channel_y, math.floor((base.peak - base.town_n) / C.DROP_EVERY),
	"total channel drop over the line")
eq(cols[#cols].channel_y, base.source.y, "channel at the source is the source height")

-- Piers: 3 blocks of column at each pitch of 10 from the source end, so the
-- first column is the source column itself. Each column tops out at cb - 1.
local pier_count, pier_pattern_ok = 0, true
for _, col in ipairs(cols) do
	local s = base.peak - col.n
	local expect_pier = s % C.PIER_PITCH < C.PIER_SIZE
	if col.pier ~= expect_pier then pier_pattern_ok = false end
	if col.pier then pier_count = pier_count + 1 end
end
eq(pier_count > 0, true, "piers exist on the rising line")
eq(pier_pattern_ok, true, "piers at 3 of every 10 columns from the source end")
eq(cols[#cols].pier, true, "source column carries a pier")

-- Spout: one flowing node, outside the town.
local result = aq.plan_aqueduct(plan, east(14, 50))
eq(inside_bounds(result.spout.x, result.spout.z), false, "spout is outside the town")
local map = index(result.changes)
local spout = map[result.spout.x .. ":" .. result.spout.y .. ":" .. result.spout.z]
eq(spout and spout.name, aq.FLOW, "spout is flowing water")
local flowing = 0
for _, c in ipairs(result.changes) do
	if c.name == aq.FLOW then flowing = flowing + 1 end
end
eq(flowing, 1, "exactly one flowing node")

-- Changes: source water in the channel, cobble walls and slabs, a source box
-- at the hill end, and a write box that covers every change.
local allowed = {[aq.AIR] = true, [aq.WALL] = true, [aq.SLAB] = true, [aq.SIDE_SLAB] = true, [aq.SOURCE] = true, [aq.FLOW] = true}
local names, sources, unexpected = {}, 0, 0
for _, c in ipairs(result.changes) do
	names[c.name] = true
	if c.name == aq.SOURCE then sources = sources + 1 end
	if not allowed[c.name] then unexpected = unexpected + 1 end
end
eq(names[aq.WALL], true, "cobble used")
eq(names[aq.SLAB], true, "top slabs used (arches)")
eq(sources > 0, true, "channel holds water source nodes")
eq(unexpected, 0, "only the aqueduct's own node names")
local box_ok = true
for _, c in ipairs(result.changes) do
	local b = result.box
	if c.x < b.min.x or c.x > b.max.x or c.y < b.min.y or c.y > b.max.y or c.z < b.min.z or c.z > b.max.z then
		box_ok = false
	end
end
eq(box_ok, true, "write box covers every change")
local plug = map[(result.source.x + 1) .. ":" .. result.source.y .. ":" .. result.source.z]
eq(plug and plug.name, aq.WALL, "cobble source box closes the hill end")

-- Below MIN_LENGTH is skipped: a 20-block rise to the hill gives a 20-block line.
eq(aq.plan_aqueduct(plan, east(14, 20)), nil, "result below MIN_LENGTH is skipped")
local _, why_short = aq.plan_aqueduct(plan, east(14, 20))
eq(why_short:find("MIN_LENGTH", 1, true) ~= nil, true, "short line gives a MIN_LENGTH reason")
eq(aq.plan_aqueduct(plan, east(14, 26)) ~= nil, true, "a 26-block line is kept")

-- At most one aqueduct: hills on both east and west still give one result.
local both = field(function(x)
	local d = math.max(math.min(math.max(x - 20, 0), 50), math.min(math.max(-x, 0), 50))
	return 10 + math.floor(d * 14 / 50)
end)
eq(#aq.choose(lines, both) > 1, true, "two sides qualify")
local one = aq.plan_aqueduct(plan, both)
eq(type(one.side), "string", "a single result is returned")
eq(one.side, "+x", "tie between sides goes to the first side in order")

-- Deterministic: the same inputs give the same changes.
local again = aq.plan_aqueduct(plan, east(14, 50))
local same = #again.changes == #result.changes and again.side == result.side
	and again.offset == result.offset
for i, c in ipairs(result.changes) do
	local d = again.changes[i]
	if not d or d.x ~= c.x or d.y ~= c.y or d.z ~= c.z or d.name ~= c.name or d.param2 ~= c.param2 then
		same = false
	end
end
eq(same, true, "planning is deterministic")

-- Other sides: a hill on -x, +z or -z is mirrored. Cells follow the line's
-- direction, and the spout and source box land on the expected world columns.
-- The town end is column 0 at the edge plus one, so the spout is at start + town_n.
local function hill_on(side, rise, run)
	local dist_of = {["+x"] = function(x) return x - 20 end, ["-x"] = function(x) return -x end,
		["+z"] = function(_, z) return z - 40 end, ["-z"] = function(_, z) return -z end}
	return field(function(x, z)
		local d = math.min(math.max(dist_of[side](x, z), 0), run)
		return 10 + math.floor(d * rise / run)
	end)
end
local mirror_cases = {
	{side = "-x", dir = {x = -1, z = 0}, start = -1, spout = {-5, 1}, plug = {-51, 1}, cell3 = {-4, 1}},
	{side = "+z", dir = {x = 0, z = 1}, start = 41, spout = {1, 45}, plug = {1, 91}, cell3 = {1, 44}},
	{side = "-z", dir = {x = 0, z = -1}, start = -1, spout = {1, -5}, plug = {1, -51}, cell3 = {1, -4}},
}
for _, case in ipairs(mirror_cases) do
	local label = case.side .. ": "
	local r = aq.plan_aqueduct(plan, hill_on(case.side, 14, 50))
	eq(r ~= nil, true, label .. "hill is planned")
	if r then
		local line = r.profile.line
		eq(r.side, case.side, label .. "side")
		eq(line.dir.x, case.dir.x, label .. "direction x")
		eq(line.dir.z, case.dir.z, label .. "direction z")
		eq(line.start, case.start, label .. "start coordinate")
		eq(r.profile.town_n, 4, label .. "town end moved to r = 5 (peak 49)")
		local x3, z3 = aq.cell(line, 3, 1)
		eq(x3, case.cell3[1], label .. "cell x at column 3, lateral 1")
		eq(z3, case.cell3[2], label .. "cell z at column 3, lateral 1")
		eq(r.spout.x, case.spout[1], label .. "spout x")
		eq(r.spout.z, case.spout[2], label .. "spout z")
		eq(inside_bounds(r.spout.x, r.spout.z), false, label .. "spout outside the town")
		local m = index(r.changes)
		local spout = m[r.spout.x .. ":" .. r.spout.y .. ":" .. r.spout.z]
		eq(spout and spout.name, aq.FLOW, label .. "spout is flowing water")
		local plug = m[case.plug[1] .. ":" .. r.source.y .. ":" .. case.plug[2]]
		eq(plug and plug.name, aq.WALL, label .. "source box at the plug column")
		local plug_top = m[case.plug[1] .. ":" .. (r.source.y + 1) .. ":" .. case.plug[2]]
		eq(plug_top and plug_top.name, aq.WALL, label .. "source box is two high")
	end
end

-- A footprint on the source side (over the hill, short of the source box column)
-- rejects every line on that side.
local _, why_source = aq.plan_aqueduct(plan, east(14, 50), {{x1 = 60, z1 = 0, x2 = 69, z2 = 40}})
eq(why_source ~= nil and why_source:find("source end", 1, true) ~= nil, true,
	"footprint on the source side rejects the candidates")

-- Peak at the last column: the ground rises to x = 120 (line column 99) and
-- nowhere higher, so the peak must be searched only up to column 98.
local last = field(function(x)
	return 10 + math.floor(math.min(math.max(x - 20, 0), 100) * 14 / 100)
end)
local last_result = aq.plan_aqueduct(plan, last)
eq(last_result ~= nil, true, "ramp to the last column still plans")
if last_result then
	eq(last_result.profile.peak <= C.MAX_LENGTH - 2, true, "peak is never the last column")
	local inside = true
	for l = 0, C.WIDTH - 1 do
		local px, pz = aq.cell(last_result.profile.line, last_result.profile.peak + 1, l)
		local rc = last_result.profile.line.rect
		if px < rc.x1 or px > rc.x2 or pz < rc.z1 or pz > rc.z2 then inside = false end
	end
	eq(inside, true, "source box column lies inside the strip")
end

-- A nil surface value blocks its column: the town end is trimmed past it.
-- (profile() is called directly: choose() drops a line whose centre column is nil.)
local nil_at_40 = field(function(x)
	if x == 40 then return nil end
	return 10 + math.floor(math.min(math.max(x - 20, 0), 50) * 14 / 50)
end)
local nil_profile = aq.profile(east_first, nil_at_40)
eq(nil_profile ~= nil, true, "line with a nil column still profiles")
-- Trim to column 20 (r = 9), then the end moves outward to column 24 (r = 5).
eq(nil_profile and nil_profile.town_n, 24, "nil surface value trims past its column, end at r = 5")

-- Trimmed under MIN_RISE: the untrimmed rise is 14, but water on the town side
-- trims the line to where the ground is 19 and the peak is 24 (a rise of 5).
local function plateau(water_to)
	return field(function(x)
		local y
		if x <= 50 then y = 10
		elseif x <= 70 then y = 10 + math.floor((x - 50) * 9 / 20)
		else y = 19 + math.floor(math.min(x - 70, 40) * 5 / 40) end
		if water_to and x <= water_to then return y, "water" end
		return y
	end)
end
local plateau_plain = aq.plan_aqueduct(plan, plateau(nil))
eq(plateau_plain ~= nil and plateau_plain.profile.town_n, 4, "plateau without water: end at r = 5")
local plateau_trim, why_plateau = aq.plan_aqueduct(plan, plateau(69))
eq(plateau_trim, nil, "trimmed rise below MIN_RISE is rejected")
eq(why_plateau ~= nil and why_plateau:find("MIN_RISE", 1, true) ~= nil, true, "trimmed rise gives a MIN_RISE reason")

-- A blocked source box (water or a footprint on the column past the peak) rejects.
local water_box = field(function(x)
	local y = 10 + math.floor(math.min(math.max(x - 20, 0), 50) * 14 / 50)
	if x == 71 then return y, "water" end
	return y
end)
local _, why_box = aq.plan_aqueduct(plan, water_box)
eq(why_box ~= nil and why_box:find("source box blocked", 1, true) ~= nil, true,
	"water in the source box column rejects")
local _, why_box_fp = aq.plan_aqueduct(plan, east(14, 50), {{x1 = 71, z1 = 0, x2 = 71, z2 = 40}})
eq(why_box_fp ~= nil and why_box_fp:find("source box blocked", 1, true) ~= nil, true,
	"footprint in the source box column rejects")

-- Geometry v2 (PM redesign). A stepped ground profile shows piers, arch depths,
-- clipping, absence over ground and the side lips on one line. Distance from
-- the town edge is d (d = 1 at the first column). Ground: 10 for d <= 29, 21 for
-- d = 30..34, 23 for d = 35..43, 24 from d = 44. The first maximum is d = 44, so
-- the source is line column 43 and s = distance from the source = 44 - d.
local DIST = {["+x"] = function(x) return x - 20 end, ["-x"] = function(x) return -x end,
	["+z"] = function(_, z) return z - 40 end, ["-z"] = function(_, z) return -z end}
local function stepped_on(side)
	return field(function(x, z)
		local d = DIST[side](x, z)
		if d <= 29 then return 10 end
		if d <= 34 then return 21 end
		if d <= 43 then return 23 end
		return 24
	end)
end

local function by_s(profile)
	local map = {}
	for _, col in ipairs(profile.columns) do map[col.s] = col end
	return map
end

local stepped = aq.plan_aqueduct(plan, stepped_on("+x"))
eq(stepped ~= nil, true, "stepped hill is planned")
local P = stepped.profile
eq(P.peak, 43, "stepped source is line column 43")
eq(P.town_n, 0, "stepped line keeps the town end")
local S = by_s(P)
local map = index(stepped.changes)
-- Name of the change at column col, lateral l, height y (nil when none).
local function at(col, l, y)
	local g = col.cells[l]
	local c = map[g.x .. ":" .. y .. ":" .. g.z]
	return c and c.name
end

-- Channel step: one block down at each period start, bottom constant inside.
eq(S[9].bottom_y, 24, "period 0 bottom")
eq(S[10].bottom_y, 23, "period 1 bottom is one lower")
eq(S[19].bottom_y, 23, "period 1 bottom holds to its last block")
eq(S[20].bottom_y, 22, "period 2 bottom is one lower again")

-- Piers: 3 x 3 columns from the ground to cb - 1, at s = 10..12 (period 1).
for l = 0, C.WIDTH - 1 do
	eq(at(S[11], l, 22), aq.WALL, "pier fills up to cb - 1 at lateral " .. l)
end
-- Channel cross-section at s = 15 (gap, period 1, cb = 23): solid bottom row,
-- cobble walls at l = 0 and 2 on the water row, open centre.
for l = 0, C.WIDTH - 1 do
	eq(at(S[15], l, 23), aq.WALL, "bottom row is solid at lateral " .. l)
end
eq(at(S[15], 0, 24), aq.WALL, "wall at lateral 0 on the water row")
eq(at(S[15], 2, 24), aq.WALL, "wall at lateral 2 on the water row")
eq(at(S[15], 1, 24), aq.AIR, "centre is open at s = 15 (not a source)")

-- Arch depths across a gap (p = s % 10 - 2): 2, 1, slab, 0, slab, 1, 2 below cb.
-- Period 1: cb = 23, arches at y = 22 and 21. s = 13..14 sit on ground 21, so
-- the arch is clipped there at y = 21.
local profile_expect = {
	[13] = {22, aq.WALL, 21, nil},   -- p = 1, ground 21 clips the second block
	[14] = {22, aq.WALL, 21, nil},   -- p = 2, one block (ground clip at 21)
	[15] = {22, aq.SLAB, 21, nil},   -- p = 3, top slab
	[16] = {22, nil, 21, nil},       -- p = 4, nothing
	[17] = {22, aq.SLAB, 21, nil},   -- p = 5, top slab
	[18] = {22, aq.WALL, 21, nil},   -- p = 6, one block
	[19] = {22, aq.WALL, 21, aq.WALL}, -- p = 7, two blocks
}
for s = 13, 19 do
	local e = profile_expect[s]
	for l = 0, C.WIDTH - 1 do
		eq(at(S[s], l, e[1]), e[2], "arch s=" .. s .. " y=22 lateral " .. l)
		eq(at(S[s], l, e[3]), e[4], "arch s=" .. s .. " y=21 lateral " .. l)
	end
end
-- Absent where the channel sits in the ground (s = 3..9, ground 23 = cb - 1).
for s = 3, 9 do
	for l = 0, C.WIDTH - 1 do
		eq(at(S[s], l, 23), nil, "no arch over ground at s=" .. s)
		eq(at(S[s], l, 22), nil, "no arch below ground at s=" .. s)
	end
end

-- Sources: the first SOURCE_COUNT (4) blocks of each period, centre only.
-- The spout is the town-end column (s = 43) and takes precedence.
local source_ok, open_ok = true, true
for s = 0, 42 do
	local water = S[s].channel_y
	if s % 10 < 4 then
		if at(S[s], 1, water) ~= aq.SOURCE then source_ok = false end
	else
		if at(S[s], 1, water) ~= aq.AIR then open_ok = false end
	end
end
eq(source_ok, true, "sources at the first four blocks of every period")
eq(open_ok, true, "remaining centre cells are open")
eq(at(S[43], 1, S[43].channel_y), aq.FLOW, "spout at the town-end centre")

-- Side lips: bottom-half slab at cb + 2 on both walls for the first 5 blocks of
-- each period, only where that cell is air.
local lip_ok = true
for s = 0, 43 do
	local col = S[s]
	for _, l in ipairs({0, 2}) do
		local want = s % 10 < 5 and col.bottom_y + 2 > col.cells[l].y
		local got = at(col, l, col.bottom_y + 2) == aq.SIDE_SLAB
		if want ~= got then lip_ok = false end
	end
end
eq(lip_ok, true, "side slabs on the first 5 blocks of each period, both walls")
eq(at(S[0], 0, 26), aq.SIDE_SLAB, "side slab at cb + 2 = 26 on the source period")
eq(stepped.box.max.y >= 26, true, "write box includes cb + 2")

-- Late writes: exactly the sources plus the spout, all inside the write box.
local late_sources, late_spouts, late_inside = 0, 0, true
for _, w in ipairs(stepped.late) do
	if w.role == "source" then late_sources = late_sources + 1 end
	if w.role == "spout" then late_spouts = late_spouts + 1 end
	local b = stepped.box
	if w.x < b.min.x or w.x > b.max.x or w.y < b.min.y or w.y > b.max.y or w.z < b.min.z or w.z > b.max.z then
		late_inside = false
	end
end
local want_sources = 0
for s = 0, 42 do if s % 10 < 4 then want_sources = want_sources + 1 end end
eq(late_sources, want_sources, "late sources: first four blocks of each period")
eq(late_spouts, 1, "one late spout")
eq(#stepped.late, want_sources + 1, "late list is exactly sources plus spout")
eq(late_inside, true, "late writes lie inside the write box")

-- SOURCE_COUNT >= PIER_PITCH fills every channel cell; SIDE_SLAB_LENGTH = 0
-- removes the lips. Both are restored afterwards.
C.SOURCE_COUNT = 10
local all_src = aq.changes(P)
local every = true
for s = 0, 42 do
	local name
	for _, c in ipairs(all_src) do
		if c.x == S[s].cells[1].x and c.y == S[s].channel_y and c.z == S[s].cells[1].z then name = c.name end
	end
	if name ~= aq.SOURCE then every = false end
end
C.SOURCE_COUNT = 4
eq(every, true, "SOURCE_COUNT = 10 gives a source in every channel cell")

C.SIDE_SLAB_LENGTH = 0
local no_lips = true
for _, c in ipairs((aq.changes(P))) do
	if c.name == aq.SIDE_SLAB then no_lips = false end
end
C.SIDE_SLAB_LENGTH = 5
eq(no_lips, true, "SIDE_SLAB_LENGTH = 0 removes the side slabs")

-- Orientation: the same geometry on each side, read back through cell().
for _, side in ipairs({"+x", "-x", "+z", "-z"}) do
	local r = aq.plan_aqueduct(plan, stepped_on(side))
	local label = side .. ": "
	eq(r ~= nil and r.side, side, label .. "stepped hill on this side is chosen")
	if r then
		local line = r.profile.line
		local rmap = index(r.changes)
		local ok = true
		for _, col in ipairs(r.profile.columns) do
			local x, z = aq.cell(line, col.n, 1)
			local got = rmap[x .. ":" .. col.channel_y .. ":" .. z]
			local is_spout = col == r.profile.columns[1]
			local is_src = col.s % 10 < 4 and not is_spout
			local want = is_spout and aq.FLOW or (is_src and aq.SOURCE or aq.AIR)
			if not got or got.name ~= want then ok = false end
			local lx, lz = aq.cell(line, col.n, 0)
			local lip = col.s % 10 < 5 and col.bottom_y + 2 > col.ground
			local lip_cell = rmap[lx .. ":" .. (col.bottom_y + 2) .. ":" .. lz]
			if lip and not (lip_cell and lip_cell.name == aq.SIDE_SLAB) then ok = false end
		end
		eq(ok, true, label .. "sources, spout and lips follow the line's cells")
	end
end

-- Pier trimming at MAX_PIER = 22: a deep drop near the town end trims, and no
-- pier column left on the line is taller than MAX_PIER.
local deep = aq.plan_aqueduct(plan, east(50, 60))
eq(deep ~= nil and deep.profile.town_n > 0, true, "pier over MAX_PIER trims the town end")
eq(deep ~= nil and max_pier(deep.profile) <= C.MAX_PIER, true, "piers stay within MAX_PIER after the trim")
eq(aq.plan_aqueduct(plan, east(5, 50)), nil, "min rise still enforced for the stepped geometry")

-- Town end rule (PM follow-up): the last column has r = (peak - town_n) % 10
-- in 2..5 (a whole pier, or a pier with at most a half arch), never a partial
-- pier or more than half an arch. The end only moves toward the source.
local function end_r(pr) return (pr.peak - pr.town_n) % C.PIER_PITCH end
local sweep_plans, sweep_ok = 0, true
for _, side in ipairs({"+x", "-x", "+z", "-z"}) do
	for _, run in ipairs({25, 27, 30, 33, 36, 40, 44, 50, 55}) do
		local r = aq.plan_aqueduct(plan, hill_on(side, 14, run))
		if r then
			sweep_plans = sweep_plans + 1
			local rr = end_r(r.profile)
			if rr < 2 or rr > 5 then sweep_ok = false end
		end
	end
end
eq(sweep_plans >= 30, true, "sweep: most sides and peaks plan")
eq(sweep_ok, true, "sweep: the town end always has r in 2..5 on all four sides")

-- Footprints beside the town trim the end; the moved end never lengthens the
-- line, so it stays at or beyond the trimmed column (k + 2 for a footprint at
-- x = 21 + k, whose margin blocks columns k - 1 .. k + 1).
local fp_ok, fp_outward, fp_n = true, true, 0
for k = 0, 8 do
	local pr = aq.profile(east_first, east(14, 50), {{x1 = 21 + k, z1 = 0, x2 = 21 + k, z2 = 4}})
	if pr then
		fp_n = fp_n + 1
		if end_r(pr) < 2 or end_r(pr) > 5 then fp_ok = false end
		if pr.town_n < k + 2 then fp_outward = false end
	end
end
eq(fp_n, 9, "footprint sweep: every trim still plans")
eq(fp_ok, true, "footprint sweep: the end has r in 2..5")
eq(fp_outward, true, "footprint sweep: the end moves only outward")

-- A line already ending on r = 3 (peak 43) keeps its town end.
local kept = aq.plan_aqueduct(plan, east(14, 44))
eq(kept ~= nil and kept.profile.town_n, 0, "a line already ending on r = 3 is unchanged")

-- The spout sits at the new town-end centre cell.
local moved = aq.plan_aqueduct(plan, east(14, 50))
eq(moved.spout.x, moved.profile.columns[1].x, "spout is at the new town-end column")
eq(moved.spout.x, 21 + moved.profile.town_n, "spout moved with the end")

-- Shortening below MIN_RISE: the untrimmed end sits on a rise of 14, but the
-- moved end (column 4, ground 19) leaves a rise of 5 against the peak of 24.
local shortened = field(function(x)
	local d = math.min(math.max(x - 20, 0), 50)
	if d <= 1 then return 10 end
	if d <= 5 then return 19 end
	if d < 30 then return 19 + math.floor((d - 5) / 5) end
	return 24
end)
local short_pr, short_why = aq.profile(east_first, shortened)
eq(short_pr, nil, "shortening to a rise under MIN_RISE rejects the candidate")
eq(short_why ~= nil and short_why:find("MIN_RISE", 1, true) ~= nil, true, "rise rejection names MIN_RISE")
eq(aq.plan_aqueduct(plan, shortened), nil, "no other candidate passes either")

-- Shortening below MIN_LENGTH: a peak at column 20 (r = 0) moves the end to
-- column 5, leaving 16 blocks.
local short_len = aq.plan_aqueduct(plan, east(14, 21))
eq(short_len, nil, "shortening below MIN_LENGTH rejects the candidate")
