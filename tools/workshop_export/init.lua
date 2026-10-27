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
-- Match src/schematic.lua:M.wall_name. VoxeLibre stores wall connections in
-- the node name, so rotating a schematic moves the nodes without rotating
-- those connections. Normalize after rotation, using neighbours in the
-- exported box only (the same rule used by runtime placement).
local wall_dirs={{1,0,1},{0,1,2},{-1,0,4},{0,-1,8}}
local function is_wall(name) return core.get_item_group(name,'wall')>0 end
local function wall_name(name,at)
 local base=name:match('^(.*_)%d+$')
 if not base then return name end
 local function connects(n)
  return n~=nil and (core.get_item_group(n,'wall')==1 or core.get_item_group(n,'solid')==1)
 end
 local sum=0
 for _,d in ipairs(wall_dirs) do if connects(at(d[1],0,d[2])) then sum=sum+d[3] end end
 if sum==5 or sum==10 then
  local above=at(0,1,0)
  if connects(above) or (above~=nil and core.get_item_group(above,'torch')==1) then sum=sum+11 end
 end
 return base..sum
end
local function recompute_walls(origin,size)
 local count=0
 for z=0,size.z-1 do for y=0,size.y-1 do for x=0,size.x-1 do
  local p={x=origin.x+x,y=origin.y+y,z=origin.z+z};local node=core.get_node(p)
  if is_wall(node.name) then
   local name=wall_name(node.name,function(dx,dy,dz)
    local nx,ny,nz=x+dx,y+dy,z+dz
    if nx<0 or nx>=size.x or ny<0 or ny>=size.y or nz<0 or nz>=size.z then return nil end
    local n=core.get_node({x=origin.x+nx,y=origin.y+ny,z=origin.z+nz}).name
    return n~='air' and n or nil
   end)
   if name~=node.name then core.swap_node(p,{name=name,param2=node.param2}) end
   count=count+1
  end
 end end end
 return count
end
local function assert_walls_match(origin,size,label)
 local walls,bad=0,0
 for z=0,size.z-1 do for y=0,size.y-1 do for x=0,size.x-1 do
  local p={x=origin.x+x,y=origin.y+y,z=origin.z+z};local node=core.get_node(p)
  if is_wall(node.name) then
   walls=walls+1
   local expected=wall_name(node.name,function(dx,dy,dz)
    local nx,ny,nz=x+dx,y+dy,z+dz
    if nx<0 or nx>=size.x or ny<0 or ny>=size.y or nz<0 or nz>=size.z then return nil end
    local n=core.get_node({x=origin.x+nx,y=origin.y+ny,z=origin.z+nz}).name
    return n~='air' and n or nil
   end)
   if expected~=node.name then bad=bad+1 end
  end
 end end end
 assert(bad==0,label..' has '..bad..' wall connection mismatches among '..walls..' walls')
 return walls
end
-- Read the actual MTS back from disk and inspect its names without placing it
-- or recomputing anything. This catches serialization errors or stale names
-- that an in-memory map check would miss.
local function assert_exported_walls_match(path,size,label)
 local schem=assert(core.read_schematic(path,{}),label..' could not be read back')
 assert(schem.size.x==size.x and schem.size.y==size.y and schem.size.z==size.z,label..' size changed on disk')
 local function node(x,y,z)
  return schem.data[z*size.y*size.x+y*size.x+x+1]
 end
 local walls,bad=0,0
 for z=0,size.z-1 do for y=0,size.y-1 do for x=0,size.x-1 do
  local n=node(x,y,z)
  if is_wall(n.name) then
   walls=walls+1
   local expected=wall_name(n.name,function(dx,dy,dz)
    local nx,ny,nz=x+dx,y+dy,z+dz
    if nx<0 or nx>=size.x or ny<0 or ny>=size.y or nz<0 or nz>=size.z then return nil end
    local q=node(nx,ny,nz).name
    return q~='air' and q or nil
   end)
   if expected~=n.name then bad=bad+1 end
  end
 end end end
 assert(bad==0,label..' has '..bad..' saved wall connection mismatches among '..walls..' walls')
 return walls
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
    -- clip_to_capture: a neighbouring build overlaps the survey margin, so only
    -- the fixed capture box is surveyed (whatever lies outside the box is
    -- ignored, not reported as an escape).
    local s0,s1=j.scan_min,j.scan_max
    if j.clip_to_capture then assert(j.capture_min and j.capture_max,j.id..' clip_to_capture needs a capture box');s0,s1=j.capture_min,j.capture_max end
    for z=s0.z,s1.z do for y=j.floor_y,s1.y do for x=s0.x,s1.x do
     local n=core.get_node({x=x,y=y,z=z});assert(n.name~='ignore')
     local label=j.label_position and x==j.label_position.x and y==j.label_position.y and z==j.label_position.z
     local use=n.name~='air' and not label and (y>(j.ground_y or j.floor_y) or (y==(j.ground_y or j.floor_y) and n.name:find('^mcl_stairs:stair_')))
     if use then lo.x=math.min(lo.x,x);lo.z=math.min(lo.z,z);hi.x=math.max(hi.x,x);hi.z=math.max(hi.z,z);hi.y=math.max(hi.y,y) end
    end end end
    assert(lo.x<=hi.x,j.id..' has no structure')
    assert(lo.x>j.scan_min.x and lo.z>j.scan_min.z and hi.x<j.scan_max.x and hi.z<j.scan_max.z and hi.y<j.scan_max.y,j.id..' reaches survey edge; enlarge scan bounds')
    if j.capture_min then
     -- Landmark compounds keep the chosen full footprint and buried foundation.
     assert(j.capture_max and j.ground_y,'Landmark needs capture_max and ground_y')
     for _,k in ipairs({'x','z'}) do assert(lo[k]>=j.capture_min[k] and hi[k]<=j.capture_max[k],j.id..' extends beyond fixed capture') end
     assert(hi.y<=j.capture_max.y,j.id..' extends above fixed capture')
     lo=vector.new(j.capture_min);hi=vector.new(j.capture_max)
    end
    local size=vector.add(vector.subtract(hi,lo),1)
    local entrance=offset(j.entrance,lo,size,j.rotation)
    local kind=j.entrance_kind or 'door'
    assert(kind=='door' or kind=='opening',j.id..' invalid entrance kind')
    if kind=='opening' then
     assert(core.get_node(j.entrance).name=='air' and core.get_node(vector.add(j.entrance,{x=0,y=1,z=0})).name=='air',j.id..' walk-in entrance obstructed')
     local floor=core.get_node(vector.add(j.entrance,{x=0,y=-1,z=0}))
     local def=core.registered_nodes[floor.name]
     assert(floor.name~='air' and def and def.walkable~=false,j.id..' entrance has no solid floor')
    else
     assert(core.get_node(j.entrance).name:find('_door_b_'),j.id..' entrance moved; update buildings.json')
    end
    if not j.capture_min then assert(entrance.y==1,j.id..' entrance must sit one node above floor') end
    local ground_offset=(j.ground_y or j.floor_y)-lo.y
    assert(ground_offset>=0 and ground_offset<size.y,j.id..' invalid ground datum')
    local raw=wp..'/'..j.id..'_source.mts';assert(core.create_schematic(lo,hi,nil,raw))
    local target={x=index*160,y=150,z=0};local rotated_size={x=size.x,y=size.y,z=size.z}
    if j.rotation==90 or j.rotation==270 then rotated_size.x,rotated_size.z=size.z,size.x end
    local v=VoxelManip();v:read_from_map(target,vector.add(target,vector.subtract(rotated_size,1)))
    assert(core.place_schematic(target,raw,tostring(j.rotation),nil,true))
    local wall_count=recompute_walls(target,rotated_size)
    assert_walls_match(target,rotated_size,j.id..' rotated export')
    local output=wp..'/export/'..j.id..'.mts';assert(core.create_schematic(target,vector.add(target,vector.subtract(rotated_size,1)),nil,output))
    local exported_wall_count=assert_exported_walls_match(output,rotated_size,j.id..' saved export')
    assert(exported_wall_count==wall_count,j.id..' saved wall count changed')
    local metadata={};local nodes={};local dependencies={};local count=0
    for z=lo.z,hi.z do for y=lo.y,hi.y do for x=lo.x,hi.x do
     local p={x=x,y=y,z=z};local source=core.get_node(p);local o=offset(p,lo,size,j.rotation);local n=core.get_node(vector.add(target,o))
     if not is_wall(source.name) then assert(n.name==source.name,'Rotation changed non-wall node name') end
     count=count+1
     if n.name~='air' then
      dependencies[n.name]=true
      nodes[#nodes+1]={offset=o,name=n.name,param2=n.param2}
      local m=plain(core.get_meta(p):to_table());local fields={}
      -- Retain structural state and visible decoration; constructors regenerate formspecs.
      for k,val in pairs(m.fields or {}) do if k=='is_open' or k=='is_mirrored' or k=='utext' or k=='player_leaves' or k=='wet' or (k=='state' and source.name:find('^mcl_fences:')) then fields[k]=val end end
      local inventory=m.inventory or {}
      if next(fields) or next(inventory) then metadata[#metadata+1]={offset=o,name=n.name,fields=fields,inventory=inventory} end
     end
    end end end
    -- Verify exported file by rotating it back into source orientation.
    local inverse={x=index*160,y=150,z=120};local v2=VoxelManip();v2:read_from_map(inverse,vector.add(inverse,vector.subtract(size,1)))
    assert(core.place_schematic(inverse,output,tostring((360-j.rotation)%360),nil,true))
    recompute_walls(inverse,size)
    assert_walls_match(inverse,size,j.id..' inverse export')
    for z=0,size.z-1 do for y=0,size.y-1 do for x=0,size.x-1 do
     local p=vector.add(lo,{x=x,y=y,z=z});local q=vector.add(inverse,{x=x,y=y,z=z});local a=core.get_node(p);local b=core.get_node(q)
     local expected=a.name
     if is_wall(a.name) then
      expected=wall_name(a.name,function(dx,dy,dz)
       local nx,ny,nz=x+dx,y+dy,z+dz
       if nx<0 or nx>=size.x or ny<0 or ny>=size.y or nz<0 or nz>=size.z then return nil end
       local n=core.get_node(vector.add(lo,{x=nx,y=ny,z=nz})).name
       return n~='air' and n or nil
      end)
     end
     assert(expected==b.name and a.param2==b.param2,j.id..' inverse rotation mismatch')
    end end end
    local names={} for name in pairs(dependencies) do names[#names+1]=name end table.sort(names)
    local r={id=j.id,label=j.label,source_min=lo,source_max=hi,source_size=size,size=rotated_size,rotation=j.rotation,entrance=entrance,entrance_kind=kind,ground_offset=ground_offset,role=j.role,excluded_resident_beds=j.excluded_resident_beds,metadata=metadata,nodes=nodes,required_nodes=names,verified_nodes=count,wall_count=exported_wall_count,wall_mismatches=0}
    write_json(wp..'/export/'..j.id..'.json',r);results[#results+1]=r
   end
   write_json(wp..'/export/results.json',results)
   core.request_shutdown('Workshop exported',false,0)
  end)
 end)
end) end)
