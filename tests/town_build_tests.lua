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
local plan = assert(planner.plan({x = 0, z = 0}, 2, {landmarks = profile}))
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

------------------------------------------------------------------------
-- Real schematics: door routes judged on the actual castle/cathedral nodes
------------------------------------------------------------------------
do
	local read_mts = dofile("tests/mts_reader.lua")
	local geometry = dofile("src/geometry.lua")
	local schem = dofile("src/schematic.lua")
	local function info_of(name)
		if name == "air" then return {walkable = false, liquid = false} end
		local nonwalk = name:find("torch", 1, true) or name:find("_open", 1, true)
			or name:find("flower", 1, true) or name:find("lantern", 1, true)
			or name:find("sign", 1, true) or name:find("banner", 1, true)
			or name:find("rail", 1, true) or name:find("button", 1, true)
			or name:find("plate", 1, true) or name:find("ladder", 1, true)
		local i = placement.node_info({[name] = {walkable = not nonwalk}}, name)
		return i
	end
	local function route(id, rotation, entrance_override)
		local entry = entries[id]
		local s = read_mts("schematics/" .. entry.path:gsub("^schematics/", ""))
		local g = 40
		local pos = {x = 100, y = g - (entry.ground_offset or 0), z = 100}
		local e = entrance_override or entry.entrance
		local b = geometry.place({size = entry.size, entrance = e}, pos, rotation)
		local box = {rect = {x1 = b.min.x, z1 = b.min.z, x2 = b.max.x, z2 = b.max.z},
			rotation = b.rotation, min = b.min, max = b.max, entrance = b.entrance}
		-- Inverse of schematic.rotate_offset: world cell -> file cell.
		local inv = {}
		for z = 0, s.size.z - 1 do
			for x = 0, s.size.x - 1 do
				local o = schem.rotate_offset(s.size, {x = x, y = 0, z = z}, rotation)
				inv[(pos.x + o.x) .. "," .. (pos.z + o.z)] = {x, z}
			end
		end
		local function node(x, y, z)
			local f = inv[x .. "," .. z]
			local name
			if f and y >= pos.y and y <= b.max.y then
				name = s.at(f[1], y - pos.y, f[2])
			elseif y <= g then
				name = "mcl_core:stonebrick"
			else
				name = "air"
			end
			return info_of(name), name
		end
		return builder.check_door(box, g, node)
	end
	for _, rot in ipairs({0, 90, 180, 270}) do
		local r, why = route("cathedral", rot)
		eq(r ~= nil, true, "real cathedral door reachable at rotation " .. rot .. ": " .. tostring(why))
		-- The castle gate (the user's gate at source (295,9,124), canonical
		-- (24,6,3)) is a 6-wide, 5-high opening with half-step stairs.
		local c, cwhy = route("castle", rot)
		eq(c ~= nil, true, "real castle gate reachable at rotation " .. rot .. ": " .. tostring(cwhy))
	end
	-- #87: captures that began at the floor row sank flush with the street
	-- (one block low). A template must keep a ground row under its floor
	-- whenever it has entrance stairs: no stair node may sit on the ground row
	-- (row ground_offset) of a rotation-0 .mts. Templates that do keep the
	-- ground row (entrance.y - ground_offset == 2, ground_offset 0) must have
	-- solid ground outside the door, a solid floor row under the door and a
	-- door at the entrance, and must route at every rotation.
	local raised = {}
	for _, id in ipairs(catalog.ids()) do
		local entry = entries[id]
		if entry and entry.data_path and entry.path then
			local s = read_mts("schematics/" .. entry.path:gsub("^schematics/", ""))
			local go = entry.ground_offset or 0
			local stairs = 0
			for z = 0, s.size.z - 1 do
				for x = 0, s.size.x - 1 do
					local n = s.at(x, go, z)
					if n and n:find("stair", 1, true) then stairs = stairs + 1 end
				end
			end
			-- Landmarks (ground_offset > 0) carry authored half-step stairs.
			if go == 0 then
				eq(stairs == 0 or entry.entrance.y >= 2, true,
					id .. " has " .. stairs .. " stairs on its ground row without a ground row below the floor")
			end
			if go == 0 and entry.entrance.y == 2 then raised[#raised + 1] = id end
		end
	end
	eq(#raised >= 5, true, "raised templates found: " .. #raised)
	for _, id in ipairs(raised) do
		local entry = entries[id]
		local s = read_mts("schematics/" .. entry.path:gsub("^schematics/", ""))
		local e = entry.entrance
		eq(e.y, 2, id .. " door bottom is on floor row 1")
		eq(entry.ground_offset or 0, 0, id .. " ground row is row 0")
		local opening = entry.entrance_kind == "opening"
		-- Outside the door the ground row is natural solid ground (dirt, stone);
		-- a walk-in opening on the box edge has its ground row at the entrance.
		local below = s.at(e.x, 0, opening and e.z or e.z - 1)
		eq(below ~= nil and below ~= "air", true,
			id .. " ground row outside the door is solid ground: " .. tostring(below))
		local floor = s.at(e.x, 1, e.z)
		if opening then
			-- A stair is a valid floor under a walk-in opening; it must be solid
			-- and the two cells above it clear.
			eq(floor ~= "air", true, id .. " floor under the opening is solid: " .. tostring(floor))
			eq(s.at(e.x, e.y, e.z), "air", id .. " opening cell is air")
			eq(s.at(e.x, e.y + 1, e.z), "air", id .. " opening head room is air")
		else
			eq(floor ~= "air" and not floor:find("door", 1, true), true, id .. " floor under the door is solid: " .. tostring(floor))
			eq(s.at(e.x, e.y, e.z):find("_door_b_", 1, true) ~= nil, true, id .. " entrance is a door")
		end
		for _, rot in ipairs({0, 90, 180, 270}) do
			local r, why = route(id, rot)
			eq(r ~= nil, true, "real " .. id .. " door reachable at rotation " .. rot .. ": " .. tostring(why))
		end
	end
	-- #96: tavern_2 keeps its cellar rows below the floor (ground_offset 2,
	-- floor flush with the street), so its door is not a "raised" template.
	local t2 = entries.tavern_2
	eq(t2 ~= nil and t2.ground_offset, 2, "tavern_2 ground_offset")
	eq(t2 ~= nil and t2.entrance.y, 3, "tavern_2 door bottom is on the floor row plus one")
	local t2s = read_mts("schematics/" .. t2.path:gsub("^schematics/", ""))
	eq(t2s.at(t2.entrance.x, t2.entrance.y, t2.entrance.z):find("_door_b_", 1, true) ~= nil, true, "tavern_2 entrance is a door")
	for _, rot in ipairs({0, 90, 180, 270}) do
		local r, why = route("tavern_2", rot)
		eq(r ~= nil, true, "real tavern_2 door reachable at rotation " .. rot .. ": " .. tostring(why))
		-- The exterior stair on the +X strip to the second-floor door (5,7,1).
		local r2, why2 = route("tavern_2", rot, {x = 5, y = 7, z = 1})
		eq(r2 ~= nil, true, "tavern_2 stair reaches the upper door at rotation " .. rot .. ": " .. tostring(why2))
	end
	-- #110: soup_shop is a walk-in opening on a raised floor with a cellar
	-- below (ground_offset 3, floor row 4, opening bottom on floor row + 1).
	local ss = entries.soup_shop
	eq(ss ~= nil and ss.ground_offset, 3, "soup_shop ground_offset")
	eq(ss ~= nil and ss.entrance.y, 5, "soup_shop opening is two rows above the ground row")
	eq(ss ~= nil and ss.entrance_kind, "opening", "soup_shop entrance kind")
	local sss = read_mts("schematics/" .. ss.path:gsub("^schematics/", ""))
	local se = ss.entrance
	eq(sss.at(se.x, se.y, se.z), "air", "soup_shop opening cell is air")
	eq(sss.at(se.x, se.y + 1, se.z), "air", "soup_shop opening head room is air")
	eq(sss.at(se.x, se.y - 1, se.z), "mcl_core:cobble", "soup_shop opening floor is solid")
	eq(sss.at(se.x, ss.ground_offset, se.z - 1), "mcl_core:dirt_with_grass", "soup_shop ground row outside the opening")
	for _, rot in ipairs({0, 90, 180, 270}) do
		local r, why = route("soup_shop", rot)
		eq(r ~= nil, true, "real soup_shop opening reachable at rotation " .. rot .. ": " .. tostring(why))
	end
end

------------------------------------------------------------------------
-- Node setup (ticket #46): once, after every placement and door check
------------------------------------------------------------------------
do
	local function report(over)
		local r = {ok = true, placements = #comp.structures, already_done = 0, initialized = 3,
			by_name = {}, failed = {}, unregistered = {}, unhandled = {}}
		for k, v in pairs(over or {}) do r[k] = v end
		return r
	end
	local w = new_world()
	local calls = 0
	w.env.setup_nodes = function(structs, ents)
		calls = calls + 1
		w.log[#w.log + 1] = "setup"
		eq(#structs, #comp.structures, "setup gets every structure")
		eq(ents ~= nil, true, "setup gets the entries")
		return report()
	end
	local s, msg, code = builder.build_town(make_result(), {entries = entries, log = false}, w.env)
	eq(s ~= nil, true, "build with setup succeeds: " .. tostring(msg) .. " " .. tostring(code))
	eq(calls, 1, "setup called once")
	eq(w.log[#w.log], "setup", "setup runs after the last placement")
	eq(w.log[#w.log - 1], "place:" .. comp.structures[#comp.structures].id, "last placement precedes setup")
	eq(s and s.town.setup and s.town.setup.initialized, 3, "summary carries the setup report")

	-- Unhandled nodes are reported, not fatal.
	local w2 = new_world()
	w2.env.setup_nodes = function()
		return report({ok = false, unhandled = {{name = "fake:gizmo", structures = {"a"}, reason = "has on_construct"}}})
	end
	local s2 = builder.build_town(make_result(), {entries = entries, log = false}, w2.env)
	eq(s2 ~= nil and s2.town.setup.unhandled[1].name, "fake:gizmo", "unhandled node reported in the summary")

	-- A failed initialization is a write failure with the reason.
	local w3 = new_world()
	w3.env.setup_nodes = function()
		return report({ok = false, failed = {{id = "tavern", name = "mcl_furnaces:furnace",
			pos = {x = 1, y = 2, z = 3}, message = "boom"}}})
	end
	local s3, m3, c3, x3 = builder.build_town(make_result(), {entries = entries, log = false}, w3.env)
	eq(s3, nil, "setup failure: no summary")
	eq(c3, "write_failed", "setup failure code")
	eq(x3 and x3.reason, "node_setup_failed", "setup failure reason")
	eq(x3 and x3.setup.failed[1].name, "mcl_furnaces:furnace", "setup failure carries the report")
	eq(tostring(m3):find("boom", 1, true) ~= nil, true, "setup failure message names the error")

	-- An exception in the adapter is also a write failure.
	local w4 = new_world()
	w4.env.setup_nodes = function() error("adapter exploded") end
	local s4, _, c4, x4 = builder.build_town(make_result(), {entries = entries, log = false}, w4.env)
	eq(s4 == nil and c4 == "write_failed" and x4.reason == "node_setup_error", true, "setup exception")

	-- Not run when a placement fails first.
	local w5 = new_world({fail = comp.structures[2].id})
	local ran = false
	w5.env.setup_nodes = function() ran = true; return report() end
	builder.build_town(make_result(), {entries = entries, log = false}, w5.env)
	eq(ran, false, "no setup after a failed placement")
end
