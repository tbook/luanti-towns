-- Castle verification tests (ticket #30).
-- Verifies that the cleaned castle template (castle.mts) matches catalog
-- registration and placement at all four rotations.

return function(eq, fails, geometry)
	local catalog = dofile("src/catalog.lua")
	local castle = catalog.get("castle")

	-- Verify file header dimensions match catalog.
	local f = assert(io.open(castle.path, "rb"))
	local h = f:read(12)
	f:close()

	eq(h:sub(1, 4), "MTSM", "castle file signature")

	local function u16(i)
		return h:byte(i) * 256 + h:byte(i + 1)
	end

	eq(u16(7), castle.size.x, "castle file width matches catalog (50)")
	eq(u16(9), castle.size.y, "castle file height matches catalog (39)")
	eq(u16(11), castle.size.z, "castle file depth matches catalog (54)")

	-- Verify entrance and ground_offset coordinates within bounds.
	eq(castle.entrance.x, 24, "castle entrance x coord")
	eq(castle.entrance.z, 3, "castle entrance z coord")
	eq(castle.entrance.y, 6, "castle entrance y coord")
	eq(castle.ground_offset, 5, "castle ground_offset")

	-- Placement at each rotation with explicit expected coordinates.
	-- geometry.place(castle, {x=100, y=3, z=100}, rotation) derives from
	-- placement.plan's application of ground_offset when given pos.y=8.
	-- The outside cell is inside the footprint box (property of the z=3 recess).
	local origin = {x = 100, y = 3, z = 100}
	local expected = {
		[0] = {
			footprint_x = 50, footprint_z = 54,
			entrance = {x = 124, y = 9, z = 103},
			outside = {x = 124, y = 9, z = 102},
		},
		[90] = {
			footprint_x = 54, footprint_z = 50,
			entrance = {x = 103, y = 9, z = 125},
			outside = {x = 102, y = 9, z = 125},
		},
		[180] = {
			footprint_x = 50, footprint_z = 54,
			entrance = {x = 125, y = 9, z = 150},
			outside = {x = 125, y = 9, z = 151},
		},
		[270] = {
			footprint_x = 54, footprint_z = 50,
			entrance = {x = 150, y = 9, z = 124},
			outside = {x = 151, y = 9, z = 124},
		},
	}

	for _, rotation in ipairs(geometry.ROTATIONS) do
		local placed = geometry.place(castle, origin, rotation)
		local exp = expected[rotation]

		eq(placed.size.x, exp.footprint_x,
			"rotation " .. rotation .. " footprint width")
		eq(placed.size.z, exp.footprint_z,
			"rotation " .. rotation .. " footprint depth")

		eq(placed.entrance.x, exp.entrance.x,
			"rotation " .. rotation .. " entrance x")
		eq(placed.entrance.y, exp.entrance.y,
			"rotation " .. rotation .. " entrance y")
		eq(placed.entrance.z, exp.entrance.z,
			"rotation " .. rotation .. " entrance z")

		eq(placed.outside.x, exp.outside.x,
			"rotation " .. rotation .. " outside x")
		eq(placed.outside.y, exp.outside.y,
			"rotation " .. rotation .. " outside y")
		eq(placed.outside.z, exp.outside.z,
			"rotation " .. rotation .. " outside z")

		-- Outside cell is inside the footprint (documented property of recessed gate).
		local outside_in_footprint = (placed.outside.x >= placed.min.x and
			placed.outside.x <= placed.max.x and placed.outside.z >= placed.min.z and
			placed.outside.z <= placed.max.z)
		eq(outside_in_footprint, true,
			"rotation " .. rotation .. " outside cell inside footprint (recessed gate)")
	end
end
