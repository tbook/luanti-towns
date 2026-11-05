local eq = ...
	local villages = dofile("src/auto_villages.lua")
	local state_mod = dofile("src/auto_state.lua")
	local descriptor = {id = "site", center = {x = 500, z = 500}, max_rect = {x1 = 400, z1 = 400, x2 = 600, z2 = 600},
		activation_rect = {x1 = 300, z1 = 300, x2 = 700, z2 = 700}}
	local lookup = function() return {descriptor} end
	local session = assert(state_mod.new({lookup = lookup, adapter = {origin = -32, size = 80, accepts = function() return true end},
		footprint = {x1 = 0, z1 = 0, x2 = 0, z2 = 0}}))
	local registry = {records = {}, is_enabled = function() return true end,
		lookup = function(self, c) return self.records[c.x .. ":" .. c.z] end}
	local calls, disabled, logs, active = 0, 0, 0, true
	local suppressed = {} 
	local s = {schematic_table = {{name = "belltower", hwidth = 10, hdepth = 10, hheight = 10, hsize = 5, max_num = 1}}, find_surface = function() end, check_distance = function() end, terraform = function() end, surface_mat = {} }
	local marker = {}
	s.create_site_plan = function(a, b, pr, extra)
		calls = calls + 1
		pr.count = pr.count + 1
		return marker, nil, extra
	end
	local opts = {planner_enabled = true, mcl_vars = {get_chunk_number = function() end}, max_height_difference = 5, settlements = s, env = {village_reach = 100, config = {village = {}}, providers = {volume = {terrain = function() end}}},
		lookup = lookup, session = session, registry = registry, enabled = function() return active end,
		disable = function() disabled = disabled + 1 end, log = function() logs = logs + 1 end,
		on_suppressed = function(reason) suppressed[#suppressed + 1] = reason end}
	local guard = assert(villages.install(opts))
	eq(villages.install(opts), guard, "duplicate install returns same guard")
	local pr = {count = 0}
	local a, b, c = s.create_site_plan({x = 299, z = 500}, {x = 299, z = 500}, pr, "tail")
	eq(a, marker, "near miss passes original result")
	eq(b, nil, "pass preserves nil return")
	eq(c, "tail", "pass preserves extra argument and return")
	eq(pr.count, 1, "pass preserves planner random use")
	eq(session:state("site"), nil, "near miss leaves site untouched")
	-- Trigger a real surface event so the real session owns an active inspection.
	local h = {}; for z = 368, 447 do h[z] = {}; for x = 368, 447 do h[z][x] = 10 end end
	assert(session:on_generated({minp = {x = 368, y = -32, z = 368}, maxp = {x = 447, y = 47, z = 447}, heights = h}))
	eq(session:state("site"), "inspecting", "surface event activates inspection")
	eq(s.create_site_plan({x = 300, z = 500}, {x = 300, z = 500}, pr), false, "inclusive reach boundary suppresses")
	eq(pr.count, 1, "suppression does not touch RNG")
	eq(suppressed[1], "inspecting", "inspection suppression counted")
	session:decline("site")
	eq(s.create_site_plan({x = 300, z = 500}, {x = 300, z = 500}, pr), marker, "declined temporary reservation releases")
	registry.records["0:0"] = {envelope = {min = {x = 400, z = 400}, max = {x = 600, z = 600}}}
	active = false
	eq(s.create_site_plan({x = 700, z = 500}, {x = 700, z = 500}, pr), false, "off mode protects accepted record at reach boundary")
	eq(suppressed[2], "accepted", "accepted suppression counted")
	eq(s.create_site_plan({x = 701, z = 500}, {x = 701, z = 500}, pr), marker, "off mode near miss passes")
	registry.records = {}
	active = true
	local session2 = assert(state_mod.new({lookup = lookup, adapter = {origin = -32, size = 80, accepts = function() return true end},
		footprint = {x1 = 0, z1 = 0, x2 = 0, z2 = 0}}))
	local s2 = {schematic_table = s.schematic_table, find_surface = s.find_surface, check_distance = s.check_distance, terraform = s.terraform, surface_mat = s.surface_mat}
	s2.create_site_plan = function()
		local actions = assert(session2:on_generated({minp = {x = 368, y = -32, z = 368}, maxp = {x = 447, y = 47, z = 447}, heights = h}))
		eq(#actions, 0, "planner-generated surface cannot activate declined candidate")
		return marker
	end
	opts.settlements, opts.session = s2, session2
	assert(villages.install(opts))
	eq(s2.create_site_plan({x = 300, z = 500}, {x = 300, z = 500}, pr), marker, "pending site lets village plan")
	eq(session2:state("site"), "declined", "candidate declined before planner")
	s.create_site_plan = function() return "replacement" end
	eq(guard:check(), false, "replacement detected")
	eq(guard:check(), false, "replacement remains disabled")
	eq(disabled, 1, "replacement disables once")
	eq(logs, 1, "replacement reports once")
	local missing_opts = {}
	for k, v in pairs(opts) do missing_opts[k] = v end
	missing_opts.mcl_vars = {}
	local before = s2.create_site_plan
	eq(villages.install(missing_opts), nil, "missing Living Villages planner prerequisite is unsupported")
	eq(s2.create_site_plan, before, "unsupported planner leaves existing callable untouched")
	local s3 = {schematic_table = s.schematic_table, find_surface = s.find_surface,
		check_distance = s.check_distance, terraform = s.terraform, surface_mat = s.surface_mat,
		create_site_plan = function() return marker end}
	local disabled_opts = {}; for k, v in pairs(opts) do disabled_opts[k] = v end
	disabled_opts.planner_enabled, disabled_opts.settlements = false, s3
	local fallback = assert(villages.install(disabled_opts))
	eq(fallback:check(), false, "fallback disables new automatic operation")
	eq(villages.install(disabled_opts), nil, "disabled operation reports only once")
	registry.records["0:0"] = {envelope = {min = {x = 400, z = 400}, max = {x = 600, z = 600}}}
	eq(s3.create_site_plan({x = 731, z = 500}, {x = 731, z = 500}, pr), false, "vanilla fallback protects inclusive reach")
	eq(s3.create_site_plan({x = 732, z = 500}, {x = 732, z = 500}, pr), marker, "vanilla fallback passes near miss")
	eq(logs, 3, "fallback reports once")
	local broken = {create_site_plan = function() return marker end}
	opts.settlements = broken
	eq(villages.install(opts), nil, "unsupported dependency rejected")
	eq(broken.create_site_plan(), marker, "unsupported dependency keeps village callable")
