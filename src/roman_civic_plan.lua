-- Roman civic layout (issue #148), authored as data. Tune the town here; the
-- planner (src/roman_planner.lua) derives every rectangle, rotated box and
-- entrance from this file and the catalog's template sizes.
--
-- Frame: the planner centre is the middle of the forum. Each arm is a straight
-- street leaving one forum edge, running outward until the near face of its
-- terminal arch (or terminal landmark). Positions along an arm are measured outward in nodes ("at"),
-- starting at 0 on the first street node beside the forum, so retuning a
-- street length or the forum size never requires editing other coordinates.
--
-- Rotations are geometry.lua rotations. A rotation must turn the template's
-- entrance toward the street (toward the forum for an arch, or for a landmark
-- with faces = "forum"); the planner rejects the layout otherwise. Compass
-- sides: "+x" east, "-x" west, "+z" north, "-z" south.
return {
	-- Even, so a two-node arch opening can sit exactly mid-street.
	street_width = 6,
	street_material = "mcl_core:cobble",
	forum_material = "mcl_core:cobble",
	-- Even edge length; the forum is centred on the planner centre.
	forum_size = 30,
	-- Margin of a terminal landmark's compound (its box grown by this on the
	-- three sides away from the forum).
	margin = 4,
	-- Main city rectangle (issue #351), authored, offsets from the forum centre.
	-- The boundary is this plus each terminal compound; no other site, street or
	-- block may leave it.
	main_rect = {x1 = -95, z1 = -87, x2 = 85, z2 = 85},

	-- Street profiles (issue #172), by name; an arm picks one with `profile`.
	-- A lane is `width` nodes across, centred on the street, paved with
	-- `material` (a bottom slab, so the lane sits half a node below the full
	-- blocks at the edges). width must be even, and at least one node of the
	-- street's width must remain on each side. Lanes run from the forum edge
	-- to the node before the arch or forecourt (see roman_planner.lua).
	profiles = {
		lane = {material = "mcl_stairs:slab_cobble", width = 4},
	},

	-- length: street nodes from the forum edge to the near face of the arch.
	-- arch_rotation: turns the arch opening toward the forum.
	-- profile: optional street profile from `profiles` (principal arms only).
	arms = {
		-- The north arm ends in a terminal landmark (issue #351) instead of an arch:
		-- a forecourt square `depth` nodes deep, then the landmark, both as wide as
		-- the landmark and centred on the street. Its rotation must turn the
		-- entrance toward the forum. The boundary gains a compound around it.
		north = {
			street = "cardo_north", length = 57, profile = "lane",
			terminal = {name = "temple_of_jupiter", id = "temple_of_jupiter", rotation = 0,
				forecourt = {name = "jupiter_forecourt", depth = 8}},
		},
		south = {street = "cardo_south", length = 59, arch = "arch_south", arch_rotation = 180, profile = "lane"},
		east = {street = "decumanus_east", length = 59, arch = "arch_east", arch_rotation = 90, profile = "lane"},
		west = {street = "decumanus_west", length = 59, arch = "arch_west", arch_rotation = 270, profile = "lane"},
	},
	arch_id = "arch",

	-- Ring street (issue #164): a loop behind the main streets, as secondary
	-- bands one street wide (six since issue #202, nine since issue #353). Each band is the node range
	-- from..to outward from the forum edge (as arm positions) along the axis
	-- of its arm, and span = {lo, hi}, the compass extent across it (x for
	-- north and south bands, z for east and west). The north bands cross the
	-- cardo; the north and north_outer bands cross the east and west bands; the
	-- south and south_outer bands run across the east band; the south and west
	-- bands start beside the south and west arms (T-junctions), as do west_outer,
	-- south_west and east_outer. south_west runs through the south-west quadrant
	-- two rows south of the bath, which no other band enters. Listed in street order.
	band_material = "mcl_core:gravel",
	bands = {
		{name = "north", arm = "north", from = 18, to = 23, span = {-44, 81}},
		{name = "north_outer", arm = "north", from = 51, to = 56, span = {-91, 81}},
		{name = "south", arm = "south", from = 26, to = 31, span = {3, 81}},
		{name = "south_outer", arm = "south", from = 59, to = 64, span = {6, 81}},
		{name = "east", arm = "east", from = 23, to = 28, span = {-80, 71}},
		{name = "west", arm = "west", from = 23, to = 28, span = {3, 71}},
		-- Issue #353: T off the western decumanus ending at the hippodrome's south
		-- side; T off the southern cardo under the bath; link east of domus_3.
		{name = "west_outer", arm = "west", from = 51, to = 56, span = {3, 40}},
		{name = "south_west", arm = "south", from = 53, to = 58, span = {-91, -4}},
		{name = "east_outer", arm = "east", from = 51, to = 56, span = {-41, -4}},
	},

	-- arm/side: street arm and which side of it the building stands on.
	-- at: nodes from the forum edge to the building's nearest edge; the
	-- building is flush against the street so its entrance approach is paved.
	landmarks = {
		-- Temples face the forum: rotation 270 turns the door to -z, and at = 0
		-- puts the approach on the forum's north edge.
		{name = "temple_east", id = "temple", arm = "north", side = "+x", at = 0, rotation = 270, faces = "forum"},
		{name = "temple_west", id = "temple", arm = "north", side = "-x", at = 0, rotation = 270, faces = "forum"},
		-- Temple of Vesta (issue #352) on the south edge, east of the cardo: its
		-- cella-facing side (rotation 180) opens north onto the forum.
		{name = "temple_of_vesta", id = "temple_of_vesta", arm = "south", side = "+x", at = 0, rotation = 180, faces = "forum"},
		-- Outside the ring, east arm, north side: the north-east outer corner.
		{name = "amphitheater", id = "amphitheater", arm = "east", side = "+z", at = 29, rotation = 0},
		-- Insulae stand flush against the inner north and south bands, on their
		-- outer side (ring + side); `at` is the low edge along the band.
		{name = "insula_north_east", id = "insula", ring = "north", side = "outer", at = 3, rotation = 0},
		{name = "insula_north_west", id = "insula", ring = "north", side = "outer", at = -38, rotation = 0},
		{name = "insula_south", id = "insula", ring = "south", side = "outer", at = 3, rotation = 180},
		-- The basilica stands inside the ring; the others stand outside it.
		{name = "domus_1", id = "domus", ring = "east", side = "outer", at = 39, rotation = 0},
		-- Rotation 270 turns its front door (+X) to +z, toward the decumanus.
		{name = "basilica", id = "basilica", arm = "east", side = "-z", at = 0, rotation = 270},
		{name = "domus_3", id = "domus", arm = "east", side = "-z", at = 29, rotation = 90},
		{name = "domus_4", id = "domus", arm = "west", side = "+z", at = 29, rotation = 270},
		-- Public latrine (#218) at the far end of the east arm's north frontage,
		-- beyond block east_forum_north (which keeps the forum-edge run). Rotation
		-- 270 turns its -X opening toward -z, the decumanus; the approach is paved.
		{name = "vespasianum_east", id = "vespasianum", arm = "east", side = "+z", at = 15, rotation = 270},
		{name = "theatre", id = "theatre", arm = "west", side = "-z", at = 10, rotation = 180},
		{name = "bath", id = "bath", arm = "south", side = "-x", at = 8, rotation = 180},
		-- Hippodrome (issue #353) in the north-west interior; its long-side portico
		-- (rotation 180) opens +z onto ring_north_outer. Its door court east of it
		-- (x -54..-45) is deliberately unbuilt.
		{name = "hippodrome", id = "hippodrome", ring = "north_outer", side = "inner", at = -91, rotation = 180},
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
	--
	-- A block with ring = a band name (see bands) instead of arm stands
	-- flush against that ring band: side "outer" (away from the forum) or
	-- "inner". from..to are compass coordinates along the band, relative to
	-- the forum centre (x for north and south bands, z for east and west).
	blocks = {
		{name = "east_forum_north", arm = "east", side = "+z", from = 0, to = 14},
		{name = "south_east_inner", arm = "south", side = "+x", from = 11, to = 25},
		{name = "west_forum_south", arm = "west", side = "-z", from = 0, to = 9},
		{name = "west_end_south", arm = "west", side = "-z", from = 31, to = 58},
		{name = "west_forum_north", arm = "west", side = "+z", from = 0, to = 22},
		{name = "ring_north_inner_east", ring = "north", side = "inner", from = 15, to = 37},
		{name = "outer_north_east", ring = "north_outer", side = "outer", from = 10, to = 81},
		{name = "outer_north_west", ring = "north_outer", side = "outer", from = -91, to = -11},
		{name = "ring_east_outer_south", ring = "east", side = "outer", from = -74, to = -48},
		-- Issue #354: ordinary blocks in the gaps and corners opened by #351..#353
		-- (docs/roman_expansion_layout.md sections 9 and 10).
		{name = "ring_south_inner_east", ring = "south", side = "inner", from = 12, to = 37},
		{name = "ring_north_inner_west", ring = "north", side = "inner", from = -38, to = -16},
		{name = "ring_west_inner_north", ring = "west", side = "inner", from = 12, to = 23},
		{name = "ring_east_inner_north", ring = "east", side = "inner", from = 13, to = 23},
		{name = "ring_south_outer_east", ring = "south", side = "outer", from = 53, to = 81},
		{name = "ring_south_outer_inner_east", ring = "south_outer", side = "inner", from = 53, to = 81},
		{name = "west_outer_west", ring = "west_outer", side = "outer", from = 6, to = 40},
		{name = "south_west_outer", ring = "south_west", side = "outer", from = -91, to = -7},
		{name = "east_amph_north", ring = "north", side = "inner", from = 73, to = 81},
		{name = "east_outer_east", ring = "east_outer", side = "outer", from = -41, to = -7},
	},
}
