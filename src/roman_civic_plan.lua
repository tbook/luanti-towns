-- Roman civic layout (issue #148), authored as data. Tune the town here; the
-- planner (src/roman_planner.lua) derives every rectangle, rotated box and
-- entrance from this file and the catalog's template sizes.
--
-- Frame: the planner centre is the middle of the forum. Each arm is a straight
-- street leaving one forum edge, running outward until the near face of its
-- terminal arch. Positions along an arm are measured outward in nodes ("at"),
-- starting at 0 on the first street node beside the forum, so retuning a
-- street length or the forum size never requires editing other coordinates.
--
-- Rotations are geometry.lua rotations. A rotation must turn the template's
-- entrance toward the street (toward the forum for an arch); the planner
-- rejects the layout otherwise. Compass sides: "+x" east, "-x" west,
-- "+z" north, "-z" south.
return {
	-- Even, so a two-node arch opening can sit exactly mid-street.
	street_width = 6,
	street_material = "mcl_core:stonebrick",
	forum_material = "mcl_core:stonebrick",
	-- Even edge length; the forum is centred on the planner centre.
	forum_size = 30,
	-- Flat construction boundary: bounding box of the plan plus this margin.
	margin = 4,

	-- length: street nodes from the forum edge to the near face of the arch.
	-- arch_rotation: turns the arch opening toward the forum.
	arms = {
		north = {street = "cardo_north", length = 50, arch = "arch_north", arch_rotation = 0},
		south = {street = "cardo_south", length = 59, arch = "arch_south", arch_rotation = 180},
		east = {street = "decumanus_east", length = 59, arch = "arch_east", arch_rotation = 90},
		west = {street = "decumanus_west", length = 48, arch = "arch_west", arch_rotation = 270},
	},
	arch_id = "arch",

	-- arm/side: street arm and which side of it the building stands on.
	-- at: nodes from the forum edge to the building's nearest edge; the
	-- building is flush against the street so its entrance approach is paved.
	landmarks = {
		{name = "temple_east", id = "temple", arm = "north", side = "+x", at = 3, rotation = 0},
		{name = "temple_west", id = "temple", arm = "north", side = "-x", at = 3, rotation = 180},
		{name = "amphitheater", id = "amphitheater", arm = "north", side = "-x", at = 18, rotation = 270},
		{name = "domus_1", id = "domus", arm = "north", side = "+x", at = 18, rotation = 0},
		{name = "domus_2", id = "domus", arm = "east", side = "-z", at = 9, rotation = 90},
		{name = "domus_3", id = "domus", arm = "east", side = "-z", at = 34, rotation = 90},
		{name = "domus_4", id = "domus", arm = "west", side = "+z", at = 23, rotation = 270},
		{name = "theatre", id = "theatre", arm = "west", side = "-z", at = 10, rotation = 0},
		{name = "bath", id = "bath", arm = "south", side = "-x", at = 8, rotation = 180},
	},

	-- Buildable blocks for ordinary buildings: explicit rectangles in the
	-- same arm terms as landmarks. from..to: nodes outward from the forum
	-- edge (both inclusive); side: which side of the arm. The block is flush
	-- against the street and as deep as the shared catalog row depth (the
	-- planner derives it), so retuning a catalog never needs edits here. One
	-- block per free stretch: a monument interrupts a row, so the stretches
	-- on either side of it are separate blocks. Stretches narrower than the
	-- smallest building are left open. A block that starts at 0 also borders
	-- the forum edge; its frontage faces the forum there.
	blocks = {
		{name = "north_end_east", arm = "north", side = "+x", from = 40, to = 49},
		{name = "east_forum_north", arm = "east", side = "+z", from = 0, to = 58},
		{name = "east_forum_south", arm = "east", side = "-z", from = 0, to = 8},
		{name = "south_east", arm = "south", side = "+x", from = 0, to = 58},
		{name = "west_forum_south", arm = "west", side = "-z", from = 0, to = 9},
		{name = "west_end_south", arm = "west", side = "-z", from = 31, to = 47},
		{name = "west_forum_north", arm = "west", side = "+z", from = 0, to = 22},
	},
}
