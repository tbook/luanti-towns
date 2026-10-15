-- Headless disposable-world check for ticket #45; only ever installed in a
-- scratch world by tools/place_check/run.py. It searches for a site in the
-- flat scratch world, builds a town with real schematics through the
-- production code (towns.place_town) and re-reads the world to verify the
-- result independently of the builder's own checks. Ticket #46 additions:
-- functional node initialization, idempotence and Living Villages
-- recognition of the tavern jukebox and the well.
local seed = tonumber(core.settings:get('towns_place_check_seed')) or 5
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

-- Phase 2 (ticket #48): a fresh server process on the world phase 1 built.
-- Re-enumerates the saved boxes, runs the resident initialization again with
-- the persisted mod-storage record and checks no villager is added.
local function restart_phase()
 local ok, err = pcall(function()
  local f = assert(io.open(core.get_worldpath() .. '/place-check.json', 'r'))
  local prev = core.parse_json(f:read('*a'))
  f:close()
  local boxes = assert(prev.resident_boxes, 'phase 1 left no resident boxes')
  local lo, hi
  for _, b in ipairs(boxes) do
   lo = lo and vector.new(math.min(lo.x, b.min.x), math.min(lo.y, b.min.y), math.min(lo.z, b.min.z)) or vector.new(b.min.x, b.min.y, b.min.z)
   hi = hi and vector.new(math.max(hi.x, b.max.x), math.max(hi.y, b.max.y), math.max(hi.z, b.max.z)) or vector.new(b.max.x, b.max.y, b.max.z)
  end
  core.emerge_area(vector.subtract(lo, 16), vector.add(hi, 16), function(_, action, remaining)
   if remaining > 0 then return end
   -- No player is connected, so nothing activates stored objects: forceload
   -- every mapblock of the town (max_forceloaded_blocks is raised to 4096 in check.conf).
   local a, b = vector.subtract(lo, 16), vector.add(hi, 16)
   local nblocks = 0
   for bx = math.floor(a.x / 16), math.floor(b.x / 16) do
    for by = math.floor(a.y / 16), math.floor(b.y / 16) do
     for bz = math.floor(a.z / 16), math.floor(b.z / 16) do
      if core.forceload_block({x = bx * 16, y = by * 16, z = bz * 16}, true) then nblocks = nblocks + 1 end
     end
    end
   end
   report.forceloaded_blocks = nblocks
   core.after(3, function()
    local ok2, err2 = pcall(function()
     assert(action ~= core.EMERGE_CANCELLED and action ~= core.EMERGE_ERRORED, 'emerge failed')
     local env = towns.residents.core_env(core)
     local rep = towns.residents.enumerate(boxes, env)
     check(rep.count == prev.resident_bed_count, 'restart: same valid bed count (' .. rep.count .. ' vs ' .. tostring(prev.resident_bed_count) .. ')')
     local function villagers()
      local n = 0
      for _, o in ipairs(core.get_objects_inside_radius(vector.multiply(vector.add(lo, hi), 0.5), 400)) do
       local le = o:get_luaentity()
       if le and le.name == 'mobs_mc:villager' then n = n + 1 end
      end
      return n
     end
     local before = villagers()
     -- Every recorded resident must have persisted. Villagers beyond those
     -- are reported, not failed: Living Villages (births.lua) breeds a child
     -- into any free bed, which includes the beds enumeration skipped.
     local rec_ids = {}
     for _, b in ipairs(rep.beds) do
      local rec = towns.place_town.store.get(towns.residents.record_key(b.pos))
      if rec then rec_ids[(rec:gsub('^done:', ''))] = true end
     end
     local found, extra, seen = 0, {}, {}
     for _, o in ipairs(core.get_objects_inside_radius(vector.multiply(vector.add(lo, hi), 0.5), 400)) do
      local le = o:get_luaentity()
      if le and le.name == 'mobs_mc:villager' then
       if rec_ids[le._id] then
        -- distinct recorded ids: a duplicate entity does not count twice
        if not seen[le._id] then seen[le._id] = true; found = found + 1 end
       else extra[#extra + 1] = core.pos_to_string(vector.round(o:get_pos())) .. ' bed=' .. tostring(le._bed and core.pos_to_string(le._bed)) .. ' child=' .. tostring(le.child) end
      end
     end
     report.unrecorded_villagers = extra
     check(found >= rep.count, 'restart: every recorded resident persisted (' .. found .. ' of ' .. rep.count .. ')')
     local r = towns.residents.initialize(rep.beds, env, towns.place_town.store)
     report.restart = {villagers_before = before, spawned = r.spawned, already_done = r.already_done,
      claimed = r.claimed, interrupted = r.interrupted, failed = r.failed}
     check(r.spawned == 0 and r.failed == 0 and r.already_done == rep.count, 'restart: initialization spawns nothing (' .. r.spawned .. ' spawned, ' .. r.already_done .. ' already done)')
     check(villagers() == before, 'restart: villager count unchanged (' .. villagers() .. ')')
    end)
    if not ok2 then check(false, 'restart verification error: ' .. tostring(err2)) end
    local out = assert(io.open(core.get_worldpath() .. '/place-check-restart.json', 'w'))
    report.ok = #report.failures == 0
    out:write(core.write_json(report, true))
    out:close()
    core.request_shutdown('place check restart done', false, 0)
   end)
  end)
 end)
 if not ok then check(false, 'restart startup error: ' .. tostring(err)); finish() end
end

core.register_on_mods_loaded(function() core.after(0, function()
 if core.settings:get('towns_place_check_phase') == '2' then return restart_phase() end
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
     local st
     for _, b in ipairs(town.structures) do if b.id == d.id and b.entrance.x == e.x and b.entrance.z == e.z then st = b end end
     local route, why = towns.builder.check_door(st, g, function(x, y, z)
      local n = core.get_node({x = x, y = y, z = z}).name
      if n == 'air' then return {walkable = false}, n end
      return towns.placement.node_info(core.registered_nodes, n), n
     end)
     check(route ~= nil, d.id .. ' door route walked in the finished world' .. (why and (': ' .. why) or ''))
    end
    -- Touching buildings: pairs of ordinary structures with zero gap.
    local touching = 0
    for i = 1, #town.structures do for j = i + 1, #town.structures do
     local a, c = town.structures[i], town.structures[j]
     local dx, dz = rect_gap(a.rect, c.rect)
     if dx == 0 and dz <= 1 or dz == 0 and dx <= 1 then touching = touching + 1 end
    end end
    report.touching_pairs = touching
    local content_n = 0
    for _, b in ipairs(town.structures) do if b.kind == 'content' then content_n = content_n + 1 end end
    if content_n >= 2 then check(touching >= 1, 'at least one pair of adjacent buildings (' .. touching .. ')') end
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
    report.alleys_in_plan = #alleys > 0
    -- City hall is not paved over.
    local hall = plan.sites.city_hall
    if hall then
     local n = core.get_node({x = hall.rect.x1, y = g, z = hall.rect.z1}).name
     report.hall_corner = n
     check(n ~= 'mcl_core:stonebrick' and n ~= 'mcl_core:cobble', 'city hall corner not pavement: ' .. n)
    end
    -- Functional node initialization (ticket #46), verified in the engine.
    local setup = town.setup
    check(setup ~= nil, 'node setup report present')
    if setup then
     report.node_setup = {initialized = setup.initialized, by_name = setup.by_name,
      failed = #setup.failed, unregistered = #setup.unregistered, unhandled = setup.unhandled}
     check(#setup.failed == 0 and #setup.unregistered == 0, 'node setup: no failed or unregistered nodes')
     check(#setup.unhandled == 0, 'node setup: no unhandled required initialization (' .. #setup.unhandled .. ')')
     check(setup.initialized > 0, 'node setup initialized nodes: ' .. setup.initialized)
    end
    -- Containers and devices carry the lists their constructors define.
    local EXPECT = {
     ['mcl_jukebox:jukebox'] = {main = 1}, ['mcl_barrels:barrel_closed'] = {main = 27},
     ['mcl_furnaces:furnace'] = {src = 1, fuel = 1, dst = 1}, ['mcl_smoker:smoker'] = {src = 1, fuel = 1, dst = 1},
     ['mcl_blast_furnace:blast_furnace'] = {src = 1, fuel = 1, dst = 1},
     ['mcl_chests:chest_small'] = {main = 27}, ['mcl_chests:chest_left'] = {main = 27},
     ['mcl_chests:chest_right'] = {main = 27}, ['mcl_chests:trapped_chest_small'] = {main = 27},
     ['mcl_chests:trapped_chest_left'] = {main = 27}, ['mcl_chests:trapped_chest_right'] = {main = 27},
     ['mcl_itemframes:frame'] = {main = 1}, ['mcl_itemframes:plate'] = {main = 1},
     ['mcl_books:bookshelf'] = {main = 27}, ['mcl_brewing:stand_000'] = {input = 1, fuel = 1, stand = 3},
     ['mcl_composters:composter'] = {src = 1, dst = 1}, ['mcl_dispensers:dispenser'] = {main = 9},
    }
    local FORMSPEC = {['mcl_furnaces:furnace'] = true, ['mcl_smoker:smoker'] = true,
     ['mcl_blast_furnace:blast_furnace'] = true, ['mcl_brewing:stand_000'] = true,
     ['mcl_dispensers:dispenser'] = true, ['mcl_grindstone:grindstone'] = true}
    local counts, bad, snapshots = {}, 0, {}
    -- Canonical text form: core.serialize numbers shared references in
    -- pairs() order, which differs between identical tables.
    local function signature(meta)
     local t = meta:to_table()
     local parts = {}
     local keys = {}
     for k in pairs(t.fields) do keys[#keys + 1] = k end
     table.sort(keys)
     for _, k in ipairs(keys) do parts[#parts + 1] = 'f:' .. k .. '=' .. tostring(t.fields[k]) end
     local lists = {}
     for l in pairs(t.inventory) do lists[#lists + 1] = l end
     table.sort(lists)
     for _, l in ipairs(lists) do
      local strs = {}
      for i, st in ipairs(t.inventory[l]) do strs[i] = st:to_string() end
      parts[#parts + 1] = 'l:' .. l .. '=[' .. table.concat(strs, '|') .. ']'
     end
     return table.concat(parts, '\n')
    end
    local names = {}
    for n in pairs(EXPECT) do names[#names + 1] = n end
    for n in pairs(FORMSPEC) do if not EXPECT[n] then names[#names + 1] = n end end
    names[#names + 1] = 'mcl_fences:fence_gate'
    for _, b in ipairs(town.structures) do
     for _, p in ipairs(core.find_nodes_in_area(b.min, b.max, names)) do
      local n = core.get_node(p).name
      counts[n] = (counts[n] or 0) + 1
      local meta = core.get_meta(p)
      local inv = meta:get_inventory()
      for list, size in pairs(EXPECT[n] or {}) do
       if inv:get_size(list) < size then bad = bad + 1; check(false, b.id .. ' ' .. n .. ' list ' .. list .. ' at ' .. core.pos_to_string(p) .. ' has size ' .. inv:get_size(list)) end
      end
      if FORMSPEC[n] and meta:get_string('formspec') == '' then bad = bad + 1; check(false, n .. ' has no formspec at ' .. core.pos_to_string(p)) end
      if n == 'mcl_fences:fence_gate' and meta:get_string('state') == '' then bad = bad + 1; check(false, 'fence gate state unset at ' .. core.pos_to_string(p)) end
      snapshots[core.pos_to_string(p)] = signature(meta)
     end
    end
    report.functional_nodes = counts
    check(bad == 0, 'functional nodes carry their inventories and formspecs')
    -- Every chest has its entity.
    local chests, missing_entity = 0, 0
    for _, b in ipairs(town.structures) do
     for _, p in ipairs(core.find_nodes_in_area(b.min, b.max, {'group:chest_entity'})) do
      chests = chests + 1
      local found = false
      for _, o in ipairs(core.get_objects_inside_radius(p, 0.6)) do
       local le = o:get_luaentity()
       if le and le.name and le.name:find('^mcl_chests:') then found = true end
      end
      if not found then missing_entity = missing_entity + 1 end
     end
    end
    report.chest_entities = {chests = chests, missing = missing_entity}
    check(missing_entity == 0, 'every chest has its entity (' .. missing_entity .. ' of ' .. chests .. ' missing)')
    -- Idempotence: a second adapter call on a fresh state changes no metadata.
    do
     local env = towns.node_setup.core_env(core, {itemframes = rawget(_G, 'mcl_itemframes'), chests = rawget(_G, 'mcl_chests')},
      function(b) local e = towns.catalog.entries[b.id]; return e and towns.schematic.required_nodes(e, towns.modpath) end)
     local function entity_count()
      local n = 0
      for _, b in ipairs(town.structures) do
       for _, o in ipairs(core.get_objects_in_area(b.min, vector.add(b.max, {x = 1, y = 1, z = 1}))) do
        local le = o:get_luaentity()
        if le and le.name and (le.name:find('^mcl_chests:') or le.name:find('^mcl_armor_stand:')) then n = n + 1 end
       end
      end
      return n
     end
     local entities_before = entity_count()
     local state = {}
     local again = towns.node_setup.initialize(town.structures, env, {})
     check(#again.failed == 0, 'second node setup call has no failures')
     local changed = 0
     for key, before in pairs(snapshots) do
      local x, y, z = key:match('%((-?%d+),(-?%d+),(-?%d+)%)')
      local p = {x = tonumber(x), y = tonumber(y), z = tonumber(z)}
      if signature(core.get_meta(p)) ~= before then changed = changed + 1; report.changed_node = key .. ' ' .. core.get_node(p).name .. ' ' .. before .. ' => ' .. signature(core.get_meta(p)) end
     end
     report.entities = {before = entities_before, after = entity_count()}
     check(report.entities.after == entities_before, 'second node setup call adds no entities (' .. entities_before .. ' -> ' .. report.entities.after .. ')')
     -- Same state twice: the completed placements are skipped outright.
     local first = towns.node_setup.initialize(town.structures, env, state)
     local third = towns.node_setup.initialize(town.structures, env, state)
     check(third.already_done == third.placements and third.initialized == 0,
      'same-state repeat skips completed placements (' .. third.already_done .. ' of ' .. third.placements .. ')')
     check(entity_count() == entities_before, 'same-state repeat adds no entities')
     report.repeat_changed_nodes = changed
     check(changed == 0, 'second node setup call preserves metadata (' .. changed .. ' nodes changed)')
    end
    -- Bed enumeration (ticket #47): the summary's report, re-derived from
    -- the schematics' own bed nodes, plus Living Villages' view of the bed.
    do
     local beds = town.beds
     check(beds ~= nil, 'bed enumeration report present' .. (town.beds_error and (': ' .. town.beds_error) or ''))
     if beds then
      local per, expected_pairs, mismatch = {}, 0, 0
      for i, b in ipairs(town.structures) do
       local entry = towns.catalog.entries[b.id]
       local s = assert(core.read_schematic(root .. '/' .. entry.path, {}))
       local n = 0
       for _, node in ipairs(s.data) do
        if node.name:find('^mcl_beds:.*_bottom$') then n = n + 1 end
       end
       local sum = beds.by_structure[i]
       local row = {id = b.id, kind = b.kind, path = entry.path, schematic_beds = n, valid = sum.valid, skipped = sum.skipped}
       per[#per + 1] = row
       expected_pairs = expected_pairs + n
       if sum.valid + sum.skipped ~= n then
        mismatch = mismatch + 1
        check(false, 'bed count for ' .. b.id .. ' matches its schematic: ' .. sum.valid .. '+' .. sum.skipped .. ' vs ' .. n)
       end
      end
      report.beds = {valid = beds.count, skipped = #beds.skipped, schematic_beds = expected_pairs,
       by_color = beds.by_color, per_structure = per}
      report.bed_skips = {}
      for _, k in ipairs(beds.skipped) do
       report.bed_skips[#report.bed_skips + 1] = k.id .. ' ' .. k.name .. ' ' .. core.pos_to_string(k.pos) .. ' ' .. k.reason
      end
      check(mismatch == 0, 'every building bed count matches its schematic')
      check(beds.count + #beds.skipped == expected_pairs, 'valid + skipped beds equal the schematic pairs (' .. beds.count .. '+' .. #beds.skipped .. ' vs ' .. expected_pairs .. ')')
      -- Every valid bed: bottom and top nodes as reported, spawn cell standable.
      local bad = 0
      -- As strong as the enumeration: open (or carpet) feet cell, open head
      -- cell, walkable harmless floor below.
      local function open(p)
       local d = core.registered_nodes[core.get_node(p).name]
       return d ~= nil and d.walkable == false
      end
      local function spawn_ok(p)
       local feet = core.get_node(p).name
       local fd = core.registered_nodes[feet]
       local floor = core.registered_nodes[core.get_node({x = p.x, y = p.y - 1, z = p.z}).name]
       return fd ~= nil and (open(p) or core.get_item_group(feet, 'carpet') > 0)
        and open({x = p.x, y = p.y + 1, z = p.z})
        and floor ~= nil and floor.walkable ~= false
        and (floor.damage_per_second or 0) <= 0
        and (floor.liquidtype == nil or floor.liquidtype == 'none')
      end
      for i, bed in ipairs(beds.beds) do
       if i > 1 then
        local a, c = beds.beds[i - 1].pos, bed.pos
        if not (a.x < c.x or (a.x == c.x and (a.y < c.y or (a.y == c.y and a.z < c.z)))) then bad = bad + 1 end
       end
       local nb, nt = core.get_node(bed.pos), core.get_node(bed.top)
       local d = core.facedir_to_dir(nb.param2)
       if core.get_item_group(nb.name, 'bed') ~= 1 or core.get_item_group(nt.name, 'bed') ~= 2
         or nt.param2 ~= nb.param2 or not vector.equals(bed.top, vector.add(bed.pos, d))
         or not spawn_ok(bed.spawn) then
        bad = bad + 1
       end
       -- mcl_beds' own top-lookup agrees with the reported top.
       if mcl_beds and mcl_beds.get_bed_top and not vector.equals(mcl_beds.get_bed_top(bed.pos), bed.top) then bad = bad + 1 end
      end
      check(bad == 0, 'reported beds are sorted, paired and have a free spawn cell (' .. bad .. ' bad)')
     end
    end
    -- Residents (ticket #48): the build already spawned one villager per
    -- valid bed; verify against the world, then repeat and simulate an
    -- interrupted attempt. Phase 2 (a fresh server start on the same world)
    -- re-checks persistence.
    do
     local beds = town.beds
     local res = town.residents
     check(res ~= nil, 'resident initialization report present' .. (town.residents_error and (': ' .. town.residents_error) or ''))
     if beds and res then
      report.residents = {spawned = res.spawned, failed = res.failed, already_done = res.already_done,
       claimed = res.claimed, interrupted = res.interrupted, line = res.summary}
      check(res.spawned == beds.count and res.failed == 0, 'one resident spawned per valid bed (' .. res.spawned .. ' of ' .. beds.count .. ', ' .. res.failed .. ' failed)')
      local mid = vector.multiply(vector.add(town.bounds.min, town.bounds.max), 0.5)
      local function villagers()
       local out = {}
       for _, o in ipairs(core.get_objects_inside_radius(mid, 400)) do
        local le = o:get_luaentity()
        if le and le.name == 'mobs_mc:villager' then out[#out + 1] = le end
       end
       return out
      end
      local vs = villagers()
      check(#vs >= beds.count, 'villager entities cover the valid beds (' .. #vs .. ' vs ' .. beds.count .. ')')
      local bed_at = {}
      for _, b in ipairs(beds.beds) do bed_at[core.pos_to_string(b.pos)] = b end
      local bad, used = 0, {}
      for _, le in ipairs(vs) do
       local b = le._bed and bed_at[core.pos_to_string(le._bed)]
       local meta = b and core.get_meta(b.pos)
       if not b or used[core.pos_to_string(b.pos)] or not le._id or meta:get_string('villager') ~= le._id
         or meta:get_string('player') ~= '' then
        bad = bad + 1
       else
        used[core.pos_to_string(b.pos)] = true
        -- The villager's own validate_bed/take_bed rule: within 2 of the node.
        if vector.distance(le.object:get_pos(), b.pos) > 4 then bad = bad + 1 end
       end
      end
      check(bad == 0, 'each villager owns exactly one valid bed and the bed meta agrees (' .. bad .. ' bad)')
      local meta_claims = 0
      for _, b in ipairs(beds.beds) do
       if core.get_meta(b.pos):get_string('villager') ~= '' then meta_claims = meta_claims + 1 end
      end
      check(meta_claims == beds.count, 'every valid bed carries a villager claim (' .. meta_claims .. ')')
      local store = towns.place_town.store
      local again = towns.residents.initialize(beds.beds, towns.residents.core_env(core), store)
      report.residents.repeat_call = {spawned = again.spawned, already_done = again.already_done}
      check(again.spawned == 0 and again.already_done == beds.count and again.failed == 0, 'repeated initialization spawns nothing (' .. again.spawned .. ' spawned, ' .. again.already_done .. ' already done)')
      check(#villagers() == beds.count, 'villager count unchanged after repeat')
      -- Interrupted attempt: a leftover pending record is reported, not retried.
      if beds.beds[1] then
       local k = towns.residents.record_key(beds.beds[1].pos)
       local saved = store.get(k)
       store.set(k, 'pending')
       local pend = towns.residents.initialize(beds.beds, towns.residents.core_env(core), store)
       store.set(k, saved)
       check(pend.interrupted == 1 and pend.spawned == 0, 'pending record is reported and not retried')
       check(#villagers() == beds.count, 'villager count unchanged after pending restart')
      end
      local ids = {}
      for _, b in ipairs(town.structures) do
       ids[#ids + 1] = {id = b.id, kind = b.kind, min = b.min, max = b.max}
      end
      report.resident_boxes = ids
      report.resident_bed_count = beds.count
     end
    end
    -- Living Villages recognizes the tavern jukebox (its own keeper.lua claim
    -- logic) and the well (its own well.lua examine), by calling its modules.
    do
     local lv = core.get_modpath('living_villages')
     check(lv ~= nil, 'living_villages is loaded')
     if lv then
      local keeper = dofile(lv .. '/keeper.lua')
      local well_mod = dofile(lv .. '/well.lua')
      local taverns, jukeboxes, claimed, wells, recognized_wells = 0, 0, 0, 0, 0
      for _, b in ipairs(town.structures) do
       if b.id == 'tavern' then
        taverns = taverns + 1
        for _, p in ipairs(core.find_nodes_in_area(b.min, b.max, {'mcl_jukebox:jukebox'})) do
         jukeboxes = jukeboxes + 1
         local meta = core.get_meta(p)
         local before = meta:get_string('villager')
         local villager = {_id = 'towns-place-check', _profession = 'unemployed', child = false}
         if before == '' and keeper.employ(villager, p) and meta:get_string('villager') == 'towns-place-check'
           and villager._villages_keeper == true and keeper.claimed_jukebox(villager) ~= nil then
          claimed = claimed + 1
         end
         meta:set_string('villager', before)
        end
       elseif b.id == 'well' then
        wells = wells + 1
        local found = false
        for _, p in ipairs(core.find_nodes_in_area(b.min, b.max, {'mcl_core:water_source'})) do
         if not found and core.get_node({x = p.x + 1, y = p.y, z = p.z}).name == 'mcl_core:water_source'
          and core.get_node({x = p.x, y = p.y, z = p.z + 1}).name == 'mcl_core:water_source'
          and core.get_node({x = p.x + 1, y = p.y, z = p.z + 1}).name == 'mcl_core:water_source' then
          local w = well_mod.examine(p)
          if w then found = true; recognized_wells = recognized_wells + 1; report.well_at = p end
         end
        end
       end
      end
      report.living_villages = {taverns = taverns, jukeboxes = jukeboxes, claimable_jukeboxes = claimed,
       wells = wells, recognized_wells = recognized_wells}
      check(taverns >= 1, 'the town contains a tavern (' .. taverns .. ')')
      check(jukeboxes >= 1 and claimed == jukeboxes, 'every tavern jukebox is claimable by a Living Villages keeper (' .. claimed .. ' of ' .. jukeboxes .. ')')
      check(wells >= 1, 'the town contains a well (' .. wells .. ')')
      check(wells >= 1 and recognized_wells == wells, 'every well is recognized by Living Villages well.lua (' .. recognized_wells .. ' of ' .. wells .. ')')
     end
    end
    finish()
   end)
   if not ok2 then check(false, 'verification error: ' .. tostring(err2)); finish() end
  end)
  end)
 end)
 if not ok then check(false, 'startup error: ' .. tostring(err)); finish() end
end) end)
