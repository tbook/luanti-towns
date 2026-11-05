-- Coordination with the current Living Villages planner (#400).
-- The owner supplies the same bounds environment and lookup as auto_state, a
-- session, the accepted registry, and a mode function. Install after LV's
-- planner; its public API does not attest which callable was installed, so
-- that identity (like A10 ordering) remains an assumption. check() detects a
-- later replacement, but calls reaching a replacement before check() cannot
-- be protected, including calls overlapping accepted records.
--
-- install(opts) returns guard or nil, reason. opts: settlements, env (the
-- validated auto_bounds environment), lookup(rect), session, registry,
-- enabled() (whether new sites may activate), disable(reason), log(reason).
-- Optional on_suppressed(reason) can count lost village opportunities.
-- check() should be called before each automatic job. In off mode the guard
-- still protects accepted records, but does not decline or reserve new sites.
-- No planner arguments or RNG are read except the two chunk bounds.
local M = {}
local installed = setmetatable({}, {__mode = "k"})
local failed_options = setmetatable({}, {__mode = "k"})
local sites = dofile((debug.getinfo(1, "S").source:sub(2):match("^(.*)/src/auto_villages.lua$") or ".") .. "/src/auto_sites.lua")

local function integer(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge and n == math.floor(n)
end
local function rect_ok(r)
	return type(r) == "table" and integer(r.x1) and integer(r.z1) and integer(r.x2) and integer(r.z2)
		and r.x1 <= r.x2 and r.z1 <= r.z2
end
local function overlap(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end
local function fail(opts, why)
	pcall(opts.disable, why)
	pcall(opts.log, why)
	return nil, why
end

function M.install(opts)
	if type(opts) ~= "table" then return nil, "options required" end
	if failed_options[opts] then return nil, failed_options[opts] end
	local disable = type(opts.disable) == "function" and opts.disable or function() end
	local log = type(opts.log) == "function" and opts.log or function() end
	local notify = {disable = function(why) failed_options[opts] = why; disable(why) end, log = log}
	local s, env, session, registry = opts.settlements, opts.env, opts.session, opts.registry
	if type(s) ~= "table" or type(s.create_site_plan) ~= "function"
		or type(s.schematic_table) ~= "table" or #s.schematic_table == 0
		or type(s.find_surface) ~= "function" or type(s.check_distance) ~= "function"
		or type(s.terraform) ~= "function" or type(s.surface_mat) ~= "table"
		or type(env) ~= "table" or not integer(env.village_reach) or env.village_reach < 0
		or type(env.config) ~= "table" or type(env.config.village) ~= "table"
		or type(env.providers) ~= "table" or type(env.providers.volume) ~= "table"
		or type(env.providers.volume.terrain) ~= "function"
		or type(opts.lookup) ~= "function" or type(opts.enabled) ~= "function"
		or type(session) ~= "table" or type(session.state) ~= "function" or type(session.decline) ~= "function"
		or type(registry) ~= "table" or type(registry.lookup) ~= "function" or type(registry.is_enabled) ~= "function" then
		return fail(notify, "unsupported Living Villages coordination dependencies")
	end
	for _, schem in ipairs(s.schematic_table) do
		if type(schem) ~= "table" or type(schem.name) ~= "string" or not integer(schem.hwidth)
			or not integer(schem.hdepth) or not integer(schem.hheight) then
			return fail(notify, "unsupported Living Villages schematic shape")
		end
	end
	if installed[s] then
		if s.create_site_plan == installed[s].wrapper then return installed[s] end
		return fail(notify, "village planner was replaced after guard installation")
	end
	local function suppress(reason)
		if type(opts.on_suppressed) == "function" then pcall(opts.on_suppressed, reason) end
		return false
	end
	local reach = env.village_reach
	local guard = {original = s.create_site_plan, failed = false}
	local function disable_once(why)
		if not guard.failed then guard.failed = true; fail(notify, why) end
	end
	-- Bind the real session before enabling automatic generation. The startup
	-- guard uses an inert session while off, and always protects accepted records.
	function guard:bind(next_session, lookup, enabled, on_suppressed)
		if self.failed or type(next_session) ~= "table" or type(next_session.state) ~= "function"
			or type(next_session.decline) ~= "function" or type(lookup) ~= "function"
			or type(enabled) ~= "function" or (on_suppressed ~= nil and type(on_suppressed) ~= "function") then return false end
		session, opts.lookup, opts.enabled, opts.on_suppressed = next_session, lookup, enabled, on_suppressed
		return self:check()
	end
	function guard:check()
		if s.create_site_plan ~= self.wrapper then disable_once("village planner was replaced after guard installation") end
		return not self.failed
	end
	guard.wrapper = function(maxp, minp, ...)
		local args, count = {...}, select("#", ...)
		local function pass() return guard.original(maxp, minp, unpack(args, 1, count)) end
		if type(maxp) ~= "table" or type(minp) ~= "table" or not integer(maxp.x) or not integer(maxp.z)
			or not integer(minp.x) or not integer(minp.z) or minp.x > maxp.x or minp.z > maxp.z then
			disable_once("unsupported village planner arguments")
			return pass()
		end
		local x, z = math.floor((minp.x + maxp.x) / 2), math.floor((minp.z + maxp.z) / 2)
		local rect = {x1 = x - reach, z1 = z - reach, x2 = x + reach, z2 = z + reach}
		local healthy = registry:is_enabled()
		if not healthy then disable_once("automatic town registry unavailable"); return pass() end
		-- Accepted records are keyed by cell. Their reserved maximum lies inside
		-- that cell, even when the currently configured site descriptor changed.
		for cz = sites.cell_index(rect.z1), sites.cell_index(rect.z2) do
			for cx = sites.cell_index(rect.x1), sites.cell_index(rect.x2) do
				local r, why, code = registry:lookup({x = cx, z = cz})
				if code then disable_once("automatic town registry lookup failed: " .. tostring(why)); return pass() end
				if r then
					local e = r.envelope
					if overlap(rect, {x1 = e.min.x, z1 = e.min.z, x2 = e.max.x, z2 = e.max.z}) then return suppress("accepted") end
				end
			end
		end
		if guard.failed or not opts.enabled() then return pass() end
		local found, why = opts.lookup(rect)
		if type(found) ~= "table" then disable_once("automatic town site lookup failed: " .. tostring(why)); return pass() end
		for _, d in ipairs(found) do
			if type(d) ~= "table" or type(d.id) ~= "string" or not rect_ok(d.max_rect) then
				disable_once("invalid automatic town site descriptor"); return pass()
			end
		end
		-- First look for active inspections, then decline every other overlapping
		-- candidate before the planner can generate any chunks reentrantly.
		for _, d in ipairs(found) do
			if overlap(rect, d.max_rect) and session:state(d.id) == "inspecting" then return suppress("inspecting") end
		end
		for _, d in ipairs(found) do
			if overlap(rect, d.max_rect) then
				local state = session:state(d.id)
				if state == nil or state == "contacted" then session:decline(d.id) end
			end
		end
		return pass()
	end
	s.create_site_plan = guard.wrapper
	installed[s] = guard
	return guard
end
return M
