local eq = ...
local open = dofile("src/open_space.lua")
local planner = dofile("src/planner.lua")
local catalog = dofile("src/catalog.lua")
local preflight = dofile("src/preflight.lua")
local function R(x1,z1,x2,z2) return {x1=x1,z1=z1,x2=x2,z2=z2} end
local function fixture()
	return {town_type="medieval", bounds=R(0,-1,28,8), sites={},
		boundary={rects={R(0,-1,8,8),R(20,-1,28,8),R(9,4,19,4)}},
		streets={{rect=R(0,-1,8,-1)},{rect=R(20,-1,28,-1)}},content={buildings={}}}
end
local function signature(objects,dx,dz)
	local out={}
	for _,o in ipairs(objects) do
		out[#out+1]=table.concat({o.id,o.rotation,o.rect.x1-(dx or 0),o.rect.z1-(dz or 0)},":")
	end
	return table.concat(out,";")
end
local p=fixture()
local objects=open.plan(p,1)
eq(#objects,1,"two roomy pockets joined by a narrow strip receive only one object")
eq(objects[1].rect.x2-objects[1].rect.x1+1,7,"object footprint is seven nodes wide")
eq(objects[1].clearing.x2-objects[1].clearing.x1+1,9,"clearing is nine nodes wide")
eq(objects[1].rotation,0,"garden path faces adjacent public street")
eq(signature(open.plan(p,1)),signature(objects),"placement is deterministic")
p.streets={}
eq(#open.plan(p,1),0,"inaccessible pockets remain empty")
p=fixture();p.content.buildings={{rect=R(4,4,4,4)},{rect=R(24,4,24,4)}}
eq(#open.plan(p,1),0,"even a one-node obstruction prevents a nine-node clearing")
p=fixture();p.boundary.rects={R(0,0,7,8)};p.streets={{rect=R(0,0,7,0)}}
eq(#open.plan(p,1),0,"narrow ground is skipped")
p=fixture();p.sites={square={kind="square",rect=R(0,0,8,8)},temple={kind="landmark",rect=R(20,0,28,8)}}
eq(#open.plan(p,1),0,"public squares and landmarks are excluded")
p=fixture();p.reservations={jail={rect=R(0,0,8,8)},services={{rect=R(20,0,28,8)}}}
eq(#open.plan(p,1),0,"jail and service reservations are excluded")

local function overlap(a,b)
	return a.x1<=b.x2 and b.x1<=a.x2 and a.z1<=b.z2 and b.z1<=a.z2
end
local seen={}
local profile=assert(planner.landmark_profile(catalog.snapshot()))
for _,seed in ipairs({1,7,42,101,256,1024,2718,31415,99999,123456,777777,1000003}) do
	local plan=assert(planner.plan({x=0,z=0},seed,{landmarks=profile}))
	local moved=assert(planner.plan({x=170,z=-250},seed,{landmarks=profile}))
	eq(signature(plan.objects),signature(moved.objects,170,-250),"seed "..seed.." objects translate with town")
	local comp=assert(preflight.compose(plan,catalog.entries,40))
	local object_count=0
	for _,s in ipairs(comp.structures) do
		if s.kind=="object" then
			object_count=object_count+1
			eq(s.entrance,nil,"objects have no fabricated building entrance")
			eq(s.min.y,40-(s.id=="garden" and 1 or 0),"object foundation aligned to ground")
		end
	end
	eq(object_count,#plan.objects,"all objects composed for bounds and construction")
	for i,o in ipairs(plan.objects) do
		seen[o.id]=true
		for _,s in ipairs(plan.streets) do eq(overlap(o.clearing,s.rect),false,"clearing avoids streets") end
		for _,s in pairs(plan.sites) do eq(overlap(o.clearing,s.rect),false,"clearing avoids sites") end
		for _,s in ipairs(plan.content.buildings) do eq(overlap(o.clearing,s.rect),false,"clearing avoids buildings") end
		for _,s in ipairs(plan.reservations.services) do eq(overlap(o.clearing,s.rect),false,"clearing avoids services") end
		if plan.reservations.jail then eq(overlap(o.clearing,plan.reservations.jail.rect),false,"clearing avoids jail") end
		for j,other in ipairs(plan.objects) do if i~=j then
			eq(overlap(o.clearing,other.clearing),false,"object clearings do not overlap")
			for _,p in ipairs(o.access) do eq(overlap(R(p.x,p.z,p.x,p.z),other.rect),false,"later objects preserve reserved access") end
		end end
		local last=o.access[#o.access]
		local adjacent=false
		for _,s in ipairs(plan.streets) do
			if overlap(R(last.x-1,last.z,last.x+1,last.z),s.rect)
				or overlap(R(last.x,last.z-1,last.x,last.z+1),s.rect) then adjacent=true end
		end
		for _,s in pairs(plan.sites) do
			if s.kind=="square" and (overlap(R(last.x-1,last.z,last.x+1,last.z),s.rect)
				or overlap(R(last.x,last.z-1,last.x,last.z+1),s.rect)) then adjacent=true end
		end
		eq(adjacent,true,"object access reaches public pavement")
	end
end
eq(seen.oak_tree,true,"sample towns include oaks")
eq(seen.garden,true,"sample towns include gardens")
local roman=assert(planner.plan({x=0,z=0},1,{town_type="roman"}))
eq(#roman.objects>0,true,"Roman towns also receive outdoor objects")
eq(preflight.compose(roman,catalog.entries,40)~=nil,true,"Roman objects share preflight composition")
