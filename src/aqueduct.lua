-- Roman aqueduct planner (issue #417, step 1): a procedural pier-and-channel
-- aqueduct that runs straight out from one side of a town toward the highest
-- hill within MAX_LENGTH. Pure Lua: no Minetest globals at load and no world
-- access. Every answer about the world comes from the `surface` and
-- `footprints` arguments, so the same code runs under plain Lua 5.1 tests and
-- in the game. Nothing here writes, and no caller uses this module yet.
--
-- Conventions (shared with the existing modules):
--   rect  {x1, z1, x2, z2}                   inclusive, horizontal
--   box   {min = {x, y, z}, max = {x, y, z}} inclusive
--
-- Geometry. A line starts at the first column outside the town bounds on one
-- side (index n = 0) and runs outward for MAX_LENGTH columns. Each column is
-- WIDTH cells wide (lateral index l = 0..WIDTH-1, from the line's `offset`).
-- Cells 0 and WIDTH-1 are the walls, the others are water.
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
--       FOOTPRINT_MARGIN) or pier taller than MAX_PIER, then checks MIN_LENGTH.
--   aqueduct.changes(profile) -> list of {x, y, z, name, param2}, write box
--   aqueduct.plan_aqueduct(plan, surface, footprints) -> result | nil, reason
--       At most one aqueduct: the best ranked line whose profile passes.
local M = {}

M.CONSTANTS = {
	MAX_LENGTH = 100,
	MIN_LENGTH = 24,
	MIN_RISE = 6,
	DROP_EVERY = 11,
	PIER_SPACING = 4,
	MAX_PIER = 15,
	WIDTH = 5,
	FOOTPRINT_MARGIN = 1,
}
local C = M.CONSTANTS

M.WALL = "mcl_core:cobble"
M.CAP = "mcl_stairs:slab_cobble_top"
M.SOURCE = "mcl_core:water_source"
M.FLOW = "mcl_core:water_flowing"
M.AIR = "air"

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
-- if tied); the channel sits one block above it and drops 1 block every
-- DROP_EVERY blocks toward the town. Columns from the town end up to the source
-- are kept. The town end is trimmed past the last column holding water, an
-- obstruction, a footprint or a pier taller than MAX_PIER; a result shorter
-- than MIN_LENGTH is rejected.
function M.profile(line, surface, footprints)
	local W, P = C.WIDTH, C.PIER_SPACING
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

	local peak, peak_y
	for n = 0, line.length - 1 do
		local y = ground[n][math.floor(W / 2)].y
		if y and (not peak_y or y > peak_y) then peak, peak_y = n, y end
	end
	if not peak then return nil, "no ground" end
	local src = peak_y + 1
	local function channel(n) return src - math.floor((peak - n) / C.DROP_EVERY) end

	-- Why column n cannot be part of the aqueduct, or nil.
	local function blocked(n)
		local cy = channel(n)
		for l = 0, W - 1 do
			local g = ground[n][l]
			if g.kind ~= "solid" then return g.kind end
			if in_footprint(g.x, g.z, footprints) then return "footprint" end
			if n % P == 0 and cy - 2 - g.y > C.MAX_PIER then return "pier" end
		end
	end

	local town_n, why = 0, nil
	for n = 0, peak do
		local r = blocked(n)
		if r then town_n, why = n + 1, r end
	end
	if town_n > peak then return nil, "blocked at the source end (" .. why .. ")" end
	local length = peak - town_n + 1
	if length < C.MIN_LENGTH then
		return nil, "length " .. length .. " below MIN_LENGTH" .. (why and (" after trim (" .. why .. ")") or "")
	end

	local columns = {}
	for n = town_n, peak do
		local cy = channel(n)
		local c = ground[n][math.floor(W / 2)]
		local col = {n = n, x = c.x, z = c.z, ground = c.y, channel_y = cy, cells = ground[n],
			pier = false, cut = false, arch = false}
		for l = 0, W - 1 do
			local g = ground[n][l]
			if n % P == 0 and g.y < cy - 2 then col.pier = true end
			if l >= 1 and l <= W - 2 and g.y >= cy + 1 then col.cut = true end
		end
		col.arch = not col.pier and c.y < cy - 1
		columns[#columns + 1] = col
	end

	local centre = math.floor(W / 2)
	local spout_cell = ground[town_n][centre]
	local source_cell = ground[peak][centre]
	return {
		line = line, peak = peak, town_n = town_n, length = length, columns = columns,
		source = {n = peak, x = source_cell.x, y = src, z = source_cell.z},
		spout = {x = spout_cell.x, y = channel(town_n), z = spout_cell.z},
	}
end

-- Node writes for a profile: cut air, piers, the cobble deck, walls with a slab
-- cap, the water channel, the spout and the cobble source box. Each cell is
-- written at most once. Returns the list sorted by x, y, z, and its box.
function M.changes(profile)
	local W, P = C.WIDTH, C.PIER_SPACING
	local line = profile.line
	local cells, list = {}, {}
	local function put(x, y, z, name, param2)
		local k = x .. ":" .. y .. ":" .. z
		if not cells[k] then list[#list + 1] = k end
		cells[k] = {x = x, y = y, z = z, name = name, param2 = param2 or 0}
	end

	for _, col in ipairs(profile.columns) do
		local cy, n = col.channel_y, col.n
		for l = 0, W - 1 do
			local g = col.cells[l]
			local x, z = g.x, g.z
			if l >= 1 and l <= W - 2 then
				for y = cy + 1, g.y do put(x, y, z, M.AIR) end
			end
			if n % P == 0 then
				for y = g.y + 1, cy - 2 do put(x, y, z, M.WALL) end
			end
			put(x, cy - 1, z, M.WALL)
			if l == 0 or l == W - 1 then
				put(x, cy, z, M.WALL)
				put(x, cy + 1, z, M.CAP)
			else
				put(x, cy, z, M.SOURCE)
			end
		end
	end

	-- Spout: one flowing node in the town-end channel. Its side cells are
	-- capped so that the spout is the only outflow.
	local first = profile.columns[1]
	local centre = math.floor(W / 2)
	for l = 1, W - 2 do
		local g = first.cells[l]
		put(g.x, first.channel_y, g.z, l == centre and M.FLOW or M.WALL)
	end

	-- Source box: cobble closes the hill end of the channel.
	local src = profile.source.y
	for l = 0, W - 1 do
		local x, z = M.cell(line, profile.peak + 1, l)
		put(x, src, z, M.WALL)
		put(x, src + 1, z, M.WALL)
	end

	table.sort(list, function(a, b)
		local p, q = cells[a], cells[b]
		if p.x ~= q.x then return p.x < q.x end
		if p.y ~= q.y then return p.y < q.y end
		return p.z < q.z
	end)
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
	return out, box
end

-- The one aqueduct for a town, or nil and a reason.
function M.plan_aqueduct(plan, surface, footprints)
	local ranked = M.choose(M.candidates(plan), surface)
	if #ranked == 0 then return nil, "no side rises at least " .. C.MIN_RISE .. " blocks" end
	local reasons = {}
	for _, r in ipairs(ranked) do
		local profile, why = M.profile(r.line, surface, footprints)
		if profile then
			local list, box = M.changes(profile)
			return {side = r.line.side, offset = r.line.offset, rise = r.rise, profile = profile,
				source = profile.source, spout = profile.spout, length = profile.length,
				changes = list, box = box}
		end
		reasons[#reasons + 1] = r.line.side .. "@" .. r.line.offset .. ": " .. why
	end
	return nil, "no candidate passed: " .. table.concat(reasons, "; ")
end

return M
