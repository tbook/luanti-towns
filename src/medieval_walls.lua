-- Pure geometry for the first phase of medieval walls. Coordinates are world
-- coordinates; the plan is independent of the town layout's random stream.
local M = {}
local directions = {{x = 1, z = 0}, {x = -1, z = 0}, {x = 0, z = 1}, {x = 0, z = -1}}
local function key(x, z) return x .. ":" .. z end
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
							material = s.material}
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

-- Search for support up to 32 nodes below the town surface. Beyond that,
-- an unobstructed wall column hangs from its normal level top for this same
-- maximum depth instead of disappearing entirely.
M.DEPTH = 32
M.BRICK = "mcl_core:stonebrick"
M.STAIR = "mcl_stairs:stair_stonebrick"
-- Only known natural terrain can support new masonry. Group membership such
-- as "stone" is insufficient because crafted structures can share it.
local NATURAL = {
	["mcl_core:stone"] = true, ["mcl_core:dirt"] = true,
	["mcl_core:dirt_with_grass"] = true, ["mcl_core:dirt_with_snow"] = true,
	["mcl_core:dirt_with_grass_snow"] = true,
	["mcl_core:coarse_dirt"] = true, ["mcl_core:podzol"] = true,
	["mcl_core:sandstone"] = true, ["mcl_core:redsandstone"] = true,
	["mcl_core:gravel"] = true, ["mcl_core:sand"] = true,
	["mcl_core:redsand"] = true, ["mcl_core:clay"] = true,
	["mcl_deepslate:deepslate"] = true,
}

-- Conservatively reserve both the wall and its overhanging parapet. A
-- protected column is omitted, including if protection later changes.
function M.reserve(wall, ground, protected)
	assert(type(protected) == "function", "protection API unavailable")
	local function reserve(c, positions)
		local d = c.direction
		for _, distance in ipairs(positions) do
			local p = {x = c.x + d.x * distance, z = c.z + d.z * distance}
			for y = ground - M.DEPTH, ground + 5 do
				if protected({x = p.x, y = y, z = p.z}) then c.protected = true; break end
			end
		end
	end
	for _, c in ipairs(wall.cells) do reserve(c, {0, 1}) end
	for _, c in ipairs(wall.openings) do reserve(c, {0, 1, 2, 3}) end
end

function M.bounds(wall, ground)
	local b
	local function include(c, distances)
		for _, distance in ipairs(distances) do
			local p = {x = c.x + c.direction.x * distance, z = c.z + c.direction.z * distance}
			if not b then b = {min = {x = p.x, y = ground - M.DEPTH, z = p.z},
				max = {x = p.x, y = ground + 5, z = p.z}}
			else
				b.min.x, b.min.z = math.min(b.min.x, p.x), math.min(b.min.z, p.z)
				b.max.x, b.max.z = math.max(b.max.x, p.x), math.max(b.max.z, p.z)
			end
		end
	end
	for _, c in ipairs(wall.cells) do include(c, {0, 1}) end
	for _, c in ipairs(wall.openings) do include(c, {0, 1, 2, 3}) end
	return b
end

-- Inspect after smoothing. An entire column is omitted if any of its nodes
-- cannot be safely placed; other columns remain independent.
function M.inspect(wall, ground, region, node_info, protected)
	local changes, omissions = {}, {}
	local occupied = {}
	for _, c in ipairs(wall.cells) do occupied[key(c.x, c.z)] = true end
	for _, c in ipairs(wall.openings) do
		for distance = 0, 3 do
			occupied[key(c.x + c.direction.x * distance, c.z + c.direction.z * distance)] = true
		end
	end
	local function clear(name)
		return name == "air"
	end
	local function vegetation(name)
		if name == "air" then return false end
		local info = node_info(name)
		return info ~= nil and info.vegetation and not info.liquid and not info.ice
	end
	local function supported(x, y, z)
		-- A falling surface is stable only when its contiguous falling stack
		-- rests on non-falling natural ground within the inspected envelope.
		for below = y, ground - M.DEPTH, -1 do
			local name = region.get(x, below, z)
			local info = node_info(name)
			if not NATURAL[name] or not info or not info.walkable or info.liquid
					or info.ice or info.clearable then return false end
			if not info.falling then return true end
		end
		return false
	end
	for _, c in ipairs(wall.cells) do
		local why = c.protected and "protected" or nil
		local base, floating
		if not why then
			-- Search up to one node below the intended wall cap. This lets a
			-- raised edge support a shorter wall while ensuring at least one
			-- masonry node remains above its foundation; the cap stays level.
			for y = ground + 3, ground - M.DEPTH, -1 do
				local name = region.get(c.x, y, c.z)
				if supported(c.x, y, c.z) then base = y; break end
				if not clear(name) and not vegetation(name) then why = "water or obstruction"; break end
			end
			if not base and not why then floating = true end
		end
		local candidate = {}
		local function add(x, y, z, name, param2)
			if why then return end
			local have = region.get(x, y, z)
			if protected({x = x, y = y, z = z}) then why = "protected"
			elseif not clear(have) and not vegetation(have) then why = "water or obstruction"
			else candidate[#candidate + 1] = {x = x, y = y, z = z, name = name, param2 = param2 or 0} end
		end
		if base or floating then
			local bottom = base and (base + 1) or (ground - M.DEPTH + 1)
			for y = bottom, ground + 4 do add(c.x, y, c.z, M.BRICK) end
			local d = c.direction
			local px, pz = c.x + d.x, c.z + d.z
			if not c.corner and not occupied[key(px, pz)] then
				local axis = d.x ~= 0 and c.z or c.x
				if axis % 2 == 0 then
					-- VoxeLibre's upside-down stair placement swaps facedir 1 and 3.
					-- Values 20/22 therefore put the high side toward the wall on
					-- the +Z/-Z faces respectively; X already follows the same rule.
					local p2 = d.x == 1 and 21 or d.x == -1 and 23 or d.z == 1 and 22 or 20
					add(px, ground + 4, pz, M.STAIR, p2)
				end
				add(px, ground + 5, pz, M.BRICK)
			end
		end
		if why then omissions[#omissions + 1] = {x = c.x, z = c.z, reason = why}
		else for _, change in ipairs(candidate) do changes[#changes + 1] = change end end
	end
	-- Extend every crossing by three nodes. Only fill gaps above stable support;
	-- avoid clearing solid terrain or structures in the approach headroom.
	for _, c in ipairs(wall.openings) do
		for distance = 0, 3 do
			local x, z = c.x + c.direction.x * distance, c.z + c.direction.z * distance
			local why = c.protected and "protected" or nil
			local base
			if not why then
				-- Probe only up to the road's fixed target surface. Raised
				-- approaches are reported below without clearing or filling them.
				for y = ground + 2, ground - M.DEPTH, -1 do
					local name = region.get(x, y, z)
					if supported(x, y, z) then base = y; break end
					if not clear(name) and not vegetation(name) then why = "water or obstruction"; break end
				end
				if not base and not why then why = "unsupported drop" end
				-- A road approach must meet the town at its planned ground level.
				-- Leave a raised natural step untouched and report this crossing.
				if base and base > ground then why = "raised terrain" end
			end
			local proposed = {}
			if base and not why then
				for y = base + 1, ground + 2 do
					local name = region.get(x, y, z)
					if protected({x = x, y = y, z = z}) then why = "protected"; break end
					if not clear(name) and not vegetation(name) then why = "water or obstruction"; break end
					if y <= ground then
						proposed[#proposed + 1] = {x = x, y = y, z = z, name = c.material or M.BRICK, param2 = 0}
					elseif vegetation(name) then
						proposed[#proposed + 1] = {x = x, y = y, z = z, name = "air", param2 = 0}
					end
				end
			end
			if why then omissions[#omissions + 1] = {x = x, z = z, reason = "approach: " .. why}
			else for _, change in ipairs(proposed) do changes[#changes + 1] = change end end
		end
	end
	return changes, omissions
end

return M
