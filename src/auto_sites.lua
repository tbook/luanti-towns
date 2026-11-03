-- Automatic towns (#394): deterministic site descriptors and bounded cell lookup.
-- Pure Lua: no Minetest globals, no world access, no planner run, no clock and no
-- global random state. Every answer is a function of (world seed string, cell, config).
--
-- API: local auto_sites = dofile("src/auto_sites.lua")
--   sites, reason, code = auto_sites.new(env)
--       env is the auto_bounds environment (auto_bounds.new, #393). It must have
--       activation_rect, max_rect and fit (fit.fits true). The centre jitter (fit.jitter)
--       must keep the activation rect one mapchunk inside its cell on every axis, or the
--       whole configuration declines (impossible cell).
--   sites.describe(seed, cx, cz)  -> descriptor | nil, reason, code
--   sites.lookup(seed, rect)      -> list of descriptors | nil, reason, code
--       rect is {x1, z1, x2, z2} (inclusive, absolute). The list holds the accepted cells
--       whose 1,024-node cell range overlaps rect, ordered by cz then cx ascending.
--   auto_sites.cell_index(v)      floor(v / CELL): the cell index of a node coordinate.
--   auto_sites.draw(seed, purpose, cx, cz) -> integer in [0, HASH_MODULUS)
--
-- Descriptor (fresh table per call; rects and points are absolute world coordinates):
--   id              string, identity: version, cell, town type, planner seed and centre
--   version         VERSION (format changes bump it and are documented in epic #355)
--   cell            {x, z}     signed cell index
--   center          {x, z}     proposed centre, inside the cell with jitter
--   town_type       "medieval" or "roman" (equal weights)
--   seed            planner seed, integer in 1 .. planner.SEED_LIMIT (never the world seed)
--   max_rect        rect       centre + env.max_rect
--   activation_rect rect       centre + env.activation_rect
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
-- where SALT is "towns.auto_sites.v<VERSION>" and purpose is one of M.PURPOSE.

local M = {}
local SOURCE = debug.getinfo(1, "S").source:sub(2)
local MODPATH = SOURCE:match("^(.*)/src/auto_sites.lua$") or "."

local auto_bounds = dofile(MODPATH .. "/src/auto_bounds.lua")
local planner = dofile(MODPATH .. "/src/planner.lua")

M.VERSION = 1
M.CELL = auto_bounds.CELL                       -- 1,024 nodes (design section 2)
M.HALF = M.CELL / 2                             -- 512: the middle of a cell
M.CLEARANCE = auto_bounds.CELL_EDGE_CLEARANCE   -- one mapchunk (80) from each cell edge
M.MAP_LIMIT = auto_bounds.MAP_LIMIT             -- 31000 nodes per axis
M.TYPES = {"medieval", "roman"}                 -- equal initial weights
M.SALT = "towns.auto_sites.v" .. M.VERSION
M.PURPOSE = {
	JITTER_X = "center-jitter-x",
	JITTER_Z = "center-jitter-z",
	TYPE = "town-type",
	PLANNER = "planner-seed",
}
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

-- Builds the lookup for one auto_bounds environment. Only configuration-sized values are
-- kept (the relative rects and the jitter); descriptors are built fresh on each call.
function M.new(env)
	if type(env) ~= "table" then return nil, "auto_bounds environment is required", "invalid_env" end
	local act, max_rel, fit = env.activation_rect, env.max_rect, env.fit
	if not valid_rel_rect(act) or not valid_rel_rect(max_rel) or type(fit) ~= "table" then
		return nil, "environment needs integer activation_rect, max_rect and fit", "invalid_env"
	end
	if not auto_bounds.contains_rect(act, max_rel) then
		return nil, "max_rect is not inside activation_rect", "invalid_env"
	end
	if fit.fits ~= true then
		return nil, "activation envelope does not fit the cell with edge clearance", "impossible_cell"
	end
	local J = fit.jitter
	if not is_int(J) or J < 0 then return nil, "fit.jitter must be a nonnegative integer", "invalid_env" end

	-- Every centre offset in [HALF - J, HALF + J] must keep the activation rect within
	-- [CLEARANCE, CELL - 1 - CLEARANCE] on both axes.
	local last = M.CELL - 1 - M.CLEARANCE
	local lo_ok = M.HALF - J + act.x1 >= M.CLEARANCE and M.HALF - J + act.z1 >= M.CLEARANCE
	local hi_ok = M.HALF + J + act.x2 <= last and M.HALF + J + act.z2 <= last
	if not (lo_ok and hi_ok) then
		return nil, "activation envelope plus jitter leaves the cell clearance", "impossible_cell"
	end

	local span = 2 * J + 1
	local MAP = M.MAP_LIMIT

	local function describe(seed, cx, cz)
		local ok, why, code = check_seed(seed)
		if not ok then return nil, why, code end
		if not is_int(cx) or not is_int(cz) then
			return nil, "cell coordinates must be integers", "invalid_cell"
		end
		local ox, oz = cx * M.CELL, cz * M.CELL
		local jx = M.draw(seed, M.PURPOSE.JITTER_X, cx, cz) % span - J
		local jz = M.draw(seed, M.PURPOSE.JITTER_Z, cx, cz) % span - J
		local center = {x = ox + M.HALF + jx, z = oz + M.HALF + jz}
		local activation = rect_at(act, center)
		if activation.x1 < -MAP or activation.z1 < -MAP or activation.x2 > MAP or activation.z2 > MAP then
			return nil, "activation envelope exceeds the world map limit", "map_limit"
		end
		local town_type = M.TYPES[M.draw(seed, M.PURPOSE.TYPE, cx, cz) % #M.TYPES + 1]
		local planner_seed = 1 + M.draw(seed, M.PURPOSE.PLANNER, cx, cz) % planner.SEED_LIMIT
		return {
			id = ("%d:%d:%d:%s:%d:%d:%d"):format(M.VERSION, cx, cz, town_type, planner_seed, center.x, center.z),
			version = M.VERSION,
			cell = {x = cx, z = cz},
			center = {x = center.x, z = center.z},
			town_type = town_type,
			seed = planner_seed,
			max_rect = rect_at(max_rel, center),
			activation_rect = activation,
		}
	end

	local function lookup(seed, rect)
		local ok, why, code = check_seed(seed)
		if not ok then return nil, why, code end
		if type(rect) ~= "table" or not is_int(rect.x1) or not is_int(rect.z1)
			or not is_int(rect.x2) or not is_int(rect.z2) or rect.x1 > rect.x2 or rect.z1 > rect.z2 then
			return nil, "lookup rect must be integer {x1, z1, x2, z2} with x1 <= x2 and z1 <= z2", "invalid_rect"
		end
		-- Cells outside the map limit are declined anyway (their activation rect crosses it),
		-- so clamping the rect bounds the walk without dropping an accepted cell.
		local x1, z1 = math.max(rect.x1, -MAP), math.max(rect.z1, -MAP)
		local x2, z2 = math.min(rect.x2, MAP), math.min(rect.z2, MAP)
		local out = {}
		if x1 > x2 or z1 > z2 then return out end
		for cz = M.cell_index(z1), M.cell_index(z2) do
			for cx = M.cell_index(x1), M.cell_index(x2) do
				local d = describe(seed, cx, cz)
				if d then out[#out + 1] = d end
			end
		end
		return out
	end

	return {describe = describe, lookup = lookup}
end

return M
