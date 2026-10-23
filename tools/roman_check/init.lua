-- Installed only by run.py in a disposable world. No real-world mutations.
local root = core.get_modpath('towns')
local catalog = dofile(root .. '/src/catalog.lua')
local geometry = dofile(root .. '/src/geometry.lua')
local schematic = dofile(root .. '/src/schematic.lua')
local setup = dofile(root .. '/src/node_setup.lua')
local residents = dofile(root .. '/src/residents.lua')
local expect = dofile(core.get_modpath('roman_check') .. '/expect.lua')
-- Every landmark and rotation is checked; failures are collected, not fatal.
-- mismatches: node names/param2 that differ from the expectation (see expect.lua).
-- errors: a check that raised for one landmark and rotation.
local report = {placements = {}, nodes = 0, metadata = 0, inventory_slots = 0, mismatches = {}, errors = {}}
local ground_samples = {
 arch = {{x=0,y=0,z=0},'mcl_core:dirt_with_grass'},
 -- Temple: the Y=0 terrain row is the datum (#134); the quartz platform starts at Y=1.
 temple = {{x=0,y=0,z=0},'mcl_core:dirt_with_grass'},
 domus = {{x=0,y=1,z=0},'mcl_core:dirt_with_grass'},
 theatre = {{x=0,y=3,z=0},'mcl_core:dirt_with_grass'},
 amphitheater = {{x=0,y=2,z=0},'mcl_core:dirt_with_grass'},
 bath = {{x=0,y=2,z=0},'mcl_core:dirt_with_grass'},
 insula = {{x=0,y=2,z=0},'mcl_core:gravel'},
 vespasianum = {{x=0,y=2,z=0},'mcl_core:dirt_with_grass'},
 basilica = {{x=0,y=2,z=0},'mcl_core:dirt_with_grass'},
}

local function run()
 local invalid = catalog.verify(function(path) return core.read_schematic(path, {}) end, root)
 assert(next(invalid) == nil, core.write_json(invalid))
 local setup_env = setup.core_env(core, {itemframes = mcl_itemframes, chests = mcl_chests},
  function(s) return schematic.required_nodes(catalog.get(s.id), root) end)
 for index, id in ipairs(catalog.ids_for_role('landmark')) do
  local entry = catalog.get(id)
  local source = assert(core.read_schematic(root .. '/' .. entry.path, {}))
  local data = dofile(root .. '/' .. entry.data_path)
  for ri, rotation in ipairs({0,90,180,270}) do
   local okr, errr = pcall(function()
   local ground = 100
   local pos = {x = index * 300, y = ground - entry.ground_offset, z = ri * 160}
   local shape = geometry.place(entry, pos, rotation)
   local reference = vector.add(pos, {x = 120, y = 0, z = 0})
   -- Load the full capture (including basement), plus a flat exterior apron.
   local vm = VoxelManip()
   vm:read_from_map(vector.subtract(shape.min, 4), vector.add(shape.max, {x=124,y=4,z=4}))
   for x = shape.min.x - 3, shape.max.x + 3 do
    for z = shape.min.z - 3, shape.max.z + 3 do
     core.set_node({x=x,y=ground,z=z}, {name='mcl_core:dirt_with_grass'})
    end
   end
   assert(core.place_schematic(reference, root .. '/' .. entry.path, tostring(rotation), nil, true))
   assert(schematic.place(entry, pos, rotation, root, {initialize=false}))
   -- Every voxel, including basement/air, and every native rotated param2.
   -- Names are the ones schematic.place leaves: walls are renamed from their
   -- placed neighbours (#178), so the expectation applies the same recompute.
   local expected = expect.expected_names(source, rotation, schematic)
   for z=0,source.size.z-1 do for y=0,source.size.y-1 do for x=0,source.size.x-1 do
    local o = schematic.rotate_offset(source.size, {x=x,y=y,z=z}, rotation)
    local p = vector.add(pos, o)
    local actual = core.get_node(p)
    local want = expected[expect.key(o)]
    local native = core.get_node(vector.add(p, {x=120,y=0,z=0}))
    if actual.name ~= want or actual.param2 ~= native.param2 then
     table.insert(report.mismatches, {id=id, rotation=rotation, at=core.pos_to_string(p),
      expected=want, actual=actual.name, native_param2=native.param2, actual_param2=actual.param2})
    else
     report.nodes = report.nodes + 1
    end
   end end end
   local structure = {id=id,kind='landmark',min=shape.min,max=shape.max}
   local initialized = setup.initialize({structure}, setup_env, {})
   assert(initialized.ok, id .. ' initialization: ' .. setup.format(initialized)
    .. ' ' .. core.write_json(initialized.unhandled))
   -- Constructors must retain all captured fields and inventory item metadata.
   for _, saved in ipairs(data.metadata) do
    local p = vector.add(pos, schematic.rotate_offset(source.size, saved.offset, rotation))
    local meta = core.get_meta(p)
    for key, value in pairs(saved.fields or {}) do
     assert(meta:get_string(key) == value, id .. ' metadata field ' .. key)
    end
    for list, items in pairs(saved.inventory or {}) do
     for i, item in ipairs(items) do
      local got, wanted = meta:get_inventory():get_stack(list,i), ItemStack(item)
      assert(got:to_string() == wanted:to_string(), id .. ' inventory item mismatch')
      report.inventory_slots = report.inventory_slots + 1
     end
    end
    report.metadata = report.metadata + 1
   end
   local entrance = core.get_node(shape.entrance).name
   if entry.entrance_kind == 'door' then
    assert(entrance:find('_door_b_'), id .. ' entrance is not a door')
   else
    assert(entrance == 'air' and core.get_node(vector.add(shape.entrance,{x=0,y=1,z=0})).name == 'air',
     id .. ' entrance opening blocked')
   end
   local floor = core.get_node(vector.add(shape.entrance,{x=0,y=-1,z=0})).name
   assert(core.registered_nodes[floor].walkable ~= false, id .. ' entrance unsupported')
   local sample = ground_samples[id]
   local datum = vector.add(pos, schematic.rotate_offset(source.size,sample[1],rotation))
   assert(datum.y == ground and core.get_node(datum).name == sample[2], id .. ' ground alignment')
   -- Inspect the outward approach through the capture margin to site ground.
   -- This checks an existing straight approach, without changing any routing.
   local approach, last_y = {}, shape.entrance.y - 1
   local x,z = shape.outside.x,shape.outside.z
   while true do
    local floor_y
    for y=shape.entrance.y-1,ground-1,-1 do
     local function walkable(dy)
      return core.registered_nodes[core.get_node({x=x,y=y+dy,z=z}).name].walkable ~= false
     end
     if walkable(0) and not walkable(1) and not walkable(2) then floor_y=y; break end
    end
    assert(floor_y and math.abs(floor_y-last_y) <= 1, id .. ' obstructed/steep approach')
    approach[#approach+1] = {x=x,y=floor_y,z=z}
    last_y = floor_y
    if x<shape.min.x or x>shape.max.x or z<shape.min.z or z>shape.max.z then
     assert(floor_y == ground, id .. ' approach does not reach site ground')
     break
    end
    x,z = x+shape.front.x,z+shape.front.z
   end
   if id == 'bath' then
    for _, sample in ipairs({
     {{x=0,y=1,z=0},'mcl_core:dirt'},
     {{x=0,y=2,z=0},'mcl_core:dirt_with_grass'},
     {{x=40,y=1,z=33},'mcl_beds:bed_brown_bottom'},
    }) do
     local p = vector.add(pos, schematic.rotate_offset(source.size,sample[1],rotation))
     assert(core.get_node(p).name == sample[2], 'bath plinth/basement mismatch')
    end
   end
   local beds = residents.enumerate({structure}, residents.core_env(core))
   report.placements[#report.placements+1] = {
    id=id,rotation=rotation,origin=pos,ground_y=ground,entrance=shape.entrance,
    front=shape.front,entrance_node=entrance,floor=floor,
    ground_probe=datum,approach_floors=approach,
    initialized=initialized.initialized,beds=beds.count,skipped_beds=beds.skipped,
   }
   end)
   if not okr then
    table.insert(report.errors, {id=id, rotation=rotation, error=tostring(errr)})
   end
  end
 end
end

core.register_on_mods_loaded(function() core.after(0, function()
 local ok, err = pcall(run)
 report.ok = ok and #report.errors == 0 and #report.mismatches == 0
 if not ok then report.error = tostring(err) end
 local stream = assert(io.open(core.get_worldpath() .. '/roman-check.json','w'))
 stream:write(core.write_json(report,true)); stream:close()
 core.request_shutdown('Roman capture check complete',false,0)
end) end)
