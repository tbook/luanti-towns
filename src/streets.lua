-- Towns: street, block and frontage planning (pure Lua 5.1, no core.*).
--
-- Fills `plan.streets`, `plan.blocks` and `plan.frontage` of a plan produced
-- by planner.lua (boundary + civic sites). Called from planner.plan() on each
-- accepted boundary/sites attempt; a failure here is a rejected attempt and
-- the planner's bounded retry budget covers it.
--
--   local streets = dofile("src/streets.lua")
--   local plan, reason = streets.fill(plan, rng, constants)
--   local ok, reason   = streets.validate(plan, constants)
--
-- `rng` is the planner's seeded PRNG ({int(a, b), pick(list)}); nothing here
-- uses math.random or depends on pairs() order, and all work is done in
-- envelope-local coordinates, so a seed gives the same streets at any centre.
--
-- Method
-- ------
-- 1. Principal streets are 6 wide. A route is a shortest path (Dijkstra with
--    a turn penalty and seeded per-window noise as tie-breaker) of 6x6
--    windows that lie wholly inside the boundary and clear of the cathedral
--    and castle footprints; the union of the windows is a rectilinear
--    corridor of full street width. Straight runs become street rectangles.
--    Routes: approach_1 > market, approach_2 > market, then (from the
--    network built so far) > parvis and > castle approach.
-- 2. Secondary streets are 4 wide, straight, and added while some free cell
--    is farther than MAX_BLOCK_DEPTH from any road: a strip through the
--    worst cell is extended both ways over free cells and must abut the
--    existing network at one end (the other ends at the boundary edge, a
--    landmark footprint or a road).
-- 3. Blocks are axis-aligned rectangles greedily carved (largest first) from
--    the leftover free cells, at least MIN_BLOCK_SIDE on both sides, and only
--    kept when they have at least one frontage run.
-- 4. Frontage runs are contiguous stretches of a block edge whose outer row
--    is one street (or square), at least MIN_FRONTAGE_RUN long.

local M = {}

local SIDES = {"-z", "+z", "-x", "+x"}
local FACING = {
	["-z"] = {x = 0, z = -1}, ["+z"] = {x = 0, z = 1},
	["-x"] = {x = -1, z = 0}, ["+x"] = {x = 1, z = 0},
}
local MOVES = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------
local function shift(r, dx, dz)
	return {x1 = r.x1 + dx, z1 = r.z1 + dz, x2 = r.x2 + dx, z2 = r.z2 + dz}
end

-- Flat n*n layer helpers; cell (x, z) lives at index z * n + x + 1.
local function new_layer(n, v)
	local t = {}
	for i = 1, n * n do t[i] = v end
	return t
end

-- Inclusive-rectangle sum over a 0/1 layer via prefix sums.
local function make_count(cells, n)
	local W = n + 1
	local P = {}
	for i = 0, W * W - 1 do P[i] = 0 end
	for z = 1, n do
		local acc = 0
		for x = 1, n do
			acc = acc + cells[(z - 1) * n + x]
			P[z * W + x] = P[(z - 1) * W + x] + acc
		end
	end
	return function(x1, z1, x2, z2)
		return P[(z2 + 1) * W + x2 + 1] - P[z1 * W + x2 + 1]
			- P[(z2 + 1) * W + x1] + P[z1 * W + x1]
	end
end

local function set_rect(cells, n, r, v)
	for z = r.z1, r.z2 do
		for x = r.x1, r.x2 do cells[z * n + x + 1] = v end
	end
end

-- Binary min-heap of (key, value).
local function heap_new() return {n = 0, k = {}, v = {}} end

local function heap_push(h, key, val)
	local i = h.n + 1
	h.n = i
	local k, v = h.k, h.v
	while i > 1 do
		local p = math.floor(i / 2)
		if k[p] <= key then break end
		k[i], v[i] = k[p], v[p]
		i = p
	end
	k[i], v[i] = key, val
end

local function heap_pop(h)
	local k, v = h.k, h.v
	local topk, topv = k[1], v[1]
	local last = h.n
	local lk, lv = k[last], v[last]
	k[last], v[last] = nil, nil
	h.n = last - 1
	if last > 1 then
		local i, n = 1, last - 1
		while true do
			local c = i * 2
			if c > n then break end
			if c < n and k[c + 1] < k[c] then c = c + 1 end
			if k[c] >= lk then break end
			k[i], v[i] = k[c], v[c]
			i = c
		end
		k[i], v[i] = lk, lv
	end
	return topk, topv
end

-- Deterministic per-window noise in [0, 1), seeded by `salt`.
local function noise(x, z, salt)
	local h = (x * 374761393 + z * 668265263 + salt * 1274126177) % 1000003
	h = (h * h + 12345) % 1000003
	h = (h * 7919 + 104729) % 1000003
	return h / 1000003
end

------------------------------------------------------------------------
-- Fill
------------------------------------------------------------------------
-- Returns plan (filled in place) or nil, reason.
function M.fill(plan, rng, C)
	local n = C.ENVELOPE
	local sw, nw = C.STREET_WIDTH, C.SECONDARY_WIDTH
	local ox, oz = plan.envelope.x1, plan.envelope.z1
	local function idx(x, z) return z * n + x + 1 end
	local function lrect(r) return {x1 = r.x1 - ox, z1 = r.z1 - oz, x2 = r.x2 - ox, z2 = r.z2 - oz} end
	local function arect(r) return shift(r, ox, oz) end

	-- Free: inside the boundary and not a reserved landmark footprint.
	local F = new_layer(n, 0)
	for _, r in ipairs(plan.boundary.rects) do set_rect(F, n, lrect(r), 1) end
	local cathedral = lrect(plan.sites.cathedral.rect)
	local castle = lrect(plan.sites.castle.rect)
	set_rect(F, n, cathedral, 0)
	set_rect(F, n, castle, 0)
	local fcount = make_count(F, n)

	local market = lrect(plan.sites.market.rect)
	local parvis = lrect(plan.sites.parvis.rect)
	local pl = new_layer(n, 0)
	set_rect(pl, n, parvis, 1)
	local pcount = make_count(pl, n)

	-- R: pavement connected to the network so far (market, then streets).
	local R = new_layer(n, 0)
	set_rect(R, n, market, 1)
	local rcount = make_count(R, n)

	local streets = {}
	local function add_street(kind, r, route)
		local width = (kind == "principal") and sw or nw
		local ex, ez = r.x2 - r.x1 + 1, r.z2 - r.z1 + 1
		streets[#streets + 1] = {
			id = #streets + 1, kind = kind, width = width,
			rect = arect(r), axis = (ez > ex) and "z" or "x",
			material = (kind == "principal") and C.PRINCIPAL_MATERIAL or C.SECONDARY_MATERIAL,
			route = route,
		}
	end

	local winmax = n - sw
	local function window_free(x, z)
		return x >= 0 and z >= 0 and x <= winmax and z <= winmax
			and fcount(x, z, x + sw - 1, z + sw - 1) == sw * sw
	end

	-- Dijkstra over window top-left corners. State = (x, z, last move).
	-- Returns a list of {x, z} windows or nil.
	local function route(sources, goal, pos, avoid_parvis, inside)
		local salt = rng.int(1, 1000000)
		local heap = heap_new()
		local dist, prev, done = {}, {}, {}
		-- A* heuristic: 0.4 is the cheapest possible step.
		local gx1, gx2, gz1, gz2
		if inside then
			gx1, gx2, gz1, gz2 = goal.x1, goal.x2 - sw + 1, goal.z1, goal.z2 - sw + 1
		else
			gx1, gx2, gz1, gz2 = goal.x1 - sw + 1, goal.x2, goal.z1 - sw + 1, goal.z2
		end
		local function h(x, z)
			local dx = (x < gx1) and (gx1 - x) or ((x > gx2) and (x - gx2) or 0)
			local dz = (z < gz1) and (gz1 - z) or ((z > gz2) and (z - gz2) or 0)
			return 0.4 * (dx + dz)
		end
		for i = 1, #sources do
			local s = sources[i]
			local id = (s[2] * n + s[1]) * 5
			if dist[id] == nil then
				dist[id] = 0
				heap_push(heap, h(s[1], s[2]), id)
			end
		end
		local full = sw * sw
		while heap.n > 0 do
			local key, id = heap_pop(heap)
			if id < 0 then
				local t = -id - 1
				local path = {}
				while t do
					local p = math.floor(t / 5)
					local z = math.floor(p / n)
					table.insert(path, 1, {p - z * n, z})
					t = prev[t]
				end
				return path
			end
			local p = math.floor(id / 5)
			local dir = id - p * 5
			local z = math.floor(p / n)
			local x = p - z * n
			local d = dist[id]
			if key <= d + h(x, z) + 1e-9 then
				local at_goal
				if inside then
					-- Wholly inside a square: the corridor opens into it at
					-- full width instead of ending on a corner.
					at_goal = x >= goal.x1 and x + sw - 1 <= goal.x2
						and z >= goal.z1 and z + sw - 1 <= goal.z2
				else
					at_goal = x <= goal.x2 and x + sw - 1 >= goal.x1
						and z <= goal.z2 and z + sw - 1 >= goal.z1
				end
				if not done[p] and at_goal then
					done[p] = true
					local pen = 0.25 * (math.abs(x + (sw - 1) / 2 - pos.x)
						+ math.abs(z + (sw - 1) / 2 - pos.z))
					heap_push(heap, d + pen, -id - 1)
				end
				for m = 1, 4 do
					local nx, nz = x + MOVES[m][1], z + MOVES[m][2]
					if window_free(nx, nz) then
						local rc = rcount(nx, nz, nx + sw - 1, nz + sw - 1)
						local step
						if rc == full then
							step = 0.4 + 0.2 * noise(nx, nz, salt)
						else
							step = 1 + 0.5 * noise(nx, nz, salt)
							if rc > 0 then step = step + 1.5 end
						end
						if avoid_parvis and pcount(nx, nz, nx + sw - 1, nz + sw - 1) > 0 then
							step = step + 2
						end
						if dir ~= 0 and dir ~= m then step = step + C.TURN_PENALTY end
						local nid = (nz * n + nx) * 5 + m
						local nd = d + step
						if dist[nid] == nil or nd < dist[nid] then
							dist[nid] = nd
							prev[nid] = id
							heap_push(heap, nd + h(nx, nz), nid)
						end
					end
				end
			end
		end
		return nil
	end

	local function network_sources()
		local out = {}
		for z = 0, winmax do
			for x = 0, winmax do
				if rcount(x, z, x + sw - 1, z + sw - 1) == sw * sw then
					out[#out + 1] = {x, z}
				end
			end
		end
		return out
	end

	local function approach_window(a)
		local e = lrect(a.edge)
		if a.side == "+z" then return {e.x1, e.z2 - sw + 1}
		elseif a.side == "+x" then return {e.x2 - sw + 1, e.z1} end
		return {e.x1, e.z1}
	end

	-- Turn a window path into straight street rectangles (trimmed where an
	-- end is already wholly paved) and pave them.
	local function pave(path, name)
		local runs = {}
		if #path == 1 then
			runs[1] = {path[1], path[1]}
		else
			local i = 1
			while i < #path do
				local dx, dz = path[i + 1][1] - path[i][1], path[i + 1][2] - path[i][2]
				local j = i + 1
				while j < #path and path[j + 1][1] - path[j][1] == dx
						and path[j + 1][2] - path[j][2] == dz do
					j = j + 1
				end
				runs[#runs + 1] = {path[i], path[j]}
				i = j
			end
		end
		local rects = {}
		for _, run in ipairs(runs) do
			local a, b = run[1], run[2]
			local r = {
				x1 = math.min(a[1], b[1]), z1 = math.min(a[2], b[2]),
				x2 = math.max(a[1], b[1]) + sw - 1, z2 = math.max(a[2], b[2]) + sw - 1,
			}
			local function col_full(x)
				for z = r.z1, r.z2 do if R[idx(x, z)] == 0 then return false end end
				return true
			end
			local function row_full(z)
				for x = r.x1, r.x2 do if R[idx(x, z)] == 0 then return false end end
				return true
			end
			if r.x2 - r.x1 + 1 > sw then
				while r.x2 - r.x1 + 1 > sw and col_full(r.x1) do r.x1 = r.x1 + 1 end
				while r.x2 - r.x1 + 1 > sw and col_full(r.x2) do r.x2 = r.x2 - 1 end
			elseif r.z2 - r.z1 + 1 > sw then
				while r.z2 - r.z1 + 1 > sw and row_full(r.z1) do r.z1 = r.z1 + 1 end
				while r.z2 - r.z1 + 1 > sw and row_full(r.z2) do r.z2 = r.z2 - 1 end
			end
			if rcount(r.x1, r.z1, r.x2, r.z2) < (r.x2 - r.x1 + 1) * (r.z2 - r.z1 + 1) then
				rects[#rects + 1] = r
			end
		end
		for _, r in ipairs(rects) do
			add_street("principal", r, name)
			set_rect(R, n, r, 1)
		end
		rcount = make_count(R, n)
	end

	local function centre(site) return {x = site.approach.pos.x - ox, z = site.approach.pos.z - oz} end

	local sites = plan.sites
	local mpos = centre(sites.market)
	for i = 1, 2 do
		local a = plan.approaches[i]
		local src = approach_window(a)
		if not window_free(src[1], src[2]) then
			return nil, "approach window blocked: " .. a.name
		end
		local path = route({src}, market, mpos, true, true)
		if not path then
			return nil, "no street-wide route from " .. a.name .. " to the market"
		end
		pave(path, a.name .. ">market")
	end
	local ppos = centre(sites.parvis)
	local path = route(network_sources(), parvis, ppos, false, true)
	if not path then return nil, "no street-wide route from the network to the parvis" end
	pave(path, "network>parvis")
	set_rect(R, n, parvis, 1)
	rcount = make_count(R, n)

	local cedge = lrect(sites.castle.approach.edge)
	local cpos = centre(sites.castle)
	path = route(network_sources(), cedge, cpos, true)
	if not path then return nil, "no street-wide route from the network to the castle approach" end
	pave(path, "network>castle")

	local function avail(x, z)
		return x >= 0 and z >= 0 and x < n and z < n
			and F[idx(x, z)] == 1 and R[idx(x, z)] == 0
	end
	-- Chebyshev distance to the nearest road cell (two-pass chamfer).
	local function road_dist()
		local INF = 1e9
		local dist = {}
		for i = 1, n * n do dist[i] = (R[i] == 1) and 0 or INF end
		for z = 0, n - 1 do
			for x = 0, n - 1 do
				local i = z * n + x + 1
				local d = dist[i]
				if d > 0 then
					if x > 0 and dist[i - 1] + 1 < d then d = dist[i - 1] + 1 end
					if z > 0 then
						local j = i - n
						if dist[j] + 1 < d then d = dist[j] + 1 end
						if x > 0 and dist[j - 1] + 1 < d then d = dist[j - 1] + 1 end
						if x < n - 1 and dist[j + 1] + 1 < d then d = dist[j + 1] + 1 end
					end
					dist[i] = d
				end
			end
		end
		for z = n - 1, 0, -1 do
			for x = n - 1, 0, -1 do
				local i = z * n + x + 1
				local d = dist[i]
				if d > 0 then
					if x < n - 1 and dist[i + 1] + 1 < d then d = dist[i + 1] + 1 end
					if z < n - 1 then
						local j = i + n
						if dist[j] + 1 < d then d = dist[j] + 1 end
						if x < n - 1 and dist[j + 1] + 1 < d then d = dist[j + 1] + 1 end
						if x > 0 and dist[j - 1] + 1 < d then d = dist[j - 1] + 1 end
					end
					dist[i] = d
				end
			end
		end
		return dist
	end

	-- Straight strip nw wide through (cx, cz) along `axis`, or nil.
	local function strip(cx, cz, axis)
		local function ok_col(a, b1) -- a = coordinate along axis, b1 = first cross coordinate
			for k = 0, nw - 1 do
				local x, z = a, b1 + k
				if axis == "z" then x, z = b1 + k, a end
				if not avail(x, z) then return false end
			end
			return true
		end
		local along = (axis == "x") and cx or cz
		local cross = (axis == "x") and cz or cx
		local b1
		for _, off in ipairs({-1, -2, 0, -3}) do
			if ok_col(along, cross + off) then b1 = cross + off; break end
		end
		if not b1 then return nil end
		local lo, hi = along, along
		while ok_col(lo - 1, b1) do lo = lo - 1 end
		while ok_col(hi + 1, b1) do hi = hi + 1 end
		if hi - lo + 1 < C.MIN_SECONDARY_LEN then return nil end
		local function touches(a)
			for k = 0, nw - 1 do
				local x, z = a, b1 + k
				if axis == "z" then x, z = b1 + k, a end
				if x >= 0 and z >= 0 and x < n and z < n and R[idx(x, z)] == 1 then
					return true
				end
			end
			return false
		end
		if not (touches(lo - 1) or touches(hi + 1)) then return nil end
		if axis == "x" then
			return {x1 = lo, z1 = b1, x2 = hi, z2 = b1 + nw - 1}
		end
		return {x1 = b1, z1 = lo, x2 = b1 + nw - 1, z2 = hi}
	end

	local skip = {}
	local dist -- recomputed only when a street is added
	local added, tries = 0, 0
	while added < C.MAX_SECONDARY and tries < 4 * C.MAX_SECONDARY + 8 do
		tries = tries + 1
		if not dist then dist = road_dist() end
		local best, cands = C.MAX_BLOCK_DEPTH, {}
		local i = 0
		for z = 0, n - 1 do
			for x = 0, n - 1 do
				i = i + 1
				local d = dist[i]
				if d > best and F[i] == 1 and R[i] == 0 and not skip[i] then
					best, cands = d, {{x, z}}
				elseif d == best and #cands > 0 and F[i] == 1 and R[i] == 0
						and not skip[i] then
					cands[#cands + 1] = {x, z}
				end
			end
		end
		if #cands == 0 then break end
		local c = cands[rng.int(1, #cands)]
		local first = rng.int(0, 1) == 0 and "x" or "z"
		local second = first == "x" and "z" or "x"
		local r1, r2 = strip(c[1], c[2], first), strip(c[1], c[2], second)
		local r
		if r1 and r2 then
			r = (rng.int(0, 1) == 0) and r1 or r2
		else
			r = r1 or r2
		end
		if r then
			add_street("secondary", r, "secondary")
			set_rect(R, n, r, 1)
			added = added + 1
			dist = nil
		else
			skip[idx(c[1], c[2])] = true
		end
	end

	local U = new_layer(n, 0)
	for z = 0, n - 1 do
		for x = 0, n - 1 do
			if F[idx(x, z)] == 1 and R[idx(x, z)] == 0 then U[idx(x, z)] = 1 end
		end
	end
	local minside = C.MIN_BLOCK_SIDE
	local cand_blocks = {}
	for _ = 1, C.MAX_BLOCK_SCAN do
		local h = {}
		for x = 0, n - 1 do h[x] = 0 end
		local best_area, best
		for z = 0, n - 1 do
			for x = 0, n - 1 do
				h[x] = (U[idx(x, z)] == 1) and (h[x] + 1) or 0
			end
			local sx, sh, sp = {}, {}, 0
			for x = 0, n do
				local cur = (x < n) and h[x] or 0
				local start = x
				while sp > 0 and sh[sp] >= cur do
					local hh, s = sh[sp], sx[sp]
					sp = sp - 1
					local w = x - s
					if hh >= minside and w >= minside
							and (best_area == nil or hh * w > best_area) then
						best_area = hh * w
						best = {x1 = s, z1 = z - hh + 1, x2 = x - 1, z2 = z}
					end
					start = s
				end
				if cur > 0 then
					sp = sp + 1
					sx[sp], sh[sp] = start, cur
				end
			end
		end
		if not best then break end
		set_rect(U, n, best, 0)
		cand_blocks[#cand_blocks + 1] = best
	end

	local owner = {}
	local function claim(r, tag)
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do
				local i = idx(x, z)
				if owner[i] == nil then owner[i] = tag end
			end
		end
	end
	claim(market, "market")
	claim(parvis, "parvis")
	for _, s in ipairs(streets) do claim(lrect(s.rect), s.id) end

	local blocks, frontage = {}, {}
	for _, br in ipairs(cand_blocks) do
		local runs = {}
		for _, side in ipairs(SIDES) do
			local f = FACING[side]
			-- Block edge cells along this side, in increasing coordinate.
			local cells = {}
			if side == "-z" or side == "+z" then
				local z = (side == "-z") and br.z1 or br.z2
				for x = br.x1, br.x2 do cells[#cells + 1] = {x, z} end
			else
				local x = (side == "-x") and br.x1 or br.x2
				for z = br.z1, br.z2 do cells[#cells + 1] = {x, z} end
			end
			local i = 1
			while i <= #cells do
				local ox_, oz_ = cells[i][1] + f.x, cells[i][2] + f.z
				local tag = (ox_ >= 0 and oz_ >= 0 and ox_ < n and oz_ < n)
					and owner[idx(ox_, oz_)] or nil
				local j = i
				if tag ~= nil then
					while j < #cells do
						local nx_, nz_ = cells[j + 1][1] + f.x, cells[j + 1][2] + f.z
						local t2 = (nx_ >= 0 and nz_ >= 0 and nx_ < n and nz_ < n)
							and owner[idx(nx_, nz_)] or nil
						if t2 ~= tag then break end
						j = j + 1
					end
					if j - i + 1 >= C.MIN_FRONTAGE_RUN then
						runs[#runs + 1] = {
							side = side, tag = tag,
							rect = {x1 = math.min(cells[i][1], cells[j][1]),
								z1 = math.min(cells[i][2], cells[j][2]),
								x2 = math.max(cells[i][1], cells[j][1]),
								z2 = math.max(cells[i][2], cells[j][2])},
							length = j - i + 1,
						}
					end
				end
				i = j + 1
			end
		end
		if #runs > 0 then
			local id = #blocks + 1
			local ids = {}
			for _, run in ipairs(runs) do
				local fid = #frontage + 1
				ids[#ids + 1] = fid
				local entry = {
					id = fid, block = id, side = run.side,
					facing = {x = FACING[run.side].x, z = FACING[run.side].z},
					rect = arect(run.rect), length = run.length,
				}
				if run.tag == "market" or run.tag == "parvis" then
					entry.square = run.tag
					entry.material = C.SQUARE_MATERIAL
				else
					entry.street = run.tag
					entry.material = streets[run.tag].material
				end
				frontage[fid] = entry
			end
			blocks[id] = {
				id = id, rect = arect(br),
				size = {x = br.x2 - br.x1 + 1, z = br.z2 - br.z1 + 1},
				area = (br.x2 - br.x1 + 1) * (br.z2 - br.z1 + 1),
				frontage = ids,
			}
		end
	end

	sites.market.material = C.SQUARE_MATERIAL
	sites.parvis.material = C.SQUARE_MATERIAL
	plan.streets, plan.blocks, plan.frontage = streets, blocks, frontage

	local ok, why = M.validate(plan, C)
	if not ok then return nil, why end
	if #blocks < C.MIN_BLOCKS then
		return nil, ("only %d blocks with street frontage (need %d)"):format(#blocks, C.MIN_BLOCKS)
	end
	return plan
end

------------------------------------------------------------------------
-- Validation (uses only plan data; rebuilds occupancy from the rects)
------------------------------------------------------------------------
function M.validate(plan, C)
	local n = C.ENVELOPE
	local ox, oz = plan.envelope.x1, plan.envelope.z1
	local function idx(x, z) return (z - oz) * n + (x - ox) + 1 end
	local function inenv(x, z) return x >= ox and z >= oz and x < ox + n and z < oz + n end

	local inb = new_layer(n, 0)
	for _, r in ipairs(plan.boundary.rects) do
		set_rect(inb, n, shift(r, -ox, -oz), 1)
	end
	local reserved = new_layer(n, 0)
	set_rect(reserved, n, shift(plan.sites.cathedral.rect, -ox, -oz), 1)
	set_rect(reserved, n, shift(plan.sites.castle.rect, -ox, -oz), 1)

	local road = new_layer(n, 0)
	local principal = new_layer(n, 0)
	local sq = {"market", "parvis"}
	for _, name in ipairs(sq) do
		local r = shift(plan.sites[name].rect, -ox, -oz)
		set_rect(road, n, r, 1)
		set_rect(principal, n, r, 1)
		if plan.sites[name].material ~= C.SQUARE_MATERIAL then
			return false, name .. " material missing"
		end
	end

	for _, s in ipairs(plan.streets) do
		local r = s.rect
		local ex, ez = r.x2 - r.x1 + 1, r.z2 - r.z1 + 1
		local want = (s.kind == "principal") and C.STREET_WIDTH or C.SECONDARY_WIDTH
		if s.kind ~= "principal" and s.kind ~= "secondary" then
			return false, "street " .. s.id .. " has unknown kind"
		end
		if s.width ~= want or math.min(ex, ez) ~= want then
			return false, ("street %d is %dx%d, expected width %d"):format(s.id, ex, ez, want)
		end
		local mat = (s.kind == "principal") and C.PRINCIPAL_MATERIAL or C.SECONDARY_MATERIAL
		if s.material ~= mat then return false, "street " .. s.id .. " material" end
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do
				if not inenv(x, z) or inb[idx(x, z)] ~= 1 then
					return false, ("street %d leaves the boundary at (%d,%d)"):format(s.id, x, z)
				end
				if reserved[idx(x, z)] == 1 then
					return false, ("street %d crosses a landmark at (%d,%d)"):format(s.id, x, z)
				end
				road[idx(x, z)] = 1
				if s.kind == "principal" then principal[idx(x, z)] = 1 end
			end
		end
	end

	-- Pedestrian connectivity over the pavement, from both approaches.
	local function flood(layer, sx, sz)
		local seen = {}
		if not inenv(sx, sz) or layer[idx(sx, sz)] ~= 1 then return seen end
		local stack = {{sx, sz}}
		seen[idx(sx, sz)] = true
		while #stack > 0 do
			local c = table.remove(stack)
			for m = 1, 4 do
				local x, z = c[1] + MOVES[m][1], c[2] + MOVES[m][2]
				if inenv(x, z) and layer[idx(x, z)] == 1 and not seen[idx(x, z)] then
					seen[idx(x, z)] = true
					stack[#stack + 1] = {x, z}
				end
			end
		end
		return seen
	end
	local function hits(seen, r)
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do
				if seen[idx(x, z)] then return true end
			end
		end
		return false
	end
	local a1, a2 = plan.approaches[1], plan.approaches[2]
	local sites = plan.sites
	for _, layer in ipairs({principal, road}) do
		local label = (layer == principal) and "principal network" or "pavement"
		for _, a in ipairs({a1, a2}) do
			local seen = flood(layer, a.pos.x, a.pos.z)
			if not seen[idx(a.pos.x, a.pos.z)] then
				return false, a.name .. " is not on " .. label
			end
			if not hits(seen, sites.market.rect) then
				return false, a.name .. " cannot reach the market on " .. label
			end
			if not hits(seen, sites.parvis.rect) then
				return false, a.name .. " cannot reach the parvis on " .. label
			end
			if not hits(seen, sites.castle.approach.edge) then
				return false, a.name .. " cannot reach the castle approach on " .. label
			end
			local other = (a == a1) and a2 or a1
			if not seen[idx(other.pos.x, other.pos.z)] then
				return false, "approaches are not connected on " .. label
			end
		end
	end
	local seen = flood(road, a1.pos.x, a1.pos.z)
	for _, s in ipairs(plan.streets) do
		if not seen[idx(s.rect.x1, s.rect.z1)] then
			return false, "street " .. s.id .. " is not connected to the network"
		end
	end

	-- Blocks and frontage.
	local taken = {}
	for _, b in ipairs(plan.blocks) do
		local r = b.rect
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do
				local i = idx(x, z)
				if not inenv(x, z) or inb[i] ~= 1 or reserved[i] == 1 or road[i] == 1
						or taken[i] then
					return false, ("block %d overlaps at (%d,%d)"):format(b.id, x, z)
				end
				taken[i] = true
			end
		end
	end
	for _, f in ipairs(plan.frontage) do
		local b = plan.blocks[f.block]
		if not b then return false, "frontage " .. f.id .. " has no block" end
		for z = f.rect.z1, f.rect.z2 do
			for x = f.rect.x1, f.rect.x2 do
				if not inenv(x + f.facing.x, z + f.facing.z)
						or road[idx(x + f.facing.x, z + f.facing.z)] ~= 1 then
					return false, "frontage " .. f.id .. " does not face a street"
				end
			end
		end
	end
	return true
end

return M
