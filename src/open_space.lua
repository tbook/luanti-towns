-- Occasional trees and gardens after buildings are populated (#204).
-- One 7x7 object inside a fully unused 9x9 square, at most one per pocket.
-- The untouched one-node ring preserves passage around every object.
local M = {}
local DIRS = {{0,-1,0}, {-1,0,90}, {0,1,180}, {1,0,270}}

function M.plan(plan, seed, reserved)
	local b, free, public = plan.bounds, {}, {}
	local function key(x, z) return (z - b.z1) * (b.x2 - b.x1 + 1) + x - b.x1 + 1 end
	local function inside(x, z) return x >= b.x1 and x <= b.x2 and z >= b.z1 and z <= b.z2 end
	local function paint(r, value, pavement)
		for z = r.z1, r.z2 do for x = r.x1, r.x2 do
			local k = key(x,z)
			free[k], public[k] = value, pavement or nil
		end end
	end
	for _, r in ipairs(plan.boundary.rects) do paint(r, true) end
	for _, s in ipairs(plan.streets) do paint(s.rect, false, true) end
	for _, s in pairs(plan.sites) do paint(s.rect, false, s.kind == "square") end
	for _, r in ipairs(reserved or {}) do
		local clipped = {x1 = math.max(r.x1, b.x1), x2 = math.min(r.x2, b.x2),
			z1 = math.max(r.z1, b.z1), z2 = math.min(r.z2, b.z2)}
		for z = clipped.z1, clipped.z2 do for x = clipped.x1, clipped.x2 do
			free[key(x, z)] = false
		end end
	end
	local res = plan.reservations or {}
	if res.jail then paint(res.jail.rect, false) end
	for _, s in ipairs(res.services or {}) do paint(s.rect, false) end
	for _, s in ipairs((plan.content or {}).buildings or {}) do paint(s.rect, false) end
	local function clear(r, occupied)
		for z=r.z1,r.z2 do for x=r.x1,r.x2 do
			local k=key(x,z)
			if not free[k] or (occupied and occupied[k]) then return false end
		end end
		return true
	end
	-- All unused ground reachable from public pavement, with shortest paths.
	local function routes()
		local dist, parent, q = {}, {}, {}
		for z=b.z1,b.z2 do for x=b.x1,b.x2 do
			local k=key(x,z)
			if free[k] then
				for _, d in ipairs(DIRS) do
					local nx,nz=x+d[1],z+d[2]
					if inside(nx,nz) and public[key(nx,nz)] then
						dist[k]=1; q[#q+1]={x=x,z=z}; break
					end
				end
			end
		end end
		local head=1
		while head<=#q do
			local p=q[head]; head=head+1
			local k=key(p.x,p.z)
			for _, d in ipairs(DIRS) do
				local x,z=p.x+d[1],p.z+d[2]
				local nk=key(x,z)
				if inside(x,z) and free[nk] and not dist[nk] then
					dist[nk],parent[nk]=dist[k]+1,p
					q[#q+1]={x=x,z=z}
				end
			end
		end
		return dist,parent
	end
	local dist=routes()
	local candidates, eligible = {}, {}
	-- Integral counts and a difference grid keep large empty spaces linear
	-- in town area rather than painting every overlapping 9x9 square.
	local prefix, coverage = {}, {}
	for z=b.z1-1,b.z2 do
		local row, previous = {[b.x1-1]=0}, prefix[z-1]
		for x=b.x1,b.x2 do
			row[x] = z < b.z1 and 0 or (free[key(x,z)] and 1 or 0)
			if z >= b.z1 then row[x] = row[x]+row[x-1]+previous[x]-previous[x-1] end
		end
		prefix[z]=row
	end
	for z=b.z1,b.z2+1 do coverage[z]={} end
	local function delta(x,z,n) coverage[z][x]=(coverage[z][x] or 0)+n end
	for z=b.z1,b.z2-8 do for x=b.x1,b.x2-8 do
		local r={x1=x,z1=z,x2=x+8,z2=z+8}
		local count=prefix[z+8][x+8]-prefix[z-1][x+8]-prefix[z+8][x-1]+prefix[z-1][x-1]
		if dist[key(x,z)] and count==81 then
			candidates[#candidates+1]=r
			delta(x,z,1); delta(x+9,z,-1); delta(x,z+9,-1); delta(x+9,z+9,1)
		end
	end end
	for z=b.z1,b.z2 do
		local row, previous=coverage[z],coverage[z-1] or {}
		for x=b.x1,b.x2 do
			row[x]=(row[x] or 0)+(row[x-1] or 0)+(previous[x] or 0)-(previous[x-1] or 0)
			if row[x]>0 then eligible[key(x,z)]=true end
		end
	end
	-- Count connected areas covered by eligible squares, ignoring thin links.
	local groups, group_at = {}, {}
	for z=b.z1,b.z2 do for x=b.x1,b.x2 do
		local k=key(x,z)
		if eligible[k] and not group_at[k] then
			groups[#groups+1]={}
			local q,head={{x=x,z=z}},1
			group_at[k]=#groups
			while head<=#q do
				local p=q[head];head=head+1
				for _,d in ipairs(DIRS) do
					local nx,nz=p.x+d[1],p.z+d[2]
					local nk=key(nx,nz)
					if inside(nx,nz) and eligible[nk] and not group_at[nk] then
						group_at[nk]=#groups; q[#q+1]={x=nx,z=nz}
					end
				end
			end
		end
	end end
	for _,r in ipairs(candidates) do
		local group=groups[group_at[key(r.x1,r.z1)]]
		group[#group+1]=r
	end
	-- A separate random stream keeps the building arrangement unchanged.
	local state=(seed+1073741824)%2147483646+1
	local function random(n) state=(state*48271)%2147483647; return state%n+1 end
	for i=#groups,2,-1 do local j=random(i); groups[i],groups[j]=groups[j],groups[i] end
	local objects, reserved = {}, {}
	local target = #groups == 0 and 0 or math.max(1,math.floor(#groups/2))
	for _, group in ipairs(groups) do
		if #objects >= target then break end
		local first=random(#group)
		local id=random(2)==1 and "oak_tree" or "garden"
		for attempt=1,#group do
			local r=group[(first+attempt-2)%#group+1]
			if clear(r,reserved) then
				local rect={x1=r.x1+1,z1=r.z1+1,x2=r.x2-1,z2=r.z2-1}
				-- Treat even the whole garden/tree footprint as impassable for
				-- route reservation: access must work around it, not through it.
				paint(rect,false)
				local distances,parents=routes()
				local access,rotation,best
				local cx,cz=r.x1+4,r.z1+4
				for _,d in ipairs(DIRS) do
					local p={x=cx+d[1]*4,z=cz+d[2]*4}
					local n=distances[key(p.x,p.z)]
					if n and (not best or n<best) then access,rotation,best=p,d[3],n end
				end
				if access then
					local path,p={},access
					while p do
						path[#path+1]={x=p.x,z=p.z}; reserved[key(p.x,p.z)]=true
						p=parents[key(p.x,p.z)]
					end
					for z=r.z1,r.z2 do for x=r.x1,r.x2 do reserved[key(x,z)]=true end end
					objects[#objects+1]={id=id,rotation=rotation,rect=rect,clearing=r,access=path}
					break
				else paint(rect,true) end
			end
		end
	end
	return objects
end

return M
