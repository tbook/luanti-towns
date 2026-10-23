-- Expected node names for a Roman capture after schematic.place (issue #188).
-- Pure Lua: the caller passes in src/schematic.lua; core is used only through
-- schematic.wall_name and core.get_item_group. Installed next to init.lua by
-- run.py and loaded by tests/roman_check_expect_tests.lua.
--
-- Every node keeps its template name, except walls: schematic.place renames
-- each wall from its placed neighbours (schematic.wall_name, #178), so the
-- expectation applies the same recompute to the template's own neighbours in
-- placed (rotated) orientation. Template wall names are not authoritative
-- (#187), so comparing raw template names would fail on correct placement.
local M = {}

local function key(o) return o.x .. "," .. o.y .. "," .. o.z end
M.key = key

-- source: a capture as core.read_schematic returns it (size, and data indexed
-- z*sx*sy + y*sx + x + 1 with .name). rotation: 0, 90, 180 or 270.
-- Returns {key(offset) -> expected name}, offsets from the placement origin.
function M.expected_names(source, rotation, schematic)
	local sx, sy = source.size.x, source.size.y
	local cells, template = {}, {}
	for z = 0, source.size.z - 1 do for y = 0, sy - 1 do for x = 0, sx - 1 do
		local o = schematic.rotate_offset(source.size, {x = x, y = y, z = z}, rotation)
		local name = source.data[z * sx * sy + y * sx + x + 1].name
		cells[#cells + 1] = {o = o, name = name}
		template[key(o)] = name
	end end end
	local names = {}
	for _, c in ipairs(cells) do
		local name = c.name
		if core.get_item_group(name, "wall") > 0 then
			name = schematic.wall_name(name, function(dx, dy, dz)
				local n = template[key({x = c.o.x + dx, y = c.o.y + dy, z = c.o.z + dz})]
				return n ~= "air" and n or nil
			end)
		end
		names[key(c.o)] = name
	end
	return names
end

return M
