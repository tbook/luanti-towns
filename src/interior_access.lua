-- Towns: validate pedestrian access to leftover block interiors (ticket #54).
-- Pure Lua 5.1: no core.* calls, no requires. Reads a finished plan, never
-- modifies it.
--
--   local access = dofile(".../interior_access.lua")
--   local r, err = access.check(plan, opts)
--
--   plan  planner plan (blocks, streets, sites, reservations, content)
--   opts  {buildings = list of {rect} (default plan.content.buildings),
--          occupied  = extra obstacle rects (e.g. candidate alley-reserved
--                      buildings),
--          max_cells = bounded grid limit (default MAX_CELLS)}
--
-- Model: one node grid over the bounding box of the block rects and the
-- pavement, plus a MARGIN-node ring of open world. Obstacles are the full
-- boxes of every non-square site (cathedral, castle, city hall, ...), the
-- jail, services and content buildings: schematic interiors are never routes,
-- so a recessed door adds nothing. EVERY other cell of the grid is walkable
-- ordinary ground: pavement, block cells and also ground between or outside
-- blocks (open corners stay ordinary ground, as in #42). Touching block
-- rectangles share cells and are connected; alleys are just free cells.
-- Flood-fill sources (4-neighbourhood) are all walkable pavement cells
-- (streets and squares; disconnected pavement is NOT reported) and the margin
-- ring, which stands for the open world beyond the grid. A walkable cell no
-- source reaches is enclosed by obstacle boxes and is reported as sealed.
--
-- Returns (nil, reason) for malformed input or an oversized grid, else
--   {ok, grid = {x1, z1, x2, z2, cells}, free_cells, reachable_cells,
--    sealed_cells, components = list}
-- where every component is a sealed region:
-- {id, size, bbox = rect, first = {x, z}, blocks = sorted ids of the blocks
-- whose cells it contains, rects = row spans {x1, x2, z1, z2}}. Components
-- are ordered by their first cell (z, then x), so diagnostics are stable.

local M = {}

M.MAX_CELLS = 4000000
M.MARGIN = 3

local function is_rect(r)
	return type(r) == "table" and r.x1 and r.z1 and r.x2 and r.z2
end

function M.check(plan, opts)
	if type(plan) ~= "table" or type(plan.blocks) ~= "table" then
		return nil, "plan with blocks required"
	end
	opts = opts or {}

	local pave, blocks, solid = {}, {}, {}
	for _, s in ipairs(plan.streets or {}) do
		if is_rect(s.rect) then pave[#pave + 1] = s.rect end
	end
	for _, s in pairs(plan.sites or {}) do
		if type(s) == "table" and is_rect(s.rect) then
			if s.kind == "square" then pave[#pave + 1] = s.rect
			else solid[#solid + 1] = s.rect end
		end
	end
	for _, b in ipairs(plan.blocks) do
		if is_rect(b.rect) then blocks[#blocks + 1] = b end
	end
	local res = plan.reservations
	if type(res) == "table" then
		if type(res.jail) == "table" and is_rect(res.jail.rect) then
			solid[#solid + 1] = res.jail.rect
		end
		for _, p in ipairs(res.services or {}) do
			if is_rect(p.rect) then solid[#solid + 1] = p.rect end
		end
	end
	local list = opts.buildings
	if list == nil and type(plan.content) == "table" then list = plan.content.buildings end
	for _, b in ipairs(list or {}) do
		if is_rect(b.rect) then solid[#solid + 1] = b.rect end
	end
	for _, r in ipairs(opts.occupied or {}) do
		if is_rect(r) then solid[#solid + 1] = r end
	end

	local x1, z1, x2, z2
	local function grow(r)
		x1 = (not x1 or r.x1 < x1) and r.x1 or x1
		z1 = (not z1 or r.z1 < z1) and r.z1 or z1
		x2 = (not x2 or r.x2 > x2) and r.x2 or x2
		z2 = (not z2 or r.z2 > z2) and r.z2 or z2
	end
	for _, r in ipairs(pave) do grow(r) end
	for _, b in ipairs(blocks) do grow(b.rect) end
	if not x1 then
		return {ok = true, grid = {x1 = 0, z1 = 0, x2 = -1, z2 = -1, cells = 0},
			free_cells = 0, reachable_cells = 0, sealed_cells = 0, components = {}}
	end
	local m = M.MARGIN
	x1, z1, x2, z2 = x1 - m, z1 - m, x2 + m, z2 + m
	local w, d = x2 - x1 + 1, z2 - z1 + 1
	if w * d > (opts.max_cells or M.MAX_CELLS) then
		return nil, "grid too large: " .. w .. "x" .. d
	end

	-- cell index = (z - z1) * w + (x - x1) + 1.
	-- g: 0 obstacle, 1 walkable, 2 walkable source (pavement or margin).
	local g, owner = {}, {}
	for z = 0, d - 1 do
		local margin_row = z < m or z >= d - m
		for x = 0, w - 1 do
			local i = z * w + x + 1
			owner[i] = false
			g[i] = (margin_row or x < m or x >= w - m) and 2 or 1
		end
	end
	local function each(r, fn)
		local ax, bx = math.max(r.x1, x1), math.min(r.x2, x2)
		for z = math.max(r.z1, z1), math.min(r.z2, z2) do
			local base = (z - z1) * w - x1 + 1
			for x = ax, bx do fn(base + x) end
		end
	end
	for _, r in ipairs(pave) do each(r, function(i) g[i] = 2 end) end
	for _, b in ipairs(blocks) do
		each(b.rect, function(i) if not owner[i] then owner[i] = b.id end end)
	end
	for _, r in ipairs(solid) do each(r, function(i) g[i] = 0 end) end

	-- Flood fill from every source cell.
	local seen, stack, sp = {}, {}, 0
	local free, reach = 0, 0
	for i = 1, w * d do
		seen[i] = false
		if g[i] ~= 0 then free = free + 1 end
	end
	for i = 1, w * d do
		if g[i] == 2 then seen[i] = true; sp = sp + 1; stack[sp] = i end
	end
	local function neighbours(i, out)
		local n, c = 0, (i - 1) % w
		if c > 0 then n = n + 1; out[n] = i - 1 end
		if c < w - 1 then n = n + 1; out[n] = i + 1 end
		if i > w then n = n + 1; out[n] = i - w end
		if i <= w * (d - 1) then n = n + 1; out[n] = i + w end
		return n
	end
	local nb = {}
	while sp > 0 do
		local i = stack[sp]; sp = sp - 1
		reach = reach + 1
		for k = 1, neighbours(i, nb) do
			local j = nb[k]
			if g[j] ~= 0 and not seen[j] then
				seen[j] = true; sp = sp + 1; stack[sp] = j
			end
		end
	end

	-- Label what is left, scanning in (z, x) order.
	local components = {}
	for i = 1, w * d do
		if g[i] ~= 0 and not seen[i] then
			seen[i] = true
			local cells, n, k = {i}, 1, 1
			while k <= n do
				local j = cells[k]; k = k + 1
				for q = 1, neighbours(j, nb) do
					local o = nb[q]
					if g[o] ~= 0 and not seen[o] then
						seen[o] = true; n = n + 1; cells[n] = o
					end
				end
			end
			local bb = {x1 = math.huge, z1 = math.huge, x2 = -math.huge, z2 = -math.huge}
			local rows, ids, idlist = {}, {}, {}
			for _, j in ipairs(cells) do
				local x, z = (j - 1) % w + x1, math.floor((j - 1) / w) + z1
				if x < bb.x1 then bb.x1 = x end
				if x > bb.x2 then bb.x2 = x end
				if z < bb.z1 then bb.z1 = z end
				if z > bb.z2 then bb.z2 = z end
				local row = rows[z]
				if not row then row = {} rows[z] = row end
				row[#row + 1] = x
				local id = owner[j]
				if id and not ids[id] then ids[id] = true; idlist[#idlist + 1] = id end
			end
			table.sort(idlist)
			local spans = {}
			for z = bb.z1, bb.z2 do
				local row = rows[z]
				if row then
					table.sort(row)
					local s = row[1]
					for q = 2, #row + 1 do
						if q > #row or row[q] ~= row[q - 1] + 1 then
							spans[#spans + 1] = {x1 = s, x2 = row[q - 1], z1 = z, z2 = z}
							s = row[q]
						end
					end
				end
			end
			components[#components + 1] = {
				id = #components + 1, size = n, bbox = bb,
				first = {x = (i - 1) % w + x1, z = math.floor((i - 1) / w) + z1},
				blocks = idlist, rects = spans,
			}
		end
	end

	return {ok = #components == 0,
		grid = {x1 = x1, z1 = z1, x2 = x2, z2 = z2, cells = w * d},
		free_cells = free, reachable_cells = reach,
		sealed_cells = free - reach, components = components}
end

return M
