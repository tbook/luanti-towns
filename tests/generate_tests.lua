-- /towns_generate tests (ticket #16): argument parsing, seed generation,
-- report formatting and the controller driven by fakes.
-- Loaded by tests/run.lua:
--   loadfile("tests/generate_tests.lua")(eq, fails, planner, generate_factory)
local eq, fails, planner, generate_factory = ...
local generate = generate_factory(planner)
local medieval_profile = assert(planner.landmark_profile(dofile("src/catalog.lua").snapshot()))
local LIMIT = planner.SEED_LIMIT

local function has(s, needle) return tostring(s):find(needle, 1, true) ~= nil end

------------------------------------------------------------------------
-- Help text
------------------------------------------------------------------------
eq(has(generate.HELP, "OVERWRITING"), true, "help warns about overwriting")
eq(has(generate.HELP, "no preview and no confirmation"), true, "help: no preview")
eq(has(generate.HELP, "disposable Creative worlds"), true, "help: disposable")
eq(has(generate.HELP, "server"), true, "help: privilege")
eq(has(generate.HELP, tostring(LIMIT)), true, "help: seed range")

------------------------------------------------------------------------
-- parse_args
------------------------------------------------------------------------
local a = generate.parse_args("")
eq(a.seed, nil, "empty: no seed")
eq(generate.parse_args("   ").seed, nil, "blank: no seed")
eq(generate.parse_args(nil).seed, nil, "nil param: no seed")
eq(generate.parse_args("42").seed, 42, "plain seed")
eq(generate.parse_args("  -17 ").seed, -17, "negative seed with spaces")
eq(generate.parse_args("+5").seed, 5, "plus sign")
eq(generate.parse_args("007").seed, 7, "leading zeros")
eq(generate.parse_args("-0").seed, 0, "negative zero")
eq(1 / generate.parse_args("-0").seed, math.huge, "negative zero normalised")
eq(generate.parse_args(tostring(LIMIT)).seed, LIMIT, "upper limit accepted")
eq(generate.parse_args(tostring(-LIMIT)).seed, -LIMIT, "lower limit accepted")
eq(generate.parse_args("medieval 42 walls=on").force_walls, true, "command forces walls on")
eq(generate.parse_args("walls=off").force_walls, false, "command forces walls off without a seed")

for _, bad in ipairs({"abc", "1.5", "1e3", "0x10", "--1", "1,2", "NaN", "inf", "5x", "."}) do
	local r, msg = generate.parse_args(bad)
	eq(r, nil, "rejects '" .. bad .. "'")
	eq(has(msg, "integer"), true, "message for '" .. bad .. "' says integer")
	eq(has(msg, "Usage"), true, "message for '" .. bad .. "' has usage")
end

local r, msg = generate.parse_args("1 2")
eq(r, nil, "rejects extra arguments")
eq(has(msg, "Too many"), true, "extra args message")
r = generate.parse_args("12 abc")
eq(r, nil, "rejects seed plus word")

-- Legacy error strings (pre-#151) pinned exactly. USAGE itself gained the
-- type syntax; the legacy prefix/wording must not change.
eq(generate.USAGE, "Usage: /towns_generate [medieval|roman] [seed] [walls=on|walls=off], where seed is an integer from -"
	.. LIMIT .. " to " .. LIMIT .. ".", "usage text")
local _, legacy = generate.parse_args("abc")
eq(legacy, "Invalid seed 'abc': it must be an integer. " .. generate.USAGE, "legacy: word seed")
_, legacy = generate.parse_args("1.5")
eq(legacy, "Invalid seed '1.5': it must be an integer. " .. generate.USAGE, "legacy: fractional seed")
_, legacy = generate.parse_args("1 2")
eq(legacy, "Too many arguments (2). " .. generate.USAGE, "legacy: two numbers")
_, legacy = generate.parse_args("abc def")
eq(legacy, "Too many arguments (2). " .. generate.USAGE, "legacy: two words")
_, legacy = generate.parse_args("1.5 2")
eq(legacy, "Too many arguments (2). " .. generate.USAGE, "legacy: fractional then number")
_, legacy = generate.parse_args("12 abc")
eq(legacy, "Too many arguments (2). " .. generate.USAGE, "legacy: seed then word")
_, legacy = generate.parse_args("roman 1 2")
eq(legacy, "Too many arguments (3). " .. generate.USAGE, "type plus two numbers counts the type")

-- Out of range (including a 64-bit world seed): rejected, never folded, and
-- the message shows the allowed range from planner.check_seed.
for _, big in ipairs({tostring(LIMIT + 1), tostring(-LIMIT - 1), "9223372036854775807",
		"-9223372036854775808", "99999999999999999999999999"}) do
	r, msg = generate.parse_args(big)
	eq(r, nil, "rejects out-of-range " .. big)
	eq(has(msg, tostring(LIMIT)), true, "range in message for " .. big)
	eq(has(msg, big), true, "message echoes " .. big)
	eq(has(msg, "-" .. LIMIT), true, "lower bound in message for " .. big)
end

-- Town type (leading token): legacy forms unchanged, default medieval.
do
	local p = generate.parse_args("")
	eq(p.town_type, "medieval", "legacy: empty means medieval")
	eq(generate.parse_args("42").town_type, "medieval", "legacy: plain seed means medieval")
	eq(generate.parse_args("42").seed, 42, "legacy: plain seed kept")
	eq(generate.parse_args("medieval").town_type, "medieval", "explicit medieval")
	eq(generate.parse_args("medieval").seed, nil, "explicit medieval: no seed")
	eq(generate.parse_args("roman").town_type, "roman", "explicit roman")
	eq(generate.parse_args("  roman  ").seed, nil, "roman alone: seed omitted")
	eq(generate.parse_args("roman 42").town_type, "roman", "roman with seed: type")
	eq(generate.parse_args("roman 42").seed, 42, "roman with seed: seed")
	eq(generate.parse_args("medieval -7").seed, -7, "medieval with seed")
	eq(generate.parse_args("ROMAN 3").town_type, "roman", "type is case-insensitive")
	eq(generate.parse_args("roman " .. LIMIT).seed, LIMIT, "roman with upper limit")
	local r, msg = generate.parse_args("castle")
	eq(r, nil, "unknown single word rejected")
	eq(has(msg, "integer") and has(msg, "roman"), true, "single word message names the types")
	r, msg = generate.parse_args("castle 5")
	eq(r, nil, "unknown type with seed rejected")
	eq(msg, "Too many arguments (2). " .. generate.USAGE, "castle 5: legacy too-many message")
	eq(has(msg, "[medieval|roman]"), true, "usage shows the types")
	r, msg = generate.parse_args("roman abc")
	eq(r, nil, "roman with non-integer seed rejected")
	eq(has(msg, "integer"), true, "roman bad seed message")
	r, msg = generate.parse_args("roman roman")
	eq(r, nil, "type word as seed rejected")
	r, msg = generate.parse_args("roman 1 2")
	eq(r, nil, "roman with two seeds rejected")
	eq(has(msg, "Too many"), true, "roman extra args message")
	r, msg = generate.parse_args("roman 1.5")
	eq(r, nil, "roman with fractional seed rejected")
	r, msg = generate.parse_args("roman " .. (LIMIT + 1))
	eq(r, nil, "roman with out-of-range seed rejected")
	eq(has(msg, tostring(LIMIT)), true, "roman out-of-range message shows range")
	r, msg = generate.parse_args("medieval roman 1")
	eq(r, nil, "two types rejected")
	eq(has(msg, "Too many"), true, "two types: too many")
end

------------------------------------------------------------------------
-- random_seed
------------------------------------------------------------------------
local function valid(s)
	return planner.check_seed(s) == true and s >= 1 and s <= LIMIT
end
eq(generate.random_seed(1700000000123), generate.random_seed(1700000000123),
	"random_seed deterministic")
eq(generate.random_seed(1) ~= generate.random_seed(2), true, "random_seed varies")
local all_valid = true
for _, e in ipairs({0, 1, 2 ^ 31, 2 ^ 40 + 7, 1700000000000, -5, 0.5, 1e15}) do
	if not valid(generate.random_seed(e)) then all_valid = false end
end
eq(all_valid, true, "random_seed always in the allowed range")
eq(valid(generate.random_seed(0 / 0)), true, "random_seed survives NaN entropy")
eq(valid(generate.random_seed(math.huge)), true, "random_seed survives inf entropy")
local seen = {}
for i = 1, 200 do seen[generate.random_seed(1700000000000 + i)] = true end
local distinct = 0
for _ in pairs(seen) do distinct = distinct + 1 end
eq(distinct > 190, true, "random_seed gives distinct seeds for nearby clocks")
-- Injected RNG decides the value and receives the full range.
local got_lo, got_hi
eq(generate.random_seed(123, function(lo, hi) got_lo, got_hi = lo, hi; return 4242 end),
	4242, "injected rng value used")
eq(got_lo, 1, "rng lo")
eq(got_hi, LIMIT, "rng hi")
fails(function() generate.random_seed(1, function() return LIMIT + 5 end) end,
	"rng returned", "rng out of range raises")
fails(function() generate.random_seed(1, function() return 1.5 end) end,
	"rng returned", "rng non-integer raises")
eq(valid(generate.random_seed(1, function(lo) return lo end)), true, "rng lower edge")

------------------------------------------------------------------------
-- Formatting
------------------------------------------------------------------------
local plan = assert(planner.plan({x = 3000, z = 2952}, 11, {landmarks = medieval_profile}))
local function sites_summary(p)
	local sites = {}
	for _, n in ipairs(p.site_order) do
		local s = p.sites[n]
		sites[n] = {rect = s.rect, facing = s.facing, entrance = s.entrance}
	end
	return sites
end
local principal, secondary = 0, 0
for _, s in ipairs(plan.streets) do
	if s.kind == "principal" then principal = principal + 1 else secondary = secondary + 1 end
end
local function make_summary()
	return {
		seed = plan.seed, center = {x = 3000, z = 2952}, ground_y = 104,
		bounds = {min = {x = plan.bounds.x1, y = 100, z = plan.bounds.z1},
			max = {x = plan.bounds.x2, y = 148, z = plan.bounds.z2}},
		plan_bounds = plan.bounds, sites = sites_summary(plan),
		counts = {streets = #plan.streets, principal = principal, secondary = secondary,
			blocks = #plan.blocks, frontage = #plan.frontage},
		nodes = {changed = 12345},
		write_bounds = {min = {x = plan.bounds.x1, y = 97, z = plan.bounds.z1},
			max = {x = plan.bounds.x2, y = 148, z = plan.bounds.z2}},
	}
end
local summary = make_summary()
local lines = generate.format_report(summary)
do -- without write_bounds the modified area falls back to the site bounds
	local s2 = make_summary()
	s2.write_bounds = nil
	eq(has(table.concat(generate.format_report(s2), "\n"), "Urban builder write envelope (" .. plan.bounds.x1 .. ",100,"),
		true, "report: urban write envelope falls back to bounds")
end
do -- ticket #104: liquids, landfill and rejection counts are reported
	local s4 = make_summary()
	s4.liquids = {buried = 7, wet = 3, sealed = 2}
	s4.site = {wet = {count = 12, max_depth = 4}, rejections = {water = 3, too_wet = 1},
		candidates_tried = 5}
	local t4 = table.concat(generate.format_report(s4), "\n")
	eq(has(t4, "Replaced 7 buried liquid/ice nodes; sealed 2 open cells"), true, "report: liquids")
	eq(has(t4, "Landfilled 12 water/ice columns (deepest 4 nodes)"), true, "report: landfill")
	eq(has(t4, "too_wet x1, water x3"), true, "report: rejection counts")
end
do -- ticket #47: the town report carries the bed enumeration
	local s3 = make_summary()
	s3.town = {placed = 2, doors = {},
		beds = {count = 3, skipped = {{category = "inaccessible", reason = "no_standing_space",
			pos = {x = 1, y = 2, z = 3}, id = "townhouses"}}}}
	local t3 = table.concat(generate.format_report(s3), "\n")
	eq(has(t3, "Beds: 3 valid, 1 skipped."), true, "report: bed counts")
	eq(has(t3, "Skipped beds (inaccessible, no_standing_space): 1."), true,
		"report: skipped bed count per reason")
	s3.town.beds, s3.town.beds_error = nil, "boom"
	eq(has(table.concat(generate.format_report(s3), "\n"), "Bed enumeration failed: boom."), true,
		"report: bed enumeration failure")
end
do -- ticket #48: resident line
	local s4 = make_summary()
	s4.town = {placed = 2, doors = {}, residents = {summary = "Residents: 4 spawned, 1 skipped, 0 failed"}}
	eq(has(table.concat(generate.format_report(s4), "\n"), "Residents: 4 spawned, 1 skipped, 0 failed"),
		true, "report: residents line")
	s4.town.residents, s4.town.residents_error = nil, "boom"
	eq(has(table.concat(generate.format_report(s4), "\n"), "Resident initialization failed: boom."),
		true, "report: residents failure")
end
local text = table.concat(lines, "\n")
eq(has(text, "Seed 11"), true, "report: seed")
eq(has(text, "Centre (3000,2952)"), true, "report: centre")
eq(has(text, "ground level y=104"), true, "report: ground level")
eq(has(text, ("Site bounds (%d,100,%d) to (%d,148,%d)"):format(plan.bounds.x1, plan.bounds.z1,
	plan.bounds.x2, plan.bounds.z2)), true, "report: exact bounds")
for _, label in ipairs({"Cathedral:", "Parvis:", "Market:", "Castle:"}) do
	eq(has(text, label), true, "report: " .. label)
end
local cat = plan.sites.cathedral
eq(has(text, ("x %d..%d, z %d..%d"):format(cat.rect.x1, cat.rect.x2, cat.rect.z1, cat.rect.z2)),
	true, "report: cathedral rect")
eq(has(text, ("(%d,105,%d)"):format(cat.entrance.x, cat.entrance.z)), true,
	"report: cathedral entrance")
local cas = plan.sites.castle
eq(has(text, ("gate at (%d,105,%d)"):format(cas.entrance.x, cas.entrance.z)), true,
	"report: castle gate")
eq(has(text, ("Streets %d (%d principal, %d secondary), blocks %d, frontage runs %d."):format(
	#plan.streets, principal, secondary, #plan.blocks, #plan.frontage)), true, "report: counts")
eq(has(text, "12345 nodes changed"), true, "report: nodes")

eq(has(generate.format_search_failure("No suitable town site within 160 nodes."), "Nothing was changed"),
	true, "search failure appends nothing-changed")
local sf = generate.format_search_failure("x. Nothing was changed.")
eq(select(2, sf:gsub("Nothing was changed", "")), 1, "search failure: no duplicate suffix")
local bf = generate.format_build_failure("stale surface", "inspection_failed", {})
eq(has(bf, "inspection_failed") and has(bf, "Nothing was changed"), true, "build failure reported")
bf = generate.format_build_failure("boom", "write_failed", {build_bounds = summary.bounds})
eq(has(bf, "PARTIALLY written"), true, "write_failed: partial")
eq(has(bf, "Nothing was changed"), false, "write_failed: does not claim unchanged")
eq(has(bf, "(" .. plan.bounds.x1 .. ",100,"), true, "write_failed: bounds")
bf = generate.format_build_failure("boom", "write_failed", {build_bounds = summary.bounds},
	{bounds = {min = {x = 1, y = 2, z = 3}, max = {x = 4, y = 5, z = 6}}})
eq(has(bf, "within possible envelope (1,2,3) to (4,5,6)"), true,
	"write_failed: labels the builder's conservative bounds")

------------------------------------------------------------------------
-- Controller with fakes
------------------------------------------------------------------------
local function fakes(opts)
	opts = opts or {}
	local f = {logs = {}, sent = {}, searches = {}, builds = {}, t = 0}
	f.pos = opts.pos ~= nil and opts.pos or {x = 10.4, y = 21, z = -5.6}
	f.deps = {
		get_player_pos = function(name)
			if f.offline then return nil end
			if name == "ghost" then return nil end
			return f.pos
		end,
		search = function(pos, seed, town_type, done)
			f.searches[#f.searches + 1] = {pos = pos, seed = seed, town_type = town_type, done = done}
			if opts.search_raises then error(opts.search_raises) end
			if opts.sync_search then opts.sync_search(done) end
		end,
		build = function(result, done)
			f.builds[#f.builds + 1] = result
			if opts.build_raises then error(opts.build_raises) end
			if opts.build_delay then f.build_done = done; return end
			if opts.build_result then return done(opts.build_result(result)) end
			done(summary)
			if opts.build_raises_after_done then error(opts.build_raises_after_done) end
		end,
		send = function(name, msg) f.sent[#f.sent + 1] = {name, msg} end,
		log = function(level, msg) f.logs[#f.logs + 1] = {level, msg} end,
		entropy = function() return 777 end,
		rng = opts.rng,
		now = function() return f.t end,
	}
	f.c = generate.new(f.deps)
	return f
end

local function sent_text(f)
	local t = {}
	for _, m in ipairs(f.sent) do t[#t + 1] = m[2] end
	return table.concat(t, "\n")
end
local function logs_text(f)
	local t = {}
	for _, m in ipairs(f.logs) do t[#t + 1] = m[2] end
	return table.concat(t, "\n")
end

do
	local f = fakes()
	f.c.run("alice", "1 walls=off")
	f.searches[1].done({})
	eq(f.builds[1].force_walls, false, "wall override reaches the build result")
end

-- A late success from a search replaced as stale must never enter build.
do
	local f = fakes()
	f.c.run("alice", "1")
	f.t = generate.STALE_SECONDS + 1
	f.c.run("bob", "2")
	local built = #f.builds
	f.searches[1].done({build_bounds = summary.bounds}, nil, {})
	eq(#f.builds, built, "stale search success never starts a build")
	eq(f.c.busy(), true, "stale search success keeps the newer search active")
end

-- Search callbacks are also once-only: a late duplicate cannot start another
-- build after the first callback entered the build phase.
do
	local f = fakes({build_delay = true})
	f.c.run("alice", "5")
	local result = {}
	f.searches[1].done(result, nil, {})
	f.searches[1].done(result, nil, {})
	eq(#f.builds, 1, "duplicate search completion starts one build")
	eq(f.c.busy(), true, "duplicate search completion leaves build lock held")
	f.build_done(summary)
end

-- If a builder completes and then raises, the successful callback remains the
-- only reported outcome.
do
	local f = fakes({build_raises_after_done = "late builder error"})
	f.c.run("alice", "5")
	f.searches[1].done({}, nil, {})
	eq(f.c.busy(), false, "raise after callback releases lock")
	eq(has(sent_text(f), "Town built"), true, "raise after callback keeps completion")
	eq(has(sent_text(f), "late builder error"), false, "raise after callback is not reported twice")
end

-- Invalid arguments: no search, no build, no world access of any kind.
for _, bad in ipairs({"abc", "1.5", "1 2", tostring(LIMIT + 1), "9223372036854775807"}) do
	local f = fakes()
	local ok, m = f.c.run("alice", bad)
	eq(ok, false, "invalid '" .. bad .. "' fails")
	eq(type(m) == "string" and m ~= "", true, "invalid '" .. bad .. "' has message")
	eq(#f.searches + #f.builds, 0, "invalid '" .. bad .. "': no search or build")
	eq(f.c.busy(), false, "invalid '" .. bad .. "': not busy")
end

-- Ticket #104: the controller itself passes no search options; the wiring in
-- src/generate_command.lua adds the planner options and WET_DEFAULTS (landfill
-- mode is on for /towns_generate; exercised by place_check --scenario water).
do
	local f = fakes()
	f.c.run("alice", "31337")
	eq(f.searches[1].town_type, "medieval", "controller passes the default town type")
end

-- The build callback owns the lock until its final completion, even after the
-- stale-search timeout. Duplicate completion is ignored.
do
	local f = fakes({build_delay = true})
	f.c.run("alice", "5")
	f.searches[1].done({}, nil, {})
	eq(f.c.busy(), true, "delayed build retains the lock")
	f.t = generate.STALE_SECONDS + 1
	local ok, msg = f.c.run("bob", "6")
	eq(ok, false, "active delayed build cannot be replaced as stale")
	eq(has(msg, "already in progress") and has(msg, "alice"), true,
		"delayed build refusal names its owner")
	eq(#f.searches, 1, "delayed build refusal starts no search")
	f.build_done(summary)
	eq(f.c.busy(), false, "delayed build releases after callback")
	local sent = #f.sent
	f.build_done(nil, "late duplicate", "write_failed")
	eq(#f.sent, sent, "duplicate build completion ignored")
end

-- Offline player.
do
	local f = fakes()
	local ok, m = f.c.run("ghost", "5")
	eq(ok, false, "offline player refused")
	eq(has(m, "in game"), true, "offline message")
	eq(#f.searches, 0, "offline: no search")
end

-- Explicit seed: started message, search receives it and the exact position,
-- then success is reported to the player and logged.
do
	local f = fakes()
	local ok, m = f.c.run("alice", "  31337 ")
	eq(ok, true, "explicit seed starts")
	eq(has(m, "31337"), true, "started message prints the seed")
	eq(has(m, "OVERWRITING"), true, "started message repeats the warning")
	eq(#f.searches, 1, "one search")
	eq(f.searches[1].seed, 31337, "search seed")
	eq(f.searches[1].pos, f.pos, "search gets the player position")
	eq(f.c.busy(), true, "busy while searching")
	eq(#f.builds, 0, "no build before the search finishes")
	-- Search completes later (asynchronously): builds immediately.
	local result = {center = {x = 3000, z = 2952}, ground_y = 104}
	f.searches[1].done(result, nil, {})
	eq(#f.builds, 1, "built once on acceptance")
	eq(f.builds[1], result, "builder receives the accepted result")
	eq(f.c.busy(), false, "released after success")
	local s = sent_text(f)
	eq(has(s, "Town built"), true, "player told of success")
	eq(has(s, "Centre (3000,2952)"), true, "player gets the centre")
	eq(has(logs_text(f), "Town built"), true, "success logged")
	eq(has(logs_text(f), "Cathedral:"), true, "log has landmark coordinates")
	eq(has(logs_text(f), "write bounds"), true, "log has write bounds")
	eq(has(logs_text(f), "Streets"), true, "log has counts")
	eq(f.sent[1][1], "alice", "report addressed to the player by name")
	-- A new run is possible again.
	eq((f.c.run("alice", "1")), true, "can run again after completion")
end

-- Missing seed: generated through the injected RNG, printed, and the same
-- seed reaches the search.
do
	local f = fakes({rng = function(lo, hi) return 2468 end})
	local ok, m = f.c.run("alice", "")
	eq(ok, true, "generated seed starts")
	eq(f.searches[1].seed, 2468, "generated seed used")
	eq(has(m, "2468") and has(m, "generated"), true, "generated seed printed")
	-- Without an injected RNG: valid and clock-derived.
	local g = fakes()
	g.c.run("alice", "")
	eq(valid(g.searches[1].seed), true, "default generated seed valid")
	eq(g.searches[1].seed, generate.random_seed(777), "default seed derives from entropy")
end

-- Concurrency: a second command is refused, even from another player; the
-- first is unaffected and the guard is released on failure too.
do
	local f = fakes()
	f.c.run("alice", "1")
	local ok, m = f.c.run("bob", "2")
	eq(ok, false, "second concurrent run refused")
	eq(has(m, "already in progress") and has(m, "alice"), true, "refusal names the owner")
	eq(#f.searches, 1, "no second search started")
	f.searches[1].done(nil, "No suitable town site within 160 nodes", {})
	eq(f.c.busy(), false, "released after search failure")
	eq((f.c.run("bob", "2")), true, "bob can run after failure")
	eq(#f.searches, 2, "second search ran")
	-- Stale start (done never arrived): replaced after STALE_SECONDS.
	f.t = generate.STALE_SECONDS + 1
	local ok2 = f.c.run("alice", "3")
	eq(ok2, true, "stale search replaced")
	eq(#f.searches, 3, "third search ran")
	eq(has(logs_text(f), "stale"), true, "stale logged")
	-- The abandoned search finishing late must not release the new one.
	f.searches[2].done(nil, "late", {})
	eq(f.c.busy(), true, "late done does not release the newer search")
	eq(has(sent_text(f), "newer /towns_generate replaced this search"), true,
		"late failure reported as replaced")
	-- A duplicate SUCCESS from a completed search is ignored.
	local nb, ns = #f.builds, #f.sent
	f.searches[1].done({build_bounds = summary.bounds}, nil, {})
	eq(#f.builds, nb, "duplicate success from a completed search: builder not called")
	eq(#f.sent, ns, "duplicate success from a completed search is ignored")
	eq(f.c.busy(), true, "late success does not release the newer search")
	f.searches[3].done({build_bounds = summary.bounds}, nil, {})
	eq(#f.builds, nb + 1, "newer search still builds")
	eq(f.c.busy(), false, "newer search releases normally")
end

-- Search failure: reason + nothing changed, builder never called.
do
	local f = fakes()
	f.c.run("alice", "5")
	f.searches[1].done(nil, "No suitable town site within 160 nodes of (1,2): 40 candidates "
		.. "checked; rejected: too_uneven x30. Nothing was changed.", {})
	eq(#f.builds, 0, "search failure: builder not called")
	local s = sent_text(f)
	eq(has(s, "too_uneven"), true, "failure reason reported")
	eq(has(s, "Nothing was changed"), true, "failure says nothing changed")
	eq(has(s, "Error:"), true, "failure is marked as an error")
	eq(f.c.busy(), false, "released")
end

-- Synchronous search failure (standing on non-solid ground): returned as the
-- command result, not chat; no build.
do
	local f = fakes({sync_search = function(done)
		done(nil, "You must be standing on solid ground (found 'air' below you).")
	end})
	local ok, m = f.c.run("alice", "5")
	eq(ok, false, "sync failure not ok")
	eq(has(m, "solid ground"), true, "sync failure reason surfaced")
	eq(has(m, "Nothing was changed"), true, "sync failure says nothing changed")
	eq(#f.sent, 0, "sync failure: no chat duplicate")
	eq(#f.builds, 0, "sync failure: no build")
	eq(f.c.busy(), false, "sync failure releases the guard")
end

-- A fully synchronous search and build callback returns its final report from
-- the command call, preserving the existing command behavior.
do
	local f = fakes({sync_search = function(done) done({}, nil, {}) end})
	local ok, message = f.c.run("alice", "5")
	eq(ok, true, "synchronous search and build succeed")
	eq(has(message, "Town built"), true, "synchronous completion is returned")
	eq(#f.sent, 0, "synchronous completion is not also sent in chat")
	eq(f.c.busy(), false, "synchronous completion releases lock")
end

-- search raising (programmer error) is reported, guard released.
do
	local f = fakes({search_raises = "boom"})
	local ok, m = f.c.run("alice", "5")
	eq(ok, false, "search raise fails")
	eq(has(m, "boom") and has(m, "Nothing was changed"), true, "search raise reported")
	eq(f.c.busy(), false, "search raise releases the guard")
end

-- Builder failures: each code reported; only write_failed is "partial".
for _, code in ipairs({"bad_result", "invalid_plan", "invalid_palette", "inspection_failed"}) do
	local f = fakes({build_result = function() return nil, "reason for " .. code, code end})
	f.c.run("alice", "5")
	f.searches[1].done({build_bounds = summary.bounds}, nil, {})
	local s = sent_text(f)
	eq(has(s, code) and has(s, "reason for " .. code), true, code .. " reported")
	eq(has(s, "Nothing was changed"), true, code .. " says nothing changed")
	eq(has(s, "PARTIALLY"), false, code .. " not partial")
	eq(f.c.busy(), false, code .. " releases")
end
do
	local f = fakes({build_result = function() return nil, "engine said no", "write_failed" end})
	f.c.run("alice", "5")
	f.searches[1].done({build_bounds = summary.bounds}, nil, {})
	local s = sent_text(f)
	eq(has(s, "PARTIALLY written") and has(s, "Site bounds ("), true, "write_failed: honest partial report")
	eq(has(s, "Nothing was changed"), false, "write_failed: no false reassurance")
	eq(has(logs_text(f), "PARTIALLY"), true, "write_failed logged")
	eq(f.c.busy(), false, "write_failed releases")
end
do -- builder raising is treated as a possibly partial write
	local f = fakes({build_raises = "kaboom"})
	f.c.run("alice", "5")
	f.searches[1].done({build_bounds = summary.bounds}, nil, {})
	eq(has(sent_text(f), "PARTIALLY"), true, "builder raise reported as partial")
	eq(has(sent_text(f), "extend a few nodes below"), true, "builder raise: region may extend below")
	eq(has(sent_text(f), "nothing outside it was touched"), false, "builder raise: no false claim")
	eq(f.c.busy(), false, "builder raise releases")
end

-- Player left during the search: the controller still sends by name (the
-- core layer drops it) and logs; nothing raises.
do
	local f = fakes()
	f.c.run("alice", "5")
	f.offline = true
	f.searches[1].done({}, nil, {})
	eq(#f.builds, 1, "build still happens for an offline starter")
	eq(has(logs_text(f), "Town built"), true, "offline starter: result logged")
end

-- write_failed with a result that knows write_bounds, and with builder bounds.
do
	local wb = {min = {x = 1, y = 2, z = 3}, max = {x = 4, y = 5, z = 6}}
	local m = generate.format_build_failure("x", "write_failed", {build_bounds = summary.bounds, write_bounds = wb})
	eq(has(m, "within possible envelope (1,2,3) to (4,5,6)"), true,
		"result.write_bounds preferred and labeled possible")
	m = generate.format_build_failure("x", "write_failed", {build_bounds = summary.bounds})
	eq(has(m, "may extend a few nodes below"), true, "site bounds only: extends below")
end

-- A throwing chat send must not break completion or the guard.
do
	local f = fakes()
	f.deps.send = function() error("chat down") end
	f.c.run("alice", "5")
	local ok = pcall(f.searches[1].done, {}, nil, {})
	eq(ok, true, "throwing send does not raise out of done")
	eq(f.c.busy(), false, "throwing send: guard released")
	eq(#f.builds, 1, "throwing send: town still built")
	eq(has(logs_text(f), "could not send chat"), true, "throwing send logged")
	eq((f.c.run("alice", "6")), true, "can run again after a send failure")
end

------------------------------------------------------------------------
-- Populated town command (ticket #49)
------------------------------------------------------------------------
local function box(id, kind, role, x)
	return {id = id, kind = kind, role = role, rect = {x1 = x, z1 = 0, x2 = x + 5, z2 = 5},
		entrance = {x = x, y = 105, z = -1}}
end
local function populated(extra)
	local s = make_summary()
	s.town = {placed = 6, doors = {1, 2, 3, 4, 5, 6},
		structures = {box("cathedral", "cathedral", "cathedral", 0),
			box("castle", "castle", "castle", 10), box("city_hall", "city_hall", "city_hall", 20),
			box("tavern_a", "service", "tavern", 30), box("home_a", "content", "house", 40),
			box("home_a", "content", "house", 50)},
		beds = {count = 5, skipped = {}},
		residents = {summary = "Residents: 5 spawned, 0 skipped, 0 failed", spawned = 5, failed = 0,
			interrupted = 0},
		shortages = {{role = "well", wanted = 3, placed = 1, reason = "no_candidates"}}}
	for k, v in pairs(extra or {}) do s.town[k] = v end
	return s
end

do -- complete report
	local s = populated()
	eq(#generate.report_problems(s), 0, "populated: no problems")
	local t = table.concat(generate.format_report(s), "\n")
	eq(has(t, "Town built. Seed 11"), true, "populated: success header")
	eq(has(t, "City hall: x 20..25, z 0..5"), true, "populated: city hall")
	eq(has(t, "Buildings: 3 landmarks/city hall/jail, 1 services, 2 houses/shops/workshops."),
		true, "populated: counts")
	eq(has(t, "Catalog ids: castle x1, cathedral x1, city_hall x1, home_a x2, tavern_a x1."),
		true, "populated: catalog ids")
	eq(has(t, "Beds: 5 valid, 0 skipped."), true, "populated: beds")
	eq(has(t, "Residents: 5 spawned"), true, "populated: residents")
	eq(has(t, "Unmet target: well wanted 3, placed 1 (no_candidates)."), true, "populated: unmet")
end

do -- outskirts counts, partial skips, warnings and terraform stats
	local s = populated()
	s.town.urban_placed = s.town.placed
	s.town.urban_structure_count = #s.town.structures
	s.town.structures[#s.town.structures + 1] = box("farm", "object", "farm", 60)
	s.town.structures[#s.town.structures + 1] = box("farm", "object", "farm", 65)
	s.town.structures[#s.town.structures + 1] = box("shepherd_hut", "outskirts", "hut", 70)
	s.town.placed = 9 -- combined count includes the three countryside structures
	s.outskirts = {
		counts = {requested = {farm = 4, hut = 2, villa = 1},
			planned = {farm = 3, hut = 2, villa = 1}, rejected = {plot_water = 2, no_site = 1}},
		structures = {{role = "farm"}, {role = "farm"}, {role = "hut"}},
		skipped = {{plot = "v02", code = "terraform_incomplete", reason = "unloaded blocks: 2"},
			{plot = "f03", code = "terraform_declined", reason = "terrain API declined"}},
		warnings = {{plot = "h02", code = "door_unreachable", reason = "no route"}},
		terraform = {{stats = {changed = 12, cut = 4, filled = 8, steepest = 2,
			steps_over_one = 3, walls = 1, wall_max = 2, unloaded_blocks = 0}},
			{stats = {changed = 5, cut = 1, filled = 4, steepest = 4,
				steps_over_one = 1, walls = 2, wall_max = 5, unloaded_blocks = 0}},
			{code = "terraform_declined"}},
	}
	local t = table.concat(generate.format_report(s), "\n")
	eq(has(t, "Placed 6 buildings; all 6 door approach routes are walkable."), true,
		"outskirts do not inflate urban building count")
	eq(has(t, "Outdoor objects: 0 trees and gardens."), false, "rural farm does not appear as an urban object")
	eq(has(t, "Catalog ids: castle x1"), true, "urban catalog ids remain present")
	eq(has(t, "farm x1"), false, "rural catalog id stays out of urban catalog ids")
	eq(has(t, "Outskirts placed: farms 2/4, huts 1/2, villas 0/1."), true, "outskirts per-kind counts")
	eq(has(t, "Outskirts candidate rejections: no_site x1, plot_water x2."), true, "outskirts candidate rejection counts")
	eq(has(t, "Outskirts skipped v02: terraform_incomplete (unloaded blocks: 2)."), true, "outskirts skip reason")
	eq(has(t, "Outskirts skipped f03: terraform_declined (terrain API declined)."), true, "outskirts decline reason")
	eq(has(t, "Outskirts warning h02: door_unreachable (no route)."), true, "outskirts warning")
	eq(has(t, "Town built but INCOMPLETE"), false, "outskirts omissions do not fail the urban build")
	eq(has(t, "Outskirts terraform: 17 changed columns (5 cut, 12 filled), steepest 4, 4 steps over one, walls 3 (max 5), 0 unloaded blocks."), true,
		"outskirts counters sum and peak stats use Living Villages fields")
	local empty = populated()
	empty.outskirts = {counts = {requested = {farm = 18, hut = 6, villa = 0, chapel = 1},
		planned = {}, rejected = {}}, structures = {}, terraform = {}}
	t = table.concat(generate.format_report(empty), "\n")
	eq(has(t, "Outskirts terraform:"), false, "empty outskirts stats are omitted")
	eq(has(t, "Outskirts placed: farms 0/18, huts 0/6, villas 0/0, chapels 0/1."), true,
		"empty outskirts reports requested counts")
	empty.outskirts.terraform = {{stats = {changed = 0, cut = 0, filled = 0,
		steepest = 0, steps_over_one = 0, walls = 0, wall_max = 0, unloaded_blocks = 0}}}
	t = table.concat(generate.format_report(empty), "\n")
	eq(has(t, "Outskirts terraform: 0 changed columns"), true, "numeric zero stats are reported")
	local full = populated()
	full.outskirts = {counts = {requested = {farm = 1, hut = 1}, planned = {farm = 1, hut = 1}, rejected = {}},
		structures = {{role = "farm"}, {role = "hut"}}, terraform = {}}
	t = table.concat(generate.format_report(full), "\n")
	eq(has(t, "Outskirts placed: farms 1/1, huts 1/1."), true, "full outskirts counts are reported")
end

do -- success through the controller releases the lock
	local f = fakes({build_result = function() return populated() end})
	f.c.run("alice", "5")
	f.searches[1].done({}, nil, {})
	eq(has(sent_text(f), "Catalog ids:"), true, "controller: report sent")
	eq(has(sent_text(f), "Error:"), false, "controller: success not an error")
	eq(f.c.busy(), false, "controller: lock released after success")
end

do -- zero-write planning/preflight failure says nothing changed
	local f = fakes({build_result = function() return nil, "node 'x' not registered", "inspection_failed",
		{reason = "missing_node"} end})
	f.c.run("alice", "5")
	f.searches[1].done({}, nil, {})
	eq(has(sent_text(f), "Nothing was changed"), true, "preflight failure: nothing changed")
	eq(has(sent_text(f), "PARTIALLY"), false, "preflight failure: not partial")
	eq(f.c.busy(), false, "preflight failure: lock released")
end

do -- late-stage partial failure (node setup after schematics) is not "nothing changed"
	local wb = {min = {x = 1, y = 2, z = 3}, max = {x = 4, y = 5, z = 6}}
	local f = fakes({build_result = function() return nil, "node setup failed", "write_failed",
		{bounds = wb, reason = "node_setup_failed", building = {id = "tavern_a"}, placed = 4, total = 9} end})
	f.c.run("alice", "5")
	f.searches[1].done({}, nil, {})
	local s = sent_text(f)
	eq(has(s, "PARTIALLY written"), true, "late failure: partial")
	eq(has(s, "Nothing was changed"), false, "late failure: no false reassurance")
	eq(has(s, "node_setup_failed") and has(s, "tavern_a") and has(s, "4 of 9"), true,
		"late failure: stage, building and progress")
	eq(has(s, "Town built"), false, "late failure: no success claim")
	eq(f.c.busy(), false, "late failure: lock released")
end

do -- resident stage failure after a placed town: written, flagged, not full success
	for _, extra in ipairs({{residents = false, residents_error = "boom"},
			{residents = {summary = "Residents: 3 spawned, 0 skipped, 2 failed", spawned = 3, failed = 2,
				interrupted = 0}},
			{beds = false, beds_error = "nope", residents = false}}) do
		local f = fakes({build_result = function() return populated(extra) end})
		f.c.run("alice", "5")
		f.searches[1].done({}, nil, {})
		local s = sent_text(f)
		eq(has(s, "INCOMPLETE"), true, "resident stage failure: flagged incomplete")
		eq(has(s, "Nothing was changed"), false, "resident stage failure: no false reassurance")
		eq(has(s, "Error:"), true, "resident stage failure: reported as error")
		eq(f.c.busy(), false, "resident stage failure: lock released")
	end
end

do -- builder raising after the search keeps the lock honest
	local f = fakes({build_raises = "kaboom"})
	f.c.run("alice", "5")
	f.searches[1].done({}, nil, {})
	eq(f.c.busy(), false, "raise: lock released")
	eq((f.c.run("bob", "6")), true, "raise: next command allowed")
end

------------------------------------------------------------------------
-- Town type selection (issue #151)
------------------------------------------------------------------------
-- Help and usage name both types.
eq(has(generate.HELP, "roman"), true, "help: roman type")
eq(has(generate.USAGE, "[medieval|roman] [seed]"), true, "usage: type syntax")

-- Invalid type/seed/extra argument combinations never search or build.
for _, bad in ipairs({"castle", "castle 5", "roman abc", "roman 1 2", "roman " .. (LIMIT + 1),
		"medieval roman 1", "roman roman"}) do
	local f = fakes()
	local ok, m = f.c.run("alice", bad)
	eq(ok, false, "type: invalid '" .. bad .. "' fails")
	eq(type(m) == "string" and m ~= "", true, "type: invalid '" .. bad .. "' has message")
	eq(#f.searches + #f.builds, 0, "type: invalid '" .. bad .. "': no search or build")
	eq(f.c.busy(), false, "type: invalid '" .. bad .. "': not busy")
end

-- Roman plan from the real planner, reported through the same summary shape.
local rplan = assert(planner.plan({x = 3000, z = 2952}, 11, {town_type = "roman"}))
local function roman_summary(extra)
	local s = {
		seed = rplan.seed, center = {x = 3000, z = 2952}, ground_y = 104,
		bounds = {min = {x = rplan.bounds.x1, y = 100, z = rplan.bounds.z1},
			max = {x = rplan.bounds.x2, y = 148, z = rplan.bounds.z2}},
		plan_bounds = rplan.bounds, sites = sites_summary(rplan),
		counts = {streets = #rplan.streets, principal = 4, secondary = 0,
			blocks = #rplan.blocks, frontage = #rplan.frontage},
		nodes = {changed = 999}, town_type = "roman",
		town = {placed = 4, doors = {1, 2, 3, 4},
			structures = {box("temple", "temple_east", "temple_east", 0),
				box("domus", "domus_1", "domus_1", 10), box("tavern_a", "service", "tavern", 20),
				box("home_a", "content", "house", 30)},
			beds = {count = 4, skipped = {}},
			setup = {initialized = 2, placements = 3, unhandled = {}},
			residents = {summary = "Residents: 4 spawned, 0 skipped, 0 failed", spawned = 4,
				failed = 0, interrupted = 0}},
	}
	for k, v in pairs(extra or {}) do s.town[k] = v end
	return s
end

do -- report names the Roman sites, no medieval sites, repeat includes the type
	local s = roman_summary()
	eq(#generate.report_problems(s), 0, "roman: no problems")
	local t = table.concat(generate.format_report(s), "\n")
	eq(has(t, "Roman town built. Seed 11 (repeat it with /towns_generate roman 11 from the same place)."),
		true, "roman: header and repeat instruction")
	local forum = rplan.sites.forum.rect
	eq(has(t, ("Forum: x %d..%d, z %d..%d."):format(forum.x1, forum.x2, forum.z1, forum.z2)), true,
		"roman: forum square listed")
	local te = rplan.sites.temple_east
	eq(has(t, ("Temple east: x %d..%d, z %d..%d; entrance at (%d,"):format(te.rect.x1, te.rect.x2,
		te.rect.z1, te.rect.z2, te.entrance.x)), true, "roman: named monument with entrance")
	eq(has(t, "Arch north: "), true, "roman: arch listed")
	eq(has(t, "Amphitheater: "), true, "roman: amphitheater listed")
	eq(has(t, "Domus 1: "), true, "roman: domus listed")
	eq(has(t, "Cathedral:"), false, "roman: no cathedral")
	eq(has(t, "Castle:"), false, "roman: no castle")
	eq(has(t, "Parvis:"), false, "roman: no parvis")
	eq(has(t, "Market:"), false, "roman: no market")
	eq(has(t, "City hall:"), false, "roman: no city hall")
	eq(has(t, "Buildings: 2 landmarks/city hall/jail, 1 services, 1 houses/shops/workshops."),
		true, "roman: landmark counts include monuments")
	eq(has(t, "Node setup: 2 functional nodes initialized"), true, "roman: setup reported")
	eq(has(t, "Residents: 4 spawned"), true, "roman: residents reported")
	local inc = roman_summary({residents = false, residents_error = "boom"})
	eq(has(table.concat(generate.format_report(inc), "\n"),
		"Roman town built but INCOMPLETE (resident initialization failed)"), true,
		"roman: incomplete build flagged")
	local seedless = roman_summary()
	eq(has(table.concat(generate.format_report(seedless, "/towns_generate"), "\n"), "/towns_generate roman 11"),
		true, "roman: repeat with the explicit command")
	local med = make_summary()
	eq(has(table.concat(generate.format_report(med), "\n"), "Town built. Seed 11 (repeat it with /towns_generate 11 from the same place)."),
		true, "medieval: header and repeat unchanged")
end

do -- controller: roman passed to the search; success reaches build and reports
	local f = fakes({build_result = function() return roman_summary() end})
	local ok, m = f.c.run("alice", "roman 11")
	eq(ok, true, "roman: starts")
	eq(f.searches[1].town_type, "roman", "roman: type passed to the search")
	eq(f.searches[1].seed, 11, "roman: seed passed to the search")
	eq(has(m, "Roman town site") and has(m, "11"), true, "roman: started message names the type")
	f.searches[1].done({build_bounds = summary.bounds}, nil, {})
	eq(#f.builds, 1, "roman: shared build hook called once")
	local s = sent_text(f)
	eq(has(s, "Roman town built. Seed 11"), true, "roman: success reported")
	eq(has(s, "Temple east:"), true, "roman: landmarks reported")
	eq(has(s, "Cathedral:"), false, "roman: no fabricated medieval sites")
	eq(has(s, "Error:"), false, "roman: success is not an error")
	eq(f.c.busy(), false, "roman: lock released")
end

do -- controller: omitted Roman seed is generated, printed and repeated with the type
	local f = fakes({rng = function() return 2468 end, build_result = function()
		local r = roman_summary()
		r.seed = 2468
		return r
	end})
	local ok, m = f.c.run("alice", "roman")
	eq(ok, true, "roman without seed starts")
	eq(f.searches[1].town_type, "roman", "roman without seed: type")
	eq(f.searches[1].seed, 2468, "roman without seed: generated seed")
	eq(has(m, "2468") and has(m, "generated"), true, "roman without seed: printed")
	f.searches[1].done({build_bounds = summary.bounds}, nil, {})
	eq(has(sent_text(f), "repeat it with /towns_generate roman 2468"), true,
		"roman without seed: repeat instruction")
end

-- Build failures: the Roman run goes through the same failure formatter as
-- medieval, so for the same failure the chat text is identical and equals
-- format_build_failure's output (the type does not change the wording).
local function build_failure(param, code, msg, extra)
	local f = fakes({build_result = function() return nil, msg, code, extra end})
	f.c.run("alice", param)
	f.searches[1].done({build_bounds = summary.bounds}, nil, {})
	return sent_text(f), f
end
do -- controller: a Roman build that fails before any write says so
	local rom, f = build_failure("roman 5", "inspection_failed", "stale surface", {reason = "stale"})
	local med = build_failure("5", "inspection_failed", "stale surface", {reason = "stale"})
	eq(rom, med, "roman: preflight failure text identical to medieval")
	eq(rom, "Error: " .. generate.format_build_failure("stale surface", "inspection_failed",
		{build_bounds = summary.bounds}, {reason = "stale"}), "roman: preflight failure from the shared formatter")
	eq(has(rom, "Nothing was changed"), true, "roman: preflight failure says nothing changed")
	eq(has(rom, "PARTIALLY"), false, "roman: preflight failure not partial")
	eq(f.c.busy(), false, "roman: preflight failure releases the lock")
end
for _, code in ipairs({"bad_result", "invalid_plan", "invalid_palette", "inspection_failed"}) do
	local rom, f = build_failure("roman 5", code, "reason for " .. code)
	eq(rom, (build_failure("5", code, "reason for " .. code)), "roman: " .. code .. " identical to medieval")
	eq(has(rom, code) and has(rom, "Nothing was changed"), true, "roman: " .. code .. " says nothing changed")
	eq(f.c.busy(), false, "roman: " .. code .. " releases")
end
do -- roman write_failed: honest partial report, same wording as medieval
	local rom, f = build_failure("roman 5", "write_failed", "engine said no")
	local med = build_failure("5", "write_failed", "engine said no")
	eq(rom, med, "roman write_failed: text identical to medieval")
	eq(has(rom, "PARTIALLY written") and has(rom, "Site bounds ("), true, "roman write_failed: partial report")
	eq(has(rom, "Nothing was changed"), false, "roman write_failed: no false reassurance")
	eq(has(logs_text(f), "PARTIALLY"), true, "roman write_failed logged")
	eq(f.c.busy(), false, "roman write_failed releases")
end

do -- one job at a time across types
	local f = fakes()
	f.c.run("alice", "roman 1")
	local ok, m = f.c.run("bob", "medieval 2")
	eq(ok, false, "across types: medieval refused while roman runs")
	eq(has(m, "already in progress") and has(m, "alice"), true, "across types: names the owner")
	ok = f.c.run("bob", "roman")
	eq(ok, false, "across types: roman refused while roman runs")
	eq(#f.searches, 1, "across types: no second search")
	f.searches[1].done(nil, "No suitable town site within 160 nodes", {})
	eq(f.c.busy(), false, "across types: released after roman failure")
	eq((f.c.run("bob", "medieval 2")), true, "across types: medieval runs after roman")
	eq(f.searches[2].town_type, "medieval", "across types: second search is medieval")
	ok = f.c.run("alice", "roman 3")
	eq(ok, false, "across types: roman refused while medieval runs")
	f.searches[2].done(nil, "failed", {})
	eq((f.c.run("alice", "roman 3")), true, "across types: roman runs after medieval")
end

------------------------------------------------------------------------
-- Real search wiring (src/generate_command.lua) for each type. The chunk is
-- loaded with a stub `core` and a stub `towns`; only site_search.search is
-- captured, so no map or engine is needed.
------------------------------------------------------------------------
do
	local captured
	local entries = {marker = true}
	local towns = {
		planner = planner,
		generate = generate,
		catalog = {snapshot = function() return {} end, entries = entries},
		site_search = {
			search = function(pos, seed, opts) captured = {pos = pos, seed = seed, opts = opts} end,
			WET_DEFAULTS = {wet_probe = true},
		},
		residents = {core_store = function() return {} end},
	}
	local stub_core = {get_mod_storage = function() return {} end,
		register_chatcommand = function() end}
	local env = setmetatable({core = stub_core}, {__index = _G})
	local chunk = assert(loadfile("src/generate_command.lua"))
	setfenv(chunk, env)
	chunk(towns)
	towns.populated.search({x = 1, y = 2, z = 3}, 11, "roman", function() end)
	eq(captured.seed, 11, "wiring roman: seed passed")
	eq(captured.opts.planner_opts.town_type, "roman", "wiring roman: planner_opts.town_type")
	eq(captured.opts.entries, entries, "wiring roman: opts.entries is the catalog entries")
	eq(captured.opts.planner_opts.landmarks, nil, "wiring roman: no medieval landmark profile")
	eq(captured.opts.wet_probe, true, "wiring roman: wet defaults merged")
end
