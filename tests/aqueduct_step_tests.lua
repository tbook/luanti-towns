-- Aqueduct build step (issue #417, step 3): src/aqueduct_step.lua on fakes.
local eq = ...
local step = dofile("src/aqueduct_step.lua")

local function mk(opts)
	opts = opts or {}
	local result = {ground_y = 10,
		plan = {town_type = opts.type or "roman", bounds = {x1 = 0, z1 = 0, x2 = 20, z2 = 20},
			boundary = {rects = {{x1 = 1, z1 = 1, x2 = 19, z2 = 19}}}},
		wall_feature_footprints = {{x1 = 30, z1 = 30, x2 = 31, z2 = 31}},
		outskirts = {plots = {{rect = {x1 = 50, z1 = 50, x2 = 60, z2 = 60}}}}}
	local summary = {write_bounds = {min = {x = 0, y = 0, z = 0}, max = {x = 20, y = 20, z = 20}},
		town = {structures = {{min = {x = 2, y = 5, z = 3}, max = {x = 6, y = 9, z = 8}},
			{rect = {x1 = 70, z1 = 70, x2 = 72, z2 = 72}, min = {x = 0, y = 0, z = 0}, max = {x = 1, y = 1, z = 1}}}}}
	return result, summary
end
local bounds_before = "0,0,0,20,20,20"
local function wb(s) local b = s.write_bounds; return table.concat({b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z}, ",") end

-- Footprints: area, buildings (min/max or rect), ramps, plots.
local result, summary = mk()
local fp = step.footprints(result, summary)
local function has(x1, z1, x2, z2)
	for _, r in ipairs(fp) do if r.x1 == x1 and r.z1 == z1 and r.x2 == x2 and r.z2 == z2 then return true end end
	return false
end
eq(has(0, 0, 20, 20), true, "footprint: town bounds")
eq(has(1, 1, 19, 19), true, "footprint: boundary rect")
eq(has(2, 3, 6, 8), true, "footprint: structure min/max")
eq(has(70, 70, 72, 72), true, "footprint: structure rect preferred")
eq(has(30, 30, 31, 31), true, "footprint: ramp/feature")
eq(has(50, 50, 60, 60), true, "footprint: outskirts plot")

local function run(result, summary, ctx)
	local continued = 0
	step.run(result, summary, ctx, function() continued = continued + 1 end)
	return continued
end

-- Non-roman: adapter untouched, no summary.aqueduct, continues once.
do
	local r, s = mk({type = "medieval"})
	local called = 0
	local n = run(r, s, {env = {}, build = function() called = called + 1 end})
	eq(called, 0, "gate: medieval does not call the aqueduct")
	eq(n, 1, "gate: medieval continues once")
	eq(s.aqueduct, nil, "gate: medieval leaves summary.aqueduct unset")
end

-- Success: opts and footprints reach the adapter; summary set; bounds untouched.
do
	local r, s = mk()
	local seen
	local n = run(r, s, {env = {tag = 1}, opts = {y_min = 3, y_max = 40}, build = function(plan, env, opts, done)
		seen = {plan = plan, env = env, opts = opts}
		done({status = "built", side = "+x", length = 40, rise = 9, spout = {x = 1, y = 2, z = 3}})
	end})
	eq(n, 1, "success continues once")
	eq(s.aqueduct.status, "built", "success: summary.aqueduct built")
	eq(seen.plan, r.plan, "success: plan passed")
	eq(seen.env.tag, 1, "success: env passed")
	eq(seen.opts.ground_y, 10, "success: ground_y passed")
	eq(seen.opts.y_min, 3, "success: y clamp passed")
	eq(seen.opts.y_max, 40, "success: y_max passed")
	eq(#seen.opts.footprints, 6, "success: all footprints passed")
	eq(wb(s), bounds_before, "success: write_bounds untouched")
end

-- Adapter skip, adapter throw, throw after done, double done: one continue each.
do
	local r, s = mk()
	eq(run(r, s, {env = {}, build = function(_, _, _, done) done({status = "skipped", reason = "nope"}) end}), 1,
		"skip continues once")
	eq(s.aqueduct.reason, "nope", "skip: reason kept")
	r, s = mk()
	eq(run(r, s, {env = {}, build = function() error("boom") end}), 1, "throw continues once")
	eq(s.aqueduct.status, "skipped", "throw: skipped")
	eq(s.aqueduct.reason:find("boom", 1, true) ~= nil, true, "throw: reason has the error")
	eq(wb(s), bounds_before, "throw: write_bounds untouched")
	r, s = mk()
	eq(run(r, s, {env = {}, build = function(_, _, _, done)
		done({status = "built", length = 1}); done({status = "skipped", reason = "late"}); error("after")
	end}), 1, "done then throw continues once")
	eq(s.aqueduct.status, "built", "first result wins")
	r, s = mk()
	eq(run(r, s, {env = {}, build = function(_, _, _, done) done("garbage") end}), 1, "invalid result continues once")
	eq(s.aqueduct.status, "skipped", "invalid result becomes skipped")
end

-- Async completion is deferred through ctx.after, continues once, and an error
-- thrown by the continuation is not swallowed by the adapter's callback.
do
	local r, s = mk()
	local late, timers, continued = nil, {}, 0
	step.run(r, s, {env = {}, after = function(sec, fn) timers[#timers + 1] = fn end,
		build = function(_, _, _, done) late = done end}, function() continued = continued + 1 end)
	eq(continued, 0, "async: waits for the adapter")
	eq(s.aqueduct, nil, "async: nothing recorded yet")
	late({status = "built", length = 5}); late({status = "skipped", reason = "dup"})
	eq(continued, 0, "async: continuation deferred out of the adapter callback")
	timers[1]()
	eq(continued, 1, "async: continues once")
	eq(s.aqueduct.status, "built", "async: result recorded")
	local r2, s2 = mk()
	local queued
	step.run(r2, s2, {env = {}, after = function(_, fn) queued = fn end,
		build = function(_, _, _, done) late = done end}, function() error("finalize broke") end)
	late({status = "built", length = 1})
	eq(pcall(queued), false, "async: continuation errors surface from the timer")
	local r3, s3, n3 = mk(), nil, 0
	step.run(r3, s3 or select(2, mk()), {env = {}, after = function() error("no timers") end,
		build = function(_, _, _, done) late = done end}, function() n3 = n3 + 1 end)
	late({status = "built", length = 1})
	eq(n3, 1, "async: falls back to direct continuation when no timer is available")
end

-- No capability: skipped with the reason, adapter never called.
do
	local r, s = mk()
	local called = 0
	eq(run(r, s, {skip_reason = "automatic town has no aqueduct capability",
		build = function() called = called + 1 end}), 1, "no capability continues once")
	eq(called, 0, "no capability: adapter not called")
	eq(s.aqueduct.status, "skipped", "no capability: skipped")
	eq(s.aqueduct.reason, "automatic town has no aqueduct capability", "no capability: reason")
end

-- make_env: box adaptation, vegetation groups, default authorize.
do
	local log = {}
	local env = step.make_env({
		emerge = function(a, b, cb) log[#log + 1] = {"emerge", a, b}; cb(true) end,
		open_region = function(a, b) log[#log + 1] = {"open", a, b}; return "region" end,
		check_ownership = function() return true end, protected = function() return false end,
		after = function() end, set_node = function() end,
		registered_nodes = {leaf = {groups = {leaves = 1}}, stone = {groups = {cracky = 1}},
			flower = {groups = {flora = 1}}, mystery = {}},
	})
	local box = {min = {x = 1, y = 2, z = 3}, max = {x = 4, y = 5, z = 6}}
	env.emerge(box, function() end)
	eq(log[1][2], box.min, "env.emerge passes min")
	eq(log[1][3], box.max, "env.emerge passes max")
	eq(env.open_region(box), "region", "env.open_region adapts the box")
	eq(env.authorize_strip(box), true, "manual authorize allows")
	eq(env.is_vegetation("leaf"), true, "leaves group is vegetation")
	eq(env.is_vegetation("flower"), true, "flora group is vegetation")
	eq(env.is_vegetation("stone"), false, "stone is not vegetation")
	eq(env.is_vegetation("mystery"), false, "unknown groups are not vegetation")
	local veg = step.make_env({emerge = function() end, open_region = function() end,
		registered_nodes = {
			["x:vines"] = {groups = {vines = 1}}, ["x:sap"] = {groups = {sapling = 1}},
			["x:torch"] = {groups = {attached_node = 1}}, ["x:rock"] = {groups = {cracky = 1}},
			["mcl_core:dirt_with_grass"] = {groups = {attached_node = 0}},
			["mcl_core:vine"] = {}, ["mcl_core:podzol"] = {groups = {plant = 0}}}})
	eq(veg.is_vegetation("x:vines"), true, "vines group is vegetation")
	eq(veg.is_vegetation("x:sap"), true, "sapling group is vegetation")
	eq(veg.is_vegetation("x:torch"), true, "attached_node group is vegetation")
	eq(veg.is_vegetation("x:rock"), false, "plain stone is not vegetation")
	eq(veg.is_vegetation("mcl_core:vine"), true, "vine name heuristic applies to registered nodes")
	eq(veg.is_vegetation("mcl_flowers:tulip"), true, "unregistered names use the name heuristic")
	eq(veg.is_vegetation("mcl_core:dirt_with_grass"), false, "dirt with grass is never vegetation")
	eq(veg.is_vegetation("mcl_core:podzol"), false, "podzol is never vegetation")
	eq(veg.is_vegetation("mcl_core:grass_block"), false, "_block nodes are never vegetation")
	local plain = step.make_env({emerge = function() end, open_region = function() end})
	eq(plain.is_vegetation, nil, "no registry: adapter name fallback")
end
