-- usage: lua census.lua ROOT  : per-seed and per-block ordinary census, services, bed estimate
local root = arg[1]
local planner = dofile(root .. "/src/planner.lua")
local catalog = dofile(root .. "/src/catalog.lua")
local read = dofile(root .. "/tests/mts_reader.lua")
local beds = {}
local function bed_count(id)
  if beds[id] then return beds[id] end
  local e = catalog.entries[id]
  local s = read(root .. "/" .. e.path)
  local n = 0
  for y = 0, s.size.y - 1 do for z = 0, s.size.z - 1 do for x = 0, s.size.x - 1 do
    local nm = s.at(x, y, z)
    if nm:find("^mcl_beds:") and nm:find("_bottom$") then n = n + 1 end
  end end end
  beds[id] = n
  return n
end
local seeds = {1, 2, 3, 7}
local centres = {{0, 0}, {1500, -2500}, {-4200, 3100}}
local extra = arg[2]
if extra then centres = {{ tonumber(arg[2]), tonumber(arg[3]) }} end
local per_block, tot = {}, {}
tot.house, tot.shop, tot.workshop, tot.all, tot.beds, tot.lbeds = 0, 0, 0, 0, 0, 0
for i, seed in ipairs(seeds) do
  local c = centres[(i - 1) % #centres + 1]
  local opts = {}
  opts.town_type = "roman"
  local plan, why = planner.plan({x = c[1], z = c[2]}, seed, opts)
  if not plan then print("seed " .. seed .. " FAILED " .. tostring(why)) else
    local cnt = {}
    cnt.house, cnt.shop, cnt.workshop = 0, 0, 0
    local b = 0
    for _, bd in ipairs(plan.content.buildings) do
      cnt[bd.role] = cnt[bd.role] + 1
      b = b + bed_count(bd.building_id)
      local name = plan.blocks[bd.block].name
      per_block[name] = per_block[name] or {}
      per_block[name][seed] = (per_block[name][seed] or 0) + 1
    end
    local lb = 0
    for _, s in pairs(plan.sites) do if s.kind == "landmark" then lb = lb + bed_count(s.id) end end
    local res = plan.reservations or {}
    local sv = {}
    for _, s in ipairs(res.services or {}) do sv[#sv + 1] = (s.role or s.id or "?") .. "@" .. plan.blocks[s.block].name end
    local all = cnt.house + cnt.shop + cnt.workshop
    print(string.format("seed %d centre %d,%d: ordinary %d (house %d shop %d workshop %d) ordinary-beds %d landmark-beds %d jail %s shortages %d",
      seed, c[1], c[2], all, cnt.house, cnt.shop, cnt.workshop, b, lb,
      res.jail and plan.blocks[res.jail.block].name or "NONE", #(plan.shortages or {})))
    print("   services: " .. table.concat(sv, " "))
    for _, sh in ipairs(plan.shortages or {}) do print("   shortage: " .. tostring(sh.role) .. " " .. tostring(sh.reason or sh.code)) end
    tot.house, tot.shop, tot.workshop, tot.all = tot.house + cnt.house, tot.shop + cnt.shop, tot.workshop + cnt.workshop, tot.all + all
    tot.beds, tot.lbeds = tot.beds + b, tot.lbeds + lb
    local bmin, bmax = plan.bounds, nil
    print(string.format("   bounds %dx%d boundary rects %d", plan.bounds.x2 - plan.bounds.x1 + 1, plan.bounds.z2 - plan.bounds.z1 + 1, #plan.boundary.rects))
  end
end
print(string.format("TOTAL ordinary %d (house %d shop %d workshop %d) ordinary-beds %d landmark-beds %d", tot.all, tot.house, tot.shop, tot.workshop, tot.beds, tot.lbeds))
local names = {}
for n in pairs(per_block) do names[#names + 1] = n end
table.sort(names)
print("per block (seeds 1/2/3/7):")
for _, n in ipairs(names) do
  local r = per_block[n]
  print(string.format("  %-30s %d %d %d %d", n, r[1] or 0, r[2] or 0, r[3] or 0, r[7] or 0))
end
