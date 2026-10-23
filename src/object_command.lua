-- Manual previews of the small outdoor objects for issue #204.
local towns = ...
local objects = dofile(towns.modpath .. "/schematics/objects/catalog.lua")

core.register_chatcommand("towns_place_object", {
	params = "<oak_tree|garden> [rotation 0|90|180|270]",
	description = "Place an outdoor object ahead of you at your ground level (overwrites its volume).",
	privs = {server = true},
	func = function(name, param)
		local id, angle = param:match("^(%S+)%s*(%S*)$")
		local entry = id and objects[id]
		if not entry then return false, "Choose oak_tree or garden." end
		local rotation = angle == "" and 0 or tonumber(angle)
		if rotation ~= 0 and rotation ~= 90 and rotation ~= 180 and rotation ~= 270 then
			return false, "Rotation must be 0, 90, 180 or 270."
		end
		local player = core.get_player_by_name(name)
		if not player then return false, "You must be in game to use this command." end
		local ok, reason = towns.schematic.validate(entry, towns.modpath)
		if not ok then return false, reason end
		local p, dir = player:get_pos(), player:get_look_dir()
		local length = math.sqrt(dir.x * dir.x + dir.z * dir.z)
		if length < 0.01 then return false, "Look toward the spot where you want the object." end
		local sx, sz = entry.size.x, entry.size.z
		if rotation == 90 or rotation == 270 then sx, sz = sz, sx end
		local ground_y = math.floor(p.y - 0.5)
		local pos = {
			x = math.floor(p.x + dir.x / length * 8 + 0.5) - math.floor(sx / 2),
			y = ground_y - entry.ground_offset,
			z = math.floor(p.z + dir.z / length * 8 + 0.5) - math.floor(sz / 2),
		}
		local max = {x = pos.x + sx - 1, y = pos.y + entry.size.y - 1, z = pos.z + sz - 1}
		local failed = false
		core.emerge_area(pos, max, function(_, action, remaining)
			if action == core.EMERGE_CANCELLED or action == core.EMERGE_ERRORED then failed = true end
			if remaining > 0 then return end
			if failed then return core.chat_send_player(name, "Could not load the placement area.") end
			local placed, message = towns.schematic.place(entry, pos, rotation, towns.modpath)
			core.chat_send_player(name, placed and ("Placed " .. entry.label .. " at (" .. pos.x .. "," ..
				ground_y .. "," .. pos.z .. "), ground level, rotation " .. rotation .. ".") or
				("Could not place object: " .. tostring(message)))
		end)
		return true, "Placing " .. entry.label .. " eight nodes ahead; overwrites its full volume."
	end,
})
