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
	eq(s:state("A"), "contacted", "activation leaves the candidate contacted until begin")
	eq(s:begin("A", 0), "inspecting", "begin starts inspection")
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
	eq(s:state("A"), "contacted", "racing chunk changes no state")
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
	eq(s:state("A"), "contacted", "the same event still activates on its valid ground")
	eq(s:begin("A"), "inspecting", "begin after that activation")
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

-- Centre diagnostics: the last footprint scan is reported whether or not a centre is retained, and
-- it is dropped once the site is terminal.
do
	local s = new_session()
	eq(s:center_scan("A"), nil, "no centre scan before the centre chunk is seen")
	local e = event(1, 1, 1, "surface")
	e.heights[60][100] = 48      -- ambiguous
	e.heights[61][100] = 127     -- clipped
	e.heights[62][100] = SENTINEL
	e.heights[63] = nil          -- whole row missing: 80 sentinel columns
	s:on_generated(e)
	eq(s:center("A"), nil, "partly invalid centre is not retained")
	local scan = s:center_scan("A")
	eq(scan and scan.valid, 6400 - 1 - 1 - 81, "scan counts the valid centre columns")
	eq(scan and scan.clipped, 1, "scan counts clipped columns")
	eq(scan and scan.ambiguous, 1, "scan counts ambiguous columns")
	eq(scan and scan.sentinel, 81, "scan counts sentinel columns")
	eq(scan and scan.min, 64, "scan reports the lowest valid height")
	eq(scan and scan.max, 64, "scan reports the highest valid height")
	s:decline("A")
	eq(s:center_scan("A"), nil, "terminal site drops its centre scan")

	local sky = new_session()
	sky:on_generated(event(1, 2, 1, "sky"))
	local none = sky:center_scan("A")
	eq(none and none.valid, 0, "sky centre scan has no valid columns")
	eq(none and none.min, nil, "sky centre scan has no minimum")
	eq(none and none.max, nil, "sky centre scan has no maximum")

	local clean = new_session()
	clean:on_generated(event(1, 1, 1, "surface"))
	local ok = clean:center_scan("A")
	eq(ok and ok.valid, 6400, "retained centre scan counts every valid column")
	eq(ok and ok.min, 64, "retained centre scan reports its height")
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
	eq(s:finish("A"), nil, "a contacted site cannot finish before begin")
	s:begin("A")
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
	eq(s:state("A"), "contacted", "A activates on its own surface")
	eq(s:begin("A"), "inspecting", "A begins")
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

-- ---------------------------------------------------------------------------------------------
-- Cells with several candidates (#431 T4). Synthetic cell {0,0}: C0 (activation 0..239, max
-- 40..200, centre (120,120)) and C1 (activation 240..479, max 280..440, centre (360,120)), plus
-- D in the neighbouring cell {1,0} (activation 480..719, max 520..680, centre (600,120)).
-- Chunk index 5 (x 368..447) touches C1 only; chunk 3 (208..287) touches C0 and C1; chunk 6
-- (448..527) touches C1 and D.
local C0 = {id = "C0", cell = {x = 0, z = 0}, candidate = 0, center = {x = 120, z = 120},
	max_rect = {x1 = 40, z1 = 40, x2 = 200, z2 = 200}, activation_rect = {x1 = 0, z1 = 0, x2 = 239, z2 = 239}}
local C1 = {id = "C1", cell = {x = 0, z = 0}, candidate = 1, center = {x = 360, z = 120},
	max_rect = {x1 = 280, z1 = 40, x2 = 440, z2 = 200}, activation_rect = {x1 = 240, z1 = 0, x2 = 479, z2 = 239}}
local D = {id = "D", cell = {x = 1, z = 0}, candidate = 0, center = {x = 600, z = 120},
	max_rect = {x1 = 520, z1 = 40, x2 = 680, z2 = 200}, activation_rect = {x1 = 480, z1 = 0, x2 = 719, z2 = 239}}
-- Like a cell lookup: every candidate of every cell near the chunk, whatever it touches.
local function lookup_cells() return {C0, C1, D} end
local function cell_session(opts)
	opts = opts or {}
	opts.lookup = opts.lookup or lookup_cells
	return new_session(opts)
end

-- Union activation: contact through C1's rect alone activates the whole cell once; both
-- candidates stay contacted and share one set.
do
	local s = cell_session()
	local a = acts(s:on_generated(event(5, 1, 1, "surface"), 10), "surface through C1's rect")
	eq(#a, 1, "one activation for the cell (D is not touched)")
	eq(a[1] and #a[1].sites, 2, "the activation lists both live candidates")
	eq(a[1] and a[1].site.id, "C0", "site is the first candidate")
	eq(a[1] and a[1].sites[2].id, "C1", "sites keep lookup order")
	eq(a[1] and a[1].cell.x, 0, "the activation names the cell")
	eq(s:state("C0"), "contacted", "C0 contacted although the chunk is outside its rect")
	eq(s:state("C1"), "contacted", "C1 contacted until begin")
	eq(s:state("D"), nil, "D's cell is untouched")
	eq(#acts(s:on_generated(event(3, 1, 1, "surface"), 11), "second surface"), 0, "one activation per cell")
	eq(#acts(s:on_generated(event(1, 1, 1, "surface"), 12), "third surface"), 0, "still one activation per cell")
	-- Shared set: chunk 3 (x 208..287) touches both rects and is in the one set; C1's box in that
	-- chunk is covered although C0 made the first contact there, and C0's box in chunk 1 as well.
	eq(s:covers("C1", box(280, 50, 60, 287, 70, 100)), true, "C1 covered by the shared set (chunk 3)")
	eq(s:covers("C0", box(60, 50, 60, 100, 70, 100)), true, "C0 covered by the shared set (chunk 1)")
	eq(s:covers("C1", box(300, 50, 60, 360, 70, 100)), false, "chunk 4 was never generated: not covered")
	local ok, why = s:covers("C0", box(208, 50, 60, 215, 70, 100))
	eq(ok, false, "a recorded chunk outside the candidate's own max_rect is not authorized")
	eq(why, "outside_envelope", "own max_rect reason")
end

-- Contact from the sky or underground records into the cell's set; the later surface event
-- activates the cell and the earlier chunks stay covered.
do
	local s = cell_session()
	eq(#acts(s:on_generated(event(5, 2, 1, "sky")), "sky contact"), 0, "sky contact does not activate")
	eq(#acts(s:on_generated(event(3, -1, 1, "under")), "underground contact"), 0, "underground contact does not activate")
	eq(s:state("C0"), "contacted", "sibling contacted by the sky chunk")
	eq(s:begin("C0", 1), nil, "begin before activation is refused")
	eq(select(3, s:begin("C0", 1)), "not_activated", "not_activated code")
	eq(s:covers("C1", box(370, 130, 60, 400, 140, 100)), true, "sky chunk covered for C1")
	eq(s:covers("C1", box(280, -100, 60, 287, -50, 100)), true, "underground chunk (x 208..287) covered for C1")
	local a = acts(s:on_generated(event(1, 1, 1, "surface")), "surface")
	eq(#a, 1, "surface activates the cell")
	eq(s:covers("C1", box(370, 130, 60, 400, 140, 100)), true, "earlier sky chunk stays covered")
end

-- Freshness ordering. Chunks the session never saw (generated before first contact, loaded from
-- disk, other dimensions) are never covered; only chunks generated after contact are.
do
	local s = cell_session()
	-- Chunk 2 (x 128..207) existed before the cell was contacted: no event, never recorded.
	local other = event(2, 1, 1, "surface")
	other.dimension = "underworld"
	eq(#acts(s:on_generated(other), "ineligible event"), 0, "ineligible event emits nothing")
	eq(s:state("C0"), nil, "ineligible event is not a contact")
	s:on_generated(event(1, 1, 1, "surface"), 5)      -- first contact: chunk 1 only
	local ok, why = s:covers("C0", box(130, 50, 60, 170, 70, 100))
	eq(ok, false, "a chunk generated before first contact is not covered")
	eq(why, "not_fresh", "pre-contact chunk reason")
	eq(s:covers("C0", box(60, 50, 60, 100, 70, 100)), true, "the first contact chunk is covered")
	s:on_generated(event(2, 1, 1, "surface"), 6)      -- generated after contact
	eq(s:covers("C0", box(130, 50, 60, 170, 70, 100)), true, "a chunk generated after contact is covered")
	-- Once finished, the set is gone and later chunks authorize nothing.
	s:begin("C0", 7)
	eq(s:finish("C0"), "complete", "C0 finishes")
	s:on_generated(event(1, 1, 1, "surface"))
	eq(s:covers("C0", box(60, 50, 60, 100, 70, 100)), false, "finished cell authorizes nothing")
	eq(s:covers("C1", box(280, 50, 60, 287, 70, 100)), false, "declined sibling authorizes nothing")
end

-- Every chunk touching a real candidate's max_rect also touches the union of the cell's
-- activation rects: nothing in a max_rect can be generated unseen once a cell is live.
do
	local act = {x1 = -423, z1 = -423, x2 = 423, z2 = 423}
	local env = {activation_rect = act, max_rect = {x1 = -245, z1 = -245, x2 = 245, z2 = 245},
		fit = ab.fit(ab.CELL, act, ab.CELL_EDGE_CLEARANCE)}
	local S = assert(sites.new(env, {candidates = 9}))
	for _, cell in ipairs({{0, 0}, {-1, 2}}) do
		local list = S.cell("2014", cell[1], cell[2])
		eq(#list, 9, "nine candidates")
		local missed = 0
		local lo_x, hi_x, lo_z, hi_z = math.huge, -math.huge, math.huge, -math.huge
		for _, d in ipairs(list) do
			lo_x, hi_x = math.min(lo_x, d.max_rect.x1), math.max(hi_x, d.max_rect.x2)
			lo_z, hi_z = math.min(lo_z, d.max_rect.z1), math.max(hi_z, d.max_rect.z2)
		end
		for cz = math.floor((lo_z + 32) / 80), math.floor((hi_z + 32) / 80) do
			for cx = math.floor((lo_x + 32) / 80), math.floor((hi_x + 32) / 80) do
				local minp, maxp = chunk_bounds(cx, 0, cz)
				local chunk = {x1 = minp.x, z1 = minp.z, x2 = maxp.x, z2 = maxp.z}
				for _, d in ipairs(list) do
					local m = d.max_rect
					if chunk.x1 <= m.x2 and m.x1 <= chunk.x2 and chunk.z1 <= m.z2 and m.z1 <= chunk.z2 then
						local touched = false
						for _, e in ipairs(list) do
							local r = e.activation_rect
							if chunk.x1 <= r.x2 and r.x1 <= chunk.x2 and chunk.z1 <= r.z2 and r.z1 <= chunk.z2 then
								touched = true
							end
						end
						if not touched then missed = missed + 1 end
					end
				end
			end
		end
		eq(missed, 0, "no chunk of a max_rect escapes the union of the activation rects")
	end
end

-- Self-triggered contacts record chunks but activate nothing, in this cell or a neighbour.
do
	local s = cell_session()
	local own = event(6, 1, 1, "surface")      -- touches C1 (cell 0) and D (cell 1)
	own.self_triggered = true
	eq(#acts(s:on_generated(own, 1), "self-triggered surface"), 0, "self-triggered contact activates nothing")
	eq(s:state("C1"), "contacted", "the cell is contacted")
	eq(s:state("D"), "contacted", "the neighbouring cell is contacted")
	eq(s:covers("D", box(520, 50, 60, 527, 70, 100)), true, "the self-triggered chunk is recorded")
	eq(select(3, s:begin("D", 1)), "not_activated", "the neighbour was not activated")
	eq(#acts(s:on_generated(own, 2), "repeat self-triggered"), 0, "repeating it still activates nothing")
	-- An ordinary event later activates (the player arrives); the recorded chunk stays covered.
	local a = acts(s:on_generated(event(7, 1, 1, "surface"), 3), "player arrives at D")
	eq(#a, 1, "ordinary event activates the neighbour")
	eq(a[1] and a[1].site.id, "D", "D's cell activates")
	eq(s:covers("D", box(520, 50, 60, 527, 70, 100)), true, "self-triggered chunk stays covered")
	-- Centre copy is still taken from a self-triggered centre chunk (A9: only its own event).
	local s2 = cell_session()
	local centre = event(1, 1, 1, "surface")
	centre.self_triggered = true
	s2:on_generated(centre)
	eq(s2:center("C0") and s2:center("C0").valid, 6400, "self-triggered centre chunk still retains the centre")
end

-- begin: one inspecting candidate per cell; a decline frees the slot; declined stays declined.
do
	local s = cell_session()
	s:on_generated(event(3, 1, 1, "surface"), 100)
	eq(s:begin("C0", 101), "inspecting", "first begin")
	eq(s:state("C0"), "inspecting", "state after begin")
	local r, _, code = s:begin("C1", 102)
	eq(r, nil, "second begin while a sibling inspects is refused")
	eq(code, "sibling_inspecting", "sibling_inspecting code")
	eq(select(3, s:begin("C0", 102)), "not_contacted", "an inspecting candidate cannot begin again")
	eq(s:state("C1"), "contacted", "the refused sibling stays contacted")
	eq(s:decline("C0"), "declined", "failed candidate declines")
	eq(s:covers("C1", box(280, 50, 60, 287, 70, 100)), true, "set survives while a sibling is live")
	eq(s:begin("C1", 103), "inspecting", "the sibling can begin after the decline")
	eq(select(3, s:begin("C0", 104)), "not_contacted", "a declined candidate cannot begin again")
	eq(#acts(s:on_generated(event(3, 1, 1, "surface"), 105), "later surface"), 0, "no reactivation")
	eq(s:state("C0"), "declined", "declined candidate stays declined")
	eq(s:decline("C1"), "declined", "last candidate declines")
	eq(s:covers("C1", box(280, 50, 60, 287, 70, 100)), false, "set dropped with the last live candidate")
	eq(#acts(s:on_generated(event(3, 1, 1, "surface"), 106), "after the cell ended"), 0, "terminal cell stays terminal")
	eq(s:state("C1"), "declined", "terminal cell state")
end

-- Success declines the siblings; the cell is terminal and a second accept is rejected.
do
	local s = cell_session()
	s:on_generated(event(3, 1, 1, "surface"), 0)
	s:begin("C1", 1)
	eq(s:finish("C1"), "complete", "inspecting candidate finishes")
	eq(s:state("C0"), "declined", "finish declines the sibling")
	eq(s:covers("C1", box(280, 50, 60, 287, 70, 100)), false, "finish drops the cell set")
	local r, _, code = s:begin("C0", 2)
	eq(r, nil, "the declined sibling cannot begin")
	eq(code, "not_contacted", "second accept is refused at begin")
	r, _, code = s:finish("C0")
	eq(r, nil, "the declined sibling cannot finish")
	eq(code, "not_inspecting", "second accept is refused at finish")
	eq(s:finish("C1"), "complete", "finish stays idempotent")
	eq(#acts(s:on_generated(event(3, 1, 1, "surface"), 3), "after finish"), 0, "a finished cell never reactivates")
	eq(s:descriptor("C0"), nil, "sibling descriptor freed")
end

-- The 60 s limit from activation, by the caller's clock; the module reads no clock itself.
do
	eq(M.CELL_LIMIT, 60, "cell limit is 60 seconds")
	local s = cell_session()
	s:on_generated(event(3, 1, 1, "surface"), 100)
	eq(s:begin("C0", 160), "inspecting", "begin exactly at the limit is allowed")
	s:decline("C0")
	local r, _, code = s:begin("C1", 160.5)
	eq(r, nil, "begin after the limit is refused")
	eq(code, "cell_expired", "cell_expired code")
	eq(s:state("C1"), "declined", "an expired cell declines its candidates")
	eq(s:covers("C1", box(280, 50, 60, 287, 70, 100)), false, "expired cell authorizes nothing")
	local e = cell_session()
	e:on_generated(event(3, 1, 1, "surface"), 0)
	eq(select(3, e:begin("C0", "soon")), "invalid_clock", "a non-number clock is rejected")
	eq(e:state("C0"), "contacted", "an invalid clock changes nothing")
	-- Without an activation time (caller gave no clock) the limit is not applied.
	local n = cell_session()
	n:on_generated(event(3, 1, 1, "surface"))
	eq(n:begin("C0", 1e9), "inspecting", "no activation time means no limit")
end

-- Centre data is kept per candidate from the first event for that candidate's own centre chunk.
do
	local s = cell_session()
	s:on_generated(event(4, 2, 1, "sky"))                 -- C1's centre chunk column, sky
	eq(s:center("C1"), nil, "sky retains no C1 centre")
	s:on_generated(event(4, 1, 1, "surface"))             -- activates; C1's centre chunk
	eq(s:center("C1") and s:center("C1").chunk.minp.x, 288, "C1 centre retained from its own chunk")
	eq(s:center("C0"), nil, "C0 centre not copied from another candidate's chunk")
	s:on_generated(event(1, 1, 1, 70))
	eq(s:center("C0") and s:center("C0").values[1], 70, "C0 centre retained from its own first event")
	s:on_generated(event(1, 1, 1, 80))
	eq(s:center("C0").values[1], 70, "retained once")
	s:begin("C1")
	s:decline("C1")
	eq(s:center("C1"), nil, "terminal candidate drops its centre")
	eq(s:center("C0") and s:center("C0").valid, 6400, "the live sibling keeps its centre")
end

-- Declines before contact stick; accepted cells never activate.
do
	local s = cell_session()
	s:decline("C1")
	local a = acts(s:on_generated(event(3, 1, 1, "surface")), "surface after a pre-decline")
	eq(#a, 1, "the cell still activates")
	eq(a[1] and #a[1].sites, 1, "only the undeclined candidate is listed")
	eq(a[1] and a[1].site.id, "C0", "C0 is listed")
	eq(s:state("C1"), "declined", "pre-declined candidate stays declined")
	local acc = cell_session({accepted = function(d) return d.cell.x == 0 end})
	eq(#acts(acc:on_generated(event(3, 1, 1, "surface")), "accepted cell"), 0, "accepted cell does not activate")
	eq(acc:state("C0"), "accepted", "accepted candidate")
	eq(acc:state("C1"), "accepted", "accepted sibling")
end

-- N = 9 with the real lattice lookup: activation through any candidate's rect, then begin.
do
	local act = {x1 = -423, z1 = -423, x2 = 423, z2 = 423}
	local env = {activation_rect = act, max_rect = {x1 = -245, z1 = -245, x2 = 245, z2 = 245},
		fit = ab.fit(ab.CELL, act, ab.CELL_EDGE_CLEARANCE)}
	local S = assert(sites.new(env, {candidates = 9}))
	local s = M.new({lookup = function(rect) return S.lookup("2014", rect) end, adapter = adapter,
		footprint = ab.PLAN_EXTENT})
	local list = S.cell("2014", 0, 0)
	-- Chunk (6,1,6) x 448..527: inside cell 0 (0..1023).
	local a = acts(s:on_generated(event(6, 1, 6, "surface"), 0), "lattice surface")
	local cells = {}
	for _, x in ipairs(a) do cells[#cells + 1] = x.cell.x .. ":" .. x.cell.z end
	local own
	for _, x in ipairs(a) do if x.cell.x == 0 and x.cell.z == 0 then own = x end end
	eq(own ~= nil, true, "cell 0 activates")
	eq(own and #own.sites, 9, "all nine candidates are live")
	eq(own and own.site.id, list[1].id, "first candidate leads")
	eq(s:begin(list[4].id, 1), "inspecting", "any candidate can begin")
	eq(select(3, s:begin(list[5].id, 1)), "sibling_inspecting", "only one at a time")
	eq(s:finish(list[4].id), "complete", "finish")
	local declined = 0
	for _, d in ipairs(list) do if s:state(d.id) == "declined" then declined = declined + 1 end end
	eq(declined, 8, "eight siblings declined")
end

-- N = 1 (the default): one candidate per cell, begin right after activation as automatic.lua does.
do
	local act = {x1 = -423, z1 = -423, x2 = 423, z2 = 423}
	local env = {activation_rect = act, max_rect = {x1 = -245, z1 = -245, x2 = 245, z2 = 245},
		fit = ab.fit(ab.CELL, act, ab.CELL_EDGE_CLEARANCE)}
	local S = assert(sites.new(env))
	local s = M.new({lookup = function(rect) return S.lookup("2014", rect) end, adapter = adapter,
		footprint = ab.PLAN_EXTENT})
	local d = S.describe("2014", 0, 0)
	local a = acts(s:on_generated(event(6, 1, 6, "surface"), 0), "N = 1 surface")
	eq(#a, 1, "one activation")
	eq(a[1] and #a[1].sites, 1, "one candidate")
	eq(a[1] and a[1].site.id, d.id, "the single candidate")
	eq(s:begin(d.id, 0), "inspecting", "begin takes it to inspecting at once")
	eq(s:covers(d.id, box(460, 60, 460, 500, 70, 500)), true, "covered as before")
end

-- Centre copy (A9): only the event for the chunk that contains the candidate's centre sets it,
-- even when a neighbouring chunk intersects the centre footprint (C0 footprint x,z -12..252).
do
	local s = cell_session()
	-- Chunk 2 (x 128..207) holds z 120 but not x 120: x bound alone excludes it.
	s:on_generated(event(2, 1, 1, "surface"))
	eq(s:center("C0"), nil, "x-neighbour chunk intersecting the footprint does not set the centre")
	eq(s:center_scan("C0"), nil, "x-neighbour chunk makes no centre scan")
	-- Chunk (1,1,2) (z 128..207) holds x 120 but not z 120: z bound alone excludes it.
	s:on_generated(event(1, 1, 2, "surface"))
	eq(s:center("C0"), nil, "z-neighbour chunk intersecting the footprint does not set the centre")
	eq(s:center_scan("C0"), nil, "z-neighbour chunk makes no centre scan")
	s:on_generated(event(0, 1, 1, "surface"))
	s:on_generated(event(1, 1, 0, "surface"))
	eq(s:center("C0"), nil, "low-side neighbours do not set the centre")
	s:on_generated(event(1, 1, 1, "surface"))
	eq(s:center("C0") and s:center("C0").valid, 6400, "the centre chunk's own event sets it")

	-- Two candidates of one cell with centres in different chunks, both footprints overlapping both.
	local E0 = {id = "E0", cell = {x = 0, z = 0}, center = {x = 120, z = 120},
		max_rect = {x1 = 40, z1 = 40, x2 = 200, z2 = 200}, activation_rect = {x1 = 0, z1 = 0, x2 = 239, z2 = 239}}
	local E1 = {id = "E1", cell = {x = 0, z = 0}, center = {x = 200, z = 120},
		max_rect = {x1 = 120, z1 = 40, x2 = 280, z2 = 200}, activation_rect = {x1 = 80, z1 = 0, x2 = 319, z2 = 239}}
	local t = new_session({lookup = function() return {E0, E1} end})
	t:on_generated(event(2, 1, 1, "surface"))     -- E1's centre chunk (x 128..207)
	eq(t:center("E1") and t:center("E1").chunk.minp.x, 128, "E1 centre set from its own chunk")
	eq(t:center("E0"), nil, "E0 centre not set by E1's centre chunk")
	t:on_generated(event(1, 1, 1, "surface"))     -- E0's centre chunk (x 48..127)
	eq(t:center("E0") and t:center("E0").chunk.minp.x, 48, "E0 centre set from its own chunk")
	eq(t:center("E1").chunk.minp.x, 128, "E1 centre unchanged by E0's chunk")
end

-- Activation is once per cell: a different valid surface event touching another candidate's rect
-- after activation emits nothing.
do
	local s = cell_session()
	eq(#acts(s:on_generated(event(1, 1, 1, "surface")), "first"), 1, "chunk 1 (C0 only) activates the cell")
	eq(#acts(s:on_generated(event(5, 1, 1, "surface")), "C1-only chunk"), 0, "a surface chunk of C1's rect adds no activation")
	eq(#acts(s:on_generated(event(3, 1, 1, "surface")), "shared chunk"), 0, "a shared surface chunk adds no activation")
	eq(s:state("C1"), "contacted", "sibling is still just contacted")
end

-- live(rect): contacted and inspecting candidates overlapping a query (Roads integration, #458).
do
	local s = new_session()
	eq(#s:live({x1 = 0, z1 = 0, x2 = 1000, z2 = 1000}), 0, "no candidate is live before contact")
	s:on_generated(event(1, 1, 1, "surface"))
	local all = s:live({x1 = 0, z1 = 0, x2 = 1000, z2 = 1000})
	eq(#all, 1, "only the contacted candidate is live")
	eq(all[1].id, "A", "contacted candidate listed")
	eq(all[1].state, "contacted", "state reported")
	eq(all[1].max_rect.x1, 40, "max_rect reported")
	all[1].max_rect.x1 = -5
	eq(s:live({x1 = 0, z1 = 0, x2 = 1000, z2 = 1000})[1].max_rect.x1, 40, "result is a copy")
	eq(#s:live({x1 = 201, z1 = 0, x2 = 300, z2 = 300}), 0, "a query outside max_rect does not match")
	eq(#s:live({x1 = 200, z1 = 200, x2 = 300, z2 = 300}), 1, "an edge-touching query matches")
	eq(s:begin("A"), "inspecting", "begin")
	eq(s:live({x1 = 0, z1 = 0, x2 = 100, z2 = 100})[1].state, "inspecting", "inspecting is live")
	s:decline("A")
	eq(#s:live({x1 = 0, z1 = 0, x2 = 1000, z2 = 1000}), 0, "declined candidates are not live")
	local bad, _, code = s:live({x1 = 5})
	eq(bad, nil, "invalid rect rejected")
	eq(code, "invalid_rect", "invalid rect code")
end
