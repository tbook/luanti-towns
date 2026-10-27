-- Runtime smoke check installed only in an export snapshot. Constructors may
-- normalize node names, so this checks placement, loaded bounds, entrances,
-- and the metadata/inventory data that schematic.lua promises to restore.
local root = core.settings:get('towns_export_repo')
local catalog = dofile(root..'/src/catalog.lua')
local place = dofile(root..'/src/schematic.lua')
local geometry = dofile(root..'/src/geometry.lua')

local function equal_value(a, b)
 if type(a) ~= type(b) then return false end
 if type(a) ~= 'table' then return a == b end
 for key, value in pairs(a) do if not equal_value(value, b[key]) then return false end end
 for key in pairs(b) do if a[key] == nil then return false end end
 return true
end

local function same_stack(actual, saved)
 return equal_value(actual:to_table(), ItemStack(saved):to_table())
end

core.register_on_mods_loaded(function()
 core.after(0, function()
  local placements, non_air_nodes, metadata_nodes, inventory_lists = 0, 0, 0, 0
  for index, id in ipairs(catalog.ids()) do
   local entry = catalog.get(id)
   local data = entry.data_path and dofile(root..'/'..entry.data_path) or {metadata = {}}
   for _, rotation in ipairs({0, 90, 180, 270}) do
    local pos = {x = index * 160, y = 150, z = 400 + rotation}
    local shape = geometry.place(entry, pos, rotation)
    local ok, reason = place.place(entry, pos, rotation, root)
    assert(ok == true, id..' placement failed at rotation '..rotation..': '..tostring(reason))

    local placed = 0
    for x = shape.min.x, shape.max.x do for y = shape.min.y, shape.max.y do for z = shape.min.z, shape.max.z do
     local node = core.get_node({x = x, y = y, z = z})
     assert(node.name ~= 'ignore', id..' left unloaded node at '..core.pos_to_string({x=x,y=y,z=z}))
     if node.name ~= 'air' then placed = placed + 1 end
    end end end
    assert(placed > 0, id..' placed no non-air nodes at rotation '..rotation)
    non_air_nodes = non_air_nodes + placed

    local entrance = shape.entrance
    if id == 'castle' and not entry.data_path then
     local node = core.get_node(entrance)
     assert(node.name == 'mcl_fences:fence_gate_open', 'castle gate opening mismatch: '..node.name)
     local foundation = geometry.place(entry, {x=0,y=8-(entry.ground_offset or 0),z=0}, rotation)
     assert(foundation.min.y == 3 and foundation.entrance.y == 11, 'castle foundation/gate height mismatch')
    elseif entry.entrance_kind == 'opening' then
     assert(core.get_node(entrance).name == 'air'
      and core.get_node(vector.add(entrance, {x=0,y=1,z=0})).name == 'air', id..' opening obstructed')
     local floor = core.get_node(vector.add(entrance, {x=0,y=-1,z=0}))
     assert(floor.name ~= 'air' and core.registered_nodes[floor.name]
      and core.registered_nodes[floor.name].walkable ~= false, id..' opening has no solid floor')
    else
     assert(core.get_node(entrance).name:find('_door_b_'), id..' entrance mismatch')
    end

    for _, saved in ipairs(data.metadata or {}) do
     local p = vector.add(pos, place.rotate_offset(entry.size, saved.offset, rotation))
     local meta = core.get_meta(p)
     for key, value in pairs(saved.fields or {}) do
      assert(meta:get_string(key) == value, id..' metadata field '..key..' was not restored at '..core.pos_to_string(p))
     end
     metadata_nodes = metadata_nodes + 1
     local inv = meta:get_inventory()
     for list, items in pairs(saved.inventory or {}) do
      local restored = inv:get_list(list)
      assert(restored and #restored == #items, id..' inventory list '..list..' has wrong size')
      for slot, item in ipairs(items) do
       assert(same_stack(restored[slot], item), id..' inventory '..list..' slot '..slot..' differs')
      end
      inventory_lists = inventory_lists + 1
     end
    end
    placements = placements + 1
   end
  end
  local f = assert(io.open(core.get_worldpath()..'/runtime-validation.json', 'w'))
  f:write(core.write_json({placements=placements,non_air_nodes=non_air_nodes,
   metadata_nodes=metadata_nodes,inventory_lists=inventory_lists}))
  f:close()
  core.request_shutdown('Template runtime validated', false, 0)
 end)
end)
