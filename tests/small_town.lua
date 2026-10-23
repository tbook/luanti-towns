-- A small synthetic medieval town for fast planner tests: a 96-node envelope
-- and a hand-made landmark profile instead of the real catalog, so a plan
-- takes milliseconds rather than a second. The production planner path is the
-- same (planner.plan always takes a landmark profile); only the sizes differ.
--
--   local small = dofile("tests/small_town.lua")(planner)
--   small.plan(center, seed [, extra_opts])   planner.plan with the small town
--   small.validate(plan)                      planner.validate with its constants
--   small.opts([extra]), small.constants, small.profile
return function(planner)
	local M = {}

	-- Cathedral door off-centre on a short end, castle gate recessed.
	M.profile = {
		cathedral = {id = "t_cath", size = {x = 20, y = 18, z = 30},
			entrance = {x = 5, y = 3, z = 2}, ground_offset = 1},
		castle = {id = "t_castle", size = {x = 24, y = 20, z = 26},
			entrance = {x = 17, y = 5, z = 3}, ground_offset = 2},
	}

	-- The ENVELOPE and the dimensions that depend on it.
	M.constants = {
		ENVELOPE = 96, MIN_LONG_SPAN = 80, MIN_SHORT_SPAN = 60,
		CENTER_JITTER = 8, MAX_SECONDARY = 8, MAX_BLOCK_SCAN = 64,
	}

	-- Planner opts for the small town; `extra` fields (and extra.constants)
	-- are added on top.
	function M.opts(extra)
		local o = {landmarks = M.profile, constants = {}}
		for k, v in pairs(M.constants) do o.constants[k] = v end
		for k, v in pairs(extra or {}) do
			if k == "constants" then
				for ck, cv in pairs(v) do o.constants[ck] = cv end
			else
				o[k] = v
			end
		end
		return o
	end

	function M.plan(center, seed, extra)
		return planner.plan(center, seed, M.opts(extra))
	end

	function M.validate(plan, constants)
		local c = {}
		for k, v in pairs(M.constants) do c[k] = v end
		for k, v in pairs(constants or {}) do c[k] = v end
		return planner.validate(plan, c)
	end

	return M
end
