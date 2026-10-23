-- Street, block and frontage tests (ticket #13, reworked for the row-grid
-- planner of issue #184), on the real-catalog town of tests/small_town.lua.
-- Loaded by tests/run.lua:
--   loadfile("tests/streets_tests.lua")(eq, fails, planner)
-- Every check below rebuilds its own occupancy from the plan's data; nothing
-- reuses the planner's or the validator's structures.
local eq, fails, planner = ...
local small = dofile("tests/small_town.lua")(planner)
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

local function key(x, z) return (x + 50000) * 100000 + (z + 50000) end

local function rect_cells(r, fn)
	for z = r.z1, r.z2 do
		for x = r.x1, r.x2 do fn(x, z) end
	end
end

local function set_of(rects)
	local s = {}
	for _, r in ipairs(rects) do
		rect_cells(r, function(x, z) s[key(x, z)] = true end)
	end
	return s
end

local function flood(occ, sx, sz)
	local seen = {}
	if not occ[key(sx, sz)] then return seen end
	local stack = {{sx, sz}}
	seen[key(sx, sz)] = true
	while #stack > 0 do
		local c = table.remove(stack)
		for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
			local x, z = c[1] + d[1], c[2] + d[2]
			local k = key(x, z)
			if occ[k] and not seen[k] then
				seen[k] = true
				stack[#stack + 1] = {x, z}
			end
		end
	end
	return seen
end

local function touches(seen, r)
	local hit = false
	rect_cells(r, function(x, z) if seen[key(x, z)] then hit = true end end)
	return hit
end

local FACING = {["-z"] = {0, -1}, ["+z"] = {0, 1}, ["-x"] = {-1, 0}, ["+x"] = {1, 0}}

-- The default run uses a small seed set; TOWNS_TEST_FULL=1 runs the wider
-- seed list and a longer fuzz.
local FULL = os.getenv("TOWNS_TEST_FULL") == "1"
local seeds = {}
if FULL then
	for i = 1, 12 do seeds[#seeds + 1] = i end
	for _, s in ipairs({0, -7, 1073741823}) do seeds[#seeds + 1] = s end
else
	seeds = {1, 2, 3, 0}
end
local cases = {}
for _, s in ipairs(seeds) do cases[#cases + 1] = {{x = 0, z = 0}, s} end
for i, s in ipairs(FULL and {3, 11, 23, 77} or {3, 11}) do
	cases[#cases + 1] = {i % 2 == 0 and {x = 1000, z = -2000} or {x = -317, z = 4096}, s}
end

local sig, material_names, planned = {}, {}, 0
for _, case in ipairs(cases) do
	local c, seed = case[1], case[2]
	local label = ("streets seed %d centre (%d,%d)"):format(seed, c.x, c.z)
	local plan, why = small.plan(c, seed)
	eq(plan ~= nil, true, label .. " planned (" .. tostring(why) .. ")")
	if plan then
		planned = planned + 1
		local bset = set_of(plan.boundary.rects)
		local S = plan.sites
		local reserved = set_of({S.cathedral.rect, S.castle.rect, S.city_hall.rect})
		local road, principal = {}, {}
		rect_cells(S.market.rect, function(x, z) road[key(x, z)] = true; principal[key(x, z)] = true end)
		rect_cells(S.parvis.rect, function(x, z) road[key(x, z)] = true; principal[key(x, z)] = true end)
		eq(S.market.material, "mcl_core:cobble", label .. " market material")
		eq(S.parvis.material, "mcl_core:cobble", label .. " parvis material")

		local npr, nsec = 0, 0
		local ok_shape, ok_contained, ok_clear = true, true, true
		for i, s in ipairs(plan.streets) do
			local r = s.rect
			local ex, ez = r.x2 - r.x1 + 1, r.z2 - r.z1 + 1
			local width = (s.kind == "principal") and 6 or 4
			if s.kind == "principal" then npr = npr + 1 else nsec = nsec + 1 end
			if s.id ~= i or s.width ~= width or math.min(ex, ez) ~= width then ok_shape = false end
			local want = (s.kind == "principal") and "mcl_core:cobble" or "mcl_core:gravel"
			if s.material ~= want then ok_shape = false end
			material_names[s.material] = true
			rect_cells(r, function(x, z)
				local k = key(x, z)
				if not bset[k] then ok_contained = false end
				if reserved[k] then ok_clear = false end
				road[k] = true
				if s.kind == "principal" then principal[k] = true end
			end)
		end
		eq(ok_shape, true, label .. " street widths and materials")
		eq(ok_contained, true, label .. " streets inside boundary")
		eq(ok_clear, true, label .. " streets clear of landmarks")
		eq(npr, 2, label .. " two principal streets")
		eq(nsec >= 5, true, label .. " secondary streets present")

		-- Connectivity: independent flood fills from the crossing.
		for _, layer in ipairs({{principal, "principal"}, {road, "all"}}) do
			local seen = flood(layer[1], c.x, c.z)
			local l = label .. " " .. layer[2]
			eq(touches(seen, S.market.rect), true, l .. " market reachable")
			eq(touches(seen, S.parvis.rect), true, l .. " parvis reachable")
			for _, name in ipairs({"castle", "cathedral", "city_hall"}) do
				local p = S[name].approach.pos
				eq(seen[key(p.x, p.z)], true, l .. " " .. name .. " approach reachable")
			end
		end
		do
			local seen = flood(road, c.x, c.z)
			local all = true
			for _, s in ipairs(plan.streets) do
				all = all and seen[key(s.rect.x1, s.rect.z1)] == true
			end
			eq(all, true, label .. " every street connected")
		end
		for _, name in ipairs({"castle", "cathedral"}) do
			local p = S[name].approach.pos
			eq(principal[key(p.x, p.z)], true, label .. " " .. name .. " approach.pos on a principal or square")
		end

		-- Blocks.
		local taken, ok_blocks = {}, true
		for i, b in ipairs(plan.blocks) do
			if b.id ~= i or b.size.x < ROW or b.size.z < ROW or #b.frontage == 0 then
				ok_blocks = false
			end
			rect_cells(b.rect, function(x, z)
				local k = key(x, z)
				if not bset[k] or road[k] or reserved[k] or taken[k] then ok_blocks = false end
				taken[k] = true
			end)
			eq(b.area, b.size.x * b.size.z, label .. " block area")
		end
		eq(ok_blocks, true, label .. " blocks inside, off roads, disjoint")
		eq(#plan.blocks >= 8, true, label .. " blocks")

		-- Frontage: faces an actual street/square with the outward direction.
		local ok_front = true
		for i, f in ipairs(plan.frontage) do
			local b = plan.blocks[f.block]
			local d = FACING[f.side]
			if f.id ~= i or not b or not d or f.facing.x ~= d[1] or f.facing.z ~= d[2] then
				ok_front = false
			else
				local owner_rects = {}
				if f.square then
					owner_rects[1] = S[f.square].rect
					if f.material ~= "mcl_core:cobble" then ok_front = false end
				else
					local st = plan.streets[f.street]
					if not st or st.material ~= f.material then ok_front = false end
					owner_rects[1] = st and st.rect or {x1 = 1, z1 = 1, x2 = 0, z2 = 0}
				end
				local owner = set_of(owner_rects)
				local n = 0
				rect_cells(f.rect, function(x, z)
					n = n + 1
					local br = b.rect
					-- On the block's edge on the named side.
					local on_edge = x >= br.x1 and x <= br.x2 and z >= br.z1 and z <= br.z2
					if f.side == "-z" then on_edge = on_edge and z == br.z1
					elseif f.side == "+z" then on_edge = on_edge and z == br.z2
					elseif f.side == "-x" then on_edge = on_edge and x == br.x1
					else on_edge = on_edge and x == br.x2 end
					if not on_edge then ok_front = false end
					if not owner[key(x + d[1], z + d[2])] then ok_front = false end
					-- And the cell outward of the block is not itself blocked.
					if reserved[key(x + d[1], z + d[2])] then ok_front = false end
				end)
				if n ~= f.length or n < 4 then ok_front = false end
			end
		end
		eq(ok_front, true, label .. " frontage faces its street outward")
		eq(#plan.frontage >= #plan.blocks, true, label .. " frontage per block")

		-- Determinism.
		if c.x == 0 and seed <= 3 then
			eq(deep_equal(plan, small.plan({x = 0, z = 0}, seed)), true, label .. " deterministic")
		end
		local parts = {}
		for _, s in ipairs(plan.streets) do
			parts[#parts + 1] = ("%s%d,%d,%d,%d"):format(s.kind:sub(1, 1),
				s.rect.x1 - c.x, s.rect.z1 - c.z, s.rect.x2 - c.x, s.rect.z2 - c.z)
		end
		if c.x == 0 and c.z == 0 then sig[table.concat(parts, ";")] = true end
	end
end
eq(planned, #cases, "all street cases planned")
local nsig = 0
for _ in pairs(sig) do nsig = nsig + 1 end
eq(nsig, #seeds, "every seed gives distinct street layouts")
eq(material_names["mcl_core:cobble"] and material_names["mcl_core:gravel"], true,
	"both street materials used")

-- The centre only translates streets, blocks and frontage.
do
	local a = small.plan({x = 0, z = 0}, 17)
	local b = small.plan({x = 250, z = -90}, 17)
	local function norm(p, c)
		local out = {}
		for _, s in ipairs(p.streets) do
			out[#out + 1] = ("%s:%d,%d,%d,%d"):format(s.kind, s.rect.x1 - c.x, s.rect.z1 - c.z,
				s.rect.x2 - c.x, s.rect.z2 - c.z)
		end
		for _, bl in ipairs(p.blocks) do
			out[#out + 1] = ("b:%d,%d,%d,%d"):format(bl.rect.x1 - c.x, bl.rect.z1 - c.z,
				bl.rect.x2 - c.x, bl.rect.z2 - c.z)
		end
		out[#out + 1] = "f" .. #p.frontage
		return table.concat(out, ";")
	end
	eq(norm(a, {x = 0, z = 0}), norm(b, {x = 250, z = -90}), "streets translate with centre")
end

-- Fuzz: many seeds/centres through the authored validator plus a paved-door check.
do
	local state = 12345
	local function rnd(a, b)
		state = (state * 48271) % 2147483647
		return a + state % (b - a + 1)
	end
	local ok_all, doors_ok, count = true, true, 0
	local fuzz_runs = FULL and 14 or 3
	for _ = 1, fuzz_runs do
		local c = {x = rnd(-3000, 3000), z = rnd(-3000, 3000)}
		local seed = rnd(-1073741823, 1073741823)
		local plan = small.plan(c, seed)
		count = count + 1
		if not plan then
			ok_all = false
		else
			if not small.validate(plan) then ok_all = false end
			local paved = {}
			for _, st in ipairs(plan.streets) do
				if st.kind == "principal" then rect_cells(st.rect, function(x, z) paved[key(x, z)] = true end) end
			end
			local p = plan.sites.castle.approach.pos
			if not paved[key(p.x, p.z)] then doors_ok = false end
		end
	end
	eq(count, fuzz_runs, "fuzz plans attempted")
	eq(ok_all, true, "fuzz plans valid")
	eq(doors_ok, true, "fuzz castle door nodes paved")
end

-- The validator rejects tampered street, block and frontage data.
do
	local function clone(v)
		if type(v) ~= "table" then return v end
		local o = {}
		for k, x in pairs(v) do o[k] = clone(x) end
		return o
	end
	local base = small.plan({x = 0, z = 0}, 5)
	eq(small.validate(base), true, "base plan validates")
	local function rejects(label, mutate, pattern)
		local p = clone(base)
		mutate(p)
		local ok, reason = small.validate(p)
		eq(ok, nil, label .. " rejected")
		eq(type(reason) == "string" and (pattern == nil or reason:find(pattern, 1, true) ~= nil),
			true, label .. " reason (" .. tostring(reason) .. ")")
		eq(type(reason) == "string" and reason:find("%.lua:%d+") == nil, true,
			label .. " reason has no source location")
	end
	rejects("nil streets", function(p) p.streets = nil end)
	rejects("street without rect", function(p) p.streets[1].rect = nil end)
	rejects("frontage wrong street", function(p)
		local f = p.frontage[1]
		f.street = (f.street == 1) and 2 or 1
		f.square = nil
	end)
	rejects("frontage side vs facing", function(p) p.frontage[1].side = "+x"; p.frontage[1].facing = {x = 0, z = 1} end)
	rejects("frontage wrong material", function(p) p.frontage[1].material = "mcl_core:dirt" end, "material")
	rejects("frontage outside block", function(p) p.frontage[1].rect.x2 = p.frontage[1].rect.x2 + 40 end)
	rejects("block without frontage", function(p) p.blocks[1].frontage = {} end, "frontage")
	rejects("street over a block", function(p)
		local r = p.blocks[1].rect
		p.streets[#p.streets + 1] = {id = #p.streets + 1, kind = "secondary", width = 4,
			material = "mcl_core:gravel", rect = {x1 = r.x1, z1 = r.z1, x2 = r.x1 + 3, z2 = r.z1 + 3}}
	end, "overlaps")
	rejects("detached street", function(p)
		local b = p.bounds
		p.streets[#p.streets + 1] = {id = #p.streets + 1, kind = "secondary", width = 4,
			material = "mcl_core:gravel", rect = {x1 = b.x2 - 3, z1 = b.z2 - 3, x2 = b.x2, z2 = b.z2}}
	end)
end
