local function read_json(path)
 local f=assert(io.open(path,'r'));local v=assert(core.parse_json(f:read('*a')));f:close();return v
end
local function plain(v)
 if type(v)=='userdata' then return v.to_string and v:to_string() or tostring(v) end
 if type(v)~='table' then return v end
 local t={};for k,w in pairs(v) do if w~=nil then t[k]=plain(w) end end;return t
end
core.register_on_mods_loaded(function() core.after(0,function()
 local jobs=read_json(core.get_worldpath()..'/issue341.json')
 local low={x=31000,y=31000,z=31000};local high={x=-31000,y=-31000,z=-31000}
 for _,j in ipairs(jobs) do
  local margin=j.probe_margin or {}
  for _,k in ipairs({'x','y','z'}) do
   local m=margin[k] or 0
   low[k]=math.min(low[k],j.min[k]-m,j.max[k]-m);high[k]=math.max(high[k],j.min[k]+m,j.max[k]+m)
  end
 end
 core.emerge_area(low,high,function(_,action,remaining)
  assert(action~=core.EMERGE_CANCELLED and action~=core.EMERGE_ERRORED,'Emerge failed')
  if remaining~=0 then return end
  core.after(0,function()
   local report={}
   for _,j in ipairs(jobs) do
    local lo={x=math.min(j.min.x,j.max.x),y=math.min(j.min.y,j.max.y),z=math.min(j.min.z,j.max.z)}
    local hi={x=math.max(j.min.x,j.max.x),y=math.max(j.min.y,j.max.y),z=math.max(j.min.z,j.max.z)}
    for z=lo.z,hi.z do for y=lo.y,hi.y do for x=lo.x,hi.x do
     assert(core.get_node({x=x,y=y,z=z}).name~='ignore','Unloaded node in '..j.id)
    end end end
    local margin=j.probe_margin or {};local extension={x={},y={},z={}}
    for _,axis in ipairs({'x','y','z'}) do
     local m=margin[axis] or 0
     if m>0 then
      local first,last=lo[axis]-m,hi[axis]+m
      for coord=first,last do
       local outside=coord<lo[axis] or coord>hi[axis]
       local edge_profile=axis=='x' and (coord==lo.x or coord==lo.x+1 or coord==hi.x-1 or coord==hi.x)
       if outside or edge_profile then
        local count=0;local types={};local layers={}
        local x0,x1=lo.x,hi.x;local y0,y1=lo.y,hi.y;local z0,z1=lo.z,hi.z
        if axis=='x' then x0,x1=coord,coord elseif axis=='y' then y0,y1=coord,coord else z0,z1=coord,coord end
        for z=z0,z1 do for y=y0,y1 do for x=x0,x1 do
         local name=core.get_node({x=x,y=y,z=z}).name
         if name~='air' then
          count=count+1;types[name]=(types[name] or 0)+1
          if axis=='x' then
           local layer=layers[y] or {coord=y,non_air=0,nodes={}};layer.non_air=layer.non_air+1
           layer.nodes[name]=(layer.nodes[name] or 0)+1;layers[y]=layer
          end
         end
        end end end
        local type_list={};for name,n in pairs(types) do type_list[#type_list+1]={name=name,count=n} end
        table.sort(type_list,function(a,b)return a.name<b.name end)
        local layer_list={};for _,layer in pairs(layers) do
         local layer_types={};for name,n in pairs(layer.nodes) do layer_types[#layer_types+1]={name=name,count=n} end
         table.sort(layer_types,function(a,b)return a.name<b.name end);layer.nodes=layer_types;layer_list[#layer_list+1]=layer
        end
        table.sort(layer_list,function(a,b)return a.coord<b.coord end)
        extension[axis][#extension[axis]+1]={coord=coord,outside=outside,non_air=count,nodes=type_list,layers=layer_list}
       end
      end
     end
    end
    local out=core.get_worldpath()..'/schems/'..j.id..'.mts'
    assert(core.create_schematic(lo,hi,nil,out),'Could not capture '..j.id)
    local s=assert(core.read_schematic(out,{write_yslice_prob='all'}))
    local names,doors,metadata={},{},{}
    for z=lo.z,hi.z do for y=lo.y,hi.y do for x=lo.x,hi.x do
     local n=core.get_node({x=x,y=y,z=z})
     names[n.name]=true
     if n.name:find('_door_[bt]_') then doors[#doors+1]={x=x,y=y,z=z,name=n.name} end
     local meta=core.get_meta({x=x,y=y,z=z}):to_table()
     if meta and (next(meta.fields or {}) or next(meta.inventory or {})) then
      metadata[#metadata+1]={offset={x=x-lo.x,y=y-lo.y,z=z-lo.z},name=n.name,meta=plain(meta)}
     end
    end end end
    local list={};for n in pairs(names) do list[#list+1]=n end;table.sort(list)
    report[#report+1]={id=j.id,min=lo,max=hi,size=s.size,doors=doors,nodes=list,metadata=metadata,extension=extension}
   end
   local f=assert(io.open(core.get_worldpath()..'/issue341-report.json','w'))
   local encoded=assert(core.write_json(report,true),'Could not encode capture report')
   f:write(encoded);f:close()
   core.request_shutdown('Issue 341 capture complete',false,0)
  end)
 end)
end) end)
