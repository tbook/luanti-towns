-- Candidate geometry for authored wall features. This module does not write
-- anything; the caller must reserve and inspect the complete volume before
-- placing a schematic.
local M = {}
M.FOUNDATION_DEPTH = 32
M.MAX_CUT_HEIGHT = 2
-- Towers may replace dirt throughout their authored footprint. Keeping this
-- narrower than natural terrain support avoids cutting into stone or other
-- landscape materials when a tower sits against a hillside.
local TOWER_REPLACEABLE_TERRAIN = {
	["mcl_core:dirt"] = true,
	["mcl_core:dirt_with_grass"] = true,
	["mcl_core:dirt_with_snow"] = true,
	["mcl_core:dirt_with_grass_snow"] = true,
	["mcl_core:coarse_dirt"] = true,
	["mcl_core:podzol"] = true,
}

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

-- Add the straight-run tower sample at evenly spaced points along sufficiently
-- long uninterrupted runs. The wall centerline is three nodes from either
-- side of its 7x7 capture, and its tie-ins occupy both ends of that line.
function M.inline_candidates(wall, ground, entry)
	assert(entry and entry.size.x == 7 and entry.size.z == 7,
		"inline tower attachment contract requires a 7 by 7 template")
	local out = {}
	local function touches_only_run(candidate, run)
		local function in_footprint(x, z)
			return x >= candidate.min.x and x <= candidate.max.x
				and z >= candidate.min.z and z <= candidate.max.z
		end
		for _, cell in ipairs(wall.cells or {}) do
			if in_footprint(cell.x, cell.z) then
				local direction = cell.direction or {}
				local fixed = run.direction.x ~= 0 and cell.x or cell.z
				local along = run.direction.x ~= 0 and cell.z or cell.x
				local belongs = not cell.corner
					and direction.x == run.direction.x and direction.z == run.direction.z
					and fixed == run.fixed and along >= run.first and along <= run.last
				if not belongs then return false end
			end
		end
		-- Openings include their four wall-depth approach cells. Keep the whole
		-- schematic clear of them, even when the opening split this same run.
		for _, opening in ipairs(wall.openings or {}) do
			for depth = 0, 3 do
				local x = opening.x + opening.direction.x * depth
				local z = opening.z + opening.direction.z * depth
				if in_footprint(x, z) then return false end
			end
		end
		return true
	end
	local runs = {}
	for _, run in ipairs(wall.runs or {}) do runs[#runs + 1] = run end
	-- wall.runs is sorted with string keys; sort numerically here so translated
	-- plans keep the same candidate order across negative and positive origins.
	table.sort(runs, function(a, b)
			local ax, bx = a.direction.x ~= 0, b.direction.x ~= 0
			if ax ~= bx then return ax end
			if a.direction.x ~= b.direction.x then return a.direction.x < b.direction.x end
			if a.direction.z ~= b.direction.z then return a.direction.z < b.direction.z end
			if a.fixed ~= b.fixed then return a.fixed < b.fixed end
			return a.first < b.first
		end)
	for _, run in ipairs(runs) do
		local length = run.last - run.first + 1
		local count = math.max(0, math.floor(length / 20) - 1)
		for i = 1, count do
			-- Distribute tower centers across the run, rounding to a stable
			-- node coordinate. The count rule leaves enough room at each end.
			local center = run.first + length * i / (count + 1)
			local first = math.floor(center + 0.5) - 3
			local rotation, minx, minz
			if run.direction.x ~= 0 then
				-- Local +Z follows world +Z (or -Z); local x=3 is the core.
				-- The authored outer parapet faces canonical -X, so flip it
				-- toward +X walls and leave it as-authored for -X walls.
				rotation = run.direction.x > 0 and 180 or 0
				minx, minz = run.fixed - 3, first
			else
				-- Rotate local +Z onto world X while keeping local x=3 on
				-- the wall centerline at the run's fixed Z coordinate.
				rotation = run.direction.z > 0 and 90 or 270
				minx, minz = first, run.fixed - 3
			end
			local offset = entry.ground_offset or 0
			local candidate = {
				asset = "wall_tower_inline", rotation = rotation,
				min = {x = minx, y = ground - offset, z = minz},
				max = {x = minx + 6, y = ground - offset + entry.size.y - 1, z = minz + 6},
				run = run,
			}
			if touches_only_run(candidate, run) then out[#out + 1] = candidate end
		end
	end
	return out
end

-- Shared candidate construction for planning reservations and actual placement.
function M.candidates(wall, ground, entries, walls, missing_join)
 local candidates = {}
 for _, spec in ipairs({{id = "wall_gatehouse", gate = true}, {id = "wall_tower"},
	{id = "wall_tower_inline", inline = true}}) do
  local entry = entries[spec.id]
  if entry then
   local found = spec.gate and walls.gatehouse_candidates(wall, ground, entry)
    or (spec.inline and M.inline_candidates(wall, ground, entry))
    or M.corner_candidates(wall, ground, entry)
   for _, candidate in ipairs(found) do
    if spec.gate then
     candidate.min, candidate.max = candidate.bounds.min, candidate.bounds.max
     candidate.reserve_rect = M.footprint(candidate)
     for _, c in ipairs(candidate.outside_approach or {}) do
      for n = 0, 3 do
       local x, z = c.x + c.direction.x * n, c.z + c.direction.z * n
       local r = candidate.reserve_rect
       r.x1, r.x2 = math.min(r.x1, x), math.max(r.x2, x)
       r.z1, r.z2 = math.min(r.z1, z), math.max(r.z2, z)
      end
     end
     local r = candidate.reserve_rect
     if candidate.direction.x ~= 0 then r.z1, r.z2 = r.z1 - 1, r.z2 + 1
     else r.x1, r.x2 = r.x1 - 1, r.x2 + 1 end
    end
    if not spec.gate or M.gate_joins(candidate, wall) then
     candidates[#candidates + 1] = candidate
    elseif missing_join then
     missing_join(candidate)
    end
   end
  end
 end
 return candidates
end

local function overlap(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

local function replaceable_terrain(candidate, y, name, natural)
	-- Keep the existing shallow cut for natural terrain on all wall features.
	-- Towers can additionally replace dirt throughout their authored volume.
	return (y <= candidate.min.y + M.MAX_CUT_HEIGHT and natural(name))
		or ((candidate.asset == "wall_tower" or candidate.asset == "wall_tower_inline")
			and TOWER_REPLACEABLE_TERRAIN[name] == true)
end

function M.footprint(feature)
	return {x1 = feature.min.x, z1 = feature.min.z, x2 = feature.max.x, z2 = feature.max.z}
end

-- Both authored end stubs must meet a planned wall column immediately outside
-- the footprint. Otherwise an irregular boundary would leave a dangling gate.
function M.gate_join_cells(candidate, wall)
	local a, b
	if candidate.direction.x ~= 0 then
		a = {x = candidate.wall_plane.x, z = candidate.min.z - 1}
		b = {x = candidate.wall_plane.x, z = candidate.max.z + 1}
	else
		a = {x = candidate.min.x - 1, z = candidate.wall_plane.z}
		b = {x = candidate.max.x + 1, z = candidate.wall_plane.z}
	end
	local found_a, found_b
	for _, cell in ipairs(wall.cells) do
		if cell.x == a.x and cell.z == a.z then found_a = cell end
		if cell.x == b.x and cell.z == b.z then found_b = cell end
	end
	if found_a and found_b then return {found_a, found_b} end
end

function M.gate_joins(candidate, wall)
	return M.gate_join_cells(candidate, wall) ~= nil
end

function M.remaining_wall(wall, placed_footprints)
	local remaining = {cells = {}, openings = {}, feature_footprints = placed_footprints}
	for _, cell in ipairs(wall.cells) do
		local covered = false
		for _, rect in ipairs(placed_footprints) do
			if cell.x >= rect.x1 and cell.x <= rect.x2 and cell.z >= rect.z1 and cell.z <= rect.z2 then
				covered = true; break
			end
		end
		if not covered then remaining.cells[#remaining.cells + 1] = cell end
	end
	for _, opening in ipairs(wall.openings) do
		local covered = false
		for _, rect in ipairs(placed_footprints) do
			if opening.x >= rect.x1 and opening.x <= rect.x2 and opening.z >= rect.z1 and opening.z <= rect.z2 then
				covered = true; break
			end
		end
		if not covered then remaining.openings[#remaining.openings + 1] = opening end
	end
	return remaining
end

-- Candidates arrive in priority order; callers can put gatehouses before
-- towers. A candidate must avoid every authored structure, street, and
-- already accepted feature, even where those overlap only in projection.
function M.select(candidates, structures, streets, protected, ignore_limits)
	local selected, footprints = {}, {}
	for _, candidate in ipairs(candidates) do
		local rect, clear = candidate.reserve_rect or M.footprint(candidate), true
        if not ignore_limits then
			for _, axis in ipairs({"x", "y", "z"}) do
				if math.abs(candidate.min[axis]) > 31000 or math.abs(candidate.max[axis]) > 31000 then clear = false end
			end
			if math.abs(rect.x1) > 31000 or math.abs(rect.x2) > 31000
					or math.abs(rect.z1) > 31000 or math.abs(rect.z2) > 31000 then clear = false end
			if candidate.min.y - M.FOUNDATION_DEPTH < -31000 then clear = false end
        end
		for _, structure in ipairs(structures or {}) do
			if structure.rect and overlap(rect, structure.rect) then clear = false; break end
		end
		for _, street in ipairs(streets or {}) do
			if street.rect and overlap(rect, street.rect)
					and not (candidate.street ~= nil and street.id == candidate.street) then clear = false; break end
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
	-- Towers may clear tree-group logs throughout their complete authored
	-- volume and foundation. Gatehouses keep the narrower wall behavior: logs
	-- can be part of a building, so they remain an obstruction there.
	local clear_tree = candidate.asset == "wall_tower" or candidate.asset == "wall_tower_inline"
	local function vegetation(info)
		return info and not info.liquid and not info.ice
			and ((info.vegetation and (clear_tree or not info.tree)) or (clear_tree and info.tree))
	end
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
				if name ~= "air" and not water and not vegetation(info) then
					return nil, "foundation obstruction " .. tostring(name)
				end
				foundations[#foundations + 1] = {x = x, y = y, z = z}
			end
			if not supported then return nil, "unsupported foundation" end
			for y = candidate.min.y, candidate.max.y do
				local name = region.get(x, y, z)
				local item = node_info(name)
				if protected({x = x, y = y, z = z}) then return nil, "protected" end
				local road = candidate.street_rect and y == candidate.min.y and name == candidate.material
					and x >= candidate.street_rect.x1 and x <= candidate.street_rect.x2
					and z >= candidate.street_rect.z1 and z <= candidate.street_rect.z2
				if name ~= "air" and not road and not vegetation(item)
					and not replaceable_terrain(candidate, y, name, natural) then
					return nil, ("obstruction %s at (%d,%d,%d)"):format(
						tostring(name), x, y, z)
				end
			end
		end
	end
	return true, foundations
end

return M
