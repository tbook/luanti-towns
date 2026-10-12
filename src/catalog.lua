-- Towns: minimal building catalog.
-- Pure Lua apart from the reader function passed to verify().
--
-- To add a building: capture it in the canonical orientation (origin at the
-- min X/Z corner and bottom Y, entrance on the north/-Z edge), put the .mts
-- in schematics/, and add one entry below.
-- entrance = file-local offset of the entrance node (z is 0 unless recessed).
-- ground_offset = optional depth of the captured foundation below site ground.

local M = {}

local entries = {
	demo_house = {
		path = "schematics/demo_house.mts",
		-- Dimensions and entrance match schematics/demo_house.mts (ticket #2).
		size = {x = 9, y = 8, z = 7},
		entrance = {x = 4, y = 1, z = 0},
	},
	castle = {
		path = "schematics/castle.mts",
		size = {x = 54, y = 40, z = 50},
		-- The gate is recessed six nodes from the file's -Z edge.
		entrance = {x = 30, y = 8, z = 6},
		-- The capture includes five foundation layers below the site's ground.
		ground_offset = 5,
		role = "landmark",
	},
}

for id, e in pairs(entries) do
	e.id = id
end

M.entries = entries
-- id -> error message for entries that failed verify(); filled at startup.
M.invalid = {}

-- Returns the entry for id (entries carry their .id); errors on an unknown id.
function M.get(id)
	local e = entries[id]
	if not e then
		error("towns: unknown building id '" .. tostring(id) .. "'", 2)
	end
	return e
end

-- Sorted list of ids, for stable iteration.
function M.ids()
	local ids = {}
	for id in pairs(entries) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end

-- Checks every entry's schematic against its declared size.
--   read(path) -> {size = {x,y,z}} or nil   (wraps core.read_schematic)
--   modpath    prefix for the repo-local paths
-- Fills M.invalid and returns it. Does not raise, so a missing file does not
-- stop the mod loading; users of an entry should check M.invalid[id].
function M.verify(read, modpath)
	M.invalid = {}
	for _, id in ipairs(M.ids()) do
		local e = entries[id]
		local full = modpath .. "/" .. e.path
		local ok, s = pcall(read, full)
		local ez = e.entrance.z or 0
		local msg
		if not ok then
			msg = "schematic read failed: " .. tostring(s)
		elseif not s or not s.size then
			msg = "schematic missing or unreadable"
		elseif s.size.x ~= e.size.x or s.size.y ~= e.size.y or s.size.z ~= e.size.z then
			msg = string.format("size mismatch: catalog declares %dx%dx%d, file is %dx%dx%d",
				e.size.x, e.size.y, e.size.z, s.size.x, s.size.y, s.size.z)
		elseif e.entrance.x < 0 or e.entrance.x >= e.size.x
				or ez < 0 or ez >= e.size.z then
			msg = "entrance offset outside the schematic"
		elseif e.entrance.y and (e.entrance.y < 0 or e.entrance.y >= e.size.y) then
			msg = "entrance height outside the schematic"
		elseif e.ground_offset and (e.ground_offset < 0 or e.ground_offset >= e.size.y
				or e.ground_offset ~= math.floor(e.ground_offset)) then
			msg = "ground offset outside the schematic"
		end
		if msg then
			M.invalid[id] = string.format("towns: building '%s' (%s): %s", id, full, msg)
		end
	end
	return M.invalid
end

return M
