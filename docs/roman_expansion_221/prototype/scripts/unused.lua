local root = arg[1]
local planner = dofile(root .. "/src/planner.lua")
local opts = {}
opts.town_type = "roman"
local plan = assert(planner.plan({x = 0, z = 0}, 1, opts))
local occ = {}
local function k(x, z) return x .. "," .. z end
local function paint(r) for z = r.z1, r.z2 do for x = r.x1, r.x2 do occ[k(x, z)] = true end end end
for _, s in ipairs(plan.streets) do paint(s.rect) end
for _, s in pairs(plan.sites) do paint(s.rect) end
local blk = 0
for _, b in ipairs(plan.blocks) do paint(b.rect); blk = blk + (b.rect.x2 - b.rect.x1 + 1) * (b.rect.z2 - b.rect.z1 + 1) end
local m = plan.boundary.rects[1]
local free, inner = 0, 0
for z = m.z1 + 4, m.z2 - 4 do for x = m.x1 + 4, m.x2 - 4 do
  inner = inner + 1
  if not occ[k(x, z)] then free = free + 1 end
end end
print(string.format("inset main rect cells %d, block cells %d, unused (not street/square/landmark/block) %d (%.1f%%)", inner, blk, free, 100 * free / inner))
