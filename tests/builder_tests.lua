-- Builder tests (ticket #15): pure blockouts/layout and a recording fake world.
-- Loaded by tests/run.lua, which passes its check helpers:
--   loadfile("tests/builder_tests.lua")(eq, fails, placement, planner, site_search_factory,
--     builder_factory)
local eq, fails, placement, planner, ss_factory, builder_factory = ...
local ss = ss_factory(placement, planner)
local builder = builder_factory(placement, planner)
local blockouts = builder.blockouts
local TL = builder.layout

local BRICK = "mcl_core:brick_block"
local STONEBRICK, COBBLE = "mcl_core:stonebrick", "mcl_core:cobble"
local GRASS, DIRT, STONE = "mcl_core:dirt_with_grass", "mcl_core:dirt", "mcl_core:stone"

local function nodes_table()
	local t = {
		air = nil,
		[GRASS] = {walkable = true}, [DIRT] = {walkable = true}, [STONE] = {walkable = true},
		[STONEBRICK] = {walkable = true}, [COBBLE] = {walkable = true},
		["mcl_core:tree"] = {walkable = true, clearable = true},
		["mcl_core:leaves"] = {walkable = true, clearable = true},
		["mcl_core:water_source"] = {liquid = true},
	}
	for _, n in ipairs(blockouts.names()) do t[n] = {walkable = true} end
	return t
end

------------------------------------------------------------------------
-- Blockouts: every side, openings, bounds
------------------------------------------------------------------------
local function fake_site(rect, side, entrance)
	return {rect = rect, side = side, entrance = entrance}
end
local FACING = {["-z"] = {0, -1}, ["+z"] = {0, 1}, ["-x"] = {-1, 0}, ["+x"] = {1, 0}}
for _, spec in ipairs({
	{"cathedral", blockouts.cathedral, 32, 20},
	{"castle", blockouts.castle, 26, 30},
	{"castle", blockouts.castle, 30, 26},
}) do
	local name, fn, D, W = spec[1], spec[2], spec[3], spec[4]
	for _, side in ipairs({"+x", "-x", "+z", "-z"}) do
		-- footprint with depth D along the facing axis, W across.
		local rect
		if side == "+x" or side == "-x" then
			rect = {x1 = 100, z1 = -40, x2 = 100 + D - 1, z2 = -40 + W - 1}
		else
			rect = {x1 = 100, z1 = -40, x2 = 100 + W - 1, z2 = -40 + D - 1}
		end
		local ent
		local e = math.floor((W - 1) / 2)
		if side == "+x" then ent = {x = rect.x2, z = rect.z1 + e}
		elseif side == "-x" then ent = {x = rect.x1, z = rect.z1 + e}
		elseif side == "+z" then ent = {x = rect.x1 + e, z = rect.z2}
		else ent = {x = rect.x1 + e, z = rect.z1} end
		local label = name .. " " .. D .. "x" .. W .. " " .. side
		local blk = fn(fake_site(rect, side, ent))
		eq(blk.max_dy <= blockouts.MAX_HEIGHT, true, label .. ": height within clearance")
		eq(blk.max_dy >= 15, true, label .. ": a tall silhouette")
		local inside = true
		for x, col in pairs(blk.cols) do
			for z in pairs(col) do
				if x < rect.x1 or x > rect.x2 or z < rect.z1 or z > rect.z2 then inside = false end
			end
		end
		eq(inside, true, label .. ": inside the footprint")
		-- Opening: 5 cells on the entrance row, centred on the entrance, 3+
		-- high and clear (air or untouched) for its whole height.
		eq(#blk.opening.cells, 5, label .. ": opening width")
		eq(blk.opening.height >= 3, true, label .. ": opening height")
		local centred, clear = false, true
		for _, c in ipairs(blk.opening.cells) do
			if c.x == ent.x and c.z == ent.z then centred = true end
			local cell = blk.cols[c.x][c.z]
			for dy = 1, blk.opening.height do
				if cell[dy] ~= "air" then clear = false end
			end
			-- on the entrance row of the footprint
			local on_edge
			if side == "+x" then on_edge = c.x == rect.x2
			elseif side == "-x" then on_edge = c.x == rect.x1
			elseif side == "+z" then on_edge = c.z == rect.z2
			else on_edge = c.z == rect.z1 end
			eq(on_edge, true, label .. ": opening cell on the entrance edge")
		end
		eq(centred, true, label .. ": opening contains the entrance")
		eq(clear, true, label .. ": opening carved")
	end
end

-- A footprint too small, an entrance off the edge, and an off-centre
-- cathedral door are rejected rather than mis-built.
fails(function()
	blockouts.cathedral(fake_site({x1 = 0, z1 = 0, x2 = 20, z2 = 10}, "+x", {x = 20, z = 5}))
end, "smaller than the design", "small cathedral footprint")
fails(function()
	blockouts.castle(fake_site({x1 = 0, z1 = 0, x2 = 29, z2 = 25}, "+x", {x = 10, z = 5}))
end, "not on the footprint edge", "entrance off the edge row")
fails(function()
	blockouts.cathedral(fake_site({x1 = 0, z1 = 0, x2 = 31, z2 = 19}, "+x", {x = 31, z = 2}))
end, "not centred", "cathedral door off centre")

------------------------------------------------------------------------
-- Layout: columns, pavement priority
------------------------------------------------------------------------
local pav = TL.pavement_map({
	sites = {
		market = {rect = {x1 = 0, z1 = 0, x2 = 5, z2 = 5}, material = "m:square"},
		parvis = {rect = {x1 = 20, z1 = 0, x2 = 22, z2 = 2}, material = "m:square"},
	},
	streets = {
		{id = 1, kind = "secondary", rect = {x1 = 3, z1 = 3, x2 = 9, z2 = 4}, material = "m:cobble"},
		{id = 2, kind = "principal", rect = {x1 = 4, z1 = 4, x2 = 12, z2 = 9}, material = "m:brick"},
	},
})
eq(pav[1][1], "m:square", "square cell")
eq(pav[4][4], "m:square", "square beats principal and secondary")
eq(pav[8][4], "m:brick", "principal beats secondary where they overlap")
eq(pav[8][3], "m:cobble", "secondary where alone")
eq(pav[12][9], "m:brick", "principal street end")
eq(pav[13], nil, "no pavement outside")

-- Column semantics: cut, fill, level, with a one-rect plan.
do
	local plan = {
		boundary = {rects = {{x1 = 0, z1 = 0, x2 = 3, z2 = 0}}},
		sites = {market = {rect = {x1 = 0, z1 = 0, x2 = 0, z2 = 0}, material = STONEBRICK},
			parvis = {rect = {x1 = 100, z1 = 100, x2 = 100, z2 = 100}, material = STONEBRICK}},
		streets = {},
	}
	local fake_bo = {
		MAX_HEIGHT = 40, names = function() return {} end,
		cathedral = function() return {cols = {}, max_dy = 0, names = {}, opening = {}} end,
		castle = function() return {cols = {}, max_dy = 0, names = {}, opening = {}} end,
	}
	local T = dofile("src/town_layout.lua")(fake_bo)
	-- heights: x0 paved level, x1 high (cut), x2 low (fill 6), x3 level unpaved.
	local hs = {[0] = 20, 23, 14, 20}
	local L = T.new(plan, 20, {heights = function(x) return hs[x] end,
		surface = function() return "x:grass" end, max_y = 30})
	eq(L.node_at(0, 20, 0), STONEBRICK, "paved level column: pavement at ground")
	eq(L.node_at(0, 21, 0), "air", "paved level column: air above")
	eq(L.node_at(0, 19, 0), nil, "paved level column: ground untouched below")
	eq(L.node_at(1, 22, 0), "air", "cut column: cleared above ground")
	eq(L.node_at(1, 21, 0), "air", "cut column: cut to ground")
	eq(L.node_at(1, 20, 0), "x:grass", "cut column: natural surface at ground")
	eq(L.node_at(1, 19, 0), nil, "cut column: below ground untouched")
	local lo, hi = L.column_range(1, 0)
	eq(lo, 20, "cut column range starts at ground")
	eq(hi, 30, "cut column range top")
	eq(L.node_at(2, 20, 0), "x:grass", "fill column: surface at ground")
	eq(L.node_at(2, 19, 0), DIRT, "fill column: dirt under the surface")
	eq(L.node_at(2, 17, 0), DIRT, "fill column: third dirt row")
	eq(L.node_at(2, 16, 0), STONE, "fill column: stone deeper")
	eq(L.node_at(2, 15, 0), STONE, "fill column: stone to the old surface")
	eq(L.node_at(2, 14, 0), nil, "fill column: old surface untouched")
	lo = L.column_range(2, 0)
	eq(lo, 15, "fill column range starts above the old surface")
	eq(L.node_at(3, 20, 0), nil, "level unpaved column: nothing to do at ground")
	eq(L.node_at(3, 21, 0), "air", "level unpaved column: airspace cleared")
	eq(L.node_at(9, 21, 0), nil, "outside the boundary: untouched")
	eq(L.in_town(3, 0), true, "in_town inside")
	eq(L.in_town(4, 0), false, "in_town outside")
	eq(TL.confined(L.in_town, {min = {x = 0, y = 10, z = 0}, max = {x = 3, y = 30, z = 0}}, 3, 30, 0), true,
		"confined: corner of bounds")
	eq(TL.confined(L.in_town, {min = {x = 0, y = 10, z = 0}, max = {x = 3, y = 30, z = 0}}, 3, 31, 0), false,
		"confined: above bounds")
	eq(TL.confined(L.in_town, {min = {x = 0, y = 10, z = 0}, max = {x = 9, y = 30, z = 0}}, 5, 20, 0), false,
		"confined: inside bounds but outside the boundary union")
	fails(function()
		T.new(plan, 20, {heights = function(x) return hs[x] end, max_y = 30, max_height = 40})
		T.new(plan, 20, {heights = function() end, max_y = 30})
	end, "no surface height", "missing height rejected")
end

------------------------------------------------------------------------
-- Fake world
------------------------------------------------------------------------
local function terrain(x, z)
	return 40 + math.floor(4 + 4 * math.sin(x / 9) * math.sin(z / 11 + 1))
end

local function new_world(spec)
	spec = spec or {}
	local w = {over = {}, writes = {}, commits = 0, opened = 0}
	local nodes = spec.nodes or nodes_table()
	local function tree_at(x, z) return (x * 31 + z * 17) % 53 == 0 end
	local function base(x, y, z)
		local h = terrain(x, z)
		if y < h - 3 then return STONE end
		if y < h then return DIRT end
		if y == h then return GRASS end
		if tree_at(x, z) and y <= h + 5 then return "mcl_core:tree" end
		for dx = -1, 1 do
			for dz = -1, 1 do
				if tree_at(x + dx, z + dz) and y >= terrain(x + dx, z + dz) + 4
						and y <= terrain(x + dx, z + dz) + 6 then
					return "mcl_core:leaves"
				end
			end
		end
		return "air"
	end
	function w.get(x, y, z)
		local c = w.over[x]
		local n = c and c[z] and c[z][y]
		return n or base(x, y, z)
	end
	w.base = base
	local env = {
		node_info = function(name) return nodes[name] end,
		log = function(level, msg)
			w.logs = w.logs or {}
			w.logs[#w.logs + 1] = level .. ": " .. msg
		end,
		open_region = function(minp, maxp)
			w.opened = w.opened + 1
			if spec.open_error then return nil, spec.open_error end
			local r = {}
			function r.get(x, y, z)
				if spec.unloaded and spec.unloaded(x, y, z) then return "ignore" end
				if spec.override and spec.override(x, y, z) then return spec.override(x, y, z) end
				return w.get(x, y, z)
			end
			function r.get_param2(x, y, z) return (x + z) % 8 end
			function r.set(x, y, z, name, p2)
				w.writes[#w.writes + 1] = {x = x, y = y, z = z, name = name, p2 = p2}
				w.over[x] = w.over[x] or {}
				w.over[x][z] = w.over[x][z] or {}
				w.over[x][z][y] = name
			end
			function r.commit() w.commits = w.commits + 1 end
			return r
		end,
	}
	w.env = env
	return w
end

local C = {}
for k, v in pairs(ss.CONSTANTS) do C[k] = v end
C.BLOCKOUT_CLEARANCE = C.LANDMARK_BLOCKOUT_HEIGHT + C.BLOCKOUT_MARGIN

-- A site_search-shaped result for `seed` over the fake terrain.
local function make_result(seed, cx, cz)
	local plan = planner.plan({x = cx, z = cz}, seed)
	local cols = ss.boundary_columns(plan.boundary.rects)
	local heights, list = {}, {}
	local lo, hi
	for _, c in ipairs(cols) do
		local h = terrain(c.x, c.z)
		heights[c.x] = heights[c.x] or {}
		heights[c.x][c.z] = h
		list[#list + 1] = h
		lo = (not lo or h < lo) and h or lo
		hi = (not hi or h > hi) and h or hi
	end
	local g = ss.median(list)
	local bb = ss.build_bounds(plan.bounds, g, lo, hi, C)
	return {
		center = {x = cx, z = cz}, plan = plan, ground_y = g, heights = heights,
		columns = #cols, min_height = lo, max_height = hi, build_bounds = bb,
		build_volume = ss.build_volume(bb, C),
	}
end

local function in_rect(r, x, z)
	return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2
end

local function in_boundary(plan, x, z)
	for _, r in ipairs(plan.boundary.rects) do
		if in_rect(r, x, z) then return true end
	end
	return false
end

-- Independent expectation of the pavement material of a cell.
local function expected_pavement(plan, x, z)
	for _, name in ipairs({"market", "parvis"}) do
		if in_rect(plan.sites[name].rect, x, z) then return plan.sites[name].material end
	end
	for _, kind in ipairs({"principal", "secondary"}) do
		for _, s in ipairs(plan.streets) do
			if s.kind == kind and in_rect(s.rect, x, z) then return s.material end
		end
	end
end

local function is_solid(nodes, name)
	local i = nodes[name]
	return i ~= nil and i.walkable and not i.liquid and not i.clearable
end

------------------------------------------------------------------------
-- End to end on the fake world
------------------------------------------------------------------------
local walk_nodes = nodes_table()

-- Walkable at (x,z): solid ground row g with 2 clear air rows above.
local function walkable(get, g, x, z)
	return is_solid(walk_nodes, get(x, g, z)) and get(x, g + 1, z) == "air"
		and get(x, g + 2, z) == "air"
end

local function flood(get, g, plan, start, allow)
	local seen, queue, qi = {}, {{start.x, start.z}}, 1
	seen[start.x .. "," .. start.z] = true
	while qi <= #queue do
		local x, z = queue[qi][1], queue[qi][2]
		qi = qi + 1
		for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
			local nx, nz = x + d[1], z + d[2]
			local key = nx .. "," .. nz
			if not seen[key] and in_boundary(plan, nx, nz) and walkable(get, g, nx, nz)
					and allow(nx, nz) then
				seen[key] = true
				queue[#queue + 1] = {nx, nz}
			end
		end
	end
	return seen
end

local function site_cells_inside(plan, name, x, z)
	return in_rect(plan.sites[name].rect, x, z)
end

local SEEDS = {{1, 100, -50}, {7, -240, 130}, {20260101, 0, 0}}
for _, spec in ipairs(SEEDS) do
	local seed = spec[1]
	local label = "seed " .. seed .. ": "
	local result = make_result(seed, spec[2], spec[3])
	local plan, g, bb = result.plan, result.ground_y, result.build_bounds
	eq(result.max_height - result.min_height <= 8, true, label .. "terrain varies at most 8")
	eq(result.max_height - result.min_height >= 4, true, label .. "terrain really varies")
	local w = new_world()
	local before_trees = false
	for x = plan.bounds.x1, plan.bounds.x2 do
		for z = plan.bounds.z1, plan.bounds.z2 do
			if w.base(x, g + 5, z) == "mcl_core:tree" then before_trees = true end
		end
	end
	eq(before_trees, true, label .. "fixture has trees to clear")

	local summary, msg, code = builder.build(result, nil, w.env)
	eq(msg, nil, label .. "build ok (" .. tostring(msg) .. ")")
	eq(code, nil, label .. "no error code")
	eq(summary ~= nil, true, label .. "summary")
	if summary then
		eq(summary.seed, seed, label .. "summary seed")
		eq(summary.ground_y, g, label .. "summary ground")
		eq(summary.center.x, spec[2], label .. "summary centre x")
		eq(summary.bounds.min.y, bb.min.y, label .. "summary bounds")
		eq(summary.counts.streets, #plan.streets, label .. "summary streets")
		eq(summary.counts.blocks, #plan.blocks, label .. "summary blocks")
		eq(summary.counts.frontage, #plan.frontage, label .. "summary frontage")
		eq(summary.counts.principal + summary.counts.secondary, #plan.streets, label .. "street kinds")
		eq(summary.nodes.changed, #w.writes, label .. "changed count equals writes")
		eq(summary.sites.cathedral.rect, plan.sites.cathedral.rect, label .. "summary cathedral rect")
		eq(summary.sites.market.rect, plan.sites.market.rect, label .. "summary market rect")
		eq(w.commits, 1, label .. "single commit")
	end
	eq(#(w.logs or {}) >= 6, true, label .. "construction sequence logged")

	-- Confinement: every write inside the build bounds and the boundary.
	local oob, outside_town = 0, 0
	for _, wr in ipairs(w.writes) do
		if wr.x < bb.min.x or wr.x > bb.max.x or wr.y < bb.min.y or wr.y > bb.max.y
				or wr.z < bb.min.z or wr.z > bb.max.z then
			oob = oob + 1
		end
		if not in_boundary(plan, wr.x, wr.z) then outside_town = outside_town + 1 end
	end
	eq(oob, 0, label .. "no write outside the build bounds")
	eq(outside_town, 0, label .. "no write outside the boundary union")
	eq(#w.writes > 5000, true, label .. "a real amount of work")

	-- Per column: flat, supported, natural top, pavement union with priority.
	local flat_ok, support_ok, pave_ok, air_ok, top_ok, wrong = true, true, true, true, true, nil
	local paved_cols, total = 0, 0
	for _, c in ipairs(ss.boundary_columns(plan.boundary.rects)) do
		local x, z = c.x, c.z
		total = total + 1
		local h = result.heights[x][z]
		local lm = site_cells_inside(plan, "cathedral", x, z) or site_cells_inside(plan, "castle", x, z)
		local top = w.get(x, g, z)
		if not is_solid(walk_nodes, top) then flat_ok = false; wrong = wrong or ("top " .. x .. "," .. z) end
		-- support: solid from min(h, g) up to g
		for y = math.min(h, g), g do
			if not is_solid(walk_nodes, w.get(x, y, z)) then support_ok = false; wrong = wrong or ("support " .. x .. "," .. y .. "," .. z) end
		end
		if not lm then
			local want = expected_pavement(plan, x, z)
			if want then
				paved_cols = paved_cols + 1
				if top ~= want then pave_ok = false; wrong = wrong or ("pave " .. x .. "," .. z) end
			else
				if top ~= GRASS then top_ok = false; wrong = wrong or ("top material " .. x .. "," .. z .. " " .. tostring(top)) end
			end
			-- airspace above ground is empty to the top of the bounds
			for y = g + 1, bb.max.y do
				if w.get(x, y, z) ~= "air" then air_ok = false; wrong = wrong or ("air " .. x .. "," .. y .. "," .. z) end
			end
		end
	end
	eq(wrong, nil, label .. "first column problem")
	eq(flat_ok, true, label .. "every column has solid ground at the median level")
	eq(support_ok, true, label .. "ground supported all the way down")
	eq(pave_ok, true, label .. "pavement matches the union with priority")
	eq(top_ok, true, label .. "unpaved ground keeps a grass top")
	eq(air_ok, true, label .. "airspace cleared above ground")
	eq(paved_cols > 300, true, label .. "substantial pavement")
	eq(summary and summary.counts.paved_columns, paved_cols, label .. "paved column count")

	-- Both principal-street materials and the cobble secondary appear.
	local seen_mat = {}
	for _, wr in ipairs(w.writes) do
		if wr.y == g then seen_mat[wr.name] = true end
	end
	eq(seen_mat[STONEBRICK], true, label .. "stonebrick paved")

	-- Walkable routes on the final world.
	local function get(x, y, z) return w.get(x, y, z) end
	local a1, a2 = plan.approaches[1].pos, plan.approaches[2].pos
	local function reach(seen, x, z) return seen[x .. "," .. z] == true end
	local paved_or_lm = function(x, z)
		return expected_pavement(plan, x, z) ~= nil or site_cells_inside(plan, "cathedral", x, z)
			or site_cells_inside(plan, "castle", x, z)
	end
	for i, start in ipairs({a1, a2}) do
		for kind, allow in pairs({open = function() return true end, pavement = paved_or_lm}) do
			local l = label .. "approach " .. i .. " " .. kind .. ": "
			local seen = flood(get, g, plan, start, allow)
			eq(reach(seen, a1.x, a1.z), true, l .. "reaches approach 1")
			eq(reach(seen, a2.x, a2.z), true, l .. "reaches approach 2")
			local m = plan.sites.market
			local mc = {x = math.floor((m.rect.x1 + m.rect.x2) / 2), z = math.floor((m.rect.z1 + m.rect.z2) / 2)}
			eq(reach(seen, mc.x, mc.z), true, l .. "reaches the market centre")
			local p = plan.sites.parvis
			local pc = {x = math.floor((p.rect.x1 + p.rect.x2) / 2), z = math.floor((p.rect.z1 + p.rect.z2) / 2)}
			eq(reach(seen, pc.x, pc.z), true, l .. "reaches the parvis centre")
			if kind == "open" then
				eq(reach(seen, m.approach.pos.x, m.approach.pos.z), true, l .. "market approach")
				eq(reach(seen, p.approach.pos.x, p.approach.pos.z), true, l .. "parvis approach")
			end
			for _, name in ipairs({"cathedral", "castle"}) do
				local s = plan.sites[name]
				eq(reach(seen, s.approach.pos.x, s.approach.pos.z), true, l .. name .. " approach")
				eq(reach(seen, s.entrance.x, s.entrance.z), true, l .. name .. " entrance cell")
				-- three high at every opening cell and a path inside: step
				-- inward from the entrance for 3 cells
				local fx, fz = s.facing.x, s.facing.z
				for k = 1, 3 do
					eq(reach(seen, s.entrance.x - fx * k, s.entrance.z - fz * k), true,
						l .. name .. " interior step " .. k)
				end
				for dy = 1, 3 do
					eq(get(s.entrance.x, g + dy, s.entrance.z), "air", l .. name .. " door height " .. dy)
				end
			end
		end
	end

	-- Landmarks are physically there and tall; blockouts differ.
	local function tallest(name)
		local r = plan.sites[name].rect
		local top = g
		for x = r.x1, r.x2 do
			for z = r.z1, r.z2 do
				for y = g + 1, g + 40 do
					if w.get(x, y, z) ~= "air" and y > top then top = y end
				end
			end
		end
		return top - g
	end
	eq(tallest("cathedral") >= 20, true, label .. "cathedral stands tall")
	eq(tallest("castle") >= 20, true, label .. "castle stands tall")
	eq(tallest("cathedral") <= 40 and tallest("castle") <= 40, true, label .. "within blockout clearance")
	local ct = plan.sites.cathedral.rect
	local roof, cwall = false, false
	for x = ct.x1, ct.x2 do
		for z = ct.z1, ct.z2 do
			for y = g + 1, g + 30 do
				if w.get(x, y, z) == BRICK then roof = true end
			end
		end
	end
	local cs = plan.sites.castle.rect
	for x = cs.x1, cs.x2 do
		for z = cs.z1, cs.z2 do
			for y = g + 1, g + 30 do
				if w.get(x, y, z) == "mcl_core:stonebrickmossy" then cwall = true end
			end
		end
	end
	eq(roof, true, label .. "cathedral has a brick roof")
	eq(cwall, true, label .. "castle has mossy stone walls")

	-- Surface nodes keep the original column's param2.
	local p2_ok = true
	for _, wr in ipairs(w.writes) do
		if wr.name == GRASS and wr.y == g and wr.p2 ~= (wr.x + wr.z) % 8 then p2_ok = false end
	end
	eq(p2_ok, true, label .. "grass tops keep the column param2")

	-- Outside the plan's columns the world is byte-identical to the fixture.
	local drift = 0
	for x = bb.min.x - 3, bb.max.x + 3 do
		for z = bb.min.z - 3, bb.max.z + 3 do
			if not in_boundary(plan, x, z) then
				local col = w.over[x] and w.over[x][z]
				if col then drift = drift + 1 end
			end
		end
	end
	eq(drift, 0, label .. "no change outside the boundary columns")
end

------------------------------------------------------------------------
-- Rejections: zero writes
------------------------------------------------------------------------
local base_result = make_result(1, 100, -50)
local function copy_result()
	-- shallow structure copy of the parts a test may corrupt
	local r = {}
	for k, v in pairs(base_result) do r[k] = v end
	return r
end
local function expect_rejection(label, result, world, code, pattern)
	local summary, msg, c = builder.build(result, {log = false}, world.env)
	eq(summary, nil, label .. ": no summary")
	eq(c, code, label .. ": code")
	if pattern then
		eq(tostring(msg):find(pattern, 1, true) ~= nil, true, label .. ": message (" .. tostring(msg) .. ")")
	end
	eq(#world.writes, 0, label .. ": zero writes")
	eq(world.commits, 0, label .. ": zero commits")
end

do
	-- invalid palette: roof material unregistered
	local nodes = nodes_table()
	nodes[BRICK] = nil
	expect_rejection("palette", copy_result(), new_world({nodes = nodes}), "invalid_palette", BRICK)
	-- pavement material unregistered
	nodes = nodes_table()
	nodes[COBBLE] = nil
	local with_cobble
	for seed = 1, 40 do
		local r = make_result(seed, 0, 0)
		for _, s in ipairs(r.plan.streets) do
			if s.material == COBBLE then with_cobble = r end
		end
		if with_cobble then break end
	end
	eq(with_cobble ~= nil, true, "a seed with secondary streets exists")
	expect_rejection("palette cobble", with_cobble, new_world({nodes = nodes}), "invalid_palette", COBBLE)
	-- a surface node the world reports that is not registered anywhere
	nodes = nodes_table()
	nodes[DIRT] = nil
	expect_rejection("palette fill", copy_result(), new_world({nodes = nodes}), "invalid_palette", DIRT)

	-- rejected plan: a street moved outside the boundary
	local bad = copy_result()
	local plan = {}
	for k, v in pairs(base_result.plan) do plan[k] = v end
	plan.streets = {}
	for i, s in ipairs(base_result.plan.streets) do plan.streets[i] = s end
	local s1 = {}
	for k, v in pairs(plan.streets[1]) do s1[k] = v end
	s1.rect = {x1 = 5000, z1 = 5000, x2 = 5005, z2 = 5005}
	plan.streets[1] = s1
	bad.plan = plan
	expect_rejection("invalid plan", bad, new_world(), "invalid_plan")

	-- malformed plan and result
	bad = copy_result()
	bad.plan = {}
	expect_rejection("empty plan", bad, new_world(), "invalid_plan")
	bad = copy_result()
	bad.heights = nil
	expect_rejection("no heights", bad, new_world(), "bad_result")
	bad = copy_result()
	bad.ground_y = 40.5
	expect_rejection("fractional ground", bad, new_world(), "bad_result")
	expect_rejection("nil result", nil, new_world(), "bad_result")

	-- build bounds that do not match the plan or the volume
	bad = copy_result()
	bad.build_bounds = {min = {x = base_result.build_bounds.min.x + 1, y = base_result.build_bounds.min.y,
		z = base_result.build_bounds.min.z}, max = base_result.build_bounds.max}
	expect_rejection("bounds off the plan", bad, new_world(), "bad_result")
	bad = copy_result()
	local bb = base_result.build_bounds
	bad.build_bounds = {min = {x = bb.min.x, y = bb.min.y + 3, z = bb.min.z}, max = bb.max}
	expect_rejection("bounds above the surface", bad, new_world(), "bad_result")
	bad = copy_result()
	bad.build_bounds = {min = bb.min, max = {x = bb.max.x, y = base_result.ground_y + 10, z = bb.max.z}}
	bad.build_volume = {min = base_result.build_volume.min, max = bad.build_bounds.max}
	expect_rejection("no room for the blockouts", bad, new_world(), "invalid_plan", "build volume top")

	-- area not loaded (one ignore node deep inside the volume)
	local plan0 = base_result.plan
	local ux, uz = plan0.center.x, plan0.center.z
	expect_rejection("unloaded", copy_result(), new_world({unloaded = function(x, y, z)
		return x == ux and z == uz and y == base_result.ground_y + 20
	end}), "inspection_failed", "not loaded")
	-- unloaded at the surface row
	expect_rejection("unloaded surface", copy_result(), new_world({unloaded = function(x, y, z)
		return x == ux and z == uz and y == base_result.heights[ux][uz]
	end}), "inspection_failed", "not loaded")
	-- failed to open
	expect_rejection("open failure", copy_result(), new_world({open_error = "emerge failed"}),
		"inspection_failed", "emerge failed")
	-- liquid appeared since inspection
	expect_rejection("liquid", copy_result(), new_world({override = function(x, y, z)
		if x == ux and z == uz and y == base_result.ground_y + 3 then return "mcl_core:water_source" end
	end}), "inspection_failed", "liquid")
	-- stale surface: the column's surface is now air
	expect_rejection("stale surface", copy_result(), new_world({override = function(x, y, z)
		if x == ux and z == uz and y == base_result.heights[ux][uz] then return "air" end
	end}), "inspection_failed", "not solid ground")
end

-- A throwing region.set (engine failure) is reported, not rethrown.
do
	local w = new_world()
	local inner = w.env.open_region
	w.env.open_region = function(a, b)
		local r = inner(a, b)
		r.commit = function() error("boom") end
		return r
	end
	local summary, msg, code = builder.build(copy_result(), {log = false}, w.env)
	eq(summary, nil, "commit failure: no summary")
	eq(code, "write_failed", "commit failure: code")
end

-- Determinism: the same result builds the same nodes.
do
	local w1, w2 = new_world(), new_world()
	builder.build(copy_result(), {log = false}, w1.env)
	builder.build(copy_result(), {log = false}, w2.env)
	eq(#w1.writes, #w2.writes, "deterministic write count")
	local same = true
	for i, a in ipairs(w1.writes) do
		local b = w2.writes[i]
		if not b or a.x ~= b.x or a.y ~= b.y or a.z ~= b.z or a.name ~= b.name then same = false end
	end
	eq(same, true, "deterministic write order and content")
end

------------------------------------------------------------------------
-- Pure layout over many seeds: openings stay open, nothing leaves the plan
------------------------------------------------------------------------
for seed = 100, 130 do
	local plan = planner.plan({x = 0, z = 0}, seed)
	local g = 50
	local L = TL.new(plan, g, {heights = function() return g end, max_y = g + 44})
	local label = "layout seed " .. seed .. ": "
	local function get(x, y, z)
		local n = L.node_at(x, y, z)
		if n then return n end
		if y > g then return "air" end
		return STONE
	end
	local start = plan.approaches[1].pos
	local seen = flood(get, g, plan, start, function() return true end)
	local ok = true
	for _, name in ipairs({"cathedral", "castle", "market", "parvis"}) do
		local s = plan.sites[name]
		local p = s.approach.pos
		if not seen[p.x .. "," .. p.z] then ok = false end
		if s.entrance and not seen[s.entrance.x .. "," .. s.entrance.z] then ok = false end
	end
	eq(ok, true, label .. "doors reachable")
	local p2 = plan.approaches[2].pos
	eq(seen[p2.x .. "," .. p2.z], true, label .. "second approach reachable")
	-- the door cells are 3 high and every opening cell is clear
	for _, name in ipairs({"cathedral", "castle"}) do
		local op = L.openings[name]
		eq(op.width >= 3 and op.height >= 3, true, label .. name .. " opening size")
		for _, c in ipairs(op.cells) do
			for dy = 1, op.height do
				eq(get(c.x, g + dy, c.z), "air", label .. name .. " opening clear")
			end
		end
	end
	eq(L.max_dy <= 40, true, label .. "within clearance")
end
