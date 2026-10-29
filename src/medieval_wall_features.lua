-- Candidate geometry for authored wall features. This module does not write
-- anything; the caller must reserve and inspect the complete volume before
-- placing a schematic.
local M = {}
M.FOUNDATION_DEPTH = 32

local function rotate(x, z, rotation, size)
	if rotation == 0 then return x, z end
	if rotation == 90 then return z, size.x - 1 - x end
	if rotation == 180 then return size.x - 1 - x, size.z - 1 - z end
	return size.z - 1 - z, x
end

-- The corner template's canonical centerlines meet at (3,4), with stubs
-- toward -Z and +X. Its outward diagonal is therefore (-X,+Z).
local rotations = {['-1:1'] = 0, ['1:1'] = 90, ['1:-1'] = 180, ['-1:-1'] = 270}

function M.corner_candidates(wall, ground, entry)
	assert(entry and entry.size.x == 8 and entry.size.z == 8,
		"corner tower attachment contract requires an 8 by 8 template")
	local occupied, openings = {}, {}
	local function key(x, z) return x .. ':' .. z end
	for _, c in ipairs(wall.cells) do occupied[key(c.x, c.z)] = c end
	for _, c in ipairs(wall.openings) do
		for n = 0, 3 do openings[key(c.x + n * c.direction.x, c.z + n * c.direction.z)] = true end
	end
	local out = {}
	for _, c in ipairs(wall.corners) do
		local d = c.direction
		local rotation = rotations[d.x .. ':' .. d.z]
		if rotation then
			local x, z = rotate(3, 4, rotation, entry.size)
			local minx, minz = c.x - x, c.z - z
			local valid = true
			-- Both stubs must meet actual wall cells outside the footprint;
			-- a corner near a road or truncated edge is not eligible.
			-- Short jogs do not warrant a corner tower; both adjoining runs
			-- must continue beyond the attachment stubs.
			for distance = 1, 8 do
				for _, stub in ipairs({{3, 4 - distance}, {3 + distance, 4}}) do
					local sx, sz = rotate(stub[1], stub[2], rotation, entry.size)
					if not occupied[key(minx + sx, minz + sz)] then valid = false end
				end
			end
			for px = minx, minx + 7 do
				for pz = minz, minz + 7 do
					if openings[key(px, pz)] then valid = false end
				end
			end
			if valid then
				out[#out + 1] = {asset = 'wall_tower', rotation = rotation,
					min = {x = minx, y = ground - (entry.ground_offset or 0), z = minz},
					max = {x = minx + 7, y = ground - (entry.ground_offset or 0) + entry.size.y - 1, z = minz + 7},
					corner = c}
			end
		end
	end
	return out
end

local function overlap(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

function M.footprint(feature)
	return {x1 = feature.min.x, z1 = feature.min.z, x2 = feature.max.x, z2 = feature.max.z}
end

function M.remaining_wall(wall, placed_footprints)
	local remaining = {cells = {}, openings = wall.openings}
	for _, cell in ipairs(wall.cells) do
		local covered = false
		for _, rect in ipairs(placed_footprints) do
			if cell.x >= rect.x1 and cell.x <= rect.x2 and cell.z >= rect.z1 and cell.z <= rect.z2 then
				covered = true; break
			end
		end
		if not covered then remaining.cells[#remaining.cells + 1] = cell end
	end
	return remaining
end

-- Candidates arrive in priority order; callers can put gatehouses before
-- towers. A candidate must avoid every authored structure, street, and
-- already accepted feature, even where those overlap only in projection.
function M.select(candidates, structures, streets, protected)
	local selected, footprints = {}, {}
	for _, candidate in ipairs(candidates) do
		local rect, clear = M.footprint(candidate), true
		for _, axis in ipairs({"x", "y", "z"}) do
			if math.abs(candidate.min[axis]) > 31000 or math.abs(candidate.max[axis]) > 31000 then clear = false end
		end
		if candidate.min.y - M.FOUNDATION_DEPTH < -31000 then clear = false end
		for _, structure in ipairs(structures or {}) do
			if structure.rect and overlap(rect, structure.rect) then clear = false; break end
		end
		for _, street in ipairs(streets or {}) do
			if street.rect and overlap(rect, street.rect) then clear = false; break end
		end
		for _, prior in ipairs(footprints) do
			if overlap(rect, prior) then clear = false; break end
		end
		if clear and protected then
			for x = candidate.min.x, candidate.max.x do
				for z = candidate.min.z, candidate.max.z do
					for y = candidate.min.y - M.FOUNDATION_DEPTH, candidate.max.y do
						if protected({x = x, y = y, z = z}) then clear = false; break end
					end
					if not clear then break end
				end
				if not clear then break end
			end
		end
		if clear then selected[#selected + 1] = candidate; footprints[#footprints + 1] = rect end
	end
	return selected, footprints
end

-- Force-placement writes air as well as solid schematic nodes. Require every
-- occupied voxel to be clearable and every foundation column to sit on
-- stable natural support; partial placement is never attempted.
function M.inspect(candidate, region, node_info, protected, natural)
	local foundations = {}
	for x = candidate.min.x, candidate.max.x do
		for z = candidate.min.z, candidate.max.z do
			local supported = false
			for y = candidate.min.y - 1, candidate.min.y - M.FOUNDATION_DEPTH, -1 do
				local name = region.get(x, y, z)
				local info = node_info(name)
				if protected({x = x, y = y, z = z}) then return nil, "protected foundation" end
				if natural(name) and info and info.walkable and not info.liquid and not info.ice then
					if not info.falling then supported = true; break end
					for below = y - 1, candidate.min.y - M.FOUNDATION_DEPTH, -1 do
						local n = region.get(x, below, z)
						local i = node_info(n)
						if not natural(n) or not i or not i.walkable or i.liquid or i.ice then break end
						if not i.falling then supported = true; break end
					end
					if supported then break end
				end
				local water = info and info.liquid and name:find("water", 1, true)
				if name ~= "air" and not water
						and not (info and info.vegetation and not info.tree and not info.ice and not info.liquid) then
					return nil, "foundation obstruction " .. tostring(name)
				end
				foundations[#foundations + 1] = {x = x, y = y, z = z}
			end
			if not supported then return nil, "unsupported foundation" end
			for y = candidate.min.y, candidate.max.y do
				local name = region.get(x, y, z)
				local item = node_info(name)
				if protected({x = x, y = y, z = z}) then return nil, "protected" end
				if name ~= "air" and not (item and item.vegetation and not item.tree
						and not item.liquid and not item.ice)
						and not (y == candidate.min.y and natural(name)) then
					return nil, "obstruction " .. tostring(name)
				end
			end
		end
	end
	return true, foundations
end

return M
