-- usage: lua map.lua ROOT [scale] : plan-only overhead (no buildings); offsets from centre
local root, S = arg[1], tonumber(arg[2] or 2)
local planner = dofile(root .. "/src/planner.lua")
local opts = {}
opts.town_type = "roman"
local plan = assert(planner.plan({x = 0, z = 0}, 1, opts))
local cell = {}
local function k(x, z) return x .. "," .. z end
local function paint(r, ch) for z = r.z1, r.z2 do for x = r.x1, r.x2 do cell[k(x, z)] = ch end end end
for _, r in ipairs(plan.boundary.rects) do paint(r, ".") end
local BL = "abcdefghijklmnopqrstuvwxyz"; for i, b in ipairs(plan.blocks) do paint(b.rect, BL:sub(i, i)); print(BL:sub(i, i) .. " = block " .. b.name) end
for _, s in ipairs(plan.streets) do paint(s.rect, s.kind == "principal" and "#" or "=") end
local labels = {}
local LL = "ABCDEFGHIJKLMNOPRSTUVWXYZ"; local li = 0; for _, n in ipairs(plan.site_order) do local s = plan.sites[n]; if s.kind == "square" then paint(s.rect, "Q") else li = li + 1; paint(s.rect, LL:sub(li, li)); print(LL:sub(li, li) .. " = " .. n) end end
local PRI = {["L"] = 6, ["Q"] = 5, ["#"] = 4, ["="] = 3, [","] = 2, ["."] = 1}
local b = plan.bounds
for z = b.z2 - (b.z2 - b.z1) % S, b.z1, -S do
  local row = string.format("%4d ", z)
  for x = b.x1, b.x2, S do
    local best, bp = " ", 0
    for dz = 0, S - 1 do for dx = 0, S - 1 do
      local c = cell[k(x + dx, z + dz)]
      local p = c and (PRI[c] or (c:match("%u") and 6 or 2)); if p and p > bp then best, bp = c, p end
    end end
    row = row .. best
  end
  print(row)
end
local h = "     "
for x = b.x1, b.x2, S do h = h .. ((x % 20 == 0 or (x + 1) % 20 == 0 and S == 2) and "|" or " ") end
print(h)
print("x from " .. b.x1 .. " step " .. S .. "; '|' marks multiples of 20")
