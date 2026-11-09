-- Aqueduct build step (issue #417, step 3): the glue between the shared build
-- pipeline (generate_command.lua finish_build) and src/aqueduct_build.lua.
-- Pure Lua, no Minetest globals: every world function arrives through `deps`
-- so tests drive it with fakes.
--
-- The aqueduct is a cosmetic extra. This step never fails, alters or extends
-- the town: its only output is summary.aqueduct ({status="skipped", reason} or
-- the adapter's {status="built", ...}). Anything that goes wrong, including
-- errors in this wiring, becomes skipped plus a log line, and `continue` is
-- still called exactly once.
--
-- API:
--   M.footprints(result, summary) -> rect list {x1,z1,x2,z2}: town area,
--       buildings (incl. outskirts), road/wall ramps and features, outskirts plots.
--   M.make_env(deps) -> env for aqueduct_build.build. deps:
--       emerge(min, max, cb)   open_region(min, max)   protected(pos)
--       check_ownership()      after(sec, fn)          set_node(pos, node)
--       registered_nodes (optional, for the group based is_vegetation)
--       authorize_strip(box) (optional override; default allows any strip)
--   M.run(result, summary, ctx, continue)
--       ctx.env       env, or nil when the context has no aqueduct capability
--       ctx.skip_reason  reason text used when ctx.env is nil
--       ctx.opts      optional {y_min, y_max, timeout} (clamp from the caller)
--       ctx.build     adapter build function (default aqueduct_build.build)
--       ctx.log(level, msg)  ctx.after(seconds, fn) optional
local M = {}
local source = debug.getinfo(1, "S").source:sub(2)
local modpath = source:match("^(.*)/src/aqueduct_step.lua$") or "."

local adapter = dofile(modpath .. "/src/aqueduct_build.lua")
local VEGETATION_GROUPS = {"leaves", "tree", "plant", "flora", "dig_by_water", "vines", "sapling",
	"attached_node"}

local function rect_ok(r)
	return type(r) == "table" and type(r.x1) == "number" and type(r.z1) == "number"
		and type(r.x2) == "number" and type(r.z2) == "number"
end

local function structure_rect(st)
	if rect_ok(st.rect) then return st.rect end
	if type(st.min) == "table" and type(st.max) == "table" then
		return {x1 = st.min.x, z1 = st.min.z, x2 = st.max.x, z2 = st.max.z}
	end
end

function M.footprints(result, summary)
	local out = {}
	local function add(r)
		if rect_ok(r) then out[#out + 1] = {x1 = r.x1, z1 = r.z1, x2 = r.x2, z2 = r.z2} end
	end
	local plan = result.plan or {}
	add(plan.bounds)
	for _, r in ipairs(plan.boundary and plan.boundary.rects or {}) do add(r) end
	local town = summary and summary.town
	for _, st in ipairs(town and town.structures or {}) do add(structure_rect(st)) end
	for _, r in ipairs(result.wall_feature_footprints or {}) do add(r) end
	for _, p in ipairs(result.outskirts and result.outskirts.plots or {}) do add(p.rect) end
	return out
end

function M.make_env(d)
	local registered = d.registered_nodes
	local env = {
		emerge = function(box, cb) return d.emerge(box.min, box.max, cb) end,
		open_region = function(box) return d.open_region(box.min, box.max) end,
		authorize_strip = d.authorize_strip or function() return true end,
		check_ownership = d.check_ownership,
		protected = d.protected,
		after = d.after,
		set_node = d.set_node,
	}
	if registered then
		-- Groups OR the adapter's name heuristic (dirt, podzol, mycelium and
		-- "_block" nodes never count). Unregistered names use the heuristic alone.
		env.is_vegetation = function(name)
			if adapter.is_vegetation_name(name) then return true end
			local def = registered[name]
			local groups = def and def.groups or {}
			for _, g in ipairs(VEGETATION_GROUPS) do
				if (groups[g] or 0) > 0 then return true end
			end
			return false
		end
	end
	return env
end

local function describe(r)
	if r.status == "built" then
		return ("aqueduct built: side %s, length %s, rise %s, spout %s,%s,%s%s"):format(
			tostring(r.side), tostring(r.length), tostring(r.rise),
			tostring(r.spout and r.spout.x), tostring(r.spout and r.spout.y), tostring(r.spout and r.spout.z),
			r.spout_written == false and (" (spout write failed: " .. tostring(r.spout_error) .. ")") or "")
	end
	return "aqueduct skipped: " .. tostring(r.reason)
end

function M.run(result, summary, ctx, continue)
	if not result.plan or result.plan.town_type ~= "roman" then return continue() end
	local settled = false
	local log = ctx.log or function() end
	local function conclude(r)
		if settled then return end
		settled = true
		if type(r) ~= "table" or (r.status ~= "built" and r.status ~= "skipped") then
			r = {status = "skipped", reason = "invalid aqueduct result"}
		end
		summary.aqueduct = r
		pcall(log, r.status == "built" and "action" or "warning", "towns: " .. describe(r))
		continue()
	end

	-- The adapter's callback can arrive inside its own pcall (synchronously or
	-- from an emerge callback), which would swallow an error thrown by
	-- `continue`. So the result is only recorded there and `continue` runs
	-- outside: after build() returns, or from a zero-second timer when late.
	local in_build, pending = true, nil
	local function adapter_done(r)
		if settled or pending then return end
		pending = r
		if in_build then return end
		-- Only registering the timer is guarded; the continuation runs from the timer.
		local timed = ctx.after and pcall(ctx.after, 0, function() conclude(pending) end)
		if not timed then conclude(pending) end
	end
	local ok, err = pcall(function()
		if not ctx.env then
			pending = {status = "skipped", reason = ctx.skip_reason or "no aqueduct capability"}
			return
		end
		local build = ctx.build or adapter.build
		local opts = {ground_y = result.ground_y, footprints = M.footprints(result, summary)}
		for _, k in ipairs({"y_min", "y_max", "timeout"}) do
			if ctx.opts and ctx.opts[k] ~= nil then opts[k] = ctx.opts[k] end
		end
		build(result.plan, ctx.env, opts, adapter_done)
	end)
	in_build = false
	if not ok and not pending then
		pending = {status = "skipped", reason = "error: " .. tostring(err)}
	end
	if pending then conclude(pending) end
end

return M
