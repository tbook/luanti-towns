-- usage: lua sweep.lua ROOT N : seeds 1..N over four centres; min/max/mean ordinary, failures, shortages
local root, N = arg[1], tonumber(arg[2] or 100)
local planner = dofile(root .. "/src/planner.lua")
local centres = {{0, 0}, {1500, -2500}, {-4200, 3100}, {777, -333}}
local mn, mx, sum, fails, shorts, nojail, per_role = 1e9, 0, 0, 0, 0, 0, {}
local emptyblk = {}
for seed = 1, N do
  local c = centres[(seed - 1) % #centres + 1]
  local opts = {}
  opts.town_type = "roman"
  local plan, why = planner.plan({x = c[1], z = c[2]}, seed, opts)
  if not plan then fails = fails + 1; print("FAIL seed " .. seed .. ": " .. tostring(why)) else
    local n = #plan.content.buildings
    mn, mx, sum = math.min(mn, n), math.max(mx, n), sum + n
    shorts = shorts + #(plan.shortages or {})
    if not (plan.reservations and plan.reservations.jail) then nojail = nojail + 1 end
    local got = {}
    for _, b in ipairs(plan.content.buildings) do got[b.block] = true end
    for _, s in ipairs(plan.reservations.services or {}) do got[s.block] = true end
    if plan.reservations.jail then got[plan.reservations.jail.block] = true end
    for i, b in ipairs(plan.blocks) do if not got[i] then emptyblk[b.name] = (emptyblk[b.name] or 0) + 1 end end
  end
end
print(string.format("seeds 1..%d: failures %d, ordinary min %d max %d mean %.2f, shortages %d, plans without jail %d", N, fails, mn, mx, sum / (N - fails), shorts, nojail))
for k, v in pairs(emptyblk) do print("  block with no building or reservation in " .. v .. " plans: " .. k) end
