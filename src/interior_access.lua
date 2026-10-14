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
-- pavement. A cell is walkable when it lies on street/square pavement or in
-- any block rectangle and is covered by no obstacle. Obstacles are the full
-- boxes of every non-square site (cathedral, castle, city hall, ...), the
-- jail, services and content buildings: schematic interiors are never used as
-- routes, so a recessed door adds nothing. Touching block rectangles simply
-- share cells and are therefore connected. Alleys are just free cells.
-- Walkable pavement cells are the flood-fill sources (4-neighbourhood).
--
-- Returns (nil, reason) for malformed input or an oversized grid, else
--   {ok, grid = {x1, z1, x2, z2, cells}, free_cells, reachable_cells,
--    sealed_cells, components = list}
-- where every component is a leftover block-interior region that cannot reach
-- pavement: {id, size, bbox = rect, first = {x, z}, blocks = sorted block ids,
-- rects = row spans {x1, x2, z1, z2}}. Components are ordered by their first
-- cell (z, then x), so diagnostics are stable.

local M = {}

M.MAX_CELLS = 4000000

local function is_rect(r)
	return type(r) == "table" and r.x1 and r.z1 and r.x2 and r.z2
end

function M.check(plan, opts)
	if type(plan) ~= "table" or type(plan.blocks) ~= "table" then
		return nil, "plan with blocks required"
	end
	opts = opts or {}
	local sites = plan.sites or {}

	local pave, blocks, solid = {}, {}, {}
	for _, s in ipairs(plan.streets or {}) do
		if is_rect(s.rect) then pave[#pave + 1] = s.rect end
	end
	for _, s in pairs(sites) do
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
	local w, d = x2 - x1 + 1, z2 - z1 + 1
	if w * d > (opts.max_cells or M.MAX_CELLS) then
		return nil, "grid too large: " .. w .. "x" .. d
	end

	-- cell index = (z - z1) * w + (x - x1) + 1; value 0 blocked/outside,
	-- 1 walkable block interior, 2 walkable pavement (source).
	local g = {}
	for i = 1, w * d do g[i] = 0 end
	local function fill(r, v)
		local ax, bx = math.max(r.x1, x1), math.min(r.x2, x2)
		for z = math.max(r.z1, z1), math.min(r.z2, z2) do
			local base = (z - z1) * w - x1 + 1
			for x = ax, bx do
				local i = base + x
				g[i] = v
			end
		end
	end
	for _, r in ipairs(pave) do fill(r, 2) end
	for _, b in ipairs(blocks) do
		local r = b.rect
		local ax, bx = math.max(r.x1, x1), math.min(r.x2, x2)
		for z = math.max(r.z1, z1), math.min(r.z2, z2) do
			local base = (z - z1) * w - x1 + 1
			for x = ax, bx do
				if g[base + x] == 0 then g[base + x] = 1 end
			end
		end
	end
	for _, r in ipairs(solid) do fill(r, 0) end

	-- Flood fill from every walkable pavement cell.
	local seen, stack, sp = {}, {}, 0
	local free, reach = 0, 0
	for i = 1, w * d do
		if g[i] ~= 0 then free = free + 1 end
		if g[i] == 2 then seen[i] = true; sp = sp + 1; stack[sp] = i end
	end
	local function visit(j)
		if g[j] ~= 0 and not seen[j] then
			seen[j] = true; sp = sp + 1; stack[sp] = j
		end
	end
	while sp > 0 do
		local i = stack[sp]; sp = sp - 1
		reach = reach + 1
		local c = (i - 1) % w
		if c > 0 then visit(i - 1) end
		if c < w - 1 then visit(i + 1) end
		if i > w then visit(i - w) end
		if i <= w * (d - 1) then visit(i + w) end
	end

	-- Label what is left, scanning in (z, x) order.
	local components = {}
	local function block_ids(bb)
		local ids = {}
		for _, b in ipairs(blocks) do
			local r = b.rect
			if r.x1 <= bb.x2 and bb.x1 <= r.x2 and r.z1 <= bb.z2 and bb.z1 <= r.z2 then
				ids[#ids + 1] = b.id
			end
		end
		return ids
	end
	for i = 1, w * d do
		if g[i] ~= 0 and not seen[i] then
			seen[i] = true
			local cells, n = {i}, 1
			local k = 1
			while k <= n do
				local j = cells[k]; k = k + 1
				local c = (j - 1) % w
				local nb = {}
				if c > 0 then nb[#nb + 1] = j - 1 end
				if c < w - 1 then nb[#nb + 1] = j + 1 end
				if j > w then nb[#nb + 1] = j - w end
				if j <= w * (d - 1) then nb[#nb + 1] = j + w end
				for _, m in ipairs(nb) do
					if g[m] ~= 0 and not seen[m] then
						seen[m] = true; n = n + 1; cells[n] = m
					end
				end
			end
			local bb = {x1 = math.huge, z1 = math.huge, x2 = -math.huge, z2 = -math.huge}
			local rows = {}
			for _, j in ipairs(cells) do
				local x, z = (j - 1) % w + x1, math.floor((j - 1) / w) + z1
				if x < bb.x1 then bb.x1 = x end
				if x > bb.x2 then bb.x2 = x end
				if z < bb.z1 then bb.z1 = z end
				if z > bb.z2 then bb.z2 = z end
				local row = rows[z]
				if not row then row = {} rows[z] = row end
				row[#row + 1] = x
			end
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
				blocks = block_ids(bb), rects = spans,
			}
		end
	end

	return {ok = #components == 0,
		grid = {x1 = x1, z1 = z1, x2 = x2, z2 = z2, cells = w * d},
		free_cells = free, reachable_cells = reach,
		sealed_cells = free - reach, components = components}
end

return M
