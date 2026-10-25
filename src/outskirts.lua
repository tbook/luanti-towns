-- Pure deterministic planner for scattered rural plots around a town.
-- Terrain inspection is owned by the caller: next() yields one candidate,
-- then accept() or reject() resolves it before the next attempt is requested.
local M = {}
local SOURCE = debug.getinfo(1, "S").source:sub(2)
local MODPATH = SOURCE:match("^(.*)/src/outskirts.lua$") or "."

M.CONSTANTS = {
	VERSION = 1, FARM_COUNT = 18, HUT_COUNT = 6, VILLA_COUNT = 2, CHAPEL_COUNT = 1,
	FARM_BAND_NEAR = 10, FARM_BAND_FAR = 24, OUTER_BAND_NEAR = 24, OUTER_BAND_FAR = 58,
	MIN_SPACING = 20, PROTECT_MARGIN = 4, TERRAFORM_REACH = 10, PLAYER_MARGIN = 16,
	ATTEMPTS_PER_BUILDING = 6, SAMPLE_LIMIT = 50, MAX_SPREAD = 4,
	SCAN_UP = 48, SCAN_DOWN = 48, SALT = 226,
}

local function load_geometry()
	return dofile(MODPATH .. "/src/geometry.lua")
end
local geometry = load_geometry()
local placement = dofile(MODPATH .. "/src/placement.lua")

function M.new_rng(seed)
	local state = (seed * 31 + M.CONSTANTS.SALT) % 2147483646 + 1
	return {
		next = function()
			state = state * 48271 % 2147483647
			return state
		end,
		int = function(a, b)
			state = state * 48271 % 2147483647
			return a + state % (b - a + 1)
		end,
	}
end

local function rect_gap(a, b)
	return math.max(b.x1 - a.x2, a.x1 - b.x2, b.z1 - a.z2, a.z1 - b.z2)
end

local function valid_rect(r)
	return type(r) == "table" and type(r.x1) == "number" and type(r.z1) == "number"
		and type(r.x2) == "number" and type(r.z2) == "number"
end

function M.sample(band, size, bounds, rng, limit)
	assert(type(band) == "table" and type(size) == "table" and valid_rect(bounds), "band, size and bounds are required")
	assert(type(rng) == "table" and type(rng.int) == "function", "rng.int is required")
	local low, high = band.near or band[1], band.far or band[2]
	limit = limit or M.CONSTANTS.SAMPLE_LIMIT
	local min_x, max_x = bounds.x1 - high, bounds.x2 + high - size.x + 1
	local min_z, max_z = bounds.z1 - high, bounds.z2 + high - size.z + 1
	if min_x > max_x or min_z > max_z then return nil end
	for _ = 1, limit do
		local x, z = rng.int(min_x, max_x), rng.int(min_z, max_z)
		local rect = {x1 = x, z1 = z, x2 = x + size.x - 1, z2 = z + size.z - 1}
		local distance = rect_gap(rect, bounds)
		if distance >= low and distance < high then return rect, distance end
	end
	return nil
end

function M.fits(rect, plots, protected, player_pos, constants)
	constants = constants or M.CONSTANTS
	assert(valid_rect(rect), "rect is required")
	local limit = 31000
	if rect.x1 < -limit or rect.x2 > limit or rect.z1 < -limit or rect.z2 > limit then
		return false, "plot_out_of_range"
	end
	local p = {x1 = protected.x0 - protected.margin, z1 = protected.z0 - protected.margin,
		x2 = protected.x1 + protected.margin, z2 = protected.z1 + protected.margin}
	if rect_gap(rect, p) <= 0 then return false, "plot_protected" end
	for _, plot in ipairs(plots) do
		if rect_gap(rect, plot.rect) < constants.MIN_SPACING then return false, "plot_spacing" end
	end
	if player_pos then
		local point = {x1 = player_pos.x, x2 = player_pos.x, z1 = player_pos.z, z2 = player_pos.z}
		if rect_gap(rect, point) < constants.PLAYER_MARGIN then return false, "plot_player" end
	end
	return true
end

local function ordered_entries(entries, class)
	local found = {}
	for id, entry in pairs(entries) do
		if entry.class == class or (class == "chapel" and (entry.role == "chapel" or id == "chapel")) then
			found[#found + 1] = {id = id, entry = entry}
		end
	end
	table.sort(found, function(a, b) return a.id < b.id end)
	assert(#found > 0, "missing outskirts catalog entry for " .. class)
	return found
end

function M.new(plan, seed, entries, player_pos)
	assert(type(plan) == "table" and valid_rect(plan.bounds), "urban plan.bounds is required")
	assert(type(entries) == "table", "merged outskirts entries are required")
	local c = M.CONSTANTS
	local town_type = plan.town_type or plan.type
	local classes = {
		{class = "farm", count = c.FARM_COUNT, band = {near = c.FARM_BAND_NEAR, far = c.FARM_BAND_FAR}},
		{class = "hut", count = c.HUT_COUNT, band = {near = c.OUTER_BAND_NEAR, far = c.OUTER_BAND_FAR}},
	}
	if town_type == "roman" then
		classes[#classes + 1] = {class = "villa", count = c.VILLA_COUNT, band = {near = c.OUTER_BAND_NEAR, far = c.OUTER_BAND_FAR}}
	elseif town_type == "medieval" then
		classes[#classes + 1] = {class = "chapel", count = c.CHAPEL_COUNT, band = {near = c.OUTER_BAND_NEAR, far = c.OUTER_BAND_FAR}}
	else
		error("outskirts town type must be roman or medieval")
	end
	local state = {
		version = c.VERSION, seed = seed,
		center = plan.center and {x = plan.center.x, z = plan.center.z} or nil,
		ground_y = nil,
		protected = {x0 = plan.bounds.x1, z0 = plan.bounds.z1, x1 = plan.bounds.x2,
			z1 = plan.bounds.z2, margin = c.PROTECT_MARGIN},
		entries = entries, plots = {}, structures = {}, rejections = {},
		counts = {requested = {farm = c.FARM_COUNT, hut = c.HUT_COUNT, villa = 0, chapel = 0},
			planned = {farm = 0, hut = 0, villa = 0, chapel = 0}, rejected = {}},
	}
	local rng = M.new_rng(seed)
	local group_index, building_index, attempt, current, building_record, done = 1, 0, 0, nil, nil, false
	local asset_cache = {}
	for _, group in ipairs(classes) do
		state.counts.requested[group.class] = group.count
		group.assets = ordered_entries(entries, group.class)
	end
	local function rejection(subject, code, detail)
		state.rejections[#state.rejections + 1] = {stage = "plot", code = code, subject = subject, detail = detail}
		state.counts.rejected[code] = (state.counts.rejected[code] or 0) + 1
	end
	local function advance_building()
		building_index = building_index + 1
		attempt, building_record = 0, nil
	end
	function state:next()
		assert(current == nil, "resolve the current candidate with accept or reject before next")
		if done then return nil end
		while group_index <= #classes do
			local group = classes[group_index]
			if building_index == 0 then building_index = 1 end
			if building_index > group.count then group_index, building_index = group_index + 1, 1
			else
				if not building_record then
					local number = building_index
					local id = (group.class == "farm" and "f" or group.class == "hut" and "h"
						or group.class == "villa" and "v" or "c") .. (number < 10 and "0" or "") .. number
					local selected = asset_cache[group.class]
					if not selected then selected = group.assets[1]; asset_cache[group.class] = selected end
					local rotation = rng.int(0, 3) * 90
					local size = geometry.place({size = selected.entry.size,
						entrance = selected.entry.entrance or {x = 0, y = 1, z = 0}},
						{x = 0, y = 0, z = 0}, rotation).size
					building_record = {id = id, class = group.class, asset = selected.id,
						rotation = rotation, band = group.class == "farm" and "near" or "far", size = size}
				end
				local record = building_record
				while attempt < c.ATTEMPTS_PER_BUILDING do
					attempt = attempt + 1
					local subject = record.id .. ":a" .. attempt
					local rect, distance = M.sample(group.band, record.size, plan.bounds, rng)
					if not rect then
						rejection(subject, "no_site", "no position found inside band after " .. c.SAMPLE_LIMIT .. " draws")
					else
						local fits, code = M.fits(rect, self.plots, self.protected, player_pos, c)
						if not fits then
							rejection(subject, code, "candidate plot failed " .. code)
						else
							record.attempt, record.rect, record.distance = attempt, rect, distance
							current = record
							return record
						end
					end
				end
				advance_building()
			end
		end
		done = true
		return nil
	end
	function state:reject(candidate, code, detail)
		assert(candidate == current and current ~= nil, "candidate is not the pending plot")
		assert(type(code) == "string", "rejection code is required")
		rejection(candidate.id .. ":a" .. candidate.attempt, code, detail or code)
		current = nil
		if attempt >= c.ATTEMPTS_PER_BUILDING then advance_building() end
	end
	function state:accept(candidate, heights, ground_y)
		assert(candidate == current and current ~= nil, "candidate is not the pending plot")
		assert(type(heights) == "table" and type(heights.min) == "number" and type(heights.max) == "number",
			"heights.min and heights.max are required")
		assert(type(ground_y) == "number", "ground_y is required")
		candidate.heights, candidate.ground_y = {min = heights.min, max = heights.max}, ground_y
		candidate.size = nil
		self.plots[#self.plots + 1] = candidate
		self.counts.planned[candidate.class] = self.counts.planned[candidate.class] + 1
		current = nil
		advance_building()
		return candidate
	end
	function state:result(ground_y)
		assert(done and current == nil, "planning is not finished")
		self.ground_y = ground_y
		self.status = #self.plots == 0 and "empty" or "planned"
		return self
	end
	return state
end

-- M.assets(urban_entries) -> merged_entries | nil, error_kind, message.
-- Return a private id -> entry lookup for the rural planner. `urban_entries`
-- is the normal catalog lookup (it supplies shared entries such as chapel);
-- rural entries are read from their separate catalog and never added to it.
-- Catalog load/missing-class failures are dependency errors; id collisions or
-- malformed urban records are programming errors.
function M.assets(urban_entries)
	if type(urban_entries) ~= "table" then
		return nil, "outskirts_error", "urban catalog entries are required"
	end
	local rural_ok, rural = pcall(dofile, MODPATH .. "/schematics/outskirts/catalog.lua")
	if not rural_ok then
		return nil, "outskirts_dependency", "outskirts catalog unavailable: " .. tostring(rural)
	end
	if type(rural) ~= "table" then
		return nil, "outskirts_dependency", "outskirts catalog did not return an entry table"
	end
	local merged = {}
	for id, entry in pairs(urban_entries) do
		if type(id) ~= "string" or type(entry) ~= "table" then
			return nil, "outskirts_error", "urban catalog contains a malformed entry"
		end
		merged[id] = entry
	end
	for id, entry in pairs(rural) do
		if merged[id] ~= nil then
			return nil, "outskirts_error", "outskirts asset id conflicts with urban catalog: " .. id
		end
		merged[id] = entry
	end
	return merged
end

M.CONSTANTS.EMERGE_TIMEOUT = 30
M.CONSTANTS.MAX_CONSECUTIVE_TIMEOUTS = 3
M.CONSTANTS.PUMP_BUDGET = 8

local function median(values)
	table.sort(values)
	return values[math.floor((#values + 1) / 2)]
end

local function volume_box(volume)
	local function position(p)
		return type(p) == "table" and type(p.x) == "number" and type(p.y) == "number"
			and type(p.z) == "number" and p.x == math.floor(p.x) and p.y == math.floor(p.y)
			and p.z == math.floor(p.z)
	end
	assert(type(volume) == "table" and position(volume.minp) and position(volume.maxp),
		"Living Villages terrain.volume returned an invalid volume")
	assert(volume.minp.x <= volume.maxp.x and volume.minp.y <= volume.maxp.y
		and volume.minp.z <= volume.maxp.z, "Living Villages terrain.volume returned inverted bounds")
	return volume.minp, volume.maxp
end

-- M.search(urban_result, opts, done, env)
--
-- Read-only async outskirts search after site_search has accepted an urban
-- result. opts.assets is the urban id -> entry catalog; opts.terrain is
-- living_villages.terrain; opts.player_pos is the original player position.
-- env follows site_search: emerge(minp,maxp,cb), get_node_name(x,y,z),
-- node_info(name), after(seconds,fn), and optional log(level,message).
-- done(out, message, kind) runs once: success returns the outskirts result;
-- failures use kind "outskirts_dependency" or "outskirts_error". Candidate
-- volumes are emerged and checked first; after planning, every accepted plot
-- gets a second known-ground volume emerge before success.
function M.search(result, opts, done, env)
	assert(type(result) == "table" and type(result.plan) == "table"
		and type(result.plan.bounds) == "table", "accepted urban result with plan.bounds is required")
	assert(type(result.ground_y) == "number" and type(result.plan.seed) == "number",
		"accepted urban result must contain ground_y and plan.seed")
	assert(type(result.center) == "table" and type(result.plan.center) == "table"
		and result.center.x == result.plan.center.x and result.center.z == result.plan.center.z,
		"accepted urban result centre must match plan.center")
	assert(type(opts) == "table", "outskirts search options are required")
	assert(type(done) == "function", "outskirts search done callback is required")
	assert(type(env) == "table" and type(env.emerge) == "function"
		and type(env.get_node_name) == "function" and type(env.node_info) == "function"
		and type(env.after) == "function", "outskirts search environment is incomplete")

	local modpath = MODPATH
	local terrain_adapter = dofile(modpath .. "/src/outskirts_terrain.lua")
	local valid, dep_code, dep_message = terrain_adapter.available(opts.terrain)
	if not valid then
		pcall(done, nil, dep_message, dep_code)
		return
	end
	local urban_entries = opts.assets
	if urban_entries == nil then
		local modpath = MODPATH
		local catalog_ok, catalog = pcall(dofile, modpath .. "/src/catalog.lua")
		if not catalog_ok then
			pcall(done, nil, "urban catalog unavailable: " .. tostring(catalog), "outskirts_dependency")
			return
		end
		urban_entries = catalog.entries
	end
	local merged, asset_code, asset_message = M.assets(urban_entries)
	if not merged then
		pcall(done, nil, asset_message, asset_code)
		return
	end
	local entries = merged
	local required = {farm = true, hut = true}
	local town_type = result.plan.town_type or result.plan.type
	if town_type == "roman" then required.villa = true elseif town_type == "medieval" then required.chapel = true end
	for class in pairs(required) do
		local found = false
		for id, entry in pairs(entries) do
			if entry.class == class or (class == "chapel" and (entry.role == "chapel" or id == "chapel")) then
				found = true; break
			end
		end
		if not found then
			pcall(done, nil, "required outskirts asset class is missing: " .. class, "outskirts_dependency")
			return
		end
	end

	local finished, running, waiting, continuation = false, false, false, nil
	local timeouts, transitions = 0, 0
	local out_result, final_index
	local logf = env.log or function() end
	local function finish(out, message, kind)
		if finished then return end
		finished = true
		local called, err = pcall(done, out, message, kind)
		if not called then pcall(logf, "error", "towns outskirts: done callback raised: " .. tostring(err)) end
	end
	local function fatal(message, kind)
		finish(nil, "internal error in outskirts: " .. tostring(message), kind or "outskirts_error")
	end
	local state_ok, state = pcall(M.new, result.plan, result.plan.seed, entries, opts.player_pos)
	if not state_ok then
		fatal(state)
		return
	end
	local function reject(candidate, code, detail)
		state:reject(candidate, code, detail)
	end
	local pump
	local function emerge(minp, maxp, callback)
		waiting = true
		local settled = false
		local function settle(status)
			if settled or finished then return end
			settled, waiting = true, false
			continuation = function() callback(status) end
			pump()
		end
		env.emerge(minp, maxp, function(success) settle(success and "ok" or "failed") end)
		if not settled then
			env.after(M.CONSTANTS.EMERGE_TIMEOUT, function() settle("timeout") end)
		end
	end
	local function emerge_failure(status, candidate)
		if status == "ok" then timeouts = 0; return false end
		local label = candidate.id .. ":a" .. candidate.attempt
		if status == "timeout" then
			timeouts = timeouts + 1
			if timeouts >= M.CONSTANTS.MAX_CONSECUTIVE_TIMEOUTS then
				fatal("three consecutive terrain emerge requests timed out", "outskirts_dependency")
				return true
			end
		else
			timeouts = 0
		end
		reject(candidate, "emerge_failed", status == "timeout"
			and ("terrain emerge timed out for " .. label) or ("terrain emerge failed for " .. label))
		return true
	end
	local function terrain_volume(candidate, ground_y)
		local entry = entries[candidate.asset]
		local plan, schematic = terrain_adapter.mapping(candidate, entry, result.plan.bounds)
		local options = {}
		if ground_y then
			plan[1].pos.y = ground_y
		else
			options.surface_y = {min = result.ground_y - M.CONSTANTS.SCAN_DOWN,
				max = result.ground_y + M.CONSTANTS.SCAN_UP}
		end
		local volume, why = terrain_adapter.volume(opts.terrain, plan, schematic, options)
		if volume == nil then
			finish(nil, "Living Villages terrain.volume failed: " .. tostring(why), "outskirts_dependency")
			return nil
		end
		local minp, maxp = volume_box(volume)
		return minp, maxp
	end
	local function inspect(candidate)
		local heights = {}
		local min_y, max_y
		for x = candidate.rect.x1, candidate.rect.x2 do
			for z = candidate.rect.z1, candidate.rect.z2 do
				local height, issue, issue_y = placement.scan_column(function(y)
					return placement.classify(env.get_node_name(x, y, z), env.node_info)
				end, result.ground_y + M.CONSTANTS.SCAN_UP,
					result.ground_y - M.CONSTANTS.SCAN_DOWN)
				if not height then
					if issue == "unknown" then return nil, "plot_unloaded", ("unloaded node at (%d,%d,%d)"):format(x, issue_y, z) end
					if issue == "water" then return nil, "plot_water", ("water or ice at (%d,%d,%d)"):format(x, issue_y, z) end
					return nil, "plot_unloaded", ("no ground in scan window at (%d,%d)"):format(x, z)
				end
				heights[#heights + 1] = height
				min_y = min_y and math.min(min_y, height) or height
				max_y = max_y and math.max(max_y, height) or height
			end
		end
		if max_y - min_y > M.CONSTANTS.MAX_SPREAD then
			return nil, "plot_uneven", ("footprint spread %d exceeds %d"):format(max_y - min_y, M.CONSTANTS.MAX_SPREAD)
		end
		return {min = min_y, max = max_y}, median(heights)
	end
	local function process(candidate)
		local minp, maxp = terrain_volume(candidate)
		if finished then return end
		emerge(minp, maxp, function(status)
			if emerge_failure(status, candidate) then return end
			local heights, ground_or_code, detail = inspect(candidate)
			if not heights then return reject(candidate, ground_or_code, detail) end
			state:accept(candidate, heights, ground_or_code)
		end)
	end
	local function validate(out)
		assert(out.seed == result.plan.seed and out.ground_y == result.ground_y,
			"outskirts result does not match the accepted urban result")
		assert(type(result.center) == "table" and type(result.plan.center) == "table"
			and out.center and out.center.x == result.center.x and out.center.z == result.center.z
			and out.center.x == result.plan.center.x and out.center.z == result.plan.center.z,
			"outskirts result centre does not match the accepted urban result")
		assert(out.status == (#out.plots == 0 and "empty" or "planned"), "outskirts status is invalid")
		local prior = {}
		for _, plot in ipairs(out.plots) do
			local entry = assert(entries[plot.asset], "outskirts plot asset is missing")
			assert(type(plot.ground_y) == "number" and plot.ground_y >= plot.heights.min
				and plot.ground_y <= plot.heights.max, "outskirts plot ground is outside its measured heights")
			local placed = geometry.place({size = entry.size,
				entrance = entry.entrance or {x = 0, y = 1, z = 0}},
				{x = plot.rect.x1, y = plot.ground_y, z = plot.rect.z1}, plot.rotation)
			assert(placed.max.x == plot.rect.x2 and placed.max.z == plot.rect.z2,
				"outskirts plot rectangle differs from its rotated footprint")
			local fits, code = M.fits(plot.rect, prior, out.protected, opts.player_pos, C)
			assert(fits, "outskirts plot violates " .. tostring(code))
			prior[#prior + 1] = plot
		end
		for class, count in pairs(out.counts.planned) do
			local actual = 0
			for _, plot in ipairs(out.plots) do if plot.class == class then actual = actual + 1 end end
			assert(count == actual, "outskirts planned count differs for " .. class)
		end
	end
	local function omit_final(plot, status)
		table.remove(out_result.plots, final_index)
		out_result.status = #out_result.plots == 0 and "empty" or "planned"
		out_result.counts.planned[plot.class] = out_result.counts.planned[plot.class] - 1
		out_result.counts.rejected.emerge_failed = (out_result.counts.rejected.emerge_failed or 0) + 1
		out_result.rejections[#out_result.rejections + 1] = {
			stage = "emerge", code = "emerge_failed", subject = plot.id .. ":final",
			detail = status == "timeout" and "final terrain emerge timed out" or "final terrain emerge failed",
		}
	end
	local finalize_plot
	finalize_plot = function()
		local plot = out_result.plots[final_index]
		if not plot then
			validate(out_result)
			finish(out_result)
			return
		end
		local minp, maxp = terrain_volume(plot, plot.ground_y)
		if finished then return end
		emerge(minp, maxp, function(status)
			if status == "ok" then
				timeouts = 0
				final_index = final_index + 1
			else
				if status == "timeout" then
					timeouts = timeouts + 1
					if timeouts >= M.CONSTANTS.MAX_CONSECUTIVE_TIMEOUTS then
						fatal("three consecutive terrain emerge requests timed out", "outskirts_dependency")
						return
					end
				else
					timeouts = 0
				end
				omit_final(plot, status)
			end
			finalize_plot()
		end)
	end
	pump = function()
		if running or finished or waiting then return end
		running = true
		local ok_pump, err = pcall(function()
			while not finished and not waiting and transitions < M.CONSTANTS.PUMP_BUDGET do
				transitions = transitions + 1
				if continuation then
					local next_step = continuation; continuation = nil; next_step()
				else
					local candidate = state:next()
					if not candidate then
						out_result = state:result(result.ground_y)
						final_index = 1
						finalize_plot()
					else
						process(candidate)
					end
				end
			end
		end)
		running = false
		if not ok_pump then fatal(err); return end
		if not finished and not waiting and (continuation or transitions >= M.CONSTANTS.PUMP_BUDGET) then
			transitions = 0
			local scheduled, schedule_error = pcall(env.after, 0, pump)
			if not scheduled then fatal(schedule_error) end
		end
	end
	pump()
end

return M
