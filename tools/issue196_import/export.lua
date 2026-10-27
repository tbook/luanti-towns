local buildings_path = core.get_worldpath() .. "/issue196-buildings.json"
local file = assert(io.open(buildings_path, "r"))
local buildings = assert(core.parse_json(file:read("*a")))
file:close()
local function plain(value)
 if type(value) == "userdata" then return value.to_string and value:to_string() or tostring(value) end
 if type(value) ~= "table" then return value end
 local result = {}
 for key, item in pairs(value) do result[key] = plain(item) end
 return result
end

core.register_on_mods_loaded(function()
 core.after(0, function()
  local low, high = {x=31000,y=31000,z=31000}, {x=-31000,y=-31000,z=-31000}
  for _, b in ipairs(buildings) do for _, axis in ipairs({"x", "y", "z"}) do
   low[axis] = math.min(low[axis], b.min[axis]); high[axis] = math.max(high[axis], b.max[axis])
  end end
  core.emerge_area(low, high, function(_, action, remaining)
   assert(action ~= core.EMERGE_CANCELLED and action ~= core.EMERGE_ERRORED, "Source emerge failed")
   if remaining ~= 0 then return end
   core.after(0, function()
    local results = {}
    for _, b in ipairs(buildings) do
     local size = {x = b.max.x - b.min.x + 1, y = b.max.y - b.min.y + 1, z = b.max.z - b.min.z + 1}
     local metadata = {}
     local required = {}
     for z = b.min.z, b.max.z do for y = b.min.y, b.max.y do for x = b.min.x, b.max.x do
      local p = {x = x, y = y, z = z}
      local node = core.get_node(p)
      assert(node.name ~= "ignore", b.id .. " has unloaded source cells")
      if node.name ~= "air" then required[node.name] = true end
      local meta = core.get_meta(p):to_table()
      if meta and (next(meta.fields or {}) or next(meta.inventory or {})) then
       metadata[#metadata + 1] = {offset={x=x-b.min.x,y=y-b.min.y,z=z-b.min.z},
        name=node.name,fields=plain(meta.fields or {}),inventory=plain(meta.inventory or {})}
      end
     end end end
     local path = core.get_worldpath() .. "/out/" .. b.id .. ".mts"
     assert(core.create_schematic(b.min, b.max, nil, path),
      "Could not capture " .. b.id)
     local target = {x = 800 + #results * 40, y = 20, z = 600}
     VoxelManip():read_from_map(target, {x=target.x+size.x-1,y=target.y+size.y-1,z=target.z+size.z-1})
     assert(core.place_schematic(target, path, "0", nil, true), b.id .. " roundtrip placement failed")
     for z = 0, size.z - 1 do for y = 0, size.y - 1 do for x = 0, size.x - 1 do
      local original = core.get_node({x=b.min.x+x,y=b.min.y+y,z=b.min.z+z})
      local copied = core.get_node({x=target.x+x,y=target.y+y,z=target.z+z})
      assert(original.name == copied.name and original.param2 == copied.param2,
       b.id .. " capture roundtrip differs at " .. x .. "," .. y .. "," .. z)
     end end end
     local names = {}
     for name in pairs(required) do names[#names + 1] = name end
     table.sort(names)
     results[#results + 1] = {id = b.id, size = size, metadata=metadata, required_nodes=names}
    end
    local report = assert(io.open(core.get_worldpath() .. "/issue196-results.json", "w"))
    report:write(assert(core.write_json(results, true)))
    report:close()
    core.request_shutdown("Issue 196 buildings captured", false, 0)
   end)
  end)
 end)
end)
