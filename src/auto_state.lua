-- Automatic town session state (issue #395): freshness and activation, in memory only.
-- Pure Lua: no Minetest globals, no world access, no clock, no random state. Engine facts
-- (chunk alignment, which callbacks are eligible, the heightmap copy) come from the injected
-- adapter, and site lookup comes from the injected lookup function. Nothing here loads,
-- locks, builds or persists anything.
--
-- Facts used (docs/automatic_towns_probe_results.md):
--   A6  engine chunk minp = -32 + 80k on every axis, size 80 (auto_bounds CHUNK_ORIGIN, CHUNKSIZE).
--   A8  surface identification from heights: valid when minp.y < h < maxp.y; h == maxp.y is
--       clipped (not usable ground); h == minp.y is ambiguous; no entry or |h| >= 30000 is a
--       sentinel. Invalid heights never authorize anything.
--   A9  the centre ground is copied only from the centre chunk's own on_generated event.
--   A1, A3, A4  a generated-chunk record exists for every generated chunk; chunks loaded from
--       memory or disk produce no record.
--
-- API: local auto_state = dofile("src/auto_state.lua")
--   session, reason, code = auto_state.new(opts)
--     opts.lookup(rect)       -> list of site descriptors | nil, reason, code. rect is inclusive
--                                and absolute (auto_sites.lookup bound to the world seed).
--     opts.adapter            { origin, size, accepts(event) }
--                                origin, size: engine chunk alignment (A6). accepts(event): engine
--                                eligibility (overworld, not singlenode). Other events are ignored.
--     opts.footprint          rect relative to the site centre: the urban footprint whose valid
--                                centre heights are retained (auto_bounds.PLAN_EXTENT).
--     opts.accepted(desc)     optional: true when the registry already holds an accepted record
--                                for the site. Such a site is terminal and never activates.
--
--   actions, reason, code = session:on_generated(event)
--     event = { minp = {x,y,z}, maxp = {x,y,z}, heights = nil | {[z] = {[x] = h}} }
--       minp and maxp are the exact callback chunk bounds (inclusive). heights is a copy made by
--       the adapter inside the callback, in absolute coordinates; it holds no callback-local
--       objects. Malformed or misaligned events return nil, reason, code and change nothing.
--     actions is a list: {kind = "activate", site = descriptor copy}. An activation is emitted
--       at most once per site, by the first valid overworld surface event touching the site's
--       activation rect. Recording emits nothing else.
--
--   session:covers(id, box) -> boolean, reason
--     box = {min = {x,y,z}, max = {x,y,z}} inclusive. True only when the box lies inside the
--       site's maximum horizontal envelope and every engine chunk it touches was recorded for
--       this site. Partial coverage, padding, unrecorded chunks and inactive sites are false.
--   session:decline(id) -> state          idempotent; terminal ("declined"), frees the set.
--   session:finish(id)  -> state | nil, reason, code
--       idempotent for "complete"; only an inspecting site can finish. Frees the set.
--   session:state(id)      -> "contacted" | "inspecting" | "complete" | "declined" | "accepted" | nil
--   session:center(id)     -> copy { chunk = {minp, maxp}, values, valid, clipped, ambiguous,
--                             sentinel } | nil. values are the valid centre-chunk heights in the
--                             footprint, for the loader's median. Retained once, from the first
--                             event with valid centre ground; a sky or underground event does not
--                             retain it.
--   session:descriptor(id) -> copy of the site descriptor while contacted or inspecting | nil
--
--   auto_state.classify(h, minp_y, maxp_y) -> "valid" | "clipped" | "ambiguous" | "sentinel"
--
-- Terminal sites (complete, declined, accepted) ignore later callbacks: no recording, no
-- activation. A new session starts empty, so a restart authorizes nothing from earlier terrain.

local M = {}

M.SENTINEL = 30000   -- |height| at or above this is an invalid sentinel (A8)

local Session = {}
Session.__index = Session

local function copy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = copy(x) end
	return out
end

local function is_int(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v == math.floor(v)
end

local function valid_rect(r)
	return type(r) == "table" and is_int(r.x1) and is_int(r.z1) and is_int(r.x2) and is_int(r.z2)
		and r.x1 <= r.x2 and r.z1 <= r.z2
end

local function valid_box(b)
	if type(b) ~= "table" or type(b.min) ~= "table" or type(b.max) ~= "table" then return false end
	for _, ax in ipairs({"x", "y", "z"}) do
		if not is_int(b.min[ax]) or not is_int(b.max[ax]) or b.min[ax] > b.max[ax] then return false end
	end
	return true
end

local function valid_site(d)
	return type(d) == "table" and type(d.id) == "string" and type(d.center) == "table"
		and is_int(d.center.x) and is_int(d.center.z)
		and valid_rect(d.max_rect) and valid_rect(d.activation_rect)
end

local function touches(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

local function intersect(a, b)
	local r = {x1 = math.max(a.x1, b.x1), z1 = math.max(a.z1, b.z1),
		x2 = math.min(a.x2, b.x2), z2 = math.min(a.z2, b.z2)}
	if r.x1 > r.x2 or r.z1 > r.z2 then return nil end
	return r
end

-- Chunk grid index of one node coordinate. Chunk k covers origin + size*k .. + size - 1.
local function index(v, origin, size)
	return math.floor((v - origin) / size)
end

local function key(cx, cy, cz)
	return cx .. ":" .. cy .. ":" .. cz
end

local function chunk_key(minp, origin, size)
	return key(index(minp.x, origin, size), index(minp.y, origin, size), index(minp.z, origin, size))
end

-- Height classification (A8). The sentinel rule also covers non-numbers and values below the
-- chunk bottom, which are never ground.
function M.classify(h, minp_y, maxp_y)
	if type(h) ~= "number" or h ~= h or math.abs(h) >= M.SENTINEL or h < minp_y then return "sentinel" end
	if h == minp_y then return "ambiguous" end
	if h >= maxp_y then return "clipped" end
	return "valid"
end

-- Counts the classes of the heights over the columns of rect (absolute), and copies the valid
-- ones when wanted. The event's heights are read only here, inside the callback.
local function scan(event, rect, want_values)
	local counts = {valid = 0, clipped = 0, ambiguous = 0, sentinel = 0}
	local values = {}
	if rect then
		local heights = event.heights
		local minp_y, maxp_y = event.minp.y, event.maxp.y
		for z = rect.z1, rect.z2 do
			local row = heights and heights[z]
			for x = rect.x1, rect.x2 do
				local h = row and row[x]
				local cls = M.classify(h, minp_y, maxp_y)
				counts[cls] = counts[cls] + 1
				if cls == "valid" and want_values then values[#values + 1] = h end
			end
		end
	end
	return counts, values
end

local function chunk_rect(event)
	return {x1 = event.minp.x, z1 = event.minp.z, x2 = event.maxp.x, z2 = event.maxp.z}
end

local function check_event(event, origin, size)
	if type(event) ~= "table" or type(event.minp) ~= "table" or type(event.maxp) ~= "table" then
		return false, "event needs minp and maxp", "invalid_event"
	end
	for _, ax in ipairs({"x", "y", "z"}) do
		local a, b = event.minp[ax], event.maxp[ax]
		if not is_int(a) or not is_int(b) then
			return false, "chunk bounds must be integers", "invalid_event"
		end
		if (a - origin) % size ~= 0 or b ~= a + size - 1 then
			return false, "event bounds are not one engine chunk", "misaligned_event"
		end
	end
	return true
end

-- Terminal states drop the set, the centre copy and the descriptor. Only the state remains.
local function terminate(rec, state)
	rec.state = state
	rec.desc = nil
	rec.chunks = nil
	rec.center = nil
end

local function active(rec)
	return rec ~= nil and (rec.state == "contacted" or rec.state == "inspecting")
end

-- Builds one session. Returns nil, reason, code when an option is missing or malformed.
function M.new(opts)
	if type(opts) ~= "table" then return nil, "options are required", "invalid_options" end
	if type(opts.lookup) ~= "function" then
		return nil, "a site lookup function is required", "invalid_options"
	end
	local a = opts.adapter
	if type(a) ~= "table" or not is_int(a.origin) or not is_int(a.size) or a.size <= 0
		or type(a.accepts) ~= "function" then
		return nil, "adapter needs integer origin and size and an accepts function", "invalid_options"
	end
	if not valid_rect(opts.footprint) then
		return nil, "footprint must be an integer rect relative to the centre", "invalid_options"
	end
	if opts.accepted ~= nil and type(opts.accepted) ~= "function" then
		return nil, "accepted must be a function", "invalid_options"
	end
	return setmetatable({
		lookup = opts.lookup,
		origin = a.origin,
		size = a.size,
		accepts = a.accepts,
		footprint = copy(opts.footprint),
		accepted = opts.accepted,
		records = {},
	}, Session)
end

function Session:on_generated(event)
	local ok, why, code = check_event(event, self.origin, self.size)
	if not ok then return nil, why, code end
	if not self.accepts(event) then return {} end

	local chunk = chunk_rect(event)
	local found, lwhy, lcode = self.lookup(chunk)
	if not found then return nil, lwhy, lcode end

	local k = chunk_key(event.minp, self.origin, self.size)
	local surface   -- does this chunk hold valid ground? Scanned at most once per event.
	local actions = {}
	for _, d in ipairs(found) do
		if not valid_site(d) then return nil, "invalid site descriptor", "invalid_site" end
		if touches(d.activation_rect, chunk) then
			local rec = self.records[d.id]
			if rec == nil then
				if self.accepted and self.accepted(d) then
					rec = {state = "accepted"}
				else
					rec = {state = "contacted", desc = copy(d), chunks = {}}
				end
				self.records[d.id] = rec
			end
			if active(rec) then
				rec.chunks[k] = true
				local c = d.center
				if rec.center == nil and c.x >= chunk.x1 and c.x <= chunk.x2
					and c.z >= chunk.z1 and c.z <= chunk.z2 then
					local fp = {x1 = c.x + self.footprint.x1, z1 = c.z + self.footprint.z1,
						x2 = c.x + self.footprint.x2, z2 = c.z + self.footprint.z2}
					local counts, values = scan(event, intersect(chunk, fp), true)
					if counts.valid > 0 then
						rec.center = {
							chunk = {minp = copy(event.minp), maxp = copy(event.maxp)},
							values = values,
							valid = counts.valid,
							clipped = counts.clipped,
							ambiguous = counts.ambiguous,
							sentinel = counts.sentinel,
						}
					end
				end
				if rec.state == "contacted" then
					if surface == nil then
						local counts = scan(event, chunk, false)
						surface = counts.valid > 0
					end
					if surface then
						rec.state = "inspecting"
						actions[#actions + 1] = {kind = "activate", site = copy(rec.desc)}
					end
				end
			end
		end
	end
	return actions
end

function Session:covers(id, box)
	local rec = self.records[id]
	if not active(rec) then return false, "not_active" end
	if not valid_box(box) then return false, "invalid_box" end
	local m = rec.desc.max_rect
	if box.min.x < m.x1 or box.max.x > m.x2 or box.min.z < m.z1 or box.max.z > m.z2 then
		return false, "outside_envelope"
	end
	local o, s = self.origin, self.size
	for cy = index(box.min.y, o, s), index(box.max.y, o, s) do
		for cz = index(box.min.z, o, s), index(box.max.z, o, s) do
			for cx = index(box.min.x, o, s), index(box.max.x, o, s) do
				if not rec.chunks[key(cx, cy, cz)] then return false, "not_fresh" end
			end
		end
	end
	return true
end

function Session:decline(id)
	local rec = self.records[id]
	if rec == nil then
		self.records[id] = {state = "declined"}
		return "declined"
	end
	if active(rec) then terminate(rec, "declined") end
	return rec.state
end

function Session:finish(id)
	local rec = self.records[id]
	if rec ~= nil and rec.state == "complete" then return "complete" end
	if rec ~= nil and rec.state == "inspecting" then
		terminate(rec, "complete")
		return "complete"
	end
	return nil, "site is not inspecting", "not_inspecting"
end

function Session:state(id)
	local rec = self.records[id]
	return rec and rec.state or nil
end

function Session:center(id)
	local rec = self.records[id]
	if rec == nil or rec.center == nil then return nil end
	return copy(rec.center)
end

function Session:descriptor(id)
	local rec = self.records[id]
	if not active(rec) then return nil end
	return copy(rec.desc)
end

return M
