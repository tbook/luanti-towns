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

-- Remember protection separately for the wall and its optional overhang,
-- including protection that might change before inspection.
function M.reserve(wall, ground, protected)
	assert(type(protected) == "function", "protection API unavailable")
	local function reserve(c, positions, field)
		local d = c.direction
		for _, distance in ipairs(positions) do
			local p = {x = c.x + d.x * distance, z = c.z + d.z * distance}
			for y = ground - M.DEPTH, ground + 5 do
				if protected({x = p.x, y = y, z = p.z}) then
					-- Preserve legacy boolean reservations; their original position
					-- cannot be recovered, and indexing true would raise an error.
					if c[field] ~= true then
						c[field] = c[field] or {}
						c[field][distance] = {x = p.x, y = y, z = p.z}
					end
					break
				end
			end
		end
	end
	for _, c in ipairs(wall.cells) do
		reserve(c, {0}, "protected")
		reserve(c, {1}, "decoration_protected")
	end
	for _, c in ipairs(wall.openings) do reserve(c, {0, 1, 2, 3}, "protected") end
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

-- Inspect after smoothing. An unsafe core column is omitted; an unsafe
-- overhang is omitted independently so it does not interrupt the wall.
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
	local function water(name)
		local info = node_info(name)
		return info ~= nil and info.liquid and name:find("water", 1, true) ~= nil
	end
	local function replaceable(name)
		return clear(name) or water(name)
	end
	local function vegetation(name)
		if name == "air" then return false end
		local info = node_info(name)
		return info ~= nil and (info.vegetation or info.tree) and not info.liquid and not info.ice
	end
	local function supported(x, y, z)
		-- A falling surface is stable only when its contiguous falling stack
		-- rests on non-falling natural ground within the inspected envelope.
		for below = y, ground - M.DEPTH, -1 do
			local name = region.get(x, below, z)
			local info = node_info(name)
			if not natural(name) or not info or not info.walkable or info.liquid
					or info.ice or info.clearable then return false, {x = x, y = below, z = z, node = name} end
			if not info.falling then return true end
		end
		local name = region.get(x, ground - M.DEPTH, z)
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
		local protected_pos = reserved(c, "protected", 0)
		local why = protected_pos and "protected" or nil
		local base, floating, water_seen, blocker
		if why then
			if protected_pos.unknown then blocker = {node = "unknown"}
			else blocker = {x = protected_pos.x, y = protected_pos.y, z = protected_pos.z,
				node = region.get(protected_pos.x, protected_pos.y, protected_pos.z)} end
		end
		if not why then
			-- Search up to one node below the intended wall cap. This lets a
			-- raised edge support a shorter wall while ensuring at least one
			-- masonry node remains above its foundation; the cap stays level.
			for y = ground + 3, ground - M.DEPTH, -1 do
				local name = region.get(c.x, y, c.z)
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
						local name = region.get(c.x, y, c.z)
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
			local have = region.get(x, y, z)
			if protected({x = x, y = y, z = z}) then why = "protected"; blocker = {x = x, y = y, z = z, node = have}
			elseif not replaceable(have) and not vegetation(have) then why = "water or obstruction"; blocker = {x = x, y = y, z = z, node = have}
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
						node = region.get(decoration_pos.x, decoration_pos.y, decoration_pos.z)} end
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
		if why then omission(c.x, c.z, why, blocker)
		else for _, change in ipairs(candidate) do changes[#changes + 1] = change end end
	end
	-- Extend every crossing by three nodes. Only fill gaps above stable support;
	-- avoid clearing solid terrain or structures in the approach headroom.
	for _, c in ipairs(wall.openings) do
		for distance = 0, 3 do
			local x, z = c.x + c.direction.x * distance, c.z + c.direction.z * distance
			-- Any protected node reserved anywhere along the opening preserves
			-- the original behavior: the complete road approach stays untouched.
			local protected_pos = reserved_any(c, "protected")
			local why = protected_pos and "protected" or nil
			local base, blocker, water_seen, water_blocker
			if why then
				if protected_pos.unknown then blocker = {node = "unknown"}
				else blocker = {x = protected_pos.x, y = protected_pos.y, z = protected_pos.z,
					node = region.get(protected_pos.x, protected_pos.y, protected_pos.z)} end
			end
			if not why then
				-- Probe only up to the road's fixed target surface. Raised
				-- approaches are reported below without clearing or filling them.
				for y = ground + 2, ground - M.DEPTH, -1 do
					local name = region.get(x, y, z)
					local stable, failure = supported(x, y, z)
					if stable then base = y; break end
					if failure then blocker = failure end
					if water(name) then
						water_seen = true
						water_blocker = {x = x, y = y, z = z, node = name}
					end
					if not replaceable(name) and not vegetation(name) then
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
						blocker = {x = x, y = y, z = z, node = region.get(x, y, z)}
					end
				end
				-- A road approach must meet the town at its planned ground level.
				-- Leave a raised natural step untouched and report this crossing.
				if base and base > ground then why = "raised terrain"; blocker = {x = x, y = base, z = z, node = region.get(x, base, z)} end
			end
			local proposed = {}
			if base and not why then
				for y = base + 1, ground + 2 do
					local name = region.get(x, y, z)
					if protected({x = x, y = y, z = z}) then why = "protected"; blocker = {x = x, y = y, z = z, node = name}; break end
					if not replaceable(name) and not vegetation(name) then why = "water or obstruction"; blocker = {x = x, y = y, z = z, node = name}; break end
					if y <= ground then
						proposed[#proposed + 1] = {x = x, y = y, z = z, name = c.material or M.BRICK, param2 = 0}
					elseif water(name) then
						why = "water in approach headroom"; blocker = {x = x, y = y, z = z, node = name}; break
					elseif vegetation(name) then
						proposed[#proposed + 1] = {x = x, y = y, z = z, name = "air", param2 = 0}
					end
				end
			end
			if why then omission(x, z, "approach: " .. why, blocker)
			else for _, change in ipairs(proposed) do changes[#changes + 1] = change end end
		end
	end
	return changes, omissions
end

return M
