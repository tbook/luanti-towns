-- Aqueduct build adapter (issue #417, step 2): src/aqueduct_build.lua on a fake
-- env with a table-backed region. Loaded by tests/run.lua with the shared helper.
local eq = ...
local ab = dofile("src/aqueduct_build.lua")
local aq = dofile("src/aqueduct.lua")

local BOUNDS = {x1 = 0, z1 = 0, x2 = 20, z2 = 40}
local plan = {bounds = BOUNDS}

-- Terrain: ground 10, rising east of the town to 24 at x = 70. `special(x,z)`
-- may return {y, name} to override the top node of a column.
local function ground_at(x)
	local d = math.min(math.max(x - 20, 0), 50)
	return 10 + math.floor(d * 14 / 50)
end

local function make(opts)
	opts = opts or {}
	local env = {log = {}, writes = {}, commits = 0, emerges = 0, set_nodes = {}, opens = {}}
	local pending_emerge, timer = {}, nil
	env.timer_fn = nil
	local function node(x, y, z)
		local sp = opts.special and opts.special(x, z)
		local gy = ground_at(x)
		if sp then gy = sp[1] end
		if y > gy then
			if sp and y == gy + 1 and sp[3] then return sp[3] end
			return "air"
		end
		if y == gy and sp then return sp[2] end
		return "mcl_core:stone"
	end
	function env.emerge(box, cb)
		env.emerges = env.emerges + 1
		if opts.emerge_throws then error("emerge boom") end
		if opts.emerge_manual then pending_emerge[#pending_emerge + 1] = cb; return end
		cb(opts.emerge_ok ~= false)
	end
	function env.flush(ok) for _, cb in ipairs(pending_emerge) do cb(ok) end; pending_emerge = {} end
	function env.open_region(box)
		env.opens[#env.opens + 1] = box
		if opts.open_throws then error("open boom") end
		local r = {}
		function r.get(x, y, z) return node(x, y, z) end
		function r.set(x, y, z, name, p2)
			env.writes[#env.writes + 1] = {x = x, y = y, z = z, name = name, box = box}
			if x < box.min.x or x > box.max.x or y < box.min.y or y > box.max.y
					or z < box.min.z or z > box.max.z then error("write outside region") end
		end
		function r.commit() env.commits = env.commits + 1; env.commit_at = #env.writes end
		return r
	end
	env.authorized = opts.authorize ~= false
	function env.authorize_strip(box) env.auth_box = box; return env.authorized end
	env.owned = true
	env.owner_calls = 0
	function env.check_ownership()
		env.owner_calls = env.owner_calls + 1
		if opts.lose_ownership_after and env.owner_calls > opts.lose_ownership_after then return false, "lost" end
		return env.owned
	end
	function env.protected(pos) return opts.protected and opts.protected(pos) or false end
	function env.after(sec, fn)
		if opts.no_timer then error("no timer") end
		env.timer_fn = fn
	end
	function env.set_node(pos, n)
		if opts.set_node_throws then error("set boom") end
		env.set_nodes[#env.set_nodes + 1] = {pos = pos, node = n, after_commit = env.commits, writes = #env.writes}
	end
	return env
end

local function run(env, opts)
	local results = {}
	ab.build(plan, env, opts or {ground_y = 10, footprints = {}}, function(r) results[#results + 1] = r end)
	return results
end

-- Success.
local env = make()
local res = run(env)
eq(#res, 1, "build calls done exactly once")
eq(res[1].status, "built", "hill east of the town builds")
eq(res[1].side, "+x", "built on the rising side")
eq(res[1].length >= aq.CONSTANTS.MIN_LENGTH, true, "built length is reported")
eq(res[1].nodes, #env.writes, "node count matches writes")
eq(env.commits, 1, "exactly one commit")
eq(env.commit_at, #env.writes, "commit comes after every set")
eq(#env.set_nodes, 1, "one spout node")
eq(env.set_nodes[1].after_commit, 1, "spout written after the commit")
eq(env.set_nodes[1].node.name, aq.FLOW, "spout is flowing water")
eq(env.set_nodes[1].pos.x, res[1].spout.x, "spout position reported")
eq(res[1].spout_written, true, "spout write reported")
eq(env.timer_fn ~= nil, true, "timeout timer is armed")
local inbox = true
for _, w in ipairs(env.writes) do
	local b = res[1].box
	if w.x < b.min.x or w.x > b.max.x or w.y < b.min.y or w.y > b.max.y or w.z < b.min.z or w.z > b.max.z then inbox = false end
end
eq(inbox, true, "all writes stay inside the strip write box")
eq(env.auth_box.min.x, res[1].box.min.x, "authorize_strip gets the write box")
eq(res[1].source.y ~= nil, true, "source position reported")
-- the write strip is narrow (5 wide)
eq(res[1].box.max.z - res[1].box.min.z + 1, aq.CONSTANTS.WIDTH, "write strip is WIDTH wide")

-- Late timer after success is ignored.
env.timer_fn()
eq(#res, 1, "timer after completion is a no-op")

-- Emerge failure.
env = make({emerge_ok = false})
res = run(env)
eq(#res, 1, "emerge false calls done once")
eq(res[1].status, "skipped", "emerge false skips")
eq(#env.writes + env.commits, 0, "emerge false writes nothing")

-- Timeout, then late emerge callbacks.
env = make({emerge_manual = true})
res = run(env)
eq(#res, 0, "waiting for emerge")
env.timer_fn()
eq(#res, 1, "timeout calls done once")
eq(res[1].status, "skipped", "timeout skips")
eq(res[1].reason:find("timed out", 1, true) ~= nil, true, "timeout reason")
env.flush(true)
eq(#res, 1, "late callback after timeout is ignored")
eq(#env.writes + env.commits, 0, "late callback writes nothing")

-- Late failing callback after timeout, and completion via callbacks.
env = make({emerge_manual = true})
res = run(env)
env.flush(true)
eq(#res, 1, "manual emerge completes once all boxes load")
eq(res[1].status, "built", "manual emerge builds")
env.timer_fn()
eq(#res, 1, "timer after manual completion is ignored")

-- Emerge throws / open_region throws / timer unavailable.
res = run(make({emerge_throws = true}))
eq(#res == 1 and res[1].status, "skipped", "emerge exception skips once")
env = make({open_throws = true})
res = run(env)
eq(#res == 1 and res[1].status, "skipped", "env exception skips once")
eq(env.commits, 0, "env exception commits nothing")
res = run(make({no_timer = true}))
eq(#res == 1 and res[1].status, "skipped", "missing timer skips")

-- Authorization, ownership, protection.
env = make({authorize = false})
res = run(env)
eq(res[1].status, "skipped", "unauthorized strip skips")
eq(#env.writes + env.commits + #env.set_nodes, 0, "unauthorized strip writes nothing")
env = make({lose_ownership_after = 1})
res = run(env)
eq(res[1].status, "skipped", "lost ownership skips")
eq(res[1].reason:find("ownership", 1, true) ~= nil, true, "ownership reason")
eq(#env.writes + env.commits + #env.set_nodes, 0, "lost ownership writes nothing")
env = make({lose_ownership_after = 2})
res = run(env)
eq(#res == 1 and res[1].status, "skipped", "ownership lost just before writing skips")
eq(#env.writes + env.commits + #env.set_nodes, 0, "late ownership loss writes nothing")
env = make({protected = function(p) return p.x == 40 end})
res = run(env)
eq(res[1].status, "skipped", "protected position skips")
eq(res[1].reason:find("protected", 1, true) ~= nil, true, "protected reason")
eq(#env.writes + env.commits + #env.set_nodes, 0, "protected position writes nothing")

-- Spout failure does not undo the build and does not throw.
env = make({set_node_throws = true})
res = run(env)
eq(res[1].status, "built", "spout failure still reports built")
eq(res[1].spout_written, false, "spout failure is reported")

-- Planner rejection reasons: water and footprints.
env = make({special = function(x, z) if x >= 25 and x <= 90 then return {ground_at(x), "mcl_core:water_source"} end end})
res = run(env)
eq(res[1].status, "skipped", "water over the strip skips")
eq(res[1].reason:find("planner", 1, true) ~= nil, true, "planner rejection has a reason")
env = make()
res = run(env, {ground_y = 10, footprints = {{x1 = 21, z1 = 0, x2 = 90, z2 = 40}}})
eq(res[1].status, "skipped", "footprints over the strip skip")
eq(#env.writes, 0, "footprint skip writes nothing")

-- Trees count as solid: a leaf block atop a column does not skip the line.
env = make({special = function(x, z)
	if x >= 22 and x <= 24 then return {ground_at(x) + 6, "mcl_core:leaves"} end
end})
res = run(env)
eq(res[1].status, "built", "tree columns count as solid")

-- Unloaded ("ignore") columns are nil, not solid: a flat unloaded world skips.
env = make()
local real_open = env.open_region
env.open_region = function(box)
	local r = real_open(box)
	r.get = function() return "ignore" end
	return r
end
res = run(env)
eq(res[1].status, "skipped", "unloaded region skips")
eq(#env.writes + env.commits, 0, "unloaded region writes nothing")

-- No rise: flat ground skips.
env = make()
env.open_region = function(box)
	local r = {}
	function r.get(x, y, z) return y <= 10 and "mcl_core:stone" or "air" end
	function r.set() error("no write expected") end
	function r.commit() error("no commit expected") end
	return r
end
res = run(env)
eq(res[1].status, "skipped", "flat ground skips")
eq(res[1].reason:find("rises", 1, true) ~= nil, true, "flat ground reason names the rise")

-- At most one aqueduct, and a failing callback of done is not repeated.
env = make()
local n = 0
ab.build(plan, env, {ground_y = 10, footprints = {}}, function() n = n + 1; error("caller boom") end)
eq(n, 1, "done is not called again when it raises")
