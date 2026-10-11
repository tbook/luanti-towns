-- Towns: pure rotation geometry for catalog buildings.
-- No core.* dependency, so it can be tested with plain Lua 5.1.
--
-- Conventions
-- -----------
-- File orientation (shared with ticket #2): the schematic origin is its
-- minimum X/Z corner and bottom Y; size = {x, y, z}; the main entrance is on
-- the -Z edge (the file's z = 0 row), at file-local offset
-- entrance = {x = ex, z = ez} (ez is 0 for a door flush with that edge).
-- The entrance faces -Z in the file orientation.
--
-- World axes: +X east, +Z north, +Y up. So -Z is geographically SOUTH in
-- Luanti; the issue text calls the entrance side "north", which is just a
-- label for the -Z edge. This file uses axis names (-Z, +X, ...) only.
--
-- Rotation: core.place_schematic(pos, schem, "90"/"180"/"270") is passed
-- the minimum corner of the *rotated* footprint. Luanti's placement
-- (Schematic::placeOnMap, mapgen/mg_schematic.cpp) maps file-local (x, z) to
-- rotated-local coordinates, with sx/sz the file size X/Z:
--     0   : (x, z) -> (x,        z)
--     90  : (x, z) -> (z,        sx-1-x)   footprint is sz wide, sx deep
--     180 : (x, z) -> (sx-1-x,   sz-1-z)
--     270 : (x, z) -> (sz-1-z,   x)        footprint is sz wide, sx deep
-- i.e. the direction the entrance faces goes -Z (file) -> -X at 90 ->
-- +Z at 180 -> +X at 270. Seen from above with +X east and +Z north that is
-- a clockwise turn (south -> west -> north -> east).
-- This was derived from the engine source, NOT yet verified in game
-- (lua_api.md does not state the direction); ticket #4 must confirm it
-- against a real placement. If it turns out mirrored, swap the 90 and 270
-- branches in rotate_local() and the FRONT table; nothing else depends on it.

local M = {}

M.ROTATIONS = {0, 90, 180, 270}

-- Outward ("front") unit vector in world X/Z for each rotation.
local FRONT = {
	[0]   = {x =  0, z = -1}, -- -Z
	[90]  = {x = -1, z =  0}, -- -X
	[180] = {x =  0, z =  1}, -- +Z
	[270] = {x =  1, z =  0}, -- +X
}

local function check_rotation(rotation)
	local n = rotation
	if type(n) == "string" then
		-- Exact strings only: no hex, exponent, whitespace or signs.
		if n == "0" or n == "90" or n == "180" or n == "270" then
			n = tonumber(n)
		else
			n = nil
		end
	end
	if n ~= 0 and n ~= 90 and n ~= 180 and n ~= 270 then
		error("towns: invalid rotation " .. tostring(rotation)
			.. " (expected 0, 90, 180 or 270)", 3)
	end
	return n
end

-- Map a file-local (x, z) to rotated-local (x, z).
local function rotate_local(sx, sz, x, z, rotation)
	if rotation == 0 then
		return x, z
	elseif rotation == 90 then
		return z, sx - 1 - x
	elseif rotation == 180 then
		return sx - 1 - x, sz - 1 - z
	else -- 270
		return sz - 1 - z, x
	end
end

-- entry:    {size = {x=,y=,z=}, entrance = {x=, z=}} (extra fields ignored)
-- pos:      minimum corner {x,y,z} of the rotated footprint, as passed to
--           core.place_schematic
-- rotation: 0, 90, 180, 270 (number or numeric string)
--
-- Returns a table:
--   rotation  number
--   size      {x,y,z} rotated footprint size
--   min, max  inclusive occupied bounds (world coords)
--   entrance  world position of the entrance node (inside the footprint)
--   front     outward unit vector {x=,z=}
--   outside   world position one node out from the entrance, along front
function M.place(entry, pos, rotation)
	rotation = check_rotation(rotation)
	local sx, sy, sz = entry.size.x, entry.size.y, entry.size.z
	local wx, wz = sx, sz
	if rotation == 90 or rotation == 270 then
		wx, wz = sz, sx
	end

	local lx, lz = rotate_local(sx, sz, entry.entrance.x, entry.entrance.z or 0, rotation)
	local front = FRONT[rotation]
	local entrance = {x = pos.x + lx, y = pos.y, z = pos.z + lz}
	return {
		rotation = rotation,
		size = {x = wx, y = sy, z = wz},
		min = {x = pos.x, y = pos.y, z = pos.z},
		max = {x = pos.x + wx - 1, y = pos.y + sy - 1, z = pos.z + wz - 1},
		entrance = entrance,
		front = {x = front.x, z = front.z},
		outside = {x = entrance.x + front.x, y = entrance.y, z = entrance.z + front.z},
	}
end

return M
