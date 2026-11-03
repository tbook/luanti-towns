-- Automatic towns (#393): the one conservative geometry source for automatic
-- town envelopes. Pure Lua: no Minetest globals at load, and no world access.
-- Every world-dependent answer comes from injected providers, so the same code
-- runs under plain Lua 5.1 tests and in the game.
--
-- STATUS: the resource caps in M.CAPS are PROVISIONAL. They are measured from
-- current plans and volume queries (see "Measured basis"), but final freezing
-- waits for the write-capable containment test A12
-- (docs/automatic_towns_probe_results.md). Nothing here authorizes a write, and
-- no caller uses this module yet (#394 onward).
--
-- Conventions (shared with the existing modules):
--   rect  {x1, z1, x2, z2}                    inclusive, horizontal
--   box   {min = {x, y, z}, max = {x, y, z}}  inclusive
-- M.PLAN_EXTENT and env.max_rect are relative to the site centre; plan envelopes
-- and stage boxes are absolute.
--
-- Engine chunks (chunksize 5, probe A6/A7): chunk k covers -32 + 80k .. -32 + 80k + 79
-- on every axis. Chunks never start at zero; mapblocks (16 nodes) never straddle one.
--
-- API: local auto_bounds = dofile("src/auto_bounds.lua")
--   auto_bounds.default_config()
--       Towns constants read from the modules that own them. It does not include
--       the Living Villages planner values (config.village), which must be supplied.
--   env, reason = auto_bounds.new(providers)
--       providers.config   table: default_config() plus config.village, required:
--                          {cell, max_cells, relocate_step, relocate_rings, radius_jitter}
--                          from living_villages/site_planner.lua M.config.
--       providers.assets   {outskirts = {{id, size = {x, y, z}}, ...},
--                           village = {{name, hwidth, hdepth, hheight}, ...}
--                             (settlements.schematic_table),
--                           wall_features = {{id, size = {x, y, z}}, ...}}
--       providers.volume   {terrain = function(plan, schematics, options) -> {minp, maxp} | nil, reason,
--                           boundary = function(rects, ground_y, options) -> {minp, maxp} | nil, reason}
--                          Living Villages terrain.volume and terrain.boundary_volume (read-only).
--       A missing or malformed required provider returns nil, reason (declines).
--   env.max_rect          rect: the largest horizontal read/write rect, relative to the centre.
--   env.stage_reach       {[stage] = nodes beyond plan.bounds, per side}.
--   env.village_reach     nodes from a village centre to its furthest possible write.
--   env.activation_rect   rect: max_rect padded by village_reach (relative to the centre).
--   env.outskirts_reach   {x_neg, x_pos, z_neg, z_pos, y_min, y_max, all}: terrain reach of rural assets.
--   env.fit               M.fit(M.CELL, activation_rect, M.CELL_EDGE_CLEARANCE).
--   env.plan_envelope(state) -> envelope | nil, reason, code
--       state = {plan, center (default plan.center), ground_y (finished ground),
--                reference_y (reference ground), build_bounds (box; X/Z must equal plan.bounds),
--                wall (medieval_walls.plan result or nil), wall_features (list or nil),
--                exits (roads.exits(plan), default computed)}.
--       envelope = {stages = {[name] = {kind = "read"|"write", box}}, read = box, write = box,
--                   chunks = integer (distinct engine chunks over all stage boxes),
--                   snapshot_voxels = chunks * CHUNK_VOXELS (the whole envelope held at once),
--                   largest_box_voxels = chunk-aligned size of the largest single stage box,
--                   per_box_chunks = {chunks of each stage box, in order}}.
--       Multi-box stages are named stage[1], stage[2], ... in envelope.stages.
--       Codes: invalid_state, plan_extent_exceeded, oversized, provider_failed,
--              map_limit, chunk_cap, snapshot_cap. Every check runs before the caller allocates.
--   M.chunk_accounting(boxes)   distinct engine chunks, voxels, and the largest aligned box.
--   M.fit(cell, rect, clearance)  cell fit: {fits, width, depth, usable, excess, jitter}.
--
-- Cell fit (measured 2026-11-02 with LV 668c5fc and the VoxeLibre schematic table):
--   activation_rect is 847 x 847 nodes (max_rect +/-245 padded by village_reach 178).
--   Usable span with one mapchunk (80) of edge clearance is 1024 - 160 = 864, so it fits
--   with 17 nodes to spare and centre jitter of +/-8. M.CELL (1024) is unchanged.
-- Named caps (M.CAPS): 256 chunks and 256 * 512000 snapshot voxels. Measured maxima are
--   180 chunks and 92,160,000 voxels (see the basis note on M.CAPS). Provisional until A12.
--
-- Stage providers (names reported in envelope.stages):
--   urban_read       read: plan.bounds in X/Z, reference_y -scan_down .. +scan_up+1
--                    (site_search.inspection_volume; plus wet_ring when enabled).
--   urban_build      write: build_bounds grown by cut_fill_margin in X, Z and below
--                    (site_search.build_volume; the top is not grown).
--   city_margins     write: volume.boundary of the boundary rects, ground_y, radius and cap
--                    (Living Villages boundary_volume: cleanup and column reach included).
--   walls            write: medieval_walls.bounds (wall line, clearance, foundation).
--   wall_approaches  write: approach_bounds of each bare wall crossing.
--   wall_features    write: feature clearance, foundation (foundation_depth below) and
--                    outside approach of each placed feature.
--   outside_roads    write: approach_bounds of each road exit of an unwalled town (#357).
--   outskirts        write: plot band (outer_band_far) grown by the terrain reach of every
--                    rural asset in every rotation (volume.terrain, measured at new()).
--
-- Measured basis (2026-11-02; planner.plan over 200 seeds with the default landmark
-- profile for medieval, and Roman; see docs/automatic_towns_probe_results.md):
--   medieval plan.bounds relative to centre: x -132..132, z -132..132 (210x151, 151x210).
--   roman plan.bounds relative to centre:    x -95..85,   z -87..110  (181x198).
--   PLAN_EXTENT is their union. A plan outside it is declined.

local M = {}
local SOURCE = debug.getinfo(1, "S").source:sub(2)
local MODPATH = SOURCE:match("^(.*)/src/auto_bounds.lua$") or "."

M.VERSION = 1
M.CHUNKSIZE = 80            -- chunksize 5 (villages require it, probe A7)
M.CHUNK_ORIGIN = -32        -- chunk minp = -32 + 80k (probe A6)
M.CHUNK_VOXELS = 80 * 80 * 80
M.MAPBLOCK = 16
-- Slack for mapblock-aligned volume queries made from a synthetic origin: an
-- aligned box can exceed the unrounded reach by up to one mapblock less one node.
M.SLACK = M.MAPBLOCK - 1

-- Documented cell default (design section 2). This module does not change it.
M.CELL = 1024
M.CELL_EDGE_CLEARANCE = M.CHUNKSIZE  -- one mapchunk from each cell edge

-- Measured plan extents relative to the site centre (inclusive). See the header.
M.PLAN_EXTENT = {x1 = -132, z1 = -132, x2 = 132, z2 = 132}

-- Named finite caps. PROVISIONAL: final freezing waits for the A12 containment test.
-- Basis: 300 seeds per family (medieval walled, medieval unwalled, Roman; 900 plans, none
-- declined) with the real Living Villages terrain and boundary queries. The largest
-- envelope is 180 distinct chunks (92,160,000 voxels). The outskirts band sets it,
-- and the reach that sets it is fixed by constants, so the maximum is structural. The
-- cap is 256 chunks, about 1.4 times the measured maximum.
M.CAPS = {
	MAX_REQUEST_CHUNKS = 256,
	MAX_SNAPSHOT_VOXELS = 256 * 80 * 80 * 80,
	PROVISIONAL = true,
	BASIS = "300 seeds x 3 families; measured max 180 chunks / 92160000 voxels; cap 256 chunks",
}

local ROTATIONS = {"0", "90", "180", "270"}
local MAP_LIMIT = 31000

local function is_int(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v == math.floor(v)
end

local function box(x1, y1, z1, x2, y2, z2)
	return {min = {x = x1, y = y1, z = z1}, max = {x = x2, y = y2, z = z2}}
end

local function valid_box(b)
	return type(b) == "table" and type(b.min) == "table" and type(b.max) == "table"
		and is_int(b.min.x) and is_int(b.min.y) and is_int(b.min.z)
		and is_int(b.max.x) and is_int(b.max.y) and is_int(b.max.z)
		and b.min.x <= b.max.x and b.min.y <= b.max.y and b.min.z <= b.max.z
end

local function union(boxes)
	local u
	for _, b in ipairs(boxes) do
		if u == nil then
			u = {min = {x = b.min.x, y = b.min.y, z = b.min.z}, max = {x = b.max.x, y = b.max.y, z = b.max.z}}
		else
			for _, axis in ipairs({"x", "y", "z"}) do
				u.min[axis] = math.min(u.min[axis], b.min[axis])
				u.max[axis] = math.max(u.max[axis], b.max[axis])
			end
		end
	end
	return u
end

-- Does box `outer` contain box `inner` on every axis?
function M.contains_box(outer, inner)
	for _, axis in ipairs({"x", "y", "z"}) do
		if inner.min[axis] < outer.min[axis] or inner.max[axis] > outer.max[axis] then return false end
	end
	return true
end

-- Does rect `outer` contain rect `inner`?
function M.contains_rect(outer, inner)
	return inner.x1 >= outer.x1 and inner.x2 <= outer.x2 and inner.z1 >= outer.z1 and inner.z2 <= outer.z2
end

-- Engine chunk index of one node coordinate on one axis.
function M.chunk_index(v)
	return math.floor((v - M.CHUNK_ORIGIN) / M.CHUNKSIZE)
end

-- Chunk indices spanned by a box: {kx1, ky1, kz1, kx2, ky2, kz2}.
function M.chunk_range(b)
	return {
		M.chunk_index(b.min.x), M.chunk_index(b.min.y), M.chunk_index(b.min.z),
		M.chunk_index(b.max.x), M.chunk_index(b.max.y), M.chunk_index(b.max.z),
	}
end

-- Voxel count of the chunk-aligned region of one box (one VoxelManip snapshot of it).
function M.aligned_voxels(b)
	local r = M.chunk_range(b)
	return (r[4] - r[1] + 1) * (r[5] - r[2] + 1) * (r[6] - r[3] + 1) * M.CHUNK_VOXELS
end

-- Deduplicated chunk accounting over boxes. Returns
--   {chunks = distinct chunks, voxels = chunks * CHUNK_VOXELS,
--    largest_snapshot_voxels = largest aligned region of any one box, per_box = {chunk count per box}}
function M.chunk_accounting(boxes)
	local seen, count, largest, per_box = {}, 0, 0, {}
	for i, b in ipairs(boxes) do
		local r = M.chunk_range(b)
		local n = 0
		for kz = r[3], r[6] do
			for ky = r[2], r[5] do
				for kx = r[1], r[4] do
					local key = kx .. ":" .. ky .. ":" .. kz
					if not seen[key] then seen[key] = true; count = count + 1 end
					n = n + 1
				end
			end
		end
		per_box[i] = n
		largest = math.max(largest, M.aligned_voxels(b))
	end
	return {chunks = count, voxels = count * M.CHUNK_VOXELS,
		largest_snapshot_voxels = largest, per_box = per_box}
end

-- Cell fit. The rect (relative to the centre, inclusive) must fit in the cell with
-- `clearance` nodes between it and each cell edge. The centre may sit anywhere in the
-- cell, so the larger side must fit in cell - 2 * clearance. excess is 0 when it fits.
function M.fit(cell, rect, clearance)
	local width = rect.x2 - rect.x1 + 1
	local depth = rect.z2 - rect.z1 + 1
	local usable = cell - 2 * clearance
	local worst = math.max(width, depth)
	return {
		fits = worst <= usable, width = width, depth = depth, usable = usable,
		excess = math.max(0, worst - usable), jitter = math.floor((usable - worst) / 2),
	}
end

-- Towns constants read from the modules that own them. The site_search values are
-- repeated here: that module needs a planner factory to load, so tests check them.
function M.default_config()
	local outskirts = dofile(MODPATH .. "/src/outskirts.lua").CONSTANTS
	local roads = dofile(MODPATH .. "/src/town_roads.lua")
	local walls = dofile(MODPATH .. "/src/medieval_walls.lua")
	local features = dofile(MODPATH .. "/src/medieval_wall_features.lua")
	return {
		-- site_search.CONSTANTS (CUT_FILL_MARGIN, SCAN_UP, SCAN_DOWN)
		cut_fill_margin = 8,
		scan_up = 48, scan_down = 48,
		-- Wet mode is opt-in (MAX_WATER_DEPTH = 0); when enabled it reads one ring.
		wet_ring = 0,
		-- outskirts.CONSTANTS
		outer_band_far = outskirts.OUTER_BAND_FAR,
		outskirts_scan_up = outskirts.SCAN_UP, outskirts_scan_down = outskirts.SCAN_DOWN,
		-- town_roads, medieval_walls and medieval_wall_features
		ramp_max = roads.RAMP_MAX,
		wall_line_offset = 1,            -- the boundary wall sits one node beyond the town (generate_command)
		wall_clearance = walls.CLEARANCE,
		wall_clearance_top = walls.CLEARANCE_TOP,
		wall_depth = walls.DEPTH,
		foundation_depth = features.FOUNDATION_DEPTH,
		approach_start = 6,              -- a gate approach starts six nodes beyond its opening (medieval_walls)
		feature_door_extension = 2,      -- a feature approach starts two nodes beyond its door columns
		-- city_margins.lua OPTIONS
		city_margin = {radius = 20, cap = 20},
	}
end

-- Derives a terrain reach for one schematic at a synthetic origin (footprint corner
-- at 0,0), in one rotation. Returns {x_neg, x_pos, z_neg, z_pos, y_min, y_max, all}
-- where x_neg/z_neg are how far the volume extends before the corner, and x_pos/z_pos
-- how far it extends past the far corner. y offsets are relative to ground 0. Slack is
-- included. Returns nil, reason when the query fails.
local function reach_of(terrain, schematic, rotat, options)
	local w, d = schematic.hwidth, schematic.hdepth
	if rotat == "90" or rotat == "270" then w, d = d, w end
	local entry = {name = schematic.name, pos = {x = 0, z = 0}, rotat = rotat}
	local vol, why = terrain({entry}, {schematic}, options)
	if type(vol) ~= "table" or type(vol.minp) ~= "table" or type(vol.maxp) ~= "table" then
		return nil, why or "no volume"
	end
	local S = M.SLACK
	local r = {
		x_neg = math.max(0, -vol.minp.x) + S,
		x_pos = math.max(0, vol.maxp.x - (w - 1)) + S,
		z_neg = math.max(0, -vol.minp.z) + S,
		z_pos = math.max(0, vol.maxp.z - (d - 1)) + S,
		y_min = vol.minp.y - S,
		y_max = vol.maxp.y + S,
		w = w, d = d,
	}
	r.all = math.max(r.x_neg, r.x_pos, r.z_neg, r.z_pos)
	return r
end

-- Merges reach records: the largest per-side reach and the widest y range.
local function merge_reach(acc, r)
	if not acc then
		return {x_neg = r.x_neg, x_pos = r.x_pos, z_neg = r.z_neg, z_pos = r.z_pos,
			y_min = r.y_min, y_max = r.y_max, all = r.all}
	end
	acc.x_neg, acc.x_pos = math.max(acc.x_neg, r.x_neg), math.max(acc.x_pos, r.x_pos)
	acc.z_neg, acc.z_pos = math.max(acc.z_neg, r.z_neg), math.max(acc.z_pos, r.z_pos)
	acc.y_min, acc.y_max = math.min(acc.y_min, r.y_min), math.max(acc.y_max, r.y_max)
	acc.all = math.max(acc.all, r.all)
	return acc
end

local function check_list(list, label)
	if type(list) ~= "table" or #list == 0 then return nil, label .. " provider is missing or empty" end
	for _, item in ipairs(list) do
		if type(item) ~= "table" then return nil, label .. " provider has a malformed entry" end
	end
	return true
end

local CONFIG_INTS = {"cut_fill_margin", "scan_up", "scan_down", "wet_ring", "outer_band_far",
	"outskirts_scan_up", "outskirts_scan_down", "ramp_max", "wall_line_offset", "wall_clearance",
	"wall_clearance_top", "wall_depth", "foundation_depth", "approach_start", "feature_door_extension"}

local function check_providers(p)
	if type(p) ~= "table" then return nil, "providers table is required" end
	local c = p.config
	if type(c) ~= "table" then return nil, "config provider is missing" end
	for _, k in ipairs(CONFIG_INTS) do
		if not is_int(c[k]) or c[k] < 0 then return nil, "config." .. k .. " must be a nonnegative integer" end
	end
	if type(c.city_margin) ~= "table" or not is_int(c.city_margin.radius) or not is_int(c.city_margin.cap) then
		return nil, "config.city_margin {radius, cap} is missing"
	end
	local v = c.village
	if type(v) ~= "table" then return nil, "config.village (Living Villages planner values) is missing" end
	for _, k in ipairs({"cell", "max_cells", "relocate_step", "relocate_rings", "radius_jitter"}) do
		if not is_int(v[k]) or v[k] < 0 then return nil, "config.village." .. k .. " must be a nonnegative integer" end
	end
	if type(p.assets) ~= "table" then return nil, "assets provider is missing" end
	local ok, why = check_list(p.assets.outskirts, "assets.outskirts")
	if not ok then return nil, why end
	ok, why = check_list(p.assets.village, "assets.village")
	if not ok then return nil, why end
	ok, why = check_list(p.assets.wall_features, "assets.wall_features")
	if not ok then return nil, why end
	if type(p.volume) ~= "table" or type(p.volume.terrain) ~= "function" or type(p.volume.boundary) ~= "function" then
		return nil, "volume provider (terrain and boundary) is missing"
	end
	return true
end

-- Builds the environment. Each rural and village terrain reach is measured once, so
-- a plan needs no terrain query except city margins (a boundary query).
function M.new(providers)
	local ok, why = check_providers(providers)
	if not ok then return nil, why end
	local config, assets, terrain = providers.config, providers.assets, providers.volume.terrain

	-- Rural assets (outskirts plots): terrain reach over every rotation, relative to a
	-- surface window of -scan_down .. +scan_up around ground.
	local out_reach
	for _, asset in ipairs(assets.outskirts) do
		local s = asset.size
		if type(asset.id) ~= "string" or type(s) ~= "table" or not is_int(s.x) or not is_int(s.y) or not is_int(s.z) then
			return nil, "assets.outskirts entry is malformed: " .. tostring(asset.id)
		end
		local schem = {name = asset.id, hwidth = s.x, hdepth = s.z, hheight = s.y}
		for _, rot in ipairs(ROTATIONS) do
			local r, rwhy = reach_of(terrain, schem, rot, {surface_y = {
				min = -config.outskirts_scan_down, max = config.outskirts_scan_up}})
			if not r then return nil, "outskirts terrain volume unavailable for " .. asset.id .. ": " .. tostring(rwhy) end
			out_reach = merge_reach(out_reach, r)
		end
	end

	-- City margins: boundary reach around a unit rect at the origin.
	local cm = config.city_margin
	local cm_vol, cm_why = providers.volume.boundary({{x0 = 0, z0 = 0, x1 = 0, z1 = 0}}, 0,
		{radius = cm.radius, cap = cm.cap})
	if type(cm_vol) ~= "table" or type(cm_vol.minp) ~= "table" or type(cm_vol.maxp) ~= "table" then
		return nil, "city margin volume unavailable: " .. tostring(cm_why)
	end
	local cm_reach = math.max(-cm_vol.minp.x, cm_vol.maxp.x, -cm_vol.minp.z, cm_vol.maxp.z, 0) + M.SLACK

	-- Village reach from its centre: relocation, ring radius, the largest footprint and
	-- its terrain reach. The footprint runs from its corner (the village pos) to its far
	-- corner, so the far side adds the footprint's own extent.
	local v = config.village
	local relocate = v.relocate_rings * v.relocate_step + 1   -- +1 rounding slack
	local ring = v.max_cells * v.cell + v.radius_jitter + 1   -- ring radii are <= max_cells * cell + jitter
	local footprint = 0
	for _, s in ipairs(assets.village) do
		if type(s.name) ~= "string" or not is_int(s.hwidth) or not is_int(s.hdepth) or not is_int(s.hheight) then
			return nil, "assets.village entry is malformed: " .. tostring(s.name)
		end
		local schem = {name = s.name, hwidth = s.hwidth, hdepth = s.hdepth, hheight = s.hheight}
		for _, rot in ipairs(ROTATIONS) do
			local r, rwhy = reach_of(terrain, schem, rot, {surface_y = {
				min = -config.scan_down, max = config.scan_up}})
			if not r then return nil, "village terrain volume unavailable for " .. s.name .. ": " .. tostring(rwhy) end
			footprint = math.max(footprint, r.x_neg, r.z_neg,
				r.w - 1 + r.x_pos, r.d - 1 + r.z_pos)
		end
	end
	local village_reach = relocate + ring + footprint

	-- Largest feature asset, outward from the wall line.
	local max_feature = 0
	for _, f in ipairs(assets.wall_features) do
		if type(f.size) ~= "table" or not is_int(f.size.x) or not is_int(f.size.z) then
			return nil, "assets.wall_features entry is malformed: " .. tostring(f.id)
		end
		max_feature = math.max(max_feature, f.size.x, f.size.z)
	end

	-- Horizontal reach of each stage beyond plan.bounds, per side.
	local stage_reach = {
		urban_build = config.cut_fill_margin,
		city_margins = cm_reach,
		walls = config.wall_line_offset + config.wall_clearance,
		wall_approaches = config.wall_line_offset + config.approach_start + config.ramp_max - 1,
		wall_features = config.wall_line_offset + max_feature + config.feature_door_extension + config.ramp_max - 1,
		outside_roads = config.wall_line_offset + config.ramp_max - 1,
		outskirts = config.outer_band_far + out_reach.all,
	}
	local H = 0
	for _, r in pairs(stage_reach) do H = math.max(H, r) end

	local P = M.PLAN_EXTENT
	local max_rect = {x1 = P.x1 - H, z1 = P.z1 - H, x2 = P.x2 + H, z2 = P.z2 + H}
	local activation = {x1 = max_rect.x1 - village_reach, z1 = max_rect.z1 - village_reach,
		x2 = max_rect.x2 + village_reach, z2 = max_rect.z2 + village_reach}

	local env = {
		max_rect = max_rect,
		stage_reach = stage_reach,
		village_reach = village_reach,
		activation_rect = activation,
		outskirts_reach = out_reach,
		fit = M.fit(M.CELL, activation, M.CELL_EDGE_CLEARANCE),
		config = config,
		providers = providers,
	}
	env.plan_envelope = function(state) return M.plan_envelope(env, state) end
	return env
end

-- Modules that define the stage geometry, loaded once.
local modules
local function stage_modules()
	if not modules then
		modules = {
			walls = dofile(MODPATH .. "/src/medieval_walls.lua"),
			roads = dofile(MODPATH .. "/src/town_roads.lua"),
			features = dofile(MODPATH .. "/src/medieval_wall_features.lua"),
		}
	end
	return modules
end

-- Stage providers. Each returns a box, a list of boxes, nil (not applicable), or
-- nil, reason (a failure that declines the plan).
local function urban_read(env, st)
	local c, b, wet = env.config, st.plan.bounds, env.config.wet_ring
	return box(b.x1 - wet, st.reference_y - c.scan_down, b.z1 - wet,
		b.x2 + wet, st.reference_y + c.scan_up + 1, b.z2 + wet)
end

local function urban_build(env, st)
	local m, bb = env.config.cut_fill_margin, st.build_bounds
	return {min = {x = bb.min.x - m, y = bb.min.y - m, z = bb.min.z - m},
		max = {x = bb.max.x + m, y = bb.max.y, z = bb.max.z + m}}
end

local function city_margins(env, st)
	local rects = {}
	local src = st.plan.boundary and st.plan.boundary.rects or {st.plan.bounds}
	for _, r in ipairs(src) do
		rects[#rects + 1] = {x0 = r.x1, z0 = r.z1, x1 = r.x2, z1 = r.z2}
	end
	local c = env.config.city_margin
	local vol, why = env.providers.volume.boundary(rects, st.ground_y, {radius = c.radius, cap = c.cap})
	if type(vol) ~= "table" then return nil, "city margin volume unavailable: " .. tostring(why) end
	return box(vol.minp.x, vol.minp.y, vol.minp.z, vol.maxp.x, vol.maxp.y, vol.maxp.z)
end

local function walls(env, st, m)
	if not st.wall then return nil end
	return m.walls.bounds(st.wall, st.ground_y)
end

local function wall_approaches(env, st, m)
	if not st.wall then return nil end
	local out = {}
	for _, columns in ipairs(m.roads.crossings(st.wall.openings or {})) do
		out[#out + 1] = m.roads.approach_bounds(columns, st.ground_y)
	end
	return out
end

local function wall_features(env, st, m)
	if not st.wall or not st.wall_features then return nil end
	local out = {}
	for _, feature in ipairs(st.wall_features) do
		local apron = m.walls.feature_clearance_bounds(feature, st.ground_y)
		if apron then out[#out + 1] = apron end
		out[#out + 1] = {min = {x = feature.min.x, y = feature.min.y - env.config.foundation_depth, z = feature.min.z},
			max = feature.max}
		if feature.outside_approach then
			out[#out + 1] = m.roads.approach_bounds(feature.outside_approach, st.ground_y)
		end
	end
	return out
end

local function outside_roads(env, st, m)
	if st.wall then return nil end
	local out = {}
	for _, columns in ipairs(m.roads.crossings(st.exits or m.roads.exits(st.plan))) do
		out[#out + 1] = m.roads.approach_bounds(columns, st.ground_y)
	end
	return out
end

local function outskirts(env, st)
	local r, b, o = env.outskirts_reach, st.plan.bounds, env.config.outer_band_far
	return box(b.x1 - o - r.x_neg, st.ground_y + r.y_min, b.z1 - o - r.z_neg,
		b.x2 + o + r.x_pos, st.ground_y + r.y_max, b.z2 + o + r.z_pos)
end

local STAGES = {
	{name = "urban_read", kind = "read", fn = urban_read},
	{name = "urban_build", kind = "write", fn = urban_build},
	{name = "city_margins", kind = "write", fn = city_margins},
	{name = "walls", kind = "write", fn = walls},
	{name = "wall_approaches", kind = "write", fn = wall_approaches},
	{name = "wall_features", kind = "write", fn = wall_features},
	{name = "outside_roads", kind = "write", fn = outside_roads},
	{name = "outskirts", kind = "write", fn = outskirts},
}

-- Plan envelope for one site (see the header). Every check runs before the
-- caller allocates anything. Returns envelope, or nil, reason, code.
function M.plan_envelope(env, st)
	if type(st) ~= "table" or type(st.plan) ~= "table" or type(st.plan.bounds) ~= "table" then
		return nil, "plan.bounds is required", "invalid_state"
	end
	if not is_int(st.ground_y) or not is_int(st.reference_y) then
		return nil, "ground_y and reference_y must be integers", "invalid_state"
	end
	if not valid_box(st.build_bounds) then return nil, "build_bounds is required", "invalid_state" end
	local center = st.center or st.plan.center
	if type(center) ~= "table" or not is_int(center.x) or not is_int(center.z) then
		return nil, "site centre is required", "invalid_state"
	end
	local b = st.plan.bounds
	local bb = st.build_bounds
	if bb.min.x ~= b.x1 or bb.max.x ~= b.x2 or bb.min.z ~= b.z1 or bb.max.z ~= b.z2 then
		return nil, "build_bounds X/Z must equal plan.bounds", "invalid_state"
	end
	local rel = {x1 = b.x1 - center.x, z1 = b.z1 - center.z, x2 = b.x2 - center.x, z2 = b.z2 - center.z}
	if not M.contains_rect(M.PLAN_EXTENT, rel) then
		return nil, "plan bounds exceed the measured plan extent", "plan_extent_exceeded"
	end

	local m = stage_modules()
	local stages, all, writes = {}, {}, {}
	for _, s in ipairs(STAGES) do
		local result, why = s.fn(env, st, m)
		if result == nil and why ~= nil then
			return nil, s.name .. ": " .. tostring(why), "provider_failed"
		end
		local list = result or {}
		if valid_box(list) then list = {list} end
		for i, item in ipairs(list) do
			if not valid_box(item) then return nil, s.name .. ": invalid box", "provider_failed" end
			local name = #list > 1 and (s.name .. "[" .. i .. "]") or s.name
			stages[name] = {kind = s.kind, box = item}
			all[#all + 1] = item
			if s.kind == "write" then writes[#writes + 1] = item end
		end
	end
	local read = union(all)
	if not read then return nil, "no stage applies", "invalid_state" end

	for name, s in pairs(stages) do
		local rel_stage = {x1 = s.box.min.x - center.x, z1 = s.box.min.z - center.z,
			x2 = s.box.max.x - center.x, z2 = s.box.max.z - center.z}
		if not M.contains_rect(env.max_rect, rel_stage) then
			return nil, name .. " exceeds the horizontal maximum", "oversized"
		end
	end
	for _, axis in ipairs({"x", "y", "z"}) do
		if math.abs(read.min[axis]) > MAP_LIMIT or math.abs(read.max[axis]) > MAP_LIMIT then
			return nil, "envelope exceeds the world map limit", "map_limit"
		end
	end

	-- Snapshot voxels are the whole distinct envelope (every chunk held at once), the
	-- conservative simultaneous figure. The largest single box is reported for info.
	local acc = M.chunk_accounting(all)
	if acc.chunks > M.CAPS.MAX_REQUEST_CHUNKS then
		return nil, ("%d chunks exceed the cap of %d"):format(acc.chunks, M.CAPS.MAX_REQUEST_CHUNKS), "chunk_cap"
	end
	if acc.voxels > M.CAPS.MAX_SNAPSHOT_VOXELS then
		return nil, ("%d snapshot voxels exceed the cap of %d"):format(acc.voxels, M.CAPS.MAX_SNAPSHOT_VOXELS),
			"snapshot_cap"
	end

	return {
		stages = stages, read = read, write = union(writes),
		chunks = acc.chunks, snapshot_voxels = acc.voxels,
		largest_box_voxels = acc.largest_snapshot_voxels,
		per_box_chunks = acc.per_box,
	}
end

return M
