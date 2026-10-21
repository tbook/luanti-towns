-- Towns: pure rotation geometry for catalog buildings.
-- No core.* dependency, so it can be tested with plain Lua 5.1.
--
-- Conventions
-- -----------
-- File orientation (shared with ticket #2): the schematic origin is its
-- minimum X/Z corner and bottom Y; size = {x, y, z}; the main entrance is on
-- the -Z edge by default, at file-local offset entrance = {x = ex, y = ey, z = ez}.
-- ez is 0 for a door flush with the edge; ey defaults to 1.
-- The entrance faces -Z in the file orientation unless entrance.facing names
-- another outward axis (-X, +Z, +X). This preserves noncanonical captures.
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
-- Derived from the engine source and confirmed in game: ticket #2 measured
-- placements (docs/building_workflow.md) and ticket #4 re-checked the helper
-- coordinates (door node, chimney) against real placements.

local M = {}

M.ROTATIONS = {0, 90, 180, 270}

-- Outward ("front") unit vector in world X/Z for each rotation.
local FRONT = {
	[0]   = {x =  0, z = -1}, -- -Z
	[90]  = {x = -1, z =  0}, -- -X
	[180] = {x =  0, z =  1}, -- +Z
	[270] = {x =  1, z =  0}, -- +X
}
local FACING = {["-Z"] = 0, ["-X"] = 90, ["+Z"] = 180, ["+X"] = 270}

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

-- Rotate an inclusive file-local X/Z rectangle into the rotated footprint's
-- local coordinates. Used for authored subfeatures such as a gate opening.
function M.rotate_rect(size, r, rotation)
	rotation = check_rotation(rotation)
	if type(size) ~= "table" or type(r) ~= "table"
		or type(size.x) ~= "number" or type(size.z) ~= "number"
		or type(r.x1) ~= "number" or type(r.z1) ~= "number"
		or type(r.x2) ~= "number" or type(r.z2) ~= "number"
		or r.x1 < 0 or r.z1 < 0 or r.x1 > r.x2 or r.z1 > r.z2
		or r.x2 >= size.x or r.z2 >= size.z then
		error("towns: invalid local rectangle", 2)
	end
	local x1, z1 = rotate_local(size.x, size.z, r.x1, r.z1, rotation)
	local x2, z2 = rotate_local(size.x, size.z, r.x2, r.z2, rotation)
	return {x1 = math.min(x1, x2), z1 = math.min(z1, z2),
		x2 = math.max(x1, x2), z2 = math.max(z1, z2)}
end

-- Exterior apron adjoining the full gate wall. `box`, `span` are in the
-- same world/local coordinate space; front points outward from the box.
function M.exterior_apron(box, span, front, depth)
	local function rect_ok(r)
		return type(r) == "table" and type(r.x1) == "number" and type(r.z1) == "number"
			and type(r.x2) == "number" and type(r.z2) == "number"
			and r.x1 <= r.x2 and r.z1 <= r.z2
	end
	if not rect_ok(box) or not rect_ok(span) or type(front) ~= "table"
			or not ((front.x == 0 and math.abs(front.z) == 1)
				or (front.z == 0 and math.abs(front.x) == 1))
			or type(depth) ~= "number" or depth < 1 or depth ~= math.floor(depth) then
		error("towns: invalid gate apron geometry", 2)
	end
	if front.x ~= 0 then
		local edge = (front.x < 0) and box.x1 or box.x2
		if span.x1 ~= edge or span.x2 ~= edge or span.z1 < box.z1 or span.z2 > box.z2 then
			error("towns: gate span is not on the outward box edge", 2)
		end
		if front.x < 0 then return {x1 = box.x1 - depth, z1 = span.z1, x2 = box.x1 - 1, z2 = span.z2} end
		return {x1 = box.x2 + 1, z1 = span.z1, x2 = box.x2 + depth, z2 = span.z2}
	end
	local edge = (front.z < 0) and box.z1 or box.z2
	if span.z1 ~= edge or span.z2 ~= edge or span.x1 < box.x1 or span.x2 > box.x2 then
		error("towns: gate span is not on the outward box edge", 2)
	end
	if front.z < 0 then return {x1 = span.x1, z1 = box.z1 - depth, x2 = span.x2, z2 = box.z1 - 1} end
	return {x1 = span.x1, z1 = box.z2 + 1, x2 = span.x2, z2 = box.z2 + depth}
end

-- entry:    {size = {x=,y=,z=}, entrance = {x=,y=,z=}} (extra fields ignored)
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
	local facing_name = entry.entrance.facing
	if facing_name == nil then facing_name = "-Z" end
	local facing = FACING[facing_name]
	if not facing then error("towns: invalid entrance facing", 2) end
	local front = FRONT[(rotation + facing) % 360]
	local entrance = {x = pos.x + lx, y = pos.y + (entry.entrance.y or 1), z = pos.z + lz}
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
