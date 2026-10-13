-- Headless integration check; only ever installed in an export snapshot.
local root = core.settings:get('towns_export_repo')
local catalog = dofile(root..'/src/catalog.lua')
local place = dofile(root..'/src/schematic.lua')
local geometry = dofile(root..'/src/geometry.lua')
core.register_on_mods_loaded(function() core.after(0,function()
 local total, inventories, count=0,0,0
 for index,id in ipairs(catalog.ids()) do
  local entry=catalog.get(id)
  do
   local path=root..'/'..entry.path;local s=assert(core.read_schematic(path,{}))
   local data=entry.data_path and dofile(root..'/'..entry.data_path) or {metadata={}}
   for ri,rotation in ipairs({0,90,180,270}) do
    local pos={x=index*160,y=150,z=400+ri*160}
    local shape=geometry.place(entry,pos,rotation)
    local vm=VoxelManip();vm:read_from_map(shape.min,shape.max)
    local reference=vector.add(pos,{x=70,y=0,z=0})
    local reference_vm=VoxelManip();reference_vm:read_from_map(reference,vector.add(shape.max,{x=70,y=0,z=0}))
    assert(core.place_schematic(reference,path,tostring(rotation),nil,true))
    assert(place.place(entry,pos,rotation,root))
    for z=0,s.size.z-1 do for y=0,s.size.y-1 do for x=0,s.size.x-1 do
     local p=vector.add(pos,place.rotate_offset(s.size,{x=x,y=y,z=z},rotation))
     local expected=s.data[z*s.size.x*s.size.y+y*s.size.x+x+1]
     assert(core.get_node(p).name==expected.name,id..' node name mismatch')
     local have=core.get_node(p);local wanted=core.get_node(vector.add(p,{x=70,y=0,z=0}))
     assert(have.name==wanted.name and have.param2==wanted.param2,id..' constructed node/orientation mismatch')
     total=total+1
    end end end
    local entrance=shape.entrance
    if id=='castle' then
     local n=core.get_node(entrance)
     assert(n.name=='mcl_fences:fence_gate_open', 'castle gate opening mismatch: '..n.name)
     local plan=towns.placement.plan(entry,{x=0,y=8,z=0},rotation)
     assert(plan.pos.y==3 and plan.building.entrance.y==11, 'castle foundation/gate height mismatch')
    else
     assert(core.get_node(entrance).name:find('_door_b_'),id..' entrance mismatch')
    end
    for _,saved in ipairs(data.metadata) do
     local p=vector.add(pos,place.rotate_offset(s.size,saved.offset,rotation));local meta=core.get_meta(p)
     for k,v in pairs(saved.fields or {}) do assert(meta:get_string(k)==v,id..' field mismatch') end
     local inv=meta:get_inventory()
     for name,items in pairs(saved.inventory or {}) do for i,item in ipairs(items) do
      local got=inv:get_stack(name,i);local expected=ItemStack(item)
      assert(got:get_name()==expected:get_name() and got:get_count()==expected:get_count() and got:get_wear()==expected:get_wear(),id..' inventory mismatch')
      local gf=got:get_meta():to_table().fields or {};local ef=expected:get_meta():to_table().fields or {}
      for k,v in pairs(ef) do assert(gf[k]==v,id..' item metadata mismatch') end
      for k,v in pairs(gf) do assert(ef[k]==v,id..' extra item metadata') end
      inventories=inventories+1
     end end
    end
    count=count+1
   end
  end
 end
 local f=assert(io.open(core.get_worldpath()..'/runtime-validation.json','w'));f:write(core.write_json({placements=count,nodes=total,inventory_slots=inventories,mismatches=0}));f:close()
 core.request_shutdown('Template runtime validated',false,0)
end) end)
