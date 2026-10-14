-- Headless disposable-world check for ticket #45; only ever installed in a
-- scratch world by tools/place_check/run.py. It searches for a site in the
-- flat scratch world, builds a town with real schematics through the
-- production code (towns.place_town) and re-reads the world to verify the
-- result independently of the builder's own checks.
local seed = tonumber(core.settings:get('towns_place_check_seed')) or 6
local report = {seed = seed, checks = {}, failures = {}}
local function check(ok, label)
 report.checks[#report.checks + 1] = {ok = ok and true or false, label = label}
 if not ok then report.failures[#report.failures + 1] = label end
end
local function finish()
 report.ok = #report.failures == 0
 local f = assert(io.open(core.get_worldpath() .. '/place-check.json', 'w'))
 f:write(core.write_json(report, true))
 f:close()
 core.request_shutdown('place check done', false, 0)
end
local function rect_gap(a, b)
 local dx = math.max(a.x1 - b.x2, b.x1 - a.x2, 0)
 local dz = math.max(a.z1 - b.z2, b.z1 - a.z2, 0)
 return dx, dz
end

core.register_on_mods_loaded(function() core.after(0, function()
 local ok, err = pcall(function()
  local root = towns.modpath
  -- The scratch world has no map yet: generate the start area first.
  core.emerge_area({x = -48, y = -8, z = -48}, {x = 48, y = 40, z = 48}, function(_, action, remaining)
   if remaining > 0 then return end
   assert(action ~= core.EMERGE_CANCELLED and action ~= core.EMERGE_ERRORED, 'start area emerge failed')
  towns.place_town.search({x = 0, y = 9, z = 0}, seed, nil, function(result, msg)
   local ok2, err2 = pcall(function()
    if not result then report.search_failure = msg; check(false, 'site search: ' .. tostring(msg)); return finish() end
    report.center, report.ground_y = result.center, result.ground_y
    local summary, bmsg, code, extra = towns.place_town.build(result)
    report.build_message, report.build_code = bmsg, code
    check(summary ~= nil, 'build_town succeeded' .. (bmsg and (': ' .. bmsg) or ''))
    if not summary then
     report.extra = extra
     -- Diagnostic: nodes along the failing building's door route.
     local site = extra and extra.building and result.plan.sites[extra.building.kind]
     if site and site.entrance then
      local e, ap = site.entrance, site.approach.pos
      local dump = {}
      local function ch(n)
       if n == 'air' then return '.' end
       if n:find('stair') then return 's' end
       if n:find('slab') then return '_' end
       if n:find('door') then return 'D' end
       if n:find('fence') or n:find('wall') then return 'f' end
       local d = core.registered_nodes[n]
       if d and d.walkable == false then return '~' end
       return '#'
      end
      for y = result.ground_y, result.ground_y + 7 do
       dump[#dump + 1] = 'y=' .. y .. ' (rows z high to low, columns x ' .. (math.min(e.x, ap.x) - 4) .. '..' .. (math.max(e.x, ap.x) + 2) .. ')'
       for z = e.z + 10, e.z - 10, -1 do
        local row = {}
        for x = math.min(e.x, ap.x) - 4, math.max(e.x, ap.x) + 2 do
         row[#row + 1] = ch(core.get_node({x = x, y = y, z = z}).name)
        end
        dump[#dump + 1] = string.format('%4d ', z) .. table.concat(row)
       end
      end
      report.dump = dump
      report.door = {entrance = e, approach = ap}
     end
     return finish()
    end
    local town = summary.town
    check(town and town.complete, 'summary marked complete')
    report.counts = {structures = #town.structures, alleys = town.alleys, nodes_changed = summary.nodes.changed}
    -- Re-read every structure against its schematic, rotation by rotation.
    local mismatches, compared = 0, 0
    for _, b in ipairs(town.structures) do
     local entry = towns.catalog.entries[b.id]
     local s = assert(core.read_schematic(root .. '/' .. entry.path, {}))
     for z = 0, s.size.z - 1 do for y = 0, s.size.y - 1 do for x = 0, s.size.x - 1 do
      local want = s.data[z * s.size.x * s.size.y + y * s.size.x + x + 1]
      local p = vector.add(b.min, towns.schematic.rotate_offset(s.size, {x = x, y = y, z = z}, b.rotation))
      local have = core.get_node(p).name
      compared = compared + 1
      if have ~= want.name then mismatches = mismatches + 1 end
     end end end
    end
    report.compared_nodes, report.mismatched_nodes = compared, mismatches
    check(mismatches == 0, 'every schematic node matches (' .. mismatches .. ' of ' .. compared .. ' differ)')
    -- Real landmarks present; no blockout palette leaked in as ground.
    local kinds = {}
    for _, b in ipairs(town.structures) do kinds[b.kind] = (kinds[b.kind] or 0) + 1 end
    check(kinds.cathedral == 1 and kinds.castle == 1, 'real cathedral and castle placed')
    -- Doors: independent walk of the route cells in the finished world.
    local g = result.ground_y
    report.door_steps = {}
    for _, d in ipairs(town.doors) do
     report.door_steps[#report.door_steps + 1] = d.id .. ':' .. d.steps
     local e = d.entrance
     local feet, head = core.get_node(e).name, core.get_node(vector.add(e, {x = 0, y = 1, z = 0})).name
     local def = core.registered_nodes[feet]
     check(def ~= nil and (feet == 'air' or def.walkable == false or feet:find('door') ~= nil
       or feet:find('gate') ~= nil), d.kind .. ' ' .. d.id .. ' door node usable: ' .. feet)
     local ap = d.approach
     local floor = core.registered_nodes[core.get_node({x = ap.x, y = g, z = ap.z}).name]
     check(floor ~= nil and floor.walkable ~= false, d.id .. ' approach floor walkable')
    end
    -- Touching buildings: pairs of ordinary structures with zero gap.
    local touching = 0
    for i = 1, #town.structures do for j = i + 1, #town.structures do
     local a, c = town.structures[i], town.structures[j]
     local dx, dz = rect_gap(a.rect, c.rect)
     if dx == 0 and dz <= 1 or dz == 0 and dx <= 1 then touching = touching + 1 end
    end end
    report.touching_pairs = touching
    check(touching >= 1, 'at least one pair of adjacent buildings (' .. touching .. ')')
    -- Alleys paved and standable.
    local plan = result.plan
    local alleys = plan.content.alleys or {}
    report.plan_alleys = #alleys
    for _, a in ipairs(alleys) do
     local cell = core.get_node({x = a.rect.x1, y = g, z = a.rect.z1}).name
     check(cell == 'mcl_core:cobble' or cell == 'mcl_core:stonebrick', 'alley ' .. a.id .. ' paved: ' .. cell)
     local above = core.get_node({x = a.rect.x1, y = g + 1, z = a.rect.z1}).name
     check(above == 'air', 'alley ' .. a.id .. ' open above: ' .. above)
    end
    check(#alleys >= 1, 'town has at least one alley')
    -- City hall is not paved over.
    local hall = plan.sites.city_hall
    if hall then
     local n = core.get_node({x = hall.rect.x1, y = g, z = hall.rect.z1}).name
     report.hall_corner = n
     check(n ~= 'mcl_core:stonebrick' and n ~= 'mcl_core:cobble', 'city hall corner not pavement: ' .. n)
    end
    finish()
   end)
   if not ok2 then check(false, 'verification error: ' .. tostring(err2)); finish() end
  end)
  end)
 end)
 if not ok then check(false, 'startup error: ' .. tostring(err)); finish() end
end) end)
