-- Planner tests (ticket #12, reworked for the constructive row-grid planner of
-- issue #184): the cross-shaped medieval layout of src/medieval_planner.lua on
-- the real catalog profile, the seed contract and input checks.
-- Loaded by tests/run.lua, which passes its check helpers:
--   loadfile("tests/planner_tests.lua")(eq, fails, planner)
local eq, fails, planner = ...
local small = dofile("tests/small_town.lua")(planner)
local authored_plan = dofile("src/authored_plan.lua")
local ROW = small.row

local function deep_equal(a, b)
	if type(a) ~= type(b) then return false end
	if type(a) ~= "table" then return a == b end
	for k, v in pairs(a) do
		if not deep_equal(v, b[k]) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end

-- Plain numbers/strings/booleans/tables only; no metatables, no sharing.
local function data_only(v, seen)
	local t = type(v)
	if t == "number" or t == "string" or t == "boolean" then return true end
	if t ~= "table" or getmetatable(v) ~= nil then return false end
	seen = seen or {}
	if seen[v] then return false end
	seen[v] = true
	for k, x in pairs(v) do
		if type(k) ~= "string" and type(k) ~= "number" then return false end
		if not data_only(x, seen) then return false end
	end
	seen[v] = nil
	return true
end

local function set_size(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

local function inside(a, b)
	return a.x1 >= b.x1 and a.z1 >= b.z1 and a.x2 <= b.x2 and a.z2 <= b.z2
end

-- Every rectangle of the plan relative to the centre, in a stable order.
local function signature(plan)
	local c, out = plan.center, {}
	local function add(r)
		out[#out + 1] = ("%d,%d,%d,%d"):format(r.x1 - c.x, r.z1 - c.z, r.x2 - c.x, r.z2 - c.z)
	end
	add(plan.bounds)
	for _, r in ipairs(plan.boundary.rects) do add(r) end
	for _, name in ipairs(plan.site_order) do
		local s = plan.sites[name]
		add(s.rect)
		out[#out + 1] = (s.approach.pos.x - c.x) .. ":" .. (s.approach.pos.z - c.z)
		if s.gate_span then add(s.gate_span) end
	end
	for _, s in ipairs(plan.streets) do add(s.rect) end
	for _, b in ipairs(plan.blocks) do add(b.rect) end
	for _, f in ipairs(plan.frontage) do add(f.rect) end
	return table.concat(out, ";")
end

-- The default run checks a small seed set; TOWNS_TEST_FULL=1 sweeps more.
local FULL = os.getenv("TOWNS_TEST_FULL") == "1"
local seeds = FULL and {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0, -7, 99999, 7919, 123456789,
	536870912, 1073741823, -1073741823} or {1, 2, 3, 0, -1073741823}
local centers = {{x = 0, z = 0}, {x = 1000, z = -2000}, {x = -317, z = 4096}}

local function check_plan(plan, c, seed, label)
	eq(data_only(plan), true, label .. " data only")
	eq(plan.town_type, "medieval", label .. " town type")
	eq(plan.seed, seed, label .. " seed")
	eq(plan.center.x, c.x, label .. " centre x")
	eq(plan.center.z, c.z, label .. " centre z")
	eq(small.validate(plan), true, label .. " validates")

	-- Streets: two cobble principals (6 wide), gravel secondaries (4 wide).
	local principals = {}
	for i, s in ipairs(plan.streets) do
		local w, h = s.rect.x2 - s.rect.x1 + 1, s.rect.z2 - s.rect.z1 + 1
		if s.kind == "principal" then
			principals[#principals + 1] = s
			eq(math.min(w, h), 6, label .. " principal " .. i .. " width")
			eq(s.width, 6, label .. " principal " .. i .. " width field")
			eq(s.material, "mcl_core:cobble", label .. " principal " .. i .. " material")
		else
			eq(math.min(w, h), 4, label .. " secondary " .. i .. " width")
			eq(s.width, 4, label .. " secondary " .. i .. " width field")
			eq(s.material, "mcl_core:gravel", label .. " secondary " .. i .. " material")
		end
	end
	eq(#principals, 2, label .. " two principal streets")
	local ew, ns = principals[1].rect, principals[2].rect
	local core, cath_box, castle_box = plan.boundary.rects[1], plan.boundary.rects[2], plan.boundary.rects[3]
	eq(#plan.boundary.rects, 3, label .. " boundary is the core, cathedral and castle")
	eq(ew.x1 == core.x1 and ew.x2 == core.x2, true, label .. " E-W principal spans the core")
	eq(ns.z1 == core.z1, true, label .. " N-S principal starts at the south edge")
	eq(c.x >= ns.x1 and c.x <= ns.x2 and c.z >= ew.z1 and c.z <= ew.z2, true,
		label .. " centre is the principals' crossing")

	-- The union of the construction footprints is the bounds.
	local b = plan.bounds
	local x1, z1, x2, z2 = math.huge, math.huge, -math.huge, -math.huge
	for _, r in ipairs(plan.boundary.rects) do
		x1, z1 = math.min(x1, r.x1), math.min(z1, r.z1)
		x2, z2 = math.max(x2, r.x2), math.max(z2, r.z2)
	end
	eq(x1 == b.x1 and z1 == b.z1 and x2 == b.x2 and z2 == b.z2, true, label .. " exact bounds")
	eq(plan.width, b.x2 - b.x1 + 1, label .. " width")
	eq(plan.depth, b.z2 - b.z1 + 1, label .. " depth")

	-- Sites.
	local sorted = {}
	for _, n in ipairs(plan.site_order) do sorted[#sorted + 1] = n end
	table.sort(sorted)
	eq(table.concat(sorted, ","), "castle,cathedral,city_hall,market,parvis", label .. " sites")
	local cath, parvis, market, castle, hall = plan.sites.cathedral, plan.sites.parvis,
		plan.sites.market, plan.sites.castle, plan.sites.city_hall
	for _, name in ipairs(plan.site_order) do
		local s = plan.sites[name]
		eq(s.name, name, label .. " " .. name .. " name")
		eq(s.size.x, s.rect.x2 - s.rect.x1 + 1, label .. " " .. name .. " size x")
		eq(s.size.z, s.rect.z2 - s.rect.z1 + 1, label .. " " .. name .. " size z")
	end
	-- Cathedral attached outside the north edge, door on the principal's centre line.
	eq(cath.rect.z1, core.z2 + 1, label .. " cathedral outside the north edge")
	eq(inside(cath.rect, cath_box) and inside(cath_box, cath.rect), true, label .. " cathedral footprint")
	eq(inside(castle.rect, castle_box) and inside(castle_box, castle.rect), true, label .. " castle footprint")
	eq(cath.facing.x == 0 and cath.facing.z == -1, true, label .. " cathedral faces south")
	eq(cath.entrance.x, ns.x1 + 3, label .. " cathedral door on the principal's centre line")
	eq(cath.parvis, "parvis", label .. " cathedral parvis ref")
	eq(parvis.rect.z2, core.z2, label .. " parvis in the north edge row")
	eq(parvis.rect.x2 - parvis.rect.x1 + 1, 12, label .. " parvis width")
	eq(parvis.rect.z2 - parvis.rect.z1 + 1, 8, label .. " parvis depth")
	eq(parvis.rect.x1 + 6, cath.entrance.x, label .. " parvis centred on the door")
	eq(ns.z2, parvis.rect.z1 - 1, label .. " principal ends in the parvis")
	eq(cath.approach.pos.x == cath.entrance.x and cath.approach.pos.z == parvis.rect.z2, true,
		label .. " cathedral approach on the parvis")
	-- Castle attached outside the west edge; its six-node gate is the principal's width.
	eq(castle.rect.x2, core.x1 - 1, label .. " castle outside the west edge")
	eq(castle.facing.x == 1 and castle.facing.z == 0, true, label .. " castle faces east")
	local g = castle.gate_span
	eq(g.x1 == core.x1 - 1 and g.x2 == core.x1 - 1, true, label .. " gate on the castle's east wall")
	eq(g.z1 == ew.z1 and g.z2 == ew.z2, true, label .. " gate covers the E-W principal")
	eq(castle.approach.pos.x, core.x1, label .. " castle approach on the principal")
	eq(castle.approach.pos.z >= ew.z1 and castle.approach.pos.z <= ew.z2, true,
		label .. " castle approach on the principal row")
	-- Market at the principals' corner, city hall across it.
	eq(market.rect.x1, ns.x2 + 1, label .. " market beside the N-S principal")
	eq(market.rect.z1, ew.z2 + 1, label .. " market beside the E-W principal")
	eq(market.rect.z2 - market.rect.z1 + 1, 2 * ROW, label .. " market is the full row depth")
	local mlen = market.rect.x2 - market.rect.x1 + 1
	eq(mlen >= 20 and mlen <= 28, true, label .. " market length")
	eq(hall.square, "market", label .. " city hall square")
	eq(hall.rect.x1, market.rect.x2 + 1, label .. " city hall on the market's far edge")
	eq(hall.facing.x == -1 and hall.facing.z == 0, true, label .. " city hall faces the market")
	eq(hall.approach.pos.x, market.rect.x2, label .. " city hall approach on the market")

	-- Every block is at least a row deep both ways, and every block has frontage.
	for i, bl in ipairs(plan.blocks) do
		eq(bl.size.x >= ROW and bl.size.z >= ROW, true, label .. " block " .. i .. " holds a row")
		eq(#bl.frontage > 0, true, label .. " block " .. i .. " has frontage")
	end
	-- Population: nothing short, a jail and the services, many ordinary buildings.
	eq(#plan.shortages, 0, label .. " no shortages")
	eq(plan.reservations.jail ~= nil, true, label .. " jail reserved")
	eq(#plan.reservations.services > 0, true, label .. " services reserved")
	eq(#plan.content.buildings >= 50, true, label .. " ordinary buildings: " .. #plan.content.buildings)
end

local sigs = {}
local plans_checked, expected_plans = 0, 0
for ci, c in ipairs(centers) do
	for si, seed in ipairs(seeds) do
		if ci == 1 or si % 2 == 0 then
			expected_plans = expected_plans + 1
			local label = ("seed %d centre %d"):format(seed, ci)
			local plan, reason = small.plan(c, seed)
			eq(plan ~= nil, true, label .. " planned (" .. tostring(reason) .. ")")
			if plan then
				plans_checked = plans_checked + 1
				check_plan(plan, c, seed, label)
				if ci == 1 then sigs[signature(plan)] = true end
				if ci == 1 and si == 1 then
					eq(deep_equal(plan, small.plan({x = c.x, z = c.z}, seed)), true, label .. " deterministic")
				end
				-- Only the centre moves the layout.
				eq(signature(plan), signature(assert(small.plan({x = 12, z = -34}, seed))),
					label .. " translated centre")
			end
		end
	end
end
eq(plans_checked, expected_plans, "all fixed seeds planned")
eq(set_size(sigs), #seeds, "every seed gives a distinct layout")

-- Landmarks the profile leaves out are simply not planned.
do
	local lm = small.profile
	local plan, why = planner.plan({x = 0, z = 0}, 3, {landmarks = {cathedral = lm.cathedral, castle = lm.castle}})
	eq(plan ~= nil, true, "bare profile plans: " .. tostring(why))
	if plan then
		eq(plan.sites.city_hall, nil, "no city hall without a profile entry")
		eq(authored_plan.validate(plan), true, "bare profile validates")
	end
end

-- A catalog id the catalog does not have fails with a reason, not an error.
do
	local lm = small.profile
	local bogus = {}
	for k, v in pairs(lm) do bogus[k] = v end
	bogus.cathedral = {id = "no_such_cathedral", size = lm.cathedral.size, entrance = lm.cathedral.entrance}
	local plan, why, detail = planner.plan({x = 0, z = 0}, 1, {landmarks = bogus})
	eq(plan, nil, "unknown catalog id gives no plan")
	eq(tostring(why):find("no_such_cathedral", 1, true) ~= nil, true, "unknown id reason: " .. tostring(why))
	eq(detail.code, "invalid_layout", "unknown id code")
end

-- A deeper ordinary building widens the rows; every seed still plans.
do
	for _, depth in ipairs({25, 30, 40}) do
		local lm = small.profile
		local content = {}
		local replaced
		for id, e in pairs(lm.content) do
			content[id] = e
			replaced = replaced or id
		end
		local e = lm.content[replaced]
		content[replaced] = {id = e.id, role = e.role, entrance = e.entrance, ground_offset = e.ground_offset,
			size = {x = e.size.x, y = e.size.y, z = depth}}
		local deep = {}
		for k, v in pairs(lm) do deep[k] = v end
		deep.content = content
		local failed = 0
		for seed = 1, 20 do
			local plan = planner.plan({x = 0, z = 0}, seed, {landmarks = deep})
			if not plan then failed = failed + 1 end
		end
		eq(failed, 0, "content depth " .. depth .. " plans on seeds 1-20")
	end
end

-- The medieval planner validates its own output (authored_plan.validate):
-- a layout whose blocks are shallower than a row passes derive_frontage but is
-- rejected only by the validator.
do
	local medieval = dofile("src/medieval_planner.lua")
	local rng = {int = function(a) return a end}
	local plan, why = medieval.plan({x = 0, z = 0}, 1, small.profile, rng)
	eq(plan ~= nil, true, "stub rng plans: " .. tostring(why))
	local span = medieval.SPAN
	medieval.SPAN = 10
	plan, why = medieval.plan({x = 0, z = 0}, 1, small.profile, rng)
	medieval.SPAN = span
	eq(plan, nil, "narrow rows are rejected")
	eq(tostring(why):find("shallower than the row depth", 1, true) ~= nil, true,
		"validator reason surfaces: " .. tostring(why))
end

-- Invalid inputs fail clearly.
fails(function() planner.plan({x = 0, z = 0}, nil) end, "seed must be an integer", "nil seed")
fails(function() planner.plan({x = 0, z = 0}, 1.5) end, "seed must be an integer", "fractional seed")
fails(function() planner.plan({x = 0, z = 0}, "7") end, "seed must be an integer", "string seed")
fails(function() planner.plan({x = 0, z = 0}, 0 / 0) end, "seed must be an integer", "NaN seed")
fails(function() planner.plan({x = 0, z = 0}, math.huge) end, "seed must be an integer", "inf seed")
fails(function() planner.plan({x = 0, z = 0}, 2 ^ 60) end, "seed must be an integer", "huge seed")
fails(function() planner.plan({x = 0, z = 0}, 2147483647) end, "seed must be an integer", "seed past 2^30")
fails(function() planner.plan({x = 0, z = 0}, -1073741824) end, "seed must be an integer", "seed past -2^30")
fails(function() planner.plan(nil, 1) end, "site_center", "nil centre")
fails(function() planner.plan({x = 1}, 1) end, "site_center", "centre missing z")
fails(function() planner.plan({x = 1.5, z = 0}, 1) end, "site_center", "fractional centre")
fails(function() planner.plan({x = 0, z = "3"}, 1) end, "site_center", "string centre coord")
fails(function() planner.plan({x = 40000, z = 0}, 1) end, "site_center", "centre out of world")
fails(function() planner.plan("0,0", 1) end, "site_center", "non-table centre")
fails(function() small.plan({x = 0, z = 0}, 1, {constants = {NOPE = 1}}) end,
	"unknown constant", "unknown constant")
-- Medieval planning needs the catalog-derived landmark profile.
fails(function() planner.plan({x = 0, z = 0}, 1) end, "opts.landmarks", "no opts")
fails(function() planner.plan({x = 0, z = 0}, 1, {}) end, "opts.landmarks", "no landmark profile")
fails(function() planner.plan({x = 0, z = 0}, 1, {town_type = "medieval"}) end, "opts.landmarks",
	"medieval needs a profile")
fails(function() planner.plan({x = 0, z = 0}, 1, "x") end, "opts must be a table", "non-table opts")

-- Seeds that used to alias (7919 vs 2147483647) and the range extremes give
-- pairwise distinct layouts.
do
	local list = FULL and {7919, 0, 1, -1, 7920, 1073741823, -1073741823, 1073741823 - 7919,
		536870911, -536870911} or {7919, 7920, 1073741823, 1073741823 - 7919}
	local sigs, n = {}, 0
	for _, seed in ipairs(list) do
		local plan = small.plan({x = 0, z = 0}, seed)
		eq(plan ~= nil, true, "alias seed " .. seed .. " planned")
		if plan then
			sigs[signature(plan)] = true
			n = n + 1
		end
	end
	eq(set_size(sigs), n, "aliasing-prone seeds give distinct layouts")
end

local legacy_constants = {
	ENVELOPE = 96, MIN_LONG_SPAN = 80, MIN_SHORT_SPAN = 60,
	CENTER_JITTER = 8, MAX_SECONDARY = 8, MAX_BLOCK_SCAN = 64,
}
local function legacy_validate(plan, constants)
	local c = {}
	for k, v in pairs(legacy_constants) do c[k] = v end
	for k, v in pairs(constants or {}) do c[k] = v end
	return planner.validate(plan, c)
end

-- Validator rejects bad plans. Hand-built plan in a 96-node envelope at the
-- origin (centre 48,48): 60x40 boundary, cathedral wall on the right with
-- `wall_top` as its far Z edge, castle on the -Z edge, market near centre.
do
	local K = {MIN_LONG_SPAN = 50, MIN_SHORT_SPAN = 40, MAX_FILL = 1.0}
	local function R(x1, z1, x2, z2) return {x1 = x1, z1 = z1, x2 = x2, z2 = z2} end
	local function site(name, kind, r, side, extra)
		local e
		if side == "-z" then e = R(r.x1, r.z1 - 1, r.x2, r.z1 - 1)
		elseif side == "+z" then e = R(r.x1, r.z2 + 1, r.x2, r.z2 + 1)
		elseif side == "-x" then e = R(r.x1 - 1, r.z1, r.x1 - 1, r.z2)
		else e = R(r.x2 + 1, r.z1, r.x2 + 1, r.z2) end
		local s = {name = name, kind = kind, rect = r, side = side,
			size = {x = r.x2 - r.x1 + 1, z = r.z2 - r.z1 + 1},
			approach = {side = side, edge = e,
				pos = {x = e.x1 + math.floor((e.x2 - e.x1) / 2),
					z = e.z1 + math.floor((e.z2 - e.z1) / 2)}}}
		local F = {["-z"] = {0, -1, 0}, ["+z"] = {0, 1, 180}, ["-x"] = {-1, 0, 90}, ["+x"] = {1, 0, 270}}
		s.facing = {x = F[side][1], z = F[side][2]}
		s.rotation = F[side][3]
		if kind == "landmark" then
			local ent = {x = s.approach.pos.x, z = s.approach.pos.z}
			if side == "-z" then ent.z = r.z1 elseif side == "+z" then ent.z = r.z2
			elseif side == "-x" then ent.x = r.x1 else ent.x = r.x2 end
			s.entrance = ent
			s.door = {recess = 0, rise = 0, outside = {x = ent.x + s.facing.x, z = ent.z + s.facing.z}}
		end
		for k, v in pairs(extra or {}) do s[k] = v end
		return s
	end
	local function build(wall_top)
		local cath = R(60, 28, 66, wall_top)
		-- The parvis is PARVIS_WIDTH x PARVIS_FRONT_DEPTH, centred on the door.
		local lat = 28 + math.floor((wall_top - 28) / 2)
		local PW, PD = planner.CONSTANTS.PARVIS_WIDTH, planner.CONSTANTS.PARVIS_FRONT_DEPTH
		local plan = {
			seed = 1, center = {x = 48, z = 48}, envelope = R(0, 0, 95, 95),
			bounds = R(20, 28, 79, 67), width = 60, depth = 40,
			boundary = {rects = {R(20, 28, 79, 67)}},
			site_order = {"cathedral", "parvis", "market", "castle"},
			sites = {
				cathedral = site("cathedral", "landmark", cath, "+x", {parvis = "parvis"}),
				parvis = site("parvis", "square",
					R(67, lat - math.floor(PW / 2), 66 + PD, lat - math.floor(PW / 2) + PW - 1), "+x"),
				market = site("market", "square", R(36, 42, 46, 52), "+x"),
				castle = site("castle", "landmark", R(22, 28, 40, 35), "+z",
					{outer_side = "-z", edge_gap = 0}),
			},
			approaches = {
				{name = "approach_1", side = "-x", edge = R(20, 44, 20, 43 + planner.CONSTANTS.STREET_WIDTH), pos = {x = 20, z = 46}},
				{name = "approach_2", side = "+x", edge = R(79, 44, 79, 43 + planner.CONSTANTS.STREET_WIDTH), pos = {x = 79, z = 46}},
			},
			streets = {}, blocks = {}, frontage = {},
		}
		return plan
	end
	local ok, why = legacy_validate(build(55), K)
	-- Site/boundary/route checks pass; a plan with no streets is rejected.
	eq(ok, nil, "hand-built plan without streets rejected")
	eq(tostring(why):find("no streets", 1, true) ~= nil, true,
		"no-streets reason: " .. tostring(why))

	ok, why = legacy_validate(build(67), K)
	eq(ok, nil, "wall closes the route")
	eq(tostring(why):find("not connected by a street-wide route", 1, true) ~= nil, true,
		"blocked route reason: " .. tostring(why))

	-- Overlapping sites.
	local p = build(55)
	p.sites.market = site("market", "square", R(50, 40, 62, 50), "+x")
	ok, why = legacy_validate(p, K)
	eq(ok, nil, "overlapping sites rejected")
	eq(tostring(why):find("overlap", 1, true) ~= nil, true, "overlap reason: " .. tostring(why))

	-- Site outside the boundary.
	p = build(55)
	p.sites.castle = site("castle", "landmark", R(22, 20, 40, 27), "+z", {outer_side = "-z", edge_gap = 0})
	ok, why = legacy_validate(p, K)
	eq(ok, nil, "site outside boundary rejected")
	eq(tostring(why):find("not contained", 1, true) ~= nil, true, "containment reason: " .. tostring(why))

	-- Castle door blocked: moved far from the edge with no door room.
	p = build(55)
	p.approaches[2].edge = R(79, 44, 79, 49)
	p.approaches[1].edge = R(79, 40, 79, 45)
	p.approaches[1].side = "+x"
	ok, why = legacy_validate(p, K)
	eq(ok, nil, "same-side approaches rejected")

	-- Cut boundary: disconnected.
	p = build(55)
	p.boundary.rects = {R(20, 28, 40, 67), R(60, 28, 79, 67)}
	ok, why = legacy_validate(p, K)
	eq(ok, nil, "disconnected boundary rejected")

	-- Garbage in; no internal file:line text leaks.
	ok, why = legacy_validate({seed = 1, center = {x = 0, z = 0}, envelope = {x1 = -48, z1 = -48, x2 = 47, z2 = 47}})
	eq(ok, nil, "malformed plan rejected")
	eq(planner.validate({}), nil, "empty plan rejected")
	eq(planner.validate("x"), nil, "non-table plan rejected")
	eq(tostring(why):find("malformed", 1, true) ~= nil, true, "malformed reason")
	eq(tostring(why):find("planner.lua", 1, true) == nil, true, "no source location in reason: " .. tostring(why))
end

-- Schema fields consumers read are validated (mutations of a real plan).
do
	local function copy(v)
		if type(v) ~= "table" then return v end
		local o = {}
		for k, x in pairs(v) do o[k] = copy(x) end
		return o
	end
	local base = small.plan({x = 10, z = -20}, 31)
	eq(small.validate(base), true, "mutation base validates")
	local function bad(label, fn)
		local p = copy(base)
		fn(p)
		local ok, why = small.validate(p)
		eq(ok, nil, "validate rejects: " .. label)
		eq(type(why), "string", "validate gives reason: " .. label)
	end
	bad("castle entrance (0,0)", function(p) p.sites.castle.entrance = {x = 0, z = 0} end)
	bad("cathedral entrance moved", function(p) p.sites.cathedral.entrance.x = p.sites.cathedral.entrance.x + 1 end)
	bad("cathedral approach moved", function(p) p.sites.cathedral.approach.pos.x = p.sites.cathedral.approach.pos.x + 1 end)
	bad("castle rotation", function(p) p.sites.castle.rotation = (p.sites.castle.rotation + 90) % 360 end)
	bad("kind", function(p) p.sites.market.kind = "landmark" end)
	bad("market without material", function(p) p.sites.market.material = nil end)
	bad("boundary shifted", function(p)
		for _, r in ipairs(p.boundary.rects) do r.x1, r.x2 = r.x1 + 1, r.x2 + 1 end
	end)
	bad("bounds shrunk", function(p) p.bounds.x1 = p.bounds.x1 + 1 end)
	bad("street off the boundary", function(p) p.streets[1].rect.x1 = p.streets[1].rect.x1 - 1 end)
	bad("frontage wrong material", function(p) p.frontage[1].material = "mcl_core:stone" end)
end

-- Seed contract and the LCG fixed point (seed 70894448 used to lock up).
eq(planner.SEED_LIMIT, 1073741823, "SEED_LIMIT export")
eq(planner.check_seed(0), true, "check_seed ok")
eq(planner.check_seed(planner.SEED_LIMIT), true, "check_seed limit ok")
eq(planner.check_seed(-planner.SEED_LIMIT), true, "check_seed -limit ok")
do
	local ok, msg = planner.check_seed(planner.SEED_LIMIT + 1)
	eq(ok, nil, "check_seed past limit")
	eq(msg:find("between -1073741823 and 1073741823", 1, true) ~= nil, true, "check_seed message")
	eq(planner.check_seed("1"), nil, "check_seed string")
	eq(planner.check_seed(0.5), nil, "check_seed fractional")
	eq(planner.check_seed(nil), nil, "check_seed nil")
end
do
	local sigs = {}
	for _, c in ipairs({{x = 0, z = 0}, {x = -800, z = 1234}}) do
		for _, seed in ipairs(FULL and {70894448, 70894447, 70894449} or {70894448}) do
			local plan, why = small.plan(c, seed)
			eq(plan ~= nil, true, "fixed-point seed " .. seed .. " planned: " .. tostring(why))
			if plan then
				eq(small.validate(plan), true, "fixed-point seed " .. seed .. " validates")
				if c.x == 0 then sigs[signature(plan)] = true end
			end
		end
	end
	if FULL then eq(set_size(sigs), 3, "fixed-point seed layout distinct from its neighbours") end
end
