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
