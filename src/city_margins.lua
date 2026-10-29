-- Optional adapter for the Living Villages city-margin terrain API.
-- Usage: local city_margins = dofile("src/city_margins.lua")
-- city_margins(terrain).attempt(result, done, env) completes once with a summary.
return function(terrain)
	local M = {}
	local TIMEOUT = 30
	local OPTIONS = {radius = 20, cap = 20}

	local function integer(v)
		return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
			and v == math.floor(v)
	end

	local function copy_pos(p)
		if type(p) ~= "table" or not integer(p.x) or not integer(p.y) or not integer(p.z) then return nil end
		return {x = p.x, y = p.y, z = p.z}
	end

	local function volume_bounds(box)
		if type(box) ~= "table" then return nil end
		local minp, maxp = copy_pos(box.minp), copy_pos(box.maxp)
		if not minp or not maxp or minp.x > maxp.x or minp.y > maxp.y or minp.z > maxp.z then
			return nil
		end
		return {minp = minp, maxp = maxp}
	end

	local function finish(done, summary, env)
		local ok, err = pcall(done, summary)
		if not ok and type(env.log) == "function" then
			pcall(env.log, "error", "towns city margins callback failed: " .. tostring(err))
		end
	end

	function M.attempt(result, done, env, build_summary)
		assert(type(done) == "function", "city_margins.attempt requires done")
		if env == nil then env = {} end
		if type(env) ~= "table" then env = {} end
		local completed = false
		local summary = {status = "skipped", reason = nil, stats = nil, attempted_bounds = nil}
		local function complete()
			if completed then return end
			completed = true
			finish(done, summary, env)
		end
		local function skip(reason)
			summary.status, summary.reason = "skipped", reason
			complete()
		end

		if type(terrain) ~= "table" or type(terrain.boundary_volume) ~= "function"
				or type(terrain.smooth_boundary) ~= "function" then
			skip("Living Villages city-margin API is unavailable")
			return
		end
		if terrain.boundary_structure_protection ~= 1 then
			skip("Living Villages does not support protected boundary grading")
			return
		end
		local town = type(build_summary) == "table" and build_summary.town
		local structures = type(town) == "table" and town.structures
		if type(structures) ~= "table" or type(env.is_protected) ~= "function" then
			skip("building bounds or protection service is unavailable")
			return
		end
		local boxes, count = {}, 0
		for key, structure in pairs(structures) do
			if not integer(key) or key < 1 or type(structure) ~= "table" then
				skip("building bounds are invalid"); return
			end
			local minp, maxp = copy_pos(structure.min), copy_pos(structure.max)
			if not minp or not maxp or minp.x > maxp.x or minp.y > maxp.y or minp.z > maxp.z then
				skip("building bounds are invalid"); return
			end
			boxes[key] = {min = minp, max = maxp}
			count = count + 1
		end
		if count ~= #structures then skip("building bounds are sparse"); return end
		if type(result) ~= "table" then
			skip("town boundary or ground level is unavailable")
			return
		end
		for _, feature in ipairs(result.wall_features or {}) do
			boxes[#boxes + 1] = {min = feature.min, max = feature.max}
		end
		local plan = result.plan
		local boundary_data = type(plan) == "table" and plan.boundary or nil
		local source = type(boundary_data) == "table" and boundary_data.rects or nil
		if type(source) ~= "table" or not integer(result.ground_y) then
			skip("town boundary or ground level is unavailable")
			return
		end
		local source_count = 0
		for key in pairs(source) do
			if not integer(key) or key < 1 then
				skip("town boundary contains an invalid rectangle list")
				return
			end
			source_count = source_count + 1
		end
		if source_count == 0 or source_count ~= #source then
			skip("town boundary rectangle list is empty or sparse")
			return
		end
		local boundary = {}
		for i, rect in ipairs(source) do
			if type(rect) ~= "table" or not integer(rect.x1) or not integer(rect.z1)
					or not integer(rect.x2) or not integer(rect.z2)
					or rect.x1 > rect.x2 or rect.z1 > rect.z2 then
				skip("town boundary contains an invalid rectangle")
				return
			end
			boundary[i] = {x0 = rect.x1, z0 = rect.z1, x1 = rect.x2, z1 = rect.z2}
		end

		local options = {radius = OPTIONS.radius, cap = OPTIONS.cap, structure_boxes = boxes,
			is_protected = env.is_protected}
		if env.api_env ~= nil then options.env = env.api_env end
		local ok, box, reason = pcall(terrain.boundary_volume, boundary, result.ground_y, options)
		if not ok then skip("boundary volume failed: " .. tostring(box)); return end
		local bounds = volume_bounds(box)
		if not bounds then skip(reason or "boundary volume was invalid or unavailable"); return end

		if type(env.emerge) ~= "function" or type(env.after) ~= "function" then
			skip("emerge environment is unavailable")
			return
		end
		local waiting = true
		local function after_emerge(success, emerge_reason)
			if not waiting or completed then return end
			waiting = false
			if not success then
				skip(emerge_reason or "boundary volume emerge failed")
				return
			end
			-- Preserve the attempted envelope even when the writer throws or declines.
			summary.attempted_bounds = bounds
			local write_ok, wrote, stats_or_reason = pcall(terrain.smooth_boundary,
				boundary, result.ground_y, options)
			if not write_ok then
				summary.status, summary.reason = "incomplete", "boundary smoothing failed: " .. tostring(wrote)
			elseif wrote then
				summary.status, summary.stats = "smoothed", stats_or_reason
			else
				summary.status, summary.reason = "incomplete", stats_or_reason or "boundary smoothing was incomplete"
			end
			complete()
		end

		local emerge_ok, emerge_err = pcall(env.emerge, bounds.minp, bounds.maxp,
			function(success) after_emerge(success, success and nil or "boundary volume emerge failed") end)
		if not emerge_ok then
			if waiting then after_emerge(false, "boundary volume emerge failed: " .. tostring(emerge_err)) end
			return
		end
		if waiting then
			local timer_ok, timer_err = pcall(env.after, TIMEOUT, function()
				after_emerge(false, "boundary volume emerge timed out after " .. TIMEOUT .. " seconds")
			end)
			if not timer_ok then after_emerge(false, "emerge watchdog scheduling failed: " .. tostring(timer_err)) end
		end
	end

	return M
end
