-- Hand-measured metadata for the unchanged issue #139 captures.
-- Coordinates are file-local; see README.md for ground and approach evidence.
-- These are fixed landmarks, including domus; never random house candidates.
local entries = {
	arch = {
		size = {x = 12, y = 11, z = 8},
		entrance = {x = 5, y = 1, z = 0},
		entrance_kind = "opening", ground_offset = 0,
	},
	temple = {
		size = {x = 18, y = 11, z = 12},
		entrance = {x = 3, y = 2, z = 5, facing = "-X"},
		entrance_kind = "door", ground_offset = 0,
	},
	domus = {
		size = {x = 38, y = 11, z = 22},
		entrance = {x = 1, y = 2, z = 9, facing = "-X"},
		entrance_kind = "door", ground_offset = 1,
	},
	theatre = {
		size = {x = 21, y = 11, z = 14},
		entrance = {x = 10, y = 5, z = 13, facing = "+Z"},
		entrance_kind = "opening", ground_offset = 3,
	},
	amphitheater = {
		size = {x = 29, y = 9, z = 29},
		entrance = {x = 15, y = 3, z = 0},
		entrance_kind = "opening", ground_offset = 2,
	},
	bath = {
		size = {x = 88, y = 18, z = 43},
		entrance = {x = 4, y = 4, z = 20, facing = "-X"},
		entrance_kind = "door", ground_offset = 2,
	},
	insula = {
		size = {x = 35, y = 20, z = 27},
		entrance = {x = 17, y = 3, z = 2},
		entrance_kind = "door", ground_offset = 2,
	},
	vespasianum = {
		size = {x = 10, y = 8, z = 8},
		entrance = {x = 1, y = 3, z = 3, facing = "-X"},
		entrance_kind = "opening", ground_offset = 2,
	},
	basilica = {
		size = {x = 28, y = 14, z = 16},
		entrance = {x = 23, y = 3, z = 7, facing = "+X"},
		entrance_kind = "door", ground_offset = 2,
	},
}
for id, entry in pairs(entries) do
	entry.path = "schematics/imports/roman/" .. id .. ".mts"
	entry.data_path = "schematics/imports/roman/" .. id .. ".lua"
	entry.role = "landmark"
end
return entries
