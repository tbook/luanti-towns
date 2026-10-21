-- Validation for hand-authored town layouts. Kept separate from the
-- medieval generator's composition rules so other town types can share the
-- planner API without acquiring medieval civic-site requirements.
local function sibling(name)
	local c = rawget(_G, "core")
	if c and c.get_modpath and c.get_current_modname then
		return dofile(c.get_modpath(c.get_current_modname()) .. "/src/" .. name)
	end
	local source = debug.getinfo(1, "S").source:sub(2)
	local root = source:match("^(.*)/src/authored_plan.lua$") or "."
	return dofile(root .. "/src/" .. name)
end
local catalog = sibling("catalog.lua")
local geometry = sibling("geometry.lua")

local M = {}
local function integer(n) return type(n) == "number" and n == math.floor(n) end
local function rect(r)
	return type(r) == "table" and integer(r.x1) and integer(r.z1)
		and integer(r.x2) and integer(r.z2) and r.x1 <= r.x2 and r.z1 <= r.z2
end
local function inside(a, b)
	return a.x1 >= b.x1 and a.z1 >= b.z1 and a.x2 <= b.x2 and a.z2 <= b.z2
end
local function overlap(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end
local function contains(rects, x, z)
	for _, r in ipairs(rects) do
		if x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 then return true end
	end
	return false
end

function M.validate(plan)
	local function bad(reason) return nil, "authored plan: " .. reason end
	if type(plan) ~= "table" then return bad("plan must be a table") end
	if type(plan.envelope) ~= "table" or not rect(plan.envelope) then return bad("invalid envelope rectangle") end
	local env = plan.envelope
	local boundary = plan.boundary and plan.boundary.rects
	if type(boundary) ~= "table" or #boundary == 0 then return bad("boundary needs rectangles") end
	for i, r in ipairs(boundary) do
		if not rect(r) or not inside(r, env) then return bad("boundary rectangle " .. i .. " is invalid or outside envelope") end
	end
	local sites = plan.sites
	if type(sites) ~= "table" then return bad("sites must be a table") end
	local names, landmarks, squares = {}, {}, {}
	local site_names = {}
	for name in pairs(sites) do site_names[#site_names + 1] = name end
	table.sort(site_names)
	for _, name in ipairs(site_names) do
		local s = sites[name]
		if type(name) ~= "string" or name == "" or type(s) ~= "table" or s.name ~= name then
			return bad("site identity must match its key")
		end
		if names[name] then return bad("duplicate site identity " .. name) end
		names[name] = true
		if not rect(s.rect) or not inside(s.rect, env) then return bad("site " .. name .. " has invalid rectangle") end
		for z = s.rect.z1, s.rect.z2 do for x = s.rect.x1, s.rect.x2 do
			if not contains(boundary, x, z) then return bad("site " .. name .. " leaves boundary") end
		end end
		if s.kind == "square" then
			if type(s.material) ~= "string" or s.material == "" then return bad("square " .. name .. " needs a material") end
			squares[#squares + 1] = s
		elseif s.kind == "landmark" then
			if type(s.id) ~= "string" or not integer(s.rotation) then return bad("landmark " .. name .. " needs catalog id and rotation") end
			local entry = catalog.entries[s.id]
			if not entry then return bad("landmark " .. name .. " has unknown catalog id " .. s.id) end
			if s.rotation ~= 0 and s.rotation ~= 90 and s.rotation ~= 180 and s.rotation ~= 270 then return bad("landmark " .. name .. " has invalid rotation") end
			local placed = geometry.place(entry, {x = s.rect.x1, y = 0, z = s.rect.z1}, s.rotation)
			if s.rect.x2 - s.rect.x1 + 1 ~= placed.size.x or s.rect.z2 - s.rect.z1 + 1 ~= placed.size.z then
				return bad("landmark " .. name .. " footprint does not match catalog size")
			end
			local ent = s.entrance
			if type(ent) ~= "table" or ent.x ~= placed.entrance.x or ent.z ~= placed.entrance.z then
				return bad("landmark " .. name .. " entrance does not match catalog")
			end
			if type(s.approach) ~= "table" or type(s.approach.pos) ~= "table"
					or not integer(s.approach.pos.x) or not integer(s.approach.pos.z) then
				return bad("landmark " .. name .. " needs an approach position")
			end
			if s.approach.pos.x ~= placed.outside.x or s.approach.pos.z ~= placed.outside.z then
				return bad("landmark " .. name .. " approach does not match its entrance")
			end
			landmarks[#landmarks + 1] = s
		else return bad("site " .. name .. " has unknown kind") end
		if s.kind == "square" then
			if type(s.approach) ~= "table" or type(s.approach.pos) ~= "table"
					or not integer(s.approach.pos.x) or not integer(s.approach.pos.z) then
				return bad("square " .. name .. " needs an approach position")
			end
		end
	end
	for i = 1, #landmarks do for j = i + 1, #landmarks do
		if overlap(landmarks[i].rect, landmarks[j].rect) then return bad("landmarks overlap") end
	end end
	if type(plan.streets) ~= "table" or type(plan.blocks) ~= "table" or type(plan.frontage) ~= "table" then
		return bad("streets, blocks, and frontage must be tables")
	end
	local pavement = {}
	local function pave(r, material, label)
		if not rect(r) then return nil, label .. " has invalid rectangle" end
		if type(material) ~= "string" or material == "" then return nil, label .. " needs a material" end
		for z = r.z1, r.z2 do for x = r.x1, r.x2 do
			if x < env.x1 or x > env.x2 or z < env.z1 or z > env.z2 or not contains(boundary, x, z) then
				return nil, label .. " leaves boundary"
			end
			for _, s in ipairs(landmarks) do if x >= s.rect.x1 and x <= s.rect.x2 and z >= s.rect.z1 and z <= s.rect.z2 then
				return nil, label .. " overlaps landmark " .. s.name
			end end
			local k = x .. "," .. z
			pavement[k] = {x = x, z = z, material = material}
		end end
		return true
	end
	for _, s in ipairs(squares) do local ok, why = pave(s.rect, s.material, "square " .. s.name); if not ok then return bad(why) end end
	for i, s in ipairs(plan.streets) do
		if type(s) ~= "table" or (s.kind ~= "principal" and s.kind ~= "secondary") then return bad("street " .. i .. " is malformed") end
		local ok, why = pave(s.rect, s.material, "street " .. i); if not ok then return bad(why) end
	end
	local function key(x, z) return x .. "," .. z end
	for i, b in ipairs(plan.blocks) do
		if type(b) ~= "table" or not rect(b.rect) or type(b.frontage) ~= "table" or not inside(b.rect, env) then return bad("block " .. i .. " is malformed") end
		for _, f in ipairs(b.frontage) do
			if not integer(f) or not plan.frontage[f] or plan.frontage[f].block ~= i then
				return bad("block " .. i .. " references invalid frontage")
			end
		end
	end
	for i, f in ipairs(plan.frontage) do
		if type(f) ~= "table" or not rect(f.rect) or not inside(f.rect, env)
				or not integer(f.block) or not plan.blocks[f.block] then
			return bad("frontage " .. i .. " has invalid block reference")
		end
		local linked = false
		for _, fid in ipairs(plan.blocks[f.block].frontage) do if fid == i then linked = true end end
		if not linked then return bad("frontage " .. i .. " is missing from its block") end
		local surface
		if f.square ~= nil then
			surface = type(f.square) == "string" and sites[f.square] or nil
		elseif integer(f.street) then
			surface = plan.streets[f.street]
		end
		if not surface or not rect(surface.rect) or not inside(f.rect, surface.rect) then
			return bad("frontage " .. i .. " has invalid street or square reference")
		end
		if f.material ~= surface.material then return bad("frontage " .. i .. " has wrong material") end
	end
	local start
	for _, s in ipairs(squares) do start = s.approach.pos; break end
	if not start then return bad("public pavement needs a square approach") end
	local queue, seen = {{x = start.x, z = start.z}}, {}
	if not pavement[key(start.x, start.z)] then return bad("square approach is not paved") end
	seen[key(start.x, start.z)] = true
	local dirs = {{1,0},{-1,0},{0,1},{0,-1}}
	local qi = 1
	while qi <= #queue do
		local p = queue[qi]; qi = qi + 1
		for _, d in ipairs(dirs) do local x, z = p.x + d[1], p.z + d[2]; local k = key(x,z)
			if pavement[k] and not seen[k] then seen[k] = true; queue[#queue + 1] = {x=x,z=z} end
		end
	end
	for _, s in ipairs(landmarks) do
		local p = s.approach.pos
		if not pavement[key(p.x,p.z)] or not seen[key(p.x,p.z)] then return bad("public pavement is disconnected from landmark " .. s.name .. " approach") end
	end
	return true
end

return M
