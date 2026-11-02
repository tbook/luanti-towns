local root, id, pat = arg[1], arg[2], arg[3]
local read = dofile(root .. "/tests/mts_reader.lua")
local s = read(root .. "/schematics/imports/roman/" .. id .. ".mts")
for y = 0, s.size.y - 1 do for z = 0, s.size.z - 1 do for x = 0, s.size.x - 1 do
  local n, p2 = s.at(x, y, z)
  if n:find(pat) then print(x, y, z, n, p2) end
end end end
