-- Aqueduct build adapter (issue #417, step 2). Runs AFTER the town and its
-- outskirts are fully built, as a separate step with its own narrow read/write
-- strip. It never touches the town: it has no fail_writer, no summary and no
-- approved write envelope. Every failure becomes {status = "skipped", reason}
-- and the caller simply continues. Success is {status = "built", ...}.
--
-- All world access goes through an injected `env`, so this module has no
-- Minetest globals and runs under plain Lua 5.1 tests. It is not wired into
-- generate_command.lua or automatic.lua yet.
--
-- env contract (all functions required):
--   env.emerge(box, callback)   async load of box {min, max}; callback(ok).
--   env.open_region(box)        region with get(x,y,z) -> node name ("ignore"
--                               when unloaded), set(x,y,z,name,param2), commit()
--                               (same shape as the builder.lua region).
--   env.authorize_strip(box)    true/false for the single write box. Automatic
--                               mode wraps session:covers, player clearance,
--                               lock ownership and freshness; manual mode may
--                               be looser. false -> skip, nothing is written.
--   env.check_ownership()       allowed[, why]; checked again just before the
--                               write. Falsy -> skip.
--   env.protected(pos)          true when pos {x,y,z} is protected. Any
--                               protected write position skips the aqueduct.
--   env.after(seconds, fn)      timer used for the emerge timeout.
--   env.set_node(pos, node)     node {name, param2}; writes the spout.
--
-- API: M.build(plan, env, opts, done)
--   plan  town plan; only plan.bounds is read (see aqueduct.candidates).
--   opts  {ground_y = number (required), footprints = rect list,
--          y_min, y_max (optional, default ground_y-20 / ground_y+48; the
--          caller may pass an already clamped range), timeout = seconds (30)}
--   done(result) is called exactly once, whatever happens (emerge false,
--   timeout, late callback, exception, rejection, success).
--
-- Surface contract. surface(x, z) scans a column from y_max down to the first
-- non-air node and returns y and a kind: "solid" (terrain and also trees,
-- leaves and plants, since the aqueduct replaces them), "water" (any water
-- node) or "other" (lava and the like, an obstruction). A column that cannot
-- be resolved (unloaded node, outside the sampled strips, no ground within the
-- y range) returns nil. nil is conservative everywhere: aqueduct.choose drops a
-- line whose centre column is nil, and aqueduct.profile marks such a column
-- "unknown" and trims it away or rejects. So no fake y is ever invented and the
-- planner needs no change.
--
-- Spout (inferred, to verify in game): a flowing node written through
-- VoxelManip with write_to_map(true) and no liquid update probably does not
-- flow, so the spout is rewritten with env.set_node after the commit.
local M = {}
local source = debug.getinfo(1, "S").source:sub(2)
local modpath = source:match("^(.*)/src/aqueduct_build.lua$") or "."
local aqueduct = dofile(modpath .. "/src/aqueduct.lua")

M.DEFAULTS = {TIMEOUT = 30, DOWN = 20, UP = 48}

local function kind_of(name)
	if name == "air" then return "air" end
	if name:find("water", 1, true) then return "water" end
	if name:find("lava", 1, true) or name:find("fire", 1, true) then return "other" end
	return "solid"
end

-- Node scan of one column. Returns y, kind or nil.
local function scan(region, x, z, y_min, y_max)
	for y = y_max, y_min, -1 do
		local name = region.get(x, y, z)
		if name == nil or name == "ignore" then return nil end
		local kind = kind_of(name)
		if kind ~= "air" then return y, kind end
	end
	return nil
end

-- One sampling rect per side (the union of that side's candidate lines).
local function side_boxes(lines, y_min, y_max)
	local by, order = {}, {}
	for _, line in ipairs(lines) do
		local r, u = line.rect, by[line.side_index]
		if not u then
			u = {x1 = r.x1, z1 = r.z1, x2 = r.x2, z2 = r.z2}
			by[line.side_index] = u
			order[#order + 1] = line.side_index
		else
			u.x1, u.z1 = math.min(u.x1, r.x1), math.min(u.z1, r.z1)
			u.x2, u.z2 = math.max(u.x2, r.x2), math.max(u.z2, r.z2)
		end
	end
	table.sort(order)
	local out = {}
	for _, i in ipairs(order) do
		local u = by[i]
		out[#out + 1] = {rect = u, min = {x = u.x1, y = y_min, z = u.z1},
			max = {x = u.x2, y = y_max, z = u.z2}}
	end
	return out
end

local function inside(box, p)
	return p.x >= box.min.x and p.x <= box.max.x and p.y >= box.min.y and p.y <= box.max.y
		and p.z >= box.min.z and p.z <= box.max.z
end

-- Synchronous part, after all sampling boxes are loaded. Returns a result.
local function plan_and_write(plan, env, opts, boxes, y_min, y_max)
	local regions = {}
	for i, b in ipairs(boxes) do regions[i] = env.open_region({min = b.min, max = b.max}) end
	local cache = {}
	local function surface(x, z)
		local key = x .. ":" .. z
		local hit = cache[key]
		if hit == nil then
			hit = false
			for i, b in ipairs(boxes) do
				local r = b.rect
				if x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 then
					local y, kind = scan(regions[i], x, z, y_min, y_max)
					if y then hit = {y, kind} end
					break
				end
			end
			cache[key] = hit
		end
		if not hit then return nil end
		return hit[1], hit[2]
	end

	local result, why = aqueduct.plan_aqueduct(plan, surface, opts.footprints)
	if not result then return {status = "skipped", reason = "planner: " .. tostring(why)} end
	local box = result.box
	local read_box = {min = {x = box.min.x, y = y_min, z = box.min.z},
		max = {x = box.max.x, y = y_max, z = box.max.z}}
	if box.min.y < y_min or box.max.y > y_max then
		return {status = "skipped", reason = "aqueduct exceeds the strip height range"}
	end
	if not env.authorize_strip(box) then
		return {status = "skipped", reason = "strip not authorized"}
	end
	local allowed, own_why = env.check_ownership()
	if not allowed then
		return {status = "skipped", reason = "ownership lost: " .. tostring(own_why)}
	end
	for _, c in ipairs(result.changes) do
		if not inside(box, c) then
			return {status = "skipped", reason = "write outside the strip box"}
		end
		if env.protected({x = c.x, y = c.y, z = c.z}) then
			return {status = "skipped", reason = ("protected position (%d,%d,%d)"):format(c.x, c.y, c.z)}
		end
	end

	local region = env.open_region(read_box)
	for _, c in ipairs(result.changes) do region.set(c.x, c.y, c.z, c.name, c.param2) end
	region.commit()
	local sp = result.spout
	local spout_ok, spout_err = pcall(env.set_node, {x = sp.x, y = sp.y, z = sp.z},
		{name = aqueduct.FLOW, param2 = 0})
	return {status = "built", side = result.side, offset = result.offset, length = result.length,
		rise = result.rise, source = result.source, spout = result.spout, box = box,
		nodes = #result.changes, spout_written = spout_ok,
		spout_error = (not spout_ok) and tostring(spout_err) or nil}
end

function M.build(plan, env, opts, done)
	opts = opts or {}
	assert(type(done) == "function", "aqueduct build needs a continuation")
	local settled = false
	local function finish(result)
		if settled then return end
		settled = true
		done(result)
	end
	local function skip(reason) finish({status = "skipped", reason = reason}) end

	local ok, err = pcall(function()
		assert(type(env) == "table", "environment required")
		local ground_y = assert(opts.ground_y, "ground_y required")
		local D = M.DEFAULTS
		local y_min, y_max = opts.y_min or ground_y - D.DOWN, opts.y_max or ground_y + D.UP
		local boxes = side_boxes(aqueduct.candidates(plan), y_min, y_max)
		if #boxes == 0 then return skip("no candidate lines") end
		if not env.check_ownership() then return skip("ownership lost") end

		local pending, started = #boxes, false
		local function loaded(success)
			if settled then return end
			if not success then return skip("emerge failed") end
			pending = pending - 1
			if pending > 0 then return end
			local ran, result = pcall(function()
				if not env.check_ownership() then return {status = "skipped", reason = "ownership lost"} end
				return plan_and_write(plan, env, opts, boxes, y_min, y_max)
			end)
			if ran then finish(result) else skip("error: " .. tostring(result)) end
		end
		local timed = pcall(env.after, opts.timeout or D.TIMEOUT, function() skip("emerge timed out") end)
		if not timed then return skip("no timer available") end
		for _, b in ipairs(boxes) do
			local cb = function(success)
				local cok, cerr = pcall(loaded, success)
				if not cok then skip("error: " .. tostring(cerr)) end
			end
			env.emerge({min = b.min, max = b.max}, cb)
			if settled then break end
		end
	end)
	if not ok then skip("error: " .. tostring(err)) end
end

return M
