-- The medieval test town: the real catalog profile planned by the
-- constructive row-grid planner (src/medieval_planner.lua), which takes about
-- 30 ms per plan.
--
--   local small = dofile("tests/small_town.lua")(planner)
--   small.plan(center, seed [, extra_opts])   planner.plan with the profile
--   small.validate(plan)                      authored_plan.validate
--   small.opts([extra]), small.profile
return function(planner)
	local M = {}
	local catalog = dofile("src/catalog.lua")
	local authored_plan = dofile("src/authored_plan.lua")

	M.profile = assert(planner.landmark_profile(catalog.snapshot()))

	-- The deepest ordinary building: the medieval planner's row depth.
	M.row = 0
	for _, e in pairs(M.profile.content) do M.row = math.max(M.row, e.size.z) end

	-- Planner opts; `extra` fields are added on top.
	function M.opts(extra)
		local o = {landmarks = M.profile}
		for k, v in pairs(extra or {}) do o[k] = v end
		return o
	end

	function M.plan(center, seed, extra)
		return planner.plan(center, seed, M.opts(extra))
	end

	function M.validate(plan)
		return authored_plan.validate(plan, {min_block_depth = M.row})
	end

	return M
end
