-- Headless benchmark of real-engine site inspection (issue #186); only ever
-- installed in a scratch world by tools/site_bench/run.py.
--
-- For each terrain fixture and town type it runs the production
-- towns.site_search.search with the production options (wet defaults, real
-- plan, real preflight composition) and reports separately:
--   planning_ms  time inside planner.plan
--   emerge_ms    wall time from each emerge request to its callback
--   inspect_ms   terrain reading and classification (inspect_columns, plus
--                the bulk region read when the env offers one)
--   total_ms     wall time of the whole search
-- and the engine API traffic: core.get_node calls, VoxelManip reads and the
-- nodes they covered. Fixtures are written with a VoxelManip BEFORE the timed
-- search, so every measured read sees identical terrain. The phases are kept
-- apart so the planner's own cost never inflates (or hides) the inspection
-- numbers.
local N_REPS = tonumber(core.settings:get('towns_site_bench_reps')) or 3
local G = 8 -- mgflat_ground_level of the scratch world: surface node y
local SPAN = 232 -- fixtures cover x, z in [-SPAN, SPAN] around each origin
local STONE, GRASS, WATER = 'mcl_core:stone', 'mcl_core:dirt_with_grass', 'mcl_core:water_source'

local out = {runs = {}, notes = {}}
local function now() return core.get_us_time() end

-- Instrumentation -----------------------------------------------------------
local cnt = {get_node = 0, vm = 0}
local acc = {plan = 0, emerge = 0, inspect = 0, inspect_calls = 0, region_nodes = 0}
local real_get_node = core.get_node
core.get_node = function(p) cnt.get_node = cnt.get_node + 1; return real_get_node(p) end
local real_get_vm = core.get_voxel_manip
core.get_voxel_manip = function(...) cnt.vm = cnt.vm + 1; return real_get_vm(...) end

local real_plan = towns.planner.plan
towns.planner.plan = function(...)
 local t = now()
 local a, b = real_plan(...)
 acc.plan = acc.plan + (now() - t)
 return a, b
end
local real_inspect = towns.site_search.inspect_columns
towns.site_search.inspect_columns = function(...)
 local t = now()
 local a, b, c = real_inspect(...)
 acc.inspect = acc.inspect + (now() - t)
 acc.inspect_calls = acc.inspect_calls + 1
 return a, b, c
end
local real_core_env = towns.site_search.core_env
towns.site_search.core_env = function(c)
 local env = real_core_env(c)
 local emerge = env.emerge
 env.emerge = function(minp, maxp, cb)
  local t = now()
  emerge(minp, maxp, function(ok) acc.emerge = acc.emerge + (now() - t); return cb(ok) end)
 end
 if env.read_region then
  local read = env.read_region
  env.read_region = function(minp, maxp)
   local t = now()
   local r = read(minp, maxp)
   acc.inspect = acc.inspect + (now() - t)
   acc.region_nodes = acc.region_nodes + (maxp.x - minp.x + 1) * (maxp.y - minp.y + 1) * (maxp.z - minp.z + 1)
   return r
  end
 end
 return env
end

-- Fixtures ------------------------------------------------------------------
-- surface(x, z) -> top solid y, water(x, z) -> top water y or nil; x is
-- relative to the fixture origin.
local function pond(x, z)
 return (math.floor(x / 12) + math.floor(z / 12)) % 5 == 0 and (x * x + z * z) > 30 * 30
end
local fixtures = {
 flat = {}, -- untouched superflat map
 ['flat-fresh'] = {fresh = true}, -- only the player's block exists: real mapgen inside the search
 uneven = {
  surface = function(x, z) return G + 8 + math.floor(13 * math.sin(x / 17) * math.cos(z / 23) + 0.5) end,
 },
 ['deep-lake'] = { -- 10 below the water table everywhere beyond the player's island
  surface = function(x, z) return (x * x + z * z < 30 * 30) and G or G - 10 end,
  water = function(x, z) return (x * x + z * z < 30 * 30) and nil or G end,
 },
 ['shallow-ponds'] = { -- 3-deep ponds on ~20% of the area: accepted by wet mode
  surface = function(x, z) return pond(x, z) and G - 3 or G end,
  water = function(x, z) return pond(x, z) and G or nil end,
 },
}
local ORDER = {'flat', 'uneven', 'deep-lake', 'shallow-ponds', 'flat-fresh'}
-- Each fixture lives in its own region along x so they cannot interfere.
local function origin_x(i) return (i - 1) * 1000 end

local YMIN, YMAX = -4, 60
local function apply_fixture(fx, ox)
 if not fx.surface then return end
 local c_stone, c_grass = core.get_content_id(STONE), core.get_content_id(GRASS)
 local c_water, c_air = core.get_content_id(WATER), core.CONTENT_AIR
 for z0 = -SPAN, SPAN, 64 do
  local minp = {x = ox - SPAN, y = YMIN, z = z0}
  local maxp = {x = ox + SPAN, y = YMAX, z = math.min(z0 + 63, SPAN)}
  local vm = real_get_vm()
  local emin, emax = vm:read_from_map(minp, maxp)
  local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
  local data = vm:get_data()
  for z = minp.z, maxp.z do
   for x = minp.x, maxp.x do
    local h = fx.surface(x - ox, z)
    local w = fx.water and fx.water(x - ox, z)
    local i = area:index(x, YMIN, z)
    for y = YMIN, YMAX do
     local id
     if y < h then id = c_stone
     elseif y == h then id = c_grass
     elseif w and y <= w then id = c_water
     else id = c_air end
     data[i] = id
     i = i + area.ystride
    end
   end
  end
  vm:set_data(data)
  vm:write_to_map(false)
 end
end

local function emerge(minp, maxp, cb)
 core.emerge_area(minp, maxp, function(_, action, remaining)
  if remaining > 0 then return end
  assert(action ~= core.EMERGE_CANCELLED and action ~= core.EMERGE_ERRORED, 'emerge failed')
  cb()
 end)
end

-- One timed search ------------------------------------------------------------
local function run_search(label, town_type, ox, params, cb)
 local opts = {step = params.step, max_radius = params.radius}
 for k, v in pairs(towns.site_search.WET_DEFAULTS) do opts[k] = v end
 if town_type == 'roman' then
  opts.planner_opts = {town_type = 'roman'}
  opts.entries = towns.catalog.entries
 else
  opts.planner_opts = {landmarks = assert(towns.planner.landmark_profile(towns.catalog.snapshot()))}
 end
 cnt.get_node, cnt.vm = 0, 0
 for k in pairs(acc) do acc[k] = 0 end
 local t0 = now()
 towns.site_search.search({x = ox, y = G + 1, z = 0}, 5, opts, function(result, summary, details)
  local total = now() - t0
  local row = {
   fixture = label, town = town_type,
   total_ms = total / 1000, planning_ms = acc.plan / 1000, emerge_ms = acc.emerge / 1000,
   inspect_ms = acc.inspect / 1000,
   inspections = acc.inspect_calls, get_node_calls = cnt.get_node,
   voxelmanip_reads = cnt.vm, voxelmanip_nodes_requested = acc.region_nodes,
   accepted = result ~= nil, summary = summary,
   candidates_tried = details.candidates_tried, rejections = details.rejections,
  }
  if result then
   row.columns, row.ground_y, row.center = result.columns, result.ground_y, result.center
   row.min_height, row.max_height = result.min_height, result.max_height
   row.wet_columns = result.wet and result.wet.count or 0
  end
  out.runs[#out.runs + 1] = row
  cb()
 end)
end


-- Bulk-read probe (no production code involved): what a VoxelManip read of
-- the same inspection volume plus the same top-down column classification
-- costs, measured on the same terrain, so the potential saving is known
-- before any production change. Reports ms for the read, get_data and the
-- scan separately.
local function bulk_probe(town_type, ox)
 local b = out.footprints[town_type]
 local ref_y = G
 local top, bottom = ref_y + 49, ref_y - 48
 local minp = {x = ox + b.x1 - 1, y = bottom, z = b.z1 - 1}
 local maxp = {x = ox + b.x2 + 1, y = top, z = b.z2 + 1}
 local info_cache, class_of = {}, {}
 local function class(id)
  local c = class_of[id]
  if c then return c end
  local name = core.get_name_from_content_id(id)
  c = towns.placement.classify(name, function(n) return towns.placement.node_info(core.registered_nodes, n) end)
  class_of[id] = c
  return c
 end
 local t0 = now()
 local vm = real_get_vm()
 local emin, emax = vm:read_from_map(minp, maxp)
 local t1 = now()
 local data = vm:get_data()
 local t2 = now()
 local xd = emax.x - emin.x + 1
 local yd = emax.y - emin.y + 1
 local ystride, zstride = xd, xd * yd
 local solid, reads = 0, 0
 for z = b.z1, b.z2 do
  for x = ox + b.x1, ox + b.x2 do
   local i = (z - emin.z) * zstride + (top - emin.y) * ystride + (x - emin.x) + 1
   for y = top, bottom, -1 do
    reads = reads + 1
    if class(data[i]) == 'solid' then solid = solid + 1; break end
    i = i - ystride
   end
  end
 end
 local t3 = now()
 return {town = town_type, nodes_in_array = xd * yd * (emax.z - emin.z + 1), node_reads = reads, solid_columns = solid,
  read_from_map_ms = (t1 - t0) / 1000, get_data_ms = (t2 - t1) / 1000, scan_ms = (t3 - t2) / 1000,
  total_ms = (t3 - t0) / 1000}
end

local function finish(err)
 if err then out.error = tostring(err) end
 local f = assert(io.open(core.get_worldpath() .. '/site-bench.json', 'w'))
 f:write(core.write_json(out, true))
 f:close()
 core.request_shutdown('site bench done', false, 0)
end

local function main()
 local plans = {}
 for _, tt in ipairs({'medieval', 'roman'}) do
  local popts = tt == 'roman' and {town_type = 'roman'}
   or {landmarks = assert(towns.planner.landmark_profile(towns.catalog.snapshot()))}
  local p = assert(real_plan({x = 0, z = 0}, 5, popts))
  local b = p.bounds
  plans[tt] = {x1 = b.x1, x2 = b.x2, z1 = b.z1, z2 = b.z2}
 end
 out.footprints = plans
 -- step/radius keep rejected-terrain runs bounded and comparable: only the
 -- centres about one footprint away from the player get inspected.
 local params = {medieval = {step = 64, radius = 128}, roman = {step = 64, radius = 128}}
 local queue = {}
 for i, name in ipairs(ORDER) do
  for _, tt in ipairs({'medieval', 'roman'}) do
   for rep = 1, N_REPS do queue[#queue + 1] = {name = name, ox = origin_x(i), tt = tt, rep = rep} end
  end
 end
 local prepared = {}
 local function step(qi)
  local job = queue[qi]
  if not job then
   out.probe = {}
   for rep = 1, N_REPS do
    for _, tt in ipairs({'medieval', 'roman'}) do
     local ok, r = pcall(bulk_probe, tt, origin_x(1))
     out.probe[#out.probe + 1] = ok and r or {error = tostring(r)}
    end
   end
   return finish()
  end
  local fx = fixtures[job.name]
  local function go()
   run_search(job.name .. '#' .. job.rep, job.tt, job.ox, params[job.tt], function()
    core.after(0, step, qi + 1)
   end)
  end
  if prepared[job.name] then return go() end
  prepared[job.name] = true
  local ox = job.ox
  if fx.fresh then
   -- only the block under the player; the search itself triggers mapgen
   return emerge({x = ox - 2, y = G - 2, z = -2}, {x = ox + 2, y = G + 3, z = 2}, go)
  end
  -- Emerge the whole fixture box (the search needs it anyway), then shape it.
  emerge({x = ox - SPAN, y = YMIN, z = -SPAN}, {x = ox + SPAN, y = YMAX, z = SPAN}, function()
   local ok, err = pcall(apply_fixture, fx, ox)
   if not ok then return finish(err) end
   go()
  end)
 end
 step(1)
end

core.register_on_mods_loaded(function() core.after(0, function()
 local ok, err = pcall(main)
 if not ok then finish(err) end
end) end)
