local eq = ...
local preflight = dofile("src/preflight.lua")
local build = dofile("src/outskirts_build.lua")
local catalog = dofile("schematics/outskirts/catalog.lua")
local entries = {}
for id, e in pairs(catalog) do entries[id] = e end
local bounds = {x1 = 0, z1 = 0, x2 = 20, z2 = 20}
local out = {entries = entries, protected = {margin = 6}, plots = {
	{id = "f1", asset = "farm", class = "farm", rotation = 90, ground_y = 11,
		rect = {x1 = 30, z1 = 30, x2 = 42, z2 = 46}},
	{id = "h1", asset = "shepherd_hut", class = "hut", rotation = 0, ground_y = 17,
		rect = {x1 = 60, z1 = 30, x2 = 68, z2 = 37}},
}}
local composed = assert(preflight.compose_outskirts(out, entries))
eq(composed.structures[1].min.y, 11, "farm uses its own ground")
eq(composed.structures[2].min.y, 17, "hut uses its own ground")
eq(composed.structures[1].max.x, 42, "rotated farm footprint")

local offset_entries = {farm = {id = "farm", size = {x = 9, y = 8, z = 7}, ground_offset = 2}}
local offset = assert(preflight.compose_outskirts({plots = {{id = "f", asset = "farm", class = "farm",
	rotation = 0, ground_y = 20, rect = {x1 = 5, z1 = 5, x2 = 13, z2 = 11}}}}, offset_entries))
eq(offset.structures[1].min.y, 18, "composition subtracts each asset ground offset")

local reads, node_checks = {}, 0
local check_env = {
	read_schematic = function(path)
		reads[path] = (reads[path] or 0) + 1
		local e = path:find("farm", 1, true) and entries.farm or entries.shepherd_hut
		return {size = e.size, data = {{name = "mcl_core:dirt"}}}
	end,
	read_data = function() return {required_nodes = {}} end,
	node_registered = function() node_checks = node_checks + 1; return true end,
}
local report = assert(preflight.check_outskirts(out, check_env,
	{entries = entries, plan = {bounds = bounds}, player = {x = -100, z = -100}}))
eq(report.files, 2, "assets checked once per id")
eq(node_checks, 1, "shared node checked once")
local dup = {entries = entries, protected = out.protected, plots = {
	out.plots[1], {id = "f2", asset = "farm", class = "farm", rotation = 0, ground_y = 12,
		rect = {x1 = 110, z1 = 30, x2 = 126, z2 = 42}},
}}
reads, node_checks = {}, 0
assert(preflight.check_outskirts(dup, check_env, {entries = entries, plan = {bounds = bounds},
	player = {x = -100, z = -100}}))
eq(reads["schematics/outskirts/farm.mts"], 1, "duplicate asset is read once")
local dep, _, dep_code = preflight.check_outskirts(out, {
	read_schematic = function() return nil end, read_data = check_env.read_data,
	node_registered = check_env.node_registered,
}, {entries = entries, plan = {bounds = bounds}})
eq(dep, nil, "missing schematic fails preflight")
eq(dep_code, "outskirts_dependency", "missing schematic is dependency failure")
local wrong, _, wrong_code = preflight.check_outskirts(out, {
	read_schematic = function(path)
		local e = path:find("farm", 1, true) and entries.farm or entries.shepherd_hut
		return {size = {x = e.size.x + 1, y = e.size.y, z = e.size.z}, data = {}}
	end, read_data = check_env.read_data, node_registered = check_env.node_registered,
}, {entries = entries, plan = {bounds = bounds}})
eq(wrong, nil, "size mismatch fails preflight")
eq(wrong_code, "outskirts_dependency", "size mismatch is dependency failure")
local _, _, node_code = preflight.check_outskirts({plots = {out.plots[1]}}, {
	read_schematic = function() return {size = entries.farm.size, data = {{name = "missing:node"}}} end,
	read_data = check_env.read_data, node_registered = function() return false end,
}, {entries = {farm = entries.farm}, plan = {bounds = bounds}})
eq(node_code, "outskirts_dependency", "unregistered node is dependency failure")
local overlap_out = {plots = {out.plots[1], {id = "h2", asset = "shepherd_hut", class = "hut",
	rotation = 0, ground_y = 11, rect = {x1 = 32, z1 = 32, x2 = 40, z2 = 39}}}}
local _, _, overlap_code = preflight.compose_outskirts(overlap_out, entries)
eq(overlap_code, "geometry", "overlapping plot geometry is rejected")
local protected_out = {plots = {{id = "f", asset = "farm", class = "farm", rotation = 0,
	ground_y = 11, rect = {x1 = 22, z1 = 10, x2 = 30, z2 = 16}}}}
local _, _, protected_code = preflight.check_outskirts(protected_out, check_env,
	{entries = entries, plan = {bounds = bounds}})
eq(protected_code, "outskirts_error", "protected town overlap is rejected")
local _, _, bad_geometry = preflight.check_outskirts(out, check_env,
	{entries = entries, plan = {bounds = bounds}, player = {x = 34, z = 34}})
eq(bad_geometry, "outskirts_error", "player overlap is a programming error")

local events, placements, setups = {}, 0, 0
local result, result_error, result_code = build.apply(out, {
	terrain = {volume = function(plan) return {minp = {x=plan[1].pos.x,y=-16,z=plan[1].pos.z},
		maxp = {x=plan[1].pos.x+16,y=32,z=plan[1].pos.z+16}} end, terraform = function(plan, _, opts)
		events[#events + 1] = "terraform:" .. plan[1].name
		return true, {changed = 1, unloaded_blocks = 0,
			written = {minp = {x = plan[1].pos.x, y = plan[1].pos.y, z = plan[1].pos.z},
				maxp = {x = plan[1].pos.x, y = plan[1].pos.y, z = plan[1].pos.z}}}
	end},
	place_structure = function(st)
		events[#events + 1] = "place:" .. st.id
		placements = placements + 1
		return true
	end,
	get_node = function() return "air" end,
	check_door = function() return {approach = {x = 0, z = 0}, steps = 2} end,
	setup_nodes = function(structures) setups = #structures; return {failed = {}, unregistered = {}} end,
}, {bounds = bounds, structures = composed.structures})
assert(result, tostring(result_code) .. ": " .. tostring(result_error))
eq(result.placed, 2, "both structures place")
eq(events[1], "terraform:farm", "first terraform")
eq(events[2], "terraform:shepherd_hut", "all terrain before placement")
eq(events[3], "place:farm", "then farm placement")
eq(events[4], "place:shepherd_hut", "then hut placement")
eq(setups, 2, "setup sees placed structures")
eq(result.setup.failed ~= nil and #result.setup.failed == 0, true, "setup report is returned")
eq(#result.doors, 1, "reachable door is reported")

local failed = build.apply(out, {
	terrain = {volume = function(plan) return {minp = {x=plan[1].pos.x,y=-16,z=plan[1].pos.z},
		maxp = {x=plan[1].pos.x+16,y=32,z=plan[1].pos.z+16}} end, terraform = function(plan)
		if plan[1].name == "farm" then return false, "refused" end
		return true, {unloaded_blocks = 1,
			written = {minp={x=2000,y=1,z=2000},maxp={x=2001,y=2,z=2001}}}
	end},
	place_structure = function() placements = placements + 1; return true end,
	get_node = function() return "air" end,
	check_door = function() return {approach = {x = 0, z = 0}, steps = 2} end,
	setup_nodes = function() return {failed={},unregistered={}} end,
}, {bounds = bounds, structures = composed.structures})
eq(failed.placed, 0, "declined and incomplete plots are skipped")
eq(#failed.skipped, 2, "each skipped plot is reported")
eq(#failed.boxes, 1, "incomplete terraform written box is retained")
eq(failed.terraform[2].stats.unloaded_blocks, 1, "terraform stats are retained")

local partial, _, partial_code, partial_extra = build.apply(out, {
	terrain = {volume = function(plan) return {minp = {x=plan[1].pos.x,y=-16,z=plan[1].pos.z},
		maxp = {x=plan[1].pos.x+16,y=32,z=plan[1].pos.z+16}} end, terraform = function() return true, {unloaded_blocks = 0} end},
	place_structure = function(st)
		if st.id == "shepherd_hut" then error("engine placement raised") end
		return true
	end,
	get_node = function() return "air" end,
	check_door = function() return {approach = {x = 0, z = 0}, steps = 2} end,
	setup_nodes = function() return {failed={},unregistered={}} end,
}, {bounds = bounds, structures = composed.structures})
eq(partial, nil, "raised placement fails")
eq(partial_code, "write_failed", "raised placement is post-write failure")
eq(#partial_extra.placement_attempted, 2, "failure lists every schematic placement box attempted")
eq(partial_extra.placement_attempted[2].max.y, 25, "tall site-specific ground box is retained")

local warnings_setup
local warned = build.apply(out, {
	terrain = {volume = function(plan) return {minp = {x=plan[1].pos.x,y=-16,z=plan[1].pos.z},
		maxp = {x=plan[1].pos.x+16,y=32,z=plan[1].pos.z+16}} end,
		terraform = function() return true, {unloaded_blocks=0} end},
	place_structure = function(st) return st.id ~= "farm", "returned false" end,
	get_node = function() return "air" end,
	check_door = function() return nil, "blocked approach" end,
	setup_nodes = function(structures) warnings_setup = #structures; return {failed={},unregistered={}} end,
}, {bounds = bounds, structures = composed.structures})
eq(warned.placed, 1, "returned placement failure does not stop later plots")
eq(warned.warnings[1].code, "placement_failed", "placement failure is a warning")
eq(warned.warnings[2].code, "door_unreachable", "unreachable door is a warning")
eq(warnings_setup, 1, "setup sees survivors only")

local terraformed, _, terraform_code, terraform_extra = build.apply(out, {
	terrain = {volume = function(plan) return {minp={x=plan[1].pos.x,y=-16,z=plan[1].pos.z},
		maxp={x=plan[1].pos.x+16,y=32,z=plan[1].pos.z+16}} end,
		terraform = function(plan)
			if plan[1].name == "shepherd_hut" then error("terrain engine raised") end
			return true, {unloaded_blocks=0,written={minp={x=1000,y=1,z=1000},maxp={x=1001,y=2,z=1001}}}
		end}, place_structure=function() return true end, get_node=function() return "air" end,
	check_door=function() return {approach={x=0,z=0},steps=1} end,
	setup_nodes=function() return {failed={},unregistered={}} end,
}, {bounds=bounds,structures=composed.structures})
eq(terraformed,nil,"raised terraform fails")
eq(terraform_code,"write_failed","raised terraform reports partial write")
eq(#terraform_extra.attempted,2,"raised terraform reports current and prior volume boxes")
eq(#terraform_extra.boxes,1,"prior terraform write box survives failure")

local setup_failed, _, setup_code, setup_extra = build.apply(out, {
	terrain = {volume = function(plan) return {minp={x=plan[1].pos.x,y=-16,z=plan[1].pos.z},
		maxp={x=plan[1].pos.x+16,y=32,z=plan[1].pos.z+16}} end,
		terraform = function() return true,{unloaded_blocks=0,written={minp={x=1000,y=1,z=1000},maxp={x=1001,y=2,z=1001}}} end},
	place_structure=function() return true end,get_node=function() return "air" end,
	check_door=function() return {approach={x=0,z=0},steps=1} end,
	setup_nodes=function() return {failed={{id="farm"}},unregistered={}} end,
}, {bounds=bounds,structures=composed.structures})
eq(setup_failed,nil,"node setup failure returns failure")
eq(setup_code,"write_failed","node setup failure is post-write")
eq(#setup_extra.placement_attempted,2,"node setup failure lists all placements")
eq(#setup_extra.boxes,2,"node setup failure retains terrain write boxes")

local missing_setup = build.apply(out, {
	terrain={volume=function(plan) return {minp={x=plan[1].pos.x,y=-16,z=plan[1].pos.z},
		maxp={x=plan[1].pos.x+16,y=32,z=plan[1].pos.z+16}} end,terraform=function() return true,{unloaded_blocks=0} end},
	place_structure=function() return true end,get_node=function() return "air" end,
	check_door=function() return {approach={x=0,z=0},steps=1} end,
}, {bounds=bounds,structures=composed.structures})
eq(missing_setup,nil,"missing node setup cannot report success")
