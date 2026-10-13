-- Runs only in a disposable snapshot created by export.py.
local function read_json(path)
 local f=assert(io.open(path));local value=assert(core.parse_json(f:read('*a')));f:close();return value
end
local function write_json(path,value)
 local f=assert(io.open(path,'w'));f:write(assert(core.write_json(value,true)));f:close()
end
local function plain(v)
 if type(v)=='userdata' then return v:to_string() end
 if type(v)~='table' then return v end
 local t={} for k,w in pairs(v) do t[k]=plain(w) end return t
end
local function offset(p,lo,size,r)
 local x,y,z=p.x-lo.x,p.y-lo.y,p.z-lo.z
 if r==90 then x,z=z,size.x-1-x
 elseif r==180 then x,z=size.x-1-x,size.z-1-z
 elseif r==270 then x,z=size.z-1-z,x end
 return {x=x,y=y,z=z}
end
core.register_on_mods_loaded(function() core.after(0,function()
 local wp=core.get_worldpath();local config=read_json(wp..'/buildings.json')
 local min={x=31000,y=31000,z=31000};local max={x=-31000,y=-31000,z=-31000}
 for _,j in ipairs(config.buildings) do for _,k in ipairs({'x','y','z'}) do min[k]=math.min(min[k],j.scan_min[k]);max[k]=math.max(max[k],j.scan_max[k]) end end
 core.emerge_area(min,max,function(_,action,remaining)
  assert(action~=core.EMERGE_CANCELLED and action~=core.EMERGE_ERRORED,'Emerge failed')
  if remaining~=0 then return end
  core.after(0,function()
   local vm=VoxelManip();vm:read_from_map(min,max)
   local results={}
   for index,j in ipairs(config.buildings) do
    local lo={x=31000,y=j.floor_y,z=31000};local hi={x=-31000,y=j.floor_y,z=-31000}
    -- Bounds include everything above the finished floor, and floor-level steps.
    -- Workshop labels and terrain/paving outside the structure are excluded.
    for z=j.scan_min.z,j.scan_max.z do for y=j.floor_y,j.scan_max.y do for x=j.scan_min.x,j.scan_max.x do
     local n=core.get_node({x=x,y=y,z=z});assert(n.name~='ignore')
     local label=j.label_position and x==j.label_position.x and y==j.label_position.y and z==j.label_position.z
     local use=n.name~='air' and not label and (y>j.floor_y or n.name:find('^mcl_stairs:stair_'))
     if use then lo.x=math.min(lo.x,x);lo.z=math.min(lo.z,z);hi.x=math.max(hi.x,x);hi.z=math.max(hi.z,z);hi.y=math.max(hi.y,y) end
    end end end
    assert(lo.x<=hi.x,j.id..' has no structure')
    assert(lo.x>j.scan_min.x and lo.z>j.scan_min.z and hi.x<j.scan_max.x and hi.z<j.scan_max.z and hi.y<j.scan_max.y,j.id..' reaches survey edge; enlarge scan bounds')
    local size=vector.add(vector.subtract(hi,lo),1)
    local entrance=offset(j.entrance,lo,size,j.rotation)
    assert(core.get_node(j.entrance).name:find('_door_b_'),j.id..' entrance moved; update buildings.json')
    assert(entrance.y==1,j.id..' entrance must sit one node above floor')
    local raw=wp..'/'..j.id..'_source.mts';assert(core.create_schematic(lo,hi,nil,raw))
    local target={x=index*40,y=150,z=0};local rotated_size={x=size.x,y=size.y,z=size.z}
    if j.rotation==90 or j.rotation==270 then rotated_size.x,rotated_size.z=size.z,size.x end
    local v=VoxelManip();v:read_from_map(target,vector.add(target,vector.subtract(rotated_size,1)))
    assert(core.place_schematic(target,raw,tostring(j.rotation),nil,true))
    local output=wp..'/export/'..j.id..'.mts';assert(core.create_schematic(target,vector.add(target,vector.subtract(rotated_size,1)),nil,output))
    local metadata={};local nodes={};local dependencies={};local count=0
    for z=lo.z,hi.z do for y=lo.y,hi.y do for x=lo.x,hi.x do
     local p={x=x,y=y,z=z};local source=core.get_node(p);local o=offset(p,lo,size,j.rotation);local n=core.get_node(vector.add(target,o));assert(n.name==source.name,'Rotation changed node name')
     count=count+1
     if n.name~='air' then
      dependencies[n.name]=true
      nodes[#nodes+1]={offset=o,name=n.name,param2=n.param2}
      local m=plain(core.get_meta(p):to_table());local fields={}
      -- Retain structural state and visible decoration; constructors regenerate formspecs.
      for k,val in pairs(m.fields or {}) do if k=='is_open' or k=='is_mirrored' or k=='utext' or k=='player_leaves' or k=='wet' then fields[k]=val end end
      local inventory=m.inventory or {}
      if next(fields) or next(inventory) then metadata[#metadata+1]={offset=o,name=n.name,fields=fields,inventory=inventory} end
     end
    end end end
    -- Verify exported file by rotating it back into source orientation.
    local inverse={x=index*40,y=150,z=60};local v2=VoxelManip();v2:read_from_map(inverse,vector.add(inverse,vector.subtract(size,1)))
    assert(core.place_schematic(inverse,output,tostring((360-j.rotation)%360),nil,true))
    for z=0,size.z-1 do for y=0,size.y-1 do for x=0,size.x-1 do
     local a=core.get_node(vector.add(lo,{x=x,y=y,z=z}));local b=core.get_node(vector.add(inverse,{x=x,y=y,z=z}));assert(a.name==b.name and a.param2==b.param2,j.id..' inverse rotation mismatch')
    end end end
    local names={} for name in pairs(dependencies) do names[#names+1]=name end table.sort(names)
    local r={id=j.id,label=j.label,source_min=lo,source_max=hi,source_size=size,size=rotated_size,rotation=j.rotation,entrance=entrance,metadata=metadata,nodes=nodes,required_nodes=names,verified_nodes=count}
    write_json(wp..'/export/'..j.id..'.json',r);results[#results+1]=r
   end
   write_json(wp..'/export/results.json',results)
   core.request_shutdown('Workshop exported',false,0)
  end)
 end)
end) end)
