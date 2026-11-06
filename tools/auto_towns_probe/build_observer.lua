-- Scratch-only observation around the production coordinator's builder handoff.
-- The map is never emerged by this observer; ignore blocks are reported as blind spots.
local ring = 16
local ignore = core.get_content_id("ignore")
local function pack(vm)
	return table.concat(vm:get_data(), ",", 1, 4096) .. "|" .. table.concat(vm:get_param2_data(), ",", 1, 4096)
end
local function canonical(v)
	if type(v) == "userdata" then
		local ok, value = pcall(function() return v:to_string() end)
		assert(ok and type(value) == "string", "unsupported metadata userdata")
		return "userdata:" .. core.serialize(value)
	end
	if type(v) ~= "table" then return core.serialize(v) end
	local keys, out = {}, {}
	for k in pairs(v) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	for _, k in ipairs(keys) do out[#out + 1] = canonical(k) .. "=" .. canonical(v[k]) end
	return "{" .. table.concat(out, ",") .. "}"
end
local function metadata(lo, hi)
	local out = {}
	for _, p in ipairs(core.find_nodes_with_meta(lo, hi)) do
		out[p.x .. "," .. p.y .. "," .. p.z] = {pos = p, value = canonical(core.get_meta(p):to_table())}
	end
	return out
end
local function snapshot(box)
	local s = {blocks = {}, ignored = 0, ignored_approved = 0, count = 0}
	local lo, hi = {}, {}
	for _, a in ipairs({"x", "y", "z"}) do
		lo[a] = math.floor((box.min[a] - ring) / 16) * 16
		hi[a] = math.floor((box.max[a] + ring) / 16) * 16 + 15
	end
	s.lo, s.hi = lo, hi
	for z = lo.z, hi.z, 16 do for y = lo.y, hi.y, 16 do for x = lo.x, hi.x, 16 do
		local p = {x = x, y = y, z = z}
		local vm = VoxelManip()
		vm:read_from_map(p, {x = x + 15, y = y + 15, z = z + 15})
		local data = vm:get_data()
		local missing = false
		for i = 1, 4096 do if data[i] == ignore then missing = true; break end end
		if missing then
			s.ignored = s.ignored + 1
			if x <= box.max.x and x + 15 >= box.min.x and y <= box.max.y and y + 15 >= box.min.y
				and z <= box.max.z and z + 15 >= box.min.z then s.ignored_approved = s.ignored_approved + 1 end
		else
			s.blocks[#s.blocks + 1] = {p = p, data = core.compress(pack(vm), "deflate")}
		end
		s.count = s.count + 1
	end end end
	s.metadata = metadata(lo, hi)
	return s
end
local function inside(p, b)
	return p.x >= b.min.x and p.x <= b.max.x and p.y >= b.min.y and p.y <= b.max.y
		and p.z >= b.min.z and p.z <= b.max.z
end
local function split(s)
	local ids, p2, bar = {}, {}, s:find("|", 1, true)
	for v in s:sub(1, bar - 1):gmatch("%d+") do ids[#ids + 1] = tonumber(v) end
	for v in s:sub(bar + 1):gmatch("%d+") do p2[#p2 + 1] = tonumber(v) end
	return ids, p2
end
local function compare(s, box)
	local r = {blocks = s.count, ignored_before = s.ignored, ignored_approved = s.ignored_approved, ignored_after = 0,
		changed_nodes = 0, outside_nodes = 0, changed_metadata = 0, outside_metadata = 0,
		window = {min = s.lo, max = s.hi}, approved = box, examples = {}}
	for _, b in ipairs(s.blocks) do
		local p, vm = b.p, VoxelManip()
		vm:read_from_map(p, {x = p.x + 15, y = p.y + 15, z = p.z + 15})
		local current = pack(vm)
		if core.compress(current, "deflate") ~= b.data then
			local old_id, old_p2 = split(core.decompress(b.data, "deflate"))
			local new_id, new_p2 = split(current)
			for i = 1, 4096 do
				if new_id[i] == ignore then r.ignored_after = r.ignored_after + 1 end
				if old_id[i] ~= new_id[i] or old_p2[i] ~= new_p2[i] then
					local j = i - 1
					local q = {x = p.x + j % 16, y = p.y + math.floor(j / 16) % 16, z = p.z + math.floor(j / 256)}
					r.changed_nodes = r.changed_nodes + 1
					if not inside(q, box) then
						r.outside_nodes = r.outside_nodes + 1
						if #r.examples < 10 then r.examples[#r.examples + 1] = q end
					end
				end
			end
		end
	end
	local after = metadata(s.lo, s.hi)
	for k, before in pairs(s.metadata) do
		if not after[k] or after[k].value ~= before.value then
			r.changed_metadata = r.changed_metadata + 1
			if not inside(before.pos, box) then r.outside_metadata = r.outside_metadata + 1 end
		end
		after[k] = nil
	end
	for _, m in pairs(after) do
		r.changed_metadata = r.changed_metadata + 1
		if not inside(m.pos, box) then r.outside_metadata = r.outside_metadata + 1 end
	end
	return r
end
core.register_on_mods_loaded(function()
	local original_inspect = towns.site_search.inspect_site
	towns.site_search.inspect_site = function(center, height, seed, options, done, env)
		return original_inspect(center, height, seed, options, function(result, reason, details)
			core.log("action", "[auto-towns-build-observer] inspection " .. core.write_json({
				center = center, accepted = result ~= nil, reason = reason,
				code = type(details) == "table" and details.reason or nil}, false))
			return done(result, reason, details)
		end, env)
	end
	local phase = core.settings:get("auto_towns_probe_phase") or "1"
	local function records(when)
		local file = assert(io.open(core.get_worldpath() .. "/records-" .. phase .. "-" .. when .. ".json", "w"))
		local all = towns.auto_records:all()
		file:write(#all == 0 and "[]" or core.write_json(all, true)); file:close()
		if when == "end" and core.settings:get_bool("auto_towns_probe_break_guard", false) then
			local status = assert(io.open(core.get_worldpath() .. "/guard-status.json", "w"))
			status:write(core.write_json({disabled = towns.auto_disabled}, true)); status:close()
		end
	end
	core.after(1, function() records("start") end)
	core.register_on_shutdown(function() records("end") end)
	if core.settings:get_bool("auto_towns_probe_break_guard", false) then
		local original_planner = settlements.create_site_plan
		settlements.create_site_plan = function(...) return original_planner(...) end
		core.log("action", "[auto-towns-build-observer] replaced planner after guard installation")
	end
	local original = towns.populated.build
	towns.populated.build = function(result, done, context)
		core.after(0, function()
			local saved_protection, saved_begin, saved_builder, saved_outskirts, omission
			local ok, err = pcall(function()
				local command_check
				if core.settings:get_bool("auto_towns_probe_command_contention", false) then
					local before = towns.generation_lock.current()
					local success, message = core.registered_chatcommands.towns_generate.func("fixture", "roman 42")
					local after = towns.generation_lock.current()
					command_check = {busy_before = before ~= nil, denied = success == false,
						busy_message = type(message) == "string" and message:find("already in progress", 1, true) ~= nil,
						owner_preserved = before ~= nil and after ~= nil and before.owner == after.owner and before.phase == after.phase}
				end
				core.log("action", "[auto-towns-build-observer] starting snapshot")
				local start = core.get_us_time()
				local before = snapshot(result.write_envelope)
				local snapshot_seconds = (core.get_us_time() - start) / 1e6
				core.log("action", "[auto-towns-build-observer] snapshot complete in " .. snapshot_seconds .. " seconds")
				if core.settings:get_bool("auto_towns_probe_reject_protected", false) then
					saved_protection = core.is_protected
					core.is_protected = function()
						core.log("action", "[auto-towns-build-observer] injected protection denial")
						return true
					end
				end
				if core.settings:get_bool("auto_towns_probe_reject_storage", false) then
					saved_begin = towns.auto_records.begin
					towns.auto_records.begin = function()
						core.log("action", "[auto-towns-build-observer] injected record failure")
						return false, "injected record failure"
					end
				end
				if core.settings:get_bool("auto_towns_probe_fail_required", false) then
					saved_builder = towns.builder.build_town
					towns.builder.build_town = function(_, opts)
						local allowed, why = opts.before_write()
						if not allowed then return nil, why, "before_write_denied" end
						core.log("action", "[auto-towns-build-observer] injected required stage failure")
						return nil, "injected required stage failure", "write_failed"
					end
				end
				if core.settings:get_bool("auto_towns_probe_omit_unsafe", false) then
					saved_outskirts = towns.outskirts_build.apply
					towns.outskirts_build.apply = function(out, env, opts)
						if #opts.structures == 0 then
							omission = {fixture_available = false}
							return saved_outskirts(out, env, opts)
						end
						local st = opts.structures[1]
						local id = st.plot
						st.min.x, st.max.x = opts.automatic_context.write_bounds.max.x + 1,
							opts.automatic_context.write_bounds.max.x + 2
						local report, reason, code, extra = saved_outskirts(out, env, opts)
						local skipped, placed = false, false
						for _, s in ipairs(report and report.skipped or {}) do
							if s.plot == id and s.code == "automatic_envelope" then skipped = true end
						end
						for _, s in ipairs(report and report.structures or {}) do
							if s.plot == id then placed = true end
						end
						omission = {fixture_available = true, plot = id, skipped = skipped, placed = placed}
						return report, reason, code, extra
					end
				end
				original(result, function(...)
					if saved_protection then core.is_protected = saved_protection end
					if saved_begin then towns.auto_records.begin = saved_begin end
					if saved_builder then towns.builder.build_town = saved_builder end
					if saved_outskirts then towns.outskirts_build.apply = saved_outskirts end
					local args, count = {...}, select("#", ...)
					core.after(0, function()
						local success, failure = pcall(function()
							core.log("action", "[auto-towns-build-observer] starting diff")
							local t = core.get_us_time()
							local observation = compare(before, result.write_envelope)
							observation.command_contention = command_check
							observation.unsafe_plot = omission
							observation.snapshot_seconds = snapshot_seconds
							observation.diff_seconds = (core.get_us_time() - t) / 1e6
							local file = assert(io.open(core.get_worldpath() .. "/build-observation.json", "w"))
							file:write(core.write_json(observation, true)); file:close()
							core.log("action", "[auto-towns-build-observer] diff complete in " .. observation.diff_seconds .. " seconds")
							done(unpack(args, 1, count))
						end)
						if not success then
							core.log("error", "[auto-towns-build-observer] diff failed: " .. tostring(failure))
							context.callback_failed(failure)
						end
					end)
				end, context)
			end)
			if not ok then
				if saved_protection then core.is_protected = saved_protection end
				if saved_begin then towns.auto_records.begin = saved_begin end
				if saved_builder then towns.builder.build_town = saved_builder end
				if saved_outskirts then towns.outskirts_build.apply = saved_outskirts end
				core.log("error", "[auto-towns-build-observer] snapshot/build failed: " .. tostring(err))
				context.callback_failed(err)
			end
		end)
	end
end)
