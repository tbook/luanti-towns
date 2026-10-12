-- Towns: pure town planner (boundary + civic sites).
-- No core.* dependency, so it runs under plain Lua 5.1 and the tests.
--
--   local planner = dofile("src/planner.lua")
--   local plan, reason, detail = planner.plan({x = cx, z = cz}, seed [, opts])
--
-- Inputs are validated with error() (programmer errors): the centre must be
-- a table with integer x and z (|v| <= 31000), the seed an integer
-- (|seed| <= 2^53). When bounded retries are exhausted, plan returns
-- nil, "<readable reason>", {code = "retries_exhausted", attempts = n,
-- rejections = {[stage] = count, ...}}.
--
-- opts (all optional, mainly for tests / tuning):
--   max_attempts : integer >= 0, overrides MAX_ATTEMPTS
--   constants    : table overriding any named constant in planner.CONSTANTS
--
-- Determinism
-- -----------
-- The plan depends only on (seed, constants). The centre merely translates
-- the layout, so the same seed gives the same shape at any centre. Randomness
-- comes from an internal integer PRNG (MINSTD, every intermediate stays
-- below 2^53 so it is exact in Lua 5.1 doubles); math.random and
-- core.PseudoRandom are never used and nothing depends on pairs() order.
--
-- Plan schema (plain tables only; coordinates are absolute node X/Z)
-- ------------------------------------------------------------------
-- World axes as in geometry.lua: +X east, +Z north, -Z south. Sides are named
-- by axis: "-x", "+x", "-z", "+z". A rectangle is inclusive min/max
-- {x1, z1, x2, z2} (same convention as geometry.place min/max).
--
-- plan = {
--   seed     = integer,
--   center   = {x, z},                    -- the input centre (inside boundary)
--   envelope = rect,                      -- center-48 .. center+47 on both axes
--   bounds   = rect,                      -- exact bounding box of the boundary
--   width, depth = integer,               -- bounds extent along X and Z
--   boundary = {                          -- connected orthogonal union
--     rects = { rect, ... },              -- broad overlapping rectangles
--   },                                    --  (membership: inside ANY rect)
--   sites = {                             -- keyed by name, see site_order
--     cathedral = site, parvis = site, market = site, castle = site,
--   },
--   site_order = {"cathedral", "parvis", "market", "castle"},
--   approaches = {                        -- boundary entrances for routing
--     {name = "approach_1", side = "+z", edge = rect, pos = {x, z}}, ...
--   },
--   streets = {}, blocks = {}, frontage = {},  -- filled by the street ticket
--   attempts = integer,                   -- 1-based attempt that succeeded
-- }
--
-- site = {
--   name     = "cathedral" | "parvis" | "market" | "castle",
--   kind     = "landmark" | "square",
--   rect     = rect,                      -- reserved footprint
--   size     = {x, z},                    -- rect extent
--   side     = "-z"|"+z"|"-x"|"+x",       -- entrance/outward side of the rect
--   facing   = {x, z},                    -- unit vector for `side`
--   rotation = 0|90|180|270,              -- geometry.lua rotation whose front
--                                         --  vector equals `facing`
--   approach = {side, edge, pos},         -- see below
--   -- landmark only:
--   entrance = {x, z},                    -- door node on the footprint edge
--   -- cathedral only: parvis = "parvis"   -- name of its adjacent square
--   -- castle only:    outer_side, edge_gap -- side lying on the boundary edge
--   --                  and how many nodes of boundary lie beyond it (0 =
--   --                  touching, <= CASTLE_EDGE_SLACK)
-- }
--
-- Approach: `edge` is a 1-node-thick rect of the nodes just outside the
-- footprint along `side`; `pos` is the node of that edge in front of the
-- entrance (landmarks) or its middle (squares). For the cathedral the
-- approach is its entrance edge, which lies inside the parvis; streets reach
-- the cathedral through the parvis, whose approach is its far edge. The
-- market and parvis squares are open to routing from any side that is not the
-- cathedral; their approach is a preferred attachment point only.
--
-- Boundary approaches: `edge` is a 6-wide, 1-deep rect of boundary nodes on
-- an outer edge, `pos` its middle node, `side` the outward direction.
--
-- Guarantees checked before a plan is returned: boundary connected, bounds
-- within the envelope, non-square and stepped (no feature < MIN_FEATURE),
-- sites contained, non-overlapping and >= STREET_WIDTH apart (cathedral and
-- parvis touch by design), the castle on the boundary edge, and a
-- STREET_WIDTH-wide walkable corridor from each boundary approach to the
-- parvis, market and castle approach edge around the landmark footprints.

local M = {}

M.CONSTANTS = {
	ENVELOPE = 96,            -- town envelope, nodes per side
	MIN_LONG_SPAN = 80,       -- boundary bbox: longer side at least
	MIN_SHORT_SPAN = 60,      --                 shorter side at least
	MIN_ASPECT_DELTA = 12,    -- |width - depth| at least (non-square)
	MIN_FEATURE = 12,         -- min edge length, step depth, notch, arm width
	CENTER_JITTER = 8,        -- bbox centre vs town centre, nodes per axis
	MIN_FILL = 0.60,          -- boundary area / bbox area range
	MAX_FILL = 0.90,
	RECT_COUNT_MIN = 3,       -- broad overlapping rectangles per boundary
	RECT_COUNT_MAX = 5,
	STREET_WIDTH = 6,         -- principal street width / route clearance
	CATHEDRAL_LONG = 32,      -- footprint, long axis (entrance on short end)
	CATHEDRAL_SHORT = 20,
	PARVIS_DEPTH = 12,        -- perpendicular to the entrance side
	PARVIS_MARGIN = 4,        -- extra width on each side of the front
	MARKET_MIN = 20, MARKET_MAX = 28, -- market side lengths (varied per axis)
	MARKET_CENTER_RADIUS = 12, -- market centre within this of the town centre
	CASTLE_X = 30, CASTLE_Z = 26, -- footprint (axes swapped half the time)
	CASTLE_EDGE_SLACK = 2,    -- max nodes between castle and outer edge
	MAX_ATTEMPTS = 128,        -- bounded retries
	SITE_TRIES = 40,          -- random placements tried per site per attempt
}

local SIDES = {"-z", "+z", "-x", "+x"}
local FACING = {
	["-z"] = {x = 0, z = -1}, ["+z"] = {x = 0, z = 1},
	["-x"] = {x = -1, z = 0}, ["+x"] = {x = 1, z = 0},
}
local ROTATION = {["-z"] = 0, ["-x"] = 90, ["+z"] = 180, ["+x"] = 270}
local OPPOSITE = {["-z"] = "+z", ["+z"] = "-z", ["-x"] = "+x", ["+x"] = "-x"}

------------------------------------------------------------------------
-- PRNG (MINSTD; all products < 2^53)
------------------------------------------------------------------------
local MOD = 2147483647

local function new_rng(seed)
	local s = seed % MOD
	local hi = math.floor(seed / MOD) % MOD
	s = (s + hi * 7919 + 12345) % MOD
	for _ = 1, 8 do
		s = (s * 48271 + 1013904223) % MOD
		s = (s + math.floor(s / 65536) * 40503) % MOD
	end
	if s == 0 then s = 1 end
	local rng = {}
	function rng.int(a, b) -- uniform integer in [a, b]
		s = (s * 48271) % MOD
		return a + math.floor((s - 1) * (b - a + 1) / (MOD - 1))
	end
	function rng.pick(list)
		return list[rng.int(1, #list)]
	end
	return rng
end

------------------------------------------------------------------------
-- Rectangle helpers (inclusive {x1, z1, x2, z2})
------------------------------------------------------------------------
local function rect(x1, z1, x2, z2) return {x1 = x1, z1 = z1, x2 = x2, z2 = z2} end

local function area(r) return (r.x2 - r.x1 + 1) * (r.z2 - r.z1 + 1) end

-- Chebyshev gap in free nodes between two rects; < 0 when they overlap.
local function gap(a, b)
	local gx = math.max(a.x1 - b.x2 - 1, b.x1 - a.x2 - 1)
	local gz = math.max(a.z1 - b.z2 - 1, b.z1 - a.z2 - 1)
	return math.max(gx, gz)
end

local function inflate(r, n)
	return rect(r.x1 - n, r.z1 - n, r.x2 + n, r.z2 + n)
end

local function intersects(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

local function shift_rect(r, ox, oz)
	return rect(r.x1 + ox, r.z1 + oz, r.x2 + ox, r.z2 + oz)
end

-- The 1-node-thick row of nodes at distance d outside side `side` of r.
local function outer_row(r, side, d)
	if side == "-z" then return rect(r.x1, r.z1 - d, r.x2, r.z1 - d) end
	if side == "+z" then return rect(r.x1, r.z2 + d, r.x2, r.z2 + d) end
	if side == "-x" then return rect(r.x1 - d, r.z1, r.x1 - d, r.z2) end
	return rect(r.x2 + d, r.z1, r.x2 + d, r.z2)
end

local function mid(a, b) return a + math.floor((b - a) / 2) end

------------------------------------------------------------------------
-- Occupancy grid with prefix sums, local coordinates 0 .. n-1
------------------------------------------------------------------------
local function new_grid(n, rects)
	local cells = {}
	for z = 0, n - 1 do
		local row = {}
		for x = 0, n - 1 do row[x] = 0 end
		cells[z] = row
	end
	for _, r in ipairs(rects) do
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do cells[z][x] = 1 end
		end
	end
	return cells
end

-- count(cells, n) -> function(x1, z1, x2, z2) = filled cells (clipped)
local function prefix(cells, n)
	local P = {}
	for z = 0, n do
		local row = {}
		for x = 0, n do row[x] = 0 end
		P[z] = row
	end
	for z = 1, n do
		local acc = 0
		for x = 1, n do
			acc = acc + cells[z - 1][x - 1]
			P[z][x] = P[z - 1][x] + acc
		end
	end
	local function clip(v) if v < 0 then return 0 elseif v > n then return n end return v end
	return function(x1, z1, x2, z2)
		if x1 > x2 or z1 > z2 then return 0 end
		local a, b = clip(x1), clip(z1)
		local c, d = clip(x2 + 1), clip(z2 + 1)
		if c <= a or d <= b then return 0 end
		return P[d][c] - P[b][c] - P[d][a] + P[b][a]
	end
end

-- True when every cell of r (which may poke outside the grid) is filled.
local function all_filled(count, r)
	return count(r.x1, r.z1, r.x2, r.z2) == area(r)
end

local function none_filled(count, r)
	return count(r.x1, r.z1, r.x2, r.z2) == 0
end

------------------------------------------------------------------------
-- Boundary generation and shape validation
------------------------------------------------------------------------
-- Edges lie on lattice lines spaced MIN_FEATURE apart plus a nondecreasing
-- seeded jitter, so two distinct edge coordinates always differ by at least
-- MIN_FEATURE: steps, notches and arms cannot be smaller than that. The last
-- line sits exactly at `span`.
local function lattice(rng, C, span)
	local f = C.MIN_FEATURE
	local max_n = math.floor(span / f)
	local intervals = rng.int(math.max(3, max_n - 1), max_n)
	local total = span - f * intervals
	local j = {}
	for i = 1, intervals - 1 do j[#j + 1] = rng.int(0, total) end
	table.sort(j)
	table.insert(j, 1, 0)
	j[intervals + 1] = total
	-- j is 1-based here: line i uses j[i + 1].
	local lines = {}
	for i = 0, intervals do lines[i] = i * f + j[i + 1] end
	return lines, intervals
end

local function gen_boundary(rng, C)
	local n = C.ENVELOPE
	-- u is the long axis (envelope-filling spine), v the shorter one; the
	-- pair is transposed onto X/Z half the time so both orientations occur.
	local long = rng.int(C.MIN_LONG_SPAN, n)
	local short = rng.int(C.MIN_SHORT_SPAN, math.max(C.MIN_SHORT_SPAN, long - C.MIN_ASPECT_DELTA))
	local us, nu = lattice(rng, C, long)
	local vs, nv = lattice(rng, C, short)
	local transpose = rng.int(0, 1) == 1
	local xs, zs = us, vs
	if transpose then xs, zs = vs, us end
	local nx, nz = nu, nv
	if transpose then nx, nz = nv, nu end
	-- Offset the box so the town centre stays near the middle of the boundary.
	local function offset(span)
		local mid0 = math.floor((n - span) / 2)
		local lo = math.max(0, mid0 - C.CENTER_JITTER)
		local hi = math.min(n - span, mid0 + C.CENTER_JITTER)
		return rng.int(lo, hi)
	end
	local ox = offset(xs[nx])
	local oz = offset(zs[nz])
	local rects = {}
	local function add(u1, v1, u2, v2)
		if transpose then u1, v1, u2, v2 = v1, u1, v2, u2 end
		rects[#rects + 1] = rect(ox + xs[u1], oz + zs[v1],
			ox + xs[u2] - 1, oz + zs[v2] - 1)
	end
	-- Spine: spans the whole u extent over a band of v.
	local v1 = rng.int(0, nv - 2)
	local v2 = rng.int(v1 + 2, nv)
	add(0, v1, nu, v2)
	-- Wings reach the v extremes so the bounding box is fully used.
	if v1 > 0 then
		local u1 = rng.int(0, nu - 2)
		local u2 = rng.int(u1 + 2, nu)
		add(u1, 0, u2, rng.int(v1 + 1, v2))
	end
	if v2 < nv then
		local u1 = rng.int(0, nu - 2)
		local u2 = rng.int(u1 + 2, nu)
		add(u1, rng.int(v1, v2 - 1), u2, nv)
	end
	-- Optional extras: further broad rectangles overlapping the spine.
	local extras = rng.int(0, math.max(0, C.RECT_COUNT_MAX - #rects))
	for _ = 1, extras do
		local u1 = rng.int(0, nu - 2)
		local u2 = rng.int(u1 + 2, nu)
		local a1 = rng.int(0, nv - 2)
		local a2 = rng.int(a1 + 2, nv)
		if a1 < v2 and a2 > v1 then add(u1, a1, u2, a2) end
	end
	return rects
end

-- Edge profile check: constant runs >= feat long, consecutive values
-- differing by >= feat.
local function profile_ok(vals, first, last, feat)
	local runv, runlen, prev = nil, 0, nil
	for i = first, last do
		local v = vals[i]
		if v == runv then
			runlen = runlen + 1
		else
			if runv ~= nil then
				if runlen < feat then return false end
				if math.abs(v - runv) < feat then return false end
			end
			runv, runlen = v, 1
		end
		prev = v
	end
	return prev == nil or runlen >= feat
end

-- Returns bbox (rect) or nil, reason.
local function check_boundary(cells, rects, C)
	local n = C.ENVELOPE
	local feat = C.MIN_FEATURE
	local x1, z1, x2, z2 = n, n, -1, -1
	local filled = 0
	for z = 0, n - 1 do
		for x = 0, n - 1 do
			if cells[z][x] == 1 then
				filled = filled + 1
				if x < x1 then x1 = x end
				if x > x2 then x2 = x end
				if z < z1 then z1 = z end
				if z > z2 then z2 = z end
			end
		end
	end
	if filled == 0 then return nil, "empty boundary" end
	local bbox = rect(x1, z1, x2, z2)
	local w, d = x2 - x1 + 1, z2 - z1 + 1
	if math.max(w, d) < C.MIN_LONG_SPAN or math.min(w, d) < C.MIN_SHORT_SPAN then
		return nil, "boundary too small"
	end
	if math.abs(w - d) < C.MIN_ASPECT_DELTA then
		return nil, "boundary square-ish"
	end
	local fill = filled / (w * d)
	if fill > C.MAX_FILL then return nil, "boundary too rectangular" end
	if fill < C.MIN_FILL then return nil, "boundary too sparse" end

	-- Connectivity (4-neighbour flood fill).
	local seen, reached = {}, 0
	local stack = {}
	for z = z1, z2 do
		for x = x1, x2 do
			if cells[z][x] == 1 and #stack == 0 and reached == 0 then
				stack[1] = {x, z}
				seen[z * n + x] = true
			end
		end
	end
	while #stack > 0 do
		local c = table.remove(stack)
		reached = reached + 1
		local dirs = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
		for k = 1, 4 do
			local nx, nz = c[1] + dirs[k][1], c[2] + dirs[k][2]
			if nx >= 0 and nx < n and nz >= 0 and nz < n
					and cells[nz][nx] == 1 and not seen[nz * n + nx] then
				seen[nz * n + nx] = true
				stack[#stack + 1] = {nx, nz}
			end
		end
	end
	if reached ~= filled then return nil, "boundary disconnected" end

	-- Row/column profiles: extents, internal gaps.
	local L, R, T, B = {}, {}, {}, {}
	for z = z1, z2 do
		local last, first = nil, nil
		for x = x1, x2 do
			if cells[z][x] == 1 then
				if last and x - last - 1 > 0 and x - last - 1 < feat then
					return nil, "boundary notch narrower than feature size"
				end
				first = first or x
				last = x
			end
		end
		L[z], R[z] = first, last
	end
	for x = x1, x2 do
		local last, first = nil, nil
		for z = z1, z2 do
			if cells[z][x] == 1 then
				if last and z - last - 1 > 0 and z - last - 1 < feat then
					return nil, "boundary notch narrower than feature size"
				end
				first = first or z
				last = z
			end
		end
		T[x], B[x] = first, last
	end
	if not (profile_ok(L, z1, z2, feat) and profile_ok(R, z1, z2, feat)
			and profile_ok(T, x1, x2, feat) and profile_ok(B, x1, x2, feat)) then
		return nil, "boundary step or edge shorter than feature size"
	end

	-- Opening by a feat x feat square: no arm narrower than feat.
	local count = prefix(cells, n)
	local diff = {}
	for z = 0, n + 1 do
		diff[z] = {}
		for x = 0, n + 1 do diff[z][x] = 0 end
	end
	for z = z1, z2 - feat + 1 do
		for x = x1, x2 - feat + 1 do
			if count(x, z, x + feat - 1, z + feat - 1) == feat * feat then
				diff[z][x] = diff[z][x] + 1
				diff[z][x + feat] = diff[z][x + feat] - 1
				diff[z + feat][x] = diff[z + feat][x] - 1
				diff[z + feat][x + feat] = diff[z + feat][x + feat] + 1
			end
		end
	end
	local cov = {}
	for z = 0, n - 1 do
		cov[z] = {}
		for x = 0, n - 1 do
			local v = diff[z][x]
			if x > 0 then v = v + cov[z][x - 1] end
			if z > 0 then v = v + cov[z - 1][x] end
			if x > 0 and z > 0 then v = v - cov[z - 1][x - 1] end
			cov[z][x] = v
			if cells[z][x] == 1 and v <= 0 then
				return nil, "boundary arm narrower than feature size"
			end
		end
	end
	return bbox
end

------------------------------------------------------------------------
-- Site placement
------------------------------------------------------------------------
-- Slide a w x d rect inward from outside bbox side `side` at coordinate
-- `along` until it is wholly inside the boundary. Returns rect or nil.
local function slide_in(count, bbox, side, w, d, along, n)
	local r
	if side == "-z" then
		r = rect(along, bbox.z1 - d, along + w - 1, bbox.z1 - 1)
	elseif side == "+z" then
		r = rect(along, bbox.z2 + 1, along + w - 1, bbox.z2 + d)
	elseif side == "-x" then
		r = rect(bbox.x1 - w, along, bbox.x1 - 1, along + d - 1)
	else
		r = rect(bbox.x2 + 1, along, bbox.x2 + w, along + d - 1)
	end
	local step = FACING[OPPOSITE[side]]
	for _ = 1, n do
		if all_filled(count, r) then return r end
		r = shift_rect(r, step.x, step.z)
	end
	return nil
end

-- Number of boundary nodes between r and the outer edge beyond `side`, or
-- nil when the boundary there is not a straight edge parallel to the side.
local function edge_gap(count, r, side, limit)
	for g = 0, limit do
		local row = outer_row(r, side, g + 1)
		if none_filled(count, row) then return g end
		if not all_filled(count, row) then return nil end
	end
	return nil
end

local function shape_site(name, kind, r, side)
	local s = {
		name = name, kind = kind, rect = r, side = side,
		size = {x = r.x2 - r.x1 + 1, z = r.z2 - r.z1 + 1},
		facing = {x = FACING[side].x, z = FACING[side].z},
		rotation = ROTATION[side],
	}
	local e = outer_row(r, side, 1)
	local pos
	if side == "-z" or side == "+z" then
		pos = {x = mid(r.x1, r.x2), z = e.z1}
	else
		pos = {x = e.x1, z = mid(r.z1, r.z2)}
	end
	s.approach = {side = side, edge = e, pos = pos}
	if kind == "landmark" then
		local p = {x = pos.x, z = pos.z}
		if side == "-z" then p.z = r.z1 elseif side == "+z" then p.z = r.z2
		elseif side == "-x" then p.x = r.x1 else p.x = r.x2 end
		s.entrance = p
	end
	return s
end

local function sample_market(rng, C, count, n)
	for _ = 1, C.SITE_TRIES do
		local w = rng.int(C.MARKET_MIN, C.MARKET_MAX)
		local d = rng.int(C.MARKET_MIN, C.MARKET_MAX)
		local cx = math.floor(n / 2) + rng.int(-C.MARKET_CENTER_RADIUS, C.MARKET_CENTER_RADIUS)
		local cz = math.floor(n / 2) + rng.int(-C.MARKET_CENTER_RADIUS, C.MARKET_CENTER_RADIUS)
		local x1 = math.floor(cx - w / 2)
		local z1 = math.floor(cz - d / 2)
		local r = rect(x1, z1, x1 + w - 1, z1 + d - 1)
		if all_filled(count, r) then return r end
	end
end

-- Candidate lists are enumerated in a fixed order and one is picked with the
-- seeded rng, so a feasible layout is found whenever one exists.
local function sample_cathedral(rng, C, count, bbox, market)
	local sw = C.STREET_WIDTH
	local m, p = C.PARVIS_MARGIN, C.PARVIS_DEPTH
	local found, roomy = {}, {}
	for k = 1, 4 do
		local side = SIDES[k]
		local long_x = (side == "-x" or side == "+x")
		local w = long_x and C.CATHEDRAL_LONG or C.CATHEDRAL_SHORT
		local d = long_x and C.CATHEDRAL_SHORT or C.CATHEDRAL_LONG
		for z1 = bbox.z1, bbox.z2 - d + 1, 2 do
			for x1 = bbox.x1, bbox.x2 - w + 1, 2 do
				local c = rect(x1, z1, x1 + w - 1, z1 + d - 1)
				local pr
				if side == "-z" then pr = rect(c.x1 - m, c.z1 - p, c.x2 + m, c.z1 - 1)
				elseif side == "+z" then pr = rect(c.x1 - m, c.z2 + 1, c.x2 + m, c.z2 + p)
				elseif side == "-x" then pr = rect(c.x1 - p, c.z1 - m, c.x1 - 1, c.z2 + m)
				else pr = rect(c.x2 + 1, c.z1 - m, c.x2 + p, c.z2 + m) end
				if gap(c, market) >= sw and gap(pr, market) >= sw
						and all_filled(count, c) and all_filled(count, pr) then
					found[#found + 1] = {c, pr, side}
					-- Preferred: a street's width of boundary all round.
					if all_filled(count, inflate(c, sw))
							and all_filled(count, inflate(pr, sw)) then
						roomy[#roomy + 1] = found[#found]
					end
				end
			end
		end
	end
	if #roomy > 0 then found = roomy end
	if #found == 0 then return nil end
	local pick = found[rng.int(1, #found)]
	return pick[1], pick[2], pick[3]
end

local function sample_castle(rng, C, count, bbox, n, others)
	local sw = C.STREET_WIDTH
	local found = {}
	for k = 1, 4 do
		local side = SIDES[k]
		local horizontal = (side == "-z" or side == "+z")
		for o = 0, 1 do
			local w, d = C.CASTLE_X, C.CASTLE_Z
			if o == 1 then w, d = d, w end
			local lo = horizontal and bbox.x1 or bbox.z1
			local hi = (horizontal and bbox.x2 - w + 1 or bbox.z2 - d + 1)
			for along = lo, hi do
				local r0 = slide_in(count, bbox, side, w, d, along, n)
				for extra = 0, C.CASTLE_EDGE_SLACK do
					local r = r0
					if r then
						local step = FACING[OPPOSITE[side]]
						r = shift_rect(r, step.x * extra, step.z * extra)
					end
					local g = r and all_filled(count, r)
						and edge_gap(count, r, side, C.CASTLE_EDGE_SLACK)
					if g then
						local ok = true
						for j = 1, #others do
							ok = ok and gap(r, others[j]) >= sw
						end
						if ok then
							-- Touching edges are weighted over slack ones.
							for _ = 1, (extra == 0) and 3 or 1 do
								found[#found + 1] = {r, side, g}
							end
						end
					end
				end
			end
		end
	end
	if #found == 0 then return nil end
	local pick = found[rng.int(1, #found)]
	return pick[1], pick[2], pick[3]
end

local function sample_approach(rng, C, count, bbox, n, side, obstacles)
	local sw = C.STREET_WIDTH
	local horizontal = (side == "-z" or side == "+z")
	local lo = horizontal and bbox.x1 or bbox.z1
	local hi = (horizontal and bbox.x2 or bbox.z2) - sw + 1
	local found = {}
	for along = lo, hi do
		local r = slide_in(count, bbox, side, sw, sw, along, n)
		if r and edge_gap(count, r, side, 0) == 0 then
			local clear = true
			for j = 1, #obstacles do
				clear = clear and not intersects(r, obstacles[j])
			end
			if clear then found[#found + 1] = r end
		end
	end
	if #found == 0 then return nil end
	return found[rng.int(1, #found)]
end

-- BFS over top-left corners of free sw x sw windows. Returns the visited set
-- (keyed z * n + x).
local function reachable_windows(free_count, start, sw, n)
	local function free(x, z)
		return x >= 0 and z >= 0 and x + sw <= n and z + sw <= n
			and free_count(x, z, x + sw - 1, z + sw - 1) == sw * sw
	end
	local seen = {}
	if not free(start.x1, start.z1) then return seen end
	local queue, head = {{start.x1, start.z1}}, 1
	seen[start.z1 * n + start.x1] = true
	while head <= #queue do
		local c = queue[head]
		head = head + 1
		local dirs = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
		for k = 1, 4 do
			local nx, nz = c[1] + dirs[k][1], c[2] + dirs[k][2]
			local key = nz * n + nx
			if not seen[key] and free(nx, nz) then
				seen[key] = true
				queue[#queue + 1] = {nx, nz}
			end
		end
	end
	return seen
end

local function touches(seen, r, sw, n)
	-- Any visited window rect intersecting r.
	for z = math.max(0, r.z1 - sw + 1), r.z2 do
		for x = math.max(0, r.x1 - sw + 1), r.x2 do
			if seen[z * n + x] then return true end
		end
	end
	return false
end

-- One attempt. Returns plan (local coords) or nil, stage.
local function attempt(rng, C)
	local n = C.ENVELOPE
	local rects = gen_boundary(rng, C)
	local cells = new_grid(n, rects)
	local bbox, why = check_boundary(cells, rects, C)
	if not bbox then return nil, "boundary", why end
	local count = prefix(cells, n)
	local c = math.floor(n / 2)
	if cells[c][c] ~= 1 then return nil, "boundary", "centre outside boundary" end

	local market = sample_market(rng, C, count, n)
	if not market then return nil, "market", "no market square fits near centre" end
	local cathedral, parvis, cside = sample_cathedral(rng, C, count, bbox, market)
	if not cathedral then return nil, "cathedral", "no cathedral and parvis placement" end
	local castle, outer_side, egap = sample_castle(rng, C, count, bbox, n,
		{cathedral, parvis, market})
	if not castle then return nil, "castle", "no castle placement on an outer edge" end

	local sites = {
		cathedral = shape_site("cathedral", "landmark", cathedral, cside),
		castle = shape_site("castle", "landmark", castle, OPPOSITE[outer_side]),
	}
	sites.cathedral.parvis = "parvis"
	sites.castle.outer_side = outer_side
	sites.castle.edge_gap = egap
	-- Market approach: side facing the cathedral along the dominant axis.
	local dx = mid(cathedral.x1, cathedral.x2) - mid(market.x1, market.x2)
	local dz = mid(cathedral.z1, cathedral.z2) - mid(market.z1, market.z2)
	local mside
	if math.abs(dx) >= math.abs(dz) then mside = dx >= 0 and "+x" or "-x"
	else mside = dz >= 0 and "+z" or "-z" end
	sites.market = shape_site("market", "square", market, mside)
	-- Parvis approach is its far edge (away from the cathedral).
	sites.parvis = shape_site("parvis", "square", parvis, cside)

	-- Boundary approaches on two different outer sides.
	local s1 = rng.pick(SIDES)
	local s2
	repeat s2 = rng.pick(SIDES) until s2 ~= s1
	local obstacles = {cathedral, parvis, market, castle}
	local a1 = sample_approach(rng, C, count, bbox, n, s1, obstacles)
	local a2 = sample_approach(rng, C, count, bbox, n, s2, obstacles)
	if not a1 or not a2 then
		return nil, "approach", "no boundary approach window on two outer sides"
	end

	-- Route space: a street-wide corridor must link both approaches to the
	-- market, parvis and the castle approach edge, around the landmarks.
	local sw = C.STREET_WIDTH
	local free = new_grid(n, {})
	for z = 0, n - 1 do
		for x = 0, n - 1 do
			local f = cells[z][x] == 1
			if f and (intersects(rect(x, z, x, z), cathedral)
					or intersects(rect(x, z, x, z), castle)) then
				f = false
			end
			free[z][x] = f and 1 or 0
		end
	end
	local seen = reachable_windows(prefix(free, n), a1, sw, n)
	local reach_a2 = seen[a2.z1 * n + a2.x1]
	if not reach_a2 then
		return nil, "routes", "boundary approaches not connected by a street-wide route"
	end
	if not touches(seen, market, sw, n) then
		return nil, "routes", "no street-wide route to the market"
	end
	if not touches(seen, parvis, sw, n) then
		return nil, "routes", "no street-wide route to the parvis"
	end
	if not touches(seen, sites.castle.approach.edge, sw, n) then
		return nil, "routes", "no street-wide route to the castle approach"
	end

	local function approach_of(name, r, side)
		-- The outermost row of the window on the boundary edge.
		local edge
		if side == "-z" then edge = rect(r.x1, r.z1, r.x2, r.z1)
		elseif side == "+z" then edge = rect(r.x1, r.z2, r.x2, r.z2)
		elseif side == "-x" then edge = rect(r.x1, r.z1, r.x1, r.z2)
		else edge = rect(r.x2, r.z1, r.x2, r.z2) end
		return {name = name, side = side, edge = edge,
			pos = {x = mid(edge.x1, edge.x2), z = mid(edge.z1, edge.z2)}}
	end

	return {
		rects = rects, bbox = bbox, sites = sites,
		approaches = {approach_of("approach_1", a1, s1), approach_of("approach_2", a2, s2)},
	}
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------
local ORDER = {"cathedral", "parvis", "market", "castle"}

local function is_int(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
		and v == math.floor(v)
end

local function xz_rect(r, ox, oz)
	return {x1 = r.x1 + ox, z1 = r.z1 + oz, x2 = r.x2 + ox, z2 = r.z2 + oz}
end

local function xz_pos(p, ox, oz) return {x = p.x + ox, z = p.z + oz} end

local function to_world(local_plan, seed, center, C, attempts)
	local n = C.ENVELOPE
	local half = math.floor(n / 2)
	local ox, oz = center.x - half, center.z - half
	local sites = {}
	for _, name in ipairs(ORDER) do
		local s = local_plan.sites[name]
		local out = {
			name = s.name, kind = s.kind,
			rect = xz_rect(s.rect, ox, oz),
			size = {x = s.size.x, z = s.size.z},
			side = s.side,
			facing = {x = s.facing.x, z = s.facing.z},
			rotation = s.rotation,
			approach = {
				side = s.approach.side,
				edge = xz_rect(s.approach.edge, ox, oz),
				pos = xz_pos(s.approach.pos, ox, oz),
			},
		}
		if s.entrance then out.entrance = xz_pos(s.entrance, ox, oz) end
		if s.parvis then out.parvis = s.parvis end
		if s.outer_side then
			out.outer_side = s.outer_side
			out.edge_gap = s.edge_gap
		end
		sites[name] = out
	end
	local approaches = {}
	for i, a in ipairs(local_plan.approaches) do
		approaches[i] = {
			name = a.name, side = a.side,
			edge = xz_rect(a.edge, ox, oz), pos = xz_pos(a.pos, ox, oz),
		}
	end
	local brects = {}
	for i, r in ipairs(local_plan.rects) do brects[i] = xz_rect(r, ox, oz) end
	local bounds = xz_rect(local_plan.bbox, ox, oz)
	return {
		seed = seed,
		center = {x = center.x, z = center.z},
		envelope = rect(center.x - half, center.z - half, center.x + half - 1, center.z + half - 1),
		bounds = bounds,
		width = bounds.x2 - bounds.x1 + 1,
		depth = bounds.z2 - bounds.z1 + 1,
		boundary = {rects = brects},
		sites = sites,
		site_order = {"cathedral", "parvis", "market", "castle"},
		approaches = approaches,
		streets = {}, blocks = {}, frontage = {},
		attempts = attempts,
	}
end

function M.plan(center, seed, opts)
	if type(center) ~= "table" or not is_int(center.x) or not is_int(center.z)
			or math.abs(center.x) > 31000 or math.abs(center.z) > 31000 then
		error("towns planner: site_center must be a table with integer x and z "
			.. "(|value| <= 31000)", 2)
	end
	if not is_int(seed) or math.abs(seed) > 2 ^ 53 then
		error("towns planner: seed must be an integer (|seed| <= 2^53), got "
			.. tostring(seed), 2)
	end
	local C = {}
	for k, v in pairs(M.CONSTANTS) do C[k] = v end
	local max_attempts = C.MAX_ATTEMPTS
	if opts ~= nil then
		if type(opts) ~= "table" then
			error("towns planner: opts must be a table", 2)
		end
		if opts.constants then
			for k, v in pairs(opts.constants) do
				if M.CONSTANTS[k] == nil then
					error("towns planner: unknown constant " .. tostring(k), 2)
				end
				C[k] = v
			end
		end
		if opts.max_attempts ~= nil then
			if not is_int(opts.max_attempts) or opts.max_attempts < 0 then
				error("towns planner: max_attempts must be an integer >= 0", 2)
			end
			max_attempts = opts.max_attempts
		end
	end

	local rng = new_rng(seed)
	local rejections = {}
	local last
	for i = 1, max_attempts do
		local p, stage, why = attempt(rng, C)
		if p then
			return to_world(p, seed, center, C, i)
		end
		rejections[stage] = (rejections[stage] or 0) + 1
		last = why
	end

	local parts = {}
	for _, stage in ipairs({"boundary", "market", "cathedral", "castle", "approach", "routes"}) do
		if rejections[stage] then
			parts[#parts + 1] = stage .. " x" .. rejections[stage]
		end
	end
	local reason = ("no valid town plan for seed %d after %d attempts"):format(seed, max_attempts)
	if #parts > 0 then
		reason = reason .. " (rejected: " .. table.concat(parts, ", ")
			.. "; last: " .. tostring(last) .. ")"
	end
	return nil, reason, {
		code = "retries_exhausted", attempts = max_attempts,
		rejections = rejections, last = last,
	}
end

-- ASCII top-down rendering for debugging. North (+Z) is up, east (+X) right.
-- Legend: . boundary  C cathedral  p parvis  M market  K castle  A approach
--         + centre  e entrance  (blank = outside)
function M.render(plan)
	local b = plan.bounds
	local grid = {}
	local function put(x, z, ch)
		if x >= b.x1 and x <= b.x2 and z >= b.z1 and z <= b.z2 then
			grid[z][x] = ch
		end
	end
	for z = b.z1, b.z2 do
		grid[z] = {}
		for x = b.x1, b.x2 do grid[z][x] = " " end
	end
	for _, r in ipairs(plan.boundary.rects) do
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do put(x, z, ".") end
		end
	end
	local glyph = {cathedral = "C", parvis = "p", market = "M", castle = "K"}
	for _, name in ipairs(plan.site_order) do
		local r = plan.sites[name].rect
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do put(x, z, glyph[name]) end
		end
	end
	for _, a in ipairs(plan.approaches) do
		local e = a.edge
		for z = e.z1, e.z2 do
			for x = e.x1, e.x2 do put(x, z, "A") end
		end
	end
	for _, name in ipairs(plan.site_order) do
		local e = plan.sites[name].entrance
		if e then put(e.x, e.z, "e") end
	end
	put(plan.center.x, plan.center.z, "+")
	local lines = {}
	lines[1] = ("seed %d center (%d,%d) bounds (%d,%d)-(%d,%d) %dx%d attempts %d"):format(
		plan.seed, plan.center.x, plan.center.z, b.x1, b.z1, b.x2, b.z2,
		plan.width, plan.depth, plan.attempts)
	for z = b.z2, b.z1, -1 do
		local row = {}
		for x = b.x1, b.x2 do row[#row + 1] = grid[z][x] end
		lines[#lines + 1] = (table.concat(row):gsub("%s+$", ""))
	end
	return table.concat(lines, "\n")
end

return M
