-- Developer-only lookup of persisted accepted towns (#399). No terrain access.
local M = {}

function M.message(records, pos)
	local r, distance, code = records:nearest(pos)
	if not r then
		if code then return "Could not look up a town: " .. tostring(distance) end
		return "No accepted towns have been recorded."
	end
	return ("Nearest town record: status=%s, seed=%d, type=%s, center=(%d, %d, %d), distance=%.0f nodes.")
		:format(r.state, r.seed, r.town_type, r.center.x, r.center.y, r.center.z, distance)
end

function M.register(c, records)
	c.register_chatcommand("towns_nearest", {
		params = "",
		description = "Show the nearest recorded automatic town (developer only).",
		privs = {server = true},
		func = function(name)
			local player = c.get_player_by_name(name)
			if not player then return false, "You must be online to look up the nearest recorded town." end
			local ok, pos = pcall(function() return player:get_pos() end)
			if not ok or type(pos) ~= "table" then return false, "Could not read your position." end
			local message = M.message(records, pos)
			if message:match("^Could not look up") then return false, message end
			return true, message
		end,
	})
end

return M
