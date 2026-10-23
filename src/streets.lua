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
-- 1. Principal streets are STREET_WIDTH (5) wide. A route is a shortest path
--    (Dijkstra with a turn penalty and seeded per-window noise as
--    tie-breaker) of STREET_WIDTH-square windows (an odd width, so the
--    approach mid() node is centred) that lie wholly inside the boundary and clear of the cathedral
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
--    With C.ROW_DEPTH (ticket #86, planner.depth_policy) streets keep a
--    building row's depth to squares, landmarks, the boundary edge and
--    (two rows) other roads: see gap_scan, the router penalty, the
--    secondary shift/shorten/reject and the final gate in fill().
--    Issue #122 judges spacing on the exposed edges of the COMBINED road
--    footprint (gap_scan's edge_runs), not per route rectangle, so how a route
--    is split into rectangles cannot change a verdict. Exemptions are
--    geometric and bounded: the first STREET_WIDTH positions of an edge beside
--    a concave corner (a real junction or a square), a street end cap, the
--    entrance transition of each exit (its window grown by one street width),
--    the landmark door windows and the castle gate apron. Routes and strips
--    that would run beside or overlap a road (a fully paved STREET_WIDTH + 1
--    square, wide_cells) are penalised or refused, so such routes share one
--    normal-width corridor; fill() rejects what is left.
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
-- Wide pavement (ticket #122)
------------------------------------------------------------------------
-- Road cells (layer Rd: streets only, not squares or the gate apron) covered
-- by a fully paved (width + 1) square window. A street is `width` wide
-- (5 principal, 4 secondary) and a junction, bend or crossing never fills a
-- (sw + 1) square, so any hit is redundant paving: two routes side by side or
-- overlapping with an offset. Returns the number of such cells and the first
-- one ({x, z}, local coordinates). Squares are not roads and so never count.
local function wide_cells(Rd, n, size)
	local count = make_count(Rd, n)
	local hit, first = {}, nil
	for z = 0, n - size do
		for x = 0, n - size do
			if count(x, z, x + size - 1, z + size - 1) == size * size then
				for zz = z, z + size - 1 do
					for xx = x, x + size - 1 do hit[zz * n + xx + 1] = true end
				end
				first = first or {x, z}
			end
		end
	end
	local total = 0
	for _ in pairs(hit) do total = total + 1 end
	return total, first
end

------------------------------------------------------------------------
-- Row-depth gaps (ticket #86)
------------------------------------------------------------------------
-- gap_scan(n, B, F, R, S, C) -> {ray, narrow, edge_runs} over n*n envelope-local
-- layers (flat, cell (x, z) at z * n + x + 1): B inside the boundary, F free
-- ground (inside the boundary, not a landmark), R pavement, S square-like
-- pavement (market, parvis, and the dedicated castle gate apron). The apron
-- uses the one-row square gap rule at its intentional road junction. The
-- layers are read live, so a caller that adds
-- streets to R sees them. A ray leaves a street side over open ground (free
-- and unpaved) and ends at pavement (road or square), a landmark, or the
-- boundary edge; the gap is narrow when it is shorter than the depth the
-- ending needs (C.ROAD_GAP two opposing rows, C.SQUARE_GAP / C.LANDMARK_GAP /
-- C.BOUNDARY_GAP one row). A gap of 0 is a street touching pavement or a
-- landmark (a wall of a landmark) is fine, but a street touching the boundary
-- edge with an empty outer side is not. Spacing is judged on the exposed edges
-- of the combined pavement (edge_runs, issue #122), not per rectangle. The
-- optional P marks a square that is planned but not paved yet (the parvis
-- while the first routes are laid): rays stop at it like at a square.
local function gap_scan(n, B, F, R, S, C, P)
	local sw = C.STREET_WIDTH
	local cap = C.ROAD_GAP
	local function idx(x, z) return z * n + x + 1 end
	local function ray(x, z, dx, dz)
		local g = 0
		while true do
			if x < 0 or z < 0 or x >= n or z >= n or B[idx(x, z)] == 0 then
				return g, "outside"
			end
			local i = idx(x, z)
			if R[i] == 1 then
				return g, (S[i] == 1) and "square" or "road"
			elseif P and P[i] == 1 then
				return g, "square"
			elseif F[i] == 0 then
				return g, "landmark"
			end
			g = g + 1
			if g >= cap then return g, nil end
			x, z = x + dx, z + dz
		end
	end

	-- True when a ray result is narrower than its ending needs.
	local function narrow(g, class)
		if class == nil then return false end
		if class == "outside" then return g < C.BOUNDARY_GAP end
		if g == 0 then return false end
		if class == "road" then return g < C.ROAD_GAP end
		if class == "square" then return g < C.SQUARE_GAP end
		return g < C.LANDMARK_GAP
	end

	-- Narrow runs along the EXPOSED edges of the combined road footprint (issue
	-- #122), independent of how routes are split into rectangles. Rd marks road
	-- cells (streets, not squares); an edge cell is a road cell whose neighbour
	-- in a direction is not pavement (R), so two roads that touch have no edge
	-- between them (that case is a wide band, see wide_cells). Edge cells of one
	-- direction and line form a segment. A position is exempt only where the
	-- geometry makes a real transition:
	--   * the first `sw` positions of a segment end at a concave corner (a
	--     junction with another road or a square);
	--   * a whole segment that is an end cap (convex at both ends and at most
	--     `sw` long: a street end, which cannot hold a frontage row);
	--   * positions inside an exemption zone (`zones`, local rects the caller
	--     keeps live: entrance windows of both exits, landmark door windows
	--     and the castle gate apron, each grown by `sw`).
	-- A rectangle endpoint that is not one of these is not an exemption. Only
	-- runs of at least MIN_FRONTAGE_RUN positions count (shorter slivers hold
	-- no frontage run). `win` ({x1, z1, x2, z2}) limits which edge cells are
	-- reported. Returns {dir, x1, z1, x2, z2, a1, a2} sorted by position, where
	-- a1..a2 are the coordinates along the edge.
	local DIRS = {{0, -1}, {0, 1}, {-1, 0}, {1, 0}}
	local function edge_runs(Rd, zones, win)
		local out = {}
		win = win or {x1 = 0, z1 = 0, x2 = n - 1, z2 = n - 1}
		local function inr(x, z) return x >= 0 and z >= 0 and x < n and z < n end
		local function source(x, z) return inr(x, z) and Rd[idx(x, z)] == 1 and S[idx(x, z)] == 0 end
		local function exposed(x, z, dx, dz)
			if not source(x, z) then return false end
			local nx, nz = x + dx, z + dz
			return not inr(nx, nz) or R[idx(nx, nz)] == 0
		end
		local function in_zone(x, z)
			for _, q in ipairs(zones or {}) do
				if x >= q.x1 and x <= q.x2 and z >= q.z1 and z <= q.z2 then
					return true
				end
			end
			return false
		end
		-- "concave" when the cell beyond a segment end is pavement that
		-- continues past the edge line (a junction), "convex" when it is not.
		local function end_kind(x, z, ex, ez)
			local px, pz = x + ex, z + ez
			if not inr(px, pz) or R[idx(px, pz)] == 0 then return "convex" end
			return "concave"
		end
		for di, d in ipairs(DIRS) do
			local dx, dz = d[1], d[2]
			local ex, ez = dz ~= 0 and 1 or 0, dx ~= 0 and 1 or 0
			local seen = {}
			for z = win.z1, win.z2 do
				for x = win.x1, win.x2 do
					if exposed(x, z, dx, dz) and not seen[idx(x, z)] then
						-- Segment start: walk back along the edge line.
						local sx, sz = x, z
						while exposed(sx - ex, sz - ez, dx, dz) do sx, sz = sx - ex, sz - ez end
						local cells = {}
						local cx, cz = sx, sz
						while exposed(cx, cz, dx, dz) do
							cells[#cells + 1] = {cx, cz}
							seen[idx(cx, cz)] = true
							cx, cz = cx + ex, cz + ez
						end
						local k1 = end_kind(sx, sz, -ex, -ez)
						local last = cells[#cells]
						local k2 = end_kind(last[1], last[2], ex, ez)
						if not (k1 == "convex" and k2 == "convex" and #cells <= sw) then
							local run
							local function close(last_i)
								if run and last_i - run + 1 >= C.MIN_FRONTAGE_RUN then
									local c1, c2 = cells[run], cells[last_i]
									if c2[1] >= win.x1 and c1[1] <= win.x2
											and c2[2] >= win.z1 and c1[2] <= win.z2 then
										out[#out + 1] = {dir = di, x1 = c1[1], z1 = c1[2],
											x2 = c2[1], z2 = c2[2],
											a1 = (ex ~= 0) and c1[1] or c1[2],
											a2 = (ex ~= 0) and c2[1] or c2[2]}
									end
								end
								run = nil
							end
							for i, c in ipairs(cells) do
								local nr = true
								if k1 == "concave" and i <= sw then nr = false end
								if k2 == "concave" and i > #cells - sw then nr = false end
								if nr and in_zone(c[1], c[2]) then nr = false end
								if nr then
									local g, class = ray(c[1] + dx, c[2] + dz, dx, dz)
									nr = narrow(g, class)
								end
								if nr then
									run = run or i
								else
									close(i - 1)
								end
							end
							close(#cells)
						end
					end
				end
			end
		end
		table.sort(out, function(p, q)
			if p.dir ~= q.dir then return p.dir < q.dir end
			if p.z1 ~= q.z1 then return p.z1 < q.z1 end
			if p.x1 ~= q.x1 then return p.x1 < q.x1 end
			return p.a2 < q.a2
		end)
		return out
	end

	return {ray = ray, narrow = narrow, edge_runs = edge_runs}
end

local function grow(r, k)
	return {x1 = r.x1 - k, z1 = r.z1 - k, x2 = r.x2 + k, z2 = r.z2 + k}
end

-- The street an edge run belongs to (for reports): the first street whose
-- rect holds both ends of the run, else the first holding its first cell.
local function run_owner(list, run, to_local)
	local function has(q, x, z) return x >= q.x1 and x <= q.x2 and z >= q.z1 and z <= q.z2 end
	local first
	for _, st in ipairs(list) do
		local q = to_local(st.rect)
		if has(q, run.x1, run.z1) then
			if has(q, run.x2, run.z2) then return st.id end
			first = first or st.id
		end
	end
	return first or 0
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
	-- City hall (profile plans): an obstacle beside the market (#106), neither free
	-- ground nor pavement, so no route or paving crosses its foundation.
	local hall = plan.sites.city_hall and lrect(plan.sites.city_hall.rect)
	if hall then set_rect(F, n, hall, 0) end
	local fcount = make_count(F, n)

	local market = lrect(plan.sites.market.rect)
	local parvis = lrect(plan.sites.parvis.rect)
	local pl = new_layer(n, 0)
	set_rect(pl, n, parvis, 1)
	local pcount = make_count(pl, n)

	-- R: pavement connected to the network so far (market, then streets).
	local R = new_layer(n, 0)
	set_rect(R, n, market, 1)
	if hall then set_rect(R, n, hall, 0) end
	local rcount = make_count(R, n)

	-- Row-depth policy (ticket #86). Active only when the planner supplied
	-- ROW_DEPTH (catalog-derived, planner.row_depth); legacy plans skip it.
	-- B: inside the boundary; S: square-like pavement (market, parvis, apron).
	-- A ray leaves a street side over open ground (free, unpaved) and ends at
	-- pavement (road or square), a landmark, or the boundary edge; the gap is
	-- narrow when it is shorter than the depth the ending needs: two opposing
	-- rows between roads, one row to a square, landmark or boundary edge.
	local depth = C.ROW_DEPTH
	local B, S
	if depth then
		B = new_layer(n, 0)
		for _, r in ipairs(plan.boundary.rects) do set_rect(B, n, lrect(r), 1) end
		S = new_layer(n, 0)
		set_rect(S, n, market, 1)
		set_rect(S, n, parvis, 1)
	end
	-- Rd: road cells only (streets, no squares or apron), for the exposed-edge
	-- scan and the wide-pavement check (issue #122); zones: local rects around
	-- the exits, landmark doors and gate apron that exempt their ends.
	local Rd = new_layer(n, 0)
	local rdcount = make_count(Rd, n)
	local zones = {}
	local gap
	if depth then gap = gap_scan(n, B, F, R, S, C, pl) end
	local ray, narrow = gap and gap.ray, gap and gap.narrow

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

	-- Whether a window at (x, z) moving in direction m (MOVES index) lies
	-- narrowly beside open ground bounded by pavement, a landmark or the
	-- boundary edge on either long side. Memoised per route() call.
	local side_memo = {}
	local function side_narrow(x, z, m)
		local key = (z * n + x) * 4 + (m <= 2 and 0 or 1)
		local v = side_memo[key]
		if v == nil then
			local mid = math.floor((sw - 1) / 2)
			v = false
			if m <= 2 then
				local g, c = ray(x + mid, z - 1, 0, -1)
				if narrow(g, c) then v = true end
				if not v then
					g, c = ray(x + mid, z + sw, 0, 1)
					if narrow(g, c) then v = true end
				end
			else
				local g, c = ray(x - 1, z + mid, -1, 0)
				if narrow(g, c) then v = true end
				if not v then
					g, c = ray(x + sw, z + mid, 1, 0)
					if narrow(g, c) then v = true end
				end
			end
			side_memo[key] = v
		end
		return v
	end

	-- Whether stepping the window from (x, z) to (nx, nz) (move m) would make
	-- fully paved (sw + 1) squares with the roads laid so far: the route would
	-- hug an existing road instead of joining it. Memoised per route() call.
	local wide_memo = {}
	local function wide_step(x, z, nx, nz, m)
		local key = (z * n + x) * 4 + m
		local v = wide_memo[key]
		if v ~= nil then return v end
		v = false
		local size = sw + 1
		local bx1, bz1 = math.min(x, nx), math.min(z, nz)
		local bx2, bz2 = math.max(x, nx) + sw - 1, math.max(z, nz) + sw - 1
		local function cnt(x1, z1, x2, z2)
			if x1 < 0 then x1 = 0 end
			if z1 < 0 then z1 = 0 end
			if x2 > n - 1 then x2 = n - 1 end
			if z2 > n - 1 then z2 = n - 1 end
			if x2 < x1 or z2 < z1 then return 0 end
			return rdcount(x1, z1, x2, z2)
		end
		if cnt(bx1 - 1, bz1 - 1, bx2 + 1, bz2 + 1) > 0 then
			local P = {x1 = x, z1 = z, x2 = x + sw - 1, z2 = z + sw - 1}
			local W = {x1 = nx, z1 = nz, x2 = nx + sw - 1, z2 = nz + sw - 1}
			local function clip(a, b)
				local r = {x1 = math.max(a.x1, b.x1), z1 = math.max(a.z1, b.z1),
					x2 = math.min(a.x2, b.x2), z2 = math.min(a.z2, b.z2)}
				if r.x2 < r.x1 or r.z2 < r.z1 then return nil end
				return r
			end
			local function area(r) return r and (r.x2 - r.x1 + 1) * (r.z2 - r.z1 + 1) or 0 end
			local function rd(r) return r and cnt(r.x1, r.z1, r.x2, r.z2) or 0 end
			for wz = bz1 - size + 1, bz2 do
				for wx = bx1 - size + 1, bx2 do
					if wx >= 0 and wz >= 0 and wx + size <= n and wz + size <= n then
						local win = {x1 = wx, z1 = wz, x2 = wx + size - 1, z2 = wz + size - 1}
						local pw, ww = clip(P, win), clip(W, win)
						local pww = pw and ww and clip(pw, ww)
						local have = rd(win) + area(pw) + area(ww) - area(pww)
							- rd(pw) - rd(ww) + rd(pww)
						if have == size * size then v = true; break end
					end
				end
				if v then break end
			end
		end
		wide_memo[key] = v
		return v
	end

	-- Dijkstra over window top-left corners. State = (x, z, last move).
	-- Returns a list of {x, z} windows or nil.
	local function route(sources, goal, pos, avoid_parvis, inside)
		local salt = rng.int(1, 1000000)
		side_memo, wide_memo = {}, {}
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
						if depth and rc ~= full and side_narrow(nx, nz, m) then
							step = step + C.NARROW_PENALTY
						end
						if depth and rc ~= full and wide_step(x, z, nx, nz, m) then
							step = step + C.WIDE_PENALTY
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
			set_rect(Rd, n, r, 1)
		end
		rcount = make_count(R, n)
		rdcount = make_count(Rd, n)
	end

	local function centre(site) return {x = site.approach.pos.x - ox, z = site.approach.pos.z - oz} end

	local sites = plan.sites
	-- Exemption zones: both exits' entrance windows and the doors of the
	-- landmarks (the castle gate apron is added below).
	for _, a in ipairs(plan.approaches) do zones[#zones + 1] = grow(lrect(a.edge), sw) end
	for _, name in ipairs({"castle", "cathedral"}) do
		local p = centre(sites[name])
		local h = math.floor((sw - 1) / 2)
		zones[#zones + 1] = {x1 = p.x - h, z1 = p.z - h, x2 = p.x + h, z2 = p.z + h}
	end
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

	-- The corridor must cover the node in front of the castle door: only
	-- windows containing approach.pos are goals.
	local cpos = centre(sites.castle)
	local cgoal = {x1 = cpos.x, z1 = cpos.z, x2 = cpos.x, z2 = cpos.z}
	path = route(network_sources(), cgoal, cpos, true)
	if not path then return nil, "no street-wide route from the network to the castle approach" end
	pave(path, "network>castle")
	-- The castle gate is six nodes wide; the normal-width route reaches its
	-- centre, then a short apron covers the complete authored opening.
	local gate_apron = sites.castle.gate_apron
	local gate_apron_local
	if gate_apron then
		local ar = lrect(gate_apron)
		for z = ar.z1, ar.z2 do
			for x = ar.x1, ar.x2 do
				if x < 0 or z < 0 or x >= n or z >= n or F[idx(x, z)] ~= 1 then
					return nil, "castle gate apron conflicts with a reservation or boundary"
				end
			end
		end
		gate_apron_local = ar
		zones[#zones + 1] = ar
		set_rect(R, n, ar, 1)
		if S then set_rect(S, n, ar, 1) end
		rcount = make_count(R, n)
	end

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

	-- Narrow runs that paving the strip r (running along `axis`) would
	-- create on the combined footprint: along its own sides and along the
	-- edges of other roads that now face it (a run is new unless the roads
	-- laid so far already had it). Returns {a1, a2} runs in coordinates along
	-- the axis, and true when a new run is not parallel to the strip, which
	-- trimming the strip cannot cure.
	local function narrow_runs(r, axis)
		if not depth then return {} end
		local cap = C.ROAD_GAP
		local win = {x1 = math.max(0, r.x1 - cap), z1 = math.max(0, r.z1 - cap),
			x2 = math.min(n - 1, r.x2 + cap), z2 = math.min(n - 1, r.z2 + cap)}
		local before = gap.edge_runs(Rd, zones, win)
		set_rect(R, n, r, 1)
		set_rect(Rd, n, r, 1)
		local after = gap.edge_runs(Rd, zones, win)
		set_rect(R, n, r, 0)
		set_rect(Rd, n, r, 0)
		local out, perpendicular = {}, false
		for _, run in ipairs(after) do
			local known = false
			for _, b in ipairs(before) do
				if b.dir == run.dir and b.a1 <= run.a1 and b.a2 >= run.a2
						and ((run.dir <= 2 and b.z1 == run.z1) or (run.dir > 2 and b.x1 == run.x1)) then
					known = true
					break
				end
			end
			if not known then
				if (run.dir <= 2) == (axis == "x") then
					out[#out + 1] = {a1 = run.a1, a2 = run.a2}
				else
					perpendicular = true
				end
			end
		end
		return out, perpendicular
	end

	-- Whether paving the strip r beside the roads laid so far would make a
	-- fully paved (sw + 1) square, i.e. parallel paving instead of one corridor.
	local function strip_wide(r)
		if not depth then return false end
		local size = sw + 1
		for wz = math.max(0, r.z1 - size + 1), math.min(n - size, r.z2) do
			for wx = math.max(0, r.x1 - size + 1), math.min(n - size, r.x2) do
				local ix1, iz1 = math.max(wx, r.x1), math.max(wz, r.z1)
				local ix2, iz2 = math.min(wx + size - 1, r.x2), math.min(wz + size - 1, r.z2)
				local inside = (ix2 >= ix1 and iz2 >= iz1) and (ix2 - ix1 + 1) * (iz2 - iz1 + 1) or 0
				if rdcount(wx, wz, wx + size - 1, wz + size - 1) + inside == size * size then
					return true
				end
			end
		end
		return false
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
		local function build(b1)
		local lo, hi = along, along
		while ok_col(lo - 1, b1) do lo = lo - 1 end
		while ok_col(hi + 1, b1) do hi = hi + 1 end
		if hi - lo + 1 < C.MIN_SECONDARY_LEN then return nil end
		-- Both long sides must be mostly free land or pavement, not the
		-- boundary edge or a landmark (no edge-hugging streets).
		for _, side_b in ipairs({b1 - 1, b1 + nw}) do
			local bad = 0
			for a = lo, hi do
				local x, z = a, side_b
				if axis == "z" then x, z = side_b, a end
				if not (x >= 0 and z >= 0 and x < n and z < n) or F[idx(x, z)] == 0 then
					bad = bad + 1
				end
			end
			if bad > C.MAX_EDGE_FRACTION * (hi - lo + 1) then return nil end
		end
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
		local t_lo, t_hi = touches(lo - 1), touches(hi + 1)
		if not (t_lo or t_hi) then return nil end
		-- Depth policy: shorten the free end back to before the first narrow
		-- run; a strip that joins roads at both ends, or that would be left
		-- shorter than MIN_SECONDARY_LEN, is rejected.
		while depth do
			local rect = (axis == "x")
				and {x1 = lo, z1 = b1, x2 = hi, z2 = b1 + nw - 1}
				or {x1 = b1, z1 = lo, x2 = b1 + nw - 1, z2 = hi}
			local runs, perpendicular = narrow_runs(rect, axis)
			if perpendicular then return nil end
			if #runs == 0 then break end
			if t_lo and t_hi then return nil end
			if t_lo then
				local first = runs[1].a1
				for _, run in ipairs(runs) do first = math.min(first, run.a1) end
				hi = first - 1
			else
				local last = runs[1].a2
				for _, run in ipairs(runs) do last = math.max(last, run.a2) end
				lo = last + 1
			end
			if hi - lo + 1 < C.MIN_SECONDARY_LEN then return nil end
		end
		local result
		if axis == "x" then
			result = {x1 = lo, z1 = b1, x2 = hi, z2 = b1 + nw - 1}
		else
			result = {x1 = b1, z1 = lo, x2 = b1 + nw - 1, z2 = hi}
		end
		if strip_wide(result) then return nil end
		return result
		end

		-- The strip normally passes through the worst cell at offsets
		-- -1, -2, 0, -3. With the depth policy, wider shifts are tried too:
		-- a strip nearby that clears the narrow gaps beats no street.
		local offs = {-1, -2, 0, -3}
		if depth then
			for k = 4, 12 do
				offs[#offs + 1] = -k
				offs[#offs + 1] = k - 3
			end
		end
		for _, off in ipairs(offs) do
			if ok_col(along, cross + off) then
				local r = build(cross + off)
				if r or not depth then return r end
			end
		end
		return nil
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
			set_rect(Rd, n, r, 1)
			rdcount = make_count(Rd, n)
			added = added + 1
			dist = nil
		else
			-- A cell with no strip means its neighbours have none either
			-- (same free lines, no road at their ends): skip a square so
			-- the bounded tries are not spent one cell at a time.
			local k = C.SECONDARY_FAIL_SKIP or 0
			for zz = math.max(0, c[2] - k), math.min(n - 1, c[2] + k) do
				for xx = math.max(0, c[1] - k), math.min(n - 1, c[1] + k) do
					skip[idx(xx, zz)] = true
				end
			end
		end
	end

	-- Depth policy gate: no street may keep a run of narrow ground beside it
	-- (the router and the secondary pass avoid and shorten these; what is
	-- left makes the attempt fail so the planner retries).
	if depth then
		local runs = gap.edge_runs(Rd, zones)
		if #runs > 0 then
			local owner_id = run_owner(streets, runs[1], lrect)
			return nil, ("street %d keeps a strip too narrow for a building row (%d,%d to %d,%d)")
				:format(owner_id, runs[1].x1 + ox, runs[1].z1 + oz, runs[1].x2 + ox, runs[1].z2 + oz)
		end
		if wide_cells(Rd, n, sw + 1) > 0 then
			return nil, "parallel routes were not consolidated into one corridor"
		end
	end
	if gate_apron_local then
		-- Reserve this dedicated pavement before block carving, after street
		-- spacing checks; R already records it for routing and the depth gate.
		set_rect(F, n, gate_apron_local, 0)
	end

	local U = new_layer(n, 0)
	for z = 0, n - 1 do
		for x = 0, n - 1 do
			if F[idx(x, z)] == 1 and R[idx(x, z)] == 0 then U[idx(x, z)] = 1 end
		end
	end
	local minside = C.MIN_BLOCK_SIDE
	local cand_blocks = {}
	-- Calls emit(rect) for every maximal all-U rectangle at least minside
	-- on both sides (largest-rectangle-in-histogram scan, row by row).
	local function scan_rects(emit)
		local h = {}
		for x = 0, n - 1 do h[x] = 0 end
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
					if hh >= minside and w >= minside then
						emit({x1 = s, z1 = z - hh + 1, x2 = x - 1, z2 = z})
					end
					start = s
				end
				if cur > 0 then
					sp = sp + 1
					sx[sp], sh[sp] = start, cur
				end
			end
		end
	end

	-- Depth policy: cells of unassigned free ground that a candidate block
	-- would leave as a sliver between its edge and pavement, shallower than
	-- one building row (so no frontage run can ever use it).
	local function sliver_cells(r)
		local total = 0
		local function probe(x, z, dx, dz)
			local steps = 0
			while steps < depth - 1 do
				x, z = x + dx, z + dz
				if x < 0 or z < 0 or x >= n or z >= n then return 0 end
				local i = idx(x, z)
				if U[i] == 1 then
					steps = steps + 1
				elseif R[i] == 1 then
					return steps
				else
					return 0
				end
			end
			return 0
		end
		for x = r.x1, r.x2 do
			total = total + probe(x, r.z1, 0, -1) + probe(x, r.z2, 0, 1)
		end
		for z = r.z1, r.z2 do
			total = total + probe(r.x1, z, -1, 0) + probe(r.x2, z, 1, 0)
		end
		return total
	end

	for _ = 1, C.MAX_BLOCK_SCAN do
		local best_area, best
		scan_rects(function(r)
			local a = (r.x2 - r.x1 + 1) * (r.z2 - r.z1 + 1)
			if best_area == nil or a > best_area then best_area, best = a, r end
		end)
		if not best then break end
		if depth then
			-- Prefer, among nearly-as-large rectangles, the one that leaves
			-- the least sliver ground behind (ties keep the scan order).
			local floor_area = 0.6 * best_area
			local best_score = best_area - C.SLIVER_WEIGHT * sliver_cells(best)
			scan_rects(function(r)
				local a = (r.x2 - r.x1 + 1) * (r.z2 - r.z1 + 1)
				if a >= floor_area then
					local score = a - C.SLIVER_WEIGHT * sliver_cells(r)
					if score > best_score then best_score, best = score, r end
				end
			end)
		end
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
	if hall then
		for z = hall.z1, hall.z2 do
			for x = hall.x1, hall.x2 do owner[idx(x, z)] = nil end
		end
	end
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

	-- (planner.plan runs the full validate as its final accept gate.)
	if #blocks < C.MIN_BLOCKS then
		return nil, ("only %d blocks with street frontage (need %d)"):format(#blocks, C.MIN_BLOCKS)
	end
	return plan
end

------------------------------------------------------------------------
-- Narrow gaps and wide pavement of a finished plan (tickets #86, #122)
------------------------------------------------------------------------
-- Pavement layers of a plan, rebuilt from its rects (envelope-local).
local function plan_layers(plan, C)
	local n = C.ENVELOPE
	local ox, oz = plan.envelope.x1, plan.envelope.z1
	local function lr(r) return shift(r, -ox, -oz) end
	local B, F, R, S, Rd = new_layer(n, 0), new_layer(n, 0), new_layer(n, 0),
		new_layer(n, 0), new_layer(n, 0)
	for _, r in ipairs(plan.boundary.rects) do
		set_rect(B, n, lr(r), 1)
		set_rect(F, n, lr(r), 1)
	end
	for _, name in ipairs({"cathedral", "castle", "city_hall"}) do
		if plan.sites[name] then set_rect(F, n, lr(plan.sites[name].rect), 0) end
	end
	for _, name in ipairs({"market", "parvis"}) do
		set_rect(R, n, lr(plan.sites[name].rect), 1)
		set_rect(S, n, lr(plan.sites[name].rect), 1)
	end
	local hall = plan.sites.city_hall
	if hall then set_rect(R, n, lr(hall.rect), 0) end
	for _, st in ipairs(plan.streets) do
		set_rect(R, n, lr(st.rect), 1)
		set_rect(Rd, n, lr(st.rect), 1)
	end
	local zones = {}
	for _, a in ipairs(plan.approaches or {}) do
		zones[#zones + 1] = grow(lr(a.edge), C.STREET_WIDTH)
	end
	for _, name in ipairs({"castle", "cathedral"}) do
		local p = plan.sites[name] and plan.sites[name].approach and plan.sites[name].approach.pos
		if p then
			local h = math.floor((C.STREET_WIDTH - 1) / 2)
			zones[#zones + 1] = lr({x1 = p.x - h, z1 = p.z - h, x2 = p.x + h, z2 = p.z + h})
		end
	end
	local apron = plan.sites.castle and plan.sites.castle.gate_apron
	if apron then
		set_rect(R, n, lr(apron), 1)
		set_rect(S, n, lr(apron), 1)
		zones[#zones + 1] = lr(apron)
	end
	return {n = n, ox = ox, oz = oz, lr = lr, B = B, F = F, R = R, S = S, Rd = Rd, zones = zones}
end

-- Returns a list of {street = id, a1, a2, x1, z1, x2, z2} for runs along the
-- exposed edges of the combined road footprint that are too shallow for a
-- building row (see gap_scan), measured against the plan's streets, squares,
-- gate apron, landmarks and boundary. The verdict depends only on the paved
-- cells, not on how the streets are split into rectangles. `street` is the
-- street owning the run's first cell and a1..a2 the absolute coordinates along
-- the edge. Needs the depth policy constants (C.ROW_DEPTH and friends,
-- planner.depth_policy); returns an empty list without them. Exemptions are the
-- geometric ones of gap_scan's edge_runs. Used by the regression fixtures.
function M.narrow_gaps(plan, C)
	local out = {}
	if not C.ROW_DEPTH then return out end
	local L = plan_layers(plan, C)
	local gap = gap_scan(L.n, L.B, L.F, L.R, L.S, C)
	for _, run in ipairs(gap.edge_runs(L.Rd, L.zones)) do
		local owner = run_owner(plan.streets, run, L.lr)
		local off = (run.dir <= 2) and L.ox or L.oz
		out[#out + 1] = {street = owner, a1 = run.a1 + off, a2 = run.a2 + off,
			x1 = run.x1 + L.ox, z1 = run.z1 + L.oz, x2 = run.x2 + L.ox, z2 = run.z2 + L.oz}
	end
	return out
end

-- Number of street cells (squares and the gate apron excluded) that lie in a
-- fully paved (STREET_WIDTH + 1) square: redundant parallel or overlapping
-- paving where one normal-width corridor would do (issue #122). A junction,
-- bend or crossing of normal streets never fills such a square. Returns the
-- count and the first window's absolute {x, z}.
function M.wide_pavement(plan, C)
	local L = plan_layers(plan, C)
	local total, first = wide_cells(L.Rd, L.n, C.STREET_WIDTH + 1)
	return total, first and {x = first[1] + L.ox, z = first[2] + L.oz}
end

------------------------------------------------------------------------
-- Validation (uses only plan data; rebuilds occupancy from the rects)
------------------------------------------------------------------------
local function is_int(v) return type(v) == "number" and v == math.floor(v) and v == v end

local function is_rect(r)
	return type(r) == "table" and is_int(r.x1) and is_int(r.z1) and is_int(r.x2)
		and is_int(r.z2) and r.x1 <= r.x2 and r.z1 <= r.z2
end

-- Returns true, or false plus a reason. Shape checks come first so malformed
-- street/block/frontage entries are rejected cleanly (planner.validate also
-- guards the call with pcall as a backstop).
function M.validate(plan, C)
	local function bad(msg) return false, "malformed plan: " .. msg end
	if type(plan) ~= "table" then return bad("plan is not a table") end
	if not is_rect(plan.envelope) then return bad("plan has no envelope") end
	if type(plan.boundary) ~= "table" or type(plan.boundary.rects) ~= "table" then
		return bad("plan has no boundary rects")
	end
	for i, r in ipairs(plan.boundary.rects) do
		if not is_rect(r) then return bad("boundary rect " .. i .. " is malformed") end
	end
	if type(plan.sites) ~= "table" then return bad("plan has no sites") end
	for _, name in ipairs({"cathedral", "parvis", "market", "castle"}) do
		local st = plan.sites[name]
		if type(st) ~= "table" or not is_rect(st.rect) or type(st.approach) ~= "table"
				or type(st.approach.pos) ~= "table" or not is_int(st.approach.pos.x)
				or not is_int(st.approach.pos.z) or not is_rect(st.approach.edge) then
			return bad("site " .. name .. " is missing or malformed")
		end
	end
	local castle_site = plan.sites.castle
	if castle_site.gate_span ~= nil or castle_site.gate_apron ~= nil then
		if not is_rect(castle_site.gate_span) or not is_rect(castle_site.gate_apron) then
			return bad("castle gate span or apron is malformed")
		end
		local gs = castle_site.gate_span
		local sx, sz = gs.x2 - gs.x1 + 1, gs.z2 - gs.z1 + 1
		if type(castle_site.facing) ~= "table"
				or not ((castle_site.facing.x == 0 and (castle_site.facing.z == -1 or castle_site.facing.z == 1))
					or (castle_site.facing.z == 0 and (castle_site.facing.x == -1 or castle_site.facing.x == 1))) then
			return bad("castle gate facing is malformed")
		end
		local r, f = castle_site.rect, castle_site.facing
		if f.x == 0 then
			if sx ~= 6 or sz ~= 1 or gs.z1 ~= gs.z2
					or gs.x1 < r.x1 or gs.x2 > r.x2
					or (f.z < 0 and gs.z1 ~= r.z1) or (f.z > 0 and gs.z2 ~= r.z2) then
				return bad("castle gate span is not a six-node line on the outer facing wall")
			end
		else
			if sx ~= 1 or sz ~= 6 or gs.x1 ~= gs.x2
					or gs.z1 < r.z1 or gs.z2 > r.z2
					or (f.x < 0 and gs.x1 ~= r.x1) or (f.x > 0 and gs.x2 ~= r.x2) then
				return bad("castle gate span is not a six-node line on the outer facing wall")
			end
		end
	end
	if type(plan.approaches) ~= "table" or #plan.approaches < 2 then
		return bad("plan needs two approaches")
	end
	for i = 1, 2 do
		local a = plan.approaches[i]
		if type(a) ~= "table" or type(a.pos) ~= "table" or not is_int(a.pos.x)
				or not is_int(a.pos.z) or not is_rect(a.edge)
				or type(a.side) ~= "string" or type(a.name) ~= "string" then
			return bad("approach " .. i .. " is malformed")
		end
	end
	if type(C) ~= "table" or type(C.ENVELOPE) ~= "number" then
		return bad("constants are missing")
	end
	if type(plan.streets) ~= "table" or #plan.streets == 0 then
		return bad("plan has no streets")
	end
	if type(plan.blocks) ~= "table" or type(plan.frontage) ~= "table" then
		return bad("plan has no blocks or frontage lists")
	end
	for i, s in ipairs(plan.streets) do
		if type(s) ~= "table" or not is_rect(s.rect) then
			return bad("street " .. i .. " has no valid rect")
		end
		if s.kind ~= "principal" and s.kind ~= "secondary" then
			return bad("street " .. i .. " has unknown kind")
		end
	end
	for i, b in ipairs(plan.blocks) do
		if type(b) ~= "table" or not is_rect(b.rect) or type(b.frontage) ~= "table" then
			return bad("block " .. i .. " is malformed")
		end
	end
	for i, f in ipairs(plan.frontage) do
		if type(f) ~= "table" or not is_rect(f.rect) or type(f.facing) ~= "table"
				or type(f.side) ~= "string" then
			return bad("frontage " .. i .. " is malformed")
		end
	end

	local n = C.ENVELOPE
	local ox, oz = plan.envelope.x1, plan.envelope.z1
	local function inenv(x, z) return x >= ox and z >= oz and x < ox + n and z < oz + n end
	local function idx(x, z) return (z - oz) * n + (x - ox) + 1 end
	local sites = plan.sites
	local sw = C.STREET_WIDTH

	local inb = new_layer(n, 0)
	for _, r in ipairs(plan.boundary.rects) do set_rect(inb, n, shift(r, -ox, -oz), 1) end
	local reserved = new_layer(n, 0)
	set_rect(reserved, n, shift(sites.cathedral.rect, -ox, -oz), 1)
	set_rect(reserved, n, shift(sites.castle.rect, -ox, -oz), 1)
	local hall = sites.city_hall and shift(sites.city_hall.rect, -ox, -oz)
	if hall then set_rect(reserved, n, hall, 1) end

	-- owner[i]: "market" | "parvis" | street id (squares first, then streets
	-- in id order); mats[owner] is its material.
	local owner, road, principal = {}, new_layer(n, 0), new_layer(n, 0)
	local mats = {}
	for _, name in ipairs({"market", "parvis"}) do
		if sites[name].material ~= C.SQUARE_MATERIAL then
			return false, name .. " material missing"
		end
		mats[name] = sites[name].material
		local r = shift(sites[name].rect, -ox, -oz)
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do
				local i = z * n + x + 1
				-- The city hall lies outside the market (#106); guard only.
				if not (hall and name == "market"
						and x >= hall.x1 and x <= hall.x2
						and z >= hall.z1 and z <= hall.z2) then
					road[i], principal[i] = 1, 1
					if owner[i] == nil then owner[i] = name end
				end
			end
		end
	end
	for i, s in ipairs(plan.streets) do
		local r = s.rect
		local ex, ez = r.x2 - r.x1 + 1, r.z2 - r.z1 + 1
		local want = (s.kind == "principal") and C.STREET_WIDTH or C.SECONDARY_WIDTH
		if s.id ~= i then return false, "street " .. i .. " has wrong id" end
		if s.width ~= want or math.min(ex, ez) ~= want then
			return false, ("street %d is %dx%d, expected width %d"):format(i, ex, ez, want)
		end
		local axis = (ez > ex) and "z" or "x"
		if s.axis ~= axis then return false, "street " .. i .. " axis" end
		local mat = (s.kind == "principal") and C.PRINCIPAL_MATERIAL or C.SECONDARY_MATERIAL
		if s.material ~= mat then return false, "street " .. i .. " material" end
		mats[i] = mat
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do
				if not inenv(x, z) or inb[idx(x, z)] ~= 1 then
					return false, ("street %d leaves the boundary at (%d,%d)"):format(i, x, z)
				end
				local k = idx(x, z)
				if reserved[k] == 1 then
					return false, ("street %d crosses a landmark at (%d,%d)"):format(i, x, z)
				end
				road[k] = 1
				if s.kind == "principal" then principal[k] = 1 end
				if owner[k] == nil then owner[k] = i end
			end
		end
	end
	if sites.castle.gate_apron then
		local apron = sites.castle.gate_apron
		for z = apron.z1, apron.z2 do
			for x = apron.x1, apron.x2 do
				if not inenv(x, z) or inb[idx(x, z)] ~= 1 or reserved[idx(x, z)] == 1 then
					return false, "castle gate apron leaves clear boundary"
				end
				local k = idx(x, z)
				road[k], principal[k], owner[k] = 1, 1, "castle_gate_apron"
			end
		end
		mats.castle_gate_apron = C.PRINCIPAL_MATERIAL
	end
	if sites.castle.gate_span or sites.castle.gate_apron then
		local span, apron = sites.castle.gate_span, sites.castle.gate_apron
		local f = sites.castle.facing
		if (f.x ~= 0 and (span.z1 < apron.z1 or span.z2 > apron.z2))
				or (f.z ~= 0 and (span.x1 < apron.x1 or span.x2 > apron.x2)) then
			return false, "castle gate apron does not cover the full opening span"
		end
		local r = sites.castle.rect
		if f.z < 0 then
			if span.z1 ~= r.z1 or apron.z2 ~= r.z1 - 1 then return false, "castle gate apron is not outside the gate wall" end
		elseif f.z > 0 then
			if span.z2 ~= r.z2 or apron.z1 ~= r.z2 + 1 then return false, "castle gate apron is not outside the gate wall" end
		elseif f.x < 0 then
			if span.x1 ~= r.x1 or apron.x2 ~= r.x1 - 1 then return false, "castle gate apron is not outside the gate wall" end
		elseif span.x2 ~= r.x2 or apron.x1 ~= r.x2 + 1 then
			return false, "castle gate apron is not outside the gate wall"
		end
		local apron_x, apron_z = apron.x2 - apron.x1 + 1, apron.z2 - apron.z1 + 1
		local expected_apron
		if f.x ~= 0 then expected_apron = apron_x == 5 and apron_z == 6
		else expected_apron = apron_x == 6 and apron_z == 5 end
		if not expected_apron then return false, "castle gate apron has unexpected dimensions" end
		local p = sites.castle.approach.pos
		if p.x < apron.x1 or p.x > apron.x2 or p.z < apron.z1 or p.z > apron.z2 then
			return false, "castle approach does not enter the gate apron"
		end
		for z = apron.z1, apron.z2 do
			for x = apron.x1, apron.x2 do
				if not inenv(x, z) or inb[idx(x, z)] ~= 1 or reserved[idx(x, z)] == 1
						or principal[idx(x, z)] ~= 1 then
					return false, "castle gate apron is not fully paved inside clear boundary"
				end
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
	-- Fully paved sw x sw windows reachable from an approach window.
	local function window_walk(layer, a)
		local count = make_count(layer, n)
		local e = shift(a.edge, -ox, -oz)
		local wx, wz = e.x1, e.z1
		if a.side == "+z" then wz = e.z2 - sw + 1 elseif a.side == "+x" then wx = e.x2 - sw + 1 end
		local seen = {}
		local function full(x, z)
			return x >= 0 and z >= 0 and x + sw <= n and z + sw <= n
				and count(x, z, x + sw - 1, z + sw - 1) == sw * sw
		end
		if not full(wx, wz) then return seen end
		local queue, head = {{wx, wz}}, 1
		seen[wz * n + wx] = true
		while head <= #queue do
			local c = queue[head]
			head = head + 1
			for m = 1, 4 do
				local x, z = c[1] + MOVES[m][1], c[2] + MOVES[m][2]
				if not seen[z * n + x] and full(x, z) then
					seen[z * n + x] = true
					queue[#queue + 1] = {x, z}
				end
			end
		end
		return seen
	end
	local function covered(seen, p)
		local lx, lz = p.x - ox, p.z - oz
		for z = math.max(0, lz - sw + 1), math.min(lz, n - sw) do
			for x = math.max(0, lx - sw + 1), math.min(lx, n - sw) do
				if seen[z * n + x] then return true end
			end
		end
		return false
	end

	local a1, a2 = plan.approaches[1], plan.approaches[2]
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
			local other = (a == a1) and a2 or a1
			if not seen[idx(other.pos.x, other.pos.z)] then
				return false, "approaches are not connected on " .. label
			end
		end
	end
	-- Full-width corridors to every door/approach node, from both approaches.
	for _, a in ipairs({a1, a2}) do
		local seen = window_walk(principal, a)
		-- (market/parvis approach.pos lies outside the square: only a
		-- preferred attachment point, so not required here.)
		for _, name in ipairs({"cathedral", "castle"}) do
			if not covered(seen, sites[name].approach.pos) then
				return false, ("%s has no fully paved %d-wide route to the %s approach")
					:format(a.name, sw, name)
			end
		end
	end
	local seen = flood(road, a1.pos.x, a1.pos.z)
	for i, s in ipairs(plan.streets) do
		if not seen[idx(s.rect.x1, s.rect.z1)] then
			return false, "street " .. i .. " is not connected to the network"
		end
	end
	if sites.castle.gate_apron then
		local connected = flood(principal, a1.pos.x, a1.pos.z)
		local apron = sites.castle.gate_apron
		for z = apron.z1, apron.z2 do
			for x = apron.x1, apron.x2 do
				if not connected[idx(x, z)] then return false, "castle gate apron is disconnected from the principal route" end
			end
		end
	end

	-- Street ends: no dead-end principal streets; secondaries join the network.
	local function other_pavement(x, z, i)
		local s = plan.streets[i]
		if x >= s.rect.x1 and x <= s.rect.x2 and z >= s.rect.z1 and z <= s.rect.z2 then
			return false
		end
		return inenv(x, z) and road[idx(x, z)] == 1
	end
	local function covered_by_other(x, z, i)
		for _, name in ipairs({"market", "parvis"}) do
			local q = sites[name].rect
			if x >= q.x1 and x <= q.x2 and z >= q.z1 and z <= q.z2 then return true end
		end
		for j, t in ipairs(plan.streets) do
			local q = t.rect
			if j ~= i and x >= q.x1 and x <= q.x2 and z >= q.z1 and z <= q.z2 then
				return true
			end
		end
		return false
	end
	for i, s in ipairs(plan.streets) do
		local r = s.rect
		local ex, ez = r.x2 - r.x1 + 1, r.z2 - r.z1 + 1
		local faces = {}
		-- Each face is the cells just outside an end plus the end row itself
		-- (another street may overlap the end, as at a bend).
		local function face(x1, z1, x2, z2, ix1, iz1, ix2, iz2)
			local cells = {}
			for z = z1, z2 do
				for x = x1, x2 do cells[#cells + 1] = {x, z} end
			end
			local inner = {}
			for z = iz1, iz2 do
				for x = ix1, ix2 do inner[#inner + 1] = {x, z} end
			end
			faces[#faces + 1] = {cells = cells, inner = inner}
		end
		if ex > ez then
			face(r.x1 - 1, r.z1, r.x1 - 1, r.z2, r.x1, r.z1, r.x1, r.z2)
			face(r.x2 + 1, r.z1, r.x2 + 1, r.z2, r.x2, r.z1, r.x2, r.z2)
		elseif ez > ex then
			face(r.x1, r.z1 - 1, r.x2, r.z1 - 1, r.x1, r.z1, r.x2, r.z1)
			face(r.x1, r.z2 + 1, r.x2, r.z2 + 1, r.x1, r.z2, r.x2, r.z2)
		else
			face(r.x1 - 1, r.z1, r.x1 - 1, r.z2, r.x1, r.z1, r.x1, r.z2)
			face(r.x2 + 1, r.z1, r.x2 + 1, r.z2, r.x2, r.z1, r.x2, r.z2)
			face(r.x1, r.z1 - 1, r.x2, r.z1 - 1, r.x1, r.z1, r.x2, r.z1)
			face(r.x1, r.z2 + 1, r.x2, r.z2 + 1, r.x1, r.z2, r.x2, r.z2)
		end
		-- An approach counts only when its 6x6 inward window is one end
		-- block of this street (the street starts at the town entrance).
		local on_approach = false
		for _, a in ipairs(plan.approaches) do
			local e = a.edge
			local wx, wz = e.x1, e.z1
			if a.side == "+z" then wz = e.z2 - sw + 1 elseif a.side == "+x" then wx = e.x2 - sw + 1 end
			if wx >= r.x1 and wx + sw - 1 <= r.x2 and wz >= r.z1 and wz + sw - 1 <= r.z2 then
				local at_end
				if ex > ez then at_end = wx == r.x1 or wx + sw - 1 == r.x2
				elseif ez > ex then at_end = wz == r.z1 or wz + sw - 1 == r.z2
				else at_end = true end
				if at_end then on_approach = true end
			end
		end
		-- A street may end at a landmark door: the door node (approach.pos)
		-- must lie within one end block of the street.
		local at_door = false
		for _, name in ipairs({"castle", "cathedral"}) do
			local q = sites[name].approach.pos
			if q.x >= r.x1 and q.x <= r.x2 and q.z >= r.z1 and q.z <= r.z2 then
				local near
				if ex > ez then near = q.x <= r.x1 + sw - 1 or q.x >= r.x2 - sw + 1
				elseif ez > ex then near = q.z <= r.z1 + sw - 1 or q.z >= r.z2 - sw + 1
				else near = true end
				if near then at_door = true end
			end
		end
		local joined = 0
		for _, fc in ipairs(faces) do
			local ok = false
			for _, c in ipairs(fc.inner) do
				if covered_by_other(c[1], c[2], i) then ok = true; break end
			end
			for _, c in ipairs(ok and {} or fc.cells) do
				if other_pavement(c[1], c[2], i) then ok = true; break end
				if inenv(c[1], c[2]) then
					local k = idx(c[1], c[2])
					if inb[k] ~= 1 and on_approach then ok = true; break end
				elseif on_approach then
					ok = true; break
				end
			end
			if ok then joined = joined + 1 end
		end
		if s.kind == "principal" then
			-- A 6x6 corner window needs two joined faces; a street starting at
			-- an approach window is entered from outside the town, and one
			-- ending at a door node is entered from the landmark: each covers
			-- one face.
			local allowed = (#faces == 4) and 2 or 0
			if on_approach then allowed = allowed + 1 end
			if at_door then allowed = allowed + 1 end
			if #faces - joined > allowed then
				return false, "principal street " .. i .. " has a dead end"
			end
		else
			local net = false
			for _, fc in ipairs(faces) do
				for _, c in ipairs(fc.cells) do
					if other_pavement(c[1], c[2], i) then net = true end
				end
				for _, c in ipairs(fc.inner) do
					if covered_by_other(c[1], c[2], i) then net = true end
				end
			end
			if not net then
				return false, "secondary street " .. i .. " does not join the network"
			end
		end
	end

	-- Blocks.
	local minside = C.MIN_BLOCK_SIDE
	local taken = {}
	for i, b in ipairs(plan.blocks) do
		local r = b.rect
		if b.id ~= i then return false, "block " .. i .. " has wrong id" end
		if r.x2 - r.x1 + 1 < minside or r.z2 - r.z1 + 1 < minside then
			return false, ("block %d is smaller than %dx%d"):format(i, minside, minside)
		end
		if #b.frontage == 0 then return false, "block " .. i .. " has no frontage" end
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do
				local k = inenv(x, z) and idx(x, z)
				if not k or inb[k] ~= 1 or reserved[k] == 1 or road[k] == 1 or taken[k] then
					return false, ("block %d overlaps at (%d,%d)"):format(i, x, z)
				end
				taken[k] = true
			end
		end
		for _, fid in ipairs(b.frontage) do
			local f = plan.frontage[fid]
			if not f or f.block ~= i then
				return false, "block " .. i .. " lists foreign frontage " .. tostring(fid)
			end
		end
	end

	-- Frontage runs.
	local per_block = {}
	for i, f in ipairs(plan.frontage) do
		local fl = "frontage " .. i
		local b = plan.blocks[f.block]
		local d = FACING[f.side]
		if f.id ~= i then return false, fl .. " has wrong id" end
		if not b then return false, fl .. " has no block" end
		if not d or f.facing.x ~= d.x or f.facing.z ~= d.z then
			return false, fl .. " side and facing disagree"
		end
		per_block[f.block] = (per_block[f.block] or 0) + 1
		local br, fr = b.rect, f.rect
		local edge_ok = fr.x1 >= br.x1 and fr.x2 <= br.x2 and fr.z1 >= br.z1 and fr.z2 <= br.z2
		if f.side == "-z" then edge_ok = edge_ok and fr.z1 == br.z1 and fr.z2 == br.z1
		elseif f.side == "+z" then edge_ok = edge_ok and fr.z1 == br.z2 and fr.z2 == br.z2
		elseif f.side == "-x" then edge_ok = edge_ok and fr.x1 == br.x1 and fr.x2 == br.x1
		else edge_ok = edge_ok and fr.x1 == br.x2 and fr.x2 == br.x2 end
		if not edge_ok then return false, fl .. " is not on its block's edge" end
		local len = (fr.x2 - fr.x1 + 1) * (fr.z2 - fr.z1 + 1)
		if f.length ~= len or len < C.MIN_FRONTAGE_RUN then
			return false, fl .. " has bad length"
		end
		if (f.square ~= nil) == (f.street ~= nil) then
			return false, fl .. " must name exactly one street or square"
		end
		local want_owner = f.square or f.street
		if f.material ~= mats[want_owner] then return false, fl .. " has wrong material" end
		for z = fr.z1, fr.z2 do
			for x = fr.x1, fr.x2 do
				local ux, uz = x + d.x, z + d.z
				if not inenv(ux, uz) or owner[idx(ux, uz)] ~= want_owner then
					return false, fl .. " does not face " .. tostring(want_owner)
				end
			end
		end
	end
	for i, b in ipairs(plan.blocks) do
		if (per_block[i] or 0) ~= #b.frontage then
			return false, "block " .. i .. " frontage list does not match its runs"
		end
	end
	return true
end

return M
