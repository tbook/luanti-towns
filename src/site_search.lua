-- Towns: nearby town-site search and terrain inspection (ticket #14).
-- Read-only: this module never writes to the world. Selection and ordering
-- are pure Lua; world access goes through an injectable `env` so the whole
-- asynchronous search runs under plain Lua 5.1 in tests/site_search_tests.lua.
--
-- Usage: local ss = dofile(".../site_search.lua")(placement, planner)
--
--   ss.search(player_pos, seed, opts, done [, env])
--     player_pos  {x, y, z} the player's position (core player:get_pos()).
--                 Rounded to nodes; the node below the feet (y rounded - 1)
--                 is the reference ground used for the vertical windows.
--     seed        integer accepted by planner.check_seed (|seed| <=
--                 ss.MAX_SEED = planner.SEED_LIMIT); else raises an error.
--     opts        optional table overriding any ss.CONSTANTS entry by its
--                 name in lower case (step, max_radius, player_margin,
--                 max_range, ...) and `planner_opts` (forwarded to
--                 planner.plan). Once the plan exists its actual extent
--                 grows the default max_radius so that a larger town is still
--                 searched the same distance beyond its edge; terrain limits
--                 never change.
--                 Build bounds always come from the composed structures, so
--                 the buildings' real schematic boxes are what is inspected
--                 and emerged: opts.entries = catalog entries for the plan's
--                 named sites (a table), or planner_opts.landmarks (a
--                 landmark profile, whose entries are used) must be given,
--                 else the search raises an error. Y runs from the lowest of
--                 surface, ground and every foundation (ground -
--                 ground_offset) up to the top node of the tallest placed
--                 structure (or the highest surface), result.structures lists
--                 the composed boxes (src/preflight.lua), and an
--                 uncomposable plan ends the search with a failure.
--                 Flattening and every cut/fill limit are unchanged.
--     done        called exactly once: done(result, nil, details) on
--                 success or done(nil, summary, details) on failure.
--     env         defaults to ss.core_env(core): {emerge, get_node_name,
--                 node_info}; see below.
--
--   result = {
--     center       = {x, z}          chosen town centre (absolute)
--     plan         = planner plan    plan(center, seed), untouched
--     ground_y     = integer         finished ground level: the median of
--                                    all column surface heights (see
--                                    ss.median for even-count ties)
--     heights      = {[x] = {[z] = y}}  surface (topmost solid node) of every
--                                    boundary column; ss.height_at(result,x,z)
--     wet          = nil | {count, max_depth, surfaces = {[x]={[z]=y}}}
--                                    wet mode only (MAX_WATER_DEPTH > 0): the
--                                    landfilled columns and their liquid/ice
--                                    surface; heights holds their BED
--     columns      = integer         number of inspected columns
--     min_height, max_height = integer   actual surface extremes, including outliers
--     build_bounds = {min={x,y,z}, max={x,y,z}} inclusive, exact: X/Z are
--                    plan.bounds; Y runs from the lowest cut/fill row or
--                    structure foundation up to the top of the tallest
--                    structure (or the highest surface).
--     structures   = composed boxes of the plan's buildings
--     inspection_volume = {min, max} emerged and read during the search
--                    (plan bounds X/Z, surface window ref_y-48 .. ref_y+48+1).
--     build_volume = {min, max} also emerged for the accepted site:
--                    build_bounds plus CUT_FILL_MARGIN around and below.
--                    No extra foundation depth below min_height is included.
--     candidate    = {index, dx, dz}  offset from the player in the order
--     candidates_tried = integer
--     rejections   = {[code] = count}  for the candidates rejected on the way
--   }
--   details (both outcomes) = {candidates_tried, candidates_total,
--     rejections = {[code]=count}, examples = {[code]="first message"}}
--
-- A plan failure for the seed ends the search at once (plan_failed x1).
-- Also: the player must stand on solid ground (else done(nil, msg)); a
-- throwing env function or any internal error ends the search through
-- done(nil, "internal error: ..."). Emerge requests have a watchdog.
-- Terrain classes are those of placement.classify. Ice (ice,
-- packed ice, frosted ice, any slippery node) counts as water: never ground,
-- so a frozen lake is rejected as "water". Cactus etc. are not special-cased.
-- Wet columns (ticket #104, opt-in through MAX_WATER_DEPTH > 0): a column
-- whose topmost non-air/non-vegetation node is liquid or ice and which reaches
-- solid ground within MAX_WATER_DEPTH nodes is "wet". Its `surface` is the top
-- liquid/ice node; its `bed` is the topmost solid node below (result.heights
-- keeps the BED, so the builder fills from solid ground; result.wet holds the
-- surfaces). The finished ground is
--     ground_y = max(median of the surface heights (bed for dry columns,
--                water surface for wet ones), highest wet surface in the
--                footprint or in the one-node ring around it)
-- so the water level is never above the finished ground and no liquid can
-- flow back into the cleared volume. Range and cut/fill are measured on
-- surfaces (range, upper cut) and beds (lower fill: min_height is the lowest
-- bed). Lava and unknown nodes always reject. Rejection codes added: lava,
-- too_deep_water (a column deeper than MAX_WATER_DEPTH, or water without a
-- bed in the window), too_wet (wet columns > MAX_WET_FRACTION of the footprint).
-- Rejection codes: out_of_range (centre beyond planner's +/-31000),
-- emerge_timeout (see EMERGE_TIMEOUT), player_inside (player within the candidate's bounds plus
-- PLAYER_MARGIN), plan_failed, emerge_failed (CANCELLED/ERRORED), water
-- (water/lava), unknown (ignore/unloaded/unregistered node), no_ground (no
-- solid node in the window), too_high (surface reaches the window top, the
-- real surface is not seen), too_uneven (range > MAX_RANGE).
--
-- env contract (all thin core wrappers; core_env builds them):
--   env.emerge(minpos, maxpos, cb)   cb(ok) exactly once, after the whole
--                                    area is emerged; ok=false on
--                                    CANCELLED/ERRORED.
--   env.get_node_name(x, y, z)       node name ("ignore" if unloaded)
--   env.node_info(name)              {walkable, liquid, clearable} or nil
--   env.after(seconds, fn)           watchdog timer (core.after)
--   env.log(level, msg)              optional; receives errors raised by `done`
-- `done` should not throw: a throwing `done` is logged via env.log and
-- swallowed (never rethrown into engine callbacks).
-- Unknown opts keys, non-integer scan_up/scan_down, non-finite numbers and
-- NaN/inf player_pos components raise errors.
-- The search never calls anything else on env.

return function(placement, planner)

local M = {}

local function load_sibling(name)
	local c = rawget(_G, "core")
	if c and c.get_modpath and c.get_current_modname then
		return dofile(c.get_modpath(c.get_current_modname()) .. "/src/" .. name)
	end
	return dofile("src/" .. name)
end
local preflight = load_sibling("preflight.lua")

-- Largest seed accepted by planner.plan (alias of planner.SEED_LIMIT).
M.MAX_SEED = planner.SEED_LIMIT

M.CONSTANTS = {
	STEP = 16,                -- candidate lattice spacing, nodes
	MAX_RADIUS = 320,         -- candidate centres within this distance, for a
	                          --  town whose edge is REACH_EDGE from its centre
	PLAYER_MARGIN = 4,        -- player must be this far outside the bounds
	MAX_RANGE = 16,           -- max range of the middle surface heights
	OUTLIER_PERCENT = 5,      -- trim up to 2.5% of columns from each tail
	MAX_CUT_FILL = 24,        -- every surface must be within this of the median
	CUT_FILL_MARGIN = 8,      -- extra nodes emerged around/below the town
	SCAN_UP = 48,             -- surface window: reference ground +/- this
	SCAN_DOWN = 48,
	EMERGE_TIMEOUT = 30,      -- seconds to wait for one emerge before giving up
	MAX_CONSECUTIVE_TIMEOUTS = 3, -- then fail the whole search
	CENTER_LIMIT = 31000,     -- planner.plan accepts |centre| <= this
	-- Wet sites (ticket #104). Both default to 0 = off: any liquid or ice
	-- node in a footprint column rejects the candidate as "water". Opt in with
	-- M.WET_DEFAULTS (or any positive values); see "Wet columns" in the header.
	MAX_WATER_DEPTH = 0,      -- deepest liquid/ice column that is landfilled, nodes
	MAX_WET_FRACTION = 0,     -- largest share of footprint columns that may be wet
}

-- Half extent of the town M.CONSTANTS.MAX_RADIUS is calibrated for; a plan
-- reaching farther from its centre adds the difference to the default radius.
M.REACH_EDGE = 48

-- Conservative loosening used by /towns_generate: columns under at most 6
-- nodes of water/ice are landfilled, up to a quarter of the footprint columns.
M.WET_DEFAULTS = {max_water_depth = 6, max_wet_fraction = 0.25}

local function constants(opts)
	local C = {}
	for k, v in pairs(M.CONSTANTS) do C[k] = v end
	if opts then
		for k, v in pairs(opts) do
			local key = type(k) == "string" and k:upper() or nil
			if key and M.CONSTANTS[key] ~= nil then
				if type(v) ~= "number" or v ~= v or v < 0 or v == math.huge then
					error("towns site_search: opts." .. k .. " must be a finite number >= 0, got "
						.. tostring(v), 3)
				end
				C[key] = v
			elseif k ~= "planner_opts" and k ~= "entries" then
				error("towns site_search: unknown option '" .. tostring(k) .. "'", 3)
			end
		end
	end
	for _, name in ipairs({"SCAN_UP", "SCAN_DOWN"}) do
		if C[name] ~= math.floor(C[name]) then
			error("towns site_search: opts." .. name:lower() .. " must be an integer, got "
				.. tostring(C[name]), 3)
		end
	end
	if C.STEP < 1 or C.STEP ~= math.floor(C.STEP) then
		error("towns site_search: opts.step must be an integer >= 1, got " .. tostring(C.STEP), 3)
	end
	if C.MAX_WET_FRACTION > 1 then
		error("towns site_search: opts.max_wet_fraction must be <= 1", 3)
	end
	if C.MAX_WATER_DEPTH ~= math.floor(C.MAX_WATER_DEPTH) then
		error("towns site_search: opts.max_water_depth must be an integer", 3)
	end
	if C.OUTLIER_PERCENT >= 100 then
		error("towns site_search: opts.outlier_percent must be < 100", 3)
	end
	local popts = type(opts) == "table" and opts.planner_opts or nil
	if type(opts) == "table" and opts.entries ~= nil and type(opts.entries) ~= "table" then
		error("towns site_search: opts.entries must be a catalog-entry table", 3)
	end
	if not (type(opts) == "table" and type(opts.entries) == "table")
			and not (type(popts) == "table" and type(popts.landmarks) == "table") then
		error("towns site_search: opts.entries or opts.planner_opts.landmarks is required "
			.. "to compose the structure bounds", 3)
	end
	-- A medieval town (landmark profile) is searched at least as far as the
	-- old 208-node envelope (planner.CONSTANTS.ENVELOPE) reaches beyond
	-- REACH_EDGE, whatever the seed's actual extent;
	-- an explicit opts.max_radius is taken as given. Larger plans grow it
	-- further once planned (see search).
	if type(popts) == "table" and type(popts.landmarks) == "table" then
		local explicit = false
		for k in pairs(opts) do
			if type(k) == "string" and k:upper() == "MAX_RADIUS" then explicit = true end
		end
		local growth = math.floor(planner.CONSTANTS.ENVELOPE / 2 - M.REACH_EDGE)
		if growth > 0 and not explicit then C.MAX_RADIUS = C.MAX_RADIUS + growth end
	end
	return C
end

local function round(v) return math.floor(v + 0.5) end

------------------------------------------------------------------------
-- Pure helpers
------------------------------------------------------------------------

-- Candidate offsets {dx, dz} (multiples of step, Euclidean length <=
-- radius), nearest first; ties broken by dz then dx. Deterministic.
function M.candidate_offsets(step, radius)
	local n = math.floor(radius / step)
	local list = {}
	for iz = -n, n do
		for ix = -n, n do
			local dx, dz = ix * step, iz * step
			if dx * dx + dz * dz <= radius * radius then
				list[#list + 1] = {dx = dx, dz = dz, d2 = dx * dx + dz * dz}
			end
		end
	end
	table.sort(list, function(a, b)
		if a.d2 ~= b.d2 then return a.d2 < b.d2 end
		if a.dz ~= b.dz then return a.dz < b.dz end
		return a.dx < b.dx
	end)
	return list
end

-- Does the player's X/Z fall inside bounds {x1,z1,x2,z2} grown by margin?
function M.player_inside(bounds, px, pz, margin)
	return px >= bounds.x1 - margin and px <= bounds.x2 + margin
		and pz >= bounds.z1 - margin and pz <= bounds.z2 + margin
end

-- Every distinct X/Z of the union of rects, ordered by x then z.
-- Returns a list of {x, z}.
function M.boundary_columns(rects)
	local seen, cols = {}, {}
	for _, r in ipairs(rects) do
		for x = r.x1, r.x2 do
			local col = seen[x]
			if not col then col = {}; seen[x] = col end
			for z = r.z1, r.z2 do
				if not col[z] then
					col[z] = true
					cols[#cols + 1] = {x = x, z = z}
				end
			end
		end
	end
	table.sort(cols, function(a, b)
		if a.x ~= b.x then return a.x < b.x end
		return a.z < b.z
	end)
	return cols
end

-- Median of a list of integers. For an even count the LOWER of the two
-- middle values is returned (sorted[n/2]), so the result is always one of
-- the actual surface heights and deterministic.
function M.median(values)
	local n = #values
	if n == 0 then return nil end
	local s = {}
	for i = 1, n do s[i] = values[i] end
	table.sort(s)
	return s[math.floor((n + 1) / 2)]
end

-- Volume emerged and read during the search: the plan bounds in X/Z, and in
-- Y the surface window ref_y-SCAN_DOWN .. ref_y+SCAN_UP plus one sentinel row
-- on top (a surface found in the sentinel row means the real surface is out
-- of the window: too_high). Returns volume, scan_top (the sentinel y),
-- scan_bottom. ref_y = reference ground y (the node under the player).
function M.inspection_volume(plan_bounds, ref_y, C)
	local b = plan_bounds
	local top = ref_y + C.SCAN_UP + 1
	local bottom = ref_y - C.SCAN_DOWN
	-- Wet mode also reads the one-node ring around the plan (outside water).
	local m = C.MAX_WATER_DEPTH > 0 and 1 or 0
	return {
		min = {x = b.x1 - m, y = bottom, z = b.z1 - m},
		max = {x = b.x2 + m, y = top, z = b.z2 + m},
	}, top, bottom
end

-- Volume emerged for an accepted site, so the build ticket need not emerge
-- again: build bounds plus CUT_FILL_MARGIN around and below.
function M.build_volume(build_bounds, C)
	local m = C.CUT_FILL_MARGIN
	local b = build_bounds
	return {
		min = {x = b.min.x - m, y = b.min.y - m, z = b.min.z - m},
		max = {x = b.max.x + m, y = b.max.y, z = b.max.z + m},
	}
end

-- Exact build bounds for an accepted site (see header). `comp` (optional,
-- preflight.compose result): Y runs from the lowest of the surface, ground and
-- every structure foundation up to the top of the tallest selected structure
-- (or the highest surface).
function M.build_bounds(plan_bounds, ground_y, min_h, max_h, comp)
	local lo = math.min(min_h, ground_y)
	local hi = math.max(max_h, comp.max_y or ground_y)
	if comp.min_y then lo = math.min(lo, comp.min_y) end
	return {
		min = {x = plan_bounds.x1, y = lo, z = plan_bounds.z1},
		max = {x = plan_bounds.x2, y = hi, z = plan_bounds.z2},
	}
end

function M.height_at(result, x, z)
	local col = result.heights[x]
	return col and col[z]
end

-- Scan of one column in wet mode (ticket #104). class_at(y) returns the
-- placement.classify classes plus "lava" (named lava). Returns
--   bed, nil, nil, surface   wet column (surface = topmost liquid/ice y)
--   bed                      dry column
--   nil, problem, y          problem: lava, unknown, no_ground, too_deep_water
-- (liquid/ice, then vegetation, then solid is wet; air under a liquid is a
-- cave or ice-sheet gap and rejects as no_ground; no bed within max_depth
-- nodes of the surface is too_deep_water, including water that runs to the
-- bottom of the window.)
function M.scan_column_wet(class_at, top, bottom, max_depth)
	local surface
	for y = top, bottom, -1 do
		local c = class_at(y)
		if c == "solid" then
			if surface then return y, nil, nil, surface end
			return y
		elseif c == "unknown" or c == "lava" then
			return nil, c, y
		elseif c == "water" then
			surface = surface or y
			if surface - y + 1 > max_depth then return nil, "too_deep_water", y end
		elseif c == "air" and surface then
			return nil, "no_ground", y
		end
	end
	if surface then return nil, "too_deep_water", bottom end
	return nil, "no_ground", bottom
end

-- Surface y of a ring column (water outside the footprint) or nil.
function M.ring_surface(class_at, top, bottom)
	for y = top, bottom, -1 do
		local c = class_at(y)
		if c == "water" then return y end
		if c == "solid" or c == "unknown" or c == "lava" then return nil end
	end
end

-- Columns adjacent (4-neighbourhood) to the union but not in it.
function M.ring_columns(rects)
	local inside = {}
	for _, r in ipairs(rects) do
		for x = r.x1, r.x2 do
			inside[x] = inside[x] or {}
			for z = r.z1, r.z2 do inside[x][z] = true end
		end
	end
	local seen, list = {}, {}
	for x, col in pairs(inside) do
		for z in pairs(col) do
			for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
				local nx, nz = x + d[1], z + d[2]
				if not (inside[nx] and inside[nx][nz]) then
					seen[nx] = seen[nx] or {}
					if not seen[nx][nz] then
						seen[nx][nz] = true
						list[#list + 1] = {x = nx, z = nz}
					end
				end
			end
		end
	end
	table.sort(list, function(a, b)
		if a.x ~= b.x then return a.x < b.x end
		return a.z < b.z
	end)
	return list
end

-- Inspects every column. read(x, z) -> height | nil, problem, y
-- (the placement.scan_column results; in wet mode scan_column_wet's, whose
-- 4th value is the liquid surface of a wet column).
-- Pure given `read`.
-- Returns info table, or nil, code, message with code one of
-- water, lava, unknown, no_ground, too_high, too_uneven, too_deep_water,
-- too_wet.
-- Optional outlier_percent trims equally from both tails, rounded down so
-- the allowance is never exceeded. Actual extremes and all heights are kept
-- for construction. max_cut_fill caps every column relative to the median.
-- Optional `wet` = {max_depth, max_fraction, ring = columns} enables wet
-- columns (see the header): info.heights stays the bed, info.wet =
-- {count, max_depth, surfaces = {[x]={[z]=y}}}, and ground_y is raised to the
-- highest water surface (footprint or ring) when the median is lower.
function M.inspect_columns(columns, read, top, max_range, outlier_percent, max_cut_fill, wet)
	local heights, list = {}, {}
	local lo, hi, bed_lo
	local nwet, wet_depth, wet_max_surf, surfaces = 0, 0, nil, {}
	for _, c in ipairs(columns) do
		local h, problem, py, surf = read(c.x, c.z)
		if not h then
			if problem == "water" then
				return nil, "water", ("water or lava at (%d,%d,%d)"):format(c.x, py, c.z)
			elseif problem == "lava" then
				return nil, "lava", ("lava at (%d,%d,%d)"):format(c.x, py, c.z)
			elseif problem == "too_deep_water" then
				return nil, "too_deep_water",
					("water at (%d,%d) deeper than %d nodes (no bed above y=%d)"):format(
						c.x, c.z, wet and wet.max_depth or 0, py)
			elseif problem == "unknown" then
				return nil, "unknown", ("unloaded or unknown node at (%d,%d,%d)"):format(c.x, py, c.z)
			end
			return nil, "no_ground", ("no solid ground at (%d,%d) down to y=%d"):format(c.x, c.z, py)
		end
		local v = surf or h -- the height this column contributes to range/median
		if v >= top then
			return nil, "too_high", ("surface at (%d,%d) reaches the inspection window top y=%d"):format(c.x, c.z, top)
		end
		local col = heights[c.x]
		if not col then col = {}; heights[c.x] = col end
		col[c.z] = h
		if surf then
			nwet = nwet + 1
			wet_depth = math.max(wet_depth, surf - h)
			if not wet_max_surf or surf > wet_max_surf then wet_max_surf = surf end
			surfaces[c.x] = surfaces[c.x] or {}
			surfaces[c.x][c.z] = surf
		end
		list[#list + 1] = v
		if not lo or v < lo then lo = v end
		if not hi or v > hi then hi = v end
		if not bed_lo or h < bed_lo then bed_lo = h end
	end
	if not lo then return nil, "no_ground", "no columns to inspect" end
	if nwet > 0 and wet and #list > 0 and nwet > wet.max_fraction * #list then
		return nil, "too_wet",
			("%d of %d columns (%.1f%%) are under water or ice, more than the allowed %.1f%%"):format(
				nwet, #list, 100 * nwet / #list, 100 * wet.max_fraction)
	end
	table.sort(list)
	local ground = list[math.floor((#list + 1) / 2)]
	local trim = math.floor(#list * (outlier_percent or 0) / 200)
	local core_lo, core_hi = list[trim + 1], list[#list - trim]
	if core_hi - core_lo > max_range then
		return nil, "too_uneven",
			("middle surface heights vary from y=%d to y=%d (range %d, max %d; %d columns excluded from each tail)"):format(
				core_lo, core_hi, core_hi - core_lo, max_range, trim)
	end
	-- Water must never end up above the finished ground (no flow back in).
	if wet and wet.ring then
		for _, c in ipairs(wet.ring) do
			local rs = wet.read_ring(c.x, c.z)
			if rs and (not wet_max_surf or rs > wet_max_surf) then wet_max_surf = rs end
		end
	end
	local label = "median"
	if wet_max_surf and wet_max_surf > ground then
		ground, label = wet_max_surf, "water-level ground"
	end
	if max_cut_fill and math.max(ground - bed_lo, hi - ground) > max_cut_fill then
		return nil, "too_uneven",
			("surface extremes y=%d..%d require more than %d nodes of cut/fill at %s y=%d"):format(
				bed_lo, hi, max_cut_fill, label, ground)
	end
	local info = {heights = heights, list = list, min_height = bed_lo, max_height = hi,
		ground_y = ground}
	if nwet > 0 then
		info.wet = {count = nwet, max_depth = wet_depth, surfaces = surfaces}
	end
	return info
end

-- "water x3, too_uneven x10": most frequent first, ties by code.
function M.format_rejections(rejections)
	local codes = {}
	for code in pairs(rejections) do codes[#codes + 1] = code end
	table.sort(codes, function(a, b)
		if rejections[a] ~= rejections[b] then return rejections[a] > rejections[b] end
		return a < b
	end)
	local parts = {}
	for _, code in ipairs(codes) do
		parts[#parts + 1] = code .. " x" .. rejections[code]
	end
	return table.concat(parts, ", ")
end

------------------------------------------------------------------------
-- Search (callback driven)
------------------------------------------------------------------------
local function same_rect(a, b)
	return a.x1 == b.x1 and a.z1 == b.z1 and a.x2 == b.x2 and a.z2 == b.z2
end

local TRANSLATED_POINTS = {
	center = true, pos = true, entrance = true, outside = true, approach = true,
}
local function same_translation(base, actual, dx, dz, key)
	if type(base) ~= type(actual) then return false end
	if type(base) ~= "table" then return base == actual end
	if type(base.x1) == "number" and type(base.z1) == "number"
			and type(base.x2) == "number" and type(base.z2) == "number" then
		return actual.x1 == base.x1 + dx and actual.x2 == base.x2 + dx
			and actual.z1 == base.z1 + dz and actual.z2 == base.z2 + dz
	end
	if TRANSLATED_POINTS[key] and type(base.x) == "number" and type(base.z) == "number" then
		return actual.x == base.x + dx and actual.z == base.z + dz
			and same_translation(base.y, actual.y, 0, 0)
	end
	for k, v in pairs(base) do
		if actual[k] == nil or not same_translation(v, actual[k], dx, dz, k) then return false end
	end
	for k in pairs(actual) do if base[k] == nil then return false end end
	return true
end

-- Exact lava node names (wet mode reports them as "lava", not "water").
M.LAVA_NODES = {
	["mcl_core:lava_source"] = true, ["mcl_core:lava_flowing"] = true,
	["default:lava_source"] = true, ["default:lava_flowing"] = true,
}

function M.search(player_pos, seed, opts, done, env)
	local seed_ok, seed_msg = planner.check_seed(seed)
	if not seed_ok then
		error("towns site_search: " .. tostring(seed_msg), 2)
	end
	if type(player_pos) ~= "table" or type(player_pos.x) ~= "number"
			or type(player_pos.y) ~= "number" or type(player_pos.z) ~= "number" then
		error("towns site_search: player_pos must be a table with numeric x, y, z", 2)
	end
	if type(done) ~= "function" then
		error("towns site_search: done must be a function", 2)
	end
	for _, c in ipairs({"x", "y", "z"}) do
		local v = player_pos[c]
		if v ~= v or v == math.huge or v == -math.huge then
			error("towns site_search: player_pos." .. c .. " must be finite, got " .. tostring(v), 2)
		end
	end
	opts = opts or {}
	if type(opts) ~= "table" then
		error("towns site_search: opts must be a table", 2)
	end
	local C = constants(opts)
	env = env or M.core_env(core)
	local px, pz = round(player_pos.x), round(player_pos.z)
	local ref_y = round(player_pos.y) - 1
	local offsets = M.candidate_offsets(C.STEP, C.MAX_RADIUS)
	local rejections, examples = {}, {}
	local tried, finished = 0, false
	local logf = rawget(env, "log") or function() end

	local function details()
		return {
			candidates_tried = tried, candidates_total = #offsets,
			rejections = rejections, examples = examples,
		}
	end
	local function finish(result, summary)
		if finished then return end
		finished = true
		-- `done` must not throw. If it does, that must never propagate into
		-- the engine's emerge/timer callbacks (fatal to the server): it is
		-- logged through env.log and swallowed, on every path.
		local ok, err = pcall(done, result, summary, details())
		if not ok then
			logf("error", "towns site_search: done callback raised: " .. tostring(err))
		end
	end
	local function reject(code, msg)
		rejections[code] = (rejections[code] or 0) + 1
		examples[code] = examples[code] or msg
	end

	-- The reference ground must be solid, so a player in
	-- flight or on water gets a clear failure, not a silently wrong window.
	local gok, gname = pcall(env.get_node_name, px, ref_y, pz)
	if not gok then
		return finish(nil, "internal error: " .. tostring(gname))
	end
	local cok, gclass = pcall(placement.classify, gname, env.node_info)
	if not cok then
		return finish(nil, "internal error: " .. tostring(gclass))
	end
	if gclass ~= "solid" then
		return finish(nil, ("You must be standing on solid ground (found '%s' below you at (%d,%d,%d)). Nothing was changed."):format(
			tostring(gname), px, ref_y, pz))
	end

	local wet_mode = C.MAX_WATER_DEPTH > 0
	local function class_at(x, y, z)
		local name = env.get_node_name(x, y, z)
		if wet_mode and M.LAVA_NODES[name] then return "lava" end
		return placement.classify(name, env.node_info)
	end

	-- The layout depends only on the seed and the centre merely translates
	-- it (planner contract), and planning costs tens of ms, so the plan is
	-- computed once (at the origin) and translated for the cheap candidate
	-- tests. The accepted candidate gets a genuine planner.plan(center, seed).
	local base, base_why
	local function shifted(r, dx, dz)
		return {x1 = r.x1 + dx, z1 = r.z1 + dz, x2 = r.x2 + dx, z2 = r.z2 + dz}
	end

	-- Driver: candidates are processed in a loop (never by recursion, so
	-- synchronous emerges cannot grow the stack); emerge results arrive as
	-- continuations. Every error is contained and ends the search through
	-- done(), never through the engine's emerge callback.
	local index, waiting, cont, running = 0, false, nil, false
	local timeouts = 0
	local pump

	-- Emerges a volume with a watchdog. on_result("ok"|"failed"|"timeout")
	-- runs once, from the driver loop; late callbacks are ignored.
	local function emerge_step(minp, maxp, on_result)
		waiting = true
		local settled = false
		local function settle(status)
			if settled or finished then return end
			settled = true
			waiting = false
			cont = function() on_result(status) end
			pump()
		end
		env.emerge(minp, maxp, function(ok) settle(ok and "ok" or "failed") end)
		if not settled then
			env.after(C.EMERGE_TIMEOUT, function() settle("timeout") end)
		end
	end

	-- Handles a failed/timed-out emerge; returns true if the candidate is dead.
	local function emerge_bad(status, center)
		if status == "ok" then
			timeouts = 0
			return false
		end
		local where = ("(%d,%d)"):format(center.x, center.z)
		if status == "timeout" then
			timeouts = timeouts + 1
			reject("emerge_timeout", "emerge did not finish within "
				.. C.EMERGE_TIMEOUT .. "s for candidate centre " .. where)
			if timeouts >= C.MAX_CONSECUTIVE_TIMEOUTS then
				finish(nil, ("Giving up: %d emerge requests in a row timed out after %ds. Nothing was changed."):format(
					timeouts, C.EMERGE_TIMEOUT))
			end
		else
			timeouts = 0
			reject("emerge_failed", "emerge cancelled or failed for candidate centre " .. where)
		end
		return true
	end

	local function candidate(i)
		local off = offsets[i]
		local center = {x = px + off.dx, z = pz + off.dz}
		tried = tried + 1
		if math.abs(center.x) > C.CENTER_LIMIT or math.abs(center.z) > C.CENTER_LIMIT then
			return reject("out_of_range", ("centre (%d,%d) is beyond the planner limit %d"):format(
				center.x, center.z, C.CENTER_LIMIT))
		end
		if base == nil then
			local ok, p, why = pcall(planner.plan, {x = 0, z = 0}, seed, opts.planner_opts)
			if ok then
				base, base_why = p or false, why
			else
				base, base_why = false, p
			end
			if base then
				-- Size search reach from the selected plan's actual footprint.
				-- This also covers Roman (authored) plans.
				local c = base.center or {x = 0, z = 0}
				local b = base.bounds
				local edge = math.max(c.x - b.x1, b.x2 - c.x, c.z - b.z1, b.z2 - c.z)
				local growth = math.max(0, math.floor(edge - M.REACH_EDGE))
				local explicit = false
				for k in pairs(opts) do
					if type(k) == "string" and k:upper() == "MAX_RADIUS" then explicit = true end
				end
				local target_radius = M.CONSTANTS.MAX_RADIUS + growth
				if growth > 0 and not explicit and target_radius > C.MAX_RADIUS then
					C.MAX_RADIUS = target_radius
					offsets = M.candidate_offsets(C.STEP, C.MAX_RADIUS)
					index = 0
					tried = tried - 1 -- this candidate is counted again from the new list
					return
				end
			end
		end
		if not base then
			-- The layout depends only on the seed, so every centre fails
			-- the same way: fail fast with the planner's reason.
			reject("plan_failed", tostring(base_why))
			return finish(nil, ("No town plan for seed %s: %s. Nothing was changed."):format(
				tostring(seed), tostring(base_why)))
		end
		local sx, sz = center.x - base.center.x, center.z - base.center.z
		local bounds = shifted(base.bounds, sx, sz)
		do
			-- Read and build volumes (margins included) must stay inside the
			-- map limits; otherwise the emerge could only time out.
			local m = C.CUT_FILL_MARGIN
			if bounds.x1 - m < -C.CENTER_LIMIT or bounds.x2 + m > C.CENTER_LIMIT
					or bounds.z1 - m < -C.CENTER_LIMIT or bounds.z2 + m > C.CENTER_LIMIT then
				return reject("out_of_range", ("volume around centre (%d,%d) extends beyond +/-%d"):format(
					center.x, center.z, C.CENTER_LIMIT))
			end
		end
		if M.player_inside(bounds, px, pz, C.PLAYER_MARGIN) then
			return reject("player_inside",
				("player at (%d,%d) is within the town bounds"):format(px, pz))
		end
		local rects = {}
		for k, r in ipairs(base.boundary.rects) do rects[k] = shifted(r, sx, sz) end
		local volume, top, bottom = M.inspection_volume(bounds, ref_y, C)

		emerge_step(volume.min, volume.max, function(status)
			if emerge_bad(status, center) then return end
			local read, wet
			if wet_mode then
				read = function(x, z)
					return M.scan_column_wet(function(y) return class_at(x, y, z) end,
						top, bottom, C.MAX_WATER_DEPTH)
				end
				wet = {max_depth = C.MAX_WATER_DEPTH, max_fraction = C.MAX_WET_FRACTION,
					ring = M.ring_columns(rects),
					read_ring = function(x, z)
						return M.ring_surface(function(y) return class_at(x, y, z) end, top, bottom)
					end}
			else
				read = function(x, z)
					return placement.scan_column(function(y) return class_at(x, y, z) end, top, bottom)
				end
			end
			local info, code, msg = M.inspect_columns(M.boundary_columns(rects), read,
				top, C.MAX_RANGE, C.OUTLIER_PERCENT, C.MAX_CUT_FILL, wet)
			if not info then return reject(code, msg) end

			-- Real plan for the accepted site; it must be exactly the
			-- translated layout that was inspected.
			local pok, plan, pwhy = pcall(planner.plan, center, seed, opts.planner_opts)
			local same = pok and plan and same_translation(base, plan, sx, sz)
			if not same then
				return reject("plan_failed", (not pok and tostring(plan)) or (pwhy and tostring(pwhy))
					or "plan is not a translation of the seed's layout")
			end

			local ground = info.ground_y
			local lm = type(opts.planner_opts) == "table" and opts.planner_opts.landmarks
			local entries = opts.entries or {}
			if type(opts.entries) ~= "table" then
				for _, n in ipairs({"cathedral", "castle", "city_hall", "jail"}) do
					if lm[n] then entries[lm[n].id] = lm[n] end
				end
				for _, sv in pairs(lm.services or {}) do entries[sv.id] = sv end
				for _, list in pairs(lm.service_variants or {}) do
					for _, sv in ipairs(list) do entries[sv.id] = sv end
				end
				for id, e in pairs(lm.content or {}) do entries[id] = e end
			end
			local comp, cwhy = preflight.compose(plan, entries, ground)
			if not comp then
				return finish(nil, "Town content is invalid: " .. tostring(cwhy)
					.. ". Nothing was changed.")
			end
			local bb = M.build_bounds(bounds, ground, info.min_height, info.max_height, comp)
			local bvol = M.build_volume(bb, C)
			if bb.max.y > C.CENTER_LIMIT or bvol.min.y < -C.CENTER_LIMIT then
				return reject("out_of_range", ("build volume y=%d..%d extends beyond +/-%d"):format(
					bvol.min.y, bvol.max.y, C.CENTER_LIMIT))
			end
			emerge_step(bvol.min, bvol.max, function(status2)
				if emerge_bad(status2, center) then return end
				finish({
					center = center,
					plan = plan,
					ground_y = ground,
					heights = info.heights,
					wet = info.wet,
					columns = #info.list,
					min_height = info.min_height,
					max_height = info.max_height,
					build_bounds = bb,
					structures = comp.structures,
					inspection_volume = volume,
					build_volume = bvol,
					candidate = {index = i, dx = off.dx, dz = off.dz},
					candidates_tried = tried,
					rejections = rejections,
				})
			end)
		end)
	end

	pump = function()
		if running then return end
		running = true
		local ok, err = pcall(function()
			while not finished and not waiting do
				local c = cont
				if c then
					cont = nil
					c()
				else
					index = index + 1
					if index > #offsets then
						local summary = ("No suitable town site within %d nodes of (%d,%d): %d candidates checked"):format(
							C.MAX_RADIUS, px, pz, tried)
						if next(rejections) then
							summary = summary .. "; rejected: " .. M.format_rejections(rejections)
						end
						finish(nil, summary .. ". Nothing was changed.")
					else
						candidate(index)
					end
				end
			end
		end)
		running = false
		if not ok then
			if finished then
				logf("error", "towns site_search: error after finishing: " .. tostring(err))
				return
			end
			finish(nil, "internal error: " .. tostring(err) .. ". Nothing was changed.")
		end
	end

	pump()
end

------------------------------------------------------------------------
-- core.* adapter (the only part that touches the engine)
------------------------------------------------------------------------
function M.core_env(c)
	return {
		node_info = function(name)
			return placement.node_info(c.registered_nodes, name)
		end,
		get_node_name = function(x, y, z)
			return c.get_node({x = x, y = y, z = z}).name
		end,
		after = function(seconds, fn) c.after(seconds, fn) end,
		log = function(level, msg) c.log(level, msg) end,
		-- emerge_area calls back several times (calls_remaining); act once
		-- when the last one arrives, failed if ANY call reported an error.
		emerge = function(minpos, maxpos, cb)
			local failed, fired = false, false
			c.emerge_area(minpos, maxpos, function(_, action, remaining)
				if action == c.EMERGE_CANCELLED or action == c.EMERGE_ERRORED then
					failed = true
				end
				if remaining > 0 or fired then return end
				fired = true
				cb(not failed)
			end)
		end,
	}
end

return M

end
