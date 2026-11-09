-- Roman aqueduct planner (issue #417): a procedural pier-and-channel aqueduct
-- that runs straight out from one side of a town toward the highest hill within
-- MAX_LENGTH. Pure Lua: no Minetest globals at load and no world access. Every
-- answer about the world comes from the `surface` and `footprints` arguments, so
-- the same code runs under plain Lua 5.1 tests and in the game. Nothing here
-- writes; src/aqueduct_build.lua applies the result.
--
-- Conventions (shared with the existing modules):
--   rect  {x1, z1, x2, z2}                   inclusive, horizontal
--   box   {min = {x, y, z}, max = {x, y, z}} inclusive
--
-- Geometry. A line starts at the first column outside the town bounds on one
-- side (column n = 0, the town end) and runs outward for MAX_LENGTH columns.
-- Each column is WIDTH = 3 cells wide; lateral index l = 0..2 with the centre
-- at l = 1 (the spec's l = -1, 0, +1). Let s = distance from the source end
-- (s = peak - n), period k = floor(s / PIER_PITCH), and cb = channel bottom.
--   * cb is constant within each period and drops 1 block per period toward
--     the town (DROP_EVERY = PIER_PITCH).
--   * Piers: 3 x 3 cobble columns at s % PIER_PITCH < PIER_SIZE, from the ground
--     up to cb - 1. Gaps of PIER_GAP columns sit between them.
--   * Channel: bottom row y = cb is cobble across all 3 cells. Water row
--     y = cb + 1 has cobble walls at l = 0 and l = 2 and an open centre l = 1.
--     Sources sit in the centre for the first SOURCE_COUNT blocks of each period
--     (s % PIER_PITCH < SOURCE_COUNT); the rest of the centre stays open. The
--     spout is the centre cell of the town-end column.
--   * Side lips: for the first SIDE_SLAB_LENGTH blocks of each period, a
--     bottom-half slab on each side wall at y = cb + 2, where that cell is air.
--   * Arches: in each gap, a position p = 1..PIER_GAP below the channel bottom
--     (ARCH below), clipped by the ground.
--   * Town end: after trimming, the end moves toward the source (never
--     lengthens) until r = (peak - n) % PIER_PITCH is 2..5: a whole pier, or a
--     pier with at most a half arch. Never a partial pier or more than half an arch.
--
-- API: local aqueduct = dofile("src/aqueduct.lua")
--   aqueduct.CONSTANTS
--   aqueduct.candidates(plan) -> lines
--       One line per side and lateral offset that lies fully alongside the
--       edge of plan.bounds. Each line: {side, dir, start, offset, length, rect}.
--   aqueduct.cell(line, n, l) -> x, z
--   aqueduct.choose(lines, surface) -> ranked list of {line, rise, peak, peak_y}
--       Lines whose centre column rises at least MIN_RISE above the town end,
--       highest rise first. surface(x, z) returns y and kind; kind "solid" is
--       terrain or vegetation (replaced), anything else is an obstruction.
--   aqueduct.profile(line, surface, footprints) -> profile | nil, reason
--       Trims the town end past any water, obstruction, footprint (with a
--       FOOTPRINT_MARGIN) or pier taller than MAX_PIER, then checks MIN_LENGTH
--       and MIN_RISE.
--   aqueduct.changes(profile) -> list of {x, y, z, name, param2}, write box,
--       late list (sources and spout, each with role "source" or "spout")
--   aqueduct.plan_aqueduct(plan, surface, footprints) -> result | nil, reason
--       At most one aqueduct: the best ranked line whose profile passes.
local M = {}

M.CONSTANTS = {
	MAX_LENGTH = 100,
	MIN_LENGTH = 24,
	MIN_RISE = 6,
	PIER_PITCH = 10,
	PIER_SIZE = 3,
	PIER_GAP = 7,
	DROP_EVERY = 10,
	SOURCE_COUNT = 4,
	SIDE_SLAB_LENGTH = 5,
	MAX_PIER = 22,
	WIDTH = 3,
	FOOTPRINT_MARGIN = 1,
}
local C = M.CONSTANTS

M.WALL = "mcl_core:cobble"
M.SLAB = "mcl_stairs:slab_cobble_top"
M.SIDE_SLAB = "mcl_stairs:slab_cobble"
M.SOURCE = "mcl_core:water_source"
M.FLOW = "mcl_core:water_flowing"
M.AIR = "air"

-- Arch fill by position p = 1..PIER_GAP across a gap: {dy, name} rows below the
-- channel bottom (dy = -1 is y = cb - 1). Symmetric, so the count direction
-- does not matter.
M.ARCH = {
	[1] = {{-1, M.WALL}, {-2, M.WALL}},
	[2] = {{-1, M.WALL}},
	[3] = {{-1, M.SLAB}},
	[4] = {},
	[5] = {{-1, M.SLAB}},
	[6] = {{-1, M.WALL}},
	[7] = {{-1, M.WALL}, {-2, M.WALL}},
}

-- Sides in a fixed order, so ranking ties resolve the same way every time.
local SIDES = {
	{side = "+x", dir = {x = 1, z = 0}},
	{side = "-x", dir = {x = -1, z = 0}},
	{side = "+z", dir = {x = 0, z = 1}},
	{side = "-z", dir = {x = 0, z = -1}},
}

-- World cell of column n, lateral cell l on a line.
function M.cell(line, n, l)
	local d = line.dir
	if d.x ~= 0 then return line.start + d.x * n, line.offset + l end
	return line.offset + l, line.start + d.z * n
end

-- Every straight line that fits alongside one side of the town edge, at each
-- lateral offset whose strip lies wholly within the edge's extent.
function M.candidates(plan)
	local b, out = plan.bounds, {}
	if not b then return out end
	local W, L = C.WIDTH, C.MAX_LENGTH
	for index, s in ipairs(SIDES) do
		local d = s.dir
		local lo, hi, start
		if d.x ~= 0 then
			lo, hi = b.z1, b.z2
			start = d.x > 0 and b.x2 + 1 or b.x1 - 1
		else
			lo, hi = b.x1, b.x2
			start = d.z > 0 and b.z2 + 1 or b.z1 - 1
		end
		for offset = lo, hi - W + 1 do
			local line = {side = s.side, side_index = index, dir = d, start = start,
				offset = offset, length = L}
			-- Strip rect: the two far corners of the line bound it.
			local x1, z1 = M.cell(line, 0, 0)
			local x2, z2 = M.cell(line, L - 1, W - 1)
			line.rect = {x1 = math.min(x1, x2), z1 = math.min(z1, z2),
				x2 = math.max(x1, x2), z2 = math.max(z1, z2)}
			out[#out + 1] = line
		end
	end
	return out
end

-- Rank lines by rise: the centre column's highest point above its town end.
-- Lines that rise less than MIN_RISE are dropped.
function M.choose(lines, surface)
	local ranked = {}
	for _, line in ipairs(lines) do
		local start_y, peak, peak_y = nil, nil, nil
		for n = 0, line.length - 1 do
			local x, z = M.cell(line, n, math.floor(C.WIDTH / 2))
			local y = surface(x, z)
			if not y then start_y = nil; break end
			if n == 0 then start_y = y end
			if not peak_y or y > peak_y then peak, peak_y = n, y end
		end
		if start_y and peak_y - start_y >= C.MIN_RISE then
			ranked[#ranked + 1] = {line = line, rise = peak_y - start_y, peak = peak, peak_y = peak_y}
		end
	end
	table.sort(ranked, function(a, b)
		if a.rise ~= b.rise then return a.rise > b.rise end
		if a.line.side_index ~= b.line.side_index then return a.line.side_index < b.line.side_index end
		return a.line.offset < b.line.offset
	end)
	return ranked
end

local function in_footprint(x, z, footprints)
	local m = C.FOOTPRINT_MARGIN
	for _, r in ipairs(footprints or {}) do
		if x >= r.x1 - m and x <= r.x2 + m and z >= r.z1 - m and z <= r.z2 + m then return true end
	end
	return false
end

-- Profile of one line. The source is the highest centre column (the first one
-- if tied). The channel bottom at the source is the ground there; it drops 1
-- block per period toward the town. Columns from the town end up to the source
-- are kept. The town end is trimmed past the last column holding water, an
-- obstruction, a footprint or a pier taller than MAX_PIER; a result shorter
-- than MIN_LENGTH, or with less than MIN_RISE left after the trim, is rejected.
function M.profile(line, surface, footprints)
	local W, P = C.WIDTH, C.PIER_PITCH
	local mid = math.floor(W / 2)
	local ground = {}
	for n = 0, line.length - 1 do
		local row = {}
		for l = 0, W - 1 do
			local x, z = M.cell(line, n, l)
			local y, kind = surface(x, z)
			row[l] = {x = x, z = z, y = y, kind = y and kind or "unknown"}
		end
		ground[n] = row
	end

	-- The peak is searched only up to the second-last column, so the source
	-- box column (peak + 1) always lies inside the strip.
	local peak, peak_y
	for n = 0, line.length - 2 do
		local y = ground[n][mid].y
		if y and (not peak_y or y > peak_y) then peak, peak_y = n, y end
	end
	if not peak then return nil, "no ground" end
	local base = peak_y
	local function bottom(n) return base - math.floor((peak - n) / C.DROP_EVERY) end
	local function pier_column(n) return (peak - n) % P < C.PIER_SIZE end

	-- Why column n cannot be part of the aqueduct, or nil.
	local function blocked(n)
		local cb = bottom(n)
		local pier = pier_column(n)
		for l = 0, W - 1 do
			local g = ground[n][l]
			if g.kind ~= "solid" then return g.kind end
			if in_footprint(g.x, g.z, footprints) then return "footprint" end
			if pier and cb - 1 - g.y > C.MAX_PIER then return "pier" end
		end
	end

	-- The source box column must be solid ground clear of footprints. It is
	-- not trimmed, so a blocked box rejects the candidate.
	for l = 0, W - 1 do
		local g = ground[peak + 1][l]
		if g.kind ~= "solid" then return nil, "source box blocked (" .. g.kind .. ")" end
		if in_footprint(g.x, g.z, footprints) then return nil, "source box blocked (footprint)" end
	end

	local town_n, why = 0, nil
	for n = 0, peak do
		local r = blocked(n)
		if r then town_n, why = n + 1, r end
	end
	if town_n > peak then return nil, "blocked at the source end (" .. why .. ")" end
	-- The town end finishes with a whole pier (r = 2) or a pier and at most a
	-- half arch (r = 3..5), where r = (peak - n) % PIER_PITCH counts from the
	-- source end. Moving the end toward the source only shortens the line, so
	-- trimmed cells stay trimmed. Applied before the length and rise checks.
	local function end_ok(n)
		local r = (peak - n) % P
		return r >= 2 and r <= 5
	end
	while town_n <= peak and not end_ok(town_n) do town_n = town_n + 1 end
	if town_n > peak then return nil, "no whole pier or half arch at the town end" end
	local length = peak - town_n + 1
	if length < C.MIN_LENGTH then
		return nil, "length " .. length .. " below MIN_LENGTH" .. (why and (" after trim (" .. why .. ")") or "")
	end
	-- MIN_RISE is checked again after the trim: a plateau near the peak height
	-- may be all that is left at the new town end.
	local rise = peak_y - ground[town_n][mid].y
	if rise < C.MIN_RISE then
		return nil, "rise " .. rise .. " after trim below MIN_RISE"
	end

	local columns = {}
	for n = town_n, peak do
		local c = ground[n][mid]
		columns[#columns + 1] = {n = n, s = peak - n, x = c.x, z = c.z, ground = c.y,
			bottom_y = bottom(n), channel_y = bottom(n) + 1, pier = pier_column(n), cells = ground[n]}
	end
	local spout_cell = ground[town_n][mid]
	local source_cell = ground[peak][mid]
	return {
		line = line, peak = peak, town_n = town_n, length = length, columns = columns,
		source = {n = peak, x = source_cell.x, y = base + 1, z = source_cell.z},
		spout = {x = spout_cell.x, y = bottom(town_n) + 1, z = spout_cell.z},
	}
end

-- Node writes for a profile. Each cell is written at most once, in this order:
-- cut air above the channel centre, piers, the bottom row, the water row (walls
-- or open centre), arches, then the sources, spout and source box on top.
-- Returns the list sorted by x, y, z, its write box, and the late list: the
-- source nodes and the spout, which the adapter re-sets after the commit so the
-- engine starts the flow.
function M.changes(profile)
	local W, P = C.WIDTH, C.PIER_PITCH
	local mid = math.floor(W / 2)
	local line = profile.line
	local cells, list = {}, {}
	local function put(x, y, z, name, param2)
		local k = x .. ":" .. y .. ":" .. z
		if not cells[k] then list[#list + 1] = k end
		cells[k] = {x = x, y = y, z = z, name = name, param2 = param2 or 0}
	end
	local late = {}

	for i, col in ipairs(profile.columns) do
		local cb, water = col.bottom_y, col.channel_y
		for l = 0, W - 1 do
			local g = col.cells[l]
			local x, z = g.x, g.z
			if l == mid then
				for y = water, math.max(water, g.y) do put(x, y, z, M.AIR) end
			end
			if col.pier and g.y < cb - 1 then
				for y = g.y + 1, cb - 1 do put(x, y, z, M.WALL) end
			end
			put(x, cb, z, M.WALL)
			if l ~= mid then put(x, water, z, M.WALL) end
		end

		-- Arches hang below the bottom in gaps, where the channel is over air.
		if not col.pier and col.ground < cb - 1 then
			local p = col.s % P - C.PIER_SIZE + 1
			for _, a in ipairs(M.ARCH[p]) do
				for l = 0, W - 1 do
					local g = col.cells[l]
					if cb + a[1] > g.y then put(g.x, cb + a[1], g.z, a[2]) end
				end
			end
		end

		-- Sources in the open centre: the first SOURCE_COUNT blocks of each period,
		-- counted from the source end. The town-end column is the spout instead.
		if i > 1 and col.s % P < C.SOURCE_COUNT then
			local g = col.cells[mid]
			put(g.x, water, g.z, M.SOURCE)
			late[#late + 1] = {x = g.x, y = water, z = g.z, name = M.SOURCE, param2 = 0, role = "source"}
		end

		-- Half-block lips on the side walls for the first SIDE_SLAB_LENGTH blocks
		-- after each step down. Only in air: a cell with ground at or above it is
		-- left as terrain.
		if col.s % P < C.SIDE_SLAB_LENGTH then
			for l = 0, W - 1 do
				if l ~= mid then
					local g = col.cells[l]
					if cb + 2 > g.y then put(g.x, cb + 2, g.z, M.SIDE_SLAB) end
				end
			end
		end
	end

	-- Spout: one flowing node in the town-end channel centre. Its walls are
	-- already in place, so it is the only outflow.
	local spout = profile.spout
	put(spout.x, spout.y, spout.z, M.FLOW)
	late[#late + 1] = {x = spout.x, y = spout.y, z = spout.z, name = M.FLOW, param2 = 0, role = "spout"}

	-- Source box: cobble closes the hill end of the channel.
	local src = profile.source.y
	for l = 0, W - 1 do
		local x, z = M.cell(line, profile.peak + 1, l)
		put(x, src, z, M.WALL)
		put(x, src + 1, z, M.WALL)
	end

	local function sorted(keys_of)
		table.sort(keys_of, function(a, b)
			if a.x ~= b.x then return a.x < b.x end
			if a.y ~= b.y then return a.y < b.y end
			return a.z < b.z
		end)
		return keys_of
	end

	local out, box = {}, nil
	for i, k in ipairs(list) do
		local c = cells[k]
		out[i] = c
		if not box then
			box = {min = {x = c.x, y = c.y, z = c.z}, max = {x = c.x, y = c.y, z = c.z}}
		else
			box.min.x, box.min.y, box.min.z = math.min(box.min.x, c.x), math.min(box.min.y, c.y), math.min(box.min.z, c.z)
			box.max.x, box.max.y, box.max.z = math.max(box.max.x, c.x), math.max(box.max.y, c.y), math.max(box.max.z, c.z)
		end
	end
	sorted(out)
	return out, box, sorted(late)
end

-- The one aqueduct for a town, or nil and a reason.
function M.plan_aqueduct(plan, surface, footprints)
	local ranked = M.choose(M.candidates(plan), surface)
	if #ranked == 0 then return nil, "no side rises at least " .. C.MIN_RISE .. " blocks" end
	local reasons = {}
	for _, r in ipairs(ranked) do
		local profile, why = M.profile(r.line, surface, footprints)
		if profile then
			local list, box, late = M.changes(profile)
			return {side = r.line.side, offset = r.line.offset, rise = r.rise, profile = profile,
				source = profile.source, spout = profile.spout, length = profile.length,
				changes = list, box = box, late = late}
		end
		reasons[#reasons + 1] = r.line.side .. "@" .. r.line.offset .. ": " .. why
	end
	return nil, "no candidate passed: " .. table.concat(reasons, "; ")
end

return M
