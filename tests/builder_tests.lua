-- Builder tests (tickets #15, #45): the ground layout, and terrain writes,
-- rejections and failure reporting of builder.build_town on a small authored
-- plan (tests/authored_plan_fixture.lua) over a recording fake world, so no
-- town is generated. Loaded by tests/run.lua, which passes its check helpers:
--   loadfile("tests/builder_tests.lua")(eq, fails, placement, planner, site_search_factory,
--     builder_factory)
local eq, fails, placement, planner, ss_factory, builder_factory = ...
local ss = ss_factory(placement, planner)
local builder = builder_factory(placement, planner)
local TL = builder.layout
local catalog = dofile("src/catalog.lua")
local make_authored_plan = dofile("tests/authored_plan_fixture.lua")

local STONEBRICK = "mcl_core:stonebrick"
local GRASS, DIRT, STONE = "mcl_core:dirt_with_grass", "mcl_core:dirt", "mcl_core:stone"
local PAVING, ROAD = "test:paving", "test:road"
local WATER = "mcl_core:water_source"

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

local gate_pavement = TL.pavement_map({
	sites = {
		market = {rect = {x1 = 0, z1 = 0, x2 = 0, z2 = 0}, material = "m:square"},
		parvis = {rect = {x1 = 20, z1 = 20, x2 = 20, z2 = 20}, material = "m:square"},
		castle = {rect = {x1 = 30, z1 = 30, x2 = 35, z2 = 35},
			gate_apron = {x1 = 30, z1 = 24, x2 = 35, z2 = 28}},
	},
	streets = {{id = 1, kind = "principal", rect = {x1 = 28, z1 = 26, x2 = 32, z2 = 30},
		material = "m:brick"}},
})
eq(gate_pavement[30][24], "m:brick", "gate apron is paved")
eq(gate_pavement[35][28], "m:brick", "far corner of gate apron is paved")

-- Street lane (issue #172): centre cells are slabs, edge cells keep the
-- street material, and a square still wins over the lane.
local lane_plan = {
	boundary = {rects = {{x1 = 0, z1 = 0, x2 = 5, z2 = 9}}},
	sites = {market = {rect = {x1 = 0, z1 = 9, x2 = 0, z2 = 9}, material = "m:square"}},
	streets = {{id = 1, kind = "principal", rect = {x1 = 0, z1 = 0, x2 = 5, z2 = 9},
		material = "m:cobble", lane = {rect = {x1 = 1, z1 = 0, x2 = 4, z2 = 8}, material = "m:slab"}}},
}
local lane_pav = TL.pavement_map(lane_plan)
eq(lane_pav[1][0], "m:slab", "lane cell is a slab")
eq(lane_pav[4][8], "m:slab", "far lane corner is a slab")
eq(lane_pav[0][4], "m:cobble", "west edge stays a block")
eq(lane_pav[5][4], "m:cobble", "east edge stays a block")
eq(lane_pav[2][9], "m:cobble", "lane stops before the arch end")
eq(lane_pav[0][0], "m:cobble", "street corner stays a block")
eq(lane_pav[0][9], "m:square", "square still beats the street")
do
	local LL = TL.new(lane_plan, 20, {heights = function() return 20 end,
		surface = function() return "x:grass" end, max_y = 30})
	local lane_node, lane_kind = LL.node_at(2, 20, 4)
	eq(lane_node, "m:slab", "lane ground row writes the slab node")
	eq(lane_kind, "pave", "lane ground row is pavement (param2 0, bottom slab)")
	eq(LL.node_at(0, 20, 4), "m:cobble", "edge ground row writes the block")
	eq(LL.node_at(2, 19, 4), DIRT, "lane keeps its support row")
	local has_slab = false
	for _, n in ipairs(LL.palette()) do if n == "m:slab" then has_slab = true end end
	eq(has_slab, true, "palette lists the lane material")
end

-- Column semantics: cut, fill, level, with a one-rect plan.
do
	local plan = {
		boundary = {rects = {{x1 = 0, z1 = 0, x2 = 3, z2 = 0}}},
		sites = {market = {rect = {x1 = 0, z1 = 0, x2 = 0, z2 = 0}, material = STONEBRICK},
			parvis = {rect = {x1 = 100, z1 = 100, x2 = 100, z2 = 100}, material = STONEBRICK}},
		streets = {},
	}
	local T = TL
	-- heights: x0 paved level, x1 high (cut), x2 low (fill 6), x3 level unpaved.
	local hs = {[0] = 20, 23, 14, 20}
	local L = T.new(plan, 20, {heights = function(x) return hs[x] end,
		surface = function() return "x:grass" end, max_y = 30})
	eq(L.node_at(0, 20, 0), STONEBRICK, "paved level column: pavement at ground")
	eq(L.node_at(0, 21, 0), "air", "paved level column: air above")
	eq(L.node_at(0, 19, 0), DIRT, "paved level column: support row below the surface")
	eq(L.node_at(0, 16, 0), nil, "paved level column: deeper ground untouched")
	local _, kind19 = L.node_at(0, 19, 0)
	eq(kind19, "support", "support rows are flagged for the builder")
	eq(L.node_at(1, 22, 0), "air", "cut column: cleared above ground")
	eq(L.node_at(1, 21, 0), "air", "cut column: cut to ground")
	eq(L.node_at(1, 20, 0), "x:grass", "cut column: natural surface at ground")
	eq(L.node_at(1, 19, 0), DIRT, "cut column: support row under the ground")
	eq(L.node_at(1, 17, 0), DIRT, "cut column: third support row")
	eq(L.node_at(1, 16, 0), nil, "cut column: deeper ground untouched")
	local lo, hi = L.column_range(1, 0)
	eq(lo, 17, "cut column range starts at the support rows")
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
	eq(L.node_at(3, 18, 0), DIRT, "level column: support row")
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
		T.new(plan, 20, {heights = function() end, max_y = 30})
	end, "no surface height", "missing height rejected")
end

------------------------------------------------------------------------
-- Fake world
------------------------------------------------------------------------
local CENTER = {x = 100, z = -50}
local entries = catalog.entries
local FULL = os.getenv("TOWNS_TEST_FULL") == "1"

-- Terrain around `base` (the finished ground level) in the fixture plan's
-- own coordinates (rx, rz from its minimum corner): rx 0-2 forum, 3-4 street,
-- 5-11 temple, 12-15 plain ground. Columns 12 and 15 are cut, 13 is filled,
-- one forum and one street column are cut/filled under their pavement.
local function terrain_at(base)
	return function(x, z)
		local rx, rz = x - CENTER.x, z - CENTER.z
		if rx == 12 then return base + 3 end
		if rx == 13 then return base - 3 end
		if rx == 15 then return base + 2 end
		if rx == 1 and rz == 3 then return base + 2 end
		if rx == 3 and rz == 2 then return base - 2 end
		if rx >= 5 and rx <= 11 and rz % 3 == 0 then return base + 1 end
		return base
	end
end
local terrain = terrain_at(40)

local function nodes_table()
	return {
		[GRASS] = {walkable = true}, [DIRT] = {walkable = true}, [STONE] = {walkable = true},
		[PAVING] = {walkable = true}, [ROAD] = {walkable = true},
		["fake:wall"] = {walkable = true}, ["fake:door"] = {walkable = true, door = true},
		["mcl_core:tree"] = {walkable = true, clearable = true},
		["mcl_core:leaves"] = {walkable = true, clearable = true},
		[WATER] = {liquid = true}, ["mcl_core:water_flowing"] = {liquid = true},
		["mcl_core:sand"] = {walkable = true, falling = true},
		["mcl_core:gravel"] = {walkable = true, falling = true},
		["mcl_core:ice"] = {walkable = true, ice = true},
	}
end

local FRONT = {[0] = {0, -1}, [90] = {-1, 0}, [180] = {0, 1}, [270] = {1, 0}}
local function in_rect(r, x, z)
	return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2
end

-- Recording world over sparse overrides. spec: terrain, notrees, nodes,
-- world(x,y,z) base override, unloaded(x,y,z), override(x,y,z) region read
-- override, open_error. `placed`/`log` record place_structure calls and the
-- order of "commit" and "place:<id>" events.
local function new_world(spec)
	spec = spec or {}
	local w = {over = {}, writes = {}, commits = 0, opened = 0, placed = {}, log = {}}
	local nodes = spec.nodes or nodes_table()
	local tfn = spec.terrain or terrain
	local function tree_at(x, z)
		return not spec.notrees and (x * 31 + z * 17) % 53 == 0
	end
	local function base(x, y, z)
		local h = tfn(x, z)
		if y < h - 3 then return STONE end
		if y < h then return DIRT end
		if y == h then return GRASS end
		if tree_at(x, z) and y <= h + 5 then return "mcl_core:tree" end
		for dx = -1, 1 do
			for dz = -1, 1 do
				if tree_at(x + dx, z + dz) and y >= tfn(x + dx, z + dz) + 4
						and y <= tfn(x + dx, z + dz) + 6 then
					return "mcl_core:leaves"
				end
			end
		end
		return "air"
	end
	if spec.world then
		local base0 = base
		base = function(x, y, z) return spec.world(x, y, z) or base0(x, y, z) end
	end
	function w.get(x, y, z)
		local c = w.over[x]
		return c and c[z] and c[z][y] or base(x, y, z)
	end
	function w.set(x, y, z, name)
		w.over[x] = w.over[x] or {}
		w.over[x][z] = w.over[x][z] or {}
		w.over[x][z][y] = name
	end
	w.env = {
		node_info = function(name) return nodes[name] end,
		log = function(level, msg)
			w.logs = w.logs or {}
			w.logs[#w.logs + 1] = level .. ": " .. msg
		end,
		get_node = function(x, y, z) return w.get(x, y, z) end,
		open_region = function()
			w.opened = w.opened + 1
			if spec.open_error then return nil, spec.open_error end
			local r = {}
			function r.get(x, y, z)
				if spec.unloaded and spec.unloaded(x, y, z) then return "ignore" end
				if spec.override and spec.override(x, y, z) then return spec.override(x, y, z) end
				return w.get(x, y, z)
			end
			function r.get_param2(x, _, z) return (x + z) % 8 end
			function r.set(x, y, z, name, p2)
				w.writes[#w.writes + 1] = {x = x, y = y, z = z, name = name, p2 = p2}
				w.set(x, y, z, name)
			end
			function r.commit()
				w.commits = w.commits + 1
				w.log[#w.log + 1] = "commit"
			end
			return r
		end,
		-- The schematic: solid below the door sill, air above, one door node
		-- pair at the entrance. Written strictly inside the box.
		place_structure = function(b, entry)
			w.log[#w.log + 1] = "place:" .. b.id
			w.placed[#w.placed + 1] = b
			local ground = b.min.y + (entry.ground_offset or 0)
			for x = b.min.x, b.max.x do
				for z = b.min.z, b.max.z do
					for y = b.min.y, b.max.y do
						w.set(x, y, z, y < b.entrance.y and "fake:wall" or "air")
					end
				end
			end
			local f = FRONT[b.rotation]
			local k = 0
			while true do
				local x, z = b.entrance.x + f[1] * k, b.entrance.z + f[2] * k
				if not in_rect(b.rect, x, z) then break end
				local top = math.max(ground, b.entrance.y - 1 - k)
				for y = b.min.y, b.max.y do
					if y <= top then w.set(x, y, z, "fake:wall")
					elseif y <= top + 6 then w.set(x, y, z, "air") end
				end
				k = k + 1
			end
			w.set(b.entrance.x, b.entrance.y, b.entrance.z, "fake:door")
			w.set(b.entrance.x, b.entrance.y + 1, b.entrance.z, "fake:door")
			return true
		end,
	}
	return w
end

local function boundary_in(plan, x, z)
	for _, r in ipairs(plan.boundary.rects) do
		if in_rect(r, x, z) then return true end
	end
	return false
end

-- A site_search-shaped result for the fixture plan over `tfn`.
local function make_result(tfn)
	tfn = tfn or terrain
	local plan = make_authored_plan(CENTER, 7)
	local cols = ss.boundary_columns(plan.boundary.rects)
	local heights, list = {}, {}
	local lo, hi
	for _, c in ipairs(cols) do
		local h = tfn(c.x, c.z)
		heights[c.x] = heights[c.x] or {}
		heights[c.x][c.z] = h
		list[#list + 1] = h
		lo = (not lo or h < lo) and h or lo
		hi = (not hi or h > hi) and h or hi
	end
	local g = ss.median(list)
	local comp = assert(builder.preflight.compose(plan, entries, g))
	local bb = ss.build_bounds(plan.bounds, g, lo, hi, comp)
	return {
		center = {x = CENTER.x, z = CENTER.z}, plan = plan, ground_y = g, heights = heights,
		columns = #cols, min_height = lo, max_height = hi, build_bounds = bb,
		build_volume = ss.build_volume(bb, ss.CONSTANTS), structures = comp.structures,
	}
end

local function expected_pavement(plan, x, z)
	if in_rect(plan.sites.forum.rect, x, z) then return plan.sites.forum.material end
	for _, s in ipairs(plan.streets) do
		if in_rect(s.rect, x, z) then return s.material end
	end
end

local function in_structure(plan, x, z)
	return in_rect(plan.sites.temple.rect, x, z)
end

local function is_solid(nodes, name)
	local i = nodes[name]
	return i ~= nil and i.walkable and not i.liquid and not i.clearable
end

local function build(result, world, opts)
	return builder.build_town(result, opts or {entries = entries, log = false}, world.env)
end

------------------------------------------------------------------------
-- End to end on the fake world
------------------------------------------------------------------------
do
	local walk_nodes = nodes_table()
	local result = make_result()
	local plan, g, bb = result.plan, result.ground_y, result.build_bounds
	eq(g, 40, "ground is the median surface")
	eq(result.max_height - result.min_height, 6, "terrain really varies")
	local w = new_world()
	local trees = false
	for _, c in ipairs(ss.boundary_columns(plan.boundary.rects)) do
		if w.get(c.x, g + 5, c.z) == "mcl_core:tree" then trees = true end
	end
	eq(trees, true, "fixture has trees to clear")

	local summary, msg, code = build(result, w, {entries = entries})
	eq(msg, nil, "build ok (" .. tostring(msg) .. ")")
	eq(code, nil, "no error code")
	eq(summary ~= nil, true, "summary")
	if summary then
		eq(summary.seed, plan.seed, "summary seed")
		eq(summary.ground_y, g, "summary ground")
		eq(summary.center.x, CENTER.x, "summary centre x")
		eq(summary.bounds.min.y, bb.min.y, "summary bounds")
		eq(summary.counts.streets, #plan.streets, "summary streets")
		eq(summary.counts.blocks, #plan.blocks, "summary blocks")
		eq(summary.counts.frontage, #plan.frontage, "summary frontage")
		eq(summary.counts.principal + summary.counts.secondary, #plan.streets, "street kinds")
		eq(summary.nodes.changed, #w.writes, "changed count equals writes")
		eq(summary.sites.forum.rect, plan.sites.forum.rect, "summary forum rect")
		eq(summary.sites.temple.rect, plan.sites.temple.rect, "summary temple rect")
		eq(summary.town.complete, true, "town complete")
		eq(summary.town.placed, 1, "one building placed")
		eq(#summary.town.doors, 1, "one door route checked")
		eq(summary.town.doors[1].approach.x, plan.sites.temple.approach.pos.x, "door approach x")
		eq(summary.town.doors[1].approach.z, plan.sites.temple.approach.pos.z, "door approach z")
		eq(w.commits, 1, "single commit")
	end
	eq(w.log[1], "commit", "terrain committed first")
	eq(w.log[2], "place:demo_house", "building placed after the terrain")
	eq(#(w.logs or {}) >= 6, true, "construction sequence logged")

	-- Confinement: every terrain write inside the build bounds and the boundary.
	local oob, outside_town = 0, 0
	for _, wr in ipairs(w.writes) do
		if wr.x < bb.min.x or wr.x > bb.max.x or wr.y < bb.min.y or wr.y > bb.max.y
				or wr.z < bb.min.z or wr.z > bb.max.z then
			oob = oob + 1
		end
		if not boundary_in(plan, wr.x, wr.z) then outside_town = outside_town + 1 end
	end
	eq(oob, 0, "no write outside the build bounds")
	eq(outside_town, 0, "no write outside the boundary union")
	eq(#w.writes > 200, true, "a real amount of work")
	local st = w.placed[1]
	eq(st.min.x >= bb.min.x and st.max.x <= bb.max.x and st.min.y >= bb.min.y
		and st.max.y <= bb.max.y and st.min.z >= bb.min.z and st.max.z <= bb.max.z, true,
		"the placed box lies inside the build bounds")

	-- Per column: flat, supported, natural top, pavement with priority.
	local flat_ok, support_ok, pave_ok, air_ok, top_ok, wrong = true, true, true, true, true, nil
	local paved_cols = 0
	for _, c in ipairs(ss.boundary_columns(plan.boundary.rects)) do
		local x, z = c.x, c.z
		local h = result.heights[x][z]
		local top = w.get(x, g, z)
		if not is_solid(walk_nodes, top) then flat_ok = false; wrong = wrong or ("top " .. x .. "," .. z) end
		for y = math.min(h, g), g do
			if not is_solid(walk_nodes, w.get(x, y, z)) then
				support_ok = false
				wrong = wrong or ("support " .. x .. "," .. y .. "," .. z)
			end
		end
		if not in_structure(plan, x, z) then
			local want = expected_pavement(plan, x, z)
			if want then
				paved_cols = paved_cols + 1
				if top ~= want then pave_ok = false; wrong = wrong or ("pave " .. x .. "," .. z) end
			elseif top ~= GRASS then
				top_ok = false
				wrong = wrong or ("top material " .. x .. "," .. z .. " " .. tostring(top))
			end
			for y = g + 1, bb.max.y do
				if w.get(x, y, z) ~= "air" then
					air_ok = false
					wrong = wrong or ("air " .. x .. "," .. y .. "," .. z)
				end
			end
		end
	end
	eq(wrong, nil, "first column problem")
	eq(flat_ok, true, "every column has solid ground at the median level")
	eq(support_ok, true, "ground supported all the way down")
	eq(pave_ok, true, "pavement matches the squares and streets")
	eq(top_ok, true, "unpaved ground keeps a grass top")
	eq(air_ok, true, "airspace cleared above ground")
	eq(summary and summary.counts.paved_columns, paved_cols, "paved column count")
	eq(paved_cols, 3 * 7 + 2 * 7, "forum and street columns are paved, the building is not")

	local seen_mat = {}
	for _, wr in ipairs(w.writes) do
		if wr.y == g then seen_mat[wr.name] = true end
	end
	eq(seen_mat[PAVING], true, "square paved")
	eq(seen_mat[ROAD], true, "street paved")

	-- Surface nodes keep the original column's param2.
	local p2_ok = true
	for _, wr in ipairs(w.writes) do
		if wr.name == GRASS and wr.y == g and wr.p2 ~= (wr.x + wr.z) % 8 then p2_ok = false end
	end
	eq(p2_ok, true, "grass tops keep the column param2")

	-- Outside the plan's columns the world is untouched.
	local drift = 0
	for x = bb.min.x - 3, bb.max.x + 3 do
		for z = bb.min.z - 3, bb.max.z + 3 do
			if not boundary_in(plan, x, z) and w.over[x] and w.over[x][z] then drift = drift + 1 end
		end
	end
	eq(drift, 0, "no change outside the boundary columns")
end

------------------------------------------------------------------------
-- Rejections: zero writes
------------------------------------------------------------------------
local base_result = make_result()
local function copy_result()
	local r = {}
	for k, v in pairs(base_result) do r[k] = v end
	return r
end
local function expect_rejection(label, result, world, code, pattern)
	local summary, msg, c = build(result, world)
	eq(summary, nil, label .. ": no summary")
	eq(c, code, label .. ": code")
	if pattern then
		eq(tostring(msg):find(pattern, 1, true) ~= nil, true, label .. ": message (" .. tostring(msg) .. ")")
	end
	eq(#world.writes, 0, label .. ": zero writes")
	eq(world.commits, 0, label .. ": zero commits")
	eq(#world.placed, 0, label .. ": zero buildings placed")
end

do
	-- Unregistered pavement, square, and fill materials.
	local nodes = nodes_table()
	nodes[ROAD] = nil
	expect_rejection("palette road", copy_result(), new_world({nodes = nodes}), "invalid_palette", ROAD)
	nodes = nodes_table()
	nodes[PAVING] = nil
	expect_rejection("palette square", copy_result(), new_world({nodes = nodes}), "invalid_palette", PAVING)
	nodes = nodes_table()
	nodes[DIRT] = nil
	expect_rejection("palette fill", copy_result(), new_world({nodes = nodes}), "invalid_palette", DIRT)

	-- Rejected plan: the street moved outside the boundary.
	local bad = copy_result()
	local plan = {}
	for k, v in pairs(base_result.plan) do plan[k] = v end
	plan.streets = {{kind = "principal", material = ROAD,
		rect = {x1 = 5000, z1 = 5000, x2 = 5005, z2 = 5005}}}
	bad.plan = plan
	expect_rejection("invalid plan", bad, new_world(), "invalid_plan")

	-- Malformed plan and result.
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

	-- Build bounds that do not match the plan, the surface, or the building.
	local bb = base_result.build_bounds
	bad = copy_result()
	bad.build_bounds = {min = {x = bb.min.x + 1, y = bb.min.y, z = bb.min.z}, max = bb.max}
	expect_rejection("bounds off the plan", bad, new_world(), "bad_result")
	bad = copy_result()
	bad.build_bounds = {min = {x = bb.min.x, y = bb.min.y + 1, z = bb.min.z}, max = bb.max}
	expect_rejection("bounds above the surface", bad, new_world(), "bad_result")
	bad = copy_result()
	bad.build_bounds = {min = bb.min, max = {x = bb.max.x, y = base_result.ground_y + 2, z = bb.max.z}}
	bad.build_volume = {min = base_result.build_volume.min, max = bad.build_bounds.max}
	expect_rejection("building above the bounds", bad, new_world(), "invalid_plan",
		"outside the build bounds")

	-- Area not loaded (deep in the volume, and at a surface row), open failure.
	local ux, uz = CENTER.x, CENTER.z
	expect_rejection("unloaded", copy_result(), new_world({unloaded = function(x, y, z)
		return x == ux and z == uz and y == bb.max.y
	end}), "inspection_failed", "not loaded")
	expect_rejection("unloaded surface", copy_result(), new_world({unloaded = function(x, y, z)
		return x == ux and z == uz and y == base_result.heights[ux][uz]
	end}), "inspection_failed", "not loaded")
	expect_rejection("open failure", copy_result(), new_world({open_error = "emerge failed"}),
		"inspection_failed", "emerge failed")
	-- Liquid appeared since inspection, and a stale surface.
	expect_rejection("liquid", copy_result(), new_world({override = function(x, y, z)
		if x == ux and z == uz and y == base_result.ground_y + 3 then return WATER end
	end}), "inspection_failed", "liquid")
	expect_rejection("stale surface", copy_result(), new_world({override = function(x, y, z)
		if x == ux and z == uz and y == base_result.heights[ux][uz] then return "air" end
	end}), "inspection_failed", "not solid ground")
end

-- A throwing commit (engine failure) is reported, not rethrown, and no
-- building is placed after it.
do
	local w = new_world()
	local inner = w.env.open_region
	w.env.open_region = function(a, b)
		local r = inner(a, b)
		r.commit = function() error("boom") end
		return r
	end
	local summary, _, code = build(copy_result(), w)
	eq(summary, nil, "commit failure: no summary")
	eq(code, "write_failed", "commit failure: code")
	eq(#w.placed, 0, "commit failure: nothing placed")
end

-- A plain cut column (112, -46): away from the pavement and the building.
local CUTX, CUTZ = CENTER.x + 12, CENTER.z + 4
local FILLX = CENTER.x + 13

-- Support under every column (cut columns included).
do
	local res = copy_result()
	local g = res.ground_y
	local h = res.heights[CUTX][CUTZ]
	eq(h, g + 3, "support fixture: the column is a cut")

	-- Cavity under the cut column: air g-4..g-1.
	local w = new_world({world = function(x, y, z)
		if x == CUTX and z == CUTZ and y >= g - 4 and y <= g - 1 then return "air" end
	end})
	local summary, msg = build(res, w)
	eq(summary ~= nil, true, "cavity: built (" .. tostring(msg) .. ")")
	for y = g - 3, g - 1 do
		eq(w.get(CUTX, y, CUTZ), DIRT, "cavity: row " .. (y - g) .. " filled with dirt")
	end
	eq(w.get(CUTX, g - 4, CUTZ), "air", "cavity: deeper rows untouched")
	eq(w.get(CUTX, g, CUTZ), GRASS, "cavity: natural surface at ground")
	eq(summary.nodes.by_kind.support >= 3, true, "cavity: support nodes counted")
	local deep, lowest = 0, 1e9
	for _, wr in ipairs(w.writes) do
		if wr.y < g - 3 and wr.y <= res.heights[wr.x][wr.z] then deep = deep + 1 end
		lowest = math.min(lowest, wr.y)
	end
	eq(deep, 0, "no write below the support rows under existing ground")
	eq(lowest >= res.build_volume.min.y, true, "writes stay inside the build volume")

	-- Sand surface over a cavity, gravel under it: replaced by dirt, sand top kept.
	w = new_world({world = function(x, y, z)
		if x == CUTX and z == CUTZ then
			if y == h then return "mcl_core:sand" end
			if y >= g - 3 and y <= g - 1 then return "mcl_core:gravel" end
			if y == g - 4 then return "air" end
		end
	end})
	summary, msg = build(res, w)
	eq(summary ~= nil, true, "sand: built (" .. tostring(msg) .. ")")
	eq(w.get(CUTX, g, CUTZ), "mcl_core:sand", "sand: surface node kept at ground")
	for y = g - 3, g - 1 do
		eq(w.get(CUTX, y, CUTZ), DIRT, "sand: falling gravel row replaced by dirt")
	end

	-- Liquid under the surface is filled, not rejected.
	w = new_world({world = function(x, y, z)
		if x == CUTX and z == CUTZ and y == g - 2 then return WATER end
	end})
	summary, msg = build(res, w)
	eq(summary ~= nil, true, "liquid under surface: built (" .. tostring(msg) .. ")")
	eq(w.get(CUTX, g - 2, CUTZ), DIRT, "liquid under surface: filled with dirt")

	-- Liquid or ice in the airspace above the ground still rejects.
	expect_rejection("liquid above ground", copy_result(), new_world({world = function(x, y, z)
		if x == CUTX and z == CUTZ and y == h + 2 then return WATER end
	end}), "inspection_failed", "liquid or ice")
	expect_rejection("ice above ground", copy_result(), new_world({world = function(x, y, z)
		if x == CUTX and z == CUTZ and y == h + 2 then return "mcl_core:ice" end
	end}), "inspection_failed", "liquid or ice")

	-- Frozen lake: every surface node is ice; not ground, nothing written.
	expect_rejection("frozen lake", copy_result(), new_world({world = function(x, y, z)
		if y == terrain(x, z) then return "mcl_core:ice" end
	end}), "inspection_failed", "not solid ground")
end

-- Ice is water-like for the shared classifier.
do
	local reg = {
		["mcl_core:ice"] = {walkable = true, groups = {ice = 1, slippery = 3}},
		["mcl_core:packed_ice"] = {walkable = true, groups = {ice = 1, slippery = 3}},
		["mcl_core:frosted_ice_0"] = {walkable = true, groups = {frosted_ice = 1, slippery = 3, ice = 1}},
		["mcl_core:stone"] = {walkable = true, groups = {}},
		["mcl_core:sand"] = {walkable = true, groups = {falling_node = 1}},
	}
	local function info(n) return placement.node_info(reg, n) end
	for name in pairs(reg) do
		local want = name:find("ice", 1, true) and "water" or "solid"
		eq(placement.classify(name, info), want, "classify " .. name)
	end
	eq(info("mcl_core:sand").falling, true, "falling flag from node groups")
	eq(info("mcl_core:stone").falling, false, "stone does not fall")
end

-- build_town() never raises: errors while reading are inspection failures.
do
	local function raising(label, mutate)
		local w = new_world()
		local inner = w.env.open_region
		w.env.open_region = function(a, b) return mutate(inner, a, b) end
		local ok, summary, _, code = pcall(build, copy_result(), w)
		eq(ok, true, label .. ": build did not raise")
		eq(summary, nil, label .. ": no summary")
		eq(code, "inspection_failed", label .. ": code")
		eq(#w.writes, 0, label .. ": zero writes")
		eq(w.commits, 0, label .. ": zero commits")
		eq(#w.placed, 0, label .. ": zero buildings placed")
	end
	raising("open raises", function() error("open boom") end)
	raising("get raises", function(inner, a, b)
		local r = inner(a, b)
		local n = 0
		r.get = function() n = n + 1; if n > 500 then error("get boom") end return "air" end
		return r
	end)
	raising("get raises on first read", function(inner, a, b)
		local r = inner(a, b)
		r.get = function() error("index boom") end
		return r
	end)
	local w = new_world()
	w.env.node_info = function() error("node_info boom") end
	local ok = pcall(build, copy_result(), w)
	eq(ok, true, "node_info raising: build did not raise")
end

-- Partial commit: write_failed says so, names the bounds, reports the plan.
do
	local w = new_world()
	local inner = w.env.open_region
	w.env.open_region = function(a, b)
		local r = inner(a, b)
		local set = r.set
		local n = 0
		r.set = function(...)
			n = n + 1
			if n == 10 then error("disk boom") end
			return set(...)
		end
		return r
	end
	local ok, summary, msg, code, info = pcall(build, copy_result(), w)
	eq(ok, true, "partial: build did not raise")
	eq(summary, nil, "partial: no summary")
	eq(code, "write_failed", "partial: code")
	eq(msg:find("disk boom", 1, true) ~= nil, true, "partial: cause in message")
	eq(msg:find("partially written", 1, true) ~= nil, true, "partial: says the area may be partially written")
	local wb = info and info.bounds
	eq(wb ~= nil, true, "partial: bounds returned")
	if wb then
		local expect = ("(%d,%d,%d) to (%d,%d,%d)"):format(wb.min.x, wb.min.y, wb.min.z,
			wb.max.x, wb.max.y, wb.max.z)
		eq(msg:find(expect, 1, true) ~= nil, true, "partial: bounds in message")
		eq(wb.min.x, base_result.build_bounds.min.x, "partial: bounds are the build bounds in X")
	end
	eq(info and info.planned > 100, true, "partial: planned node count reported")
	eq(#w.writes, 9, "partial: nine writes happened before the failure")
	eq(w.commits, 0, "partial: never committed")
	eq(#w.placed, 0, "partial: no building placed")
end

-- Engine path: builder.core_env over a finite VoxelArea/VoxelManip fake that
-- snaps to 16-node mapblocks and does no bounds checking (like the engine).
-- Support rows can lie below build_bounds, so the region must be opened over
-- the whole write range; every access must stay inside the requested range.
-- The fake's write_to_map applies the changes to the same world the building
-- stub and the door check use, so the whole build runs through it.
do
	local saved_area = rawget(_G, "VoxelArea")
	local VA = {}
	VA.__index = VA
	function VA:new(t)
		local a = setmetatable({}, self)
		a.min, a.max = t.MinEdge, t.MaxEdge
		a.sx = a.max.x - a.min.x + 1
		a.sy = a.max.y - a.min.y + 1
		return a
	end
	function VA:index(x, y, z)
		return (z - self.min.z) * self.sx * self.sy + (y - self.min.y) * self.sx + (x - self.min.x) + 1
	end
	_G.VoxelArea = VA
	local function snap(v) return math.floor(v / 16) * 16 end

	local function vm_case(label, base)
		local tfn = terrain_at(base)
		local res = make_result(tfn)
		local g = res.ground_y
		-- Reference: the plain fake world.
		local ref = new_world({terrain = tfn, notrees = true})
		local rs, rmsg = build(res, ref)
		eq(rs ~= nil, true, label .. ": reference build (" .. tostring(rmsg) .. ")")
		local truth = new_world({terrain = tfn, notrees = true})

		local ids, names, nid = {}, {}, 0
		local function cid(n)
			if not ids[n] then nid = nid + 1; ids[n] = nid; names[nid] = n end
			return ids[n]
		end
		local reg = {}
		for name, i in pairs(nodes_table()) do
			local groups = {}
			if i.ice then groups.ice = 1 end
			if i.falling then groups.falling_node = 1 end
			if i.door then groups.door = 1 end
			reg[name] = {walkable = i.walkable, groups = groups,
				liquidtype = i.liquid and "source" or nil, buildable_to = i.clearable}
		end
		local vm_state
		local fake_core = {
			registered_nodes = reg, log = function() end,
			get_content_id = cid,
			get_name_from_content_id = function(i) return names[i] end,
			get_node = function(p) return {name = truth.get(p.x, p.y, p.z)} end,
			get_voxel_manip = function()
				local vm = {}
				function vm:read_from_map(a, b)
					self.emin = {x = snap(a.x), y = snap(a.y), z = snap(a.z)}
					self.emax = {x = snap(b.x) + 15, y = snap(b.y) + 15, z = snap(b.z) + 15}
					self.area = VA:new({MinEdge = self.emin, MaxEdge = self.emax})
					self.data, self.p2, self.init = {}, {}, {}
					for z = self.emin.z, self.emax.z do
						for y = self.emin.y, self.emax.y do
							for x = self.emin.x, self.emax.x do
								local i = self.area:index(x, y, z)
								self.data[i] = cid(truth.get(x, y, z))
								self.init[i] = self.data[i]
								self.p2[i] = 0
							end
						end
					end
					vm_state = self
					return self.emin, self.emax
				end
				function vm:get_data() return self.data end
				function vm:get_param2_data() return self.p2 end
				function vm:set_data(d) self.data = d end
				function vm:set_param2_data(d) self.p2 = d end
				function vm:write_to_map()
					self.written = true
					for z = self.emin.z, self.emax.z do
						for y = self.emin.y, self.emax.y do
							for x = self.emin.x, self.emax.x do
								local i = self.area:index(x, y, z)
								if self.data[i] ~= self.init[i] then
									truth.set(x, y, z, names[self.data[i]])
								end
							end
						end
					end
				end
				return vm
			end,
		}
		local env = builder.core_env(fake_core)
		env.place_structure = truth.env.place_structure
		local req_min, req_max, bad_access = nil, nil, 0
		local open = env.open_region
		env.open_region = function(a, b)
			req_min, req_max = a, b
			local r = open(a, b)
			local function chk(x, y, z)
				if x < a.x or x > b.x or y < a.y or y > b.y or z < a.z or z > b.z then
					bad_access = bad_access + 1
				end
			end
			local get, set = r.get, r.set
			r.get = function(x, y, z) chk(x, y, z); return get(x, y, z) end
			r.set = function(x, y, z, n, p) chk(x, y, z); return set(x, y, z, n, p) end
			return r
		end
		local summary, msg = builder.build_town(res, {entries = entries, log = false}, env)
		eq(summary ~= nil, true, label .. ": engine-path build (" .. tostring(msg) .. ")")
		eq(bad_access, 0, label .. ": every get/set inside the requested range")
		eq(vm_state and vm_state.written, true, label .. ": committed")
		if summary then
			local bb = res.build_bounds
			eq(req_min.y, math.min(bb.min.y, g - 3), label .. ": region opened from the lowest written row")
			eq(req_max.y, bb.max.y, label .. ": region opened to the top row")
			eq(req_min.y <= g - 3, true, label .. ": support rows covered")
			eq(summary.bounds.min.x, bb.min.x, label .. ": bounds X")
		end
		-- The resulting area equals the reference rendering node for node.
		local diff, checked = 0, 0
		for z = vm_state.emin.z, vm_state.emax.z do
			for y = vm_state.emin.y, vm_state.emax.y do
				for x = vm_state.emin.x, vm_state.emax.x do
					checked = checked + 1
					if truth.get(x, y, z) ~= ref.get(x, y, z) then diff = diff + 1 end
				end
			end
		end
		eq(checked > 10000, true, label .. ": compared the whole area")
		eq(diff, 0, label .. ": identical to the reference rendering")
		return g
	end

	-- Mapblock alignment cases: the edge residues by default, all under
	-- TOWNS_TEST_FULL=1.
	for _, k in ipairs(FULL and {0, 1, 2, 3, 15} or {0, 1, 15}) do
		local g = vm_case("vm g%16=" .. k, 64 + k)
		eq(g % 16, k, "ground level residue " .. k)
	end
	_G.VoxelArea = saved_area
end

-- Output after the commit must not turn a successful build into a failure:
-- env.log throwing is swallowed; any throw after writing began is write_failed.
do
	local w = new_world()
	w.env.log = function() error("log boom") end
	local ok, summary, msg = pcall(builder.build_town, copy_result(), {entries = entries}, w.env)
	eq(ok, true, "throwing log: build did not raise")
	eq(summary ~= nil, true, "throwing log: summary returned (" .. tostring(msg) .. ")")
	eq(w.commits, 1, "throwing log: committed once")

	local w2 = new_world()
	local inner = w2.env.open_region
	w2.env.open_region = function(a, b)
		local r = inner(a, b)
		local commit = r.commit
		r.commit = function() commit(); error("post-commit boom") end
		return r
	end
	local ok2, s2, m2, c2 = pcall(build, copy_result(), w2)
	eq(ok2, true, "post-commit throw: no raise")
	eq(s2, nil, "post-commit throw: no summary")
	eq(c2, "write_failed", "post-commit throw: write_failed")
	eq(m2:find("partially written", 1, true) ~= nil, true, "post-commit throw: message")
end

-- Determinism: the same result builds the same nodes.
do
	local w1, w2 = new_world(), new_world()
	build(copy_result(), w1)
	build(copy_result(), w2)
	eq(#w1.writes > 0 and #w1.writes, #w2.writes, "deterministic write count")
	local same = true
	for i, a in ipairs(w1.writes) do
		local b = w2.writes[i]
		if not b or a.x ~= b.x or a.y ~= b.y or a.z ~= b.z or a.name ~= b.name then same = false end
	end
	eq(same, true, "deterministic write order and content")
end

-- Landfilled wet columns (ticket #104): liquid/ice between the bed and the
-- finished ground (and above it) is replaced; without result.wet it rejects.
do
	local res = copy_result()
	local g = res.ground_y
	local fx, fz = FILLX, CUTZ
	local h = res.heights[fx][fz]
	eq(h < g - 1, true, "wet fixture has a fill column")
	local function lake(x, y, z)
		if x == fx and z == fz and y > h and y <= g + 2 then
			return (y == g) and "mcl_core:ice" or WATER
		end
	end
	expect_rejection("lake without wet info", copy_result(), new_world({world = lake}),
		"inspection_failed", "liquid or ice")
	local wres = copy_result()
	wres.wet = {count = 1, max_depth = g - h, surfaces = {[fx] = {[fz] = g}}}
	local w = new_world({world = lake})
	local summary, msg = build(wres, w)
	eq(summary ~= nil, true, "lake: built (" .. tostring(msg) .. ")")
	for y = h + 1, g - 1 do
		local n = w.get(fx, y, fz)
		eq(n == DIRT or n == STONE, true, "lake: row " .. y .. " solid fill (" .. tostring(n) .. ")")
	end
	eq(w.get(fx, g, fz), GRASS, "lake: default surface at ground")
	eq(w.get(fx, g + 1, fz), "air", "lake: water above ground cleared")
	eq(w.get(fx, g + 2, fz), "air", "lake: water above ground cleared 2")
	-- Flowing water and ice over a wet column are replaced as well.
	local function mixed(x, y, z)
		if x == fx and z == fz and y > h and y <= g + 1 then
			if y == g + 1 then return "mcl_core:water_flowing" end
			return (y % 2 == 0) and "mcl_core:ice" or "mcl_core:water_flowing"
		end
	end
	local mres = copy_result()
	mres.wet = {count = 1, max_depth = g - h, surfaces = {[fx] = {[fz] = g}}}
	local mw = new_world({world = mixed})
	local ms, mm = build(mres, mw)
	eq(ms ~= nil, true, "flowing/ice lake: built (" .. tostring(mm) .. ")")
	for y = h + 1, g - 1 do
		local n = mw.get(fx, y, fz)
		eq(n == DIRT or n == STONE, true, "flowing/ice lake: row " .. y .. " solid")
	end
	eq(mw.get(fx, g + 1, fz), "air", "flowing/ice lake: flowing water above ground cleared")
	local bad = copy_result()
	bad.wet = {count = 1, max_depth = 1, surfaces = {[fx] = {[fz] = g + 1}}}
	expect_rejection("wet surface above ground", bad, new_world({world = lake}), "bad_result",
		"above the finished ground")
end

-- Buried liquid and the seal (ticket #104).
do
	local res = copy_result()
	local g = res.ground_y
	-- Water pocket inside the cut (rows g..g+2) and a deep one below it.
	local w = new_world({world = function(x, y, z)
		if x == CUTX and z == CUTZ and y >= g and y <= g + 2 then return WATER end
		if x == CUTX and z == CUTZ and y == g - 6 then return WATER end
	end})
	local summary, msg = build(copy_result(), w)
	eq(summary ~= nil, true, "buried pocket in the cut: built (" .. tostring(msg) .. ")")
	if summary then
		eq(summary.liquids.buried, 3, "buried pocket: counted")
		for y = g + 1, g + 3 do
			eq(w.get(CUTX, y, CUTZ), "air", "buried pocket: carved row " .. y)
		end
		eq(w.get(CUTX, g - 6, CUTZ), WATER, "deep pocket left untouched")
	end

	-- Liquid just outside the town beside a carved edge column (112+3, z).
	local ex, ez = CENTER.x + 15, CUTZ
	local eh = res.heights[ex][ez]
	eq(eh >= g + 2, true, "seal fixture has a carved edge column")
	local w2 = new_world({world = function(x, y, z)
		if x == ex + 1 and z == ez and y >= g + 1 and y <= g + 2 then return WATER end
	end})
	local s2, m2 = build(copy_result(), w2)
	eq(s2 ~= nil, true, "seal: built (" .. tostring(m2) .. ")")
	if s2 then
		eq(s2.liquids.sealed >= 2, true, "seal: counted")
		eq(w2.get(ex, g + 1, ez) ~= "air", true, "seal: edge cell beside the liquid kept solid")
		eq(w2.get(ex, g + 2, ez) ~= "air", true, "seal: second row kept solid")
		eq(w2.get(ex, eh + 1, ez), "air", "seal: free air above the surface")
	end
end
