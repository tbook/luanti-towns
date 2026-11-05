-- Bounded, center-first loading for one automatic town site (#397).
-- Pure coordinator: site state, exact inspection, envelope calculation and world access are
-- injected. Every emerge is split into deduplicated engine chunks and only one is in flight.
-- Heightmap early rejection is intentionally omitted: A9 does not establish terrain-height
-- semantics that match the exact inspector, so all urban candidates reach inspect_site.
--
-- API: loader = auto_loader.new({
--   session, site_search, env, origin, size, seed, inspect_opts, caps, request_timeout,
--   envelope = function(result, site, reference_y) -> auto_bounds envelope | nil, reason, code
-- })
-- loader:start(site, trigger_event, done) -> true | false, reason
-- done(result, nil) hands an accepted inspection and active freshness session to the builder;
-- done(nil, reason, code) means the site was declined. `env.emerge` accepts exactly one chunk.

local M = {}

local function copy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[k] = copy(x) end
	return out
end

local function is_int(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge and v == math.floor(v)
end

local function valid_pos(p)
	return type(p) == "table" and is_int(p.x) and is_int(p.y) and is_int(p.z)
end

local function valid_box(b)
	if type(b) ~= "table" or not valid_pos(b.min) or not valid_pos(b.max) then return false end
	return b.min.x <= b.max.x and b.min.y <= b.max.y and b.min.z <= b.max.z
end

local function key(x, y, z)
	return x .. ":" .. y .. ":" .. z
end

local function sorted_chunks(box, origin, size, center, ref_y)
	local ix1, iy1, iz1 = math.floor((box.min.x - origin) / size), math.floor((box.min.y - origin) / size),
		math.floor((box.min.z - origin) / size)
	local ix2, iy2, iz2 = math.floor((box.max.x - origin) / size), math.floor((box.max.y - origin) / size),
		math.floor((box.max.z - origin) / size)
	local chunks = {}
	for cz = iz1, iz2 do
		for cy = iy1, iy2 do
			for cx = ix1, ix2 do
				local minp = {x = origin + cx * size, y = origin + cy * size, z = origin + cz * size}
				chunks[#chunks + 1] = {
					key = key(cx, cy, cz), cx = cx, cy = cy, cz = cz,
					min = minp,
					max = {x = minp.x + size - 1, y = minp.y + size - 1, z = minp.z + size - 1},
					dx = (minp.x + (size - 1) / 2) - center.x,
					dz = (minp.z + (size - 1) / 2) - center.z,
					dy = (minp.y + (size - 1) / 2) - ref_y,
				}
			end
		end
	end
	table.sort(chunks, function(a, b)
		local ad, bd = a.dx * a.dx + a.dz * a.dz, b.dx * b.dx + b.dz * b.dz
		if ad ~= bd then return ad < bd end
		if math.abs(a.dy) ~= math.abs(b.dy) then return math.abs(a.dy) < math.abs(b.dy) end
		if a.cz ~= b.cz then return a.cz < b.cz end
		if a.cx ~= b.cx then return a.cx < b.cx end
		return a.cy < b.cy
	end)
	return chunks
end

local function median(values)
	local v = {}
	for i, h in ipairs(values) do v[i] = h end
	table.sort(v)
	if #v == 0 then return nil end
	return v[math.floor((#v + 1) / 2)]
end

local function valid_envelope(e)
	if type(e) ~= "table" or type(e.stages) ~= "table" or not valid_box(e.read) or not valid_box(e.write)
			or not is_int(e.chunks) or e.chunks < 0
			or not is_int(e.snapshot_voxels) or e.snapshot_voxels < 0 then return false end
	for _, s in pairs(e.stages) do
		if type(s) ~= "table" or (s.kind ~= "read" and s.kind ~= "write") then return false end
		if not valid_box(s.box) then return false end
	end
	return true
end

local function with_loader_deadline(opts, seconds)
	local out, previous = {}, 0
	for k, v in pairs(opts) do
		if type(k) == "string" and k:upper() == "EMERGE_TIMEOUT" then
			if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
				previous = math.max(previous, v)
			end
		else
			out[k] = v
		end
	end
	out.emerge_timeout = math.max(previous, seconds)
	return out
end

local function stage_names(stages)
	local names = {}
	for name in pairs(stages) do names[#names + 1] = name end
	table.sort(names)
	return names
end

function M.new(opts)
	if type(opts) ~= "table" then return nil, "options are required", "invalid_options" end
	local state, search, env = opts.session, opts.site_search, opts.env
	if type(state) ~= "table" or type(state.center) ~= "function" or type(state.covers) ~= "function"
		or type(state.state) ~= "function" or type(state.decline) ~= "function" then
		return nil, "session must provide center, covers, state and decline", "invalid_options"
	end
	if type(search) ~= "table" or type(search.inspect_site) ~= "function" then
		return nil, "site_search.inspect_site is required", "invalid_options"
	end
	if type(opts.envelope) ~= "function" then return nil, "an envelope function is required", "invalid_options" end
	if type(env) ~= "table" or type(env.emerge) ~= "function" then
		return nil, "env.emerge is required", "invalid_options"
	end
	local origin, size = opts.origin, opts.size
	if not is_int(origin) or not is_int(size) or size <= 0 then
		return nil, "chunk origin and size must be integers", "invalid_options"
	end
	local caps = opts.caps or {MAX_REQUEST_CHUNKS = 256, MAX_SNAPSHOT_VOXELS = 256 * 80 * 80 * 80}
	if type(caps) ~= "table" or not is_int(caps.MAX_REQUEST_CHUNKS) or caps.MAX_REQUEST_CHUNKS <= 0
			or not is_int(caps.MAX_SNAPSHOT_VOXELS) or caps.MAX_SNAPSHOT_VOXELS <= 0 then
		return nil, "positive chunk and snapshot caps are required", "invalid_options"
	end
	local timeout = opts.request_timeout or 30
	if type(timeout) ~= "number" or timeout ~= timeout or timeout <= 0
			or timeout == math.huge or timeout == -math.huge then
		return nil, "request_timeout must be positive", "invalid_options"
	end
	if timeout > math.huge / (caps.MAX_REQUEST_CHUNKS + 1) then
		return nil, "request_timeout and chunk cap exceed the finite inspector deadline", "invalid_options"
	end
	if type(env.after) ~= "function" then return nil, "env.after is required for bounded requests", "invalid_options" end
	return setmetatable({
		session = state, site_search = search, envelope = opts.envelope, env = env,
		origin = origin, size = size, caps = caps, timeout = timeout,
		seed = opts.seed, inspect_opts = opts.inspect_opts or {}, jobs = {},
	}, {__index = M})
end

-- Load a site's urban terrain, inspect it exactly once, then request the remaining approved
-- stage boxes. `trigger` is the eligible surface-generation callback that activated the site.
-- Completion is done(result, nil) or done(nil, reason, code), exactly once.
function M:start(site, trigger, done)
	if type(site) ~= "table" or type(site.id) ~= "string" or type(site.center) ~= "table"
			or not is_int(site.center.x) or not is_int(site.center.z) then
		error("auto_loader: a valid activated site is required", 2)
	end
	if type(trigger) ~= "table" or not valid_pos(trigger.minp) or not valid_pos(trigger.maxp)
			or type(done) ~= "function" then
		error("auto_loader: trigger bounds and done callback are required", 2)
	end
	if self.jobs[site.id] then return false, "already_started" end
	local state = self.session:state(site.id)
	if state == "declined" or state == "complete" or state == "accepted" then return false, "terminal" end
	if state ~= "inspecting" then return false, "not_inspecting" end
	local job = {id = site.id, site = copy(site), done = done, terminal = false,
		requested = {}, completed = {}, in_flight = false, serial = 0, ref_y = nil}
	self.jobs[site.id] = job

	local function finish(result, reason, code)
		if job.terminal then return end
		job.terminal = true
		job.serial = job.serial + 1 -- invalidate any late emerge callback
		job.in_flight = false
		if not result then
			self.session:decline(job.id)
		end
		local callback = job.done
		-- Keep only a tiny marker for successful inspection handoff (the session remains
		-- inspecting until the builder finishes); declined/failed sites are suppressed by session state.
		self.jobs[job.id] = result and true or nil
		job.done, job.site, job.requested, job.completed = nil, nil, nil, nil
		job.ref_y, job.load_failure = nil, nil
		-- Successful loading is a handoff to the future builder. Keep session freshness alive
		-- until that owner records the eventual build or decline.
		local ok, err = pcall(callback, result, reason, code)
		if not ok and self.env.log then pcall(self.env.log, "error", "auto_loader completion raised: " .. tostring(err)) end
	end

	local function cap_ok(box)
		local ix1, iy1, iz1 = math.floor((box.min.x - self.origin) / self.size),
			math.floor((box.min.y - self.origin) / self.size), math.floor((box.min.z - self.origin) / self.size)
		local ix2, iy2, iz2 = math.floor((box.max.x - self.origin) / self.size),
			math.floor((box.max.y - self.origin) / self.size), math.floor((box.max.z - self.origin) / self.size)
		local area_count = (ix2 - ix1 + 1) * (iy2 - iy1 + 1) * (iz2 - iz1 + 1)
		if area_count > self.caps.MAX_REQUEST_CHUNKS then return false, "chunk_cap" end
		local count = 0
		for _ in pairs(job.requested) do count = count + 1 end
		local added = 0
		for cz = iz1, iz2 do
			for cy = iy1, iy2 do
				for cx = ix1, ix2 do
					if not job.requested[key(cx, cy, cz)] then added = added + 1 end
				end
			end
		end
		local next_count = count + added
		if next_count > self.caps.MAX_REQUEST_CHUNKS then return false, "chunk_cap" end
		if next_count * self.size * self.size * self.size > self.caps.MAX_SNAPSHOT_VOXELS then
			return false, "snapshot_cap"
		end
		for cz = iz1, iz2 do
			for cy = iy1, iy2 do
				for cx = ix1, ix2 do job.requested[key(cx, cy, cz)] = true end
			end
		end
		return true
	end

	local function load_box(box, center, ref_y, cb)
		if job.terminal then return end
		if not valid_box(box) then return cb(false, "invalid_box") end
		local allowed, why = cap_ok(box)
		if not allowed then job.load_failure = why; return cb(false, why) end
		local chunks = sorted_chunks(box, self.origin, self.size, center, ref_y)
		local i, waiting, continuation, pumping = 1, false, nil, false
		local pump
		local function settle(serial, chunk, ok)
			if job.terminal or serial ~= job.serial or not waiting then return end
			waiting = false
			job.in_flight = false
			if ok then job.completed[chunk.key] = true end
			continuation = ok and true or false
			pump()
		end
		pump = function()
			if pumping or job.terminal then return end
			pumping = true
			while not waiting and not job.terminal do
				if continuation ~= nil then
					local good = continuation
					continuation = nil
					if not good then pumping = false; return cb(false, "emerge_failed") end
				end
				while i <= #chunks and job.completed[chunks[i].key] do i = i + 1 end
				if i > #chunks then pumping = false; return cb(true) end
				local c = chunks[i]
				i = i + 1
				job.in_flight, waiting = true, true
				job.serial = job.serial + 1
				local serial = job.serial
				local ok, err = pcall(self.env.emerge, c.min, c.max, function(good)
					settle(serial, c, good == true)
				end)
				if not ok then settle(serial, c, false)
				elseif waiting then
					local timer_ok = pcall(self.env.after, self.timeout, function() settle(serial, c, false) end)
					if not timer_ok then settle(serial, c, false) end
				end
			end
			pumping = false
		end
		pump()
	end

	local function fail(reason, code)
		finish(nil, reason or "Automatic town inspection could not load fresh terrain.", code or "load_failed")
	end

	local center_data = self.session:center(site.id)
	local function inspect_from_center(data)
		if job.terminal then return end
		if type(data) ~= "table" or type(data.values) ~= "table" then
			return fail("The center surface chunk did not provide valid ground.", "center_ground_missing")
		end
		local ref_y = median(data.values)
		if not is_int(ref_y) then return fail("The center surface chunk did not provide valid ground.", "center_ground_missing") end
		job.ref_y = ref_y
		-- An exploration callback has already loaded this generated chunk and the session's
		-- retained center copy proves its freshness. Reuse it without another emerge request.
		if type(data.chunk) == "table" and type(data.chunk.minp) == "table" and valid_pos(data.chunk.minp) then
			local cx = math.floor((data.chunk.minp.x - self.origin) / self.size)
			local cy = math.floor((data.chunk.minp.y - self.origin) / self.size)
			local cz = math.floor((data.chunk.minp.z - self.origin) / self.size)
			job.completed[key(cx, cy, cz)] = true
		end
		local wrapped = {}
		for k, v in pairs(self.env) do wrapped[k] = v end
		wrapped.emerge = function(minp, maxp, cb)
			local box = {min = copy(minp), max = copy(maxp)}
			load_box(box, site.center, ref_y, function(ok, why)
				if not job.terminal then cb(ok, why) end
			end)
		end
		local called = false
		local function inspected(result, reason, details)
			if called or job.terminal then return end
			called = true
			if not result then return fail(reason, job.load_failure or (details and details.reason) or "inspection_failed") end
			result.reference_y = ref_y
			local ok, envelope, why, code = pcall(self.envelope, result, site, ref_y)
			if not ok then return fail("Could not calculate the approved site envelope: " .. tostring(envelope), "envelope_failed") end
			if not valid_envelope(envelope) then return fail(why or "The approved site envelope is invalid.", code or "envelope_failed") end
			if envelope.chunks > self.caps.MAX_REQUEST_CHUNKS
					or envelope.snapshot_voxels > self.caps.MAX_SNAPSHOT_VOXELS then
				return fail("The approved site envelope exceeds the frozen loading caps.", "envelope_cap")
			end
			local names, index = stage_names(envelope.stages), 1
			local function next_stage()
				if job.terminal then return end
				local name = names[index]
				index = index + 1
				if not name then
					for _, n in ipairs(names) do
						local stage = envelope.stages[n]
						if stage.kind == "write" then
							local covered = self.session:covers(site.id, stage.box)
							if not covered then return fail("Possible town writes are not covered by fresh generated chunks.", "not_fresh") end
						end
					end
					result.envelope = copy(envelope)
					result.read_envelope = copy(envelope.read)
					result.write_envelope = copy(envelope.write)
					return finish(result)
				end
				local stage = envelope.stages[name]
				load_box(stage.box, site.center, ref_y, function(good, load_why)
					if not good then return fail("A town envelope chunk could not be loaded.", load_why) end
					next_stage()
				end)
			end
			next_stage()
		end
		-- site_search's own watchdog covers a whole env.emerge call. Since this adapter
		-- serializes mapchunks, bound it by the maximum chunk count times the per-chunk timeout.
		local total_timeout = (self.caps.MAX_REQUEST_CHUNKS + 1) * self.timeout
		local inspect_opts = with_loader_deadline(self.inspect_opts, total_timeout)
		local ok, err = pcall(self.site_search.inspect_site, copy(site.center), ref_y, self.seed,
			inspect_opts, inspected, wrapped)
		if not ok then fail("Exact site inspection failed: " .. tostring(err), "inspection_failed") end
	end

	if center_data then
		inspect_from_center(center_data)
	else
		-- The trigger layer is a bounded vertical hint only; never search above or below it.
		local cx = math.floor((site.center.x - self.origin) / self.size)
		local cz = math.floor((site.center.z - self.origin) / self.size)
		local cy = math.floor((trigger.minp.y - self.origin) / self.size)
		local minp = {x = self.origin + cx * self.size, y = self.origin + cy * self.size,
			z = self.origin + cz * self.size}
		local maxp = {x = minp.x + self.size - 1, y = minp.y + self.size - 1,
			z = minp.z + self.size - 1}
		load_box({min = minp, max = maxp}, site.center, trigger.minp.y, function(ok, why)
			if not ok then return fail("The center surface chunk could not be loaded.", why) end
			inspect_from_center(self.session:center(site.id))
		end)
	end
	return true
end

return M
