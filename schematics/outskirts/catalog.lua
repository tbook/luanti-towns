-- Rural buildings used only by the outskirts planner. Keep these out of the
-- urban template and role catalogs.
return {
	farm = {
		id = "farm", label = "Farm", class = "farm", role = "farm",
		path = "schematics/outskirts/farm.mts",
		size = {x = 9, y = 8, z = 7}, ground_offset = 0,
		composter = {x = 4, y = 2, z = 0},
	},
	shepherd_hut = {
		id = "shepherd_hut", label = "Shepherd's hut", class = "hut", role = "hut",
		path = "schematics/outskirts/small_house.mts",
		size = {x = 9, y = 9, z = 8}, ground_offset = 0,
		entrance = {x = 4, y = 2, z = 2, facing = "-Z"},
		entrance_kind = "door",
		loom = {x = 3, y = 2, z = 5}, bed = {x = 4, y = 2, z = 5},
	},
}
