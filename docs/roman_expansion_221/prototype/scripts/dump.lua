-- usage: lua dump.lua root id [y1 y2]
local root, id, y1, y2 = arg[1], arg[2], tonumber(arg[3]), tonumber(arg[4])
local read = dofile(root .. "/tests/mts_reader.lua")
local s = read(root .. "/schematics/imports/roman/" .. id .. ".mts")
local sx, sy, sz = s.size.x, s.size.y, s.size.z
print(id, sx, sy, sz)
local chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@$%&*+=?<>/"
local map, n, legend = {}, 0, {}
local function ch(name)
  if name == "air" then return " " end
  if not map[name] then n = n + 1; map[name] = chars:sub(n, n); legend[#legend+1] = map[name] .. " " .. name end
  return map[name]
end
for y = (y1 or 0), (y2 or sy - 1) do
  print("--- y=" .. y .. "  (rows z from " .. (sz-1) .. " down to 0; cols x 0.." .. (sx-1) .. ")")
  local hdr = "     "
  for x = 0, sx - 1 do hdr = hdr .. (x % 10) end
  print(hdr)
  for z = sz - 1, 0, -1 do
    local row = string.format("%3d  ", z)
    for x = 0, sx - 1 do row = row .. ch((s.at(x, y, z))) end
    print(row)
  end
end
for _, l in ipairs(legend) do print(l) end
