-- usage: lua walk.lua root id gx gy gz [sx sy sz]
-- BFS walk from start (default: every outside ring cell at ground) to goal
-- feet cell (gx,gy,gz) in FILE coordinates. Outside the footprint the world is
-- flat ground with surface at y = ground_offset (feet at ground_offset+1).
local root, id = arg[1], arg[2]
local gx, gy, gz = tonumber(arg[3]), tonumber(arg[4]), tonumber(arg[5])
local sx0, sy0, sz0 = tonumber(arg[6]), tonumber(arg[7]), tonumber(arg[8])
local read = dofile(root .. "/tests/mts_reader.lua")
local cat = dofile(root .. "/schematics/imports/roman/catalog.lua")
local s = read(root .. "/schematics/imports/roman/" .. id .. ".mts")
local go = cat[id].ground_offset
local SX, SY, SZ = s.size.x, s.size.y, s.size.z
local function passable_name(n)
  if n == "air" then return true end
  if n:find("door_") and not n:find("trapdoor") then return true end
  if n:find("trapdoor_open") then return true end
  if n:find("torch") or n:find("sign") or n:find("itemframe") or n:find("lantern")
    or n:find("mesecons:wire") or n:find("pressure") or n:find("lever") or n:find("ladder")
    or n:find("fence_gate") then return true end
  return false
end
local function node(x, y, z)
  if x < 0 or z < 0 or x >= SX or z >= SZ then
    if y <= go then return "OUTSIDE_GROUND" end
    return "air"
  end
  if y < 0 then return "BELOW" end
  if y >= SY then return "air" end
  return (s.at(x, y, z))
end
local function pass(x, y, z) return passable_name(node(x, y, z)) end
local function standable(x, y, z)
  local below = node(x, y - 1, z)
  return pass(x, y, z) and pass(x, y + 1, z) and (not passable_name(below) or below:find("ladder") or node(x,y,z):find("ladder"))
end
local function inrange(x, z) return x >= -2 and z >= -2 and x <= SX + 1 and z <= SZ + 1 end
local key = function(x, y, z) return x .. "," .. y .. "," .. z end
local queue, prev, qi = {}, {}, 1
local function push(x, y, z, from)
  local k = key(x, y, z)
  if prev[k] ~= nil then return end
  prev[k] = from or false; queue[#queue + 1] = {x, y, z}
end
if sx0 then push(sx0, sy0, sz0) else
  for x = -1, SX do push(x, go + 1, -1); push(x, go + 1, SZ) end
  for z = 0, SZ - 1 do push(-1, go + 1, z); push(SX, go + 1, z) end
end
local goalk = key(gx, gy, gz)
while qi <= #queue do
  local p = queue[qi]; qi = qi + 1
  local k = key(p[1], p[2], p[3])
  if k == goalk then break end
  for _, d in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
    local nx, nz = p[1] + d[1], p[3] + d[2]
    if inrange(nx, nz) then
      -- same level, step up (jump: needs head room above start), drop up to 3
      for _, dy in ipairs({0, 1, -1, -2, -3}) do
        local ny = p[2] + dy
        local ok = standable(nx, ny, nz)
        if ok and dy == 1 and not pass(p[1], p[2] + 2, p[3]) then ok = false end
        if ok and dy < 0 then for yy = ny + 1, p[2] + 1 do if not pass(nx, yy, nz) then ok = false end end end
        if ok then push(nx, ny, nz, k); break end
      end
    end
  end
  -- ladders: vertical
  for _, dy in ipairs({1, -1}) do
    if node(p[1], p[2], p[3]):find("ladder") or node(p[1], p[2] + dy, p[3]):find("ladder") then
      if pass(p[1], p[2] + dy, p[3]) and pass(p[1], p[2] + dy + 1, p[3]) then push(p[1], p[2] + dy, p[3], k) end
    end
  end
end
if prev[goalk] == nil then print("UNREACHABLE " .. goalk .. " (" .. node(gx,gy,gz) .. ", below " .. node(gx,gy-1,gz) .. ")") os.exit(1) end
local path, k = {}, goalk
while k do table.insert(path, 1, k); k = prev[k] end
print("REACHED " .. goalk .. " in " .. (#path - 1) .. " steps from " .. path[1])
for _, c in ipairs(path) do
  local x, y, z = c:match("(-?%d+),(-?%d+),(-?%d+)")
  x, y, z = tonumber(x), tonumber(y), tonumber(z)
  print(string.format("  %-12s feet=%-28s floor=%s", c, node(x,y,z), node(x,y-1,z)))
end
