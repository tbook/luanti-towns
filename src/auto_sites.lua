-- Automatic towns (#394): deterministic site descriptors and bounded cell lookup.
-- Pure Lua: no Minetest globals, no world access, no planner run, no clock and no
-- global random state. Every answer is a function of (world seed string, cell, config).
--
-- API: local auto_sites = dofile("src/auto_sites.lua")
--   sites, reason, code = auto_sites.new(env, opts)
--       env is the auto_bounds environment (auto_bounds.new, #393). It must have
--       activation_rect, max_rect and fit. opts.candidates (default auto_sites.CANDIDATES) is
--       1 or 9.
--       N = 1 (version 1 behaviour, today's activation): one centre per cell with fit.jitter;
--       the whole activation rect must stay one mapchunk inside its cell (fit.fits).
--       N = 9 (#431 T3, not yet wired into activation): a 3 x 3 lattice with offsets
--       {-LATTICE_SPACING, 0, +LATTICE_SPACING} plus seeded +/-LATTICE_JITTER. Only max_rect
--       must stay one mapchunk inside the cell; activation rects overhang the cell edge by
--       sites.overhang (98 nodes for the measured basis).
--       Either way an impossible configuration declines (impossible_cell).
--   sites.describe(seed, cx, cz, k) -> descriptor | nil, reason, code   (k defaults to 0)
--   sites.cell(seed, cx, cz)        -> list of the cell's candidates, index order
--   sites.lookup(seed, rect)        -> list of descriptors | nil, reason, code
--       rect is {x1, z1, x2, z2} (inclusive, absolute). The list holds every candidate of the
--       cells whose 1,024-node range overlaps rect padded by sites.overhang, ordered by cz,
--       cx, then k ascending. Per-cell descriptors are cached (bounded); results are copies.
--   sites.candidates, sites.overhang   N and the activation overhang of this lookup
--   auto_sites.cell_index(v)      floor(v / CELL): the cell index of a node coordinate.
--   auto_sites.draw(seed, purpose, cx, cz) -> integer in [0, HASH_MODULUS)
--
-- Descriptor (fresh table per call; rects and points are absolute world coordinates):
--   id              "2:cx:cz:k:type:seed:x:z": version, cell, candidate, town type, planner
--                   seed and centre
--   version         VERSION (format changes bump it and are documented in epic #355)
--   candidate       k, 0-based index in the cell (always 0 when N = 1)
--   cell            {x, z}     signed cell index
--   center          {x, z}     proposed centre
--   town_type       "medieval" or "roman" (equal weights), one per cell
--   seed            planner seed, integer in 1 .. planner.SEED_LIMIT, one per cell (never the world seed)
--   max_rect        rect       centre + env.max_rect
--   activation_rect rect       centre + env.activation_rect
--
-- Version 2 versus 1: only the id (candidate index added) and the descriptor shape changed.
-- With N = 1 the centre, town type and planner seed equal version 1 exactly because the hash
-- salt is pinned to HASH_VERSION = 1. Accepted-town records (towns.auto_records.v1) are keyed
-- by cell, so version 1 records still reserve their cells.
--
-- Declines (nil, reason, code): invalid_seed, invalid_cell, invalid_rect, invalid_env,
-- impossible_cell (configuration), map_limit (activation rect beyond auto_bounds.MAP_LIMIT).
--
-- Hash. The world seed is a string of arbitrary length, so it is hashed byte by byte and
-- never converted to a number. The state lives in [0, P) with P = 2^31 - 1. Every product
-- is taken by mulmod, which splits one operand into 16-bit halves, so each intermediate is
-- below 2^49 and exact in a double. Each input is length-prefixed, so the text and the
-- coordinates cannot run together. Signed cell coordinates enter as cx % P.
--   draw = finish(absorb(absorb(absorb(0, SALT), seed), purpose), cx, cz)
-- where SALT is "towns.auto_sites.v<HASH_VERSION>" and purpose is one of M.PURPOSE.

local M = {}
local SOURCE = debug.getinfo(1, "S").source:sub(2)
local MODPATH = SOURCE:match("^(.*)/src/auto_sites.lua$") or "."

local auto_bounds = dofile(MODPATH .. "/src/auto_bounds.lua")
local planner = dofile(MODPATH .. "/src/planner.lua")

M.VERSION = 2
-- The hash salt keeps its version-1 text on purpose: town type, planner seed and the legacy
-- single-candidate jitter are draws of (seed, cell), and they must not change with the id
-- format (N = 1 reproduces version 1 geometry, type and planner seed exactly).
M.HASH_VERSION = 1
M.CELL = auto_bounds.CELL                       -- 1,024 nodes (design section 2)
M.HALF = M.CELL / 2                             -- 512: the middle of a cell
M.CLEARANCE = auto_bounds.CELL_EDGE_CLEARANCE   -- one mapchunk (80) from each cell edge
M.MAP_LIMIT = auto_bounds.MAP_LIMIT             -- 31000 nodes per axis
M.TYPES = {"medieval", "roman"}                 -- equal initial weights
M.SALT = "towns.auto_sites.v" .. M.HASH_VERSION
-- Candidates per cell (#431 T3). Valid values: 1 (one centre, jitter fit.jitter, activation
-- rect inside the cell: the version 1 behaviour) or LATTICE_CANDIDATES (3 x 3 lattice).
-- Activation does not use more than one candidate until the cell job lands (T4/T5), so the
-- default stays 1; sites.new(env, {candidates = 9}) selects the lattice.
-- UNCERTAIN (design, multi-candidate): 9 candidates and LATTICE_SPACING were chosen by
-- reasoning, not measured; change these constants after playtests.
M.CANDIDATES = 1
M.LATTICE_CANDIDATES = 9
M.LATTICE_SPACING = 180     -- lattice offsets are {-SPACING, 0, +SPACING} from the cell middle
M.LATTICE_JITTER = 6        -- seeded +/- jitter added to each lattice offset
M.PURPOSE = {
	JITTER_X = "center-jitter-x",               -- legacy (N = 1) centre jitter
	JITTER_Z = "center-jitter-z",
	LATTICE_X = "lattice-jitter-x",             -- candidate jitter; ":<k>" is appended
	LATTICE_Z = "lattice-jitter-z",
	TYPE = "town-type",
	PLANNER = "planner-seed",
}
M.CACHE_LIMIT = 8192                            -- cells kept in the descriptor cache
M.HASH_MODULUS = 2147483647                     -- 2^31 - 1, prime

local P = M.HASH_MODULUS

-- (a * b) % P with a, b integers in [0, 2^32). b is split into 16-bit halves so that
-- every intermediate stays below 2^49.
local function mulmod(a, b)
	local bh = math.floor(b / 65536)
	local bl = b - bh * 65536
	return ((a * bh) % P * 65536 + a * bl) % P
end

-- One mixing step absorbing word w (integer in [0, P)).
local function step(h, w)
	h = mulmod((h + w + 1) % P, 1540483477)
	h = (h + 2246822519) % P
	return mulmod(h, h + 1)
end

-- Absorbs a string: its length, then its bytes.
local function absorb_text(h, s)
	h = step(h, #s)
	for i = 1, #s do h = step(h, s:byte(i)) end
	return h
end

-- Three extra rounds so the final bits depend on every absorbed word.
local function finish(h)
	for _ = 1, 3 do h = step(h, 0) end
	return h
end

local function is_int(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v == math.floor(v)
end

-- Named draw of one cell. Pure, and integer-exact for any seed string.
function M.draw(seed, purpose, cx, cz)
	local h = absorb_text(0, M.SALT)
	h = absorb_text(h, seed)
	h = absorb_text(h, purpose)
	h = step(h, cx % P)
	h = step(h, cz % P)
	return finish(h)
end

-- Cell index of one node coordinate (floor division, so -1 is cell -1).
function M.cell_index(v)
	return math.floor(v / M.CELL)
end

local function check_seed(seed)
	if type(seed) ~= "string" or seed == "" then
		return nil, "world seed must be a non-empty string", "invalid_seed"
	end
	return true
end

local function rect_at(rel, c)
	return {x1 = c.x + rel.x1, z1 = c.z + rel.z1, x2 = c.x + rel.x2, z2 = c.z + rel.z2}
end

local function valid_rel_rect(r)
	return type(r) == "table" and is_int(r.x1) and is_int(r.z1) and is_int(r.x2) and is_int(r.z2)
		and r.x1 <= r.x2 and r.z1 <= r.z2
end

-- Builds the lookup for one auto_bounds environment. opts.candidates (default M.CANDIDATES)
-- is 1 or M.LATTICE_CANDIDATES. Only configuration-sized values and a bounded cache of
-- immutable per-cell candidate lists are kept; callers always receive fresh copies.
function M.new(env, opts)
	if type(env) ~= "table" then return nil, "auto_bounds environment is required", "invalid_env" end
	local act, max_rel, fit = env.activation_rect, env.max_rect, env.fit
	if not valid_rel_rect(act) or not valid_rel_rect(max_rel) or type(fit) ~= "table" then
		return nil, "environment needs integer activation_rect, max_rect and fit", "invalid_env"
	end
	if not auto_bounds.contains_rect(act, max_rel) then
		return nil, "max_rect is not inside activation_rect", "invalid_env"
	end
	local N = type(opts) == "table" and opts.candidates or M.CANDIDATES
	if N ~= 1 and N ~= M.LATTICE_CANDIDATES then
		return nil, "candidates must be 1 or " .. M.LATTICE_CANDIDATES, "invalid_env"
	end
	local last = M.CELL - 1 - M.CLEARANCE
	local offsets, J, pad = {}, 0, 0
	if N == 1 then
		-- Version 1 rule: the whole activation rect stays inside the cell clearance.
		if fit.fits ~= true then
			return nil, "activation envelope does not fit the cell with edge clearance", "impossible_cell"
		end
		J = fit.jitter
		if not is_int(J) or J < 0 then return nil, "fit.jitter must be a nonnegative integer", "invalid_env" end
		-- Every centre offset in [HALF - J, HALF + J] must keep the activation rect within
		-- [CLEARANCE, CELL - 1 - CLEARANCE] on both axes.
		local lo_ok = M.HALF - J + act.x1 >= M.CLEARANCE and M.HALF - J + act.z1 >= M.CLEARANCE
		local hi_ok = M.HALF + J + act.x2 <= last and M.HALF + J + act.z2 <= last
		if not (lo_ok and hi_ok) then
			return nil, "activation envelope plus jitter leaves the cell clearance", "impossible_cell"
		end
		offsets[1] = {0, 0}
	else
		-- Lattice rule: only max_rect must keep the clearance; activation rects may overhang.
		J = M.LATTICE_JITTER
		local reach = M.LATTICE_SPACING + J
		local lo_ok = M.HALF - reach + max_rel.x1 >= M.CLEARANCE and M.HALF - reach + max_rel.z1 >= M.CLEARANCE
		local hi_ok = M.HALF + reach + max_rel.x2 <= last and M.HALF + reach + max_rel.z2 <= last
		if not (lo_ok and hi_ok) then
			return nil, "max_rect plus lattice offsets leaves the cell clearance", "impossible_cell"
		end
		for iz = -1, 1 do
			for ix = -1, 1 do offsets[#offsets + 1] = {ix * M.LATTICE_SPACING, iz * M.LATTICE_SPACING} end
		end
		-- Furthest an activation rect can reach outside its own cell (98 for the measured basis).
		pad = math.max(0, -(M.HALF - reach + act.x1), -(M.HALF - reach + act.z1),
			M.HALF + reach + act.x2 - (M.CELL - 1), M.HALF + reach + act.z2 - (M.CELL - 1))
	end

	local span = 2 * J + 1
	local MAP = M.MAP_LIMIT
	local cache, cached = {}, 0

	local function copy(c)
		return {
			id = c.id, version = c.version, candidate = c.candidate,
			cell = {x = c.cell.x, z = c.cell.z}, center = {x = c.center.x, z = c.center.z},
			town_type = c.town_type, seed = c.seed,
			max_rect = rect_at(c.max_rect, {x = 0, z = 0}), activation_rect = rect_at(c.activation_rect, {x = 0, z = 0}),
		}
	end

	-- Immutable candidate list of one cell, or nil, reason, code. The whole cell declines when
	-- any candidate's activation rect crosses the map limit.
	local function build_cell(seed, cx, cz)
		local ox, oz = cx * M.CELL, cz * M.CELL
		local town_type = M.TYPES[M.draw(seed, M.PURPOSE.TYPE, cx, cz) % #M.TYPES + 1]
		local planner_seed = 1 + M.draw(seed, M.PURPOSE.PLANNER, cx, cz) % planner.SEED_LIMIT
		local list = {}
		for k = 0, N - 1 do
			local jx, jz
			if N == 1 then
				jx = M.draw(seed, M.PURPOSE.JITTER_X, cx, cz) % span - J
				jz = M.draw(seed, M.PURPOSE.JITTER_Z, cx, cz) % span - J
			else
				jx = M.draw(seed, M.PURPOSE.LATTICE_X .. ":" .. k, cx, cz) % span - J
				jz = M.draw(seed, M.PURPOSE.LATTICE_Z .. ":" .. k, cx, cz) % span - J
			end
			local center = {x = ox + M.HALF + offsets[k + 1][1] + jx, z = oz + M.HALF + offsets[k + 1][2] + jz}
			local activation = rect_at(act, center)
			if activation.x1 < -MAP or activation.z1 < -MAP or activation.x2 > MAP or activation.z2 > MAP then
				return nil, "activation envelope exceeds the world map limit", "map_limit"
			end
			list[k + 1] = {
				id = ("%d:%d:%d:%d:%s:%d:%d:%d"):format(M.VERSION, cx, cz, k, town_type, planner_seed, center.x, center.z),
				version = M.VERSION,
				candidate = k,
				cell = {x = cx, z = cz},
				center = center,
				town_type = town_type,
				seed = planner_seed,
				max_rect = rect_at(max_rel, center),
				activation_rect = activation,
			}
		end
		return list
	end

	-- Cached cell list (shared, never handed out), or nil, reason, code.
	local function cell_list(seed, cx, cz)
		local ok, why, code = check_seed(seed)
		if not ok then return nil, why, code end
		if not is_int(cx) or not is_int(cz) then
			return nil, "cell coordinates must be integers", "invalid_cell"
		end
		local key = seed .. "\0" .. cx .. "," .. cz
		local hit = cache[key]
		if hit == nil then
			local list, w, c = build_cell(seed, cx, cz)
			hit = list or {reason = w, code = c}
			if cached >= M.CACHE_LIMIT then cache, cached = {}, 0 end
			cache[key] = hit
			cached = cached + 1
		end
		if hit.code then return nil, hit.reason, hit.code end
		return hit
	end

	-- All candidates of one cell, fresh copies in index order.
	local function cell(seed, cx, cz)
		local list, why, code = cell_list(seed, cx, cz)
		if not list then return nil, why, code end
		local out = {}
		for i, c in ipairs(list) do out[i] = copy(c) end
		return out
	end

	-- One candidate (k defaults to 0, the only one when N = 1).
	local function describe(seed, cx, cz, k)
		local list, why, code = cell_list(seed, cx, cz)
		if not list then return nil, why, code end
		k = k == nil and 0 or k
		if not is_int(k) or k < 0 or k >= N then
			return nil, "candidate index out of range", "invalid_cell"
		end
		return copy(list[k + 1])
	end

	local function lookup(seed, rect)
		local ok, why, code = check_seed(seed)
		if not ok then return nil, why, code end
		if type(rect) ~= "table" or not is_int(rect.x1) or not is_int(rect.z1)
			or not is_int(rect.x2) or not is_int(rect.z2) or rect.x1 > rect.x2 or rect.z1 > rect.z2 then
			return nil, "lookup rect must be integer {x1, z1, x2, z2} with x1 <= x2 and z1 <= z2", "invalid_rect"
		end
		-- Cells outside the map limit are declined anyway (their activation rect crosses it),
		-- so clamping the rect bounds the walk without dropping an accepted cell. The query is
		-- padded by the overhang so a cell whose activation rect reaches into rect is found.
		local x1, z1 = math.max(rect.x1 - pad, -MAP), math.max(rect.z1 - pad, -MAP)
		local x2, z2 = math.min(rect.x2 + pad, MAP), math.min(rect.z2 + pad, MAP)
		local out = {}
		if x1 > x2 or z1 > z2 then return out end
		for cz = M.cell_index(z1), M.cell_index(z2) do
			for cx = M.cell_index(x1), M.cell_index(x2) do
				local list = cell_list(seed, cx, cz)
				if list then
					for _, c in ipairs(list) do out[#out + 1] = copy(c) end
				end
			end
		end
		return out
	end

	return {describe = describe, cell = cell, lookup = lookup, candidates = N, overhang = pad}
end

return M
