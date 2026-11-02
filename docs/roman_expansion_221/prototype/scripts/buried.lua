local root = arg[1]
local read = dofile(root .. "/tests/mts_reader.lua")
local s = read(root .. "/schematics/imports/roman/hippodrome.mts")
local lowest, edge, count = nil, 0, 0
for y = 0, 6 do for z = 0, 24 do for x = 0, 36 do
  local n = s.at(x, y, z)
  if n == "air" or n:find("ladder") or n:find("torch") then
    count = count + 1
    lowest = lowest and math.min(lowest, y) or y
    if x == 0 or x == 36 or z == 0 or z == 24 then edge = edge + 1 end
  end
end end end
local solid0 = 0
for z = 0, 24 do for x = 0, 36 do if s.at(x, 0, z) ~= "air" then solid0 = solid0 + 1 end end end
print("buried non-solid cells", count, "lowest y", lowest, "on footprint edge", edge, "solid cells in y=0 layer", solid0, "of", 37 * 25)
