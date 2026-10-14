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
--                 planner.plan). When planner_opts selects a larger envelope
--                 (a landmark profile), the default max_radius grows by
--                 half the extra envelope; terrain limits never change.
--                 opts.structure_bounds = true (ticket #44, needs a landmark
--                 profile in planner_opts): build_bounds then come from the
--                 selected structures instead of the 40-node blockout
--                 clearance: Y runs from the lowest of surface, ground and
--                 every foundation (ground - ground_offset) up to the top
--                 node of the tallest placed structure (or the highest
--                 surface), result.structures lists the composed boxes
--                 (src/preflight.lua), and an uncomposable plan ends the
--                 search with a failure. Default false: legacy bounds.
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
--     columns      = integer         number of inspected columns
--     min_height, max_height = integer   actual surface extremes, including outliers
--     build_bounds = {min={x,y,z}, max={x,y,z}} inclusive, exact: X/Z are
--                    plan.bounds; Y runs from min(min_height, ground_y)
--                    (lowest cut/fill row) up to max(max_height, ground_y +
--                    BLOCKOUT_CLEARANCE), i.e. includes cut/fill and the
--                    landmark blockout clearance.
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
-- Terrain classes are exactly Phase 1's (placement.classify). Ice (ice,
-- packed ice, frosted ice, any slippery node) counts as water: never ground,
-- so a frozen lake is rejected as "water". Cactus etc. are not special-cased.
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
	MAX_RADIUS = 320,         -- candidate centres within this distance
	PLAYER_MARGIN = 4,        -- player must be this far outside the bounds
	MAX_RANGE = 16,           -- max range of the middle surface heights
	OUTLIER_PERCENT = 5,      -- trim up to 2.5% of columns from each tail
	MAX_CUT_FILL = 24,        -- every surface must be within this of the median
	LANDMARK_BLOCKOUT_HEIGHT = 40, -- tallest landmark blockout above ground
	BLOCKOUT_MARGIN = 4,      -- slack above it (#15 may tune both)
	CUT_FILL_MARGIN = 8,      -- extra nodes emerged around/below the town
	SCAN_UP = 48,             -- surface window: reference ground +/- this
	SCAN_DOWN = 48,
	EMERGE_TIMEOUT = 30,      -- seconds to wait for one emerge before giving up
	MAX_CONSECUTIVE_TIMEOUTS = 3, -- then fail the whole search
	CENTER_LIMIT = 31000,     -- planner.plan accepts |centre| <= this
}

local function constants(opts)
	local C = {}
	for k, v in pairs(M.CONSTANTS) do C[k] = v end
	if opts then
		for k, v in pairs(opts) do
			local key = type(k) == "string" and k:upper() or nil
			if k == "structure_bounds" then
				if type(v) ~= "boolean" then
					error("towns site_search: opts.structure_bounds must be a boolean", 3)
				end
				C.STRUCTURE_BOUNDS = v
			elseif key and M.CONSTANTS[key] ~= nil then
				if type(v) ~= "number" or v ~= v or v < 0 or v == math.huge then
					error("towns site_search: opts." .. k .. " must be a finite number >= 0, got "
						.. tostring(v), 3)
				end
				C[key] = v
			elseif k ~= "planner_opts" then
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
	if C.OUTLIER_PERCENT >= 100 then
		error("towns site_search: opts.outlier_percent must be < 100", 3)
	end
	-- Envelope-derived dimensions (ticket #38). The town centre must be
	-- farther from the player the larger the town is, so MAX_RADIUS (the
	-- reach beyond the Phase 2 town edge) grows by the extra half-envelope;
	-- an explicit opts.max_radius is taken as given. Terrain limits
	-- (MAX_RANGE, MAX_CUT_FILL, SCAN_*) are never scaled. A landmark profile
	-- also raises the clearance above ground to the tallest real landmark.
	local popts = type(opts) == "table" and opts.planner_opts or nil
	if type(popts) == "table" then
		local PC = planner.resolve_constants(popts)
		local growth = math.floor((PC.ENVELOPE - planner.LEGACY_ENVELOPE) / 2)
		local explicit = false
		for k in pairs(opts) do
			if type(k) == "string" and k:upper() == "MAX_RADIUS" then explicit = true end
		end
		if growth > 0 and not explicit then C.MAX_RADIUS = C.MAX_RADIUS + growth end
		if type(popts.landmarks) == "table" then
			for _, name in ipairs({"cathedral", "castle"}) do
				local L = popts.landmarks[name]
				if type(L) == "table" and type(L.size) == "table"
						and type(L.size.y) == "number" then
					local h = L.size.y - (L.ground_offset or 0)
					if h > C.LANDMARK_BLOCKOUT_HEIGHT then C.LANDMARK_BLOCKOUT_HEIGHT = h end
				end
			end
		end
	end
	C.BLOCKOUT_CLEARANCE = C.LANDMARK_BLOCKOUT_HEIGHT + C.BLOCKOUT_MARGIN
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
	return {
		min = {x = b.x1, y = bottom, z = b.z1},
		max = {x = b.x2, y = top, z = b.z2},
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
-- preflight.compose result, opts.structure_bounds) replaces the blockout
-- clearance: Y then runs from the lowest of the surface, ground and every
-- structure foundation up to the top of the tallest selected structure (or
-- the highest surface).
function M.build_bounds(plan_bounds, ground_y, min_h, max_h, C, comp)
	local lo = math.min(min_h, ground_y)
	local hi
	if comp then
		hi = math.max(max_h, comp.max_y or ground_y)
		if comp.min_y then lo = math.min(lo, comp.min_y) end
	else
		hi = math.max(max_h, ground_y + C.BLOCKOUT_CLEARANCE)
	end
	return {
		min = {x = plan_bounds.x1, y = lo, z = plan_bounds.z1},
		max = {x = plan_bounds.x2, y = hi, z = plan_bounds.z2},
	}
end

function M.height_at(result, x, z)
	local col = result.heights[x]
	return col and col[z]
end

-- Inspects every column. read(x, z) -> height | nil, problem, y
-- (the placement.scan_column results). Pure given `read`.
-- Returns info table, or nil, code, message with code one of
-- water, unknown, no_ground, too_high, too_uneven.
-- Optional outlier_percent trims equally from both tails, rounded down so
-- the allowance is never exceeded. Actual extremes and all heights are kept
-- for construction. max_cut_fill caps every column relative to the median.
function M.inspect_columns(columns, read, top, max_range, outlier_percent, max_cut_fill)
	local heights, list = {}, {}
	local lo, hi
	for _, c in ipairs(columns) do
		local h, problem, py = read(c.x, c.z)
		if not h then
			if problem == "water" then
				return nil, "water", ("water or lava at (%d,%d,%d)"):format(c.x, py, c.z)
			elseif problem == "unknown" then
				return nil, "unknown", ("unloaded or unknown node at (%d,%d,%d)"):format(c.x, py, c.z)
			end
			return nil, "no_ground", ("no solid ground at (%d,%d) down to y=%d"):format(c.x, c.z, py)
		end
		if h >= top then
			return nil, "too_high", ("surface at (%d,%d) reaches the inspection window top y=%d"):format(c.x, c.z, top)
		end
		local col = heights[c.x]
		if not col then col = {}; heights[c.x] = col end
		col[c.z] = h
		list[#list + 1] = h
		if not lo or h < lo then lo = h end
		if not hi or h > hi then hi = h end
	end
	if not lo then return nil, "no_ground", "no columns to inspect" end
	table.sort(list)
	local ground = list[math.floor((#list + 1) / 2)]
	local trim = math.floor(#list * (outlier_percent or 0) / 200)
	local core_lo, core_hi = list[trim + 1], list[#list - trim]
	if core_hi - core_lo > max_range then
		return nil, "too_uneven",
			("middle surface heights vary from y=%d to y=%d (range %d, max %d; %d columns excluded from each tail)"):format(
				core_lo, core_hi, core_hi - core_lo, max_range, trim)
	end
	if max_cut_fill and math.max(ground - lo, hi - ground) > max_cut_fill then
		return nil, "too_uneven",
			("surface extremes y=%d..%d require more than %d nodes of cut/fill at median y=%d"):format(
				lo, hi, max_cut_fill, ground)
	end
	return {heights = heights, list = list, min_height = lo, max_height = hi, ground_y = ground}
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

	-- Like /towns_test: the reference ground must be solid, so a player in
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

	local function class_at(x, y, z)
		return placement.classify(env.get_node_name(x, y, z), env.node_info)
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
			local info, code, msg = M.inspect_columns(M.boundary_columns(rects), function(x, z)
				return placement.scan_column(function(y) return class_at(x, y, z) end, top, bottom)
			end, top, C.MAX_RANGE, C.OUTLIER_PERCENT, C.MAX_CUT_FILL)
			if not info then return reject(code, msg) end

			-- Real plan for the accepted site; it must be exactly the
			-- translated layout that was inspected.
			local pok, plan, pwhy = pcall(planner.plan, center, seed, opts.planner_opts)
			local same = pok and plan and same_rect(plan.bounds, bounds)
				and #plan.boundary.rects == #rects
			if same then
				for k, r in ipairs(rects) do
					if not same_rect(plan.boundary.rects[k], r) then same = false end
				end
			end
			if not same then
				return reject("plan_failed", (not pok and tostring(plan)) or (pwhy and tostring(pwhy))
					or "plan is not a translation of the seed's layout")
			end

			local ground = info.ground_y
			local comp
			if C.STRUCTURE_BOUNDS then
				local lm = type(opts.planner_opts) == "table" and opts.planner_opts.landmarks
				local entries = {}
				if type(lm) == "table" then
					for _, n in ipairs({"cathedral", "castle", "city_hall", "jail"}) do
						if lm[n] then entries[lm[n].id] = lm[n] end
					end
					for _, sv in pairs(lm.services or {}) do entries[sv.id] = sv end
					for id, e in pairs(lm.content or {}) do entries[id] = e end
				end
				local cwhy
				comp, cwhy = preflight.compose(plan, entries, ground)
				if not comp then
					return finish(nil, "Town content is invalid: " .. tostring(cwhy)
						.. ". Nothing was changed.")
				end
				if comp.max_y and comp.max_y + C.CUT_FILL_MARGIN > C.CENTER_LIMIT then
					return reject("out_of_range", ("structures reach y=%d beyond +/-%d"):format(
						comp.max_y, C.CENTER_LIMIT))
				end
			end
			local bb = M.build_bounds(bounds, ground, info.min_height, info.max_height, C, comp)
			local bvol = M.build_volume(bb, C)
			emerge_step(bvol.min, bvol.max, function(status2)
				if emerge_bad(status2, center) then return end
				finish({
					center = center,
					plan = plan,
					ground_y = ground,
					heights = info.heights,
					columns = #info.list,
					min_height = info.min_height,
					max_height = info.max_height,
					build_bounds = bb,
					structures = comp and comp.structures or nil,
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
