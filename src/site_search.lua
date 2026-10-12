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
--     seed        integer, passed straight to planner.plan.
--     opts        optional table overriding any ss.CONSTANTS entry by its
--                 name in lower case (step, max_radius, player_margin,
--                 max_range, ...) and `planner_opts` (forwarded to
--                 planner.plan).
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
--     min_height, max_height = integer   surface range (max - min <= MAX_RANGE)
--     build_bounds = {min={x,y,z}, max={x,y,z}} inclusive, exact: X/Z are
--                    plan.bounds; Y runs from min(min_height, ground_y)
--                    (lowest cut/fill row) up to max(max_height, ground_y +
--                    BLOCKOUT_CLEARANCE), i.e. includes cut/fill and the
--                    landmark blockout clearance.
--     inspection_volume = {min, max} the volume that was emerged and read.
--     candidate    = {index, dx, dz}  offset from the player in the order
--     candidates_tried = integer
--     rejections   = {[code] = count}  for the candidates rejected on the way
--   }
--   details (both outcomes) = {candidates_tried, candidates_total,
--     rejections = {[code]=count}, examples = {[code]="first message"}}
--
-- A plan failure for the seed ends the search at once (plan_failed x1).
-- Rejection codes: player_inside (player within the candidate's bounds plus
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
-- The search never calls anything else on env.

return function(placement, planner)

local M = {}

M.CONSTANTS = {
	STEP = 16,                -- candidate lattice spacing, nodes
	MAX_RADIUS = 160,         -- candidate centres within this distance
	PLAYER_MARGIN = 4,        -- player must be this far outside the bounds
	MAX_RANGE = 8,            -- max surface height range (max - min)
	LANDMARK_BLOCKOUT_HEIGHT = 40, -- tallest landmark blockout above ground
	BLOCKOUT_MARGIN = 4,      -- slack above it (#15 may tune both)
	CUT_FILL_MARGIN = 8,      -- extra nodes emerged around/below the town
	SCAN_UP = 24,             -- surface window: reference ground +/- this
	SCAN_DOWN = 24,
}

local function constants(opts)
	local C = {}
	for k, v in pairs(M.CONSTANTS) do C[k] = v end
	if opts then
		for k, v in pairs(opts) do
			local key = type(k) == "string" and k:upper() or nil
			if key and M.CONSTANTS[key] ~= nil then C[key] = v end
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

-- Volume to emerge and read for a plan. Returns volume, scan_top,
-- scan_bottom. ref_y = reference ground y (the node under the player).
-- X/Z: plan bounds grown by CUT_FILL_MARGIN. Y: from the surface window
-- bottom minus CUT_FILL_MARGIN to the window top plus BLOCKOUT_CLEARANCE.
function M.inspection_volume(plan_bounds, ref_y, C)
	local b = plan_bounds
	local m = C.CUT_FILL_MARGIN
	local top = ref_y + C.SCAN_UP
	local bottom = ref_y - C.SCAN_DOWN
	return {
		min = {x = b.x1 - m, y = bottom - m, z = b.z1 - m},
		max = {x = b.x2 + m, y = top + C.BLOCKOUT_CLEARANCE, z = b.z2 + m},
	}, top, bottom
end

-- Exact build bounds for an accepted site (see header).
function M.build_bounds(plan_bounds, ground_y, min_h, max_h, C)
	return {
		min = {x = plan_bounds.x1, y = math.min(min_h, ground_y), z = plan_bounds.z1},
		max = {
			x = plan_bounds.x2,
			y = math.max(max_h, ground_y + C.BLOCKOUT_CLEARANCE),
			z = plan_bounds.z2,
		},
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
function M.inspect_columns(columns, read, top, max_range)
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
	if hi - lo > max_range then
		return nil, "too_uneven",
			("surface varies from y=%d to y=%d (range %d, max %d)"):format(lo, hi, hi - lo, max_range)
	end
	return {heights = heights, list = list, min_height = lo, max_height = hi}
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
function M.search(player_pos, seed, opts, done, env)
	opts = opts or {}
	local C = constants(opts)
	env = env or M.core_env(core)
	local px, pz = round(player_pos.x), round(player_pos.z)
	local ref_y = round(player_pos.y) - 1
	local offsets = M.candidate_offsets(C.STEP, C.MAX_RADIUS)
	local rejections, examples = {}, {}
	local tried, finished = 0, false

	local function details()
		return {
			candidates_tried = tried, candidates_total = #offsets,
			rejections = rejections, examples = examples,
		}
	end
	local function finish(result, summary)
		if finished then return end
		finished = true
		done(result, summary, details())
	end
	local function reject(code, msg)
		rejections[code] = (rejections[code] or 0) + 1
		examples[code] = examples[code] or msg
	end

	local function class_at(x, y, z)
		return placement.classify(env.get_node_name(x, y, z), env.node_info)
	end

	local index = 0
	local step
	local function next_candidate()
		index = index + 1
		if index > #offsets then
			local summary = ("No suitable town site within %d nodes of (%d,%d): %d candidates checked"):format(
				C.MAX_RADIUS, px, pz, tried)
			if next(rejections) then
				summary = summary .. "; rejected: " .. M.format_rejections(rejections)
			end
			return finish(nil, summary .. ". Nothing was changed.")
		end
		return step(index)
	end

	-- The layout depends only on the seed and the centre merely translates
	-- it (planner contract), and planning costs tens of ms, so the plan is
	-- computed once and translated for the cheap candidate tests. The
	-- accepted candidate gets a genuine planner.plan(center, seed).
	local base, base_why
	local function shifted(r, dx, dz)
		return {x1 = r.x1 + dx, z1 = r.z1 + dz, x2 = r.x2 + dx, z2 = r.z2 + dz}
	end

	step = function(i)
		local off = offsets[i]
		local center = {x = px + off.dx, z = pz + off.dz}
		if base == nil then
			base, base_why = planner.plan(center, seed, opts.planner_opts)
			base = base or false
		end
		tried = tried + 1
		if not base then
			-- The layout depends only on the seed, so every centre fails
			-- the same way: fail fast with the planner's reason.
			reject("plan_failed", tostring(base_why))
			return finish(nil, ("No town plan for seed %s: %s. Nothing was changed."):format(
				tostring(seed), tostring(base_why)))
		end
		local sx, sz = center.x - base.center.x, center.z - base.center.z
		local bounds = shifted(base.bounds, sx, sz)
		if M.player_inside(bounds, px, pz, C.PLAYER_MARGIN) then
			reject("player_inside", ("player at (%d,%d) is within the town bounds"):format(px, pz))
			return next_candidate()
		end
		local rects = {}
		for k, r in ipairs(base.boundary.rects) do rects[k] = shifted(r, sx, sz) end
		local volume, top, bottom = M.inspection_volume(bounds, ref_y, C)
		env.emerge(volume.min, volume.max, function(ok)
			if finished then return end
			if not ok then
				reject("emerge_failed", "emerge cancelled or failed for candidate centre ("
					.. center.x .. "," .. center.z .. ")")
				return next_candidate()
			end
			local columns = M.boundary_columns(rects)
			local info, code, msg = M.inspect_columns(columns, function(x, z)
				return placement.scan_column(function(y) return class_at(x, y, z) end, top, bottom)
			end, top, C.MAX_RANGE)
			if not info then
				reject(code, msg)
				return next_candidate()
			end
			local plan, pwhy = planner.plan(center, seed, opts.planner_opts)
			if not plan or plan.bounds.x1 ~= bounds.x1 or plan.bounds.z1 ~= bounds.z1
					or plan.bounds.x2 ~= bounds.x2 or plan.bounds.z2 ~= bounds.z2 then
				reject("plan_failed", pwhy and tostring(pwhy)
					or "plan is not a translation of the seed's layout")
				return next_candidate()
			end
			local ground = M.median(info.list)
			return finish({
				center = center,
				plan = plan,
				ground_y = ground,
				heights = info.heights,
				columns = #info.list,
				min_height = info.min_height,
				max_height = info.max_height,
				build_bounds = M.build_bounds(bounds, ground, info.min_height, info.max_height, C),
				inspection_volume = volume,
				candidate = {index = i, dx = off.dx, dz = off.dz},
				candidates_tried = tried,
				rejections = rejections,
			})
		end)
	end

	return next_candidate()
end

------------------------------------------------------------------------
-- core.* adapter (the only part that touches the engine)
------------------------------------------------------------------------
-- node_info mirrors /towns_test's rules (src/test_command.lua).
function M.core_env(c)
	local function node_info(name)
		local def = c.registered_nodes[name]
		if not def then return nil end
		local g = def.groups or {}
		local liquid = def.liquidtype ~= nil and def.liquidtype ~= "none"
		local clearable = def.buildable_to
			or g.tree or g.leaves or g.plant or g.vines or g.flower or g.deco_block
			or g.dead_bush or g.mushroom or g.sapling
			or name:find("^mcl_core:snow_?%d*$") ~= nil
		return {
			walkable = def.walkable ~= false,
			liquid = liquid,
			clearable = clearable and true or false,
		}
	end
	return {
		node_info = node_info,
		get_node_name = function(x, y, z)
			return c.get_node({x = x, y = y, z = z}).name
		end,
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
