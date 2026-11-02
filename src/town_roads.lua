-- Outside-road helpers shared by Roman and medieval towns (#357): road openings
-- in a town boundary, and the cobblestone ramps that grade them down to natural
-- terrain. Pure Lua: no Minetest globals at load; the world is reached only
-- through the region, node_info and protected arguments passed by callers.
local M = {}

-- Search for support up to 32 nodes below the town surface. Beyond that,
-- an unobstructed wall column hangs from its normal level top for this same
-- maximum depth instead of disappearing entirely.
M.DEPTH = 32

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

-- Group openings into contiguous crossings (same street, direction and wall
-- line) and return each crossing's full run of columns, which is graded as a
-- ramp of the opening's full width.
function M.crossings(openings)
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
		local columns
		for i, item in ipairs(list) do
			if columns and item.t == list[i - 1].t + 1 then columns[#columns + 1] = item.o
			else columns = {item.o}; out[#out + 1] = columns end
		end
	end
	return out
end

-- Grade each bare crossing with the outside-road ramp. Returns the ramp
-- changes and a list of failed omissions; graded openings are flagged so
-- inspect skips the flat stub. A failed crossing keeps the legacy behavior.
function M.grade(openings, ground, region, node_info, protected)
	local changes, failures = {}, {}
	for _, columns in ipairs(M.crossings(openings)) do
		local ramp, omissions = M.approach(columns, ground, region, node_info, protected)
		if #omissions > 0 then failures[#failures + 1] = omissions[1]
		else
			for _, c in ipairs(ramp) do changes[#changes + 1] = c end
			for _, c in ipairs(columns) do c.graded = true end
		end
	end
	return changes, failures
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

local directions = {{x = 1, z = 0}, {x = -1, z = 0}, {x = 0, z = 1}, {x = 0, z = -1}}
local function key(x, z) return x .. ":" .. z end
local function inside(rects, x, z)
	for _, r in ipairs(rects) do
		if x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 then return true end
	end
	return false
end

-- The street that a boundary edge at (x,z) facing d opens onto, or nil. A
-- crossing follows the road's long axis, not its side.
function M.street_at(plan, x, z, d)
	for _, s in ipairs(plan.streets) do
		local r = s.rect
		if x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 then
			if d.x ~= 0 and r.x2 - r.x1 >= r.z2 - r.z1
					or d.z ~= 0 and r.z2 - r.z1 >= r.x2 - r.x1 then return s end
		end
	end
end

-- Road exits of a town boundary: each exposed edge with a street along its
-- long axis gives an opening on the first column outside the town. Returns the
-- openings sorted by position; empty when the plan has no boundary or streets.
function M.exits(plan)
	if not plan.boundary or not plan.streets then return {} end
	local rects, openings = plan.boundary.rects, {}
	for _, r in ipairs(rects) do
		for x = r.x1, r.x2 do
			for z = r.z1, r.z2 do
				for _, d in ipairs(directions) do
					local ox, oz = x + d.x, z + d.z
					local s = not inside(rects, ox, oz) and M.street_at(plan, x, z, d)
					if s then
						openings[key(ox, oz)] = {x = ox, z = oz, direction = d, street = s.id, kind = s.kind,
							material = s.material,
							street_rect = {x1 = s.rect.x1, z1 = s.rect.z1,
								x2 = s.rect.x2, z2 = s.rect.z2}}
					end
				end
			end
		end
	end
	local list = {}
	for _, o in pairs(openings) do list[#list + 1] = o end
	table.sort(list, function(a, b) return a.x == b.x and a.z < b.z or a.x < b.x end)
	return list
end

return M
