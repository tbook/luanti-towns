-- usage: lua route_check.lua ROOT id rotation ex ey ez [facing]
local root, id, rotation = arg[1], arg[2], tonumber(arg[3])
local e = {}
e.x, e.y, e.z, e.facing = tonumber(arg[4]), tonumber(arg[5]), tonumber(arg[6]), arg[7]
local geometry = dofile(root .. "/src/geometry.lua")
local placement = dofile(root .. "/src/placement.lua")
local planner = dofile(root .. "/src/planner.lua")
local builder = dofile(root .. "/src/builder.lua")(placement, planner)
local schem = dofile(root .. "/src/schematic.lua")
local read_mts = dofile(root .. "/tests/mts_reader.lua")
local cat = dofile(root .. "/schematics/imports/roman/catalog.lua")
local entry = cat[id]
local function info_of(name)
  if name == "air" then local t = {}; t.walkable = false; t.liquid = false; return t end
  local nonwalk = name:find("torch", 1, true) or name:find("_open", 1, true)
    or name:find("flower", 1, true) or name:find("lantern", 1, true)
    or name:find("sign", 1, true) or name:find("banner", 1, true)
    or name:find("rail", 1, true) or name:find("button", 1, true)
    or name:find("plate", 1, true) or name:find("ladder", 1, true)
  local reg = {}
  reg[name] = {}
  reg[name].walkable = not nonwalk
  return placement.node_info(reg, name)
end
local s = read_mts(root .. "/" .. entry.path)
local g = 40
local pos = {}
pos.x, pos.y, pos.z = 100, g - (entry.ground_offset or 0), 100
local ent = {}
ent.size = entry.size; ent.entrance = e
local b = geometry.place(ent, pos, rotation)
local box = {}
box.rect = {}
box.rect.x1, box.rect.z1, box.rect.x2, box.rect.z2 = b.min.x, b.min.z, b.max.x, b.max.z
box.rotation, box.min, box.max, box.entrance = b.rotation, b.min, b.max, b.entrance
local inv = {}
for z = 0, s.size.z - 1 do for x = 0, s.size.x - 1 do
  local o = schem.rotate_offset(s.size, {x = x, y = 0, z = z}, rotation)
  inv[(pos.x + o.x) .. "," .. (pos.z + o.z)] = {x, z}
end end
local function node(x, y, z)
  local f = inv[x .. "," .. z]
  local name
  if f and y >= pos.y and y <= b.max.y then name = s.at(f[1], y - pos.y, f[2])
  elseif y <= g then name = "mcl_core:stonebrick" else name = "air" end
  return info_of(name), name
end
local r, why = builder.check_door(box, g, node)
if r then
  print(string.format("%s rot %d: entrance local(%d,%d) front(%d,%d) approach local(%d,%d) steps %d",
    id, rotation, b.entrance.x - pos.x, b.entrance.z - pos.z, b.front.x, b.front.z, r.approach.x - pos.x, r.approach.z - pos.z, r.steps))
else print(id .. " rot " .. rotation .. ": UNREACHABLE " .. tostring(why)) end
