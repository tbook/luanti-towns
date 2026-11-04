-- Automatic town session state (issue #395): src/auto_state.lua. Loaded by tests/run.lua:
--   run_group("tests/auto_state_tests.lua", eq)
-- Event-stream tests with synthetic chunk events. Chunk geometry comes from auto_bounds
-- (origin -32, size 80, probe A6). One test runs the real auto_sites lookup for seed "2014".
local eq = ...
local M = dofile("src/auto_state.lua")
local ab = dofile("src/auto_bounds.lua")
local sites = dofile("src/auto_sites.lua")

local SENTINEL = 31000

local function chunk_bounds(cx, cy, cz)
	local o, s = ab.CHUNK_ORIGIN, ab.CHUNKSIZE
	local minp = {x = o + s * cx, y = o + s * cy, z = o + s * cz}
	local maxp = {x = minp.x + s - 1, y = minp.y + s - 1, z = minp.z + s - 1}
	return minp, maxp
end

-- Heights over the chunk columns: a uniform value h, or the chunk top (clipped) when h is nil
-- and top is true. Only the columns are copied; the event owns its table.
local function uniform(minp, maxp, h)
	local t = {}
	for z = minp.z, maxp.z do
		local row = {}
		t[z] = row
		for x = minp.x, maxp.x do row[x] = h end
	end
	return t
end

-- kind: "surface" (ground at y 64, valid for chunk cy 1), "sky" (sentinel), "under" (clipped top),
-- "none" (no heights at all), or a number used as a uniform height.
local function event(cx, cy, cz, kind)
	local minp, maxp = chunk_bounds(cx, cy, cz)
	local heights
	if kind == "surface" then heights = uniform(minp, maxp, 64)
	elseif kind == "sky" then heights = uniform(minp, maxp, SENTINEL)
	elseif kind == "under" then heights = uniform(minp, maxp, maxp.y)
	elseif kind == "none" then heights = nil
	elseif type(kind) == "number" then heights = uniform(minp, maxp, kind)
	end
	return {minp = minp, maxp = maxp, dimension = "overworld", heights = heights}
end

local function box(x1, y1, z1, x2, y2, z2)
	return {min = {x = x1, y = y1, z = z1}, max = {x = x2, y = y2, z = z2}}
end

local adapter = {
	origin = ab.CHUNK_ORIGIN,
	size = ab.CHUNKSIZE,
	accepts = function(e) return e.dimension == "overworld" and not e.singlenode end,
}

-- Synthetic sites. A: activation 0..239, max 40..200, centre (120,120), so it touches chunk
-- indices 0..3 horizontally, and its centre lies in chunk (1,1,1). B: activation 240..479,
-- max 280..440, centre (360,120). The two activation rects are adjacent, not shared.
local SITE_A = {id = "A", center = {x = 120, z = 120}, max_rect = {x1 = 40, z1 = 40, x2 = 200, z2 = 200},
	activation_rect = {x1 = 0, z1 = 0, x2 = 239, z2 = 239}}
local SITE_B = {id = "B", center = {x = 360, z = 120}, max_rect = {x1 = 280, z1 = 40, x2 = 440, z2 = 200},
	activation_rect = {x1 = 240, z1 = 0, x2 = 479, z2 = 239}}

-- The lookup returns every site, as a cell lookup would return every cell overlapping the rect.
-- The session must filter to the sites whose activation rect is touched.
local function lookup_both() return {SITE_A, SITE_B} end

local function new_session(opts)
	opts = opts or {}
	local s, why = M.new({
		lookup = opts.lookup or lookup_both,
		adapter = opts.adapter or adapter,
		footprint = ab.PLAN_EXTENT,
		accepted = opts.accepted,
	})
	eq(type(s), "table", "session builds: " .. tostring(why))
	return s
end

local function acts(list, label)
	eq(type(list), "table", label .. " returns an action list")
	return list or {}
end

-- Option validation.
do
	local s, why, code = M.new(nil)
	eq(s, nil, "options are required")
	eq(code, "invalid_options", "missing options code")
	s, _, code = M.new({adapter = adapter, footprint = ab.PLAN_EXTENT})
	eq(code, "invalid_options", "lookup is required")
	s, _, code = M.new({lookup = lookup_both, adapter = {origin = -32, size = 80}, footprint = ab.PLAN_EXTENT})
	eq(code, "invalid_options", "adapter needs accepts")
	s, _, code = M.new({lookup = lookup_both, adapter = {origin = -32, size = 0, accepts = adapter.accepts},
		footprint = ab.PLAN_EXTENT})
	eq(code, "invalid_options", "adapter size must be positive")
	s, _, code = M.new({lookup = lookup_both, adapter = adapter, footprint = {x1 = 5, z1 = 0, x2 = 1, z2 = 0}})
	eq(code, "invalid_options", "footprint must be a valid rect")
	s, _, code = M.new({lookup = lookup_both, adapter = adapter, footprint = ab.PLAN_EXTENT, accepted = true})
	eq(code, "invalid_options", "accepted must be a function")
end

-- Height classes (A8): valid, clipped at the top, ambiguous at the bottom, sentinel otherwise.
do
	eq(M.classify(64, 48, 127), "valid", "mid-chunk height is valid")
	eq(M.classify(127, 48, 127), "clipped", "height at maxp.y is clipped")
	eq(M.classify(200, 48, 127), "clipped", "height above maxp.y is clipped")
	eq(M.classify(48, 48, 127), "ambiguous", "height at minp.y is ambiguous")
	eq(M.classify(47, 48, 127), "sentinel", "height below the chunk is a sentinel")
	eq(M.classify(SENTINEL, 48, 127), "sentinel", "31000 is a sentinel")
	eq(M.classify(-SENTINEL, 48, 127), "sentinel", "-31000 is a sentinel")
	eq(M.classify(nil, 48, 127), "sentinel", "no entry is a sentinel")
	eq(M.classify(0 / 0, 48, 127), "sentinel", "NaN is a sentinel")
	eq(M.classify(math.huge, 48, 127), "sentinel", "infinity is a sentinel")
end

-- Sky first: recorded, no activation; the surface event after it activates once.
do
	local s = new_session()
	local a = acts(s:on_generated(event(1, 2, 1, "sky")), "sky event")
	eq(#a, 0, "sky-first emits no action")
	eq(s:state("A"), "contacted", "sky-first contacts A")
	eq(s:state("B"), nil, "sky chunk x 48..127 does not touch B")
	local ok, why = s:covers("A", box(60, 130, 60, 100, 140, 100))
	eq(ok, true, "sky chunk is recorded for later coverage: " .. tostring(why))
	ok, why = s:covers("A", box(60, 50, 60, 100, 70, 100))
	eq(ok, false, "ground chunk not yet recorded")
	eq(why, "not_fresh", "unrecorded chunk reason")
	a = acts(s:on_generated(event(1, 1, 1, "surface")), "surface event")
	eq(#a, 1, "first valid surface event activates")
	eq(a[1] and a[1].kind, "activate", "activation kind")
	eq(a[1] and a[1].site.id, "A", "activation names the site")
	eq(s:state("A"), "inspecting", "activation starts inspection")
	ok = s:covers("A", box(60, 50, 60, 100, 70, 100))
	eq(ok, true, "surface chunk is fresh after recording")
end

-- Underground first: clipped heights are recorded but do not activate.
do
	local s = new_session()
	local a = acts(s:on_generated(event(1, -1, 1, "under")), "underground event")
	eq(#a, 0, "underground-first emits no action")
	eq(s:state("A"), "contacted", "underground-first contacts A")
	local ok = s:covers("A", box(60, -100, 60, 100, -50, 100))
	eq(ok, true, "underground chunk is recorded")
	a = acts(s:on_generated(event(1, 1, 1, "surface")), "surface after underground")
	eq(#a, 1, "surface after underground activates once")
end

-- Heights that are not valid ground never activate: all sentinel, all ambiguous, all clipped.
do
	local s = new_session()
	eq(#acts(s:on_generated(event(1, 1, 1, "sky")), "sentinel-only surface"), 0, "sentinel-only chunk does not activate")
	eq(#acts(s:on_generated(event(1, 1, 1, 48)), "ambiguous-only surface"), 0, "ambiguous-only chunk does not activate")
	eq(#acts(s:on_generated(event(1, 1, 1, 127)), "clipped-only surface"), 0, "clipped-only chunk does not activate")
	eq(#acts(s:on_generated(event(1, 1, 1, "none")), "no-heights event"), 0, "event without heights does not activate")
	eq(s:state("A"), "contacted", "invalid surfaces only contact")
end

-- Activation is emitted once: duplicate events are idempotent.
do
	local s = new_session()
	local first = acts(s:on_generated(event(1, 1, 1, "surface")), "first")
	eq(#first, 1, "first surface event activates")
	local dup = event(1, 1, 1, "surface")
	for _ = 1, 3 do
		eq(#acts(s:on_generated(dup), "duplicate"), 0, "duplicate event emits no second activation")
	end
	eq(s:covers("A", box(60, 50, 60, 100, 70, 100)), true, "duplicates leave coverage unchanged")
end

-- Memory-only old neighbours and partial coverage fail conservatively.
do
	local s = new_session()
	s:on_generated(event(1, 1, 1, "surface"))
	local ok, why = s:covers("A", box(100, 60, 60, 170, 70, 100))
	eq(ok, false, "box across an unrecorded old neighbour is not fresh")
	eq(why, "not_fresh", "neighbour reason")
	ok = s:covers("A", box(60, 50, 60, 100, 70, 100))
	eq(ok, true, "box inside the one recorded chunk is fresh")
	ok, why = s:covers("A", box(60, 50, 40, 100, 70, 60))
	eq(ok, false, "box reaching into an unrecorded chunk below in z is not fresh")
	eq(why, "not_fresh", "unrecorded z neighbour reason")
	ok, why = s:covers("A", box(60, 60, 60, 100, 140, 100))
	eq(ok, false, "box reaching into an unrecorded chunk above is not fresh")
	eq(why, "not_fresh", "unrecorded vertical neighbour reason")
end

-- Exploration racing a load: a chunk generated by another request while inspecting is recorded.
do
	local s = new_session()
	s:on_generated(event(1, 1, 1, "surface"))
	local a = acts(s:on_generated(event(2, 1, 1, "surface")), "racing exploration chunk")
	eq(#a, 0, "racing chunk does not start a second activation")
	eq(s:state("A"), "inspecting", "racing chunk keeps inspection")
	local ok = s:covers("A", box(100, 60, 60, 170, 70, 100))
	eq(ok, true, "racing chunk joins the fresh set")
end

-- Envelope: boxes outside the maximum read/write rect are never authorized.
do
	local s = new_session()
	s:on_generated(event(1, 1, 1, "surface"))
	s:on_generated(event(2, 1, 1, "surface"))
	local ok, why = s:covers("A", box(100, 60, 60, 210, 70, 100))
	eq(ok, false, "box past the max rect is rejected")
	eq(why, "outside_envelope", "envelope reason")
	ok, why = s:covers("A", box(60, 60, 60, 100, 60, 60))
	eq(ok, true, "one-node box inside a recorded chunk is fresh")
	ok, why = s:covers("A", box(130, 120, 60, 150, 135, 100))
	eq(ok, false, "vertical padding chunk above the recorded one is not fresh")
	eq(why, "not_fresh", "padding reason")
	ok, why = s:covers("A", {min = {x = 60, y = 60, z = 60}, max = {x = 50, y = 70, z = 70}})
	eq(ok, false, "inverted box is invalid")
	eq(why, "invalid_box", "invalid box reason")
end

-- Centre ground: the centre chunk's valid heights in the footprint; retained once; absent for sky.
do
	local s = new_session()
	s:on_generated(event(1, 2, 1, "sky"))
	eq(s:center("A"), nil, "sky centre chunk retains no ground")
	s:on_generated(event(1, 1, 1, "surface"))
	local c = s:center("A")
	eq(type(c), "table", "surface centre chunk retains ground")
	if c then
		eq(c.valid, 6400, "uniform surface: every column valid")
		eq(c.clipped + c.ambiguous + c.sentinel, 0, "uniform surface: no invalid columns")
		eq(#c.values, 6400, "values hold the valid heights")
		eq(c.chunk.minp.x, 48, "retained chunk minp")
		eq(c.chunk.maxp.z, 127, "retained chunk maxp")
	end
	-- A later event for the same column does not replace the retained copy.
	s:on_generated(event(1, 1, 1, 100))
	eq(s:center("A").valid, 6400, "retained centre is not replaced")
end

-- Centre: a partly clipped, ambiguous or sentinel footprint is not retained. A later clean event
-- for the same centre column still provides it.
do
	local s = new_session()
	local e = event(1, 1, 1, "surface")
	e.heights[60][100] = 48      -- ambiguous
	e.heights[61][100] = 127     -- clipped
	e.heights[62][100] = SENTINEL
	e.heights[63] = nil          -- whole row missing: 80 sentinel columns
	s:on_generated(e)
	eq(s:center("A"), nil, "partly invalid footprint retains no centre")
	eq(s:state("A"), "inspecting", "the same event still activates on its valid ground")
	local one_clipped = event(1, 1, 1, "surface")
	one_clipped.heights[60][100] = 127
	s:on_generated(one_clipped)
	eq(s:center("A"), nil, "a single clipped column blocks retention")
	local one_ambiguous = event(1, 1, 1, "surface")
	one_ambiguous.heights[60][100] = 48
	s:on_generated(one_ambiguous)
	eq(s:center("A"), nil, "a single ambiguous column blocks retention")
	local one_sentinel = event(1, 1, 1, "surface")
	one_sentinel.heights[60][100] = SENTINEL
	s:on_generated(one_sentinel)
	eq(s:center("A"), nil, "a single sentinel column blocks retention")
	s:on_generated(event(1, 1, 1, "surface"))
	local c = s:center("A")
	eq(c and c.valid, 6400, "a later clean event provides the centre")
	eq(c and c.clipped + c.ambiguous + c.sentinel, 0, "retained centre is fully clean")
	eq(c and #c.values, 6400, "values hold the clean valid heights")
end

-- Validation before mutation: a malformed descriptor anywhere in the lookup changes nothing.
do
	local bad = {id = "X", center = {x = 1}}   -- malformed: no centre z, no rects
	for _, list in ipairs({{SITE_A, bad}, {bad, SITE_A}}) do
		local s = new_session({lookup = function() return list end})
		local a, why, code = s:on_generated(event(1, 1, 1, "surface"))
		eq(a, nil, "malformed descriptor makes the event fail")
		eq(code, "invalid_site", "malformed descriptor code")
		eq(why, "invalid site descriptor", "malformed descriptor reason")
		eq(s:state("A"), nil, "a valid site before the bad one is not left inspecting")
		eq(s:covers("A", box(60, 50, 60, 100, 70, 100)), false, "no chunk is recorded for the valid site")
		-- The same session, with the valid site alone, activates normally afterwards.
		s = new_session({lookup = function() return {SITE_A} end})
		local ok = acts(s:on_generated(event(1, 1, 1, "surface")), "recovered event")
		eq(#ok, 1, "the valid site activates once the descriptor list is clean")
	end
end

-- Centre copies are independent of the session's state.
do
	local s = new_session()
	s:on_generated(event(1, 1, 1, "surface"))
	local c = s:center("A")
	c.values[1] = -999
	c.valid = 0
	eq(s:center("A").valid, 6400, "mutating a centre copy leaves the session unchanged")
	eq(s:center("A").values[1], 64, "copied values are independent")
end

-- Completion: finish frees the set; later callbacks are ignored; finish is idempotent.
do
	local s = new_session()
	s:on_generated(event(1, 1, 1, "surface"))
	eq(s:finish("A"), "complete", "inspecting site finishes")
	eq(s:finish("A"), "complete", "second finish is idempotent")
	eq(s:state("A"), "complete", "state is complete")
	local ok, why = s:covers("A", box(60, 50, 60, 100, 70, 100))
	eq(ok, false, "finished site authorizes nothing")
	eq(why, "not_active", "finished site reason")
	eq(#acts(s:on_generated(event(2, 1, 1, "surface")), "after finish"), 0, "later callbacks emit nothing")
	eq(s:state("A"), "complete", "later callbacks leave terminal state")
	eq(s:center("A"), nil, "finished site frees its centre copy")
	eq(s:descriptor("A"), nil, "finished site frees its descriptor")
	eq(s:decline("A"), "complete", "decline cannot undo completion")
end

-- Decline: idempotent, terminal, and later callbacks cannot reactivate.
do
	local s = new_session()
	s:on_generated(event(1, 2, 1, "sky"))
	eq(s:decline("A"), "declined", "contacted site declines")
	eq(s:decline("A"), "declined", "second decline is idempotent")
	eq(#acts(s:on_generated(event(1, 1, 1, "surface")), "after decline"), 0, "declined site does not activate")
	local ok = s:covers("A", box(60, 130, 60, 100, 140, 100))
	eq(ok, false, "declined site authorizes nothing")
	eq(s:finish("A"), nil, "declined site cannot finish")
	eq(select(2, s:finish("A")), "site is not inspecting", "finish reason")
	eq(s:decline("Z"), "declined", "declining an unseen site records a terminal decline")
	eq(s:state("Z"), "declined", "unseen decline is terminal")
	-- Declines are per site: A stays declined while B, untouched so far, activates on its own chunk.
	local a = acts(s:on_generated(event(3, 1, 1, "surface")), "after decline of A")
	eq(#a, 1, "only the undeclined site activates")
	eq(a[1] and a[1].site.id, "B", "B activates, A stays declined")
	eq(s:state("A"), "declined", "A remains declined")
end

-- A decline during inspection frees the set.
do
	local s = new_session()
	s:on_generated(event(1, 1, 1, "surface"))
	eq(s:decline("A"), "declined", "inspecting site can decline (busy job or failure)")
	eq(s:covers("A", box(60, 50, 60, 100, 70, 100)), false, "declined inspection authorizes nothing")
end

-- A new session after restart starts empty: earlier coverage is not carried over.
do
	local s1 = new_session()
	s1:on_generated(event(1, 1, 1, "surface"))
	eq(s1:covers("A", box(60, 50, 60, 100, 70, 100)), true, "old session covers its chunk")
	local s2 = new_session()
	local ok, why = s2:covers("A", box(60, 50, 60, 100, 70, 100))
	eq(ok, false, "new session authorizes nothing from earlier terrain")
	eq(why, "not_active", "new session reason")
	eq(s2:state("A"), nil, "new session has no record of A")
	eq(#acts(s2:on_generated(event(1, 1, 1, "surface")), "new session surface"), 1,
		"new session starts its own activation")
end

-- Registry accepted records suppress activation and recording.
do
	local s = new_session({accepted = function(d) return d.id == "A" end})
	local a = acts(s:on_generated(event(1, 1, 1, "surface")), "accepted site")
	eq(#a, 0, "accepted site emits no activation")
	eq(s:state("A"), "accepted", "accepted site is terminal")
	eq(s:covers("A", box(60, 50, 60, 100, 70, 100)), false, "accepted site authorizes nothing")
	-- A chunk touching both sites: A is terminal, B is not affected and activates.
	local a = acts(s:on_generated(event(3, 1, 1, "surface")), "shared chunk with an accepted site")
	eq(#a, 1, "the other site still activates")
	eq(a[1] and a[1].site.id, "B", "only B activates")
	eq(s:state("A"), "accepted", "A stays accepted")
end

-- Events that are not overworld, or are singlenode, are ignored entirely.
do
	local s = new_session()
	local e = event(1, 1, 1, "surface")
	e.dimension = "underground"
	local a = acts(s:on_generated(e), "other dimension")
	eq(#a, 0, "other dimension emits nothing")
	eq(s:state("A"), nil, "other dimension contacts nothing")
	e = event(1, 1, 1, "surface")
	e.singlenode = true
	eq(#acts(s:on_generated(e), "singlenode"), 0, "singlenode emits nothing")
	eq(s:state("A"), nil, "singlenode contacts nothing")
end

-- Events that do not touch any activation rect are not recorded.
do
	local s = new_session()
	local a = acts(s:on_generated(event(5, 1, 5, "surface")), "far chunk")
	eq(#a, 0, "a far chunk emits nothing")
	eq(s:state("A"), nil, "a far chunk contacts no site")
	eq(s:state("B"), nil, "a far chunk contacts no site (B)")
end

-- Malformed or misaligned events are rejected and change nothing.
do
	local s = new_session()
	local e = event(1, 1, 1, "surface")
	e.minp.x = e.minp.x + 1
	local a, why, code = s:on_generated(e)
	eq(a, nil, "misaligned minp is rejected")
	eq(code, "misaligned_event", "misaligned code")
	e = event(1, 1, 1, "surface")
	e.maxp.y = e.maxp.y - 1
	a, _, code = s:on_generated(e)
	eq(code, "misaligned_event", "short chunk is rejected")
	a, _, code = s:on_generated({dimension = "overworld"})
	eq(code, "invalid_event", "missing bounds is rejected")
	eq(s:state("A"), nil, "rejected events contact nothing")
	eq(why ~= nil, true, "rejection carries a reason")
end

-- A lookup failure is returned, not swallowed.
do
	local s = new_session({lookup = function() return nil, "lookup down", "unavailable" end})
	local a, why, code = s:on_generated(event(1, 1, 1, "surface"))
	eq(a, nil, "lookup failure returns nil")
	eq(why, "lookup down", "lookup reason is returned")
	eq(code, "unavailable", "lookup code is returned")
end

-- Separate sites never share sets. A chunk touching both A and B records for both, but a
-- chunk touching only A never reaches B's set.
do
	local s = new_session()
	s:on_generated(event(3, 2, 1, "sky"))   -- x 208..287 touches A and B
	s:on_generated(event(2, 1, 1, "surface"))  -- x 128..207 touches A only
	eq(s:state("A"), "inspecting", "A activates on its own surface")
	eq(s:state("B"), "contacted", "B is not touched by A's surface chunk")
	-- Chunk x 3 covers 208..287: B's max rect starts at 280, so the boxes stay in that chunk.
	eq(s:covers("B", box(280, 130, 60, 285, 140, 70)), true, "B records the shared sky chunk")
	eq(s:covers("B", box(280, 50, 60, 285, 70, 70)), false, "B has no record of A's ground chunk")
	local a = acts(s:on_generated(event(3, 1, 1, "surface")), "shared surface")
	eq(#a, 1, "B activates on its own surface chunk")
	eq(a[1] and a[1].site.id, "B", "only B's activation is emitted for the shared chunk")
	-- The returned descriptor is a copy: changing it does not change the session.
	if a[1] then a[1].site.max_rect.x1 = -1000 end
	eq(s:covers("B", box(280, 50, 60, 285, 70, 70)), true, "B's copied descriptor did not alter its envelope")
	eq(s:descriptor("B").max_rect.x1, 280, "session descriptor is independent")
	eq(s:covers("A", box(130, 50, 60, 170, 70, 100)), true, "A's set is independent of B's (chunk 2 recorded for A)")
	eq(s:covers("A", box(280, 50, 60, 285, 70, 70)), false, "A's max rect excludes B's region")
end

-- Vertical bound: boxes beyond the engine map limit are rejected, not walked.
do
	eq(M.MAP_LIMIT, ab.MAP_LIMIT, "session map limit matches auto_bounds")
	local s = new_session()
	s:on_generated(event(1, 1, 1, "surface"))
	local ok, why = s:covers("A", box(60, 50, 60, 100, M.MAP_LIMIT + 1, 100))
	eq(ok, false, "box above the map limit is rejected")
	eq(why, "outside_world", "map limit reason")
	ok, why = s:covers("A", box(60, -M.MAP_LIMIT - 1, 60, 100, 70, 100))
	eq(ok, false, "box below the map limit is rejected")
	eq(why, "outside_world", "map limit reason below")
	ok = s:covers("A", box(60, -M.MAP_LIMIT, 60, 100, M.MAP_LIMIT, 100))
	eq(ok, false, "a full-height box is not fresh (its chunks are not recorded)")
end

-- Real auto_sites lookup for seed "2014": one cell-0 site with centre (506,505) (golden row).
do
	local act = {x1 = -423, z1 = -423, x2 = 423, z2 = 423}
	local env = {activation_rect = act, max_rect = {x1 = -245, z1 = -245, x2 = 245, z2 = 245},
		fit = ab.fit(ab.CELL, act, ab.CELL_EDGE_CLEARANCE)}
	local S = sites.new(env)
	local s = M.new({
		lookup = function(rect) return S.lookup("2014", rect) end,
		adapter = adapter,
		footprint = ab.PLAN_EXTENT,
	})
	local d = S.describe("2014", 0, 0)
	-- Chunk (6,1,6) covers x 448..527, z 448..527, y 48..127 and contains the centre.
	local a = acts(s:on_generated(event(6, 1, 6, "surface")), "real lookup surface")
	eq(#a, 1, "real site activates on its centre chunk")
	eq(a[1] and a[1].site.id, d.id, "real activation names the descriptor id")
	local c = s:center(d.id)
	eq(c and c.chunk.minp.x, 448, "real centre chunk is retained")
	eq(c and c.valid, 6400, "real centre chunk has valid ground in the footprint")
	eq(s:covers(d.id, box(460, 60, 460, 500, 70, 500)), true, "real chunk covers an interior box")
	eq(s:covers(d.id, box(300, 60, 300, 310, 70, 310)), false, "real site rejects unrecorded chunks")
end
