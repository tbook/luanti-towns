-- Verified road exits of a completed automatic town (Roads integration, #458).
-- Pure Lua: no Minetest globals at load; the world is reached only through the
-- get_node function passed to verify/build.
--
-- A candidate is a graded outside approach that was written successfully:
--   {source, direction = {x, z}, columns = {{x, z}...}, length, profile}
-- where profile[n + 1] = {y, name, param2} is the road node at step n
-- (0 .. length - 1) in every column. Column c at step n is
-- (c.x + direction.x * n, profile[n + 1].y, c.z + direction.z * n).
-- Planned openings are never exits: only a candidate whose every profile node
-- is read back from the world unchanged is published.
local M = {}

M.FORMAT = 1
M.MAX_EXITS = 32
M.MAX_STRUCTURES = 128
M.MAX_OMITTED = 32
M.MAX_COLUMNS = 4
M.MAX_LENGTH = 16
M.SOURCES = {street = true, wall_gatehouse = true, wall_postern = true, wall_opening = true}

local LABELS = {["1:0"] = "+x", ["-1:0"] = "-x", ["0:1"] = "+z", ["0:-1"] = "-z"}

local function integer(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v == math.floor(v)
end

local function valid_rect(r)
	return type(r) == "table" and integer(r.x1) and integer(r.z1) and integer(r.x2) and integer(r.z2)
		and r.x1 <= r.x2 and r.z1 <= r.z2
end

local function rect_copy(r) return {x1 = r.x1, z1 = r.z1, x2 = r.x2, z2 = r.z2} end

local function rect_less(a, b)
	if a.x1 ~= b.x1 then return a.x1 < b.x1 end
	if a.z1 ~= b.z1 then return a.z1 < b.z1 end
	if a.x2 ~= b.x2 then return a.x2 < b.x2 end
	return a.z2 < b.z2
end

local function direction_label(d)
	return type(d) == "table" and LABELS[tostring(d.x) .. ":" .. tostring(d.z)] or nil
end

-- Columns of a candidate sorted by transverse position (z for x-axis roads,
-- x for z-axis roads) as fresh {x, z} tables. nil when malformed.
local function sorted_columns(columns, d)
	if type(columns) ~= "table" or #columns < 1 or #columns > M.MAX_COLUMNS then return nil end
	local out, seen = {}, {}
	for i, c in ipairs(columns) do
		if type(c) ~= "table" or not integer(c.x) or not integer(c.z) then return nil end
		local k = c.x .. ":" .. c.z
		if seen[k] then return nil end
		seen[k] = true
		out[i] = {x = c.x, z = c.z}
	end
	local function t(c) return d.x ~= 0 and c.z or c.x end
	table.sort(out, function(a, b) return t(a) < t(b) end)
	return out
end

local function valid_step(s)
	return type(s) == "table" and integer(s.y) and type(s.name) == "string" and s.name ~= ""
		and integer(s.param2) and s.param2 >= 0 and s.param2 <= 255
end

-- Normalize one candidate into the published exit shape (fresh tables, sorted
-- columns, stable id). Returns exit | nil, reason.
function M.normalize(c)
	if type(c) ~= "table" then return nil, "candidate is not a table" end
	if not M.SOURCES[c.source] then return nil, "unknown source" end
	local label = direction_label(c.direction)
	if not label then return nil, "invalid direction" end
	local d = {x = c.direction.x, z = c.direction.z}
	local columns = sorted_columns(c.columns, d)
	if not columns then return nil, "invalid columns" end
	if not integer(c.length) or c.length < 1 or c.length > M.MAX_LENGTH then return nil, "invalid length" end
	if type(c.profile) ~= "table" or #c.profile ~= c.length then return nil, "profile length differs from length" end
	local profile = {}
	for n = 1, c.length do
		if not valid_step(c.profile[n]) then return nil, "invalid profile step " .. (n - 1) end
		local s = c.profile[n]
		profile[n] = {y = s.y, name = s.name, param2 = s.param2}
	end
	return {id = label .. ":" .. columns[1].x .. ":" .. columns[1].z, source = c.source, direction = d,
		columns = columns, length = c.length, profile = profile}
end

local function mismatch(e, get_node)
	for _, col in ipairs(e.columns) do
		for n = 0, e.length - 1 do
			local s = e.profile[n + 1]
			local x, z = col.x + e.direction.x * n, col.z + e.direction.z * n
			local name, param2 = get_node(x, s.y, z)
			if name == "ignore" or name == nil then
				return ("node (%d,%d,%d) is not loaded"):format(x, s.y, z)
			end
			if name ~= s.name or (param2 or 0) ~= s.param2 then
				return ("node (%d,%d,%d) is %s/%s, expected %s/%s"):format(x, s.y, z,
					tostring(name), tostring(param2 or 0), s.name, tostring(s.param2))
			end
		end
	end
end

-- Verify candidates against the world. get_node(x, y, z) -> name, param2.
-- Returns exits (sorted by id, at most MAX_EXITS) and omitted ({id?, reason},
-- at most MAX_OMITTED, in a deterministic order). A candidate is kept only
-- when every column and step matches name and param2. A get_node error
-- propagates: the caller publishes no exits.
function M.verify(candidates, get_node)
	local exits, omitted, by_id = {}, {}, {}
	local function omit(id, reason)
		omitted[#omitted + 1] = {id = id, reason = reason}
	end
	for _, c in ipairs(candidates or {}) do
		local e, why = M.normalize(c)
		if not e then omit(nil, why)
		else
			local bad = mismatch(e, get_node)
			if bad then omit(e.id, bad)
			elseif by_id[e.id] then omit(e.id, "duplicate exit id")
			else by_id[e.id] = true; exits[#exits + 1] = e end
		end
	end
	table.sort(exits, function(a, b) return a.id < b.id end)
	while #exits > M.MAX_EXITS do
		local e = table.remove(exits)
		omit(e.id, "more than " .. M.MAX_EXITS .. " exits")
	end
	table.sort(omitted, function(a, b)
		local ai, bi = a.id or "", b.id or ""
		if ai ~= bi then return ai < bi end
		return a.reason < b.reason
	end)
	while #omitted > M.MAX_OMITTED do omitted[#omitted] = nil end
	return exits, omitted
end

-- Town core: the plan bounds widened by the wall line (one node).
function M.core_rect(bounds)
	if type(bounds) ~= "table" then return nil end
	local r = {x1 = bounds.x1 - 1, z1 = bounds.z1 - 1, x2 = bounds.x2 + 1, z2 = bounds.z2 + 1}
	return valid_rect(r) and r or nil
end

local function contains(outer, inner)
	return inner.x1 >= outer.x1 and inner.x2 <= outer.x2 and inner.z1 >= outer.z1 and inner.z2 <= outer.z2
end

-- Footprints of everything written beyond the core (outskirts structures and
-- terraform boxes, wall features). boxes hold {x1,z1,x2,z2} rects or
-- {min, max} boxes. Rects inside the core or malformed are dropped; the rest
-- are sorted and de-duplicated. Beyond MAX_STRUCTURES they collapse to their
-- union, which only ever protects more.
function M.structure_rects(boxes, core)
	local rects, seen = {}, {}
	for _, b in ipairs(boxes or {}) do
		local r
		if type(b) == "table" and b.min and b.max then
			r = {x1 = b.min.x, z1 = b.min.z, x2 = b.max.x, z2 = b.max.z}
		elseif type(b) == "table" then
			r = b
		end
		if valid_rect(r) and not (core and contains(core, r)) then
			local k = r.x1 .. ":" .. r.z1 .. ":" .. r.x2 .. ":" .. r.z2
			if not seen[k] then seen[k] = true; rects[#rects + 1] = rect_copy(r) end
		end
	end
	table.sort(rects, rect_less)
	if #rects > M.MAX_STRUCTURES then
		local u = rect_copy(rects[1])
		for _, r in ipairs(rects) do
			u.x1, u.z1 = math.min(u.x1, r.x1), math.min(u.z1, r.z1)
			u.x2, u.z2 = math.max(u.x2, r.x2), math.max(u.z2, r.z2)
		end
		rects = {u}
	end
	return rects
end

-- The published record of a completed town: {format, core, structures, exits,
-- omitted}. candidates are verified with get_node. Errors propagate.
function M.build(args, get_node)
	local core = assert(M.core_rect(args.bounds), "invalid town bounds")
	local exits, omitted = M.verify(args.candidates, get_node)
	return {format = M.FORMAT, core = core, structures = M.structure_rects(args.boxes, core),
		exits = exits, omitted = omitted}
end

-- A published record with no exits; used when verification could not run.
function M.without_exits(args, reason)
	local core = assert(M.core_rect(args.bounds), "invalid town bounds")
	return {format = M.FORMAT, core = core, structures = M.structure_rects(args.boxes, core),
		exits = {}, omitted = {{reason = reason}}}
end

-- Structural validation of a published record (as stored or about to be
-- stored). Returns true | false, reason.
function M.valid_published(p)
	if type(p) ~= "table" then return false, "published is not a table" end
	if p.format ~= M.FORMAT then return false, "unsupported published format" end
	if not valid_rect(p.core) then return false, "invalid core rect" end
	if type(p.structures) ~= "table" or #p.structures > M.MAX_STRUCTURES then
		return false, "invalid structures"
	end
	for _, r in ipairs(p.structures) do
		if not valid_rect(r) then return false, "invalid structure rect" end
	end
	if type(p.exits) ~= "table" or #p.exits > M.MAX_EXITS then return false, "invalid exits" end
	local ids = {}
	for _, e in ipairs(p.exits) do
		local n, why = M.normalize(e)
		if not n then return false, "invalid exit: " .. why end
		if n.id ~= e.id then return false, "exit id does not match its columns" end
		if ids[e.id] then return false, "duplicate exit id" end
		ids[e.id] = true
	end
	if type(p.omitted) ~= "table" or #p.omitted > M.MAX_OMITTED then return false, "invalid omitted" end
	for _, o in ipairs(p.omitted) do
		if type(o) ~= "table" or type(o.reason) ~= "string" or (o.id ~= nil and type(o.id) ~= "string") then
			return false, "invalid omitted entry"
		end
	end
	return true
end

-- Deep copy of a valid published record (fresh tables only).
function M.copy_published(p)
	local out = {format = p.format, core = rect_copy(p.core), structures = {}, exits = {}, omitted = {}}
	for i, r in ipairs(p.structures) do out.structures[i] = rect_copy(r) end
	for i, e in ipairs(p.exits) do out.exits[i] = M.normalize(e) end
	for i, o in ipairs(p.omitted) do out.omitted[i] = {id = o.id, reason = o.reason} end
	return out
end

return M
