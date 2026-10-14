-- Town placement tests (ticket #45): real schematics placed after the ground
-- and pavement phases through an injected, recording fake engine. Loaded by
-- tests/run.lua:
--   loadfile("tests/town_build_tests.lua")(eq, fails, planner, catalog, placement, ss_factory, builder_factory)
local eq, fails, planner, catalog, placement, ss_factory, builder_factory = ...
local ss = ss_factory(placement, planner)
local builder = builder_factory(placement, planner)
local TL = builder.layout
local blockouts = builder.blockouts

local STONE, DIRT, GRASS = "mcl_core:stone", "mcl_core:dirt", "mcl_core:dirt_with_grass"
local GROUND_Y = 40

local entries = catalog.entries
local profile = assert(planner.landmark_profile(catalog.snapshot()))
local plan = assert(planner.plan({x = 0, z = 0}, 6, {landmarks = profile}))
eq(#plan.content.alleys >= 1, true, "fixture plan has an alley")
eq(#plan.content.buildings >= 2, true, "fixture plan has buildings")
eq(plan.sites.city_hall ~= nil, true, "fixture plan has a city hall")

local comp = assert(builder.preflight.compose(plan, entries, GROUND_Y))

local function in_rect(r, x, z)
	return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2
end

-- A site_search-shaped result over flat terrain at GROUND_Y.
local function make_result()
	local C = {}
	for k, v in pairs(ss.CONSTANTS) do C[k] = v end
	C.BLOCKOUT_CLEARANCE = C.LANDMARK_BLOCKOUT_HEIGHT + C.BLOCKOUT_MARGIN
	local heights = {}
	for _, c in ipairs(ss.boundary_columns(plan.boundary.rects)) do
		heights[c.x] = heights[c.x] or {}
		heights[c.x][c.z] = GROUND_Y
	end
	local bb = ss.build_bounds(plan.bounds, GROUND_Y, GROUND_Y, GROUND_Y, C, comp)
	return {
		center = {x = 0, z = 0}, plan = plan, ground_y = GROUND_Y, heights = heights,
		min_height = GROUND_Y, max_height = GROUND_Y, build_bounds = bb,
		build_volume = ss.build_volume(bb, C), structures = comp.structures,
	}
end

local function nodes_table()
	local t = {
		[GRASS] = {walkable = true}, [DIRT] = {walkable = true}, [STONE] = {walkable = true},
		["mcl_core:stonebrick"] = {walkable = true}, ["mcl_core:cobble"] = {walkable = true},
		["fake:wall"] = {walkable = true}, ["fake:door"] = {walkable = true, door = true},
	}
	for _, n in ipairs(blockouts.names()) do t[n] = {walkable = true} end
	return t
end

-- Fake world: sparse overrides over flat terrain. `log` records ordered
-- events: "commit", "place:<id>".
local FRONT = {[0] = {0, -1}, [90] = {-1, 0}, [180] = {0, 1}, [270] = {1, 0}}
local function new_world(spec)
	spec = spec or {}
	local w = {over = {}, log = {}, writes = {}, placed = {}, boxes = {}}
	local nodes = nodes_table()
	local function base(x, y, z)
		if y < GROUND_Y - 3 then return STONE end
		if y < GROUND_Y then return DIRT end
		if y == GROUND_Y then return GRASS end
		return "air"
	end
	function w.get(x, y, z)
		local c = w.over[x]
		return c and c[z] and c[z][y] or base(x, y, z)
	end
	local function set(x, y, z, name)
		w.over[x] = w.over[x] or {}
		w.over[x][z] = w.over[x][z] or {}
		w.over[x][z][y] = name
	end
	w.env = {
		node_info = function(name) return nodes[name] end,
		log = function() end,
		open_region = function()
			local r = {}
			local pending = {}
			function r.get(x, y, z) return w.get(x, y, z) end
			function r.get_param2() return 0 end
			function r.set(x, y, z, name) pending[#pending + 1] = {x, y, z, name} end
			function r.commit()
				if spec.commit_error then error("commit exploded") end
				for _, p in ipairs(pending) do
					set(p[1], p[2], p[3], p[4])
					w.writes[#w.writes + 1] = {x = p[1], y = p[2], z = p[3], name = p[4]}
				end
				w.log[#w.log + 1] = "commit"
			end
			return r
		end,
		get_node = function(x, y, z) return w.get(x, y, z) end,
		place_structure = function(b, entry)
			w.log[#w.log + 1] = "place:" .. b.id
			w.placed[#w.placed + 1] = b
			w.boxes[#w.boxes + 1] = {min = b.min, max = b.max}
			if spec.engine_error == b.id then error("engine exploded") end
			if spec.fail == b.id then return nil, "Schematic placement failed" end
			-- The schematic: solid below the door sill, air above, one door
			-- node pair at the entrance. Written strictly inside the box.
			for x = b.min.x, b.max.x do
				for z = b.min.z, b.max.z do
					for y = b.min.y, b.max.y do
						set(x, y, z, y < b.entrance.y and "fake:wall" or "air")
					end
				end
			end
			-- The route from the box edge to a recessed door climbs one node
			-- per step (authored stairs), headroom above it.
			local f = FRONT[b.rotation]
			local k = 0
			while true do
				local x, z = b.entrance.x + f[1] * k, b.entrance.z + f[2] * k
				if not in_rect(b.rect, x, z) then break end
				local top = math.max(GROUND_Y, b.entrance.y - 1 - k)
				for y = b.min.y, b.max.y do
					if y <= top then set(x, y, z, "fake:wall")
					elseif y <= top + 6 then set(x, y, z, "air") end
				end
				k = k + 1
			end
			set(b.entrance.x, b.entrance.y, b.entrance.z, "fake:door")
			set(b.entrance.x, b.entrance.y + 1, b.entrance.z, "fake:door")
			if spec.block == b.id then
				-- Wall the door and the cell behind it shut.
				for _, d in ipairs({0, 1}) do
					set(b.entrance.x, b.entrance.y + d, b.entrance.z, "fake:wall")
					set(b.entrance.x - f[1], b.entrance.y + d, b.entrance.z - f[2], "fake:wall")
				end
			end
			return true
		end,
	}
	return w
end

local function run(spec)
	local w = new_world(spec)
	local summary, msg, code, extra = builder.build_town(make_result(),
		{entries = entries, log = false}, w.env)
	return w, summary, msg, code, extra
end

------------------------------------------------------------------------
-- Success: ordering, rotations, bounds, pavement
------------------------------------------------------------------------
local w, summary, msg, code = run()
eq(summary ~= nil, true, "town build succeeds: " .. tostring(msg) .. " " .. tostring(code))
if summary then
	eq(summary.town.complete, true, "marked complete")
	eq(summary.town.placed, #comp.structures, "all structures placed")
	eq(w.log[1], "commit", "terrain committed before the first placement")
	eq(#w.log, #comp.structures + 1, "one commit and one placement per structure")
	for i, st in ipairs(comp.structures) do
		eq(w.log[i + 1], "place:" .. st.id, "placement order " .. i)
		local b = w.placed[i]
		eq(b.rotation, st.rotation, "rotation " .. i)
		-- Minimum corner of the rotated box at the planned rect.
		eq(b.min.x, st.rect.x1, "min x " .. i)
		eq(b.min.z, st.rect.z1, "min z " .. i)
		eq(b.min.y, GROUND_Y - (entries[st.id].ground_offset or 0), "min y " .. i)
	end
	-- The real landmarks come first, in the stable order.
	eq(w.placed[1].id, plan.sites.cathedral.id, "cathedral first")
	eq(w.placed[2].id, plan.sites.castle.id, "castle second")
	eq(w.placed[3].id, plan.sites.city_hall.id, "city hall third")

	-- No temporary blockouts, nothing paved under any placed building.
	local blk = {}
	for _, n in ipairs(blockouts.names()) do blk[n] = true end
	local bad_blk, under = 0, 0
	for _, wr in ipairs(w.writes) do
		if blk[wr.name] then bad_blk = bad_blk + 1 end
		if wr.y == GROUND_Y and (wr.name == "mcl_core:cobble" or wr.name == "mcl_core:stonebrick") then
			for _, st in ipairs(comp.structures) do
				if in_rect(st.rect, wr.x, wr.z) then under = under + 1 end
			end
		end
	end
	eq(bad_blk, 0, "no blockout nodes written")
	eq(under, 0, "no pavement under any placed building (city hall included)")

	-- Alleys are paved.
	local material = TL.alley_material(plan)
	local alley_cells, alley_paved = 0, 0
	for _, a in ipairs(plan.content.alleys) do
		for x = a.rect.x1, a.rect.x2 do
			for z = a.rect.z1, a.rect.z2 do
				alley_cells = alley_cells + 1
				local n = w.get(x, GROUND_Y, z)
				-- (street pavement may already own a cell)
				if n == material or n == "mcl_core:stonebrick" then alley_paved = alley_paved + 1 end
			end
		end
	end
	eq(alley_cells > 0 and alley_paved == alley_cells, true, "every alley cell paved")

	-- Each placement box is exactly the validated full box.
	for i, box in ipairs(w.boxes) do
		local st = comp.structures[i]
		eq(box.min.x == st.min.x and box.min.y == st.min.y and box.min.z == st.min.z
			and box.max.x == st.max.x and box.max.y == st.max.y and box.max.z == st.max.z, true,
			"placement box is the validated box " .. i)
	end
	eq(summary.town.bounds.max.y >= comp.max_y, true, "summary bounds cover the tallest structure")
	eq(#summary.town.doors, #comp.structures, "every door route checked")
end
if os.getenv("DBG") then
	for y = 38, 43 do print(y, w.get(7, y, 57), w.get(6, y, 57), w.get(-2, y, 57)) end
end

------------------------------------------------------------------------
-- Failures after the terrain is written
------------------------------------------------------------------------
do
	local target = comp.structures[4].id
	local first
	for i, st in ipairs(comp.structures) do
		if st.id == target then first = i break end
	end
	local w2, s2, m2, c2, x2 = run({fail = target})
	eq(s2, nil, "placement failure: no summary")
	eq(c2, "write_failed", "placement failure code")
	eq(x2 and x2.building and x2.building.id, target, "failing building id reported")
	eq(x2 and x2.placed, first - 1, "buildings placed before the failure")
	eq(x2 and x2.reason, "placement_failed", "failure reason")
	eq(tostring(m2):find(target, 1, true) ~= nil, true, "message names the building")
	eq(#w2.placed, first, "no placement after the failure")
	local b = comp.structures[first]
	eq(x2 ~= nil and x2.bounds.min.x <= b.min.x and x2.bounds.max.x >= b.max.x
		and x2.bounds.min.y <= b.min.y and x2.bounds.max.y >= b.max.y
		and x2.bounds.min.z <= b.min.z and x2.bounds.max.z >= b.max.z, true,
		"bounds include the failing box")

	local _, s3, m3, c3, x3 = run({engine_error = comp.structures[2].id})
	eq(s3, nil, "engine error: no summary")
	eq(c3, "write_failed", "engine error code")
	eq(x3 and x3.reason, "engine_error", "engine error reason")
	eq(x3 and x3.building.id, comp.structures[2].id, "engine error building")
	eq(tostring(m3):find("engine exploded", 1, true) ~= nil, true, "engine error message")

	-- A terrain commit failure places nothing.
	local w4, s4, _, c4 = run({commit_error = true})
	eq(s4, nil, "commit error: no summary")
	eq(c4, "write_failed", "commit error code")
	eq(#w4.placed, 0, "commit error: nothing placed")

	-- Unreachable door after placement.
	local blocked = comp.structures[1].id
	local _, s5, _, c5, x5 = run({block = blocked})
	eq(s5, nil, "blocked door: no summary")
	eq(c5, "write_failed", "blocked door code")
	eq(x5 and x5.reason, "door_unreachable", "blocked door reason")
	eq(x5 and x5.building.id, blocked, "blocked door building")
end

-- Bad input is rejected before any write.
do
	local w6 = new_world()
	local e2 = {}
	for k, v in pairs(entries) do e2[k] = v end
	e2[comp.structures[1].id] = nil
	local s, _, c = builder.build_town(make_result(), {entries = e2, log = false}, w6.env)
	eq(s, nil, "missing entry: no summary")
	eq(c, "invalid_plan", "missing entry code")
	eq(#w6.writes, 0, "missing entry: nothing written")
	local s7, _, c7 = builder.build_town(make_result(), {log = false}, w6.env)
	eq(s7 == nil and c7 == "bad_result", true, "entries required")
end

------------------------------------------------------------------------
-- Door route: recessed door reached by steps
------------------------------------------------------------------------
do
	-- Door facing -Z (rotation 0) at (10, 44, 23): box z 20..30, ground 40,
	-- stairs rising one node per node inward from the approach (10, 40, 19).
	local st = {rect = {x1 = 5, z1 = 20, x2 = 15, z2 = 30}, rotation = 0,
		min = {x = 5, y = 35, z = 20}, max = {x = 15, y = 60, z = 30},
		entrance = {x = 10, y = 44, z = 23}}
	local nodes = {}
	local function put(x, y, z, n) nodes[x .. "," .. y .. "," .. z] = n end
	local info = {air = {}, solid = {walkable = true}, door = {walkable = true, door = true}}
	local function node(x, y, z)
		local n = nodes[x .. "," .. y .. "," .. z] or (y <= 40 and "solid" or "air")
		return info[n], n
	end
	-- z=20 floor top 41, z=21 42, z=22 43, door cell z=23 floor top 43.
	for k = 0, 3 do
		for y = 41, 41 + k do put(10, y, 20 + k, "solid") end
	end
	put(10, 44, 23, "door")
	put(10, 45, 23, "door")
	local r, why = builder.check_door(st, 40, node)
	eq(r ~= nil, true, "stepped recess route found: " .. tostring(why))
	if r then
		eq(r.approach.z, 19, "approach is the first node outside the box")
		eq(r.approach.x, 10, "approach in line with the door")
	end
	-- A staircase of stair nodes (half steps, a node of rise every node).
	local function stairs(x, y, z)
		if x == 10 and z == 20 and y == 41 then return {walkable = true}, "mcl_stairs:stair_stone" end
		if x == 10 and z == 21 and y == 42 then return {walkable = true}, "mcl_stairs:stair_stone" end
		if x == 10 and z == 22 and y == 43 then return {walkable = true}, "mcl_stairs:stair_stone" end
		if x == 10 and z == 20 and y > 41 then return info.air, "air" end
		if x == 10 and z == 21 and y > 42 then return info.air, "air" end
		if x == 10 and z == 22 and y > 43 then return info.air, "air" end
		return node(x, y, z)
	end
	local rs, whys = builder.check_door(st, 40, stairs)
	eq(rs ~= nil, true, "a staircase of stair nodes is walkable: " .. tostring(whys))
	-- Remove a step: unreachable.
	put(10, 41, 21, "air")
	put(10, 42, 21, "air")
	local r2, why2 = builder.check_door(st, 40, node)
	eq(r2, nil, "missing step is unreachable")
	eq(type(why2), "string", "reason given")
end
