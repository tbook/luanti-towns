-- Pure deterministic planner for scattered rural plots around a town.
-- Terrain inspection is owned by the caller: next() yields one candidate,
-- then accept() or reject() resolves it before the next attempt is requested.
local M = {}

M.CONSTANTS = {
	VERSION = 1, FARM_COUNT = 18, HUT_COUNT = 6, VILLA_COUNT = 2, CHAPEL_COUNT = 1,
	FARM_BAND_NEAR = 14, FARM_BAND_FAR = 48, OUTER_BAND_NEAR = 48, OUTER_BAND_FAR = 116,
	MIN_SPACING = 20, PROTECT_MARGIN = 4, TERRAFORM_REACH = 10, PLAYER_MARGIN = 16,
	ATTEMPTS_PER_BUILDING = 6, SAMPLE_LIMIT = 50, MAX_SPREAD = 4,
	SCAN_UP = 48, SCAN_DOWN = 48, SALT = 226,
}

local function load_geometry()
	local core = rawget(_G, "core")
	if core and core.get_modpath and core.get_current_modname then
		return dofile(core.get_modpath(core.get_current_modname()) .. "/src/geometry.lua")
	end
	return dofile("src/geometry.lua")
end
local geometry = load_geometry()

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

return M
