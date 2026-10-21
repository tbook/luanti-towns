-- Towns: composition and preflight of a complete town build (ticket #44).
-- Pure Lua 5.1 except for the injected `env`; this module NEVER writes to
-- the world and calls only read/emerge functions of its env, so a failed
-- preflight has changed nothing by construction. It does not place anything
-- (that is ticket #45) and registers no mapgen.
--
--   local preflight = dofile(".../preflight.lua")
--
--   preflight.compose(plan, entries, ground_y)
--       -> comp | nil, message, reason  (reason: bad_input, missing_entry,
--       geometry or out_of_bounds, as in check)
--   preflight.run(params, env, done)         asynchronous; done is called
--       exactly once: done(report) or done(nil, message, "inspection_failed",
--       {reason = <code>}). run() itself does not raise for bad input.
--   preflight.check(params, env) -> report | nil, message, reason
--       everything run() does except the emerge (pure given env reads).
--   preflight.core_env(core) -> env
--
-- Wiring into builder / /towns_generate is deliberately NOT done here: the
-- whole path is opt-in today and is left to tickets #45 and #49. Nothing in
-- the legacy command calls this module.
--
-- compose: every civic and content placement of a finished plan resolved to
-- an exact XYZ box. Sources, in this deterministic order: named sites
-- (landmarks), plan.reservations.jail, plan.reservations.services, then
-- plan.content.buildings. `entries` is id -> {size, entrance, ground_offset,
-- path, data_path} (catalog.entries, or the planner landmark profile when
-- only heights are needed). The rotated box is placed with geometry.place at
-- {rect.x1, ground_y - ground_offset, rect.z1}, i.e. the foundation sits at
-- the accepted ground level and the box includes the true schematic height.
-- The planned rect must equal the rotated footprint, lie inside plan.bounds
-- and not overlap another structure; otherwise compose fails.
--
--   comp = {
--     structures = list of {id, kind, role, rotation, rect, min, max, size,
--                  entrance, ground_offset}   (min/max inclusive XYZ)
--     min_y, max_y = lowest/highest node of any structure (nil when none)
--   }
--
-- params for check/run:
--   plan, entries, ground_y           as above (required)
--   build_bounds {min,max}            the site_search build bounds; every
--                                     structure box must lie inside
--   build_volume {min,max}            optional; emerged instead of
--                                     build_bounds (must contain it)
--   player {x,y,z}, player_margin     the player's X/Z may not be within
--                                     plan.bounds grown by the margin (4)
--   modpath                           prefix of entry.path / data_path
--   limit                             coordinate limit (default 31000)
--   emerge_timeout                    seconds (default 30), needs env.after
--
-- env (all injected):
--   env.read_schematic(path) -> {size = {x,y,z}, data = optional list of
--                               {name = ...}} | nil   (core.read_schematic)
--   env.read_data(path) -> {required_nodes = {names}} | nil
--   env.node_registered(name) -> boolean
--   env.emerge(minpos, maxpos, cb)  cb(ok) exactly once, after the whole
--                               volume is loaded
--   env.after(seconds, fn)      optional watchdog timer
--   env.log(level, msg)         optional
--
-- report = {structures, min_y, max_y, bounds = {min,max} (build_bounds),
--           volume = {min,max} (emerged), files = n, nodes = {names}}

local M = {}

local function load_sibling(name)
	local c = rawget(_G, "core")
	if c and c.get_modpath and c.get_current_modname then
		return dofile(c.get_modpath(c.get_current_modname()) .. "/src/" .. name)
	end
	return dofile("src/" .. name)
end
local geometry = load_sibling("geometry.lua")
local plan_sites = load_sibling("plan_sites.lua")

M.LIMIT = 31000
M.PLAYER_MARGIN = 4
M.EMERGE_TIMEOUT = 30
M.NOTE = " Nothing was changed."

local function is_int(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
		and v == math.floor(v)
end

local function overlap(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

local function fmt_rect(r)
	return ("x %d..%d, z %d..%d"):format(r.x1, r.x2, r.z1, r.z2)
end

local function valid_rect(r)
	return type(r) == "table" and is_int(r.x1) and is_int(r.z1) and is_int(r.x2)
		and is_int(r.z2) and r.x1 <= r.x2 and r.z1 <= r.z2
end

-- Resolves one placement; returns structure or nil, message.
local function resolve(entries, ground_y, bounds, id, kind, role, rotation, rect)
	local label = ("%s '%s'"):format(kind, tostring(id))
	local e = entries[id]
	if type(e) ~= "table" or type(e.size) ~= "table" or type(e.entrance) ~= "table" then
		return nil, label .. " has no catalog entry", "missing_entry"
	end
	local s = e.size
	if not (is_int(s.x) and is_int(s.y) and is_int(s.z) and s.x > 0 and s.y > 0 and s.z > 0) then
		return nil, label .. " has no valid schematic size", "geometry"
	end
	local go = e.ground_offset or 0
	if not is_int(go) or go < 0 or go >= s.y then
		return nil, label .. " has an invalid ground_offset", "geometry"
	end
	if not valid_rect(rect) then return nil, label .. " has no valid planned rect", "geometry" end
	local ok, g = pcall(geometry.place, {size = s, entrance = {x = e.entrance.x or 0,
		y = e.entrance.y or 1, z = e.entrance.z or 0, facing = e.entrance.facing}},
		{x = rect.x1, y = ground_y - go, z = rect.z1}, rotation)
	if not ok then return nil, label .. ": " .. tostring(g), "geometry" end
	if g.max.x ~= rect.x2 or g.max.z ~= rect.z2 then
		return nil, ("%s: planned rect (%s) is not its rotated %dx%d footprint at rotation %s"):format(
			label, fmt_rect(rect), g.size.x, g.size.z, tostring(rotation)), "geometry"
	end
	if rect.x1 < bounds.x1 or rect.x2 > bounds.x2 or rect.z1 < bounds.z1 or rect.z2 > bounds.z2 then
		return nil, label .. " lies outside the town bounds (" .. fmt_rect(rect) .. ")", "out_of_bounds"
	end
	local excluded_beds = {}
	for _, p in ipairs(e.excluded_resident_beds or {}) do
		local x, z = p.x, p.z
		if g.rotation == 90 then x, z = z, s.x - 1 - x
		elseif g.rotation == 180 then x, z = s.x - 1 - x, s.z - 1 - z
		elseif g.rotation == 270 then x, z = s.z - 1 - z, x end
		excluded_beds[#excluded_beds + 1] = {x = g.min.x + x, y = g.min.y + p.y, z = g.min.z + z}
	end
	return {
		id = id, kind = kind, role = role or kind, rotation = g.rotation,
		rect = {x1 = rect.x1, z1 = rect.z1, x2 = rect.x2, z2 = rect.z2},
		min = g.min, max = g.max, size = g.size, entrance = g.entrance, front = g.front,
		ground_offset = go, excluded_beds = excluded_beds,
	}
end

function M.compose(plan, entries, ground_y)
	if type(plan) ~= "table" or type(plan.sites) ~= "table" or type(plan.bounds) ~= "table" then
		return nil, "plan is not a town plan", "bad_input"
	end
	if type(entries) ~= "table" then return nil, "no catalog entries", "bad_input" end
	if not is_int(ground_y) then return nil, "ground_y must be an integer", "bad_input" end
	local list, err, code = {}, nil, nil
	local function add(id, kind, role, rotation, rect)
		if err then return end
		if id == nil then
			err, code = kind .. " has no catalog id", "missing_entry"
			return
		end
		local st, why, wcode = resolve(entries, ground_y, plan.bounds, id, kind, role, rotation, rect)
		if not st then err, code = why, wcode else list[#list + 1] = st end
	end
	for _, item in ipairs(plan_sites.list(plan)) do
		local name, s = item.name, item.site
		if type(s) == "table" and s.kind == "landmark" then
			add(s.id, name, name, s.rotation, s.rect)
		end
	end
	local res = plan.reservations
	if type(res) == "table" then
		if type(res.jail) == "table" then
			local j = res.jail
			add(j.building_id, "jail", "jail", j.rotation, j.rect)
		end
		for _, p in ipairs(res.services or {}) do
			add(p.building_id, "service", p.role, p.rotation, p.rect)
		end
	end
	if type(plan.content) == "table" then
		for _, b in ipairs(plan.content.buildings or {}) do
			add(b.building_id, "content", b.role, b.rotation, b.rect)
		end
	end
	if err then return nil, err, code end
	for i = 1, #list do
		for j = i + 1, #list do
			if overlap(list[i].rect, list[j].rect) then
				return nil, ("%s '%s' and %s '%s' overlap"):format(list[i].kind, list[i].id,
					list[j].kind, list[j].id), "geometry"
			end
		end
	end
	local min_y, max_y
	for _, st in ipairs(list) do
		if not min_y or st.min.y < min_y then min_y = st.min.y end
		if not max_y or st.max.y > max_y then max_y = st.max.y end
	end
	return {structures = list, min_y = min_y, max_y = max_y}
end

local function box_ok(b)
	if type(b) ~= "table" or type(b.min) ~= "table" or type(b.max) ~= "table" then return false end
	for _, a in ipairs({"x", "y", "z"}) do
		if not is_int(b.min[a]) or not is_int(b.max[a]) or b.min[a] > b.max[a] then
			return false
		end
	end
	return true
end

local function contains(outer, inner)
	for _, a in ipairs({"x", "y", "z"}) do
		if inner.min[a] < outer.min[a] or inner.max[a] > outer.max[a] then return false end
	end
	return true
end

local function fail(reason, msg) return nil, msg .. M.NOTE, reason end

-- Pure part of the preflight; see the header.
function M.check(params, env)
	if type(params) ~= "table" or type(env) ~= "table" then
		return fail("bad_input", "preflight needs params and env")
	end
	local limit = params.limit or M.LIMIT
	local bb = params.build_bounds
	if not box_ok(bb) then return fail("bad_input", "build_bounds missing or malformed") end
	local vol = params.build_volume or bb
	if not box_ok(vol) then return fail("bad_input", "build_volume malformed") end
	if not contains(vol, bb) then
		return fail("out_of_bounds", "build_volume does not contain build_bounds")
	end
	for _, a in ipairs({"x", "y", "z"}) do
		if math.abs(vol.min[a]) > limit or math.abs(vol.max[a]) > limit then
			return fail("out_of_bounds", "the build volume extends beyond +/-" .. limit)
		end
	end

	local comp, why, reason = M.compose(params.plan, params.entries, params.ground_y)
	if not comp then
		return fail(reason or "geometry", "Invalid town content: " .. why .. ".")
	end
	if #comp.structures == 0 then
		return fail("no_structures", "The plan has no buildings to construct.")
	end
	for _, st in ipairs(comp.structures) do
		if not contains(bb, st) then
			return fail("out_of_bounds", ("%s '%s' (%d,%d,%d to %d,%d,%d) does not fit the build bounds"):format(
				st.kind, st.id, st.min.x, st.min.y, st.min.z, st.max.x, st.max.y, st.max.z))
		end
	end

	local p = params.player
	if p ~= nil then
		local m = params.player_margin or M.PLAYER_MARGIN
		local b = params.plan.bounds
		local px, pz = math.floor(p.x + 0.5), math.floor(p.z + 0.5)
		if px >= b.x1 - m and px <= b.x2 + m and pz >= b.z1 - m and pz <= b.z2 + m then
			return fail("player_inside", ("The player at (%d,%d) is inside the town footprint."):format(px, pz))
		end
	end

	-- Files, dimensions and node registrations, once per catalog id.
	local prefix = params.modpath and (params.modpath .. "/") or ""
	local seen, ids, names, files = {}, {}, {}, 0
	for _, st in ipairs(comp.structures) do
		if not seen[st.id] then seen[st.id] = true; ids[#ids + 1] = st.id end
	end
	table.sort(ids)
	local nodes = {}
	for _, id in ipairs(ids) do
		local e = params.entries[id]
		if type(e.path) ~= "string" then
			return fail("missing_file", "Building '" .. id .. "' has no schematic file.")
		end
		local ok, s = pcall(env.read_schematic, prefix .. e.path)
		if not ok or type(s) ~= "table" or type(s.size) ~= "table" then
			return fail("missing_file", "Schematic file " .. e.path .. " for '" .. id
				.. "' is missing or unreadable.")
		end
		if s.size.x ~= e.size.x or s.size.y ~= e.size.y or s.size.z ~= e.size.z then
			return fail("size_mismatch", ("Schematic %s is %dx%dx%d but the catalog declares %dx%dx%d."):format(
				e.path, s.size.x or -1, s.size.y or -1, s.size.z or -1, e.size.x, e.size.y, e.size.z))
		end
		files = files + 1
		local required = {}
		for _, n in ipairs(type(s.data) == "table" and s.data or {}) do
			if type(n) == "table" and type(n.name) == "string" then required[#required + 1] = n.name end
		end
		if e.data_path then
			local dok, d = pcall(env.read_data, prefix .. e.data_path)
			if not dok or type(d) ~= "table" or type(d.required_nodes) ~= "table" then
				return fail("missing_file", "Data file " .. e.data_path .. " for '" .. id
					.. "' is missing or unreadable.")
			end
			for _, n in ipairs(d.required_nodes) do required[#required + 1] = n end
		end
		for _, n in ipairs(required) do
			if n ~= "air" and n ~= "ignore" and not nodes[n] then
				nodes[n] = true
				names[#names + 1] = n
			end
		end
	end
	table.sort(names)
	for _, n in ipairs(names) do
		local ok, known = pcall(env.node_registered, n)
		if not ok or not known then
			return fail("missing_node", "Required node '" .. n .. "' is not registered; enable its mod.")
		end
	end
	return {
		structures = comp.structures, min_y = comp.min_y, max_y = comp.max_y,
		bounds = bb, volume = vol, files = files, nodes = names,
	}
end

function M.run(params, env, done)
	local finished = false
	local function finish(...)
		if finished then return end
		finished = true
		local ok, err = pcall(done, ...)
		if not ok and type(env) == "table" and env.log then
			pcall(env.log, "error", "towns preflight: done callback raised: " .. tostring(err))
		end
	end
	local function failure(msg, reason)
		finish(nil, msg, "inspection_failed", {reason = reason})
	end
	local ok, report, msg, reason = pcall(M.check, params, env)
	if not ok then return failure("Preflight error: " .. tostring(report) .. M.NOTE, "internal") end
	if not report then return failure(msg, reason) end
	local vol = report.volume
	local timeout = params.emerge_timeout or M.EMERGE_TIMEOUT
	local settled = false
	local function settle(status)
		if settled or finished then return end
		settled = true
		if status == "ok" then
			finish(report)
		elseif status == "timeout" then
			failure("The build volume did not finish loading within " .. timeout .. "s." .. M.NOTE,
				"emerge_timeout")
		else
			failure("The build volume could not be loaded (emerge failed)." .. M.NOTE, "emerge_failed")
		end
	end
	local eok, err = pcall(env.emerge, vol.min, vol.max, function(good)
		settle(good and "ok" or "failed")
	end)
	if not eok then
		return failure("The build volume could not be loaded: " .. tostring(err) .. M.NOTE,
			"emerge_failed")
	end
	if not settled and env.after then
		pcall(env.after, timeout, function() settle("timeout") end)
	end
end

function M.core_env(c)
	return {
		read_schematic = function(path) return c.read_schematic(path, {}) end,
		read_data = function(path) return dofile(path) end,
		node_registered = function(name) return c.registered_nodes[name] ~= nil end,
		after = function(seconds, fn) c.after(seconds, fn) end,
		log = function(level, msg) c.log(level, msg) end,
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
