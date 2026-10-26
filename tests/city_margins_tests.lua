
local eq, factory = ...
	local function fixture(terrain, behavior)
		local calls = {volume = 0, smooth = 0, emerge = 0, after = 0, done = 0}
		local env = {
			emerge = function(minp, maxp, cb)
				calls.emerge = calls.emerge + 1
				calls.minp, calls.maxp, calls.cb = minp, maxp, cb
				if behavior and behavior.emerge_throw then error("emerge boom") end
				if not (behavior and behavior.emerge_late) then cb(not (behavior and behavior.emerge_fail)) end
			end,
			after = function(seconds, cb)
				calls.after = calls.after + 1
				calls.seconds, calls.timer = seconds, cb
				if behavior and behavior.after_throw then error("timer boom") end
			end,
		}
		local api = terrain or {
			boundary_volume = function(rects, ground, options)
				calls.volume = calls.volume + 1
				calls.rects, calls.ground, calls.options = rects, ground, options
				if behavior and behavior.volume_throw then error("volume boom") end
				if behavior and behavior.volume_false then return nil, "declined" end
				if behavior and behavior.bad_volume then return {minp = {x = 2}, maxp = {x = 1}} end
				return {minp = {x = -16, y = -32, z = -16}, maxp = {x = 31, y = 47, z = 31}}
			end,
			smooth_boundary = function(rects, ground, options)
				calls.smooth = calls.smooth + 1
				calls.write_rects, calls.write_ground, calls.write_options = rects, ground, options
				if behavior and behavior.smooth_throw then error("writer boom") end
				if behavior and behavior.smooth_false then return false, "partial write" end
				return true, {changed = 9, steps_over_one = 3}
			end,
		}
		local result = {ground_y = 12, plan = {boundary = {rects = {
			{x1 = 3, z1 = 5, x2 = 8, z2 = 10},
			{x1 = 8, z1 = 5, x2 = 12, z2 = 7},
		}}}}
		local originals = {}
		for i, rect in ipairs(result.plan.boundary.rects) do originals[i] = {x1=rect.x1,z1=rect.z1,x2=rect.x2,z2=rect.z2} end
		local summary
		factory(api).attempt(result, function(value) calls.done = calls.done + 1; summary = value end, env)
		return calls, result, originals, function() return summary end
	end

	local calls, result, originals, summary = fixture()
	eq(calls.volume, 1, "volume called once")
	eq(calls.emerge, 1, "emerge before writer")
	eq(calls.smooth, 1, "writer after successful emerge")
	eq(calls.done, 1, "successful attempt completes once")
	eq(summary().status, "smoothed", "successful status")
	eq(summary().stats.steps_over_one, 3, "slope diagnostic retained")
	eq(summary().attempted_bounds.minp.y, -32, "attempted bounds retained")
	eq(calls.ground, 12, "volume uses fixed inspected ground")
	eq(calls.options.radius, 20, "radius fixed at twenty")
	eq(calls.options.cap, 20, "cap fixed at twenty")
	eq(calls.write_options.env, nil, "no engine environment forwarded unless supplied")
	eq(#calls.rects, 2, "rectangles mapped as union")
	eq(calls.rects[1].x0, 3, "rect x1 maps to x0")
	eq(calls.rects[1].z0, 5, "rect z1 maps to z0")
	eq(calls.rects[2].x1, 12, "rect x2 maps to LV x1")
	eq(result.plan.boundary.rects[1].x1, originals[1].x1, "original rect unchanged")
	eq(result.plan.boundary.rects[2].x2, originals[2].x2, "overlap remains represented")
	local watchdog_calls = fixture(nil, {emerge_late = true})
	eq(watchdog_calls.seconds, 30, "watchdog uses thirty seconds")

	local function check_skipped(behavior, label)
		local c, _, _, get = fixture(nil, behavior)
		eq(get().status, "skipped", label .. " status")
		eq(c.done, 1, label .. " completes once")
		eq(c.smooth, 0, label .. " never writes")
		eq(get().attempted_bounds, nil, label .. " no attempted envelope")
	end
	check_skipped({volume_false = true}, "volume decline")
	check_skipped({volume_throw = true}, "volume exception")
	check_skipped({emerge_fail = true}, "failed emerge")
	check_skipped({emerge_throw = true}, "emerge exception")
	check_skipped({emerge_late = true, after_throw = true}, "timer exception")
	check_skipped({bad_volume = true}, "malformed volume")

	local malformed_inputs = {
		{value = nil, label = "nil result"},
		{value = {}, label = "missing plan"},
		{value = {plan = false, ground_y = 0}, label = "malformed plan"},
		{value = {plan = {boundary = {rects = {[1]={x1=0,z1=0,x2=1,z2=1}, [3]={x1=4,z1=4,x2=5,z2=5}}}}, ground_y=0}, label = "sparse boundary"},
		{value = {plan = {boundary = {rects = {{x1=0,z1=0,x2=1,z2=1}}}}, ground_y=0}, env = false, label = "malformed environment"},
	}
	for _, case in ipairs(malformed_inputs) do
		local api_calls = {volume = 0, smooth = 0, done = 0}
		local api = {
			boundary_volume = function() api_calls.volume = api_calls.volume + 1; return nil, "should not run" end,
			smooth_boundary = function() api_calls.smooth = api_calls.smooth + 1 end,
		}
		local env = {emerge = function() end, after = function() end}
		if case.env == false then env = false end
		factory(api).attempt(case.value, function(s) api_calls.done=api_calls.done+1; api_calls.summary=s end, env)
		eq(api_calls.summary.status, "skipped", case.label .. " status")
		eq(api_calls.done, 1, case.label .. " completes once")
		eq(api_calls.volume, case.label == "malformed environment" and 1 or 0,
			case.label .. " volume API calls")
		eq(api_calls.smooth, 0, case.label .. " does not call writer")
	end

	local missing_calls = {done = 0}
	factory(nil).attempt({plan = {boundary = {rects = {{x1=0,z1=0,x2=1,z2=1}}}}, ground_y=0},
		function(s) missing_calls.done=missing_calls.done+1; missing_calls.summary=s end, {})
	eq(missing_calls.summary.status, "skipped", "missing API optional")
	eq(missing_calls.done, 1, "missing API completes once")

	for _, behavior in ipairs({{smooth_false = true}, {smooth_throw = true}}) do
		local c, _, _, get = fixture(nil, behavior)
		eq(get().status, "incomplete", "writer failure is incomplete")
		eq(get().attempted_bounds.maxp.x, 31, "writer failure keeps attempted bounds")
		eq(c.done, 1, "writer failure completes once")
	end

	local c, _, _, get = fixture(nil, {emerge_late = true})
	eq(get(), nil, "late emerge initially pending")
	c.timer()
	eq(get().status, "skipped", "timeout skips")
	c.cb(true)
	eq(c.smooth, 0, "late emerge never writes")
	eq(c.done, 1, "timeout and late callback complete once")

	local sync_cb_throws = {boundary_volume = function() return {minp={x=0,y=0,z=0},maxp={x=0,y=0,z=0}} end,
		smooth_boundary = function() return true, {} end}
	local done_count = 0
	factory(sync_cb_throws).attempt({plan={boundary={rects={{x1=0,z1=0,x2=0,z2=0}}}},ground_y=0},
		function() done_count=done_count+1; error("callback error") end,
		{emerge=function(_,_,cb) cb(true); cb(false) end, after=function() end})
		eq(done_count, 1, "sync duplicate callback and throwing done complete once")

	local forwarded
	local api_env = {}
	local api_env_api = {
		boundary_volume = function(_, _, options) forwarded = options.env; return nil, "declined" end,
		smooth_boundary = function() error("declined volume must not write") end,
	}
	factory(api_env_api).attempt({plan={boundary={rects={{x1=0,z1=0,x2=0,z2=0}}}},ground_y=0},
		function() end, {api_env=api_env})
	eq(forwarded, api_env, "API environment forwarded when supplied")
