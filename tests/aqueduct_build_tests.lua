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
	env.boxes, env.queries = {}, {}
	local function node(x, y, z)
		env.queries[#env.queries + 1] = {x = x, y = y, z = z}
		if opts.column then
			local c = opts.column(x, y, z)
			if c then return c end
		end
		local sp = opts.special and opts.special(x, z)
		local gy = (opts.ground or ground_at)(x)
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
		env.boxes[#env.boxes + 1] = box
		if opts.emerge_throws then error("emerge boom") end
		if opts.emerge_manual then pending_emerge[#pending_emerge + 1] = cb; return end
		if opts.emerge_repeat then cb(true); cb(true); return end
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

local function in_box(b, x, y, z)
	return x >= b.min.x and x <= b.max.x and y >= b.min.y and y <= b.max.y and z >= b.min.z and z <= b.max.z
end
local function in_any(boxes, x, y, z)
	for _, b in ipairs(boxes) do if in_box(b, x, y, z) then return true end end
	return false
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
-- Late writes: the spout and every source are re-set after the commit.
local flows, sources_set, late_after = 0, 0, true
for _, s in ipairs(env.set_nodes) do
	if s.after_commit ~= 1 then late_after = false end
	if s.node.name == aq.FLOW then
		flows = flows + 1
		eq(s.pos.x, res[1].spout.x, "spout position reported")
		eq(s.pos.z, res[1].spout.z, "spout z reported")
	elseif s.node.name == aq.SOURCE then
		sources_set = sources_set + 1
	end
end
eq(late_after, true, "late writes happen after the commit")
eq(flows, 1, "one spout re-set")
eq(sources_set > 0, true, "sources are re-set")
eq(sources_set, res[1].sources_written, "sources_written counts the re-sets")
eq(#env.set_nodes, sources_set + 1, "only sources and the spout are re-set")
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
eq(res[1].sources_written, 0, "source failures are counted, not fatal")

-- A protected source position (a late write) skips the whole aqueduct.
local probe = make()
local first = run(probe)[1]
env = make({protected = function(p)
	return p.x == first.source.x and p.y == first.source.y and p.z == first.source.z
end})
res = run(env)
eq(res[1].status, "skipped", "protected source position skips")
eq(#env.writes + env.commits + #env.set_nodes, 0, "protected source writes nothing")

-- Planner rejection reasons: water and footprints.
env = make({special = function(x, z) if x >= 25 and x <= 90 then return {ground_at(x), "mcl_core:water_source"} end end})
res = run(env)
eq(res[1].status, "skipped", "water over the strip skips")
eq(res[1].reason:find("planner", 1, true) ~= nil, true, "planner rejection has a reason")
eq(env.commits + #env.set_nodes + #env.writes, 0, "water rejection writes, commits and sets nothing")
env = make()
res = run(env, {ground_y = 10, footprints = {{x1 = 21, z1 = 0, x2 = 90, z2 = 40}}})
eq(res[1].status, "skipped", "footprints over the strip skip")
eq(#env.writes, 0, "footprint skip writes nothing")

-- Vegetation is skipped, not ground. A tall tree on flat ground makes no rise.
local function tree_at(tx, tz, base, height)
	return function(x, y, z)
		if x == tx and z == tz and y > base and y <= base + height then
			return y == base + height and "mcl_core:leaves" or "mcl_core:tree"
		end
	end
end
env = make({ground = function() return 10 end, column = tree_at(30, 20, 10, 8)})
res = run(env)
eq(res[1].status, "skipped", "a tree on flat ground does not make a hill")
eq(res[1].reason:find("rises", 1, true) ~= nil, true, "tree on flat ground: no rise")
eq(env.commits + #env.set_nodes, 0, "tree on flat ground writes nothing")
-- A tree on the real hill builds at the hill's height, not the canopy's.
env = make({column = tree_at(70, 20, 24, 8)})
res = run(env)
eq(res[1].status, "built", "tree on a hill still builds")
eq(res[1].source.y, 25, "source sits on the hill, not the canopy")
-- Vegetation words never hide dirt_with_grass ground; env hook takes priority.
env = make({special = function(x) if x == 40 then return {ground_at(x), "mcl_core:dirt_with_grass"} end end})
res = run(env)
eq(res[1].status, "built", "dirt_with_grass is ground")
env = make({is_vegetation = function(name) return name == "mcl_core:stone" end,
	ground = function() return 10 end})
res = run(env)
eq(res[1].status, "skipped", "is_vegetation hook overrides the name list")
-- A tree over water reports water.
env = make({ground = function() return 10 end,
	special = function(x) if x >= 21 then return {10, "mcl_core:water_source"} end end,
	column = tree_at(30, 20, 10, 5)})
res = run(env)
eq(res[1].status, "skipped", "tree over water is not solid")
-- Lava and fire are obstructions ("other"), like water.
env = make({special = function(x) if x >= 25 and x <= 90 then return {ground_at(x), "mcl_core:lava_source"} end end})
res = run(env)
eq(res[1].status, "skipped", "lava over the strip skips")
env = make({special = function(x) if x >= 25 and x <= 90 then return {ground_at(x), "mcl_fire:fire"} end end})
res = run(env)
eq(res[1].status, "skipped", "fire over the strip skips")

-- Height range: a hill reaching y_max - 1 does not fit the source box.
env = make()
res = run(env, {ground_y = 10, footprints = {}, y_max = 25})
eq(res[1].status, "skipped", "hill at y_max-1 skips")
eq(res[1].reason:find("height range", 1, true) ~= nil, true, "height range reason")
eq(#env.writes + env.commits + #env.set_nodes, 0, "height range skip writes nothing")
-- Clamped y range is used for the emerge boxes.
env = make()
run(env, {ground_y = 10, footprints = {}, y_min = 0, y_max = 40})
eq(env.boxes[1].min.y, 0, "y_min clamp reaches the emerge box")
eq(env.boxes[1].max.y, 40, "y_max clamp reaches the emerge box")

-- Reads and writes stay inside the emerged boxes.
env = make()
res = run(env)
local reads_ok = #env.queries > 0
for _, q in ipairs(env.queries) do
	if not in_any(env.boxes, q.x, q.y, q.z) then reads_ok = false end
end
eq(reads_ok, true, "every surface query lies inside an emerged box")
local box_ok = false
for _, b in ipairs(env.boxes) do
	if in_box(b, res[1].box.min.x, res[1].box.min.y, res[1].box.min.z)
			and in_box(b, res[1].box.max.x, res[1].box.max.y, res[1].box.max.z) then box_ok = true end
end
eq(box_ok, true, "the write box lies inside one emerged box")
eq(env.boxes[1].min.y, -10, "default emerge range starts ground_y-20")
eq(env.boxes[1].max.y, 58, "default emerge range ends ground_y+48")

-- A repeated emerge callback for one box is ignored.
env = make({emerge_repeat = true})
res = run(env)
eq(#res, 1, "repeated emerge callbacks complete once")
eq(env.commits, 1, "repeated emerge callbacks commit once")

-- The plan table is not mutated.
local plan2 = {bounds = {x1 = 0, z1 = 0, x2 = 20, z2 = 40}}
env = make()
ab.build(plan2, env, {ground_y = 10, footprints = {}}, function() end)
local keys = 0
for _ in pairs(plan2) do keys = keys + 1 end
eq(keys, 1, "plan gains no keys")
eq(plan2.bounds.x1 + plan2.bounds.z1 + plan2.bounds.x2 + plan2.bounds.z2, 60, "plan bounds unchanged")

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
