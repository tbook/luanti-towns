-- lua cells.lua root id x1 x2 z1 z2 y1 y2 : prints each cell name compactly
local root, id = arg[1], arg[2]
local x1,x2,z1,z2,y1,y2 = tonumber(arg[3]),tonumber(arg[4]),tonumber(arg[5]),tonumber(arg[6]),tonumber(arg[7]),tonumber(arg[8])
local read = dofile(root .. "/tests/mts_reader.lua")
local s = read(root .. "/schematics/imports/roman/" .. id .. ".mts")
local function short(n)
  n = n:gsub("^mcl_[%w]*:", ""):gsub("^mesecons[%w_]*:", "m:")
  return n:sub(1, 9)
end
for y = y1, y2 do
  print("y=" .. y)
  local h = "      "
  for x = x1, x2 do h = h .. string.format("%-10s", "x" .. x) end
  print(h)
  for z = z2, z1, -1 do
    local r = string.format("z%-4d ", z)
    for x = x1, x2 do local n = s.at(x, y, z); r = r .. string.format("%-10s", n == "air" and "." or short(n)) end
    print(r)
  end
end
