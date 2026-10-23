-- Manual placement for Issue 139 assets. These remain outside the town catalog.
local towns = ...
local ids = {"domus", "arch", "theatre", "villa", "aqueduct", "amphitheater", "temple", "bath", "insula"}
local known = {}
for _, id in ipairs(ids) do known[id] = true end

core.register_chatcommand("towns_import_roman", {
	params = "<building_id> [rotation 0|90|180|270]",
	description = "Manually place an Issue 139 Roman import near you (overwrites its volume).",
	privs = {server = true},
	func = function(name, param)
		local id, rotation = param:match("^(%S+)%s*(%S*)$")
		if not id or not known[id] then
			return false, "Choose one of: " .. table.concat(ids, ", ")
		end
		rotation = rotation == "" and 0 or tonumber(rotation)
		if rotation ~= 0 and rotation ~= 90 and rotation ~= 180 and rotation ~= 270 then
			return false, "Rotation must be 0, 90, 180 or 270."
		end
		local player = core.get_player_by_name(name)
		if not player then return false, "You must be in game to use this command." end
		local pos = player:get_pos()
		local dir = player:get_look_dir()
		local place = {x = math.floor(pos.x + dir.x * 4 + 0.5),
			y = math.floor(pos.y + 0.5), z = math.floor(pos.z + dir.z * 4 + 0.5)}
		local entry = {id = id, path = "schematics/imports/roman/" .. id .. ".mts",
			data_path = "schematics/imports/roman/" .. id .. ".lua"}
		local ok, reason = towns.schematic.validate(entry, towns.modpath)
		if not ok then return false, reason end
		local schematic = assert(core.read_schematic(towns.modpath .. "/" .. entry.path, {}))
		local size_x, size_z = schematic.size.x, schematic.size.z
		if rotation == 90 or rotation == 270 then size_x, size_z = size_z, size_x end
		local max = {x = place.x + size_x - 1, y = place.y + schematic.size.y - 1,
			z = place.z + size_z - 1}
		local failed = false
		core.emerge_area(place, max, function(_, action, remaining)
			if action == core.EMERGE_CANCELLED or action == core.EMERGE_ERRORED then failed = true end
			if remaining > 0 then return end
			if failed then return core.chat_send_player(name, "Error: Could not load the placement area.") end
			local placed, message = towns.schematic.place(entry, place, rotation, towns.modpath)
			core.chat_send_player(name, placed and ("Placed " .. id .. " at (" .. place.x .. "," .. place.y .. "," .. place.z .. ")" ..
				" (rotation " .. rotation .. ").") or ("Error: " .. message))
		end)
		return true, "Importing " .. id .. " in front of you; the schematic overwrites its full volume."
	end,
})
