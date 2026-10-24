-- Bed enumeration adapter tests (ticket #47). Pure fake world: nodes are
-- {name, param2} keyed by position; anything unset is air above y=0 and
-- stone at or below it. Run by tests/run.lua:
--   loadfile("tests/residents_tests.lua")(eq, fails, catalog, residents)
local eq, fails, catalog, residents = ...

local function pk(p) return p.x .. "," .. p.y .. "," .. p.z end
local DIR = {[0] = {0, 1}, [1] = {1, 0}, [2] = {0, -1}, [3] = {-1, 0}}
local NONWALK = {"torch", "_open", "flower", "lantern", "sign", "banner", "rail", "button",
	"plate", "ladder", "lava", "fire"}

local function new_world()
	local W = {nodes = {}, unloaded = {}, queries = {}}
	function W.set(p, name, p2) W.nodes[pk(p)] = {name = name, param2 = p2 or 0} end
	function W.bed(x, y, z, color, facedir)
		local d = DIR[facedir]
		W.set({x = x, y = y, z = z}, "mcl_beds:bed_" .. color .. "_bottom", facedir)
		W.set({x = x + d[1], y = y, z = z + d[2]}, "mcl_beds:bed_" .. color .. "_top", facedir)
	end
	local env = {}
	W.env = env
	local function get(p)
		if W.unloaded[pk(p)] then return nil end
		return W.nodes[pk(p)] or {name = p.y <= 0 and "mcl_core:stone" or "air", param2 = 0}
	end
	function env.get_node(p) return get(p) end
	function env.find_beds(minp, maxp)
		W.queries[#W.queries + 1] = {min = minp, max = maxp}
		local out = {}
		for k, n in pairs(W.nodes) do
			if n.name:find("^mcl_beds:") then
				local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
				x, y, z = tonumber(x), tonumber(y), tonumber(z)
				if x >= minp.x and x <= maxp.x and y >= minp.y and y <= maxp.y
						and z >= minp.z and z <= maxp.z then
					out[#out + 1] = {x = x, y = y, z = z}
				end
			end
		end
		return out
	end
	function env.bed_part(name)
		if name:find("^mcl_beds:.*_bottom$") then return 1 end
		if name:find("^mcl_beds:.*_top$") then return 2 end
	end
	local function walkable(name)
		if name == "air" then return false end
		for _, s in ipairs(NONWALK) do if name:find(s, 1, true) then return false end end
		return true
	end
	function env.is_passable(name) return not walkable(name) end
	function env.is_low(name) return name:find("carpet", 1, true) ~= nil end
	function env.is_floor(name) return walkable(name) and not name:find("lava", 1, true) end
	return W
end

local function box(id, x1, y1, z1, x2, y2, z2)
	return {id = id, kind = "content", min = {x = x1, y = y1, z = z1}, max = {x = x2, y = y2, z = z2}}
end

local function reasons(r)
	local t = {}
	for _, s in ipairs(r.skipped) do t[#t + 1] = s.reason end
	return table.concat(t, ",")
end

------------------------------------------------------------------------
-- Colours, pairing, sorting, rotation
------------------------------------------------------------------------
do
	local W = new_world()
	local colors = {"red", "blue", "cyan", "grey", "silver", "black", "yellow", "green", "magenta",
		"orange", "purple", "brown", "pink", "lime", "light_blue", "white"}
	for i, c in ipairs(colors) do W.bed(i * 4, 1, 4, c, (i - 1) % 4) end
	local r = residents.enumerate({box("house", 0, 1, 0, 80, 5, 8)}, W.env)
	eq(r.count, 16, "all 16 colours counted, each pair once")
	eq(#r.skipped, 0, "no skips for clean beds")
	eq(r.by_color["mcl_beds:bed_light_blue"], 1, "colour with underscore tallied")
	for i = 2, #r.beds do
		eq(r.beds[i - 1].pos.x < r.beds[i].pos.x, true, "sorted by x " .. i)
	end
	eq(r.by_structure[1].valid, 16, "per-structure valid count")
	for _, b in ipairs(r.beds) do
		local d = DIR[b.param2]
		eq(b.top.x, b.pos.x + d[1], "top x follows facedir " .. b.name)
		eq(b.top.z, b.pos.z + d[2], "top z follows facedir " .. b.name)
		eq(b.spawn.y, b.pos.y, "spawn on the bed's level")
	end
end

-- Every facedir, bed against walls on three sides.
for fd = 0, 3 do
	local W = new_world()
	W.bed(10, 1, 10, "red", fd)
	local r = residents.enumerate({box("h", 5, 1, 5, 15, 5, 15)}, W.env)
	eq(r.count, 1, "facedir " .. fd .. " bed valid")
end

------------------------------------------------------------------------
-- Broken, blocked and malformed beds
------------------------------------------------------------------------
do
	local W = new_world()
	W.set({x = 2, y = 1, z = 2}, "mcl_beds:bed_red_bottom", 0) -- top missing
	W.bed(6, 1, 2, "blue", 0)
	W.set({x = 6, y = 1, z = 3}, "mcl_beds:bed_green_top", 0) -- wrong colour top
	W.bed(10, 1, 2, "white", 0)
	W.set({x = 10, y = 1, z = 3}, "mcl_beds:bed_white_top", 1) -- wrong param2
	W.set({x = 14, y = 1, z = 2}, "mcl_beds:bed_pink_top", 0) -- orphan top
	W.set({x = 18, y = 1, z = 2}, "mcl_beds:bed_lime_bottom", 5) -- tilted axis
	W.set({x = 18, y = 1, z = 3}, "mcl_beds:bed_lime_top", 5)
	W.bed(22, 1, 2, "cyan", 0)
	W.set({x = 22, y = 2, z = 2}, "mcl_core:stone") -- ceiling directly above bottom
	W.bed(26, 1, 2, "black", 0)
	W.set({x = 26, y = 2, z = 3}, "mcl_core:stone") -- ceiling above top
	-- Fully enclosed bed (no standing cell).
	W.bed(30, 1, 2, "brown", 0)
	for x = 29, 31 do for z = 1, 4 do
		for y = 1, 2 do
			if not (x == 30 and (z == 2 or z == 3)) then W.set({x = x, y = y, z = z}, "mcl_core:stone") end
		end
	end end
	-- Bed on a floor of lava: neighbours unsafe.
	W.bed(34, 1, 2, "yellow", 0)
	for x = 33, 35 do for z = 1, 4 do W.set({x = x, y = 0, z = z}, "mcl_core:lava_source") end end
	W.set({x = 34, y = 0, z = 2}, "mcl_core:stone")
	W.set({x = 34, y = 0, z = 3}, "mcl_core:stone")
	local r = residents.enumerate({box("h", 0, 1, 0, 40, 6, 8)}, W.env)
	eq(r.count, 0, "no malformed or blocked bed is counted: " .. reasons(r))
	local by = {}
	for _, s in ipairs(r.skipped) do by[#by + 1] = s.pos.x .. ":" .. s.reason .. ":" .. s.category end
	eq(table.concat(by, " "), table.concat({
		"2:missing_top:malformed", "6:missing_top:malformed",
		"6:orphan_top:malformed", "10:missing_top:malformed", "10:orphan_top:malformed", "14:orphan_top:malformed",
		"18:bad_orientation:malformed", "18:orphan_top:malformed",
		"22:blocked_above:inaccessible", "26:blocked_above:inaccessible",
		"30:no_standing_space:inaccessible", "34:no_standing_space:inaccessible",
	}, " "), "skip reasons per bed")
end

-- Unloaded neighbours are skipped, not guessed.
do
	local W = new_world()
	W.bed(4, 1, 4, "red", 0)
	W.unloaded[pk({x = 4, y = 1, z = 5})] = true
	local r = residents.enumerate({box("h", 0, 1, 0, 10, 5, 10)}, W.env)
	eq(r.count, 0, "unloaded top is not counted")
	eq(r.skipped[1].reason, "not_loaded", "unloaded reason")
end

-- Standing space needs the head node and the floor, not just a free cell.
do
	local W = new_world()
	W.bed(4, 1, 4, "red", 0) -- z 4..5
	-- Block all sides' head cells with stone at y+2? feet cells free but head blocked:
	for _, c in ipairs({{3, 4}, {5, 4}, {3, 5}, {5, 5}, {4, 3}, {4, 6}}) do
		W.set({x = c[1], y = 2, z = c[2]}, "mcl_core:stone")
	end
	local r = residents.enumerate({box("h", 0, 1, 0, 10, 5, 10)}, W.env)
	eq(r.count, 0, "no headroom beside the bed")
	eq(r.skipped[1].reason, "no_standing_space", "headroom reason")
	-- A carpet on the floor beside the bed is a standing cell, a carpet over a
	-- hole is not.
	W.set({x = 4, y = 1, z = 6}, "mcl_wool:white_carpet")
	W.nodes[pk({x = 4, y = 2, z = 6})] = nil
	r = residents.enumerate({box("h", 0, 1, 0, 10, 5, 10)}, W.env)
	eq(r.count, 1, "carpet cell beside the bed is standable")
	eq(pk(r.beds[1].spawn), "4,1,6", "spawn on the carpet cell")
	-- Plain open end: valid again, spawn is that cell.
	W.nodes[pk({x = 4, y = 1, z = 6})] = nil
	r = residents.enumerate({box("h", 0, 1, 0, 10, 5, 10)}, W.env)
	eq(r.count, 1, "one open end suffices")
	eq(pk(r.beds[1].spawn), "4,1,6", "spawn is the open end cell")
	-- A hole in the floor under the only standing cell.
	W.set({x = 4, y = 0, z = 6}, "air")
	r = residents.enumerate({box("h", 0, 1, 0, 10, 5, 10)}, W.env)
	eq(r.count, 0, "no floor under the only standing cell")
end

-- Sibling-bed rule.
do
	local function wall(W, x, z)
		W.set({x = x, y = 1, z = z}, "mcl_core:stone")
		W.set({x = x, y = 2, z = z}, "mcl_core:stone")
	end
	local b10 = box("h", 0, 1, 0, 10, 6, 10)
	-- A (red, open) with B (blue) east of it, enclosed except toward A.
	local W = new_world()
	W.bed(4, 1, 4, "red", 0)
	W.bed(5, 1, 4, "blue", 0)
	for _, c in ipairs({{6, 4}, {6, 5}, {5, 3}, {5, 6}}) do wall(W, c[1], c[2]) end
	local r = residents.enumerate({b10}, W.env)
	eq(r.count, 2, "enclosed bed valid through its sibling: " .. reasons(r))
	eq(#r.skipped, 0, "no skips with a sibling")
	eq(r.beds[1].name, "mcl_beds:bed_red_bottom", "A first")
	eq(pk(r.beds[2].spawn), pk(r.beds[1].spawn), "sibling bed spawns at the sibling's standing cell")
	-- No headroom over A's adjoining half (only y+2): B is skipped again.
	W.set({x = 4, y = 3, z = 4}, "mcl_core:stone")
	W.set({x = 4, y = 3, z = 5}, "mcl_core:stone")
	r = residents.enumerate({b10}, W.env)
	eq(r.count, 1, "no headroom over the sibling: the enclosed bed stays skipped")
	-- Two enclosed beds next to each other: neither has a standing cell.
	W = new_world()
	W.bed(4, 1, 4, "red", 0)
	W.bed(5, 1, 4, "blue", 0)
	for x = 3, 6 do for z = 3, 6 do
		if not (x >= 4 and x <= 5 and z >= 4 and z <= 5) then wall(W, x, z) end
	end end
	r = residents.enumerate({b10}, W.env)
	eq(r.count, 0, "adjacent enclosed beds are not siblings of each other")
	eq(#r.skipped, 2, "both reported")
	-- Ladder shaft: the only open neighbour is a ladder cell.
	W = new_world()
	W.bed(4, 1, 4, "white", 0)
	for x = 3, 5 do for z = 3, 6 do
		if not (x == 4 and (z == 4 or z == 5)) then wall(W, x, z) end
	end end
	W.set({x = 5, y = 0, z = 4}, "mcl_core:ladder")
	W.set({x = 5, y = 1, z = 4}, "mcl_core:ladder")
	W.set({x = 5, y = 2, z = 4}, "air")
	r = residents.enumerate({b10}, W.env)
	eq(r.count, 0, "ladder shaft bed stays skipped")
	eq(r.skipped[1].reason, "no_standing_space", "ladder shaft reason")
end

------------------------------------------------------------------------
-- Boxes: beds outside are ignored; straddling and duplicates
------------------------------------------------------------------------
do
	local W = new_world()
	W.bed(4, 1, 4, "red", 0)       -- inside
	W.bed(4, 1, 20, "blue", 0)     -- just outside (z 20..21, box ends at 10)
	W.bed(4, 1, 11, "green", 0)    -- one cell past the box edge
	W.bed(8, 1, 10, "white", 0)    -- bottom z=10 inside, top z=11 outside
	local b = box("h", 0, 1, 0, 10, 5, 10)
	local r = residents.enumerate({b}, W.env)
	eq(r.count, 1, "only the bed inside the box counts")
	eq(r.beds[1].name, "mcl_beds:bed_red_bottom", "the inside bed")
	eq(reasons(r), "straddles_box", "bed half outside is reported, not counted")
	eq(#W.queries, 1, "one area query per box")
	eq(W.queries[1].max.z, 10, "query limited to the box")
	-- A second box owning the same cells does not double count.
	local r2 = residents.enumerate({b, box("again", 0, 1, 0, 10, 5, 10)}, W.env)
	eq(r2.count, 1, "overlapping boxes count a bed once")
	eq(r2.by_structure[1].valid, 1, "first box owns it")
	eq(r2.by_structure[2].valid, 0, "second box does not")
end

------------------------------------------------------------------------
-- Excluded beds (schematic excluded_resident_beds, issue #222): a box carries
-- its exclusions; enumeration must be given them to skip the bed. A rebuilt
-- box without them counts the same bed, so the list has to be kept with it.
------------------------------------------------------------------------
do
	local W = new_world()
	W.bed(4, 1, 4, "red", 0)
	W.bed(4, 1, 8, "blue", 0)
	local b = box("house", 0, 1, 0, 10, 5, 10)
	b.excluded_beds = {{x = 4, y = 1, z = 4}}
	local r = residents.enumerate({b}, W.env)
	eq(r.count, 1, "excluded bed is not counted")
	eq(r.beds[1].name, "mcl_beds:bed_blue_bottom", "the other bed still counts")
	eq(reasons(r), "excluded_bed", "excluded bed is reported as skipped")
	eq(r.by_structure[1].skipped, 1, "skip is charged to the box")
	local copy = box("house", 0, 1, 0, 10, 5, 10)
	eq(residents.enumerate({copy}, W.env).count, 2, "a box rebuilt without its exclusions over-counts")
end

------------------------------------------------------------------------
-- Engine adapter against a fake core
------------------------------------------------------------------------
do
	local nodes = {
		["1,1,1"] = {name = "mcl_beds:bed_red_bottom", param2 = 0},
		["1,1,2"] = {name = "mcl_beds:bed_red_top", param2 = 0},
	}
	local groups = {["mcl_beds:bed_red_bottom"] = 1, ["mcl_beds:bed_red_top"] = 2}
	local c = {
		registered_nodes = {
			air = {walkable = false}, ["mcl_core:stone"] = {walkable = true},
			["mcl_core:lava_source"] = {walkable = false, liquidtype = "source", damage_per_second = 8},
			["mcl_beds:bed_red_bottom"] = {}, ["mcl_beds:bed_red_top"] = {},
		},
		get_item_group = function(name, g) return g == "bed" and groups[name] or 0 end,
		get_node_or_nil = function(p)
			local n = nodes[pk(p)]
			if n then return n end
			if p.x == 99 then return nil end
			return {name = p.y <= 0 and "mcl_core:stone" or "air", param2 = 0}
		end,
		find_nodes_in_area = function(minp, maxp, names)
			eq(names[1], "group:bed", "adapter searches the bed group")
			return {{x = 1, y = 1, z = 1}, {x = 1, y = 1, z = 2}}
		end,
	}
	local env = residents.core_env(c)
	eq(env.bed_part("mcl_beds:bed_red_bottom"), 1, "adapter bottom part")
	eq(env.bed_part("mcl_beds:bed_red_top"), 2, "adapter top part")
	eq(env.bed_part("mcl_core:stone"), nil, "adapter non-bed")
	eq(env.is_passable("air"), true, "air passable")
	eq(env.is_passable("mcl_core:lava_source"), false, "lava is not passable")
	eq(env.is_floor("mcl_core:lava_source"), false, "lava is not a floor")
	eq(env.is_floor("mcl_core:stone"), true, "stone is a floor")
	eq(env.get_node({x = 99, y = 1, z = 1}), nil, "unloaded node is nil")
	local r = residents.enumerate({box("h", 0, 1, 0, 5, 3, 5)}, env)
	eq(r.count, 1, "adapter enumerates a bed")
	eq(residents.format(r), "1 valid beds, 0 skipped", "format")
end

------------------------------------------------------------------------
-- Real templates: .mts read directly, at every rotation, against the
-- manually countable bottom nodes and their documented pairing.
------------------------------------------------------------------------
do
	local read_mts = dofile("tests/mts_reader.lua")
	local schem = dofile("src/schematic.lua")
	-- id = {complete pairs counted from the .mts, of which valid}. The
	-- invalid one is real: gaboo_house has a bed reachable only through a
	-- ladder cell (not walkable). The townhouses niche beds are valid through
	-- their sibling bed.
	local expected = {banker_house = {2, 2}, castle = {20, 20}, cathedral = {7, 7},
		corner_house = {3, 3}, gaboo_house = {3, 2}, leather_worker = {2, 2},
		scribe = {2, 2}, soup_shop = {1, 1}, tavern_2 = {2, 2}, townhouses = {9, 9}, weaver_house = {1, 1}}
	local total_beds = 0
	for id, counts in pairs(expected) do
		local want, valid = counts[1], counts[2]
		local entry = catalog.entries[id]
		local s = read_mts("schematics/" .. entry.path:gsub("^schematics/", ""))
		-- Count straight from the file: bottoms with a matching top at the
		-- documented offset.
		local manual = 0
		for z = 0, s.size.z - 1 do for y = 0, s.size.y - 1 do for x = 0, s.size.x - 1 do
			local n, p2 = s.at(x, y, z)
			if n:find("^mcl_beds:.*_bottom$") then
				local d = DIR[p2]
				local tx, tz = x + d[1], z + d[2]
				if tx >= 0 and tx < s.size.x and tz >= 0 and tz < s.size.z then
					local n2, q = s.at(tx, y, tz)
					if n2 == n:gsub("_bottom$", "_top") and q == p2 then manual = manual + 1 end
				end
			end
		end end end
		eq(manual, want, id .. " manual bed count from the .mts")
		total_beds = total_beds + manual
		for _, rot in ipairs({0, 90, 180, 270}) do
			local W = new_world()
			local gy = 40
			local oy = gy - (entry.ground_offset or 0)
			local ox, oz = 100, 100
			local sx = (rot % 180 == 0) and s.size.x or s.size.z
			local sz = (rot % 180 == 0) and s.size.z or s.size.x
			for z = 0, s.size.z - 1 do for y = 0, s.size.y - 1 do for x = 0, s.size.x - 1 do
				local n, p2 = s.at(x, y, z)
				if n ~= "ignore" then
					local o = schem.rotate_offset(s.size, {x = x, y = y, z = z}, rot)
					if n:find("^mcl_beds:") then p2 = (p2 + rot / 90) % 4 end
					W.set({x = ox + o.x, y = oy + y, z = oz + o.z}, n, p2)
				end
			end end end
			-- Stone below the template's base level, air elsewhere.
			W.env.get_node = function(p)
				local n = W.nodes[pk(p)]
				if n then return n end
				return {name = p.y < gy and "mcl_core:stone" or "air", param2 = 0}
			end
			local b = {id = id, kind = "content",
				min = {x = ox, y = oy, z = oz},
				max = {x = ox + sx - 1, y = oy + s.size.y - 1, z = oz + sz - 1}}
			local r = residents.enumerate({b}, W.env)
			eq(r.count, valid, id .. " rot " .. rot .. " valid beds")
			eq(r.count + #r.skipped, want, id .. " rot " .. rot .. " every pair reported once")
			for _, sk in ipairs(r.skipped) do
				eq(sk.reason, "no_standing_space", id .. " rot " .. rot .. " skip reason")
			end
		end
	end
	eq(total_beds, 52, "total manual beds across stock templates")
end

-- Spawn and claim (ticket #48): fake engine and fake mod-storage record.
do
	local function P(x) return {x = x, y = 1, z = 0} end
	local function beds(n)
		local out = {}
		for i = 1, n do
			out[i] = {pos = P(i * 3), top = {x = i * 3, y = 1, z = 1}, spawn = {x = i * 3 + 1, y = 1, z = 0},
				id = "townhouses", kind = "content"}
		end
		return out
	end
	local function new_store(init)
		local data = {}
		for k, v in pairs(init or {}) do data[k] = v end
		return {data = data,
			get = function(k) return data[k] end,
			set = function(k, v) data[k] = v end}
	end
	local function new_engine(opts)
		opts = opts or {}
		local E = {meta = {}, removed = 0, spawned = {}, n = 0, events = {}}
		for k, v in pairs(opts.meta or {}) do E.meta[k] = v end
		local env = {}
		E.env = env
		function env.bed_owner(b)
			local m = E.meta[pk(b.pos)] or {}
			return {villager = m.villager or "", player = m.player or ""}
		end
		function env.spawn(p)
			E.n = E.n + 1
			E.events[#E.events + 1] = "spawn"
			if opts.fail_spawn and opts.fail_spawn[E.n] then return nil end
			local h = {id = (opts.bad_entity and opts.bad_entity[E.n]) and "" or ("v" .. E.n), at = p}
			E.spawned[#E.spawned + 1] = h
			return h
		end
		function env.entity_id(h) return h.id end
		function env.claim(h, p, id)
			if opts.fail_claim then return false end
			E.meta[pk(p)] = {villager = id}
			h.bed = p
			return true
		end
		function env.remove(h) E.removed = E.removed + 1; h.removed = true end
		function env.unclaim(p, id) end
		return E
	end
	local function key(i) return residents.record_key(P(i * 3)) end

	-- Successful spawn and claim: pending is recorded before the spawn,
	-- done after the claim; bed and meta agree.
	do
		local store = new_store()
		local E = new_engine()
		local seen_pending
		local spawn = E.env.spawn
		E.env.spawn = function(p)
			seen_pending = store.data[key(1)] == "pending" or seen_pending
			return spawn(p)
		end
		local r = residents.initialize(beds(3), E.env, store)
		eq(r.spawned, 3, "init: three spawned")
		eq(seen_pending, true, "init: pending recorded before spawning")
		eq(store.data[key(1)], "done:v1", "init: done record carries the villager id")
		eq(E.meta["3,1,0"].villager, "v1", "init: bed meta claimed")
		eq(E.spawned[1].bed.x, 3, "init: villager bed is the bottom node")
		eq(E.spawned[1].at.x, 4, "init: spawned at the spawn cell")
		eq(r.summary, "Residents: 3 spawned, 0 skipped, 0 failed", "init: report line")
	end
	-- Repeat call and fresh state with the same storage: nothing new.
	do
		local store = new_store()
		local E = new_engine()
		residents.initialize(beds(2), E.env, store)
		local E2 = new_engine({meta = E.meta})
		local r = residents.initialize(beds(2), E2.env, store)
		eq(r.spawned, 0, "repeat: nothing spawned")
		eq(r.already_done, 2, "repeat: reported as already initialized")
		eq(#E2.events, 0, "repeat: no engine spawn attempted")
		-- Dead resident (claim meta cleared) is still not replaced.
		local E3 = new_engine()
		r = residents.initialize(beds(2), E3.env, store)
		eq(r.spawned, 0, "dead resident is not replaced")
	end
	-- Existing claims are respected.
	do
		local store = new_store()
		local E = new_engine({meta = {["3,1,0"] = {villager = "other"}, ["6,1,0"] = {player = "bob"}}})
		local r = residents.initialize(beds(3), E.env, store)
		eq(r.spawned, 1, "claimed: only the free bed is used")
		eq(r.claimed, 2, "claimed: villager and player beds skipped")
		eq(store.data[key(1)], nil, "claimed: no record written")
		eq(E.meta["3,1,0"].villager, "other", "claimed: existing claim untouched")
	end
	-- Engine failure and unusable entity: no completed claim, cleaned up.
	do
		local store = new_store()
		local E = new_engine({fail_spawn = {[1] = true}, bad_entity = {[2] = true}})
		local r = residents.initialize(beds(3), E.env, store)
		eq(r.spawned, 1, "failure: remaining bed still spawned")
		eq(r.failed, 2, "failure: two failures counted")
		eq(r.failures[1].reason, "spawn_failed", "failure: add_entity nil reason")
		eq(r.failures[2].reason, "invalid_entity", "failure: invalid entity reason")
		eq(E.removed, 1, "failure: unusable object removed")
		eq(store.data[key(1)], nil, "failure: no record after failed spawn")
		eq(store.data[key(2)], nil, "failure: no record after invalid entity")
		eq(E.meta["3,1,0"], nil, "failure: no claim written")
		local E2 = new_engine({meta = E.meta})
		local r2 = residents.initialize(beds(3), E2.env, store)
		eq(r2.spawned, 2, "failure: retry spawns the failed beds only")
		eq(r2.already_done, 1, "failure: retry skips the done bed")
	end
	do -- claim failure cleans up and records nothing
		local store = new_store()
		local E = new_engine({fail_claim = true})
		local r = residents.initialize(beds(1), E.env, store)
		eq(r.failures[1].reason, "claim_failed", "claim failure reason")
		eq(E.removed, 1, "claim failure removes object")
		eq(store.data[key(1)], nil, "claim failure leaves no record")
	end
	-- Restart with a pending record: reported, not respawned; done respected.
	do
		local store = new_store({[key(1)] = "pending", [key(2)] = "done:abc"})
		local E = new_engine()
		local r = residents.initialize(beds(3), E.env, store)
		eq(r.interrupted, 1, "restart: pending reported")
		eq(r.interrupted_beds[1].pos.x, 3, "restart: pending bed identified")
		eq(r.already_done, 1, "restart: done respected")
		eq(r.spawned, 1, "restart: only the untouched bed spawned")
		eq(store.data[key(1)], "pending", "restart: pending record left for inspection")
		eq(r.summary:find("1 interrupted earlier", 1, true) ~= nil, true, "restart: report mentions it")
	end
	-- A throw after the spawn does not abort the loop or lose counts.
	do
		local store = new_store()
		local E = new_engine()
		local claim = E.env.claim
		E.env.claim = function(h, p, id)
			if p.x == 6 then error("boom") end
			return claim(h, p, id)
		end
		local r = residents.initialize(beds(3), E.env, store)
		eq(r.spawned, 2, "throw: other beds still processed")
		eq(r.failed, 1, "throw: one failure counted")
		eq(r.failures[1].reason, "error", "throw: error reason")
		eq(E.removed, 1, "throw: spawned object cleaned up")
		eq(store.data[key(2)], nil, "throw: record cleared after confirmed cleanup")
		eq(store.data[key(3)], "done:v3", "throw: later bed completed")
	end
	do -- cleanup that cannot be confirmed leaves the pending record
		local store = new_store()
		local E = new_engine()
		E.env.claim = function() error("boom") end
		E.env.remove = function() error("cannot remove") end
		local r = residents.initialize(beds(2), E.env, store)
		eq(r.failed, 2, "unconfirmed: both beds failed")
		eq(r.spawned, 0, "unconfirmed: nothing counted spawned")
		eq(store.data[key(1)], "pending", "unconfirmed: pending left in place")
	end
	do -- the store throwing on the done write
		local data = {}
		local store = {data = data, get = function(k) return data[k] end,
			set = function(k, v)
				if v and v:find("^done:v1") then error("disk") end
				data[k] = v
			end}
		local E = new_engine()
		local r = residents.initialize(beds(2), E.env, store)
		eq(r.failed, 1, "store throw: failure counted")
		eq(r.spawned, 1, "store throw: next bed still spawned")
		eq(E.removed, 1, "store throw: object removed")
		eq(data[key(1)], nil, "store throw: pending cleared after cleanup")
	end
	do -- claimed beds are counted apart from failures
		local E = new_engine({meta = {["3,1,0"] = {villager = "other"}}})
		local r = residents.initialize(beds(2), E.env, new_store())
		eq(r.summary, "Residents: 1 spawned, 1 skipped, 0 failed (1 already claimed)", "claimed line")
	end
end
