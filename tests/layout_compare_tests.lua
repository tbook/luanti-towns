-- Layout comparison tool tests (ticket #109). Loaded by tests/run.lua:
--   loadfile("tests/layout_compare_tests.lua")(eq, fails, planner, catalog)
local eq, fails, planner, catalog = ...

local lib = dofile("tools/layout_compare/lib.lua")

local function same_files(a, b)
	for name, content in pairs(a) do
		if b[name] ~= content then return false, name end
	end
	for name in pairs(b) do
		if a[name] == nil then return false, name end
	end
	return true
end

local opts = {seeds = {42}, centers = {{x = 0, z = 0}}}
local r1 = lib.run(planner, catalog, opts)
local r2 = lib.run(planner, catalog, opts)
local same, which = same_files(r1.files, r2.files)
eq(same, true, "layout compare is deterministic for a fixed seed (" .. tostring(which) .. ")")
eq(r1.files["seed_42.svg"] ~= nil, true, "layout compare emits an SVG")
eq(r1.files["seed_42.txt"] ~= nil, true, "layout compare emits an ASCII plan")
eq(r1.files["metrics.tsv"] ~= nil, true, "layout compare emits metrics.tsv")

local row = r1.rows[1]
eq(row.status, "ok", "seed 42 plans")
eq(row.ordinary, row.houses + row.shops + row.workshops, "ordinary count is the role sum")
eq(row.frontage_usable <= row.frontage_ordinary, true, "usable frontage within theoretical")
eq(row.frontage_square_used > 0, true, "square frontage has placed content")
eq(row.frontage_square_used <= row.frontage_square, true, "square use within theoretical frontage")
eq(row.market_open <= row.market_area, true, "open market within market")

-- The centre only translates the layout: the metrics (not the centre
-- column) are identical at another centre.
local other = lib.run(planner, catalog, {seeds = {42}, centers = {{x = 700, z = -900}}})
local o = other.rows[1]
for _, col in ipairs(lib.COLUMNS) do
	if col ~= "center" then
		eq(o[col], row[col], "centre invariant metric " .. col)
	end
end

-- Command line (issue #152): existing invocations keep their meaning.
local function arg_error(argv, text)
	local ok, err = pcall(lib.parse_args, argv)
	return (not ok) and tostring(err):find(text, 1, true) ~= nil
end
local defaults = lib.parse_args({})
eq(defaults.town_type, "medieval", "default town type is medieval")
eq(defaults.outdir, "docs/layout_baseline", "default outdir unchanged")
local positional = lib.parse_args({"/tmp/x", "1,2"})
eq(positional.outdir .. " " .. positional.seeds[2] .. " " .. positional.town_type,
	"/tmp/x 2 medieval", "positional OUTDIR and seeds parse as before")
local roman_args = lib.parse_args({"/tmp/x", "--town-type=roman"})
eq(roman_args.town_type, "roman", "--town-type=roman selects Roman")
eq(roman_args.seeds, nil, "Roman seeds default to the Roman set")
eq(arg_error({"--town-type=roman"}, "needs an OUTDIR"), true, "Roman needs a scratch OUTDIR")
eq(arg_error({"docs/layout_x", "--town-type=roman"}, "under docs/"), true,
	"Roman output stays out of docs/")
eq(arg_error({"/tmp/x", "--town-type=tower"}, "unknown town type"), true, "unknown town type fails")
eq(arg_error({"/tmp/x", "--bogus"}, "unknown option"), true, "unknown option fails")
local ok_type = pcall(lib.run, planner, catalog, {seeds = {42}, town_type = "tower"})
eq(ok_type, false, "lib.run rejects an unknown town type")

-- Medieval: an explicit medieval town type is the default output.
local explicit = lib.run(planner, catalog, {seeds = {42}, centers = {{x = 0, z = 0}},
	town_type = "medieval"})
eq(same_files(r1.files, explicit.files), true, "explicit medieval equals the default")
eq(r1.files["report.md"]:find("Town type: medieval", 1, true) ~= nil, true,
	"medieval report names its town type")

-- Roman: a populated authored plan (issue #152), seeds 1 and 2.
local roman = lib.run(planner, catalog, {seeds = {1, 2}, centers = {{x = 0, z = 0}},
	town_type = "roman"})
local rr1, rr2 = roman.rows[1], roman.rows[2]
eq(rr1.status .. " " .. rr2.status, "ok ok", "roman seeds 1 and 2 plan")
local rreport = roman.files["report.md"]
eq(rreport:find("Town type: roman", 1, true) ~= nil, true, "roman report names its town type")
eq(rreport:find("forum_size = 30", 1, true) ~= nil, true, "roman report lists layout settings")
eq(rreport:find("Authored layout settings:", 1, true) ~= nil, true, "roman report hashes settings")
eq(rreport:find("Catalog: 29 entries", 1, true) ~= nil, true, "roman report lists catalog identity")
eq(rr1.parvis_area, "n/a", "parvis is not applicable to Roman")
eq(rr1.market_open_share, "n/a", "market is not applicable to Roman")
eq(rreport:find("Not applicable to Roman plans", 1, true) ~= nil, true, "roman report marks n/a")
eq(rr1.ordinary > 0 and rr1.services > 0 and rr1.jail == 1, true, "roman has ordinary, services and jail")
eq(rr1.street_len == rr2.street_len and rr1.blocks == rr2.blocks, true,
	"roman seeds share the civic layout")
eq(roman.files["seed_1.txt"] ~= roman.files["seed_2.txt"], true, "roman seeds vary ordinary rows")

-- Every site of the plan is one labelled instance in the SVG, and the forum
-- square is drawn; medieval-only legend entries are not listed for Roman.
local rplan = assert(planner.plan({x = 0, z = 0}, 1, {town_type = "roman"}))
local svg = roman.files["seed_1.svg"]
local labelled = 0
for _, name in ipairs(rplan.site_order) do
	local needle = ">" .. name .. "</text>"
	local n, from = 0, 1
	while true do
		local s, e = svg:find(needle, from, true)
		if not s then break end
		n, from = n + 1, e + 1
	end
	eq(n, 1, "roman svg labels " .. name .. " once")
	labelled = labelled + n
end
eq(labelled, #rplan.site_order, "every site is labelled")
eq(svg:find(">market square</text>", 1, true) == nil, true, "no market legend for Roman")
local txt = roman.files["seed_1.txt"]
eq(txt:find("  temple_east  landmark  temple  ", 1, true) ~= nil, true,
	"roman ascii lists named instances")
eq(txt:find("  forum  square  -  ", 1, true) ~= nil, true, "roman ascii lists the forum")

-- Roman metrics keep their identity under a shifted centre.
local rmoved = lib.run(planner, catalog, {seeds = {1}, centers = {{x = 700, z = -900}},
	town_type = "roman"})
for _, col in ipairs(lib.COLUMNS) do
	if col ~= "center" then
		eq(rmoved.rows[1][col], rr1[col], "roman centre invariant metric " .. col)
	end
end
