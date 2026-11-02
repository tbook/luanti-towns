local root, id, y, z = arg[1], arg[2], tonumber(arg[3]), tonumber(arg[4])
local read = dofile(root .. "/tests/mts_reader.lua")
local s = read(root .. "/schematics/imports/roman/" .. id .. ".mts")
local gaps = {}
for x = 0, s.size.x - 1 do if s.at(x, y, z) == "air" and s.at(x, y + 1, z) == "air" then gaps[#gaps + 1] = x end end
print(id .. " y" .. y .. " z" .. z .. " feet+head air at x: " .. table.concat(gaps, ","))
