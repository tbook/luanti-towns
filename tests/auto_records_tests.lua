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
	local accepted_envelope = clone(reg:lookup({x = 1, z = 0}).envelope)
	overlap.center = clone(reg:lookup({x = 1, z = 0}).center)
	overlap.envelope = accepted_envelope
	local overlap_ok = reg:begin(overlap)
	eq(overlap_ok, false, "accepted envelope suppresses a descriptor from another cell")
	local vertical_overlap = record(8, 8, 1, 101)
	vertical_overlap.center = {x = accepted_envelope.min.x, y = accepted_envelope.max.y + 20,
		z = accepted_envelope.min.z}
	vertical_overlap.envelope = {
		min = {x = accepted_envelope.min.x, y = vertical_overlap.center.y - 5, z = accepted_envelope.min.z},
		max = {x = accepted_envelope.max.x, y = vertical_overlap.center.y + 5, z = accepted_envelope.max.z},
	}
	eq(reg:begin(vertical_overlap), false, "horizontal reservation overlaps even when envelopes are vertically separate")

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
	fake_core.get_player_by_name = function(name)
		if name == "fractional" then return {get_pos = function() return {x = 0.5, y = 22.25, z = -0.75} end} end
	end
	local fractional = registered.def.func("fractional", "")
	eq(fractional, true, "fractional player coordinates work in nearest lookup")

	-- Published settlement data (#458).
	do
		local function published()
			local profile = {}
			for n = 1, 4 do profile[n] = {y = 22, name = "mcl_core:cobble", param2 = 0} end
			return {format = 1, core = {x1 = 0, z1 = 0, x2 = 10, z2 = 10}, structures = {{x1 = 20, z1 = 20, x2 = 25, z2 = 25}},
				exits = {{id = "+x:12:3", source = "street", direction = {x = 1, z = 0},
					columns = {{x = 12, z = 3}, {x = 12, z = 4}}, length = 4, profile = profile}},
				omitted = {{id = "-x:1:1", reason = "mismatch"}}}
		end
		local function fresh(cx)
			local values, st = store()
			local r = new_registry(st)
			local rec = record(cx, 0)
			rec.site_id = "2:" .. cx .. ":0:0:medieval:41:5:5"
			eq(r:begin(rec), true, "published fixture begin")
			return r, values, st
		end
		local cell = {x = 3, z = 0}
		local r, values, st = fresh(3)
		eq(r:lookup(cell).site_id, "2:3:0:0:medieval:41:5:5", "site id kept")
		eq(r:lookup(cell).published, nil, "building record has no published data")
		-- Published data is rejected unless the record is going complete.
		local ok, _, code = r:update(cell, "interrupted", published())
		eq(ok, false, "published rejected with interrupted")
		eq(code, "invalid_published", "interrupted publish code")
		eq(r:lookup(cell).state, "building", "rejected update changes nothing")
		ok, _, code = r:update(cell, "complete", {format = 1})
		eq(ok, false, "malformed published rejected")
		eq(code, "invalid_published", "malformed publish code")
		eq(r:lookup(cell).state, "building", "malformed publish leaves the record building")
		-- Save failure: memory stays building, nothing published.
		values.fail = true
		ok, _, code = r:update(cell, "complete", published())
		eq(ok, false, "save failure fails the update")
		eq(code, "store_failed", "save failure code")
		eq(r:lookup(cell).state, "building", "save failure leaves the record building")
		eq(r:lookup(cell).published, nil, "save failure publishes nothing")
		values.fail = nil
		-- Success stores published with the state, in one write.
		ok = r:update(cell, "complete", published())
		eq(ok, true, "complete with published succeeds")
		local got = r:lookup(cell)
		eq(got.state, "complete", "state complete")
		eq(got.published.exits[1].id, "+x:12:3", "published exit stored")
		got.published.exits[1].id = "changed"
		eq(r:lookup(cell).published.exits[1].id, "+x:12:3", "lookup returns a copy")
		-- A second update cannot replace it.
		ok, _, code = r:update(cell, "complete", published())
		eq(ok, false, "second publish rejected")
		eq(code, "terminal_state", "second publish code")
		eq(r:update(cell, "complete"), true, "plain repeat update is still idempotent")
		-- Restart: round trip keeps it.
		local reloaded = new_registry(st)
		eq(reloaded:lookup(cell).state, "complete", "complete survives restart")
		eq(reloaded:lookup(cell).published.core.x2, 10, "published survives restart")
		eq(reloaded:lookup(cell).published.omitted[1].reason, "mismatch", "omissions survive restart")
		-- Restart converts building to interrupted and never publishes it.
		local r2, _, st2 = fresh(4)
		local after = new_registry(st2)
		eq(after:lookup({x = 4, z = 0}).state, "interrupted", "building becomes interrupted")
		eq(after:lookup({x = 4, z = 0}).published, nil, "interrupted record has no published data")
		-- A record from before this field existed loads as complete, unpublished.
		local old_values, old_store = store()
		local old = new_registry(old_store)
		old:begin(record(5, 0))
		old:update({x = 5, z = 0}, "complete")
		local old_loaded = new_registry(old_store)
		eq(old_loaded:lookup({x = 5, z = 0}).state, "complete", "old complete record loads")
		eq(old_loaded:lookup({x = 5, z = 0}).published, nil, "old complete record is unpublished")
		eq(old_loaded:lookup({x = 5, z = 0}).published_invalid, nil, "old record is not flagged invalid")
		-- Malformed published data is dropped and flagged; the registry stays enabled.
		local raw = old_values["towns.auto_records.v1"]
		local serialize, deserialize = serializer()
		local table_form = deserialize(raw)
		table_form["5:0"].published = {format = 1, core = "nope"}
		old_values["towns.auto_records.v1"] = serialize(table_form)
		local logged = {}
		local _, d = serializer()
		local tolerant = records_mod.new({store = old_store, serialize = serialize, deserialize = d,
			log = function(level, msg) logged[#logged + 1] = msg end})
		eq(tolerant:is_enabled(), true, "malformed published data does not disable the registry")
		eq(tolerant:lookup({x = 5, z = 0}).state, "complete", "record remains accepted")
		eq(tolerant:lookup({x = 5, z = 0}).published, nil, "malformed published dropped")
		eq(tolerant:lookup({x = 5, z = 0}).published_invalid, true, "malformed published flagged")
		eq(#logged >= 1, true, "malformed published logged")
		-- Published data on a non-complete record is dropped too.
		table_form["5:0"].published = published()
		table_form["5:0"].state = "interrupted"
		old_values["towns.auto_records.v1"] = serialize(table_form)
		local mismatch = records_mod.new({store = old_store, serialize = serialize, deserialize = d})
		eq(mismatch:is_enabled(), true, "published on interrupted keeps the registry enabled")
		eq(mismatch:lookup({x = 5, z = 0}).published, nil, "published on interrupted is dropped")
	end
