-- Accepted automatic-town persistence and developer lookup (#399).
local eq = ...
	local records_mod = dofile("src/auto_records.lua")
	local command = dofile("src/auto_records_command.lua")
	local function clone(v)
		if type(v) ~= "table" then return v end
		local out = {}
		for k, x in pairs(v) do out[k] = clone(x) end
		return out
	end
	local function literal(v)
		if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
		if type(v) == "string" then return string.format("%q", v) end
		local fields = {}
		for k, x in pairs(v) do
			fields[#fields + 1] = "[" .. literal(k) .. "]=" .. literal(x)
		end
		table.sort(fields)
		return "{" .. table.concat(fields, ",") .. "}"
	end
	local function serializer(c)
		return records_mod.core_serializers({
			serialize = function(v) return literal(v) end,
			deserialize = function(s, safe)
				eq(safe, true, "engine deserialize requests safe mode")
				local chunk, err = loadstring("return " .. s)
				if not chunk then error(err) end
				return chunk()
			end,
		})
	end
	local function store(initial)
		local values = initial or {}
		return values, {
			get = function(k) return values[k] end,
			set = function(k, v)
				if values.fail then error("disk full") end
				values[k] = v
			end,
		}
	end
	local function new_registry(s)
		local serialize, deserialize = serializer()
		return records_mod.new({store = s, serialize = serialize, deserialize = deserialize})
	end
	local function record(cx, cz, version, seed)
		return {cell = {x = cx, z = cz}, version = version or 1, seed = seed or 41,
			town_type = "medieval", center = {x = cx * 1024 + 500, y = 22, z = cz * 1024 + 500},
			envelope = {min = {x = cx * 1024 + 400, y = -20, z = cz * 1024 + 400},
				max = {x = cx * 1024 + 600, y = 100, z = cz * 1024 + 600}}, state = "building"}
	end

	local backing, s = store()
	local reg = new_registry(s)
	local first = record(0, 0)
	local ok = reg:begin(first)
	eq(ok, true, "begin persists an accepted town")
	eq(reg:lookup({x = 0, z = 0}).state, "building", "begin record visible")
	local reloaded = new_registry(s)
	eq(reloaded:lookup({x = 0, z = 0}).seed, 41, "record survives serialization and reload")
	eq(reloaded:lookup({x = 0, z = 0}).state, "interrupted", "startup converts building to interrupted")
	eq(backing["towns.auto_records.v1"] ~= nil, true, "startup transition persisted")

	local complete = record(1, 0, 1, 42)
	complete.state = "complete"
	eq(reg:begin(complete), true, "begin normalizes accepted state to building")
	eq(reg:update({x = 1, z = 0}, "complete"), true, "terminal update to complete succeeds")
	eq(reg:lookup({x = 1, z = 0}).state, "complete", "complete record retained")
	eq(reg:update({x = 1, z = 0}, "interrupted"), false, "terminal record cannot change state")
	eq(reg:update({x = 0, z = 0}, "interrupted"), true, "interrupted terminal update succeeds")
	eq(reg:lookup({x = 0, z = 0}).state, "interrupted", "interrupted record retained")
	local v2 = record(1, 0, 2, 99)
	local duplicate = reg:begin(v2)
	eq(duplicate, false, "accepted cell suppresses descriptor from a later version")
	eq(reg:lookup({x = 1, z = 0}).version, 1, "stored version identity remains unchanged")
	local overlap = record(7, 7, 1, 100)
	overlap.envelope = clone(reg:lookup({x = 1, z = 0}).envelope)
	local overlap_ok = reg:begin(overlap)
	eq(overlap_ok, false, "accepted envelope suppresses a descriptor from another cell")

	local failed_values, failed_store = store()
	failed_values.fail = true
	local failed_registry = new_registry(failed_store)
	local wrote = false
	local began = failed_registry:begin(record(5, 4))
	if began then wrote = true end -- the caller may write only after successful begin
	eq(began, false, "storage failure rejects begin")
	eq(wrote, false, "storage failure prevents first town write")
	eq(failed_registry:all()[1], nil, "failed record is not held as accepted")

	local malformed_store = {get = function() return "broken" end, set = function() error("must preserve malformed bytes") end}
	local bad = records_mod.new({store = malformed_store, serialize = function() return "" end,
		deserialize = function() error("bad payload") end})
	local enabled = bad:is_enabled()
	eq(enabled, false, "malformed records disable automatic processing")
	eq(bad.disabled ~= nil, true, "malformed data reports a reason")
	eq(bad:begin(record(8, 8)), false, "disabled registry cannot accept records")
	local bad_lookup, _, bad_code = bad:lookup({x = 8, z = 8})
	eq(bad_lookup, nil, "disabled registry cannot claim a cell is empty")
	eq(bad_code, "disabled", "disabled lookup is explicit")

	local _, tie_store = store()
	local ties = new_registry(tie_store)
	local left = record(-1, 0, 1, 5)
	left.center = {x = -10, y = 22, z = 0}
	left.envelope = {min = {x = -11, y = 21, z = -1}, max = {x = -9, y = 23, z = 1}}
	eq(ties:begin(left), true, "tie fixture first record")
	local other = record(0, -1, 1, 6)
	other.center = {x = 10, y = 22, z = 0}
	other.envelope = {min = {x = 9, y = 21, z = -1}, max = {x = 11, y = 23, z = 1}}
	eq(ties:begin(other), true, "tie fixture second record")
	local nearest = ties:nearest({x = 0, y = 500, z = 0})
	eq(nearest.cell.z, -1, "nearest tie uses z then x deterministic ordering")
	local none = new_registry(select(2, store()))
	eq(none:all()[1], nil, "declined/rejected inspection creates no persisted record")
	eq(command.message(none, {x = 0, y = 0, z = 0}), "No accepted towns have been recorded.", "lookup handles no records")
	eq(command.message(ties, {x = 0, y = 0, z = 0}):find("status=building", 1, true) ~= nil,
		true, "developer lookup reports status and town details")
	eq(command.message(ties, {x = "bad", y = 0, z = 0}):find("Could not look up", 1, true) ~= nil,
		true, "developer lookup handles invalid position")

	local registered
	local fake_core = {
		register_chatcommand = function(name, def) registered = {name = name, def = def} end,
		get_player_by_name = function(name) if name == "online" then return {get_pos = function() return {x = 0, y = 22, z = 0} end} end end,
	}
	command.register(fake_core, ties)
	eq(registered.name, "towns_nearest", "developer lookup command registered")
	local success, message = registered.def.func("offline", "")
	eq(success, false, "offline caller handled cleanly")
	eq(message:find("online", 1, true) ~= nil, true, "offline caller gets a clear message")
	local online = registered.def.func("online", "")
	eq(online, true, "online server caller can use lookup")
