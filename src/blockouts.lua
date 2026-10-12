-- Towns: temporary cathedral and castle blockout silhouettes (ticket #15).
-- Pure Lua, no core.* dependency. These are physical placeholders built from
-- existing VoxeLibre nodes, not handmade schematics.
--
--   local b = dofile("src/blockouts.lua")
--   local blk = b.cathedral(site)   -- site: planner landmark site
--   blk = {
--     cols = {[x] = {[z] = {[dy] = node name}}},  dy is relative to the
--            finished ground level: dy 0 is the floor/ground row, dy >= 1 the
--            airspace above it. Only cells inside site.rect are present; a
--            "air" entry is a carved opening; absent dy are free ground/air.
--     max_dy = tallest dy used (<= b.MAX_HEIGHT),
--     opening = {width, height, center = {x, z}, cells = {{x, z}, ...}}
--              the planned entrance opening (cells on the footprint edge row,
--              centred on site.entrance),
--     names = {node name, ...}  every node name used (for the palette check),
--   }
--
-- Frame: u is the depth from the entrance edge (u = 0 is the footprint row
-- holding site.entrance, u grows inward), v runs along that edge. The same
-- design is mapped onto any of the four sides, so the opening always lies on
-- the entrance row, centred on site.entrance and facing site.facing.
--
-- Cathedral (nominal 32 deep x 20 wide, entrance on the short end):
--   twin 6x6 towers either side of a 5-wide portal on the facade, a pitched
--   brick-red nave roof, a transept crossing with a tall lantern and a
--   narrower chancel at the far end. Light diorite walls, red roofs.
-- Castle (>= 24 x 24, entrance in the long curtain wall facing the town):
--   2-thick battlemented curtain wall, four 6x6 corner towers, a gatehouse
--   with a 5-wide 7-high gate passage and a tall central keep. Mossy stone
--   brick, no red.

local M = {}

M.MAX_HEIGHT = 40 -- must match site_search LANDMARK_BLOCKOUT_HEIGHT

M.CATHEDRAL = {
	wall = "mcl_core:diorite_smooth",
	tower = "mcl_core:diorite",
	roof = "mcl_core:brick_block",
	floor = "mcl_core:andesite_smooth",
	lantern = "mcl_core:sandstonesmooth",
}
M.CASTLE = {
	wall = "mcl_core:stonebrickmossy",
	tower = "mcl_core:stonebrickmossy",
	keep = "mcl_core:andesite",
	trim = "mcl_core:stonebrickcarved",
}

M.PORTAL_WIDTH = 5
M.CATHEDRAL_PORTAL_HEIGHT = 6
M.CASTLE_GATE_HEIGHT = 7

-- Every node name a blockout may use.
function M.names()
	local seen, list = {}, {}
	for _, set in ipairs({M.CATHEDRAL, M.CASTLE}) do
		for _, name in pairs(set) do
			if not seen[name] then
				seen[name] = true
				list[#list + 1] = name
			end
		end
	end
	table.sort(list)
	return list
end

local function frame_for(site)
	local r = site.rect
	local side = site.side
	local f = {side = side}
	if side == "+x" or side == "-x" then
		f.D, f.W = r.x2 - r.x1 + 1, r.z2 - r.z1 + 1
		f.e = site.entrance.z - r.z1
		if side == "+x" then
			f.map = function(u, v) return r.x2 - u, r.z1 + v end
		else
			f.map = function(u, v) return r.x1 + u, r.z1 + v end
		end
		f.entrance_u = side == "+x" and (r.x2 - site.entrance.x) or (site.entrance.x - r.x1)
	elseif side == "+z" or side == "-z" then
		f.D, f.W = r.z2 - r.z1 + 1, r.x2 - r.x1 + 1
		f.e = site.entrance.x - r.x1
		if side == "+z" then
			f.map = function(u, v) return r.x1 + v, r.z2 - u end
		else
			f.map = function(u, v) return r.x1 + v, r.z1 + u end
		end
		f.entrance_u = side == "+z" and (r.z2 - site.entrance.z) or (site.entrance.z - r.z1)
	else
		error("blockouts: bad site side " .. tostring(side))
	end
	return f
end

local function new_canvas(f)
	local c = {cols = {}, max_dy = 0, used = {}}
	local function put(u, v, dy, name)
		local x, z = f.map(u, v)
		local col = c.cols[x]
		if not col then col = {}; c.cols[x] = col end
		local cell = col[z]
		if not cell then cell = {}; col[z] = cell end
		cell[dy] = name
		if name ~= "air" and dy > c.max_dy then c.max_dy = dy end
		c.used[name] = true
	end
	c.put = put
	function c.solid(u, v, dy1, dy2, name)
		for dy = dy1, dy2 do put(u, v, dy, name) end
	end
	function c.carve(u, v, dy1, dy2)
		for dy = dy1, dy2 do put(u, v, dy, "air") end
	end
	return c
end

local function finish(c, f, site, height)
	local names = {}
	for name in pairs(c.used) do names[#names + 1] = name end
	table.sort(names)
	local cells = {}
	for v = f.e - 2, f.e + 2 do
		local x, z = f.map(0, v)
		cells[#cells + 1] = {x = x, z = z}
	end
	return {
		cols = c.cols,
		max_dy = c.max_dy,
		opening = {
			width = M.PORTAL_WIDTH, height = height,
			center = {x = site.entrance.x, z = site.entrance.z}, cells = cells,
		},
		names = names,
	}
end

local function check_site(site, what, mind, minw)
	if type(site) ~= "table" or type(site.rect) ~= "table" or type(site.entrance) ~= "table" then
		error("blockouts: " .. what .. " site needs rect and entrance", 3)
	end
	local f = frame_for(site)
	if f.entrance_u ~= 0 then
		error(("blockouts: %s entrance is not on the footprint edge row"):format(what), 3)
	end
	if f.D < mind or f.W < minw then
		error(("blockouts: %s footprint %dx%d is smaller than the design %dx%d"):format(
			what, f.D, f.W, mind, minw), 3)
	end
	return f
end

------------------------------------------------------------------------
-- Cathedral
------------------------------------------------------------------------
function M.cathedral(site)
	local f = check_site(site, "cathedral", 32, 20)
	local m = M.CATHEDRAL
	local vo = math.floor((f.W - 20) / 2) -- design frame is centred across
	local e = f.e - vo
	if e < 8 or e > 11 then
		error(("blockouts: cathedral entrance offset %d is not centred on the facade"):format(f.e))
	end
	local c = new_canvas(f)
	local function V(v) return v + vo end
	local function solid(u, v, h1, h2, name) c.solid(u, V(v), h1, h2, name) end
	local function put(u, v, dy, name) c.put(u, V(v), dy, name) end
	local function floor(u, v) c.put(u, V(v), 0, m.floor) end
	local function roofcells(u, v, rh) solid(u, v, rh - 1, rh, m.roof) end

	-- Nave: u 0..25, v 5..14 (interior v 6..13), pitched roof 10..14 high.
	for u = 0, 25 do
		local crossing = u >= 12 and u <= 19
		for v = 5, 14 do
			if not crossing then
				local rh = 10 + math.min(v - 5, 14 - v)
				local ring = u == 0 or u == 25 or v == 5 or v == 14
				if u == 25 and v >= 7 and v <= 12 then ring = false end -- chancel arch
				if ring then
					solid(u, v, 1, rh, m.wall)
					if u == 0 then floor(u, v) end
				else
					floor(u, v)
					roofcells(u, v, rh)
				end
			end
		end
	end

	-- Transept arms: u 12..19, v 0..4 and v 15..19, pitched along u.
	for u = 12, 19 do
		local rh = 10 + math.min(u - 12, 19 - u)
		for _, range in ipairs({{0, 4}, {15, 19}}) do
			for v = range[1], range[2] do
				if v == 0 or v == 19 or u == 12 or u == 19 then
					solid(u, v, 1, rh, m.wall)
				else
					floor(u, v)
					roofcells(u, v, rh)
				end
			end
		end
	end

	-- Crossing: u 12..19, v 5..14, flat roof at 15..16 with clerestory walls
	-- and arches (dy 1..8) to the nave and arms; lantern tower on top.
	for u = 12, 19 do
		for v = 5, 14 do
			local edge = u == 12 or u == 19 or v == 5 or v == 14
			if edge then
				solid(u, v, 1, 16, m.wall)
				local arch
				if u == 12 or u == 19 then
					arch = v >= 6 and v <= 13
				else
					arch = u >= 13 and u <= 18
				end
				if arch then
					c.carve(u, V(v), 1, 8)
					floor(u, v)
				end
			else
				floor(u, v)
				roofcells(u, v, 16)
			end
		end
	end
	for a = 0, 3 do
		for b = 0, 3 do
			local ring = math.min(a, b, 3 - a, 3 - b)
			solid(14 + a, 8 + b, 17, 19, m.lantern)
			solid(14 + a, 8 + b, 20, 20 + ring, m.roof)
		end
	end

	-- Chancel: u 26..31, v 6..13 (interior v 7..12), flat roof at 9..10.
	for u = 26, 31 do
		for v = 6, 13 do
			if v == 6 or v == 13 or u == 31 then
				solid(u, v, 1, 10, m.wall)
			else
				floor(u, v)
				roofcells(u, v, 10)
			end
		end
	end

	-- Facade towers, solid, with a stepped brick cap.
	for _, v0 in ipairs({0, 14}) do
		for a = 0, 5 do
			for b = 0, 5 do
				local ring = math.min(a, b, 5 - a, 5 - b)
				solid(a, v0 + b, 1, 23, m.tower)
				solid(a, v0 + b, 24, 24 + ring, m.roof)
			end
		end
	end

	-- Portal through the facade (u = 0), aligned with site.entrance.
	for v = e - 2, e + 2 do
		c.carve(0, V(v), 1, M.CATHEDRAL_PORTAL_HEIGHT)
		floor(0, v)
	end
	return finish(c, f, site, M.CATHEDRAL_PORTAL_HEIGHT)
end

------------------------------------------------------------------------
-- Castle
------------------------------------------------------------------------
function M.castle(site)
	local f = check_site(site, "castle", 24, 24)
	local m = M.CASTLE
	local D, W, e = f.D, f.W, f.e
	if e < 2 or e > W - 3 then
		error("blockouts: castle entrance too close to a corner")
	end
	local c = new_canvas(f)
	local function crenel(u, v, dy, name)
		if (u + v) % 2 == 0 then c.put(u, v, dy, name) end
	end

	-- Curtain wall, 2 thick, height 9 plus crenels at 10.
	for u = 0, D - 1 do
		for v = 0, W - 1 do
			if u < 2 or u >= D - 2 or v < 2 or v >= W - 2 then
				c.solid(u, v, 1, 9, m.wall)
				crenel(u, v, 10, m.wall)
			end
		end
	end
	-- Corner towers 6x6, solid to 14 with a crenelled top and a cap stud.
	for _, u0 in ipairs({0, D - 6}) do
		for _, v0 in ipairs({0, W - 6}) do
			for a = 0, 5 do
				for b = 0, 5 do
					local u, v = u0 + a, v0 + b
					c.solid(u, v, 1, 14, m.tower)
					local ring = math.min(a, b, 5 - a, 5 - b)
					if ring == 0 then
						crenel(u, v, 15, m.trim)
					elseif ring == 2 then
						c.solid(u, v, 15, 17, m.trim)
					end
				end
			end
		end
	end
	-- Gatehouse on the entrance side: u 0..3, v e-4..e+4, height 12.
	for u = 0, 3 do
		for v = math.max(0, e - 4), math.min(W - 1, e + 4) do
			c.solid(u, v, 1, 12, m.trim)
			crenel(u, v, 13, m.trim)
		end
	end
	-- Keep: 10 x 10 at the far side of the courtyard, 22 high with turrets.
	local ku0, kv0 = D - 14, math.floor(W / 2) - 5
	for a = 0, 9 do
		for b = 0, 9 do
			local u, v = ku0 + a, kv0 + b
			c.solid(u, v, 1, 22, m.keep)
			if (a == 0 or a == 9) and (b == 0 or b == 9) then
				c.solid(u, v, 23, 26, m.keep)
			elseif a == 0 or a == 9 or b == 0 or b == 9 then
				crenel(u, v, 23, m.keep)
			end
		end
	end
	-- Gate passage through the curtain and gatehouse, 5 wide, 7 high.
	for u = 0, 3 do
		for v = e - 2, e + 2 do
			c.carve(u, v, 1, M.CASTLE_GATE_HEIGHT)
		end
	end
	return finish(c, f, site, M.CASTLE_GATE_HEIGHT)
end

return M
