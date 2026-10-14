-- Placement of a catalog schematic plus its saved decoration/inventory data.
-- Constructors regenerate position-dependent formspecs; source ownership,
-- simulation timestamps, and world coordinates are never imported.
local M = {}
local cache = {}

function M.rotate_offset(size, p, rotation)
 local x, z = p.x, p.z
 rotation = tonumber(rotation)
 assert(rotation == 0 or rotation == 90 or rotation == 180 or rotation == 270, 'invalid schematic rotation')
 if rotation == 90 then x, z = z, size.x - 1 - x
 elseif rotation == 180 then x, z = size.x - 1 - x, size.z - 1 - z
 elseif rotation == 270 then x, z = size.z - 1 - z, x end
 return {x = x, y = p.y, z = z}
end

local function data(entry, modpath)
 if not entry.data_path then return {metadata = {}, required_nodes = {}} end
 local path = modpath .. '/' .. entry.data_path
 if not cache[path] then cache[path] = dofile(path) end
 return cache[path]
end

-- The node names the entry's schematic contains: the exporter's saved list
-- when there is one, otherwise read from the .mts itself (hand-captured
-- entries such as demo_house have no data file).
local names_cache = {}
function M.required_nodes(entry, modpath)
 if entry.data_path then return data(entry, modpath).required_nodes end
 local path = modpath .. '/' .. entry.path
 if not names_cache[path] then
  local s = assert(core.read_schematic(path, {}))
  local seen, list = {}, {}
  for _, node in ipairs(s.data) do
   if node.name ~= 'air' and node.name ~= 'ignore' and not seen[node.name] then
    seen[node.name] = true
    list[#list + 1] = node.name
   end
  end
  table.sort(list)
  names_cache[path] = list
 end
 return names_cache[path]
end

function M.validate(entry, modpath)
 for _, name in ipairs(data(entry, modpath).required_nodes) do
  if not core.registered_nodes[name] then
   return nil, "Required node '" .. name .. "' is unavailable; enable its mod before placing " .. entry.id
  end
 end
 return true
end

-- opts.initialize = false: write the nodes and restore saved metadata and
-- inventories only. The caller runs the node setup adapter (node_setup.lua,
-- ticket #46) afterwards instead of the blanket constructors and displays
-- below. The default keeps /towns_test's behaviour.
function M.place(entry, pos, rotation, modpath, opts)
 local initialize = not (opts and opts.initialize == false)
 local ok, reason = M.validate(entry, modpath)
 if not ok then return nil, reason end
 local s = assert(core.read_schematic(modpath .. '/' .. entry.path, {}))
 if not core.place_schematic(pos, modpath .. '/' .. entry.path, tostring(rotation), nil, true) then
  return nil, 'Schematic placement failed'
 end
 local positions = {}
 for z = 0, s.size.z - 1 do for y = 0, s.size.y - 1 do for x = 0, s.size.x - 1 do
  local p = vector.add(pos, M.rotate_offset(s.size, {x=x,y=y,z=z}, rotation))
  local node = core.get_node(p)
  if node.name ~= 'air' then
   positions[#positions + 1] = p
   local def = core.registered_nodes[node.name]
   -- Armor stand activation reads its inventory, so defer it until restoration.
   -- Foliage construction recomputes biome colors/flags; keep the authored param2.
   if initialize and def and def.on_construct and node.name ~= 'mcl_armor_stand:armor_stand'
      and not node.name:find('^mcl_decor:hedge_')
      and core.get_item_group(node.name, 'foliage_palette') == 0
      and core.get_item_group(node.name, 'leaves') == 0 then def.on_construct(p) end
  end
 end end end
 for _, saved in ipairs(data(entry, modpath).metadata or {}) do
  local p = vector.add(pos, M.rotate_offset(s.size, saved.offset, rotation))
  local meta = core.get_meta(p)
  for key, value in pairs(saved.fields or {}) do meta:set_string(key, value) end
  local inv = meta:get_inventory()
  for name, items in pairs(saved.inventory or {}) do
   inv:set_size(name, #items)
   inv:set_list(name, items)
  end
 end
 for _, p in ipairs(initialize and positions or {}) do
  local node = core.get_node(p)
  if node.name == 'mcl_armor_stand:armor_stand' then core.registered_nodes[node.name].on_construct(p)
  elseif mcl_itemframes and node.name:find('^mcl_itemframes:') then mcl_itemframes.update_entity(p)
  elseif mcl_chests and core.get_item_group(node.name, 'chest_entity') > 0 then mcl_chests.select_and_spawn_entity(p, node)
  elseif mcl_signs and node.name:find('^mcl_signs:') then mcl_signs.update_sign(p) end
 end
 return true
end

return M
