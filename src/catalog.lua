-- Towns: minimal building catalog.
-- Pure Lua apart from the reader function passed to verify().
--
-- To add a building: capture it in the canonical orientation (origin at the
-- min X/Z corner and bottom Y, entrance on the -Z edge), put the .mts
-- in schematics/, and add one entry below.
-- entrance = file-local offset of the entrance node (x and z are required;
--            y is the door bottom height and defaults to 1).
-- ground_offset = optional depth of the captured foundation below site ground.
-- role = one of "house", "shop", "workshop", "tavern", "well", "cathedral",
--        "castle", "city_hall", "chapel", or "jail" (optional; required for
--        hand-authored entries, omitted by the generated templates).

local M = {}

-- Valid role values for catalog entries.
M.VALID_ROLES = {
	house = true, shop = true, workshop = true, tavern = true,
	well = true, cathedral = true, castle = true, city_hall = true,
	chapel = true, jail = true,
}

local entries = {
	demo_house = {
		path = "schematics/demo_house.mts",
		-- Dimensions and entrance match schematics/demo_house.mts (ticket #2).
		size = {x = 9, y = 8, z = 7},
		entrance = {x = 4, y = 1, z = 0},
		role = "house",
	},
}

-- Workshop exports are generated separately so re-capturing a building does
-- not require hand-editing dimensions or entrance offsets here.
local source = debug.getinfo(1, "S").source:sub(2)
local modpath = source:match("^(.*)/src/catalog.lua$") or "."
local imported = dofile(modpath .. "/schematics/templates/catalog.lua")
for id, entry in pairs(imported) do entries[id] = entry end

for id, e in pairs(entries) do
	e.id = id
	-- Normalize entrance.y to default of 1 if not provided.
	if e.entrance then
		e.entrance.y = e.entrance.y or 1
	end
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

-- Sorted list of ids, excluding invalid entries.
function M.ids()
	local ids = {}
	for id in pairs(entries) do
		if not M.invalid[id] then
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	return ids
end

-- Sorted list of ids matching a role, excluding invalid entries.
-- Returns an empty table if the role doesn't match any valid entries.
function M.ids_for_role(role)
	local ids = {}
	for id in pairs(entries) do
		if not M.invalid[id] and (not role or entries[id].role == role) then
			ids[#ids + 1] = id
		end
	end
	table.sort(ids)
	return ids
end

-- Deep copy of valid entries only, usable by pure planners without dependencies.
-- Returns {id -> {size, entrance, ground_offset, role, path}}.
function M.snapshot()
	local snap = {}
	for id in pairs(entries) do
		if not M.invalid[id] then
			local e = entries[id]
			snap[id] = {
				size = {x = e.size.x, y = e.size.y, z = e.size.z},
				entrance = {x = e.entrance.x, y = e.entrance.y or 1, z = e.entrance.z or 0},
				role = e.role,
				path = e.path,
			}
			if e.ground_offset then
				snap[id].ground_offset = e.ground_offset
			end
			if e.excluded_resident_beds then
				snap[id].excluded_resident_beds = e.excluded_resident_beds
			end
		end
	end
	return snap
end

-- Checks every entry's schematic against its declared size and structure.
--   read(path) -> {size = {x,y,z}} or nil   (wraps core.read_schematic)
--   modpath    prefix for the repo-local paths
-- Fills M.invalid and returns it. Does not raise, so a missing file does not
-- stop the mod loading; users of an entry should check M.invalid[id].
-- Validates: size (present, integer, positive), entrance x/y/z (present,
-- integer; y defaults to 1), role (valid if present), ground_offset (non-negative integer).
function M.verify(read, modpath)
	M.invalid = {}
	for id in pairs(entries) do
		local e = entries[id]
		local full = modpath .. "/" .. e.path
		local msg

		-- Structural validation: no crashes on nil fields.
		if type(e.size) ~= "table" or not e.size.x or not e.size.y or not e.size.z then
			msg = "size missing or incomplete"
		elseif type(e.size.x) ~= "number" or type(e.size.y) ~= "number" or type(e.size.z) ~= "number"
				or e.size.x <= 0 or e.size.y <= 0 or e.size.z <= 0
				or e.size.x ~= math.floor(e.size.x) or e.size.y ~= math.floor(e.size.y) or e.size.z ~= math.floor(e.size.z) then
			msg = "size not positive integers"
		elseif type(e.entrance) ~= "table" or not e.entrance.x or e.entrance.z == nil then
			msg = "entrance missing x or z"
		elseif type(e.entrance.x) ~= "number" or type(e.entrance.z) ~= "number"
				or e.entrance.x ~= math.floor(e.entrance.x) or e.entrance.z ~= math.floor(e.entrance.z) then
			msg = "entrance x/z not integers"
		elseif e.entrance.y and (type(e.entrance.y) ~= "number" or e.entrance.y ~= math.floor(e.entrance.y)) then
			msg = "entrance y not an integer"
		end

		if not msg then
			-- Use normalized y value.
			local ey = e.entrance.y or 1
			local ez = e.entrance.z
			if e.entrance.x < 0 or e.entrance.x >= e.size.x or ez < 0 or ez >= e.size.z then
				msg = "entrance offset outside the schematic"
			elseif ey < 0 or ey >= e.size.y then
				msg = "entrance height outside the schematic"
			elseif e.role and not M.VALID_ROLES[e.role] then
				msg = "invalid role '" .. tostring(e.role) .. "'"
			elseif e.ground_offset and (type(e.ground_offset) ~= "number" or e.ground_offset < 0 or e.ground_offset >= e.size.y
					or e.ground_offset ~= math.floor(e.ground_offset)) then
				msg = "ground offset outside the schematic"
			elseif e.excluded_resident_beds ~= nil then
				if type(e.excluded_resident_beds) ~= "table" then
					msg = "excluded resident beds must be a list"
				else
					for _, p in ipairs(e.excluded_resident_beds) do
						if type(p) ~= "table" or type(p.x) ~= "number" or type(p.y) ~= "number"
								or type(p.z) ~= "number" or p.x ~= math.floor(p.x) or p.y ~= math.floor(p.y)
								or p.z ~= math.floor(p.z) or p.x < 0 or p.x >= e.size.x
								or p.y < 0 or p.y >= e.size.y or p.z < 0 or p.z >= e.size.z then
							msg = "excluded resident bed offset outside the schematic"
							break
						end
					end
				end
			end
		end

		if not msg then
			-- Schematic file check (only for non-invalid entries).
			local ok, s = pcall(read, full)
			if not ok then
				msg = "schematic read failed: " .. tostring(s)
			elseif not s or not s.size then
				msg = "schematic missing or unreadable"
			elseif s.size.x ~= e.size.x or s.size.y ~= e.size.y or s.size.z ~= e.size.z then
				msg = string.format("size mismatch: catalog declares %dx%dx%d, file is %dx%dx%d",
					e.size.x, e.size.y, e.size.z, s.size.x, s.size.y, s.size.z)
			end
		end

		if msg then
			M.invalid[id] = string.format("towns: building '%s' (%s): %s", id, full, msg)
		end
	end
	return M.invalid
end

return M
