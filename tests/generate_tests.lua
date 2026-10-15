-- /towns_generate tests (ticket #16): argument parsing, seed generation,
-- report formatting and the controller driven by fakes.
-- Loaded by tests/run.lua:
--   loadfile("tests/generate_tests.lua")(eq, fails, planner, generate_factory)
local eq, fails, planner, generate_factory = ...
local generate = generate_factory(planner)
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
local plan = assert(planner.plan({x = 3000, z = 2952}, 11))
local function sites_summary(p)
	local sites = {}
	for _, n in ipairs(p.site_order) do
		local s = p.sites[n]
		sites[n] = {rect = s.rect, side = s.side, entrance = s.entrance}
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
		plan_bounds = plan.bounds, sites = sites_summary(plan), approaches = plan.approaches,
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
	eq(has(table.concat(generate.format_report(s2), "\n"), "Modified area (" .. plan.bounds.x1 .. ",100,"),
		true, "report: modified area falls back to bounds")
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
	s3.town = {placed = 2, alleys = 0, doors = {},
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
	s4.town = {placed = 2, alleys = 0, doors = {}, residents = {summary = "Residents: 4 spawned, 1 skipped, 0 failed"}}
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
eq(has(text, "Boundary approach approach_1"), true, "report: approaches")
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
eq(has(bf, "within (1,2,3) to (4,5,6)"), true, "write_failed: uses the builder's write bounds")

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
		search = function(pos, seed, o, done)
			f.searches[#f.searches + 1] = {pos = pos, seed = seed, opts = o, done = done}
			if opts.search_raises then error(opts.search_raises) end
			if opts.sync_search then opts.sync_search(done) end
		end,
		build = function(result)
			f.builds[#f.builds + 1] = result
			if opts.build_raises then error(opts.build_raises) end
			if opts.build_result then return opts.build_result(result) end
			return summary
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

-- Invalid arguments: no search, no build, no world access of any kind.
for _, bad in ipairs({"abc", "1.5", "1 2", tostring(LIMIT + 1), "9223372036854775807"}) do
	local f = fakes()
	local ok, m = f.c.run("alice", bad)
	eq(ok, false, "invalid '" .. bad .. "' fails")
	eq(type(m) == "string" and m ~= "", true, "invalid '" .. bad .. "' has message")
	eq(#f.searches + #f.builds, 0, "invalid '" .. bad .. "': no search or build")
	eq(f.c.busy(), false, "invalid '" .. bad .. "': not busy")
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
	-- A late SUCCESS from a taken-over search must not build.
	local nb, ns = #f.builds, #f.sent
	f.searches[1].done({build_bounds = summary.bounds}, nil, {})
	eq(#f.builds, nb, "late success from a replaced search: builder not called")
	eq(#f.sent > ns and has(f.sent[#f.sent][2], "nothing was changed"), true,
		"late success reported as nothing changed")
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
	eq(has(m, "within (1,2,3) to (4,5,6)"), true, "result.write_bounds preferred")
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
