-- Towns: pack one street frontage run with touching schematic boxes
-- (ticket #40). Pure Lua 5.1: no core.* calls, no catalog require; the
-- catalog snapshot, seed and obstacles are all injected.
--
-- Usage: local packer = dofile(".../frontage_packer.lua")(geometry)
--        local result = packer.pack{run=, block=, entries=, seed=, occupied=}
--
--   run       one plan.frontage entry: {id, facing = {x,z}, rect = x1,z1,x2,z2}
--             (the one-node-thick block edge row that borders the street)
--   block     the plan.blocks entry {id, rect}; boxes stay wholly inside it
--   entries   catalog.snapshot()-style table id -> {size, entrance}; iterated
--             in sorted id order. Callers filter by role beforehand.
--   seed      integer; the same inputs and seed give the same result
--   occupied  optional list of inclusive rects {x1,z1,x2,z2} to avoid
--             (earlier placements on other faces, landmarks, reservations)
--
-- Returns {placements = {...}, unused = {...}, placed_length = n}
--   placements  {building_id, block, frontage, rect, rotation, entrance}
--               rect is the full rotated box (inclusive); entrance is the
--               world {x,z} of the door node from geometry.place
--   unused      {rect, length} intervals of the run row not covered by any
--               box, in increasing coordinate order
-- Boxes are placed with zero automatic gap, flush against the run row, in a
-- single orientation (front toward run.facing). Buildings are never
-- stretched, cropped or mirrored. A run nothing fits returns no placements
-- and one unused interval covering the run.

return function(geometry)

local M = {}

-- File front is -Z; rotation that turns it toward a facing vector.
local ROTATION = {
	["0,-1"] = 0, ["-1,0"] = 90, ["0,1"] = 180, ["1,0"] = 270,
}

local MOD = 2147483647

local function new_rng(seed)
	local s = seed % MOD
	for _ = 1, 8 do s = (s * 48271 + 1013904223) % MOD end
	return function(n) -- uniform integer in [1, n]
		s = (s * 48271 + 1013904223) % MOD
		return 1 + math.floor(s * n / MOD)
	end
end

local function intersects(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

-- Clearance occupies the sides and rear of a building, keeping the street
-- face available for its entrance. The schematic rect remains unchanged.
local function reserved_rect(rect, front, clearance)
	if not clearance or clearance <= 0 then return rect end
	local r = {x1 = rect.x1, z1 = rect.z1, x2 = rect.x2, z2 = rect.z2}
	if front.x ~= 0 then
		r.z1, r.z2 = r.z1 - clearance, r.z2 + clearance
		if front.x < 0 then r.x2 = r.x2 + clearance else r.x1 = r.x1 - clearance end
	else
		r.x1, r.x2 = r.x1 - clearance, r.x2 + clearance
		if front.z < 0 then r.z2 = r.z2 + clearance else r.z1 = r.z1 - clearance end
	end
	return r
end

local function is_rect(r)
	return type(r) == "table" and type(r.x1) == "number" and type(r.z1) == "number"
		and type(r.x2) == "number" and type(r.z2) == "number"
		and r.x1 <= r.x2 and r.z1 <= r.z2
end

local function valid_entry(e)
	if type(e) ~= "table" then return false end
	local s, en = e.size, e.entrance
	return type(s) == "table" and type(en) == "table"
		and type(s.x) == "number" and type(s.y) == "number" and type(s.z) == "number"
		and s.x >= 1 and s.z >= 1 and s.x == math.floor(s.x) and s.z == math.floor(s.z)
		and type(en.x) == "number" and en.x >= 0 and en.x < s.x
end

function M.pack(args)
	assert(type(args) == "table", "frontage_packer: args table required")
	local run, block, entries = args.run, args.block, args.entries
	assert(type(run) == "table" and is_rect(run.rect) and type(run.facing) == "table",
		"frontage_packer: malformed run")
	assert(type(block) == "table" and is_rect(block.rect), "frontage_packer: malformed block")
	assert(type(entries) == "table", "frontage_packer: entries required")
	local seed = args.seed
	assert(type(seed) == "number" and seed == math.floor(seed), "frontage_packer: integer seed required")
	local rotation = ROTATION[run.facing.x .. "," .. run.facing.z]
	assert(rotation, "frontage_packer: facing must be an axis unit vector")
	local r, br = run.rect, block.rect
	assert(r.x1 == r.x2 or r.z1 == r.z2, "frontage_packer: run must be one node thick")

	local occupied = {}
	for _, o in ipairs(args.occupied or {}) do
		assert(is_rect(o), "frontage_packer: malformed occupied rect")
		occupied[#occupied + 1] = o
	end

	local ids = {}
	for id, e in pairs(entries) do
		if valid_entry(e) then ids[#ids + 1] = id end
	end
	table.sort(ids)

	-- Along-run axis: x for faces on a z edge, else z.
	local along_x = run.facing.z ~= 0
	local lo = along_x and r.x1 or r.z1
	local hi = along_x and r.x2 or r.z2
	local fx, fz = run.facing.x, run.facing.z

	-- Box rect for a width/depth starting at coordinate c along the run.
	local function box(c, w, d)
		if along_x then
			if fz < 0 then return {x1 = c, x2 = c + w - 1, z1 = r.z1, z2 = r.z1 + d - 1} end
			return {x1 = c, x2 = c + w - 1, z1 = r.z2 - d + 1, z2 = r.z2}
		end
		if fx < 0 then return {x1 = r.x1, x2 = r.x1 + d - 1, z1 = c, z2 = c + w - 1} end
		return {x1 = r.x2 - d + 1, x2 = r.x2, z1 = c, z2 = c + w - 1}
	end

	local function free(b, reserve)
		if reserve.x1 < br.x1 or reserve.x2 > br.x2 or reserve.z1 < br.z1 or reserve.z2 > br.z2 then return false end
		for _, o in ipairs(occupied) do
			if intersects(reserve, o) then return false end
		end
		return true
	end

	local rng = new_rng(seed)
	local placements, unused = {}, {}
	local placed_length = 0
	local gap_start = nil

	local function close_gap(upto)
		if gap_start then
			local rect = along_x
				and {x1 = gap_start, x2 = upto, z1 = r.z1, z2 = r.z2}
				or {x1 = r.x1, x2 = r.x2, z1 = gap_start, z2 = upto}
			unused[#unused + 1] = {rect = rect, length = upto - gap_start + 1}
			gap_start = nil
		end
	end

	local c = lo
	while c <= hi do -- every pass advances c by at least one node
		local cands = {}
		for _, id in ipairs(ids) do
			local s = entries[id].size
			-- Rotation turns file X into the run axis whatever the facing,
			-- so width along the run is always s.x and depth is s.z.
			local w, d = s.x, s.z
			if c + w - 1 <= hi then
				local b = box(c, w, d)
				local reserve = reserved_rect(b, run.facing, entries[id].clearance)
				if free(b, reserve) then cands[#cands + 1] = {id = id, rect = b, reserved_rect = reserve, w = w} end
			end
		end
		if #cands == 0 then
			gap_start = gap_start or c
			c = c + 1
		else
			close_gap(c - 1)
			local pick = cands[rng(#cands)]
			local g = geometry.place(entries[pick.id], {x = pick.rect.x1, y = 0, z = pick.rect.z1}, rotation)
			placements[#placements + 1] = {
				building_id = pick.id, block = block.id, frontage = run.id,
				rect = pick.rect, reserved_rect = pick.reserved_rect, rotation = rotation,
				entrance = {x = g.entrance.x, z = g.entrance.z},
			}
			occupied[#occupied + 1] = pick.reserved_rect
			placed_length = placed_length + pick.w
			c = c + pick.w
		end
	end
	close_gap(hi)

	return {placements = placements, unused = unused, placed_length = placed_length}
end

return M

end
