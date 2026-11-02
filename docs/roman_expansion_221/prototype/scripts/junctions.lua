local root = arg[1]
local planner = dofile(root .. "/src/planner.lua")
local opts = {}
opts.town_type = "roman"
local plan = assert(planner.plan({x = 0, z = 0}, 1, opts))
local function overlap(a, b) return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2 end
local function abuts(a, b)
  if overlap(a, b) then return false end
  local side_x = a.x2 + 1 == b.x1 or b.x2 + 1 == a.x1
  local side_z = a.z2 + 1 == b.z1 or b.z2 + 1 == a.z1
  if side_x then return b.z1 <= a.z2 and a.z1 <= b.z2 end
  if side_z then return b.x1 <= a.x2 and a.x1 <= b.x2 end
  return false
end
for i = 1, #plan.streets do for j = i + 1, #plan.streets do
  local a, b = plan.streets[i], plan.streets[j]
  if overlap(a.rect, b.rect) then print("crossing " .. a.name .. "/" .. b.name) end
  if abuts(a.rect, b.rect) then print("abutment " .. a.name .. "/" .. b.name) end
end end
