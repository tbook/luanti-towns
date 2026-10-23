-- Towns: pure intended-node layout for the town volume (ticket #15).
-- No core.* dependency; runs under plain Lua 5.1 and the tests.
--
--   local TL = dofile("src/town_layout.lua")
--   local L = TL.new(plan, ground_y, {
--     heights  = function(x, z) -> surface y (topmost solid node),
--     surface  = function(x, z) -> node name at the surface (optional,
--                default TL.DEFAULT_SURFACE),
--     max_y    = integer, top of the build volume (build_bounds.max.y),
--     holes = see TL.pavement_map,
--   })
--
-- Buildings are not part of this layout: the placed schematics own their
-- boxes, and the layout only grades the ground, clears the airspace above it
-- and paves the squares and streets round them.
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
--        kind = "clear" | "fill" | "support" | "surface" | "pave"
--   L.pavement(x, z)         material name or nil
--   L.palette()              sorted list of every node name the layout can
--                            produce (registration check before any write)
--
-- Rules per column (g = ground_y, h = surface height):
--   y > g   : air (all vegetation / terrain above g)
--   y == g  : pavement, else the natural surface node (nil if h == g and
--             nothing paves it)
--   h < y < g: fill (dirt for the top FILL_DIRT_DEPTH rows below g, stone
--             deeper), so nothing floats
--   g-FILL_DIRT_DEPTH <= y < g and y <= h : "support" (dirt): the builder
--             writes it only where the existing node is not solid, stable
--             ground (air, liquid, ice, falling sand/gravel, vegetation), so
--             every column has solid support under the finished ground even
--             over a cave or overhang
--   deeper existing rows : untouched
-- Pavement: the market and parvis squares first, then other named squares,
-- then principal streets,
-- secondary streets, each in id order; the first claim on a cell wins, so
-- squares and principal streets always beat secondary streets.

local TL = {}

TL.DEFAULT_SURFACE = "mcl_core:dirt_with_grass"
TL.FILL_DIRT = "mcl_core:dirt"
TL.FILL_DEEP = "mcl_core:stone"
TL.FILL_DIRT_DEPTH = 3 -- rows of dirt directly below the finished surface
TL.AIR = "air"

local function in_rect(r, x, z)
	return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2
end

local function load_sibling(name)
	local c = rawget(_G, "core")
	if c and c.get_modpath and c.get_current_modname then
		return dofile(c.get_modpath(c.get_current_modname()) .. "/src/" .. name)
	end
	return dofile("src/" .. name)
end
local plan_sites = load_sibling("plan_sites.lua")

-- Pavement map {[x] = {[z] = material}} from the plan's squares and streets.
-- `extra` (optional, town placement, ticket #45):
--   extra.holes   list of rects that are never paved (the footprints of the
--                 placed schematics: a building owns its own floor)
function TL.pavement_map(plan, extra)
	extra = extra or {}
	local map, rank = {}, {}
	-- City hall foundation: never paved. It lies beside the
	-- market (#106), so this is a guard rather than a cut-out of the square.
	local holes = {}
	local hall = plan.sites and plan.sites.city_hall and plan.sites.city_hall.rect
	if hall then holes[#holes + 1] = hall end
	for _, h in ipairs(extra.holes or {}) do holes[#holes + 1] = h end
	local function is_hole(x, z)
		for _, h in ipairs(holes) do
			if x >= h.x1 and x <= h.x2 and z >= h.z1 and z <= h.z2 then return true end
		end
		return false
	end
	local function claim(rect, material, order)
		if type(material) ~= "string" then
			error("town layout: pavement without a material name", 3)
		end
		for x = rect.x1, rect.x2 do
			local col = map[x]
			if not col then col = {}; map[x] = col; rank[x] = {} end
			for z = rect.z1, rect.z2 do
				if col[z] == nil and not is_hole(x, z) then
					col[z] = material
					rank[x][z] = order
				end
			end
		end
	end
	local ordered_sites = plan_sites.list(plan)
	local square_names, square_lookup = {}, {}
	for _, item in ipairs(ordered_sites) do
		if item.site.kind == "square" or
				(item.site.kind == nil and (item.name == "market" or item.name == "parvis")) then
			square_names[#square_names + 1] = item.name
			square_lookup[item.name] = item.site
		end
	end
	local claimed = {}
	local function claim_square(name)
		local site = square_lookup[name]
		if site then claim(site.rect, site.material, 0); claimed[name] = true end
	end
	-- Keep the medieval market-over-parvis precedence while allowing any
	-- additional named squares to participate after those sites.
	claim_square("market")
	claim_square("parvis")
	for _, name in ipairs(square_names) do
		if not claimed[name] then claim_square(name) end
	end
	for _, kind in ipairs({"principal", "secondary"}) do
		for _, s in ipairs(plan.streets) do
			if s.kind == kind then
				-- A street lane (issue #172) is claimed first, so its material
				-- (a slab) wins over the street's own material on its cells.
				if s.lane then claim(s.lane.rect, s.lane.material, 1) end
				claim(s.rect, s.material, kind == "principal" and 1 or 2)
			end
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
	local g = ground_y

	local set, columns = boundary(plan)
	local pave = TL.pavement_map(plan, {holes = opts.holes})

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
		col[z] = {h = h, surf = sname, pave = pave[x] and pave[x][z]}
	end

	local L = {ground_y = g, columns = columns, max_y = max_y}

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

	function L.surface_height(x, z)
		local r = rec[x] and rec[x][z]
		return r and r.h or nil
	end

	function L.node_at(x, y, z)
		local r = rec[x] and rec[x][z]
		if not r then return nil end
		if y > g then
			return TL.AIR, "clear"
		elseif y == g then
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
