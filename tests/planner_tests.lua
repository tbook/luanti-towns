-- Planner tests (ticket #12): boundary and civic sites. Loaded by
-- tests/run.lua, which passes its check helpers:
--   loadfile("tests/planner_tests.lua")(eq, fails, planner)
local eq, fails, planner = ...

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

local function key(x, z) return (x + 50000) * 100000 + (z + 50000) end

local function cell_set(plan)
	local set, n = {}, 0
	for _, r in ipairs(plan.boundary.rects) do
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do
				local k = key(x, z)
				if not set[k] then set[k] = true; n = n + 1 end
			end
		end
	end
	return set, n
end

local function rect_inside(set, r)
	for z = r.z1, r.z2 do
		for x = r.x1, r.x2 do
			if not set[key(x, z)] then return false end
		end
	end
	return true
end

local function rect_outside(set, r)
	for z = r.z1, r.z2 do
		for x = r.x1, r.x2 do
			if set[key(x, z)] then return false end
		end
	end
	return true
end

-- Chebyshev gap in free nodes (< 0 when overlapping).
local function rgap(a, b)
	return math.max(math.max(a.x1 - b.x2 - 1, b.x1 - a.x2 - 1),
		math.max(a.z1 - b.z2 - 1, b.z1 - a.z2 - 1))
end

local function connected(set, total, plan)
	local r = plan.boundary.rects[1]
	local start = {r.x1, r.z1}
	local seen, stack, n = {[key(start[1], start[2])] = true}, {start}, 0
	while #stack > 0 do
		local c = table.remove(stack)
		n = n + 1
		for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
			local x, z = c[1] + d[1], c[2] + d[2]
			local k = key(x, z)
			if set[k] and not seen[k] then
				seen[k] = true
				stack[#stack + 1] = {x, z}
			end
		end
	end
	return n == total
end

-- Independent feature check: no internal row/column gap below 12, and no
-- left/right/top/bottom extent step below 12.
local function features_ok(plan, set)
	local b = plan.bounds
	local function scan(lo1, hi1, lo2, hi2, at)
		local prevL, prevR
		for a = lo1, hi1 do
			local first, last
			for c = lo2, hi2 do
				if set[at(a, c)] then
					if last and c - last - 1 > 0 and c - last - 1 < 12 then return false end
					first = first or c
					last = c
				end
			end
			if prevL and first ~= prevL and math.abs(first - prevL) < 12 then return false end
			if prevR and last ~= prevR and math.abs(last - prevR) < 12 then return false end
			prevL, prevR = first, last
		end
		return true
	end
	return scan(b.z1, b.z2, b.x1, b.x2, function(z, x) return key(x, z) end)
		and scan(b.x1, b.x2, b.z1, b.z2, function(x, z) return key(x, z) end)
end

local function set_size(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

local OPPOSITE = {["-z"] = "+z", ["+z"] = "-z", ["-x"] = "+x", ["+x"] = "-x"}

local seeds = {}
for i = 1, 30 do seeds[#seeds + 1] = i end
for _, s in ipairs({0, -7, 99999, 2147483647, 2147483648, 4294967296,
		9007199254740991, -9007199254740991}) do
	seeds[#seeds + 1] = s
end
local centers = {{x = 0, z = 0}, {x = 1000, z = -2000}, {x = -317, z = 4096}}

local sig_bounds, sig_layout, cath_sides, castle_sides, castle_gaps = {}, {}, {}, {}, {}
local plans_checked = 0
local expected_plans = 0
for ci, c in ipairs(centers) do
	-- Every seed at the first centre; a subset at the others.
	for si, seed in ipairs(seeds) do
		if ci == 1 or si % 4 == 0 then
		expected_plans = expected_plans + 1
		local label = ("seed %d centre %d"):format(seed, ci)
		local plan, reason = planner.plan(c, seed)
		eq(plan ~= nil, true, label .. " planned (" .. tostring(reason) .. ")")
		if plan then
			plans_checked = plans_checked + 1
			if ci == 1 then
				local again = planner.plan({x = c.x, z = c.z}, seed)
				eq(deep_equal(plan, again), true, label .. " deterministic")
			end
			eq(data_only(plan), true, label .. " data only")
			eq(plan.seed, seed, label .. " seed")
			eq(plan.center.x, c.x, label .. " centre x")
			eq(plan.center.z, c.z, label .. " centre z")
			eq(#plan.streets > 0 and #plan.blocks > 0 and #plan.frontage > 0, true,
				label .. " streets, blocks and frontage filled")

			local set, total = cell_set(plan)
			local b, env = plan.bounds, plan.envelope
			eq(env.x2 - env.x1 + 1, 96, label .. " envelope width")
			eq(env.z2 - env.z1 + 1, 96, label .. " envelope depth")
			eq(env.x1, c.x - 48, label .. " envelope x1")
			eq(b.x1 >= env.x1 and b.x2 <= env.x2 and b.z1 >= env.z1 and b.z2 <= env.z2,
				true, label .. " bounds inside envelope")
			local x1, z1, x2, z2 = math.huge, math.huge, -math.huge, -math.huge
			for _, r in ipairs(plan.boundary.rects) do
				x1, z1 = math.min(x1, r.x1), math.min(z1, r.z1)
				x2, z2 = math.max(x2, r.x2), math.max(z2, r.z2)
			end
			eq(x1 == b.x1 and z1 == b.z1 and x2 == b.x2 and z2 == b.z2, true,
				label .. " exact bounds")
			eq(plan.width, b.x2 - b.x1 + 1, label .. " width")
			eq(plan.depth, b.z2 - b.z1 + 1, label .. " depth")
			eq(math.max(plan.width, plan.depth) >= 80, true, label .. " broad")
			eq(math.min(plan.width, plan.depth) >= 60, true, label .. " not tiny")
			eq(math.abs(plan.width - plan.depth) >= 12, true, label .. " non-square")
			eq(total < plan.width * plan.depth * 0.9, true, label .. " stepped, not a rectangle")
			eq(#plan.boundary.rects >= 2, true, label .. " multiple rects")
			eq(connected(set, total, plan), true, label .. " boundary connected")
			eq(features_ok(plan, set), true, label .. " no small notches or steps")
			eq(set[key(c.x, c.z)] == true, true, label .. " centre inside boundary")

			eq(#plan.site_order, 4, label .. " site count")
			for _, name in ipairs(plan.site_order) do
				local s = plan.sites[name]
				eq(s.name, name, label .. " " .. name .. " name")
				eq(rect_inside(set, s.rect), true, label .. " " .. name .. " contained")
				eq(s.size.x, s.rect.x2 - s.rect.x1 + 1, label .. " " .. name .. " size x")
				eq(s.size.z, s.rect.z2 - s.rect.z1 + 1, label .. " " .. name .. " size z")
				eq(s.facing.x * s.facing.x + s.facing.z * s.facing.z, 1,
					label .. " " .. name .. " facing")
				local e, p = s.approach.edge, s.approach.pos
				eq(e.x1 <= e.x2 and e.z1 <= e.z2, true, label .. " " .. name .. " approach edge")
				eq(p.x >= e.x1 and p.x <= e.x2 and p.z >= e.z1 and p.z <= e.z2,
					true, label .. " " .. name .. " approach pos on edge")
				eq(rgap(e, s.rect), 0, label .. " " .. name .. " approach touches site")
			end
			local cath, parvis, market, castle = plan.sites.cathedral, plan.sites.parvis,
				plan.sites.market, plan.sites.castle

			-- No overlaps; separate sites leave route room.
			local names = plan.site_order
			for i = 1, #names do
				for j = i + 1, #names do
					local g = rgap(plan.sites[names[i]].rect, plan.sites[names[j]].rect)
					if names[i] == "cathedral" and names[j] == "parvis" then
						eq(g, 0, label .. " cathedral/parvis touch")
					else
						eq(g >= 6, true, label .. " " .. names[i] .. "/" .. names[j] .. " gap")
					end
				end
			end

			-- Cathedral/parvis adjacency on the entrance side.
			local cr, pr = cath.rect, parvis.rect
			eq(parvis.facing.x, cath.facing.x, label .. " parvis facing x")
			eq(parvis.facing.z, cath.facing.z, label .. " parvis facing z")
			eq(cath.parvis, "parvis", label .. " cathedral parvis ref")
			if cath.side == "-z" then
				eq(pr.z2, cr.z1 - 1, label .. " parvis -z adjacent")
				eq(cath.entrance.z, cr.z1, label .. " entrance on edge")
			elseif cath.side == "+z" then
				eq(pr.z1, cr.z2 + 1, label .. " parvis +z adjacent")
				eq(cath.entrance.z, cr.z2, label .. " entrance on edge")
			elseif cath.side == "-x" then
				eq(pr.x2, cr.x1 - 1, label .. " parvis -x adjacent")
				eq(cath.entrance.x, cr.x1, label .. " entrance on edge")
			else
				eq(pr.x1, cr.x2 + 1, label .. " parvis +x adjacent")
				eq(cath.entrance.x, cr.x2, label .. " entrance on edge")
			end
			if cath.side == "-z" or cath.side == "+z" then
				eq(pr.x1 <= cr.x1 and pr.x2 >= cr.x2, true, label .. " parvis spans front")
				eq(cath.entrance.x >= pr.x1 and cath.entrance.x <= pr.x2, true,
					label .. " door fronts parvis")
			else
				eq(pr.z1 <= cr.z1 and pr.z2 >= cr.z2, true, label .. " parvis spans front")
				eq(cath.entrance.z >= pr.z1 and cath.entrance.z <= pr.z2, true,
					label .. " door fronts parvis")
			end
			eq(cath.approach.side, cath.side, label .. " cathedral approach side")

			-- Market separate and near the centre.
			local mx = (market.rect.x1 + market.rect.x2) / 2
			local mz = (market.rect.z1 + market.rect.z2) / 2
			eq(math.abs(mx - c.x) <= 13 and math.abs(mz - c.z) <= 13, true,
				label .. " market near centre")

			-- Castle touches (or closely follows) an outer edge.
			local o = castle.outer_side
			eq(castle.edge_gap >= 0 and castle.edge_gap <= 2, true, label .. " castle gap range")
			local function row(d)
				local r = castle.rect
				if o == "-z" then return {x1 = r.x1, z1 = r.z1 - d, x2 = r.x2, z2 = r.z1 - d} end
				if o == "+z" then return {x1 = r.x1, z1 = r.z2 + d, x2 = r.x2, z2 = r.z2 + d} end
				if o == "-x" then return {x1 = r.x1 - d, z1 = r.z1, x2 = r.x1 - d, z2 = r.z2} end
				return {x1 = r.x2 + d, z1 = r.z1, x2 = r.x2 + d, z2 = r.z2}
			end
			for d = 1, castle.edge_gap do
				eq(rect_inside(set, row(d)), true, label .. " castle edge row inside")
			end
			eq(rect_outside(set, row(castle.edge_gap + 1)), true, label .. " castle edge outside")
			eq(castle.side, OPPOSITE[o], label .. " castle faces inward")

			-- Boundary approaches.
			eq(#plan.approaches, 2, label .. " approaches")
			eq(plan.approaches[1].side ~= plan.approaches[2].side, true,
				label .. " distinct approach sides")
			for _, a in ipairs(plan.approaches) do
				eq(rect_inside(set, a.edge), true, label .. " approach on boundary")
				local ex, ez = a.edge.x2 - a.edge.x1 + 1, a.edge.z2 - a.edge.z1 + 1
				eq(math.max(ex, ez), 6, label .. " approach width")
				eq(math.min(ex, ez), 1, label .. " approach depth")
				for _, name in ipairs(names) do
					eq(rgap(a.edge, plan.sites[name].rect) >= 0, true,
						label .. " approach clear of " .. name)
				end
			end

			if ci == 1 then
				sig_bounds[plan.width .. "x" .. plan.depth] = true
				local parts = {}
				for _, r in ipairs(plan.boundary.rects) do
					parts[#parts + 1] = ("%d,%d,%d,%d"):format(r.x1, r.z1, r.x2, r.z2)
				end
				parts[#parts + 1] = cath.rect.x1 .. "," .. cath.rect.z1 .. cath.side
				parts[#parts + 1] = castle.rect.x1 .. "," .. castle.rect.z1 .. castle.outer_side
				sig_layout[table.concat(parts, ";")] = true
				cath_sides[cath.side] = true
				castle_sides[castle.outer_side] = true
				castle_gaps[castle.edge_gap] = true
			end
		end
		end
	end
end

eq(plans_checked, expected_plans, "all fixed seeds planned")
eq(set_size(sig_layout), #seeds, "every seed gives a distinct layout")
eq(set_size(sig_bounds) >= 20, true, "varied bounding boxes")
eq(set_size(cath_sides), 4, "all four cathedral entrance sides occur")
eq(set_size(castle_sides) >= 3, true, "castle on varied edges")
eq(castle_gaps[0], true, "castle touching the edge occurs")

-- The centre translates the layout without changing it.
do
	local a = planner.plan({x = 0, z = 0}, 17)
	local b = planner.plan({x = 250, z = -90}, 17)
	local function norm(p, c)
		local out = {}
		for _, name in ipairs(p.site_order) do
			local r = p.sites[name].rect
			out[#out + 1] = ("%d,%d,%d,%d"):format(r.x1 - c.x, r.z1 - c.z, r.x2 - c.x, r.z2 - c.z)
		end
		return table.concat(out, ";")
	end
	eq(norm(a, {x = 0, z = 0}), norm(b, {x = 250, z = -90}), "same seed, translated centre")
	eq(deep_equal(a, planner.plan({x = 0, z = 0}, 18)), false, "different seed differs")
end

-- Invalid inputs fail clearly.
fails(function() planner.plan({x = 0, z = 0}, nil) end, "seed must be an integer", "nil seed")
fails(function() planner.plan({x = 0, z = 0}, 1.5) end, "seed must be an integer", "fractional seed")
fails(function() planner.plan({x = 0, z = 0}, "7") end, "seed must be an integer", "string seed")
fails(function() planner.plan({x = 0, z = 0}, 0 / 0) end, "seed must be an integer", "NaN seed")
fails(function() planner.plan({x = 0, z = 0}, math.huge) end, "seed must be an integer", "inf seed")
fails(function() planner.plan({x = 0, z = 0}, 2 ^ 60) end, "seed must be an integer", "huge seed")
fails(function() planner.plan(nil, 1) end, "site_center", "nil centre")
fails(function() planner.plan({x = 1}, 1) end, "site_center", "centre missing z")
fails(function() planner.plan({x = 1.5, z = 0}, 1) end, "site_center", "fractional centre")
fails(function() planner.plan({x = 0, z = "3"}, 1) end, "site_center", "string centre coord")
fails(function() planner.plan({x = 40000, z = 0}, 1) end, "site_center", "centre out of world")
fails(function() planner.plan("0,0", 1) end, "site_center", "non-table centre")
fails(function() planner.plan({x = 0, z = 0}, 1, {max_attempts = -1}) end,
	"max_attempts", "bad max_attempts")
fails(function() planner.plan({x = 0, z = 0}, 1, {constants = {NOPE = 1}}) end,
	"unknown constant", "unknown constant")

-- Exhausted retries return nil plus a useful reason.
do
	local plan, reason, detail = planner.plan({x = 0, z = 0}, 5, {max_attempts = 0})
	eq(plan, nil, "zero budget plan")
	eq(type(reason), "string", "zero budget reason is a string")
	eq(reason:find("no valid town plan for seed 5 after 0 attempts", 1, true) ~= nil, true,
		"zero budget message")
	eq(detail.code, "retries_exhausted", "zero budget code")
	eq(detail.attempts, 0, "zero budget attempts")

	-- An impossible constant (castle bigger than the envelope) exhausts a
	-- real budget and names the failing stage.
	local opts = {max_attempts = 6, constants = {CASTLE_X = 200, CASTLE_Z = 200}}
	plan, reason, detail = planner.plan({x = 0, z = 0}, 5, opts)
	eq(plan, nil, "impossible castle plan")
	eq(detail.code, "retries_exhausted", "impossible castle code")
	eq(detail.attempts, 6, "impossible castle attempts")
	local total = 0
	for _, v in pairs(detail.rejections) do total = total + v end
	eq(total, 6, "every attempt accounted for")
	eq((detail.rejections.castle or 0) > 0, true, "castle stage reported")
	eq(reason:find("castle x", 1, true) ~= nil, true, "reason names castle stage")
	eq(reason:find("after 6 attempts", 1, true) ~= nil, true, "reason names budget")
	local _, reason2 = planner.plan({x = 0, z = 0}, 5, opts)
	eq(reason2, reason, "failure is deterministic")
	-- Caller options never leak into later calls.
	eq(planner.plan({x = 0, z = 0}, 5) ~= nil, true, "defaults unaffected by opts")
end

-- ASCII renderer.
do
	local plan = planner.plan({x = 0, z = 0}, 3)
	local text = planner.render(plan)
	eq(text:find("seed 3 center (0,0)", 1, true) ~= nil, true, "render header")
	for _, ch in ipairs({"C", "p", "M", "K", "A", "+", "e", "."}) do
		eq(text:find(ch, 1, true) ~= nil, true, "render has " .. ch)
	end
	local lines = 0
	for _ in text:gmatch("[^\n]+") do lines = lines + 1 end
	eq(lines, plan.depth + 1, "render line count")
	eq(planner.render(plan), text, "render deterministic")
end
