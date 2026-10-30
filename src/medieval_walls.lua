-- Pure geometry for the first phase of medieval walls. Coordinates are world
-- coordinates; the plan is independent of the town layout's random stream.
local M = {}
function M.clear_metadata(core, changes)
	local cleaned = {}
	for _, change in ipairs(changes) do
		if change.clearance or change.clear_metadata then
			local k = change.x .. ":" .. change.y .. ":" .. change.z
			if not cleaned[k] then
				cleaned[k] = true
				local pos = {x = change.x, y = change.y, z = change.z}
				if type(core.get_meta) == "function" then
					local meta = core.get_meta(pos)
					if meta and type(meta.from_table) == "function" then meta:from_table({}) end
				end
				if type(core.get_node_timer) == "function" then
					local timer = core.get_node_timer(pos)
					if timer and type(timer.stop) == "function" then timer:stop() end
				end
			end
		end
	end
end
local directions = {{x = 1, z = 0}, {x = -1, z = 0}, {x = 0, z = 1}, {x = 0, z = -1}}
local function key(x, z) return x .. ":" .. z end
local function clearance_positions(c)
	local out, extent = {}, M.CLEARANCE
	if c.corner then
		for x = 0, extent do for z = 0, extent do out[#out + 1] = {
			x = c.x + (c.direction.x < 0 and -x or x),
			z = c.z + (c.direction.z < 0 and -z or z)} end end
	else
		for distance = 0, extent do out[#out + 1] = {
			x = c.x + c.direction.x * distance, z = c.z + c.direction.z * distance} end
	end
	return out
end
local function inside(rects, x, z)
	for _, r in ipairs(rects) do
		if x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 then return true end
	end
	return false
end

function M.selected(plan, force)
	if plan.town_type ~= "medieval" then return false end
	if force ~= nil then return force end
	-- A separate multiplicative hash leaves the planner's random stream intact.
	return ((plan.seed + 1073741824) * 48271 % 2147483647) % 5 ~= 0
end

-- Each exposed unit edge contributes its adjacent exterior node. Only roads
-- that actually touch an exposed edge become openings; internal endpoints do
-- not project through cathedral or castle compounds.
function M.plan(plan, force)
	if not M.selected(plan, force) then return nil end
	local rects, cells, openings = plan.boundary.rects, {}, {}
	local function road(x, z, d)
		for _, s in ipairs(plan.streets) do
			local r = s.rect
			if x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 then
				-- A crossing follows the road's long axis, not its side.
				if d.x ~= 0 and r.x2 - r.x1 >= r.z2 - r.z1
						or d.z ~= 0 and r.z2 - r.z1 >= r.x2 - r.x1 then return s end
			end
		end
	end
	for _, r in ipairs(rects) do
		for x = r.x1, r.x2 do
			for z = r.z1, r.z2 do
				for _, d in ipairs(directions) do
					local ox, oz = x + d.x, z + d.z
					if not inside(rects, ox, oz) then
						local k = key(ox, oz)
						local s = road(x, z, d)
						if s then openings[k] = {x = ox, z = oz, direction = d, street = s.id, kind = s.kind,
							material = s.material,
							street_rect = {x1 = s.rect.x1, z1 = s.rect.z1,
								x2 = s.rect.x2, z2 = s.rect.z2}}
						else cells[k] = cells[k] or {x = ox, z = oz, direction = d} end
					end
				end
				-- Convex vertices need the diagonal cell to join the two
				-- exterior edge lines into a continuous corner.
				for _, dx in ipairs({-1, 1}) do
					for _, dz in ipairs({-1, 1}) do
						if not inside(rects, x + dx, z) and not inside(rects, x, z + dz)
								and not inside(rects, x + dx, z + dz) then
							local k = key(x + dx, z + dz)
							cells[k] = cells[k] or {x = x + dx, z = z + dz,
								direction = {x = dx, z = dz}, corner = true}
						end
					end
				end
			end
		end
	end
	for _, gap in pairs(openings) do
		for distance = 0, 3 do
			cells[key(gap.x + gap.direction.x * distance, gap.z + gap.direction.z * distance)] = nil
		end
	end
	local list, gaps = {}, {}
	for _, v in pairs(cells) do list[#list + 1] = v end
	for _, v in pairs(openings) do gaps[#gaps + 1] = v end
	local function order(a, b) return a.x == b.x and a.z < b.z or a.x < b.x end
	table.sort(list, order); table.sort(gaps, order)
	local corners, groups = {}, {}
	for _, c in ipairs(list) do
		if c.corner then corners[#corners + 1] = c
		else
			local d = c.direction
			local fixed = d.x ~= 0 and c.x or c.z
			local k = d.x .. ":" .. d.z .. ":" .. fixed
			groups[k] = groups[k] or {direction = d, fixed = fixed, values = {}}
			groups[k].values[#groups[k].values + 1] = d.x ~= 0 and c.z or c.x
		end
	end
	local runs = {}
	for _, group in pairs(groups) do
		table.sort(group.values)
		local run
		for _, value in ipairs(group.values) do
			if not run or value ~= run.last + 1 then
				run = {direction = group.direction, fixed = group.fixed, first = value, last = value}
				runs[#runs + 1] = run
			else run.last = value end
		end
	end
	table.sort(runs, function(a, b)
		local ka = a.direction.x .. ":" .. a.direction.z .. ":" .. a.fixed .. ":" .. a.first
		local kb = b.direction.x .. ":" .. b.direction.z .. ":" .. b.fixed .. ":" .. b.first
		return ka < kb
	end)
	return {cells = list, runs = runs, corners = corners, openings = gaps}
end

-- Return world placement candidates for the authored primary-road gatehouse.
-- `wall.openings` is the road-crossing plan: each entry is one column across
-- the six-node road where the wall would otherwise stand. The template's
-- four-node passage is centered on those six columns. Placement is only a
-- candidate here; the generation writer must validate protection, terrain,
-- overlap and foundation safety before reserving/masking anything.
--
-- Candidate bounds cover the complete schematic volume, including its
-- captured foundation and air cells, because place_schematic writes both.
function M.gatehouse_candidates(wall, ground, entry)
	assert(type(wall) == "table" and type(wall.openings) == "table", "wall openings are required")
	assert(type(entry) == "table" and type(entry.size) == "table", "gatehouse catalog entry is required")
	local groups = {}
	for _, opening in ipairs(wall.openings) do
		if opening.kind == "principal" and opening.street ~= nil then
			local d = opening.direction
			local normal = d.x .. ":" .. d.z
			local fixed = d.x ~= 0 and opening.x or opening.z
			local key = tostring(opening.street) .. ":" .. normal .. ":" .. fixed
			local group = groups[key]
			if not group then
				group = {street = opening.street, direction = {x = d.x, z = d.z}, fixed = fixed,
					kind = opening.kind, material = opening.material, columns = {}}
				groups[key] = group
			end
			group.columns[#group.columns + 1] = opening
		end
	end
	local candidates = {}
	-- Each entry maps canonical +Z (the gatehouse's outward face) to the
	-- indicated world normal, with the associated canonical +X tangent.
	local orientation = {
		["0:1"] = {rotation = 0, nx = 0, nz = 1, tx = 1, tz = 0},
		["1:0"] = {rotation = 90, nx = 1, nz = 0, tx = 0, tz = -1},
		["0:-1"] = {rotation = 180, nx = 0, nz = -1, tx = -1, tz = 0},
		["-1:0"] = {rotation = 270, nx = -1, nz = 0, tx = 0, tz = 1},
	}
	local function sort_openings(a, b)
		local ta = a.direction.x ~= 0 and a.z or a.x
		local tb = b.direction.x ~= 0 and b.z or b.x
		return ta < tb
	end
	local function add_candidate(group, o, openings, low, high)
		local first = openings[1]
		local plane_x, plane_z = first.x, first.z
		-- Passage local x=6..9 has center 7.5. Center it in the
		-- six-node road (cell-center 2.5) in world coordinates. Compute
		-- pos as the rotated footprint's minimum corner, matching
		-- core.place_schematic and geometry.place conventions.
		local center = (low + high) / 2
		local local_x, local_z
		if o.rotation == 0 then local_x, local_z = 7.5, 3
		elseif o.rotation == 90 then local_x, local_z = 3, entry.size.x - 1 - 7.5
		elseif o.rotation == 180 then local_x, local_z = entry.size.x - 1 - 7.5, entry.size.z - 1 - 3
		else local_x, local_z = entry.size.z - 1 - 3, 7.5 end
		local target_x = o.tx ~= 0 and center or plane_x
		local target_z = o.tz ~= 0 and center or plane_z
		if o.nx ~= 0 then target_x = plane_x end
		if o.nz ~= 0 then target_z = plane_z end
		local origin = {x = target_x - local_x, y = ground, z = target_z - local_z}
		local sx, sz = entry.size.x, entry.size.z
		if o.rotation == 90 or o.rotation == 270 then sx, sz = sz, sx end
		candidates[#candidates + 1] = {
			asset = entry.id or "wall_gatehouse",
			rotation = o.rotation,
			pos = origin,
			direction = {x = o.nx, z = o.nz},
			street = group.street,
			kind = group.kind,
			material = group.material,
			openings = openings,
			passage = {first = 6, last = 9, width = 4},
			road_width_inside = 6,
			road_width_gate = 4,
			road_width_outside = 4,
			wall_plane = {x = plane_x, z = plane_z},
			bounds = {min = {x = origin.x, y = ground, z = origin.z},
				max = {x = origin.x + sx - 1, y = ground + entry.size.y - 1,
					z = origin.z + sz - 1}},
			street_rect = first.street_rect,
		}
		local candidate = candidates[#candidates]
		candidate.outside_approach = {}
		-- The authored capture ends five nodes beyond the wall. Continue its
		-- central four road columns for another four nodes beyond that face.
		for i = 2, 5 do
			local gap = openings[i]
			candidate.outside_approach[#candidate.outside_approach + 1] = {
				x = gap.x + 6 * o.nx, z = gap.z + 6 * o.nz,
				direction = {x = o.nx, z = o.nz}, material = group.material,
				pave_surface = true,
			}
		end
	end
	for _, group in pairs(groups) do
		local o = orientation[group.direction.x .. ":" .. group.direction.z]
		if o then
			table.sort(group.columns, sort_openings)
			local unique, positions = {}, {}
			for _, c in ipairs(group.columns) do
				local transverse = o.tx ~= 0 and c.x or c.z
				if not unique[transverse] then
					unique[transverse] = c
					positions[#positions + 1] = transverse
				end
			end
			table.sort(positions)
			-- Split a street's edge crossings into contiguous runs before
			-- matching the authored six-node gate width. A disjoint crossing
			-- on the same street and wall plane must not swallow the first.
			local run = {}
			local previous
			local function finish_run()
				if #run == 6 then
					local openings = {}
					for _, transverse in ipairs(run) do openings[#openings + 1] = unique[transverse] end
					add_candidate(group, o, openings, run[1], run[#run])
				end
				run = {}
			end
			for _, transverse in ipairs(positions) do
				if previous and transverse ~= previous + 1 then finish_run() end
				run[#run + 1] = transverse
				previous = transverse
			end
			finish_run()
		end
	end
	table.sort(candidates, function(a, b)
		if a.street ~= b.street then return a.street < b.street end
		if a.wall_plane.x ~= b.wall_plane.x then return a.wall_plane.x < b.wall_plane.x end
		return a.wall_plane.z < b.wall_plane.z
	end)
	return candidates
end

-- Return authored posterns for complete four-node secondary-road crossings.
-- The postern is 3 nodes deep and 10 wide; its double door at local
-- (x=1,z=6..7) is centered on the inner two columns of the road. The long
-- capture dimension runs along the wall, replacing the wall around that door.
function M.postern_candidates(wall, ground, entry)
	assert(type(wall) == "table" and type(wall.openings) == "table", "wall openings are required")
	assert(type(entry) == "table" and type(entry.size) == "table", "postern catalog entry is required")
	assert(entry.size.x == 3 and entry.size.z == 10, "postern attachment contract requires a 3 by 10 template")
	local groups = {}
	for _, opening in ipairs(wall.openings) do
		if opening.kind == "secondary" and opening.street ~= nil then
			local d = opening.direction
			local fixed = d.x ~= 0 and opening.x or opening.z
			local key = table.concat({opening.street, d.x, d.z, fixed}, ":")
			local group = groups[key]
			if not group then
				group = {street = opening.street, direction = {x = d.x, z = d.z}, fixed = fixed,
					kind = opening.kind, material = opening.material, street_rect = opening.street_rect, columns = {}}
				groups[key] = group
			end
			group.columns[#group.columns + 1] = opening
		end
	end
	local rotations = {
		["1:0"] = 0, ["-1:0"] = 180,
		["0:1"] = 270, ["0:-1"] = 90,
	}
	local function rotate(x, z, rotation)
		if rotation == 0 then return x, z end
		if rotation == 90 then return z, entry.size.x - 1 - x end
		if rotation == 180 then return entry.size.x - 1 - x, entry.size.z - 1 - z end
		return entry.size.z - 1 - z, x
	end
	local candidates = {}
	for _, group in pairs(groups) do
		local d = group.direction
		local rotation = rotations[d.x .. ":" .. d.z]
		local unique, values = {}, {}
		for _, opening in ipairs(group.columns) do
			local transverse = d.x ~= 0 and opening.z or opening.x
			if not unique[transverse] then unique[transverse] = opening; values[#values + 1] = transverse end
		end
		table.sort(values)
		local run = {}
		local previous
		local function finish_run()
			if #run ~= 4 then run = {}; return end
			local door_a_x, door_a_z = rotate(1, 6, rotation)
			local door_b_x, door_b_z = rotate(1, 7, rotation)
			local normal_axis = d.x ~= 0 and "x" or "z"
			local tangent_axis = d.x ~= 0 and "z" or "x"
			local normal_a = normal_axis == "x" and door_a_x or door_a_z
			local normal_b = normal_axis == "x" and door_b_x or door_b_z
			local tangent_a = tangent_axis == "x" and door_a_x or door_a_z
			local tangent_b = tangent_axis == "x" and door_b_x or door_b_z
			assert(normal_a == normal_b, "postern door pair must share a wall plane")
			local door_low = math.min(tangent_a, tangent_b)
			local first = run[1]
			local target_low = first + 1
			local tangent_origin = target_low - door_low
			local plane = group.fixed
			local normal_origin = plane - normal_a
			local pos = normal_axis == "x" and {x = normal_origin, y = ground - (entry.ground_offset or 0), z = tangent_origin}
				or {x = tangent_origin, y = ground - (entry.ground_offset or 0), z = normal_origin}
			local sx, sz = entry.size.x, entry.size.z
			if rotation == 90 or rotation == 270 then sx, sz = sz, sx end
			local candidate = {
				asset = entry.id or "wall_postern", rotation = rotation, pos = pos,
				min = pos, max = {x = pos.x + sx - 1,
					y = pos.y + entry.size.y - 1, z = pos.z + sz - 1},
				direction = d, street = group.street, kind = group.kind, material = group.material,
				street_rect = group.street_rect, wall_plane = d.x ~= 0 and {x = plane} or {z = plane},
				openings = {unique[run[1]], unique[run[2]], unique[run[3]], unique[run[4]]},
				passage = {first = 1, last = 2, width = 2},
				road_width_inside = 4, road_width_gate = 2, road_width_outside = 2,
				ground_offset = entry.ground_offset or 0,
			}
			candidate.bounds = {min = candidate.min, max = candidate.max}
			candidate.door_cells = {}
			for _, local_door in ipairs({{1, 6}, {1, 7}}) do
				local rx, rz = rotate(local_door[1], local_door[2], rotation)
				candidate.door_cells[#candidate.door_cells + 1] = {x = pos.x + rx, z = pos.z + rz}
			end
			candidate.outside_approach = {}
			-- The asset extends one node past the wall plane on each side. Extend
			-- the two door columns four more nodes outside the town.
			for _, door in ipairs(candidate.door_cells) do
				candidate.outside_approach[#candidate.outside_approach + 1] = {
					x = door.x + d.x * 2, z = door.z + d.z * 2,
					direction = d, material = group.material, pave_surface = true,
				}
			end
			candidates[#candidates + 1] = candidate
		end
		for _, transverse in ipairs(values) do
			if previous and transverse ~= previous + 1 then finish_run() end
			run[#run + 1] = transverse
			previous = transverse
		end
		finish_run()
	end
	table.sort(candidates, function(a, b)
		if a.street ~= b.street then return a.street < b.street end
		if a.wall_plane.x ~= b.wall_plane.x then return (a.wall_plane.x or -math.huge) < (b.wall_plane.x or -math.huge) end
		return (a.wall_plane.z or -math.huge) < (b.wall_plane.z or -math.huge)
	end)
	return candidates
end

-- Search for support up to 32 nodes below the town surface. Beyond that,
-- an unobstructed wall column hangs from its normal level top for this same
-- maximum depth instead of disappearing entirely.
M.DEPTH = 32
-- The wall has masonry through ground+4 and an optional parapet at +5.
-- Clear five nodes beyond that profile, starting above the support surface.
M.CLEARANCE = 5
M.CLEARANCE_TOP = 10
M.BRICK = "mcl_core:stonebrick"
M.STAIR = "mcl_stairs:stair_stonebrick"
-- Outside gate/postern roads: cobblestone ramp pieces. A ramp is at most
-- RAMP_MAX columns long and at least RAMP_MIN columns long.
M.RAMP_FULL = "mcl_core:cobble"
M.RAMP_SLAB = "mcl_stairs:slab_cobble"
M.RAMP_STAIR = "mcl_stairs:stair_cobble"
M.RAMP_MAX = 16
M.RAMP_MIN = 4
-- Keep the natural-material helper for callers that need to distinguish
-- terrain from authored blocks. Wall support itself uses any solid node.
local NATURAL = {
	["mcl_core:stone"] = true, ["mcl_core:granite"] = true,
	["mcl_core:dirt"] = true,
	["mcl_core:dirt_with_grass"] = true, ["mcl_core:dirt_with_snow"] = true,
	["mcl_core:dirt_with_grass_snow"] = true,
	["mcl_core:coarse_dirt"] = true, ["mcl_core:podzol"] = true,
	["mcl_core:sandstone"] = true, ["mcl_core:redsandstone"] = true,
	["mcl_core:gravel"] = true, ["mcl_core:sand"] = true,
	["mcl_core:redsand"] = true, ["mcl_core:clay"] = true,
	["mcl_deepslate:deepslate"] = true,
}

local function natural(name)
	-- Badlands terrain uses the hardened_clay family as natural substrate.
	-- Its uncolored and colored nodes share this prefix in VoxeLibre.
	return NATURAL[name] or name:match("^mcl_colorblocks:hardened_clay_[a-z_]+$") ~= nil
		or name == "mcl_colorblocks:hardened_clay"
end
M.natural = natural

-- Reserve protected wall and clearance voxels before town structures are
-- written, then recheck protection during final inspection.
-- Exterior apron follows the outside faces of each authored feature.
function M.feature_clearance_positions(feature)
 local d = feature.direction or (feature.corner and feature.corner.direction)
  or (feature.run and feature.run.direction)
 if not d then return {} end
 local r, out = feature, {}
 local x1, x2, z1, z2 = r.min.x, r.max.x, r.min.z, r.max.z
 if d.x > 0 then x1, x2 = r.max.x + 1, r.max.x + M.CLEARANCE
 elseif d.x < 0 then x1, x2 = r.min.x - M.CLEARANCE, r.min.x - 1 end
 if d.z > 0 then z1, z2 = r.max.z + 1, r.max.z + M.CLEARANCE
 elseif d.z < 0 then z1, z2 = r.min.z - M.CLEARANCE, r.min.z - 1 end
 -- Corner aprons include both faces as well as the outer quadrant.
 if d.x ~= 0 and d.z ~= 0 then
  x1 = d.x > 0 and r.min.x or r.min.x - M.CLEARANCE
  x2 = d.x > 0 and r.max.x + M.CLEARANCE or r.max.x
  z1 = d.z > 0 and r.min.z or r.min.z - M.CLEARANCE
  z2 = d.z > 0 and r.max.z + M.CLEARANCE or r.max.z
 end
 for x = x1, x2 do for z = z1, z2 do
  if x < r.min.x or x > r.max.x or z < r.min.z or z > r.max.z then
   out[#out + 1] = {x=x,z=z}
  end
 end end
 return out
end

function M.reserve_feature_clearance(feature, ground, protected)
 feature.clearance_protected = {}
 for _, p in ipairs(M.feature_clearance_positions(feature)) do
  for y = ground + 1, ground + M.CLEARANCE_TOP do
   if protected({x=p.x,y=y,z=p.z}) then
    feature.clearance_protected[p.x .. ":" .. y .. ":" .. p.z] = true
   end
  end
 end
end

function M.feature_clearance_bounds(feature, ground)
 local b
 for _, p in ipairs(M.feature_clearance_positions(feature)) do
  if not b then b={min={x=p.x,y=ground+1,z=p.z},max={x=p.x,y=ground+M.CLEARANCE_TOP,z=p.z}}
  else b.min.x=math.min(b.min.x,p.x); b.min.z=math.min(b.min.z,p.z)
   b.max.x=math.max(b.max.x,p.x); b.max.z=math.max(b.max.z,p.z) end
 end
 return b
end

function M.reserve(wall, ground, protected)
	assert(type(protected) == "function", "protection API unavailable")
	for _, c in ipairs(wall.cells) do
		-- Preserve the existing conservative reservation for the core and all
		-- possible foundation writes.
		if not c.protected then
			for y = ground - M.DEPTH, ground + M.CLEARANCE_TOP do
				if protected({x = c.x, y = y, z = c.z}) then
					c.protected = {x = c.x, y = y, z = c.z}
					break
				end
			end
		end
		c.clearance_protected = c.clearance_protected or {}
		for _, p in ipairs(clearance_positions(c)) do
			if p.x ~= c.x or p.z ~= c.z then
				for y = ground + 1, ground + M.CLEARANCE_TOP do
					if protected({x = p.x, y = y, z = p.z}) then
						c.clearance_protected[p.x .. ":" .. y .. ":" .. p.z] = {x = p.x, y = y, z = p.z}
					end
				end
			end
		end
	end
	for _, c in ipairs(wall.openings) do
		for distance = 0, 3 do
			local x, z = c.x + c.direction.x * distance, c.z + c.direction.z * distance
			for y = ground - M.DEPTH, ground + M.CLEARANCE_TOP do
				if protected({x = x, y = y, z = z}) then
					if c.protected ~= true then
						c.protected = c.protected or {}
						c.protected[distance] = {x = x, y = y, z = z}
					end
					break
				end
			end
		end
	end
end

function M.bounds(wall, ground)
	local b
	local function include(c, positions)
		for _, p in ipairs(positions) do
			if not b then b = {min = {x = p.x, y = ground - M.DEPTH, z = p.z},
				max = {x = p.x, y = ground + M.CLEARANCE_TOP, z = p.z}}
			else
				b.min.x, b.min.z = math.min(b.min.x, p.x), math.min(b.min.z, p.z)
				b.max.x, b.max.z = math.max(b.max.x, p.x), math.max(b.max.z, p.z)
			end
		end
	end
	for _, c in ipairs(wall.cells) do
		include(c, clearance_positions(c))
	end
	for _, c in ipairs(wall.openings) do
		local positions = {}
		for distance = 0, 3 do positions[#positions + 1] = {x = c.x + c.direction.x * distance,
			z = c.z + c.direction.z * distance} end
		-- Approaches are part of the actual wall write envelope.
		for _, p in ipairs(positions) do
			if not b then b = {min = {x = p.x, y = ground - M.DEPTH, z = p.z},
				max = {x = p.x, y = ground + 2, z = p.z}}
			else
				b.min.x, b.min.z = math.min(b.min.x, p.x), math.min(b.min.z, p.z)
				b.max.x, b.max.z = math.max(b.max.x, p.x), math.max(b.max.z, p.z)
				b.max.y = math.max(b.max.y, ground + 2)
			end
		end
	end
	-- Road openings remain open and are not part of the clearance volume.
	return b
end

-- Inspect after smoothing. Build the clearance overlay first, then place only
-- supported wall columns and their optional overhangs.
function M.inspect(wall, ground, region, node_info, protected)
	local changes, omissions, emitted_clear = {}, {}, {}
	local occupied, feature_cells, road_cells, cleared = {}, {}, {}, {}
	for _, c in ipairs(wall.cells) do occupied[key(c.x, c.z)] = true end
	for _, c in ipairs(wall.openings) do
		for distance = 0, 3 do
			local x, z = c.x + c.direction.x * distance, c.z + c.direction.z * distance
			occupied[key(x, z)], road_cells[key(x, z)] = true, true
		end
	end
	for _, c in ipairs(wall.road_openings or {}) do
		for distance = 0, 3 do road_cells[key(c.x + c.direction.x * distance, c.z + c.direction.z * distance)] = true end
	end
	for _, feature in ipairs(wall.placed_features or {}) do
		for _, c in ipairs(feature.outside_approach or {}) do
			for distance = 0, (feature.approach_length or 4) - 1 do road_cells[key(c.x + c.direction.x * distance, c.z + c.direction.z * distance)] = true end
		end
	end
	for _, rect in ipairs(wall.feature_footprints or {}) do
		for x = rect.x1, rect.x2 do
			for z = rect.z1, rect.z2 do
				occupied[key(x, z)], feature_cells[key(x, z)] = true, true
			end
		end
	end
	local function voxel_key(x, y, z) return x .. ":" .. y .. ":" .. z end
	-- Protected wall-core columns must also shield their full vertical column
	-- from a neighboring cell's overlapping apron.
	local protected_core, wall_core = {}, {}
	for _, c in ipairs(wall.cells) do
		wall_core[key(c.x, c.z)] = true
		local is_protected = c.protected ~= nil and c.protected ~= false
		local protected_pos
		if not is_protected then
			for y = ground - M.DEPTH, ground + M.CLEARANCE_TOP do
				local pos = {x = c.x, y = y, z = c.z}
				if protected(pos) then is_protected, protected_pos = true, pos; break end
			end
		end
		c._inspect_protected, c._inspect_protected_pos = is_protected, protected_pos
		if is_protected then protected_core[key(c.x, c.z)] = true end
	end
	local core_clear_by_cell = {}
	for _, c in ipairs(wall.cells) do
		local to_clear = {}
		if not c._inspect_protected then
			for y = ground - M.DEPTH, ground + M.CLEARANCE_TOP do
				local have = region.get(c.x, y, c.z)
				local info = node_info(have)
				if have ~= "air" and have ~= "ignore" and not (info and info.liquid)
					and (not info or not info.walkable or info.vegetation or y > ground) then
					to_clear[#to_clear + 1] = {x = c.x, y = y, z = c.z}
					cleared[voxel_key(c.x, y, c.z)] = true
				end
			end
		end
		core_clear_by_cell[c] = to_clear
	end
	local function get(x, y, z)
		if cleared[voxel_key(x, y, z)] then return "air" end
		return region.get(x, y, z)
	end
	local function clear(name)
		return name == "air"
	end
	local function water(name)
		local info = node_info(name)
		return info ~= nil and info.liquid and name:find("water", 1, true) ~= nil
	end
	local function replaceable(name)
		local info = node_info(name)
		return clear(name) or water(name) or (info ~= nil and not info.walkable and not info.liquid)
	end
	local function vegetation(name)
		if name == "air" then return false end
		local info = node_info(name)
		return info ~= nil and info.vegetation and not info.liquid and not info.ice
	end
	local function supported(x, y, z)
		-- A falling surface is stable only when its contiguous falling stack
		-- rests on a non-falling solid within the inspected envelope.
		for below = y, ground - M.DEPTH, -1 do
			local name = get(x, below, z)
			local info = node_info(name)
			if not info or not info.walkable or info.liquid or info.vegetation
					or (info.tree and below > ground) then
				return false, {x = x, y = below, z = z, node = name}
			end
			if not info.falling then return true end
		end
		local name = get(x, ground - M.DEPTH, z)
		return false, {x = x, y = ground - M.DEPTH, z = z, node = name}
	end
	local function omission(x, z, reason, blocker)
		local item = {x = x, z = z, reason = reason}
		if blocker then item.blocker = blocker end
		omissions[#omissions + 1] = item
	end
	local function reserved(c, field, distance)
		local value = c[field]
		if type(value) == "table" and value.x then return value end -- older stored reservation shape
		if type(value) == "table" then return value[distance] end
		if value == true then return {unknown = true} end
	end
	local function reserved_any(c, field)
		local value = c[field]
		if type(value) == "table" and value.x then return value end
		if type(value) == "table" then
			for distance = 0, 3 do
				if value[distance] then return value[distance] end
			end
		elseif value == true then
			return {unknown = true}
		end
	end
	for _, c in ipairs(wall.cells) do
		local staged_clear = {}
		for _, p in ipairs(clearance_positions(c)) do
			local k = key(p.x, p.z)
			if not wall_core[k]
					and not road_cells[k] and not feature_cells[k] then
				for y = ground + 1, ground + M.CLEARANCE_TOP do
					local vk = voxel_key(p.x,y,p.z)
					local have = region.get(p.x,y,p.z)
					local info = node_info(have)
					local reservations = c.clearance_protected
					local reserved_cell = type(reservations) == "table" and reservations[vk]
					if not reserved_cell and not protected({x=p.x,y=y,z=p.z}) and have ~= "air"
							and have ~= "ignore" and not (info and info.liquid) then
						staged_clear[#staged_clear + 1] = {x=p.x,y=y,z=p.z}
						cleared[vk] = true
					end
				end
			end
		end
		local protected_pos = reserved(c, "protected", 0) or c._inspect_protected_pos
		local why = protected_pos and "protected" or nil
		local base, floating, water_seen, blocker
		if why then
			if protected_pos.unknown then blocker = {node = "unknown"}
			else blocker = {x = protected_pos.x, y = protected_pos.y, z = protected_pos.z,
				node = get(protected_pos.x, protected_pos.y, protected_pos.z)} end
		end
		if not why then
			-- Search up to one node below the intended wall cap. This lets a
			-- raised edge support a shorter wall while ensuring at least one
			-- masonry node remains above its foundation; the cap stays level.
			for y = ground + 3, ground - M.DEPTH, -1 do
				local name = get(c.x, y, c.z)
				local stable, failure = supported(c.x, y, c.z)
				if stable then base = y; break end
				if failure then blocker = failure end
				if water(name) then water_seen = true end
				if not replaceable(name) and not vegetation(name) then
					why = "water or obstruction"; blocker = failure or {x = c.x, y = y, z = c.z, node = name}; break
				end
			end
			if not base and not why then
				if water_seen then
					why = "water bottom beyond reach"
					for y = ground - M.DEPTH, ground + 3 do
						local name = get(c.x, y, c.z)
						if water(name) then
							blocker = {x = c.x, y = y, z = c.z, node = name,
								search_limit_y = ground - M.DEPTH}
							break
						end
					end
				else floating = true end
			end
		end
		local candidate = {}
		local function add(x, y, z, name, param2)
			if why then return end
			local have = get(x, y, z)
			local reservation = c.clearance_protected
			local reserved_cell = type(reservation) == "table" and reservation[voxel_key(x, y, z)]
			if reserved_cell or protected({x = x, y = y, z = z}) then
				why = "protected"
				blocker = {x = x, y = y, z = z, node = have}
			elseif have == "ignore" or (node_info(have) and node_info(have).liquid and not water(have)) then
				why = "unloaded or non-water liquid obstruction"
				blocker = {x = x, y = y, z = z, node = have}
			elseif not replaceable(have) and not vegetation(have) and not (node_info(have) or {}).tree
					and (x ~= c.x or z ~= c.z) then why = "water or obstruction"; blocker = {x = x, y = y, z = z, node = have}
			else candidate[#candidate + 1] = {x = x, y = y, z = z, name = name, param2 = param2 or 0} end
		end
		if base or floating then
			local bottom = base and (base + 1) or (ground - M.DEPTH + 1)
			for y = bottom, ground + 4 do add(c.x, y, c.z, M.BRICK) end
			local d = c.direction
			local px, pz = c.x + d.x, c.z + d.z
			if not why and not c.corner and not occupied[key(px, pz)] then
				-- A roof or protected node in the optional overhang must not
				-- prevent the supported wall itself from being built.
				local core = candidate
				candidate = {}
				local decoration_pos = reserved(c, "decoration_protected", 1)
				if decoration_pos then
					why = "protected"
					if decoration_pos.unknown then blocker = {node = "unknown"}
					else blocker = {x = decoration_pos.x, y = decoration_pos.y, z = decoration_pos.z,
						node = get(decoration_pos.x, decoration_pos.y, decoration_pos.z)} end
				end
				local axis = d.x ~= 0 and c.z or c.x
				if axis % 2 == 0 then
					-- VoxeLibre's upside-down stair placement swaps facedir 1 and 3.
					-- Values 20/22 therefore put the high side toward the wall on
					-- the +Z/-Z faces respectively; X already follows the same rule.
					local p2 = d.x == 1 and 21 or d.x == -1 and 23 or d.z == 1 and 22 or 20
					add(px, ground + 4, pz, M.STAIR, p2)
				end
				add(px, ground + 5, pz, M.BRICK)
				if why then
					omission(px, pz, "decoration: " .. why, blocker)
					why = nil
				else
					for _, change in ipairs(candidate) do core[#core + 1] = change end
				end
				candidate = core
			end
		end
		if why then
			for _, p in ipairs(staged_clear) do cleared[voxel_key(p.x,p.y,p.z)] = nil end
			omission(c.x, c.z, why, blocker)
		else
			local function append_clear(p)
				local vk = voxel_key(p.x,p.y,p.z)
				if not emitted_clear[vk] then
					emitted_clear[vk] = true
					changes[#changes + 1] = {x=p.x,y=p.y,z=p.z,name="air",param2=0,clearance=true}
				end
			end
			for _, p in ipairs(core_clear_by_cell[c] or {}) do
				append_clear(p)
			end
			for _, p in ipairs(staged_clear) do
				append_clear(p)
			end
			for _, change in ipairs(candidate) do changes[#changes + 1] = change end
		end
	end
	-- Extend every crossing by three nodes. Only fill gaps above stable support;
	-- avoid clearing solid terrain or structures in the approach headroom.
	for _, c in ipairs(wall.openings) do
		-- Openings graded by M.grade_openings are replaced by a ramp.
		for distance = 0, c.graded and -1 or 3 do
			local x, z = c.x + c.direction.x * distance, c.z + c.direction.z * distance
			-- Any protected node reserved anywhere along the opening preserves
			-- the original behavior: the complete road approach stays untouched.
			local protected_pos = reserved_any(c, "protected")
			local why = protected_pos and "protected" or nil
			local base, blocker, water_seen, water_blocker
			if why then
				if protected_pos.unknown then blocker = {node = "unknown"}
				else blocker = {x = protected_pos.x, y = protected_pos.y, z = protected_pos.z,
					node = get(protected_pos.x, protected_pos.y, protected_pos.z)} end
			end
			if not why then
				-- Probe only up to the road's fixed target surface. Raised
				-- approaches are reported below without clearing or filling them.
				for y = ground + 2, ground - M.DEPTH, -1 do
					local name = get(x, y, z)
					local stable, failure = supported(x, y, z)
					if stable then base = y; break end
					if failure then blocker = failure end
					if water(name) then
						water_seen = true
						water_blocker = {x = x, y = y, z = z, node = name}
					end
					if not replaceable(name) and not vegetation(name)
							and not (c.material and (node_info(name) or {}).tree) then
						why = "water or obstruction"; blocker = failure or {x = x, y = y, z = z, node = name}; break
					end
				end
				if not base and not why then
					why = water_seen and "water bottom beyond reach" or "unsupported drop"
					if water_seen then
						blocker = water_blocker
						blocker.search_limit_y = ground - M.DEPTH
					elseif not blocker then
						local y = ground - M.DEPTH
						blocker = {x = x, y = y, z = z, node = get(x, y, z)}
					end
				end
				-- A road approach must meet the town at its planned ground level.
				-- Leave a raised natural step untouched and report this crossing.
				if base and base > ground then why = "raised terrain"; blocker = {x = x, y = base, z = z, node = get(x, base, z)} end
			end
			local proposed = {}
			if base and not why then
				if (c.pave_surface or (c.material and (vegetation(get(x, ground, z))
						or (node_info(get(x, ground, z)) or {}).tree))) and base == ground then
					local name = get(x, ground, z)
					if protected({x = x, y = ground, z = z}) then
						why = "protected"; blocker = {x = x, y = ground, z = z, node = name}
					else
						proposed[#proposed + 1] = {x = x, y = ground, z = z,
							name = c.material or M.BRICK, param2 = 0}
					end
				end
				for y = base + 1, ground + 2 do
					local name = get(x, y, z)
					if protected({x = x, y = y, z = z}) then why = "protected"; blocker = {x = x, y = y, z = z, node = name}; break end
					if not replaceable(name) and not vegetation(name)
							and not (c.material and (node_info(name) or {}).tree) then
						why = "water or obstruction"; blocker = {x = x, y = y, z = z, node = name}; break
					end
					if y <= ground then
						proposed[#proposed + 1] = {x = x, y = y, z = z, name = c.material or M.BRICK, param2 = 0}
					elseif water(name) then
						why = "water in approach headroom"; blocker = {x = x, y = y, z = z, node = name}; break
					elseif vegetation(name) or (c.material and (node_info(name) or {}).tree) then
						proposed[#proposed + 1] = {x = x, y = y, z = z, name = "air", param2 = 0}
					end
				end
			end
			if why then omission(x, z, "approach: " .. why, blocker)
			else for _, change in ipairs(proposed) do changes[#changes + 1] = change end end
		end
	end
	local wall_written = {}
	for _, c in ipairs(changes) do
		if c.name ~= "air" then wall_written[voxel_key(c.x,c.y,c.z)] = true end
	end
	-- Clear only around features actually placed, keeping all road and feature
	-- footprints and protected voxels intact.
	for _, feature in ipairs(wall.placed_features or {}) do
	 for _, p in ipairs(M.feature_clearance_positions(feature)) do
	  local k = key(p.x,p.z)
	  local r = feature.street_rect
	  local road = road_cells[k] or (r and p.x >= r.x1 and p.x <= r.x2 and p.z >= r.z1 and p.z <= r.z2)
	  for _, street in ipairs(wall.streets or {}) do
	   local sr = street.rect
	   if sr and p.x >= sr.x1 and p.x <= sr.x2 and p.z >= sr.z1 and p.z <= sr.z2 then road = true end
	  end
	  for _, approach in ipairs(feature.outside_approach or {}) do
	   for n = 0, (feature.approach_length or 4) - 1 do
	    if p.x == approach.x + n * approach.direction.x and p.z == approach.z + n * approach.direction.z then road = true end
	   end
	  end
	  if not road and not feature_cells[k] and not wall_core[k] then
	   for y = ground + 1, ground + M.CLEARANCE_TOP do
	    local vk = voxel_key(p.x,y,p.z)
	    local have = region.get(p.x,y,p.z)
	    local info = node_info(have)
	    if not emitted_clear[vk] and not wall_written[vk] and not (feature.clearance_protected or {})[vk]
	      and not protected({x=p.x,y=y,z=p.z}) and have ~= "air" and have ~= "ignore"
	      and not (info and info.liquid) then
	     emitted_clear[vk] = true
	     changes[#changes+1] = {x=p.x,y=y,z=p.z,name="air",param2=0,clearance=true}
	    end
	   end
	  end
	 end
	end
	for _, change in ipairs(changes) do
		local existing = region.get(change.x, change.y, change.z)
		if existing ~= "air" and existing ~= "ignore" then change.clear_metadata = true end
	end
	return changes, omissions
end

-- Footprint of the first `length` ramp columns.
function M.approach_rect(columns, length)
	local r
	for _, c in ipairs(columns) do
		for _, n in ipairs({0, length - 1}) do
			local x, z = c.x + c.direction.x * n, c.z + c.direction.z * n
			if not r then r = {x1 = x, x2 = x, z1 = z, z2 = z}
			else
				r.x1, r.x2 = math.min(r.x1, x), math.max(r.x2, x)
				r.z1, r.z2 = math.min(r.z1, z), math.max(r.z2, z)
			end
		end
	end
	return r
end

-- Region needed to read and write a ramp of the maximum length.
function M.approach_bounds(columns, ground)
	local r = M.approach_rect(columns, M.RAMP_MAX)
	return {min = {x = r.x1, y = ground - M.DEPTH, z = r.z1},
		max = {x = r.x2, y = ground + M.RAMP_MAX + 4, z = r.z2}}
end

-- Outside road widths for an opening that has no gatehouse/postern.
M.BARE_WIDTH = {principal = 4, secondary = 2}

-- Group openings into contiguous crossings and return, for each, the central
-- columns (principal 4, secondary 2) that get a graded ramp. Crossings that
-- cannot be centered on that width are skipped and keep the legacy stub.
function M.bare_crossings(openings)
	local groups, order = {}, {}
	for _, o in ipairs(openings) do
		local d = o.direction
		local transverse = d.x ~= 0 and o.z or o.x
		local k = tostring(o.street) .. ":" .. d.x .. ":" .. d.z .. ":" .. (d.x ~= 0 and o.x or o.z)
		if not groups[k] then groups[k] = {}; order[#order + 1] = k end
		groups[k][#groups[k] + 1] = {t = transverse, o = o}
	end
	table.sort(order)
	local out = {}
	for _, k in ipairs(order) do
		local list = groups[k]
		table.sort(list, function(a, b) return a.t < b.t end)
		local i = 1
		while i <= #list do
			local j = i
			while j < #list and list[j + 1].t == list[j].t + 1 do j = j + 1 end
			local n = j - i + 1
			local width = M.BARE_WIDTH[list[i].o.kind]
			if width and n >= width and (n - width) % 2 == 0 then
				local trim, columns = (n - width) / 2, {}
				for m = i + trim, j - trim do columns[#columns + 1] = list[m].o end
				out[#out + 1] = columns
			end
			i = j + 1
		end
	end
	return out
end

-- Grade each bare crossing with the outside-road ramp. Returns the ramp
-- changes and a list of failed omissions; graded openings are flagged so
-- inspect skips the flat stub. A failed crossing keeps the legacy behavior.
function M.grade_openings(openings, ground, region, node_info, protected)
	local changes, failures = {}, {}
	for _, columns in ipairs(M.bare_crossings(openings)) do
		local ramp, omissions = M.approach(columns, ground, region, node_info, protected)
		if #omissions > 0 then failures[#failures + 1] = omissions[1]
		else
			for _, c in ipairs(ramp) do changes[#changes + 1] = c end
			for _, c in ipairs(columns) do c.graded = true end
		end
	end
	return changes, failures
end

-- Grade bare openings, then inspect the wall. Ramp changes come last so they
-- win over wall clearance. Returns changes, omissions, ramp failures.
function M.inspect_graded(wall, ground, region, node_info, protected)
	local ramp, failures = M.grade_openings(wall.openings, ground, region, node_info, protected)
	local changes, omissions = M.inspect(wall, ground, region, node_info, protected)
	for _, c in ipairs(ramp) do changes[#changes + 1] = c end
	return changes, omissions, failures
end

local FACEDIR = {["0:1"] = 0, ["1:0"] = 1, ["0:-1"] = 2, ["-1:0"] = 3}

-- Plan an outside road (all `columns` share one direction) that leaves town
-- ground level and slopes until it meets natural terrain. Heights are tracked
-- in half nodes: level 2y is a full block at node y, level 2y-1 a bottom slab
-- at node y. Each column outward moves one level (slab/full alternating), or
-- two levels (a stair) when the gap is at least two nodes and the road is on a
-- full block. Higher terrain is trenched to road width; lower terrain gets a
-- cobblestone causeway. Buildings, fluids and protected nodes are never
-- replaced: the first such hit omits the whole approach.
-- Returns changes, omissions, length.
function M.approach(columns, ground, region, node_info, protected)
	local changes, omissions = {}, {}
	local dir = columns[1].direction
	local function kind(name)
		if name == "air" then return "air" end
		local info = node_info(name)
		if not info then return "other" end
		if info.liquid then return "liquid" end
		if info.vegetation or info.tree then return "air" end
		if M.natural(name) then return "terrain" end
		if not info.walkable then return "air" end
		return "other"
	end
	local function fail(x, y, z, why, name)
		omissions[1] = {x = x, z = z, reason = "approach: " .. why, blocker = {x = x, y = y, z = z, node = name}}
		return {}, omissions
	end
	local function surface(x, z)
		for y = ground + M.RAMP_MAX + 1, ground - M.DEPTH, -1 do
			local name = region.get(x, y, z)
			local k = kind(name)
			if k == "terrain" then return y end
			if k ~= "air" then return nil, y, name, k == "liquid" and "water in approach" or "water or obstruction" end
		end
		local y = ground - M.DEPTH
		return nil, y, region.get(x, y, z), "unsupported drop"
	end
	local function put(x, y, z, name, param2)
		local have = region.get(x, y, z)
		if protected({x = x, y = y, z = z}) then return false, "protected", have end
		changes[#changes + 1] = {x = x, y = y, z = z, name = name, param2 = param2 or 0,
			clear_metadata = have ~= "air" and have ~= "ignore" or nil}
		return true
	end
	local level, last_step = 2 * ground, 0
	for n = 0, M.RAMP_MAX - 1 do
		local surf, top = {}, nil
		for i, c in ipairs(columns) do
			local x, z = c.x + dir.x * n, c.z + dir.z * n
			local s, y, name, why = surface(x, z)
			if not s then return fail(x, y, z, why, name) end
			surf[i] = s
			top = math.max(top or s, s)
		end
		local diff = 2 * top - level
		-- A descending stair leaves its outer half a half node below the road
		-- above it, so it may only be followed by another stair or a flat/rising
		-- piece, never a slab one full node lower.
		local stair = math.abs(diff) >= 4 and level % 2 == 0 or (diff == -2 and last_step == -2)
		local step = diff == 0 and 0 or stair and 2 or 1
		if diff < 0 then step = -step end
		level, last_step = level + step, step
		local y, name, p2 = nil, M.RAMP_FULL, 0
		if step == 2 then y, name, p2 = level / 2, M.RAMP_STAIR, FACEDIR[dir.x .. ":" .. dir.z]
		elseif step == -2 then y, name, p2 = level / 2 + 1, M.RAMP_STAIR, FACEDIR[(0 - dir.x) .. ":" .. (0 - dir.z)]
		elseif level % 2 == 0 then y = level / 2
		else y, name = (level + 1) / 2, M.RAMP_SLAB end
		for i, c in ipairs(columns) do
			local x, z = c.x + dir.x * n, c.z + dir.z * n
			local function check(yy)
				local have = region.get(x, yy, z)
				local k = kind(have)
				if k == "liquid" then return fail(x, yy, z, "water in approach", have) end
				if k == "other" then return fail(x, yy, z, "water or obstruction", have) end
				return nil, have, k
			end
			local function write(yy, node, param2)
				local ok, why, have = put(x, yy, z, node, param2)
				if not ok then return fail(x, yy, z, why, have) end
			end
			-- Headroom and trench above the road surface.
			for yy = math.max(surf[i], y + 3), y + 1, -1 do
				local bad, have = check(yy)
				if bad then return bad, omissions end
				if have ~= "air" then
					local f = write(yy, "air")
					if f then return f, omissions end
				end
			end
			local bad = check(y)
			if bad then return bad, omissions end
			local f = write(y, name, p2)
			if f then return f, omissions end
			-- Causeway fill down to the first solid support.
			local yy = y - 1
			while true do
				if yy < ground - M.DEPTH then
					return fail(x, yy, z, "unsupported drop", region.get(x, yy, z))
				end
				local have = region.get(x, yy, z)
				local k = kind(have)
				if k == "liquid" then return fail(x, yy, z, "water in approach", have) end
				if k ~= "air" then break end
				f = write(yy, M.RAMP_FULL)
				if f then return f, omissions end
				yy = yy - 1
			end
		end
		if n >= M.RAMP_MIN - 1 and level == 2 * top then return changes, omissions, n + 1 end
	end
	local c = columns[1]
	return fail(c.x + dir.x * (M.RAMP_MAX - 1), ground, c.z + dir.z * (M.RAMP_MAX - 1),
		"terrain not met within " .. M.RAMP_MAX .. " blocks", "unknown")
end

return M
