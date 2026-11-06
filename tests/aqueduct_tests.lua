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
-- (x > 20). The edge column x = 21 is the aqueduct's town end and the peak is
-- at x = 20 + run (the line's last column before MAX_LENGTH).
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
		if col.pier then m = math.max(m, col.channel_y - 2 - col.ground) end
	end
	return m
end

-- Constants: the starting values from issue #417.
eq(C.MAX_LENGTH, 100, "max length")
eq(C.MIN_LENGTH, 24, "min length")
eq(C.MIN_RISE, 6, "min rise")
eq(C.DROP_EVERY, 11, "drop every")
eq(C.PIER_SPACING, 4, "pier spacing")
eq(C.MAX_PIER, 15, "max pier")
eq(C.WIDTH, 5, "width")

-- Candidates: one line per side and lateral offset alongside the edge.
-- The 20 x 40 town has 37 offsets on the east and west edges, 17 on north and south.
local lines = aq.candidates(plan)
eq(#lines, 2 * 37 + 2 * 17, "candidate count")
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
eq(valley.profile.town_n, 0, "valley within MAX_PIER keeps the town end")
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
eq(water_town and water_town.profile.town_n, 1, "water at the town end trims one column")
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

-- Piers stand only on PIER_SPACING columns, and at least one exists on this line.
local pier_count, pier_spacing_ok = 0, true
for _, col in ipairs(cols) do
	if col.pier then
		pier_count = pier_count + 1
		if col.n % C.PIER_SPACING ~= 0 then pier_spacing_ok = false end
	end
end
eq(pier_count > 0, true, "piers exist on the rising line")
eq(pier_spacing_ok, true, "piers only on PIER_SPACING columns")

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

-- Changes: source water in the channel, cobble walls and slab caps, a source box
-- at the hill end, and a write box that covers every change.
local allowed = {[aq.AIR] = true, [aq.WALL] = true, [aq.CAP] = true, [aq.SOURCE] = true, [aq.FLOW] = true}
local names, sources, unexpected = {}, 0, 0
for _, c in ipairs(result.changes) do
	names[c.name] = true
	if c.name == aq.SOURCE then sources = sources + 1 end
	if not allowed[c.name] then unexpected = unexpected + 1 end
end
eq(names[aq.WALL], true, "cobble used")
eq(names[aq.CAP], true, "slab caps used")
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
