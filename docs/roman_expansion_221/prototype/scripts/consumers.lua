local root = arg[1]
local planner = dofile(root .. "/src/planner.lua")
local catalog = dofile(root .. "/src/catalog.lua")
local preflight = dofile(root .. "/src/preflight.lua")
local TL = dofile(root .. "/src/town_layout.lua")
local ss = dofile(root .. "/src/site_search.lua")(dofile(root .. "/src/placement.lua"), planner)
local opts = {}
opts.town_type = "roman"
for _, c in ipairs({{0, 0}, {777, -333}}) do
  local plan = assert(planner.plan({x = c[1], z = c[2]}, 1, opts))
  local v, vwhy = planner.validate(plan)
  local comp, why = preflight.compose(plan, preflight.entries(catalog.entries), 50)
  print("centre", c[1], c[2], "validate", v, vwhy, "compose", comp ~= nil, why)
  if comp then
    local lo = 1e9
    for _, st in ipairs(comp.structures) do if st.min.y < lo then lo = st.min.y; low = st.id end end
    print("  structures", #comp.structures, "lowest foundation y", lo, low)
  end
  local lopts = {}
  lopts.heights = function() return 50 end
  lopts.max_y = 100
  local ok, L = pcall(TL.new, plan, 50, lopts)
  print("  town_layout", ok, ok and #L.columns or L)
  local cols = ss.boundary_columns(plan.boundary.rects)
  print("  site_search boundary columns", #cols, "bounds cells", (plan.bounds.x2 - plan.bounds.x1 + 1) * (plan.bounds.z2 - plan.bounds.z1 + 1))
end
