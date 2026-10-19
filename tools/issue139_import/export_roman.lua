local function plain(v)
 if type(v)=='userdata' then return v.to_string and v:to_string() or tostring(v) end
 if type(v)~='table' then return v end
 local t={};for k,w in pairs(v) do if w~=nil then t[k]=plain(w) end end;return t
end
core.register_on_mods_loaded(function() core.after(0,function()
 local f=assert(io.open(core.get_worldpath()..'/roman-export.json','r'))
 local buildings=assert(core.parse_json(f:read('*a')));f:close()
 local low={x=31000,y=31000,z=31000};local high={x=-31000,y=-31000,z=-31000}
 for _,b in ipairs(buildings) do
  for _,k in ipairs({'x','y','z'}) do low[k]=math.min(low[k],b.min[k]);high[k]=math.max(high[k],b.max[k]) end
 end
 core.emerge_area(low,high,function(_,action,remaining)
  assert(action~=core.EMERGE_CANCELLED and action~=core.EMERGE_ERRORED,'Emerge failed')
  if remaining~=0 then return end
  core.after(0,function()
   local out={}
   for _,b in ipairs(buildings) do
    local size={x=b.max.x-b.min.x+1,y=b.max.y-b.min.y+1,z=b.max.z-b.min.z+1}
    local names,metadata={},{}
    for z=b.min.z,b.max.z do for y=b.min.y,b.max.y do for x=b.min.x,b.max.x do
     local p={x=x,y=y,z=z};local node=core.get_node(p)
     assert(node.name~='ignore','Unloaded node in '..b.id)
     if node.name~='air' then names[node.name]=true end
     local meta=core.get_meta(p):to_table()
     if meta and (next(meta.fields or {}) or next(meta.inventory or {})) then
      metadata[#metadata+1]={offset={x=x-b.min.x,y=y-b.min.y,z=z-b.min.z},fields=plain(meta.fields or {}),inventory=plain(meta.inventory or {})}
     end
    end end end
    local path=core.get_worldpath()..'/out/'..b.id..'.mts'
    assert(core.create_schematic(b.min,b.max,nil,path),'Could not capture '..b.id)
    local sorted={};for n in pairs(names) do sorted[#sorted+1]=n end;table.sort(sorted)
    out[#out+1]={id=b.id,size=size,metadata=metadata,required_nodes=sorted}
   end
   local w=assert(io.open(core.get_worldpath()..'/roman-results.json','w'))
   w:write(assert(core.write_json(out,true)));w:close()
   core.request_shutdown('Roman asset export complete',false,0)
  end)
 end)
end) end)
