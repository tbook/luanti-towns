-- Verified road exits (#458): src/town_exits.lua. Loaded by tests/run.lua:
--   loadfile("tests/town_exits_tests.lua")(eq)
local eq = ...
local exits = dofile("src/town_exits.lua")

local COBBLE, STAIR = "mcl_core:cobble", "mcl_stairs:stair_cobble"

local function flat(source, x, z, dir, width)
	local columns = {}
	for t = 0, width - 1 do
		columns[#columns + 1] = dir.x ~= 0 and {x = x, z = z + t} or {x = x + t, z = z}
	end
	local profile = {}
	for n = 1, 4 do profile[n] = {y = 5, name = COBBLE, param2 = 0} end
	return {source = source, direction = dir, columns = columns, length = 4, profile = profile}
end

-- A fake world holding exactly what a candidate describes.
local function world_for(list)
	local nodes = {}
	for _, c in ipairs(list) do
		for _, col in ipairs(c.columns) do
			for n = 0, c.length - 1 do
				local s = c.profile[n + 1]
				nodes[(col.x + c.direction.x * n) .. ":" .. s.y .. ":" .. (col.z + c.direction.z * n)] = s
			end
		end
	end
	return nodes, function(x, y, z)
		local s = nodes[x .. ":" .. y .. ":" .. z]
		if not s then return "air", 0 end
		return s.name, s.param2
	end
end

local function ids(list)
	local out = {}
	for _, e in ipairs(list) do out[#out + 1] = e.id end
	return table.concat(out, ",")
end

-- Stable ids, independent of input and column order.
do
	local a = flat("street", 10, 20, {x = 1, z = 0}, 4)
	local b = flat("wall_postern", -10, 7, {x = -1, z = 0}, 2)
	local c = flat("wall_opening", 3, -9, {x = 0, z = 1}, 2)
	local d = flat("wall_gatehouse", 8, 30, {x = 0, z = -1}, 4)
	local _, get = world_for({a, b, c, d})
	local e1 = exits.verify({a, b, c, d}, get)
	local flipped = {}
	for _, cand in ipairs({d, c, b, a}) do
		local copy = {source = cand.source, direction = cand.direction, length = cand.length,
			profile = cand.profile, columns = {}}
		for i = #cand.columns, 1, -1 do copy.columns[#copy.columns + 1] = cand.columns[i] end
		flipped[#flipped + 1] = copy
	end
	local e2 = exits.verify(flipped, get)
	eq(ids(e1), ids(e2), "ids independent of input and column order")
	eq(ids(e1), "+x:10:20,+z:3:-9,-x:-10:7,-z:8:30", "exit ids use direction and first column")
	eq(e1[1].columns[1].z, 20, "columns sorted by transverse position")
	eq(e1[1].columns[4].z, 23, "last column")
	eq(e1[1].source, "street", "source preserved")
end

-- Flat and sloped profiles verify; results are fresh copies.
do
	local f = flat("street", 0, 0, {x = 1, z = 0}, 2)
	local sloped = {source = "wall_opening", direction = {x = 0, z = 1}, length = 5,
		columns = {{x = 40, z = 0}, {x = 41, z = 0}},
		profile = {{y = 5, name = COBBLE, param2 = 0}, {y = 6, name = STAIR, param2 = 0},
			{y = 7, name = STAIR, param2 = 0}, {y = 8, name = "mcl_stairs:slab_cobble", param2 = 0},
			{y = 8, name = COBBLE, param2 = 0}}}
	local _, get = world_for({f, sloped})
	local out, omitted = exits.verify({f, sloped}, get)
	eq(#out, 2, "flat and sloped exits verify")
	eq(#omitted, 0, "nothing omitted")
	eq(out[1].id, "+x:0:0", "sorted by id")
	eq(out[2].profile[2].name, STAIR, "sloped profile kept")
	out[2].profile[2].name = "changed"
	eq(sloped.profile[2].name, STAIR, "output does not alias input")
end

-- Mismatches drop the exit with a reason; the rest survive.
do
	local good = flat("street", 0, 0, {x = 1, z = 0}, 2)
	local bad_name = flat("street", 0, 10, {x = 1, z = 0}, 2)
	local bad_p2 = flat("street", 0, 20, {x = 1, z = 0}, 2)
	local missing = flat("street", 0, 30, {x = 1, z = 0}, 2)
	local nodes, get = world_for({good, bad_name, bad_p2, missing})
	nodes["2:5:11"] = {name = "mcl_core:stone", param2 = 0}
	nodes["3:5:20"] = {name = COBBLE, param2 = 1}
	nodes["1:5:30"] = nil
	local out, omitted = exits.verify({good, bad_name, bad_p2, missing}, get)
	eq(ids(out), "+x:0:0", "only the matching exit is kept")
	eq(#omitted, 3, "three omitted")
	for _, o in ipairs(omitted) do eq(type(o.reason), "string", "omission has a reason") end
	eq(omitted[1].id, "+x:0:10", "omitted sorted by id")
	-- "ignore" (not loaded) drops the exit.
	local out2, omitted2 = exits.verify({good}, function() return "ignore", 0 end)
	eq(#out2, 0, "unloaded nodes drop the exit")
	eq(omitted2[1].reason:find("not loaded", 1, true) ~= nil, true, "unloaded reason")
	-- A throwing reader propagates.
	eq(pcall(exits.verify, {good}, function() error("boom") end), false, "reader errors propagate")
end

-- Malformed candidates and duplicates.
do
	local good = flat("street", 0, 0, {x = 1, z = 0}, 2)
	local dup = flat("wall_opening", 0, 0, {x = 1, z = 0}, 2)
	local short = flat("street", 0, 50, {x = 1, z = 0}, 2)
	short.profile[4] = nil
	local wide = flat("street", 0, 60, {x = 1, z = 0}, 2)
	wide.columns = {{x = 0, z = 60}, {x = 0, z = 61}, {x = 0, z = 62}, {x = 0, z = 63}, {x = 0, z = 64}}
	local badsource = flat("street", 0, 70, {x = 1, z = 0}, 2)
	badsource.source = "magic"
	local _, get = world_for({good, dup})
	local out, omitted = exits.verify({good, dup, short, wide, badsource, "junk"}, get)
	eq(#out, 1, "only one valid exit")
	eq(#omitted, 5, "malformed and duplicate candidates omitted")
end

-- Caps: at most 32 exits and 32 omissions.
do
	local list = {}
	for i = 1, 40 do list[i] = flat("street", i * 10, 0, {x = 1, z = 0}, 2) end
	local _, get = world_for(list)
	local out, omitted = exits.verify(list, get)
	eq(#out, exits.MAX_EXITS, "exits capped")
	eq(#omitted, 8, "overflow reported")
	eq(out[1].id, "+x:100:0", "lexicographically lowest ids retained")
	local junk = {}
	for i = 1, 50 do junk[i] = {} end
	local _, om = exits.verify(junk, get)
	eq(#om, exits.MAX_OMITTED, "omissions capped")
end

-- Core and structures.
do
	local core = exits.core_rect({x1 = 0, z1 = 0, x2 = 10, z2 = 12})
	eq(core.x1 .. "," .. core.z1 .. "," .. core.x2 .. "," .. core.z2, "-1,-1,11,13", "core widened by the wall line")
	local rects = exits.structure_rects({
		{min = {x = 30, y = 0, z = 30}, max = {x = 33, y = 5, z = 33}},
		{x1 = 20, z1 = 20, x2 = 22, z2 = 22},
		{x1 = 20, z1 = 20, x2 = 22, z2 = 22},
		{x1 = 0, z1 = 0, x2 = 5, z2 = 5},
		{x1 = "a"},
	}, core)
	eq(#rects, 2, "duplicates, inner and malformed rects dropped")
	eq(rects[1].x1, 20, "sorted")
	local many = {}
	for i = 1, 200 do many[i] = {x1 = 100 + i * 5, z1 = 0, x2 = 102 + i * 5, z2 = 3} end
	local merged = exits.structure_rects(many, core)
	eq(#merged, 1, "oversized list collapses to its union")
	eq(merged[1].x1, 105, "union x1")
	eq(merged[1].x2, 1102, "union x2")
end

-- build + validation + copy.
do
	local f = flat("street", 0, 0, {x = 1, z = 0}, 2)
	local _, get = world_for({f})
	local p = exits.build({bounds = {x1 = -20, z1 = -20, x2 = -5, z2 = -5}, candidates = {f},
		boxes = {{x1 = 50, z1 = 50, x2 = 60, z2 = 60}}}, get)
	eq(exits.valid_published(p), true, "built record is valid")
	local c = exits.copy_published(p)
	c.exits[1].columns[1].x = 99
	eq(p.exits[1].columns[1].x, 0, "copy is deep")
	eq(exits.valid_published(c), false, "an exit whose id differs from its columns is invalid")
	local none = exits.without_exits({bounds = {x1 = 0, z1 = 0, x2 = 1, z2 = 1}}, "verification failed")
	eq(exits.valid_published(none), true, "record without exits is valid")
	eq(#none.exits, 0, "no exits")
	eq(none.omitted[1].reason, "verification failed", "reason kept")
	for _, broken in ipairs({"x", {}, {format = 2}, {format = 1, core = {}},
		{format = 1, core = {x1 = 0, z1 = 0, x2 = 1, z2 = 1}, structures = {{}}, exits = {}, omitted = {}},
		{format = 1, core = {x1 = 0, z1 = 0, x2 = 1, z2 = 1}, structures = {}, exits = {{id = "x"}}, omitted = {}},
		{format = 1, core = {x1 = 0, z1 = 0, x2 = 1, z2 = 1}, structures = {}, exits = {}, omitted = {{}}}}) do
		eq(exits.valid_published(broken), false, "malformed published rejected")
	end
end
