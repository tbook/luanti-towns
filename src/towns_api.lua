-- Public, versioned, read-only integration API (global `towns_api`, #458).
-- See docs/roads_integration.md for the contract. Pure Lua: every dependency is
-- injected, so the module is tested without the engine. All results are fresh
-- tables with integer coordinates and a deterministic order; callers never see
-- Towns storage or internal tables.
--
-- new(deps):
--   deps.registry()  -> the auto_records registry (or nil)
--   deps.session()   -> the automatic-town session (or nil when automatic towns are off)
--   deps.lock        -> generation lock with current()
local function sibling(name)
	local c = rawget(_G, "core")
	if c and c.get_modpath and c.get_current_modname then
		return dofile(c.get_modpath(c.get_current_modname()) .. "/src/" .. name)
	end
	local source = debug.getinfo(1, "S").source:sub(2)
	local root = source:match("^(.*)/src/towns_api.lua$") or "."
	return dofile(root .. "/src/" .. name)
end
local exits_mod = sibling("town_exits.lua")

local M = {}
M.VERSION = 1
M.MAX_RADIUS = 1024        -- settlements(): largest search radius
M.MAX_SETTLEMENTS = 32     -- settlements(): results returned
M.MAX_SIDE = 2048          -- exclusions(): largest rect side, in nodes
M.MAX_EXCLUSIONS = 256     -- exclusions(): items before "too_many"
M.WORLD_Y = 31000          -- vertical bound of a candidate reservation

local function integer(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v == math.floor(v)
end

local function finite(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function overlaps(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

local function rect_copy(r) return {x1 = r.x1, z1 = r.z1, x2 = r.x2, z2 = r.z2} end

local function settlement_id(rec) return "auto:" .. rec.cell.x .. ":" .. rec.cell.z end

local function parse_id(id)
	if type(id) ~= "string" then return nil end
	local x, z = id:match("^auto:(%-?%d+):(%-?%d+)$")
	x, z = tonumber(x), tonumber(z)
	if not x or not z or not integer(x) or not integer(z) then return nil end
	if settlement_id({cell = {x = x, z = z}}) ~= id then return nil end
	return {x = x, z = z}
end

-- "ok" for a complete record with valid published data, otherwise the
-- reason it is not a usable destination.
local function classify(rec)
	if rec.state ~= "complete" then return "incomplete" end
	if rec.published_invalid then return "invalid" end
	if rec.published == nil then return "unsupported" end
	return "ok"
end

local function shape(rec)
	local p = rec.published
	local out = {id = settlement_id(rec), state = "complete", town_type = rec.town_type,
		center = {x = rec.center.x, y = rec.center.y, z = rec.center.z},
		reservation = {min = {x = rec.envelope.min.x, y = rec.envelope.min.y, z = rec.envelope.min.z},
			max = {x = rec.envelope.max.x, y = rec.envelope.max.y, z = rec.envelope.max.z}},
		core = rect_copy(p.core), structures = {}, exits = {}}
	if rec.site_id then out.site_id = rec.site_id end
	for i, r in ipairs(p.structures) do out.structures[i] = rect_copy(r) end
	local list = {}
	for _, e in ipairs(p.exits) do list[#list + 1] = e end
	table.sort(list, function(a, b) return a.id < b.id end)
	for i, e in ipairs(list) do out.exits[i] = exits_mod.normalize(e) end
	return out
end

local function valid_rect(r)
	if type(r) ~= "table" or not integer(r.x1) or not integer(r.z1) or not integer(r.x2) or not integer(r.z2) then
		return false, "rect needs integer x1, z1, x2 and z2"
	end
	if r.x1 > r.x2 or r.z1 > r.z2 then return false, "rect minimum exceeds its maximum" end
	if r.x2 - r.x1 + 1 > M.MAX_SIDE or r.z2 - r.z1 + 1 > M.MAX_SIDE then
		return false, "rect side exceeds " .. M.MAX_SIDE .. " nodes"
	end
	return true
end

function M.new(deps)
	assert(type(deps) == "table", "towns_api: dependencies are required")
	local api = {version = M.VERSION}

	local function registry()
		local r = deps.registry and deps.registry()
		if not r then return nil, "automatic town records are not loaded" end
		local ok, why = r:is_enabled()
		if not ok then return nil, why or "automatic town records are disabled" end
		return r
	end

	-- true when the registry can answer queries; false, reason otherwise.
	function api.available()
		local r, why = registry()
		if not r then return false, why end
		return true
	end

	-- Completed settlements with valid published data near pos, nearest first.
	function api.settlements(pos, radius)
		if type(pos) ~= "table" or not finite(pos.x) or not finite(pos.z) then
			return nil, "pos needs finite x and z", "invalid_position"
		end
		if not finite(radius) or radius < 0 or radius > M.MAX_RADIUS then
			return nil, "radius must be between 0 and " .. M.MAX_RADIUS, "invalid_radius"
		end
		local reg, why = registry()
		if not reg then return nil, why, "unavailable" end
		local found = {}
		for _, rec in ipairs(reg:all()) do
			if classify(rec) == "ok" then
				local dx, dz = rec.center.x - pos.x, rec.center.z - pos.z
				local d = math.sqrt(dx * dx + dz * dz)
				if d <= radius then found[#found + 1] = {d = d, id = settlement_id(rec), rec = rec} end
			end
		end
		table.sort(found, function(a, b)
			if a.d ~= b.d then return a.d < b.d end
			return a.id < b.id
		end)
		local out = {}
		for i = 1, math.min(#found, M.MAX_SETTLEMENTS) do out[i] = shape(found[i].rec) end
		return out
	end

	-- One settlement by id. On failure: nil, status, message with status one of
	-- "not_found", "incomplete", "unsupported", "invalid", "unavailable".
	function api.settlement(id)
		local cell = parse_id(id)
		if not cell then return nil, "not_found", "unknown settlement id" end
		local reg, why = registry()
		if not reg then return nil, "unavailable", why end
		local rec = reg:lookup(cell)
		if not rec then return nil, "not_found", "no such settlement" end
		local status = classify(rec)
		if status == "incomplete" then return nil, "incomplete", "settlement is " .. rec.state end
		if status == "unsupported" then
			return nil, "unsupported", "settlement has no published exit data"
		end
		if status == "invalid" then return nil, "invalid", "published exit data is malformed" end
		return shape(rec)
	end

	-- Areas Roads must not write into, intersecting rect. Items are
	-- {id, kind, state, rects, y_min, y_max}, sorted by kind then id.
	function api.exclusions(rect)
		local ok, why = valid_rect(rect)
		if not ok then return nil, why, "invalid_rect" end
		local reg, rwhy = registry()
		if not reg then return nil, rwhy, "unavailable" end
		local q = {x1 = rect.x1, z1 = rect.z1, x2 = rect.x2, z2 = rect.z2}
		local items = {}
		for _, rec in ipairs(reg:all()) do
			local rects
			if classify(rec) == "ok" then
				rects = {rect_copy(rec.published.core)}
				for _, r in ipairs(rec.published.structures) do rects[#rects + 1] = rect_copy(r) end
			else
				-- Building, interrupted, unsupported or invalid: the whole reservation.
				rects = {{x1 = rec.envelope.min.x, z1 = rec.envelope.min.z,
					x2 = rec.envelope.max.x, z2 = rec.envelope.max.z}}
			end
			local hit = false
			for _, r in ipairs(rects) do if overlaps(r, q) then hit = true; break end end
			if hit then
				items[#items + 1] = {id = settlement_id(rec), kind = "settlement", state = rec.state,
					rects = rects, y_min = rec.envelope.min.y, y_max = rec.envelope.max.y}
			end
		end
		local session = deps.session and deps.session()
		if session then
			local live, lwhy = session:live(q)
			if not live then return nil, lwhy or "candidate query failed", "unavailable" end
			for _, c in ipairs(live) do
				items[#items + 1] = {id = c.id, kind = "candidate", state = c.state,
					rects = {rect_copy(c.max_rect)}, y_min = -M.WORLD_Y, y_max = M.WORLD_Y}
			end
		end
		table.sort(items, function(a, b)
			if a.kind ~= b.kind then return a.kind < b.kind end
			return a.id < b.id
		end)
		if #items > M.MAX_EXCLUSIONS then
			return nil, "more than " .. M.MAX_EXCLUSIONS .. " exclusions intersect the rect", "too_many"
		end
		return items
	end

	-- nil when no Towns terrain writer is active; otherwise {kind, phase, since}.
	function api.writer()
		local cur = deps.lock and deps.lock.current()
		if not cur then return nil end
		-- Automatic cells own the lock under their site id ("<version>:<cx>:<cz>:..."); a
		-- manual command owns it under the player name, which cannot contain a colon.
		local automatic = type(cur.owner) == "string" and cur.owner:match("^%d+:%-?%d+:") ~= nil
		return {kind = automatic and "automatic" or "manual", phase = cur.phase, since = cur.started}
	end

	return api
end

return M
