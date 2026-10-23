-- Variation tests (issue #184 stage 4): the market quadrant, castle side and
-- 4-way turn of the medieval plan. Loaded by tests/run.lua:
--   loadfile("tests/medieval_variation_tests.lua")(eq, fails, planner, catalog)
local eq, fails, planner, catalog = ...
local authored_plan = dofile("src/authored_plan.lua")
local medieval = dofile("src/medieval_planner.lua")
local A = dofile("tests/medieval_arrangement.lua")

local FULL = os.getenv("TOWNS_TEST_FULL") == "1"
local profile = assert(planner.landmark_profile(catalog.snapshot()))
local ROW = 0
for _, e in pairs(profile.content) do ROW = math.max(ROW, e.size.z) end
local function fixed_rng(seed)
	-- Unforced draws are irrelevant once the variant is forced; this rng is
	-- only here for the market length and the block cuts.
	local n = seed
	return {int = function(a, b) n = (n * 1103515245 + 12345) % 2147483648; return a + n % (b - a + 1) end}
end

-- Every arrangement: 4 quadrants x 2 castle sides x 4 turns, on two seeds.
local keys, count = {}, 0
for quadrant = 0, 3 do
	for _, east in ipairs({false, true}) do
		for turn = 0, 270, 90 do
			for _, seed in ipairs(FULL and {1, 2, 3} or {1, 2}) do
				local label = ("arrangement q%d east=%s turn=%d seed=%d"):format(quadrant, tostring(east), turn, seed)
				local plan, why = medieval.plan({x = 100, z = -40}, seed, profile, fixed_rng(seed),
					{quadrant = quadrant, castle_east = east, turn = turn})
				eq(plan ~= nil, true, label .. " plans: " .. tostring(why))
				if plan then
					count = count + 1
					eq(authored_plan.validate(plan, {min_block_depth = ROW}), true, label .. " validates")
					local problems = A.problems(plan)
					eq(table.concat(problems, "; "), "", label .. " rules")
					keys[A.arrangement(plan)] = true
				end
			end
		end
	end
end
local distinct = 0
for _ in pairs(keys) do distinct = distinct + 1 end
eq(distinct, 32, "32 distinct arrangements")

-- A turn is a rigid rotation about the centre: the same stream of draws gives
-- the turned geometry (sizes, block count, bounds extents).
do
	local c = {x = 7, z = -9}
	local base = assert(medieval.plan(c, 5, profile, fixed_rng(5), {quadrant = 1, castle_east = true, turn = 0}))
	for turn = 90, 270, 90 do
		local t = assert(medieval.plan(c, 5, profile, fixed_rng(5), {quadrant = 1, castle_east = true, turn = turn}))
		local bw, bh = base.bounds.x2 - base.bounds.x1 + 1, base.bounds.z2 - base.bounds.z1 + 1
		local tw, th = t.bounds.x2 - t.bounds.x1 + 1, t.bounds.z2 - t.bounds.z1 + 1
		if turn == 180 then eq(tw == bw and th == bh, true, "turn 180 keeps the extent")
		else eq(tw == bh and th == bw, true, "turn " .. turn .. " swaps the extent") end
		eq(#t.blocks, #base.blocks, "turn " .. turn .. " keeps the block count")
		eq(#t.streets, #base.streets, "turn " .. turn .. " keeps the street count")
		eq(t.sites.castle.rotation, (base.sites.castle.rotation + turn) % 360, "turn " .. turn .. " castle rotation")
		eq(t.sites.cathedral.rotation, turn, "turn " .. turn .. " cathedral rotation")
	end
end

-- Real planner.plan: seeds 1-60 at several centres validate, satisfy every
-- arrangement rule, are deterministic and translate with the centre; all
-- 4 quadrants, both castle sides and all 4 turns occur.
do
	local centers = {{x = 0, z = 0}, {x = 1000, z = -2000}, {x = -317, z = 4096}}
	local quadrants, castles, turns, arrangements = {}, {}, {}, {}
	for seed = 1, 60 do
		for ci, c in ipairs(centers) do
			if ci == 1 or seed % 10 == 0 then
				local label = ("seed %d centre %d"):format(seed, ci)
				local plan, why = planner.plan(c, seed, {landmarks = profile})
				eq(plan ~= nil, true, label .. " plans: " .. tostring(why))
				if plan then
					eq(authored_plan.validate(plan, {min_block_depth = ROW}), true, label .. " validates")
					eq(table.concat(A.problems(plan), "; "), "", label .. " rules")
					if ci == 1 then
						local key = A.arrangement(plan)
						arrangements[key] = true
						local f = plan.sites.cathedral.facing
						turns[f.x .. "," .. f.z] = true
						quadrants[key:match("market=(%S%S)")] = true
						castles[key:match("castle=(.)$")] = true
					end
				end
			end
		end
	end
	local function n(t) local k = 0 for _ in pairs(t) do k = k + 1 end return k end
	eq(n(turns), 4, "all four turns occur in seeds 1-60")
	eq(n(quadrants), 4, "all four market quadrants occur in seeds 1-60")
	eq(n(castles), 2, "both castle sides occur in seeds 1-60")
	eq(n(arrangements) >= 24, true, "seeds 1-60 cover most of the 32 arrangements: " .. n(arrangements))
	local a = assert(planner.plan({x = 5, z = 5}, 33, {landmarks = profile}))
	local b = assert(planner.plan({x = 5, z = 5}, 33, {landmarks = profile}))
	eq(A.arrangement(a), A.arrangement(b), "same seed, same arrangement")
	eq(a.bounds.x1 == b.bounds.x1 and a.bounds.z2 == b.bounds.z2 and #a.blocks == #b.blocks, true,
		"same seed, same plan")
	local c = assert(planner.plan({x = 105, z = -45}, 33, {landmarks = profile}))
	eq(A.arrangement(a), A.arrangement(c), "arrangement does not depend on the centre")
	eq(c.bounds.x1 - a.bounds.x1, 100, "plan translates with the centre (x)")
	eq(c.bounds.z1 - a.bounds.z1, -50, "plan translates with the centre (z)")
end

-- Mutation checks: the arrangement rules catch broken geometry that the
-- generic validator accepts.
do
	local function clone(v)
		if type(v) ~= "table" then return v end
		local o = {}
		for k, x in pairs(v) do o[k] = clone(x) end
		return o
	end
	local base = assert(medieval.plan({x = 0, z = 0}, 4, profile, fixed_rng(4),
		{quadrant = 3, castle_east = true, turn = 90}))
	eq(#A.problems(base), 0, "mutation base is clean")
	local function caught(label, fn, expected)
		local p = clone(base)
		fn(p)
		local found = false
		for _, name in ipairs(A.problems(p)) do if name == expected then found = true end end
		eq(found, true, "rules catch: " .. label .. " (" .. expected .. ")")
	end
	local function shift_rect(r, dx, dz) r.x1, r.x2, r.z1, r.z2 = r.x1 + dx, r.x2 + dx, r.z1 + dz, r.z2 + dz end
	local function shift_site(s, dx, dz)
		shift_rect(s.rect, dx, dz)
		s.entrance.x, s.entrance.z = s.entrance.x + dx, s.entrance.z + dz
		s.approach.pos.x, s.approach.pos.z = s.approach.pos.x + dx, s.approach.pos.z + dz
		if s.gate_span then shift_rect(s.gate_span, dx, dz) end
	end
	local f = base.sites.cathedral.facing
	local lat = {x = -f.z, z = f.x}
	caught("cathedral off the principal's centre line", function(p) shift_site(p.sites.cathedral, lat.x * 2, lat.z * 2) end,
		"cathedral door on the principal's centre line")
	caught("cathedral detached from the core", function(p) shift_site(p.sites.cathedral, -f.x * 2, -f.z * 2) end,
		"cathedral outside the core")
	caught("parvis off the door", function(p) shift_rect(p.sites.parvis.rect, lat.x * 4, lat.z * 4) end,
		"parvis centred on the door")
	local g = base.sites.castle.facing
	local glat = {x = -g.z, z = g.x}
	caught("gate off the principal", function(p) shift_rect(p.sites.castle.gate_span, glat.x, glat.z) end,
		"gate covers the principal")
	caught("castle approach off the principal", function(p) shift_site(p.sites.castle, glat.x * 8, glat.z * 8) end,
		"castle approach on the principal")
	caught("castle gate not on the wall", function(p) shift_rect(p.sites.castle.gate_span, g.x * 3, g.z * 3) end,
		"gate on the castle's wall facing the town")
	caught("market moved off the crossing corner", function(p) shift_rect(p.sites.market.rect, lat.x * 3, lat.z * 3) end,
		"market beside both principals")
end

-- Turned plans keep every block's size field in step with its rect.
for _, turn in ipairs({0, 90, 180, 270}) do
	local plan = assert(medieval.plan({x = 3, z = 4}, 6, profile, fixed_rng(6),
		{quadrant = 2, castle_east = false, turn = turn}))
	local bad = 0
	for _, b in ipairs(plan.blocks) do
		if b.size.x ~= b.rect.x2 - b.rect.x1 + 1 or b.size.z ~= b.rect.z2 - b.rect.z1 + 1 then bad = bad + 1 end
	end
	eq(bad, 0, "turn " .. turn .. " block sizes match their rects")
end

-- Forcing a field never shifts the other draws: the market length and the
-- block cuts equal those of the unforced plan from the same rng stream.
do
	local function dims(r)
		local a, b = r.x2 - r.x1 + 1, r.z2 - r.z1 + 1
		return math.min(a, b) .. "x" .. math.max(a, b)
	end
	local function block_sizes(plan)
		local out = {}
		for _, b in ipairs(plan.blocks) do out[#out + 1] = dims(b.rect) end
		table.sort(out)
		return table.concat(out, ",")
	end
	for seed = 1, 6 do
		local c = {x = 0, z = 0}
		local natural = assert(medieval.plan(c, seed, profile, fixed_rng(seed)))
		local function forced(v) return assert(medieval.plan(c, seed, profile, fixed_rng(seed), v)) end
		local label = "seed " .. seed
		for _, turn in ipairs({0, 90, 180, 270}) do
			local p = forced({turn = turn})
			eq(dims(p.sites.market.rect), dims(natural.sites.market.rect), label .. " turn " .. turn .. " market length")
			eq(block_sizes(p), block_sizes(natural), label .. " turn " .. turn .. " block cuts")
		end
		for _, east in ipairs({false, true}) do
			local p = forced({castle_east = east})
			eq(dims(p.sites.market.rect), dims(natural.sites.market.rect), label .. " castle " .. tostring(east) .. " market length")
			eq(block_sizes(p), block_sizes(natural), label .. " castle " .. tostring(east) .. " block cuts")
		end
		for q = 0, 3 do
			eq(dims(forced({quadrant = q}).sites.market.rect), dims(natural.sites.market.rect),
				label .. " quadrant " .. q .. " market length")
		end
	end
end
