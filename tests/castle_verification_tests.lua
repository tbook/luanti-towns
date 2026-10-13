-- Castle verification tests (ticket #30).
-- Verifies that the cleaned castle template (castle.mts) matches catalog
-- registration and has valid entrances at all four rotations.

return function(eq, fails, geometry)
	local catalog = dofile("src/catalog.lua")
	local placement = dofile("src/placement.lua")(geometry)

	local castle = catalog.get("castle")

	-- Verify dimensions from file header match catalog.
	local f = assert(io.open(castle.path, "rb"))
	local h = f:read(12)
	f:close()

	eq(h:sub(1, 4), "MTSM", "castle file signature")

	local function u16(i)
		return h:byte(i) * 256 + h:byte(i + 1)
	end

	eq(u16(7), castle.size.x, "castle file width matches catalog (54)")
	eq(u16(9), castle.size.y, "castle file height matches catalog (39)")
	eq(u16(11), castle.size.z, "castle file depth matches catalog (50)")

	-- Verify entrance coordinates are within bounds.
	eq(castle.entrance.x >= 0 and castle.entrance.x < castle.size.x, true,
		"castle entrance x in bounds (30 < 54)")
	eq(castle.entrance.z >= 0 and castle.entrance.z < castle.size.z, true,
		"castle entrance z in bounds (6 < 50)")
	eq(castle.entrance.y >= 0 and castle.entrance.y < castle.size.y, true,
		"castle entrance y in bounds (8 < 39)")

	-- Verify ground_offset is within bounds.
	eq(castle.ground_offset >= 0 and castle.ground_offset < castle.size.y, true,
		"castle ground_offset in bounds (5 < 39)")

	-- Verify the castle placement and entrance at all four rotations.
	local ground_pos = {x = 100, y = 8, z = 100}

	for _, rotation in ipairs(geometry.ROTATIONS) do
		local placed = geometry.place(castle, ground_pos, rotation)

		-- Entrance should be inside the footprint.
		eq(placed.entrance.x >= placed.min.x and placed.entrance.x <= placed.max.x, true,
			"castle rotation " .. rotation .. " entrance x in footprint")
		eq(placed.entrance.z >= placed.min.z and placed.entrance.z <= placed.max.z, true,
			"castle rotation " .. rotation .. " entrance z in footprint")

		-- Outside node provides ground contact point (valid for recessed entrances).
		eq(type(placed.outside), "table",
			"castle rotation " .. rotation .. " outside node is valid")

		-- placement.plan should compute the castle correctly with ground_offset.
		local plan = placement.plan(castle, ground_pos, rotation)
		eq(plan.pos.y, ground_pos.y - castle.ground_offset,
			"castle rotation " .. rotation .. " foundation at ground_offset")
	end

	-- The entrance height should be correctly preserved through rotations.
	for _, rotation in ipairs(geometry.ROTATIONS) do
		local plan = placement.plan(castle, {x = 0, y = 8, z = 0}, rotation)
		eq(plan.building.entrance.y, 11,
			"castle rotation " .. rotation .. " gate height accounts for placement and entrance")
	end
end
