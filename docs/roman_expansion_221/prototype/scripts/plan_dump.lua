-- usage: lua plan_dump.lua ROOT [cx cz seed]
local root = arg[1]
local cx, cz, seed = tonumber(arg[2] or 0), tonumber(arg[3] or 0), tonumber(arg[4] or 1)
local planner = dofile(root .. "/src/planner.lua")
local opts = {}
opts.town_type = "roman"
local plan, why = planner.plan({x = cx, z = cz}, seed, opts)
if not plan then print("FAILED", why) os.exit(1) end
local function R(r) return string.format("x %d..%d  z %d..%d  (%dx%d)", r.x1 - cx, r.x2 - cx, r.z1 - cz, r.z2 - cz, r.x2 - r.x1 + 1, r.z2 - r.z1 + 1) end
print("bounds", R(plan.bounds))
for i, r in ipairs(plan.boundary.rects) do print("boundary " .. i, R(r)) end
for _, n in ipairs(plan.site_order) do local s = plan.sites[n]
  print(string.format("site %-18s %-8s %-14s rot=%-4s %s", n, s.kind, tostring(s.id), tostring(s.rotation), R(s.rect)),
    s.approach and string.format("approach %d,%d", s.approach.pos.x - cx, s.approach.pos.z - cz) or "",
    s.entrance and string.format("entrance %d,%d facing %d,%d", s.entrance.x - cx, s.entrance.z - cz, s.facing.x, s.facing.z) or "") end
for i, s in ipairs(plan.streets) do print(string.format("street %2d %-16s %-9s %s", i, s.name, s.kind, R(s.rect)), s.lane and ("lane " .. R(s.lane.rect)) or "") end
for i, b in ipairs(plan.blocks) do
  local fr = {}
  for _, f in ipairs(b.frontage) do local F = plan.frontage[f]; fr[#fr+1] = F.side .. ":" .. F.length .. "=" .. tostring(F.square or F.street_name) end
  print(string.format("block %2d %-24s %s  runs %s", i, b.name, R(b.rect), table.concat(fr, " ")))
end
local counts = {}
counts.house, counts.shop, counts.workshop = 0, 0, 0
for _, c in ipairs(plan.content or {}) do counts[c.role] = (counts[c.role] or 0) + 1 end
print("content", #(plan.content or {}), "house", counts.house, "shop", counts.shop, "workshop", counts.workshop)
for k, v in pairs(plan.reservations or {}) do print("reservation", k, type(v) == "table" and #v or v) end
for _, sh in ipairs(plan.shortages or {}) do print("shortage", sh.role or sh.kind, sh.reason or sh.code or "") end
