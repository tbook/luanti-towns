-- Demonstration of the Roads integration API (#458) against a real, automatically generated
-- settlement. Installed only in a scratch world by tools/roads_api_demo/run.py.
--
-- Flow:
--  1. Pick the cells nearest the origin (auto_sites.lookup) and emerge the chunk holding each
--     candidate centre, one cell at a time, so the production first-touch coordinator starts its
--     cell job. Wait until towns_api.writer() is nil (with a limit).
--  2. For every settlement towns_api.settlements() lists, dump settlement(id) as JSON and re-read
--     each exit column and step with core.get_node, comparing node name and param2 with the profile.
--  3. A Roads-like consumer emerges fresh land beside the first settlement, polls writer() with
--     core.after and logs the timing, then queries exclusions().
--  4. Stop once a flat and a sloped exit were verified, or every cell was tried.
-- Results: <world>/roads-api-demo.json. Exit status is reported through the file only.
local MAX_CELLS = tonumber(core.settings:get("roads_demo_max_cells")) or 10
local CELL_WAIT = tonumber(core.settings:get("roads_demo_cell_wait")) or 240   -- seconds per cell
local OUT = core.get_worldpath() .. "/roads-api-demo.json"
local report = {api_version = towns_api and towns_api.version, cells = {}, settlements = {}, consumer = nil,
	flat_verified = 0, sloped_verified = 0, errors = {}}

local function write_report(status)
	report.status = status
	local f = assert(io.open(OUT, "w"))
	f:write(core.write_json(report, true))
	f:close()
end

local function fail(message)
	report.errors[#report.errors + 1] = message
	core.log("error", "[roads_api_demo] " .. message)
end

if type(towns_api) ~= "table" then
	fail("towns_api is not defined")
	write_report("fail")
	core.request_shutdown("towns_api missing", false, 0)
	return
end

-- auto_bounds loads sibling modules by the current mod name, which is this helper's.
local function as_towns(fn, ...)
	local saved = core.get_current_modname
	core.get_current_modname = function() return "towns" end
	local res = {pcall(fn, ...)}
	core.get_current_modname = saved
	if not res[1] then error(res[2], 0) end
	return unpack(res, 2)
end

local function chunk_of(v) return -32 + 80 * math.floor((v + 32) / 80) end

local function emerge(minp, maxp, callback)
	core.emerge_area(minp, maxp, function(_, _, remaining)
		if remaining == 0 then callback() end
	end)
end

-- Poll writer() until idle or the limit (seconds), logging how long that took.
local function wait_idle(limit, done)
	local started = core.get_us_time()
	local function poll()
		local elapsed = (core.get_us_time() - started) / 1000000
		local w = towns_api.writer()
		if w == nil then return done(true, elapsed) end
		if elapsed >= limit then return done(false, elapsed, w) end
		core.after(1, poll)
	end
	poll()
end

local function node_matches(pos, step)
	local node = core.get_node(pos)
	return node.name == step.name and node.param2 == step.param2, node
end

-- Compare every column/step of an exit with the world.
local function verify_exit(e)
	local result = {id = e.id, source = e.source, length = e.length, columns = #e.columns, mismatches = {}, sloped = false}
	for n = 0, e.length - 1 do
		local step = e.profile[n + 1]
		if step.name ~= "mcl_core:cobble" or step.param2 ~= 0 or step.y ~= e.profile[1].y then result.sloped = true end
		for _, c in ipairs(e.columns) do
			local pos = {x = c.x + e.direction.x * n, y = step.y, z = c.z + e.direction.z * n}
			local ok, node = node_matches(pos, step)
			if not ok then
				result.mismatches[#result.mismatches + 1] = {pos = pos, want = step.name .. "/" .. step.param2,
					have = node.name .. "/" .. node.param2}
			end
		end
	end
	result.ok = #result.mismatches == 0
	return result
end

local function dump_settlements(pos)
	local list, why, code = towns_api.settlements(pos, 1024)
	if not list then fail("settlements failed: " .. tostring(why) .. " " .. tostring(code)); return {} end
	for _, listed in ipairs(list) do
		local seen = false
		for _, s in ipairs(report.settlements) do if s.settlement.id == listed.id then seen = true end end
		if not seen then
			local s, status = towns_api.settlement(listed.id)
			if not s then fail("settlement(" .. listed.id .. ") failed: " .. tostring(status)) else
				local entry = {settlement = s, exits = {}}
				for _, e in ipairs(s.exits) do
					local v = verify_exit(e)
					entry.exits[#entry.exits + 1] = v
					if v.ok then
						if v.sloped then report.sloped_verified = report.sloped_verified + 1
						else report.flat_verified = report.flat_verified + 1 end
					end
				end
				report.settlements[#report.settlements + 1] = entry
			end
		end
	end
	return list
end

-- The Roads-like consumer: emerge fresh land beside the settlement, then wait for Towns.
local function run_consumer(settlement, done)
	local c = settlement.core
	-- Far enough beyond the town (reservation and outskirts) that the land is still ungenerated.
	local x = c.x2 + 400
	local y = core.get_spawn_level(x, settlement.center.z) or settlement.center.y
	local minp = {x = chunk_of(x), y = chunk_of(y), z = chunk_of(settlement.center.z)}
	local maxp = {x = minp.x + 79, y = minp.y + 79, z = minp.z + 79}
	local rect = {x1 = minp.x, z1 = minp.z, x2 = maxp.x, z2 = maxp.z}
	local started = core.get_us_time()
	local consumer = {emerge_rect = rect}
	emerge(minp, maxp, function()
		consumer.emerged_after_s = (core.get_us_time() - started) / 1000000
		consumer.writer_busy_at_callback = towns_api.writer() ~= nil
		consumer.writer_at_callback = towns_api.writer()
		local items = towns_api.exclusions(rect)
		consumer.exclusions_at_callback = items and #items or "error"
		wait_idle(180, function(idle, elapsed, w)
			consumer.idle = idle
			consumer.waited_s = elapsed
			consumer.writer_when_gave_up = w
			local after = towns_api.exclusions(rect)
			consumer.exclusions_after = after and #after or "error"
			report.consumer = consumer
			done()
		end)
	end)
end

local function all_cells()
	local seed = core.get_mapgen_setting("seed")
	local sites = assert(as_towns(dofile, towns.modpath .. "/src/auto_sites.lua").new(towns.auto_environment, {candidates = 9}))
	local list = assert(sites.lookup(seed, {x1 = -2600, z1 = -2600, x2 = 2600, z2 = 2600}))
	local cells, order = {}, {}
	for _, d in ipairs(list) do
		local k = d.cell.x .. ":" .. d.cell.z
		if not cells[k] then
			cells[k] = {cell = d.cell, center = d.center, dist = math.sqrt(d.center.x ^ 2 + d.center.z ^ 2),
				town_type = d.town_type}
			order[#order + 1] = cells[k]
		end
	end
	table.sort(order, function(a, b) return a.dist < b.dist end)
	return order
end

core.after(2, function()
	local ok, cells = pcall(all_cells)
	if not ok then
		fail("cell lookup failed: " .. tostring(cells))
		write_report("fail")
		return core.request_shutdown("demo failed", false, 0)
	end
	local index, consumer_done = 0, false
	local function finish()
		local mismatches = 0
		for _, s in ipairs(report.settlements) do
			for _, e in ipairs(s.exits) do mismatches = mismatches + #e.mismatches end
		end
		report.mismatches = mismatches
		report.both_exit_kinds_verified = report.flat_verified > 0 and report.sloped_verified > 0
		write_report((#report.errors == 0 and mismatches == 0 and #report.settlements > 0) and "pass" or "fail")
		core.request_shutdown("demo finished", false, 0)
	end
	local function next_cell()
		index = index + 1
		if index > MAX_CELLS or not cells[index]
				or (report.flat_verified > 0 and report.sloped_verified > 0 and consumer_done) then return finish() end
		local cell = cells[index]
		local center = cell.center
		local y = core.get_spawn_level(center.x, center.z) or 8
		local minp = {x = chunk_of(center.x), y = chunk_of(y), z = chunk_of(center.z)}
		local maxp = {x = minp.x + 79, y = minp.y + 79, z = minp.z + 79}
		local entry = {cell = cell.cell, center = center, town_type = cell.town_type}
		report.cells[#report.cells + 1] = entry
		core.log("action", ("[roads_api_demo] cell %d,%d: emerging the chunk at its centre"):format(cell.cell.x, cell.cell.z))
		emerge(minp, maxp, function()
			-- The town job starts after on_generated; wait for it (writer is already non-nil here).
			entry.writer_at_emerge_callback = towns_api.writer()
			wait_idle(CELL_WAIT, function(idle, elapsed, w)
				entry.idle, entry.waited_s, entry.writer_when_gave_up = idle, elapsed, w
				local list = dump_settlements(center)
				entry.settlements_listed = #list
				write_report("running")
				if #list > 0 and not report.consumer and idle then
					return run_consumer(list[1], function() consumer_done = true; next_cell() end)
				end
				next_cell()
			end)
		end)
	end
	next_cell()
end)
