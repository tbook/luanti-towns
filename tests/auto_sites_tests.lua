-- Automatic town sites (issue #394): src/auto_sites.lua. Loaded by tests/run.lua:
--   loadfile("tests/auto_sites_tests.lua")(eq)
-- The main fixture is the #393 measured basis: max_rect +-245, activation_rect +-423
-- (padded by village reach 178), usable 864, jitter 8. The golden descriptors were
-- computed separately with exact integer arithmetic from the rules in the module header.
-- A second fixture runs the real auto_bounds.new output (fake volume providers), so the
-- module is checked against the bounds contract rather than only its constants.
local eq = ...
local sites = dofile("src/auto_sites.lua")
local ab = dofile("src/auto_bounds.lua")
local planner = dofile("src/planner.lua")
local rural = dofile("schematics/outskirts/catalog.lua")
local catalog = dofile("src/catalog.lua")

local CELL = 1024
local ACT = 423

local function measured_env()
	local act = {x1 = -423, z1 = -423, x2 = 423, z2 = 423}
	return {
		activation_rect = act,
		max_rect = {x1 = -245, z1 = -245, x2 = 245, z2 = 245},
		fit = ab.fit(ab.CELL, act, ab.CELL_EDGE_CLEARANCE),
	}
end

local S, why = sites.new(measured_env())
eq(type(S), "table", "measured environment builds a lookup: " .. tostring(why))

local function xz(t, x, z, label)
	eq(t.x, x, label .. ".x")
	eq(t.z, z, label .. ".z")
end

local function rect_eq(r, x1, z1, x2, z2, label)
	eq(r.x1, x1, label .. ".x1")
	eq(r.z1, z1, label .. ".z1")
	eq(r.x2, x2, label .. ".x2")
	eq(r.z2, z2, label .. ".z2")
end

-- The bounds values this ticket relies on (#393 measured fit).
local fit = ab.fit(ab.CELL, {x1 = -423, z1 = -423, x2 = 423, z2 = 423}, ab.CELL_EDGE_CLEARANCE)
eq(fit.usable, 864, "usable span is 1024 - 2 * 80")
eq(fit.jitter, 8, "measured jitter is 8")
eq(sites.CELL, 1024, "cell size is 1,024 nodes")
eq(sites.CLEARANCE, 80, "clearance is one mapchunk")
eq(sites.MAP_LIMIT, 31000, "map limit comes from auto_bounds")

-- Floor division, including negative boundaries.
eq(sites.cell_index(0), 0, "node 0 is cell 0")
eq(sites.cell_index(1023), 0, "last node of cell 0")
eq(sites.cell_index(1024), 1, "first node of cell 1")
eq(sites.cell_index(-1), -1, "node -1 is cell -1 (floor, not truncation)")
eq(sites.cell_index(-1024), -1, "node -1024 is cell -1")
eq(sites.cell_index(-1025), -2, "node -1025 is cell -2")
eq(sites.cell_index(-30720), -30, "cell -30 starts at -30720")
eq(sites.cell_index(31743), 30, "last node of cell 30 is 31743")

-- Golden descriptors (world seed "2014" and the seeds below). Each row:
-- seed, cell x, cell z, centre x, centre z, town type, planner seed.
local GOLDEN = {
	{"2014", 0, 0, 506, 505, "roman", 1037214764},
	{"2014", -1, -1, -518, -519, "roman", 424548544},
	{"2014", 29, -30, 30208, -30212, "roman", 88709492},
	{"2014", -30, 29, -30202, 30205, "medieval", 186427300},
	{"9007199254740993", 0, 0, 518, 518, "medieval", 255118146},
	{"9007199254740992", 0, 0, 512, 514, "roman", 697420346},
	{"12345678901234567890", -3, 5, -2562, 5638, "medieval", 832773064},
	{"12345678901234567891", -3, 5, -2559, 5631, "roman", 618658945},
	{"-9223372036854775808", 7, -7, 7687, -6658, "roman", 39771324},
}
for _, g in ipairs(GOLDEN) do
	local seed, cx, cz, x, z, town, pseed = g[1], g[2], g[3], g[4], g[5], g[6], g[7]
	local label = ("golden %s (%d,%d)"):format(seed, cx, cz)
	local d = S.describe(seed, cx, cz)
	eq(type(d), "table", label .. " accepted")
	if d then
		eq(d.id, ("1:%d:%d:%s:%d:%d:%d"):format(cx, cz, town, pseed, x, z), label .. " id")
		eq(d.version, 1, label .. " version")
		xz(d.cell, cx, cz, label .. " cell")
		xz(d.center, x, z, label .. " centre")
		eq(d.town_type, town, label .. " town type")
		eq(d.seed, pseed, label .. " planner seed")
		rect_eq(d.activation_rect, x - ACT, z - ACT, x + ACT, z + ACT, label .. " activation")
		rect_eq(d.max_rect, x - 245, z - 245, x + 245, z + 245, label .. " max_rect")
	end
end

-- Seeds that differ beyond double precision are not merged: tonumber sees them as equal,
-- but the hash must not.
eq(tonumber("9007199254740993") == tonumber("9007199254740992"), true, "the two big seeds alias as numbers")
local big_a = S.describe("9007199254740993", 0, 0)
local big_b = S.describe("9007199254740992", 0, 0)
eq(big_a.seed ~= big_b.seed, true, "seeds beyond double precision give different planner seeds")
eq(S.describe("12345678901234567890", -3, 5).id ~= S.describe("12345678901234567891", -3, 5).id,
	true, "one-digit change at the end of a 20-digit seed changes the site")

-- Repeatability and evaluation order: the same cells give the same descriptors in any order.
local function ids_for(sites_obj, seed, order)
	local out = {}
	for _, c in ipairs(order) do
		local d = sites_obj.describe(seed, c[1], c[2])
		out[c[1] .. ":" .. c[2]] = d and d.id or "declined"
	end
	return out
end
local window = {}
for cz = -3, 3 do for cx = -3, 3 do window[#window + 1] = {cx, cz} end end
local reversed = {}
for i = #window, 1, -1 do reversed[#reversed + 1] = window[i] end
local shuffled = {}
for i = 1, #window do shuffled[i] = window[((i * 11) % #window) + 1] end -- 11 is coprime to 49: a permutation
local fwd = ids_for(S, "2014", window)
local rev = ids_for(S, "2014", reversed)
local shf = ids_for(sites.new(measured_env()), "2014", shuffled)
local same = true
for _, c in ipairs(window) do
	local k = c[1] .. ":" .. c[2]
	if fwd[k] ~= rev[k] or fwd[k] ~= shf[k] then same = false end
end
eq(same, true, "evaluation order leaves descriptors identical")
eq(S.describe("2014", 0, 0).id, fwd["0:0"], "repeat call matches the first")
eq(S.describe("2014", 0, 0).id ~= S.describe("2015", 0, 0).id, true, "another seed gives another site")

-- Type weights and planner seeds over a fixed sample (the 60 x 60 accepted cells -30..29, seed "2014").
local medieval, roman, planner_ok, jmin, jmax, clear_ok, n = 0, 0, true, math.huge, -math.huge, true, 0
for cz = -30, 29 do
	for cx = -30, 29 do
		local d = S.describe("2014", cx, cz)
		if d then
			n = n + 1
			if d.town_type == "medieval" then medieval = medieval + 1 else roman = roman + 1 end
			if not (d.seed >= 1 and d.seed <= planner.SEED_LIMIT) or planner.check_seed(d.seed) ~= true then
				planner_ok = false
			end
			local ox, oz = cx * CELL, cz * CELL
			jmin = math.min(jmin, d.center.x - ox - 512, d.center.z - oz - 512)
			jmax = math.max(jmax, d.center.x - ox - 512, d.center.z - oz - 512)
			-- Every activation rect stays one mapchunk inside its cell.
			local a = d.activation_rect
			if a.x1 < ox + 80 or a.x2 > ox + CELL - 81 or a.z1 < oz + 80 or a.z2 > oz + CELL - 81 then
				clear_ok = false
			end
		end
	end
end
eq(n, 3600, "all 60 x 60 cells of the sample are accepted")
eq(planner_ok, true, "planner seeds lie in 1 .. planner.SEED_LIMIT")
eq(clear_ok, true, "every activation rect keeps one mapchunk from its cell edges")
eq(jmin, -8, "jitter reaches -8 in the sample")
eq(jmax, 8, "jitter reaches +8 in the sample")
eq(medieval, 1795, "golden medieval count over the sample")
eq(roman, 1805, "golden roman count over the sample")
local frac = medieval / n
eq(frac > 0.45 and frac < 0.55, true, "equal type weights (within sampling noise)")
-- Golden: seed "2014", cells -2..1 on both axes: 10 medieval, 6 roman.
local m4, r4 = 0, 0
for cz = -2, 1 do for cx = -2, 1 do
	if S.describe("2014", cx, cz).town_type == "medieval" then m4 = m4 + 1 else r4 = r4 + 1 end
end end
eq(m4, 10, "golden medieval count in cells -2..1")
eq(r4, 6, "golden roman count in cells -2..1")

-- Map limit and world edges. Cell 29 and -30 are the last accepted cells; 30 and -31 decline.
local d, reason, code = S.describe("2014", 30, 0)
eq(d, nil, "cell 30 declines at the east edge")
eq(code, "map_limit", "east edge declines with map_limit")
eq(type(reason), "string", "declined cell carries a reason")
eq(select(3, S.describe("2014", -31, 0)), "map_limit", "cell -31 declines at the west edge")
eq(type(S.describe("2014", 29, 0)), "table", "cell 29 is accepted at the east edge")
eq(type(S.describe("2014", -30, 0)), "table", "cell -30 is accepted at the west edge")
eq(select(3, S.describe("2014", 0, 30)), "map_limit", "cell 30 along z declines")
eq(select(3, S.describe("2014", 0, -31)), "map_limit", "cell -31 along z declines")

-- Lookup: only overlapping cells, in stable order (cz then cx ascending).
local function cells_of(list)
	local out = {}
	for _, d in ipairs(list) do out[#out + 1] = d.cell.x .. ":" .. d.cell.z end
	return table.concat(out, " ")
end
eq(cells_of(S.lookup("2014", {x1 = 0, z1 = 0, x2 = 10, z2 = 10})), "0:0", "rect inside one cell visits that cell only")
eq(cells_of(S.lookup("2014", {x1 = -1, z1 = -1, x2 = 1, z2 = 1})), "-1:-1 0:-1 -1:0 0:0",
	"rect across the origin visits four cells in stable order")
eq(cells_of(S.lookup("2014", {x1 = 1023, z1 = 0, x2 = 1024, z2 = 0})), "0:0 1:0",
	"rect across a cell boundary visits both cells, not a third")
eq(cells_of(S.lookup("2014", {x1 = -1, z1 = -1, x2 = -1, z2 = -1})), "-1:-1",
	"a single node at -1 belongs to cell -1")
eq(#S.lookup("2014", {x1 = 40000, z1 = 0, x2 = 41000, z2 = 10}), 0, "rect beyond the map limit has no cells")
local whole = S.lookup("2014", {x1 = -40000000, z1 = -40000000, x2 = 40000000, z2 = 40000000})
eq(#whole, 3600, "a huge rect is clamped to the map: cells -30..29 on both axes")
eq(whole[1].cell.x .. ":" .. whole[1].cell.z, "-30:-30", "first cell of the walk is -30,-30")
eq(whole[#whole].cell.x .. ":" .. whole[#whole].cell.z, "29:29", "last cell of the walk is 29,29")

-- Lookup matches a brute-force overlap filter over a window of cells, in the same order.
local function expected_cells(seed, rect)
	local out = {}
	for cz = -40, 40 do
		for cx = -40, 40 do
			local ox, oz = cx * CELL, cz * CELL
			if ox <= rect.x2 and ox + CELL - 1 >= rect.x1 and oz <= rect.z2 and oz + CELL - 1 >= rect.z1 then
				local d = S.describe(seed, cx, cz)
				if d then out[#out + 1] = d end
			end
		end
	end
	return out
end
local RECTS = {
	{x1 = -2000, z1 = -5, x2 = 2100, z2 = 700},
	{x1 = 1023, z1 = 1024, x2 = 1024, z2 = 1025},
	{x1 = -1, z1 = -1, x2 = 0, z2 = 0},
	{x1 = 5000, z1 = -9000, x2 = 5080, z2 = -8990},
	{x1 = -30000, z1 = 20000, x2 = -29990, z2 = 20010},
	{x1 = 100, z1 = 100, x2 = 100, z2 = 100},
}
for _, r in ipairs(RECTS) do
	local got, want = S.lookup("2014", r), expected_cells("2014", r)
	local label = ("lookup %d,%d..%d,%d"):format(r.x1, r.z1, r.x2, r.z2)
	eq(cells_of(got), cells_of(want), label .. " matches the overlap filter in order")
	local ids_ok = #got == #want
	for i = 1, math.min(#got, #want) do ids_ok = ids_ok and got[i].id == want[i].id end
	eq(ids_ok, true, label .. " descriptors are identical")
end
eq(S.lookup("2014", {x1 = 5, z1 = 0, x2 = 4, z2 = 0}), nil, "reversed rect is rejected")

-- Mutation safety: returned descriptors are fresh copies.
local first = S.describe("2014", -1, -1)
local snapshot = {id = first.id, cx = first.cell.x, center = first.center.x,
	max = first.max_rect.x1, act = first.activation_rect.z2, town = first.town_type, seed = first.seed}
first.cell.x = 99
first.center.x = 0
first.max_rect.x1 = 0
first.activation_rect.z2 = 0
first.town_type = "nothing"
first.seed = 1
first.id = "corrupt"
local again = S.describe("2014", -1, -1)
eq(again.id, snapshot.id, "mutation does not change the next describe id")
eq(again.cell.x, snapshot.cx, "mutation does not change the next cell")
eq(again.center.x, snapshot.center, "mutation does not change the next centre")
eq(again.max_rect.x1, snapshot.max, "mutation does not change the next max_rect")
eq(again.activation_rect.z2, snapshot.act, "mutation does not change the next activation_rect")
eq(again.town_type, snapshot.town, "mutation does not change the next town type")
eq(again.seed, snapshot.seed, "mutation does not change the next planner seed")
local a1 = S.describe("2014", 0, 0)
local a2 = S.describe("2014", 0, 0)
eq(rawequal(a1, a2), false, "describe returns a fresh table per call")
eq(rawequal(a1.center, a2.center), false, "centre tables are not shared")
local l1 = S.lookup("2014", {x1 = 0, z1 = 0, x2 = 1, z2 = 1})
l1[1].center.x = 12345
local l2 = S.lookup("2014", {x1 = 0, z1 = 0, x2 = 1, z2 = 1})
eq(l2[1].center.x ~= 12345, true, "a lookup result does not alias the next lookup")

-- Declines: each returns nil, reason, code and never a partial descriptor.
local bad, _, bad_code = S.describe("", 0, 0)
eq(bad, nil, "empty seed declines")
eq(bad_code, "invalid_seed", "empty seed code")
eq(select(3, S.describe(2014, 0, 0)), "invalid_seed", "numeric seed is not accepted (string only)")
eq(select(3, S.describe("2014", 0.5, 0)), "invalid_cell", "fractional cell declines")
eq(select(3, S.describe("2014", 0, nil)), "invalid_cell", "missing cell declines")
eq(select(3, S.lookup("2014", {x1 = 0, z1 = 0, x2 = 1.5, z2 = 1})), "invalid_rect", "fractional rect declines")
eq(select(3, S.lookup("2014", nil)), "invalid_rect", "nil rect declines")
eq(select(3, S.lookup(nil, {x1 = 0, z1 = 0, x2 = 1, z2 = 1})), "invalid_seed", "lookup needs a seed")

local _, env_why, env_code = sites.new(nil)
eq(env_code, "invalid_env", "nil environment declines")
eq(type(env_why), "string", "declined environment carries a reason")
local short = measured_env()
short.fit = ab.fit(ab.CELL, {x1 = -440, z1 = -440, x2 = 440, z2 = 440}, ab.CELL_EDGE_CLEARANCE)
eq(select(3, sites.new(short)), "impossible_cell", "an activation that does not fit declines the configuration")
local off = measured_env()
off.activation_rect = {x1 = -423, z1 = -423, x2 = 423, z2 = 423}
off.fit = {fits = true, jitter = 9}
eq(select(3, sites.new(off)), "impossible_cell", "jitter that pushes the activation into the clearance declines")
local stray = measured_env()
stray.max_rect = {x1 = -500, z1 = -245, x2 = 245, z2 = 245}
eq(select(3, sites.new(stray)), "invalid_env", "max_rect outside the activation rect declines")

-- Draw purposes are separate: the same cell gives unrelated values per purpose.
local same_draw = 0
for cx = -10, 10 do
	if sites.draw("2014", sites.PURPOSE.JITTER_X, cx, 3) == sites.draw("2014", sites.PURPOSE.TYPE, cx, 3) then
		same_draw = same_draw + 1
	end
end
eq(same_draw, 0, "jitter and type draws differ for the same cell")
eq(sites.draw("2014", sites.PURPOSE.PLANNER, 0, 0) < sites.HASH_MODULUS, true, "draws stay in [0, modulus)")

-- Real auto_bounds output (fake volume providers): the module reads its numbers from the
-- environment, so a different measured fit gives a different jitter and still keeps clearance.
local VILLAGE = {
	{name = "belltower", hwidth = 5, hdepth = 5, hheight = 9},
	{name = "large_house", hwidth = 12, hdepth = 12, hheight = 9},
	{name = "blacksmith", hwidth = 8, hdepth = 11, hheight = 13},
	{name = "butcher", hwidth = 12, hdepth = 8, hheight = 10},
	{name = "church", hwidth = 13, hdepth = 13, hheight = 14},
	{name = "farm", hwidth = 9, hdepth = 7, hheight = 13},
	{name = "lamp", hwidth = 3, hdepth = 4, hheight = 13},
	{name = "library", hwidth = 12, hdepth = 12, hheight = 8},
	{name = "medium_house", hwidth = 9, hdepth = 12, hheight = 8},
	{name = "small_house", hwidth = 9, hdepth = 8, hheight = 8},
	{name = "tavern", hwidth = 12, hdepth = 10, hheight = 10},
	{name = "well", hwidth = 6, hdepth = 8, hheight = 6},
}
local outskirts = {}
for _, id in ipairs({"farm", "shepherd_hut", "villa"}) do outskirts[#outskirts + 1] = {id = id, size = rural[id].size} end
outskirts[#outskirts + 1] = {id = "chapel", size = catalog.entries.chapel.size}
local wall_features = {}
for id, e in pairs(catalog.entries) do
	if id:match("^wall_") and e.size then wall_features[#wall_features + 1] = {id = id, size = e.size} end
end
table.sort(wall_features, function(a, b) return a.id < b.id end)
local function fake_terrain(plan, schematics)
	local e, s = plan[1], schematics[1]
	local w, dd = s.hwidth, s.hdepth
	if e.rotat == "90" or e.rotat == "270" then w, dd = dd, w end
	return {minp = {x = e.pos.x - 10, y = -60, z = e.pos.z - 10},
		maxp = {x = e.pos.x + w - 1 + 10, y = 60, z = e.pos.z + dd - 1 + 10}}
end
local function fake_boundary(rects)
	local minx, minz, maxx, maxz = math.huge, math.huge, -math.huge, -math.huge
	for _, r in ipairs(rects) do
		minx, minz = math.min(minx, r.x0), math.min(minz, r.z0)
		maxx, maxz = math.max(maxx, r.x1), math.max(maxz, r.z1)
	end
	return {minp = {x = minx - 48, y = -68, z = minz - 48}, maxp = {x = maxx + 48, y = 68, z = maxz + 48}}
end
local cfg = ab.default_config()
cfg.village = {cell = 16, max_cells = 5, relocate_step = 8, relocate_rings = 4, radius_jitter = 2}
local real_env, real_why = ab.new({config = cfg,
	assets = {outskirts = outskirts, village = VILLAGE, wall_features = wall_features},
	volume = {terrain = fake_terrain, boundary = fake_boundary}})
eq(type(real_env), "table", "auto_bounds environment builds: " .. tostring(real_why))
local R = sites.new(real_env)
eq(type(R), "table", "auto_sites accepts the auto_bounds environment")
local rj = real_env.fit.jitter
local rw = real_env.activation_rect.x2 - real_env.activation_rect.x1 + 1
local real_ok, rmin, rmax = true, math.huge, -math.huge
for cz = -3, 3 do
	for cx = -3, 3 do
		local d = R.describe("2014", cx, cz)
		if d then
			local ox, oz = cx * CELL, cz * CELL
			rmin = math.min(rmin, d.center.x - ox - 512)
			rmax = math.max(rmax, d.center.x - ox - 512)
			local a = d.activation_rect
			if a.x1 < ox + 80 or a.x2 > ox + CELL - 81 or a.z1 < oz + 80 or a.z2 > oz + CELL - 81 then
				real_ok = false
			end
		end
	end
end
eq(rw, 737, "fake-provider activation width (not the measured 847)")
eq(rj, 63, "jitter follows the environment's fit")
eq(rmin >= -rj and rmax <= rj, true, "centre offsets follow the environment's jitter")
eq(real_ok, true, "activation keeps one mapchunk from the cell edges for this environment too")
