-- Probe core.get_spawn_level as an ocean pre-screen (issue 448).
-- Runs in a disposable world. Reads spawn_level_job.json from the world
-- directory, then:
--   1. calls get_spawn_level on every sample point from a core.after timer
--      callback (main thread), timing each call (best of REPEATS);
--   2. calls it from on_generated (emerge thread) for the first chunks;
--   3. emerges each sample column and reads the generated column as engine
--      ground truth (water above ground means ocean);
--   4. writes spawn_level_probe.json and shuts the server down.
local wp = core.get_worldpath()
local job = assert(core.parse_json(assert(io.open(wp .. '/spawn_level_job.json')):read('*a')))

local REPEATS = 5
local ONGEN_CHUNKS = 40
local PLANT = {'leaves', 'tree', 'log', 'flower', 'grass', 'fern', 'vine', 'mushroom',
	'sapling', 'deadbush', 'cactus', 'sugar_cane', 'bamboo', 'kelp', 'seagrass', 'coral'}

-- Node classes for the column truth. 'ice' sits on water in frozen seas and is
-- left out of the ground so that a frozen ocean still reads as ocean.
local function classify(name)
	if name == nil or name == 'ignore' then return 'unloaded' end
	if name == 'air' then return 'air' end
	if name:find('water', 1, true) then return 'water' end
	if name:find('ice', 1, true) then return 'ice' end
	for _, w in ipairs(PLANT) do
		if name:find(w, 1, true) then return 'plant' end
	end
	return 'solid'
end

local function read_column(x, z)
	local water_top, ground_y, ground_name, unloaded = nil, nil, nil, false
	for y = job.y_max, job.y_min, -1 do
		local node = core.get_node_or_nil({x = x, y = y, z = z})
		local name = node and node.name or nil
		local class = classify(name)
		if class == 'unloaded' then unloaded = true end
		if class == 'water' and water_top == nil then water_top = y end
		if class == 'solid' and ground_y == nil then ground_y, ground_name = y, name end
	end
	local ocean = water_top ~= nil and (ground_y == nil or water_top > ground_y)
	return {
		ground_y = ground_y, ground_name = ground_name, water_top = water_top,
		depth = (ocean and ground_y) and (water_top - ground_y) or nil,
		class = unloaded and 'unloaded' or (ocean and 'ocean') or (ground_y and 'land') or 'none',
	}
end

-- Calls get_spawn_level REPEATS times. Returns the first value, the best
-- (smallest) call time in microseconds, and whether repeats agreed.
local function time_level(x, z)
	local value, best, consistent = nil, nil, true
	for i = 1, REPEATS do
		local t0 = core.get_us_time()
		local ok, v = pcall(core.get_spawn_level, x, z)
		local dt = core.get_us_time() - t0
		if not ok then return {error = tostring(v)} end
		if i == 1 then value = v
		elseif v ~= value then consistent = false end
		if best == nil or dt < best then best = dt end
	end
	return {level = value, us = best, consistent = consistent}
end

local function sample_points(site)
	local pts = {}
	for _, dx in ipairs(job.offsets) do
		for _, dz in ipairs(job.offsets) do
			pts[#pts + 1] = {x = site.cx + dx, z = site.cz + dz}
		end
	end
	return pts
end

local ongen = {chunks = 0, calls = 0, errors = 0, us_total = 0, samples = {}}
core.register_on_generated(function(minp, maxp)
	ongen.chunks = ongen.chunks + 1
	if ongen.chunks > ONGEN_CHUNKS then return end
	local cx, cz = math.floor((minp.x + maxp.x) / 2), math.floor((minp.z + maxp.z) / 2)
	for _, p in ipairs({{cx, cz}, {minp.x, minp.z}, {maxp.x, maxp.z}}) do
		local t0 = core.get_us_time()
		local ok, v = pcall(core.get_spawn_level, p[1], p[2])
		local dt = core.get_us_time() - t0
		ongen.calls = ongen.calls + 1
		ongen.us_total = ongen.us_total + dt
		if not ok then ongen.errors = ongen.errors + 1 end
		if #ongen.samples < 6 then
			ongen.samples[#ongen.samples + 1] = {x = p[1], z = p[2], ok = ok,
				level = ok and v or nil, error = (not ok) and tostring(v) or nil, us = dt}
		end
	end
end)

local function write_json(path, value)
	local f = assert(io.open(path, 'w')); f:write(assert(core.write_json(value, true))); f:close()
end

local function finish(results, cols, emerge_errors)
	for _, c in ipairs(cols) do
		c.point.truth = read_column(c.point.x, c.point.z)
	end
	results.ongen = ongen
	results.ongen.us_avg = ongen.calls > 0 and ongen.us_total / ongen.calls or nil
	results.emerge_errors = emerge_errors
	results.engine_version = core.get_version and core.get_version() or nil
	write_json(wp .. '/spawn_level_probe.json', results)
	core.request_shutdown('spawn level probe done', false, 0)
end

local function run()
	local results = {seed = job.seed, offsets = job.offsets, sites = {}}
	-- Per-call cost: one point called BATCH times, since a single call is below
	-- the resolution of core.get_us_time.
	local BATCH = 10000
	local t0 = core.get_us_time()
	for _ = 1, BATCH do pcall(core.get_spawn_level, job.sites[1].cx, job.sites[1].cz) end
	local total = core.get_us_time() - t0
	results.batch = {calls = BATCH, total_us = total, per_call_us = total / BATCH}
	local cols = {}
	for _, site in ipairs(job.sites) do
		local s = {label = site.label, id = site.id, group = site.group, outcome = site.outcome,
			cx = site.cx, cz = site.cz, points = {}}
		for _, p in ipairs(sample_points(site)) do
			local r = time_level(p.x, p.z)
			r.x, r.z = p.x, p.z
			s.points[#s.points + 1] = r
			cols[#cols + 1] = {point = r}
		end
		results.sites[#results.sites + 1] = s
	end

	-- Engine ground truth: emerge each sample column in this disposable world.
	local pending, emerge_errors = #cols, 0
	if pending == 0 then return finish(results, cols, 0) end
	for _, c in ipairs(cols) do
		local x, z = c.point.x, c.point.z
		core.emerge_area({x = x, y = job.y_min, z = z}, {x = x, y = job.y_max, z = z},
			function(_, action, remaining)
				if action == core.EMERGE_CANCELLED or action == core.EMERGE_ERRORED then
					emerge_errors = emerge_errors + 1
				end
				if remaining == 0 then
					pending = pending - 1
					if pending == 0 then core.after(0, function() finish(results, cols, emerge_errors) end) end
				end
			end)
	end
end

core.register_on_mods_loaded(function() core.after(1, run) end)
