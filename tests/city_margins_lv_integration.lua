-- Optional cross-repository integration; set TOWNS_LIVING_VILLAGES to the LV checkout.
-- This exercises LV's real writer/scan through a thin API wrapper, not its full init.lua.
local eq = ...
local path = os.getenv("TOWNS_LIVING_VILLAGES")
if not path then print("SKIP city margins integration: TOWNS_LIVING_VILLAGES not set"); return end
local saved_minetest, saved_area = minetest, VoxelArea
minetest = {get_modpath = function() return path end}
VoxelArea = {new = function(_, box)
	local minp, maxp = box.MinEdge, box.MaxEdge
	local dx, dy = maxp.x - minp.x + 1, maxp.y - minp.y + 1
	return {index = function(_, x, y, z) return (z-minp.z)*dx*dy + (y-minp.y)*dx + x-minp.x+1 end}
end}
local boundary = dofile(path .. "/village_boundary.lua")
local fragments = dofile(path .. "/village_fragments.lua")
local names = {[0]="air", "mcl_core:dirt_with_grass", "mcl_core:dirt", "test:building", "test:foreign", "mcl_core:tree"}
local ids = {}; for id, name in pairs(names) do ids[name] = id end
local world, writes = {}, {}
local function key(x,y,z) return x .. "," .. y .. "," .. z end
local function get(p)
	return world[key(p.x,p.y,p.z)] or (p.y <= 8 and "mcl_core:dirt_with_grass" or "air")
end
local engine = {
	CONTENT_AIR = 0, CONTENT_IGNORE = 99,
	registered_nodes = {air={walkable=false}, ["mcl_core:dirt_with_grass"]={walkable=true, is_ground_content=true},
		["mcl_core:dirt"]={walkable=true, is_ground_content=true}, ["test:building"]={walkable=true,is_ground_content=false},
		["test:foreign"]={walkable=true,is_ground_content=false}, ["mcl_core:tree"]={walkable=true,groups={tree=1},is_ground_content=false}},
	get_name_from_content_id = function(id) return names[id] end,
	get_node = function(p) return {name=get(p), param2=0} end,
	swap_node = function(p, node) world[key(p.x,p.y,p.z)] = node.name; writes[#writes+1] = {x=p.x,y=p.y,z=p.z} end,
	log = function() end,
}
engine.get_voxel_manip = function()
	local minp, maxp, va
	return {read_from_map = function(_, a, b) minp,maxp=a,b; va=VoxelArea:new({MinEdge=a,MaxEdge=b}); return a,b end,
		get_data = function()
			local data = {}
			for z=minp.z,maxp.z do for y=minp.y,maxp.y do for x=minp.x,maxp.x do
				data[va:index(x,y,z)] = ids[get({x=x,y=y,z=z})]
			end end end
			return data
		end}
end
world[key(9,10,2)] = "test:building"
world[key(14,10,3)] = "test:foreign"
world[key(12,10,-3)] = "mcl_core:tree"
local terrain = {boundary_structure_protection=1, boundary_volume=boundary.volume,
	smooth_boundary=function(rects, ground, options) return boundary.smooth(rects, ground, options) end}
local api_env = {engine=engine, load_node=function() return {name="air"} end}
local summary
local result = {ground_y=0, plan={boundary={rects={{x1=0,z1=0,x2=9,z2=4}}}}}
local build = {town={structures={{min={x=9,y=9,z=2},max={x=9,y=12,z=2}}}}}
local env = {api_env=api_env, is_protected=function(p) return p.x==11 and p.y==30 and p.z==2 end,
	emerge=function(_,_,cb) cb(true) end, after=function() end}
dofile("src/city_margins.lua")(terrain).attempt(result, function(s) summary=s end, env, build)
eq(summary.status, "smoothed", "actual LV writer succeeds through Towns adapter")
eq(get({x=10,y=8,z=2}) ~= "mcl_core:dirt_with_grass", true, "ground beside known edge building is graded")
eq(get({x=11,y=8,z=2}), "mcl_core:dirt_with_grass", "protected column stays unchanged")
eq(get({x=13,y=8,z=3}), "mcl_core:dirt_with_grass", "foreign structure buffer stays unchanged")
eq(get({x=12,y=10,z=-3}), "mcl_core:tree", "ambiguous tree or log remains")
eq(get({x=11,y=8,z=-3}), "mcl_core:dirt_with_grass", "ambiguous tree or log buffer stays unchanged")
eq(get({x=10,y=8,z=-3}) ~= "mcl_core:dirt_with_grass", true, "nearby column beyond both buffers is graded")
eq(get({x=9,y=10,z=2}), "test:building", "known building remains")
eq(summary.stats.tree_removed, 0, "safe contract does not clear trees")
local protected_writes = 0
for _, p in ipairs(writes) do if p.x == 11 and p.z == 2 then protected_writes = protected_writes + 1 end end
eq(protected_writes, 0, "no mutation enters the protected column")
local old = {boundary_volume=function() error("old API called") end, smooth_boundary=function() error("old API called") end}
local old_summary
dofile("src/city_margins.lua")(old).attempt(result, function(s) old_summary=s end, env, build)
eq(old_summary.status, "skipped", "old API fails closed")
minetest, VoxelArea = saved_minetest, saved_area
