-- Persistent records for accepted automatic-town sites (#399).
-- Pure registry with an injected key/value store and serializer. It does not
-- inspect terrain or start construction. Call begin immediately before the
-- first permitted write; failure to save must prevent that write.

local M = {}
local KEY = "towns.auto_records.v1"
local SEED_LIMIT = 2 ^ 30 - 1
local Registry = {}
Registry.__index = Registry

local function integer(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v == math.floor(v)
end

local function valid_point(p, three)
	if type(p) ~= "table" or not integer(p.x) or not integer(p.z) then return false end
	return not three or integer(p.y)
end

local function valid_cell(c)
	return type(c) == "table" and integer(c.x) and integer(c.z)
end

local function cell_key(c)
	return c.x .. ":" .. c.z
end

local function overlaps(a, b)
	return a.min.x <= b.max.x and b.min.x <= a.max.x
		and a.min.y <= b.max.y and b.min.y <= a.max.y
		and a.min.z <= b.max.z and b.min.z <= a.max.z
end

local function copy(r)
	return {cell = {x = r.cell.x, z = r.cell.z}, version = r.version, seed = r.seed,
		town_type = r.town_type, center = {x = r.center.x, y = r.center.y, z = r.center.z},
		envelope = {min = {x = r.envelope.min.x, y = r.envelope.min.y, z = r.envelope.min.z},
			max = {x = r.envelope.max.x, y = r.envelope.max.y, z = r.envelope.max.z}}, state = r.state}
end

local function valid_record(r)
	if type(r) ~= "table" or not valid_cell(r.cell) or not integer(r.version) or r.version < 1
		or not integer(r.seed) or r.seed < 1 or r.seed > SEED_LIMIT
		or (r.town_type ~= "medieval" and r.town_type ~= "roman")
		or not valid_point(r.center, true) or type(r.envelope) ~= "table"
		or not valid_point(r.envelope.min, true) or not valid_point(r.envelope.max, true)
		or r.envelope.min.x > r.envelope.max.x or r.envelope.min.y > r.envelope.max.y
		or r.envelope.min.z > r.envelope.max.z
		or r.center.x < r.envelope.min.x or r.center.x > r.envelope.max.x
		or r.center.y < r.envelope.min.y or r.center.y > r.envelope.max.y
		or r.center.z < r.envelope.min.z or r.center.z > r.envelope.max.z
		or (r.state ~= "building" and r.state ~= "complete" and r.state ~= "interrupted") then return false end
	return true
end

local function valid_records(records)
	if type(records) ~= "table" then return false end
	for k, r in pairs(records) do
		if type(k) ~= "string" or not valid_record(r) or k ~= cell_key(r.cell) then return false end
	end
	return true
end

local function persist(self, records)
	local ok, encoded = pcall(self.serialize, records)
	if not ok or type(encoded) ~= "string" or encoded == "" then
		return false, "could not serialize automatic town records: " .. tostring(encoded)
	end
	local saved, err = pcall(self.store.set, KEY, encoded)
	if not saved or err == false then return false, "could not save automatic town records: " .. tostring(err) end
	return true
end

function M.new(opts)
	if type(opts) ~= "table" or type(opts.store) ~= "table" or type(opts.store.get) ~= "function"
		or type(opts.store.set) ~= "function" or type(opts.serialize) ~= "function"
		or type(opts.deserialize) ~= "function" then
		return nil, "store, serialize and deserialize functions are required", "invalid_options"
	end
	local self = setmetatable({store = opts.store, serialize = opts.serialize,
		deserialize = opts.deserialize, log = opts.log or function() end, records = {}, disabled = false}, Registry)
	local ok, raw = pcall(opts.store.get, KEY)
	if not ok then
		self.disabled = "could not read automatic town records: " .. tostring(raw)
	elseif raw ~= nil and raw ~= "" then
		local decoded, records = pcall(opts.deserialize, raw)
		if not decoded or not valid_records(records) then
			self.disabled = "malformed automatic town records; automatic processing disabled"
		else
			self.records = records
		end
	end
	if not self.disabled then
		local changed = false
		for _, r in pairs(self.records) do
			if r.state == "building" then r.state, changed = "interrupted", true end
		end
		if changed then
			local saved, why = persist(self, self.records)
			if not saved then self.disabled = why end
		end
	end
	if self.disabled then pcall(self.log, "error", "towns: " .. self.disabled) end
	return self
end

function Registry:is_enabled()
	return not self.disabled, self.disabled
end

function Registry:lookup(cell)
	if self.disabled then return nil, self.disabled, "disabled" end
	if not valid_cell(cell) then return nil, "cell must have integer x and z", "invalid_cell" end
	local r = self.records[cell_key(cell)]
	return r and copy(r) or nil
end

function Registry:all()
	local out = {}
	for _, r in pairs(self.records) do out[#out + 1] = copy(r) end
	table.sort(out, function(a, b)
		if a.cell.z ~= b.cell.z then return a.cell.z < b.cell.z end
		if a.cell.x ~= b.cell.x then return a.cell.x < b.cell.x end
		return a.version < b.version
	end)
	return out
end

function Registry:begin(record)
	if self.disabled then return false, self.disabled, "disabled" end
	if type(record) ~= "table" or not valid_record(record) then
		return false, "invalid automatic town record", "invalid_record"
	end
	local r = copy(record)
	r.state = "building"
	if not valid_record(r) then return false, "invalid automatic town record", "invalid_record" end
	local k = cell_key(r.cell)
	if self.records[k] then return false, "cell already has an accepted town record", "already_accepted" end
	for _, existing in pairs(self.records) do
		if overlaps(existing.envelope, r.envelope) then
			return false, "envelope overlaps an already accepted town", "already_accepted"
		end
	end
	local updated = {}
	for old_key, old in pairs(self.records) do updated[old_key] = old end
	updated[k] = r
	local ok, why = persist(self, updated)
	if not ok then return false, why, "store_failed" end
	self.records = updated
	return true, copy(r)
end

function Registry:update(cell, state)
	if self.disabled then return false, self.disabled, "disabled" end
	if not valid_cell(cell) then return false, "cell must have integer x and z", "invalid_cell" end
	if state ~= "complete" and state ~= "interrupted" then
		return false, "terminal state must be complete or interrupted", "invalid_state"
	end
	local k, old = cell_key(cell), self.records[cell_key(cell)]
	if not old then return false, "accepted town record not found", "not_found" end
	if old.state == state then return true, copy(old) end
	if old.state ~= "building" then return false, "terminal town record cannot change state", "terminal_state" end
	local updated = {}
	for old_key, r in pairs(self.records) do updated[old_key] = r end
	local next_record = copy(old)
	next_record.state = state
	updated[k] = next_record
	local ok, why = persist(self, updated)
	if not ok then return false, why, "store_failed" end
	self.records = updated
	return true, copy(next_record)
end

function Registry:nearest(pos)
	if self.disabled then return nil, self.disabled, "disabled" end
	if not valid_point(pos, true) then return nil, "position must have integer x, y and z", "invalid_position" end
	local best, best_d
	for _, r in pairs(self.records) do
		local dx, dz = pos.x - r.center.x, pos.z - r.center.z
		local d = dx * dx + dz * dz
		if not best or d < best_d or (d == best_d and (r.cell.z < best.cell.z
			or (r.cell.z == best.cell.z and r.cell.x < best.cell.x))) then best, best_d = r, d end
	end
	return best and copy(best) or nil, best_d and math.sqrt(best_d) or nil
end

function M.core_store(storage)
	return {get = function(key) local value = storage:get_string(key); return value ~= "" and value or nil end,
		set = function(key, value) storage:set_string(key, value) end}
end

function M.core_serializers(c)
	return function(value) return c.serialize(value) end,
		function(value) return c.deserialize(value, true) end
end

return M
