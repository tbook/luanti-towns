-- Runs only in the disposable world created by check.py.
local objects = dofile(towns.modpath .. "/schematics/objects/catalog.lua")
local checks, count = {}, 0
local function check(ok, message)
	assert(ok, message)
	checks[#checks + 1] = "PASS " .. message
end

local function run()
	local fountain = objects.roman_fountain
	local ok, why = towns.schematic.validate(fountain, towns.modpath)
	check(ok, "fountain uses registered game nodes: " .. tostring(why or "ok"))
	local pos = {x = 112, y = 20, z = 20}
	for z = 15, 29 do for x = 107, 121 do
		core.set_node({x=x,y=20,z=z}, {name="mcl_core:cobble"})
		for y = 21, 24 do core.set_node({x=x,y=y,z=z}, {name="air"}) end
	end end
	local placed, reason = towns.schematic.place(fountain, pos, 0, towns.modpath, {initialize = false})
	assert(placed, reason)
	check(core.get_node({x = 114, y = 21, z = 22}).name == "mcl_bells:bell", "fountain places the hidden bell at ground +1")
	check(core.get_node({x = 114, y = 23, z = 22}).name == "mcl_core:water_source", "fountain places its water source")
	for _, id in ipairs({"oak_tree", "garden"}) do
		local e = objects[id]
		local source = assert(core.read_schematic(towns.modpath .. "/" .. e.path, {}))
		check(source.size.x == e.size.x and source.size.y == e.size.y and source.size.z == e.size.z,
			id .. " dimensions match catalog")
		local ok, why = towns.schematic.validate(e, towns.modpath)
		check(ok, id .. " uses registered game nodes: " .. tostring(why or "ok"))
		local crops, waters, leaves = 0, 0, 0
		local function at(x, y, z)
			return source.data[z * e.size.y * e.size.x + y * e.size.x + x + 1]
		end
		for z = 0, e.size.z - 1 do for y = 0, e.size.y - 1 do for x = 0, e.size.x - 1 do
			local n = at(x, y, z)
			if core.get_item_group(n.name, "plant") > 0 then
				crops = crops + 1
				assert(y == e.ground_offset + 1 and at(x, y-1, z).name == "mcl_farming:soil_wet")
				local irrigated = false
				for wz = 0, e.size.z-1 do for wx = 0, e.size.x-1 do
					if at(wx, y-1, wz).name == "mcl_core:water_source"
						and math.abs(wx-x) <= 4 and math.abs(wz-z) <= 4 then irrigated = true end
				end end
				assert(irrigated, "crop without nearby water")
			elseif n.name == "mcl_core:water_source" then
				waters = waters + 1
				assert(y == e.ground_offset and at(x, y-1, z).name == "mcl_core:dirt")
				for _, d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
					local neighbor = at(x+d[1], y, z+d[2])
					assert(core.registered_nodes[neighbor.name].walkable, "uncontained water")
				end
			elseif n.name == "mcl_core:leaves" then
				leaves = leaves + 1
			end
		end end end
		if id == "garden" then
			check(crops == 18 and waters == 2, "garden has 18 supported, irrigated plants and two contained water sources")
			for z = 0, 6 do
				assert(at(3, 1, z).name == "mcl_core:gravel" and at(3, 2, z).name == "air")
			end
			check(true, "garden has an uninterrupted path at ground level")
		else
			check(leaves > 0 and crops == 0 and waters == 0, "oak has a complete crown inside its 7 by 7 footprint")
		end
		for _, angle in ipairs({0, 90, 180, 270}) do
			local p = {x = count * 16, y = 20 - e.ground_offset, z = 0}
			count = count + 1
			local placed, reason = towns.schematic.place(e, p, angle, towns.modpath, {initialize = false})
			assert(placed, reason)
			for z = 0, e.size.z - 1 do for y = 0, e.size.y - 1 do for x = 0, e.size.x - 1 do
				local n = at(x, y, z)
				local offset = towns.schematic.rotate_offset(e.size, {x=x,y=y,z=z}, angle)
				local node = core.get_node(vector.add(p, offset))
				local expected_p2 = n.param2
				-- The oak logs have a vertical facedir axis; the engine rotates
				-- the horizontal facing bits even though all four sides are bark.
				if n.name == "mcl_core:tree" then expected_p2 = (n.param2 + angle / 90) % 4 end
				assert(node.name == n.name and node.param2 == expected_p2,
					id .. " rotation " .. angle .. " node mismatch at " .. x .. "," .. y .. "," .. z ..
					": " .. node.name .. "/" .. node.param2 .. " expected " .. n.name .. "/" .. expected_p2)
			end end end
			check(true, id .. " places every node correctly at " .. angle .. " degrees")
		end
	end
	check(core.registered_chatcommands.towns_place_object ~= nil, "object preview command registered")
	core.after(4, function()
		local bell = {x=114,y=21,z=22}
		check(core.get_node(bell).name == "mcl_bells:bell", "fountain retains its hidden bell after liquid settling")
		check(core.get_node({x=114,y=23,z=22}).name == "mcl_core:water_source", "fountain retains its water source after liquid settling")
		for z=15,29 do for x=107,121 do
			if x < 112 or x > 116 or z < 20 or z > 24 then
				for y=21,23 do
					local name = core.get_node({x=x,y=y,z=z}).name
					assert(name ~= "mcl_core:water_source" and name ~= "mcl_core:water_flowing", "water escaped the fountain")
				end
			end
		end end
		check(true, "fountain water remains contained after settling")
		local lv = core.get_modpath("living_villages")
		if lv then
			local gathering = dofile(lv .. "/bell.lua")
			local center = gathering.center_of(bell)
			check(center.x == bell.x and center.y == 21 and center.z == bell.z, "Living Villages finds the forum standing height")
			local spot = gathering.pick_spot(center, "fountain-check")
			check(spot ~= nil and spot.y == 21, "Living Villages finds a standing spot around the fountain")
		else
			checks[#checks + 1] = "SKIP Living Villages bell checks: mod not loaded"
		end
		local f = assert(io.open(core.get_worldpath() .. "/object-check.txt", "w"))
		f:write(table.concat(checks, "\n"), "\n"); f:close()
		core.request_shutdown("Object checks complete", false, 0)
	end)
end

core.register_on_mods_loaded(function() core.after(0, function()
	local failed = false
	core.emerge_area({x=-16,y=0,z=-16}, {x=128,y=48,z=32}, function(_, action, remaining)
		if action == core.EMERGE_CANCELLED or action == core.EMERGE_ERRORED then
			failed = true
			core.log("error", "Object check emerge action " .. tostring(action))
		end
		if remaining == 0 then
			assert(not failed, "could not emerge object check area")
			core.after(0, run)
		end
	end)
end) end)
