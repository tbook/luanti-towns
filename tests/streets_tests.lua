-- Street, block and frontage tests (ticket #13). Loaded by tests/run.lua:
--   loadfile("tests/streets_tests.lua")(eq, fails, planner)
-- Every check below rebuilds its own occupancy from the plan's data; nothing
-- reuses the router's structures.
local eq, fails, planner = ...

-- Principal street width / route clearance (ticket #88: 5).
local SW = planner.CONSTANTS.STREET_WIDTH

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

-- Independent SW-wide clearance walk: BFS over sw x sw windows lying wholly on
-- `occ`, from the window at an approach, brute-force per window.
local function window_walk(occ, b, start, sw)
	local function full(x, z)
		for dz = 0, sw - 1 do
			for dx = 0, sw - 1 do
				if not occ[key(x + dx, z + dz)] then return false end
			end
		end
		return true
	end
	local seen, queue, head = {}, {}, 1
	if not full(start[1], start[2]) then return seen end
	queue[1] = start
	seen[key(start[1], start[2])] = true
	while head <= #queue do
		local c = queue[head]
		head = head + 1
		for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
			local x, z = c[1] + d[1], c[2] + d[2]
			if x >= b.x1 and z >= b.z1 and x + sw - 1 <= b.x2 and z + sw - 1 <= b.z2
					and not seen[key(x, z)] and full(x, z) then
				seen[key(x, z)] = true
				queue[#queue + 1] = {x, z}
			end
		end
	end
	return seen
end

local function approach_window(a, sw)
	local e = a.edge
	if a.side == "+z" then return {e.x1, e.z2 - sw + 1}
	elseif a.side == "+x" then return {e.x2 - sw + 1, e.z1} end
	return {e.x1, e.z1}
end

local function window_touches(seen, r, sw)
	for z = r.z1 - sw + 1, r.z2 do
		for x = r.x1 - sw + 1, r.x2 do
			if seen[key(x, z)] then return true end
		end
	end
	return false
end

local seeds = {}
for i = 1, 7 do seeds[#seeds + 1] = i end
for _, s in ipairs({0, -7, 1073741823}) do
	seeds[#seeds + 1] = s
end
local cases = {}
for _, s in ipairs(seeds) do cases[#cases + 1] = {{x = 0, z = 0}, s} end
for i, s in ipairs({3, 11, 23, 77}) do
	cases[#cases + 1] = {i % 2 == 0 and {x = 1000, z = -2000} or {x = -317, z = 4096}, s}
end
-- Review repro cases (castle door was once left unpaved).
for _, rc in ipairs({
	{-166, -162, -1073711202}, {-2266, -2787, 50}, {-1713, -800, 55},
	{-133, -168, -1073731110}, {-2132, -793, -1073721938}, {-1378, 2747, -1073719420},
}) do
	cases[#cases + 1] = {{x = rc[1], z = rc[2]}, rc[3]}
end

local sig, with_secondary, kinds = {}, 0, {}
local material_names = {}
local planned = 0
for _, case in ipairs(cases) do
	local c, seed = case[1], case[2]
	local label = ("streets seed %d centre (%d,%d)"):format(seed, c.x, c.z)
	local plan, why = planner.plan(c, seed)
	eq(plan ~= nil, true, label .. " planned (" .. tostring(why) .. ")")
	if plan then
		planned = planned + 1
		local bset = set_of(plan.boundary.rects)
		local S = plan.sites
		local reserved = set_of({S.cathedral.rect, S.castle.rect})
		local road, principal = {}, {}
		rect_cells(S.market.rect, function(x, z) road[key(x, z)] = true; principal[key(x, z)] = true end)
		rect_cells(S.parvis.rect, function(x, z) road[key(x, z)] = true; principal[key(x, z)] = true end)
		eq(S.market.material, "mcl_core:stonebrick", label .. " market material")
		eq(S.parvis.material, "mcl_core:stonebrick", label .. " parvis material")

		local npr, nsec = 0, 0
		local ok_shape, ok_contained, ok_clear, ok_ids = true, true, true, true
		for i, s in ipairs(plan.streets) do
			local r = s.rect
			local ex, ez = r.x2 - r.x1 + 1, r.z2 - r.z1 + 1
			local width = (s.kind == "principal") and SW or 4
			if s.kind == "principal" then npr = npr + 1 else nsec = nsec + 1 end
			if s.id ~= i or s.width ~= width or math.min(ex, ez) ~= width then ok_shape = false end
			if ex ~= width and ez ~= width then ok_shape = false end
			if ex > ez and s.axis ~= "x" or ez > ex and s.axis ~= "z" then ok_shape = false end
			local want = (s.kind == "principal") and "mcl_core:stonebrick" or "mcl_core:cobble"
			if s.material ~= want then ok_shape = false end
			material_names[s.material] = true
			if s.kind == "principal" and type(s.route) ~= "string" then ok_shape = false end
			rect_cells(r, function(x, z)
				local k = key(x, z)
				if not bset[k] then ok_contained = false end
				if reserved[k] then ok_clear = false end
				road[k] = true
				if s.kind == "principal" then principal[k] = true end
			end)
		end
		eq(ok_shape, true, label .. " street widths, orthogonality, materials")
		eq(ok_contained, true, label .. " streets inside boundary")
		eq(ok_clear, true, label .. " streets clear of landmarks")
		eq(npr >= 2, true, label .. " principal streets present")
		if nsec > 0 then with_secondary = with_secondary + 1 end

		-- Connectivity: independent flood fills.
		local a1, a2 = plan.approaches[1], plan.approaches[2]
		eq(a1.side ~= a2.side, true, label .. " distinct approaches")
		for _, layer in ipairs({{principal, "principal"}, {road, "all"}}) do
			local seen = flood(layer[1], a1.pos.x, a1.pos.z)
			local l = label .. " " .. layer[2]
			eq(seen[key(a2.pos.x, a2.pos.z)], true, l .. " approach 2 reachable")
			eq(touches(seen, S.market.rect), true, l .. " market reachable")
			eq(touches(seen, S.parvis.rect), true, l .. " parvis reachable")
			eq(touches(seen, S.castle.approach.edge), true, l .. " castle approach reachable")
		end
		do
			local seen = flood(road, a1.pos.x, a1.pos.z)
			local all = true
			for _, s in ipairs(plan.streets) do
				all = all and seen[key(s.rect.x1, s.rect.z1)] == true
			end
			eq(all, true, label .. " every street connected")
		end
		-- Full-width clearance: SWxSW windows walk from each approach to the
		-- other approach, the market and parvis, and cover the cathedral and
		-- castle door nodes (approach.pos).
		for _, a in ipairs({a1, a2}) do
			local w = window_walk(principal, plan.bounds, approach_window(a, SW), SW)
			local o = approach_window(a == a1 and a2 or a1, SW)
			local l = label .. " " .. a.name
			eq(w[key(o[1], o[2])], true, l .. " SW-wide walk to other approach")
			eq(window_touches(w, S.market.rect, SW), true, l .. " SW-wide walk to market")
			eq(window_touches(w, S.parvis.rect, SW), true, l .. " SW-wide walk to parvis")
			for _, name in ipairs({"castle", "cathedral"}) do
				local p = S[name].approach.pos
				eq(window_touches(w, {x1 = p.x, z1 = p.z, x2 = p.x, z2 = p.z}, SW), true,
					l .. " SW-wide walk covers " .. name .. " approach.pos")
			end
		end
		for _, name in ipairs({"castle", "cathedral"}) do
			local p = S[name].approach.pos
			eq(principal[key(p.x, p.z)], true, label .. " " .. name .. " approach.pos paved")
		end

		-- Blocks.
		local taken, ok_blocks = {}, true
		for i, b in ipairs(plan.blocks) do
			if b.id ~= i or b.size.x < 8 or b.size.z < 8 or #b.frontage == 0 then
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
		eq(#plan.blocks >= 3, true, label .. " at least 3 blocks")

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
					if f.material ~= "mcl_core:stonebrick" then ok_front = false end
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
			eq(deep_equal(plan, planner.plan({x = 0, z = 0}, seed)), true, label .. " deterministic")
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
eq(with_secondary >= 4, true, "secondary streets appear for many seeds")
eq(material_names["mcl_core:stonebrick"] and material_names["mcl_core:cobble"], true,
	"both street materials used")

-- The centre only translates streets, blocks and frontage.
do
	local a = planner.plan({x = 0, z = 0}, 17)
	local b = planner.plan({x = 250, z = -90}, 17)
	local function norm(p, c)
		local out = {}
		for _, s in ipairs(p.streets) do
			out[#out + 1] = ("%s:%d,%d,%d,%d"):format(s.route, s.rect.x1 - c.x, s.rect.z1 - c.z,
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

-- Street failures consume the retry budget and name the stage.
do
	local opts = {max_attempts = 40, constants = {MIN_BLOCKS = 999}}
	local plan, reason, detail = planner.plan({x = 0, z = 0}, 7, opts)
	eq(plan, nil, "unsatisfiable block count fails")
	eq(detail.code, "retries_exhausted", "street failure code")
	eq((detail.rejections.streets or 0) > 0, true, "street stage counted")
	eq(reason:find("streets x", 1, true) ~= nil, true, "reason names street stage")
	local _, reason2 = planner.plan({x = 0, z = 0}, 7, opts)
	eq(reason2, reason, "street failure deterministic")
	-- Wider streets than the town can host fail somewhere in the pipeline.
	local p2, r2 = planner.plan({x = 0, z = 0}, 7,
		{max_attempts = 4, constants = {SECONDARY_WIDTH = 60, MIN_SECONDARY_LEN = 2}})
	eq(p2 ~= nil or type(r2) == "string", true, "extreme secondary width handled")
end

-- Renderer shows streets, blocks and frontage direction.
do
	local plan = planner.plan({x = 0, z = 0}, 7)
	local text = planner.render(plan)
	for _, ch in ipairs({"#", "b", "M", "p", "C", "K"}) do
		eq(text:find(ch, 1, true) ~= nil, true, "render has " .. ch)
	end
	eq(text:find("[%^v<>]") ~= nil, true, "render shows frontage arrows")
end

-- Fuzz: many seeds/centres through planner.validate plus a paved-door check.
do
	local state = 12345
	local function rnd(a, b)
		state = (state * 48271) % 2147483647
		return a + state % (b - a + 1)
	end
	local ok_all, doors_ok, count = true, true, 0
	for _ = 1, 14 do
		local c = {x = rnd(-3000, 3000), z = rnd(-3000, 3000)}
		local seed = rnd(-1073741823, 1073741823)
		local plan = planner.plan(c, seed)
		count = count + 1
		if not plan then
			ok_all = false
		else
			if not planner.validate(plan) then ok_all = false end
			local paved = {}
			for _, st in ipairs(plan.streets) do
				if st.kind == "principal" then rect_cells(st.rect, function(x, z) paved[key(x, z)] = true end) end
			end
			local p = plan.sites.castle.approach.pos
			if not paved[key(p.x, p.z)] then doors_ok = false end
		end
	end
	eq(count, 14, "fuzz plans attempted")
	eq(ok_all, true, "fuzz plans valid")
	eq(doors_ok, true, "fuzz castle door nodes paved")
end

-- planner.validate rejects tampered street, block and frontage data.
do
	local function clone(v)
		if type(v) ~= "table" then return v end
		local o = {}
		for k, x in pairs(v) do o[k] = clone(x) end
		return o
	end
	local base = planner.plan({x = 0, z = 0}, 5)
	eq(planner.validate(base), true, "base plan validates")
	local function rejects(label, mutate, pattern)
		local p = clone(base)
		mutate(p)
		local ok, reason = planner.validate(p)
		eq(ok, nil, label .. " rejected")
		eq(type(reason) == "string" and (pattern == nil or reason:find(pattern, 1, true) ~= nil),
			true, label .. " reason (" .. tostring(reason) .. ")")
		eq(type(reason) == "string" and reason:find("%.lua:%d+") == nil, true,
			label .. " reason has no source location")
	end
	rejects("no streets", function(p) p.streets = {} end, "no streets")
	rejects("nil streets", function(p) p.streets = nil end)
	rejects("street without rect", function(p) p.streets[1].rect = nil end, "malformed plan")
	rejects("street wrong width", function(p)
		p.streets[1].rect.z2 = p.streets[1].rect.z2 + 1
		p.streets[1].rect.x2 = p.streets[1].rect.x2 + 1
	end)
	rejects("street wrong material", function(p) p.streets[1].material = "mcl_core:cobble" end, "material")
	rejects("frontage wrong street", function(p)
		local f = p.frontage[1]
		f.street = (f.street == 1) and 2 or 1
		f.square = nil
	end)
	rejects("frontage side vs facing", function(p) p.frontage[1].side = "+x"; p.frontage[1].facing = {x = 0, z = 1} end)
	rejects("frontage wrong material", function(p) p.frontage[1].material = "mcl_core:dirt" end, "material")
	rejects("frontage outside block", function(p) p.frontage[1].rect.x2 = p.frontage[1].rect.x2 + 40 end)
	rejects("block too small", function(p)
		local r = p.blocks[1].rect
		r.x2 = r.x1 + 3
	end)
	rejects("block without frontage", function(p) p.blocks[1].frontage = {} end, "frontage")
	rejects("principal dead end", function(p)
		-- A stray principal stub attached to nothing but the town interior.
		local s = p.streets[1]
		local c = p.center
		p.streets[#p.streets + 1] = {id = #p.streets + 1, kind = "principal", width = SW,
			rect = {x1 = c.x + 40, z1 = c.z + 40, x2 = c.x + 39 + SW, z2 = c.z + 52},
			axis = "z", material = s.material, route = "stub"}
	end)

	-- Stubs hanging off the castle street must not hide behind landmark
	-- leniency (reviewer repro plan, blocks and frontage cleared).
	do
		-- Re-pinned in #88 from seed -1073729107: with 5-wide streets the old
		-- plan's extension is a legitimate road, so a seed that keeps the
		-- stub shapes (extension rejected, a free spur site) is used.
		local b2 = planner.plan({x = -32, z = -8}, 3)
		eq(b2 ~= nil, true, "stub repro plan exists")
		if b2 then
			b2.blocks, b2.frontage = {}, {}
			eq(planner.validate(b2), true, "stub repro plan validates untouched")
			local pos = b2.sites.castle.approach.pos
			local idx
			for i, st in ipairs(b2.streets) do
				local r = st.rect
				if st.kind == "principal" and pos.x >= r.x1 and pos.x <= r.x2
						and pos.z >= r.z1 and pos.z <= r.z2 then idx = i end
			end
			eq(idx ~= nil, true, "castle street found")
			if idx then
				-- (a) extend the street SW cells beyond the door end.
				local p = clone(b2)
				local r = p.streets[idx].rect
				if r.x2 - r.x1 >= r.z2 - r.z1 then
					if pos.x <= r.x1 + SW - 1 then r.x1 = r.x1 - SW else r.x2 = r.x2 + SW end
				else
					if pos.z <= r.z1 + SW - 1 then r.z1 = r.z1 - SW else r.z2 = r.z2 + SW end
				end
				p.streets[idx].axis = (r.x2 - r.x1 >= r.z2 - r.z1) and "x" or "z"
				local ok, why = planner.validate(p)
				eq(ok, nil, "street extended past the door rejected (" .. tostring(why) .. ")")
				-- (b) an SWxSW spur off the street's side, on free land.
				local bset, taken = {}, {}
				for _, br in ipairs(b2.boundary.rects) do
					for z = br.z1, br.z2 do for x = br.x1, br.x2 do bset[key(x, z)] = true end end
				end
				local function mark(q) rect_cells(q, function(x, z) taken[key(x, z)] = true end) end
				for _, st in ipairs(b2.streets) do mark(st.rect) end
				for _, name in ipairs({"cathedral", "parvis", "market", "castle"}) do
					mark(b2.sites[name].rect)
				end
				local sr, spur = b2.streets[idx].rect
				local function fits(x1, z1)
					local ok_ = true
					rect_cells({x1 = x1, z1 = z1, x2 = x1 + SW - 1, z2 = z1 + SW - 1}, function(x, z)
						if not bset[key(x, z)] or taken[key(x, z)] then ok_ = false end
					end)
					return ok_
				end
				for off = sr.x1 - SW + 1, sr.x2 do
					if not spur and fits(off, sr.z2 + 1) then spur = {off, sr.z2 + 1} end
					if not spur and fits(off, sr.z1 - SW) then spur = {off, sr.z1 - 6} end
				end
				for off = sr.z1 - SW + 1, sr.z2 do
					if not spur and fits(sr.x2 + 1, off) then spur = {sr.x2 + 1, off} end
					if not spur and fits(sr.x1 - SW, off) then spur = {sr.x1 - 6, off} end
				end
				eq(spur ~= nil, true, "spur site found")
				if spur then
					local q = clone(b2)
					q.streets[#q.streets + 1] = {id = #q.streets + 1, kind = "principal",
						width = SW, axis = "x", material = b2.streets[idx].material,
						route = "spur", rect = {x1 = spur[1], z1 = spur[2],
							x2 = spur[1] + SW - 1, z2 = spur[2] + SW - 1}}
					local ok2, why2 = planner.validate(q)
					eq(ok2, nil, "SWxSW spur rejected (" .. tostring(why2) .. ")")
				end
			end
		end
	end
	-- streets.validate called directly never raises on a bare plan.
	do
		local streets_mod = dofile("src/streets.lua")
		local C = planner.CONSTANTS
		for _, bad in ipairs({{}, {streets = {{rect = {}}}},
				{envelope = {x1 = 0, z1 = 0, x2 = 95, z2 = 95}}}) do
			local ok, ok2, why = pcall(streets_mod.validate, bad, C)
			eq(ok, true, "streets.validate does not raise")
			eq(ok2, false, "streets.validate rejects bare plan")
			eq(type(why) == "string" and why:find("malformed plan", 1, true) ~= nil
				and why:find("%.lua:%d+") == nil, true, "clean malformed reason")
		end
	end
end
