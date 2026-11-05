-- Production providers for the shared automatic-town bounds. Built during
-- Towns loading, after its required Living Villages dependency has loaded.
return function(towns, core, settlements, living_villages)
	local bounds = dofile(towns.modpath .. "/src/auto_bounds.lua")
	local terrain = assert(living_villages and living_villages.terrain, "Living Villages terrain API unavailable")
	local planner = dofile(core.get_modpath("living_villages") .. "/site_planner.lua")
	local v = assert(planner.config, "Living Villages planner configuration unavailable")
	local config = bounds.default_config()
	config.village = {cell = v.cell, max_cells = v.max_cells, relocate_step = v.relocate_step,
		relocate_rings = v.relocate_rings, radius_jitter = v.radius_jitter}
	local rural = dofile(towns.modpath .. "/schematics/outskirts/catalog.lua")
	local outskirts, walls, village = {}, {}, {}
	for _, id in ipairs({"farm", "shepherd_hut", "villa"}) do
		outskirts[#outskirts + 1] = {id = id, size = rural[id].size}
	end
	outskirts[#outskirts + 1] = {id = "chapel", size = towns.catalog.entries.chapel.size}
	for id, entry in pairs(towns.catalog.entries) do
		if id:match("^wall_") and entry.size then walls[#walls + 1] = {id = id, size = entry.size} end
	end
	for _, schem in ipairs(assert(settlements and settlements.schematic_table, "village schematics unavailable")) do
		village[#village + 1] = {name = schem.name, hwidth = schem.hwidth, hdepth = schem.hdepth, hheight = schem.hheight}
	end
	local env, why = bounds.new({config = config, assets = {outskirts = outskirts, village = village, wall_features = walls},
		volume = {terrain = terrain.volume, boundary = terrain.boundary_volume}})
	assert(env, why)
	return env
end
