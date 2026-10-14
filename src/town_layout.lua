-- Towns: pure intended-node layout for the town volume (ticket #15).
-- No core.* dependency; runs under plain Lua 5.1 and the tests.
--
--   local TL = dofile("src/town_layout.lua")(blockouts)
--   local L = TL.new(plan, ground_y, {
--     heights  = function(x, z) -> surface y (topmost solid node),
--     surface  = function(x, z) -> node name at the surface (optional,
--                default TL.DEFAULT_SURFACE),
--     max_y    = integer, top of the build volume (build_bounds.max.y),
--     max_height = LANDMARK_BLOCKOUT_HEIGHT (default blockouts.MAX_HEIGHT),
--   })
--
-- L describes the finished town for every column of the boundary union:
--   L.ground_y
--   L.in_town(x, z)          boolean, inside the boundary rect union
--   L.columns                list of {x, z} (sorted by x then z)
--   L.column_range(x, z)     ylo, yhi: the rows the builder owns in that
--                            column (ylo = h+1 for a filled column, else the
--                            finished ground row; yhi = opts.max_y)
--   L.node_at(x, y, z)       name, kind | nil
--        nil  = leave the existing node (outside the town, or a row the
--               layout does not touch, e.g. the unchanged surface row).
--        kind = "clear" | "fill" | "support" | "surface" | "pave" | "landmark"
--   L.pavement(x, z)         material name or nil
--   L.landmark_dy(x, z)      sparse {[dy]=name} for a landmark column or nil
--   L.palette()              sorted list of every node name the layout can
--                            produce (registration check before any write)
--   L.max_dy                 tallest landmark dy actually produced
--   L.openings               {cathedral = {...}, castle = {...}} the
--                            blockouts' opening data
--
-- Rules per column (g = ground_y, h = surface height):
--   y > g   : landmark node, else air (all vegetation / terrain above g)
--   y == g  : landmark floor, else pavement, else the natural surface node
--             (nil if h == g and nothing paves it)
--   h < y < g: fill (dirt for the top FILL_DIRT_DEPTH rows below g, stone
--             deeper), so nothing floats
--   g-FILL_DIRT_DEPTH <= y < g and y <= h : "support" (dirt): the builder
--             writes it only where the existing node is not solid, stable
--             ground (air, liquid, ice, falling sand/gravel, vegetation), so
--             every column has solid support under the finished ground even
--             over a cave or overhang
--   deeper existing rows : untouched
-- Pavement: market and parvis squares first, then principal streets, then
-- secondary streets, each in id order; the first claim on a cell wins, so
-- squares and principal streets always beat secondary streets.

return function(blockouts)

local TL = {}

TL.DEFAULT_SURFACE = "mcl_core:dirt_with_grass"
TL.FILL_DIRT = "mcl_core:dirt"
TL.FILL_DEEP = "mcl_core:stone"
TL.FILL_DIRT_DEPTH = 3 -- rows of dirt directly below the finished surface
TL.AIR = "air"

local function in_rect(r, x, z)
	return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2
end

-- Pavement map {[x] = {[z] = material}} from the plan's squares and streets.
function TL.pavement_map(plan)
	local map, rank = {}, {}
	-- City hall foundation (profile plans): a hole in the market pavement.
	local hall = plan.sites.city_hall and plan.sites.city_hall.rect
	local function claim(rect, material, order)
		if type(material) ~= "string" then
			error("town layout: pavement without a material name", 3)
		end
		for x = rect.x1, rect.x2 do
			local col = map[x]
			if not col then col = {}; map[x] = col; rank[x] = {} end
			for z = rect.z1, rect.z2 do
				local held = hall and x >= hall.x1 and x <= hall.x2
					and z >= hall.z1 and z <= hall.z2
				if col[z] == nil and not held then
					col[z] = material
					rank[x][z] = order
				end
			end
		end
	end
	for _, name in ipairs({"market", "parvis"}) do
		local site = plan.sites[name]
		claim(site.rect, site.material, 0)
	end
	for _, kind in ipairs({"principal", "secondary"}) do
		for _, s in ipairs(plan.streets) do
			if s.kind == kind then claim(s.rect, s.material, kind == "principal" and 1 or 2) end
		end
	end
	return map
end

-- Boundary union as a sorted column list plus membership set.
local function boundary(plan)
	local set, list = {}, {}
	for _, r in ipairs(plan.boundary.rects) do
		for x = r.x1, r.x2 do
			local col = set[x]
			if not col then col = {}; set[x] = col end
			for z = r.z1, r.z2 do
				if not col[z] then
					col[z] = true
					list[#list + 1] = {x = x, z = z}
				end
			end
		end
	end
	table.sort(list, function(a, b)
		if a.x ~= b.x then return a.x < b.x end
		return a.z < b.z
	end)
	return set, list
end

function TL.new(plan, ground_y, opts)
	opts = opts or {}
	local heights = opts.heights
	if type(heights) ~= "function" then error("town layout: opts.heights required", 2) end
	if type(ground_y) ~= "number" or ground_y ~= math.floor(ground_y) then
		error("town layout: ground_y must be an integer", 2)
	end
	local surface_fn = opts.surface or function() return TL.DEFAULT_SURFACE end
	local max_y = opts.max_y
	if type(max_y) ~= "number" then error("town layout: opts.max_y required", 2) end
	local max_height = opts.max_height or blockouts.MAX_HEIGHT
	local g = ground_y

	local set, columns = boundary(plan)
	local pave = TL.pavement_map(plan)

	-- Landmarks: merged sparse columns, kept only inside the boundary.
	local landmark, max_dy, openings = {}, 0, {}
	local lm_names = {}
	for _, spec in ipairs({{"cathedral", blockouts.cathedral}, {"castle", blockouts.castle}}) do
		local site = plan.sites[spec[1]]
		local blk = spec[2](site)
		openings[spec[1]] = blk.opening
		if blk.max_dy > max_height then
			error(("town layout: %s blockout is %d high, limit %d"):format(spec[1], blk.max_dy, max_height))
		end
		if blk.max_dy > max_dy then max_dy = blk.max_dy end
		for _, n in ipairs(blk.names) do lm_names[n] = true end
		for x, col in pairs(blk.cols) do
			for z, cell in pairs(col) do
				if not (set[x] and set[x][z]) then
					error(("town layout: %s blockout leaves the boundary at (%d,%d)"):format(spec[1], x, z))
				end
				local lc = landmark[x]
				if not lc then lc = {}; landmark[x] = lc end
				if lc[z] then
					error(("town layout: blockouts overlap at (%d,%d)"):format(x, z))
				end
				lc[z] = cell
			end
		end
	end
	if g + max_dy > max_y then
		error(("town layout: blockout top y=%d is above the build volume top y=%d"):format(
			g + max_dy, max_y))
	end

	local rec = {}
	local surfaces = {}
	for _, c in ipairs(columns) do
		local x, z = c.x, c.z
		local h = heights(x, z)
		if type(h) ~= "number" or h ~= math.floor(h) then
			error(("town layout: no surface height for column (%d,%d)"):format(x, z))
		end
		local sname = surface_fn(x, z)
		if type(sname) ~= "string" then
			error(("town layout: no surface node for column (%d,%d)"):format(x, z))
		end
		surfaces[sname] = true
		local col = rec[x]
		if not col then col = {}; rec[x] = col end
		col[z] = {h = h, surf = sname, pave = pave[x] and pave[x][z], blk = landmark[x] and landmark[x][z]}
	end

	local L = {ground_y = g, columns = columns, max_dy = max_dy, openings = openings, max_y = max_y}

	function L.in_town(x, z)
		return set[x] ~= nil and set[x][z] == true
	end

	function L.column_range(x, z)
		local r = rec[x] and rec[x][z]
		if not r then return nil end
		local support = g - TL.FILL_DIRT_DEPTH
		if r.h < g then return math.min(r.h + 1, support), max_y end
		return support, max_y
	end

	function L.pavement(x, z)
		local r = rec[x] and rec[x][z]
		return r and r.pave or nil
	end

	function L.landmark_dy(x, z)
		local r = rec[x] and rec[x][z]
		return r and r.blk or nil
	end

	function L.surface_height(x, z)
		local r = rec[x] and rec[x][z]
		return r and r.h or nil
	end

	function L.node_at(x, y, z)
		local r = rec[x] and rec[x][z]
		if not r then return nil end
		if y > g then
			local n = r.blk and r.blk[y - g]
			if n then
				return n, (n == TL.AIR) and "clear" or "landmark"
			end
			return TL.AIR, "clear"
		elseif y == g then
			local n = r.blk and r.blk[0]
			if n then return n, "landmark" end
			if r.pave then return r.pave, "pave" end
			if r.h == g then return nil end
			return r.surf, "surface"
		elseif y > r.h then
			if y > g - 1 - TL.FILL_DIRT_DEPTH then return TL.FILL_DIRT, "fill" end
			return TL.FILL_DEEP, "fill"
		elseif y >= g - TL.FILL_DIRT_DEPTH then
			return TL.FILL_DIRT, "support"
		end
		return nil
	end

	function L.palette()
		local seen = {[TL.AIR] = true, [TL.FILL_DIRT] = true, [TL.FILL_DEEP] = true}
		for n in pairs(lm_names) do seen[n] = true end
		for n in pairs(surfaces) do seen[n] = true end
		for _, col in pairs(pave) do
			for _, m in pairs(col) do seen[m] = true end
		end
		local list = {}
		for n in pairs(seen) do list[#list + 1] = n end
		table.sort(list)
		return list
	end

	return L
end

-- Write-confinement check: (x, y, z) must be inside the inclusive bounds
-- {min = {x,y,z}, max = {x,y,z}} AND inside the plan's boundary column union.
-- `plan` may be passed as a prebuilt membership function (x, z) -> boolean.
function TL.confined(in_town, bounds, x, y, z)
	if x < bounds.min.x or x > bounds.max.x or y < bounds.min.y or y > bounds.max.y
			or z < bounds.min.z or z > bounds.max.z then
		return false
	end
	return in_town(x, z) and true or false
end

TL.in_rect = in_rect

return TL

end
