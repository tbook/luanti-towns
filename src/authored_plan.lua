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

local SIDES = {["-z"] = {x = 0, z = -1}, ["+z"] = {x = 0, z = 1},
	["-x"] = {x = -1, z = 0}, ["+x"] = {x = 1, z = 0}}

-- opts.min_block_depth (optional): the catalog row depth; every frontage run
-- must have a block at least that deep behind it. MIN_FRONTAGE_RUN is a
-- medieval constant and is deliberately not applied to authored runs.
function M.validate(plan, opts)
	local function bad(reason) return nil, "authored plan: " .. reason end
	if type(plan) ~= "table" then return bad("plan must be a table") end
	if type(plan.bounds) ~= "table" or not rect(plan.bounds) then return bad("invalid bounds rectangle") end
	local bounds = plan.bounds
	if type(plan.boundary) ~= "table" then return bad("boundary must be a table") end
	local boundary = plan.boundary.rects
	if type(boundary) ~= "table" or #boundary == 0 then return bad("boundary needs rectangles") end
	for i, r in ipairs(boundary) do
		if not rect(r) or not inside(r, bounds) then return bad("boundary rectangle " .. i .. " is invalid or outside bounds") end
	end
	local sites = plan.sites
	if type(sites) ~= "table" then return bad("sites must be a table") end
	local names, landmarks, squares = {}, {}, {}
	local site_names = {}
	for name in pairs(sites) do
		if type(name) ~= "string" or name == "" then
			return bad("site identities must be nonempty strings")
		end
		site_names[#site_names + 1] = name
	end
	table.sort(site_names)
	for _, name in ipairs(site_names) do
		local s = sites[name]
		if type(name) ~= "string" or name == "" or type(s) ~= "table" or s.name ~= name then
			return bad("site identity must match its key")
		end
		if names[name] then return bad("duplicate site identity " .. name) end
		names[name] = true
		if not rect(s.rect) or not inside(s.rect, bounds) then return bad("site " .. name .. " has invalid rectangle") end
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
			-- The approach is the first node outside the footprint along the
			-- entrance front; a recessed door's own outside node is inside it.
			local ax, az = placed.outside.x, placed.outside.z
			while ax >= s.rect.x1 and ax <= s.rect.x2 and az >= s.rect.z1 and az <= s.rect.z2 do
				ax, az = ax + placed.front.x, az + placed.front.z
			end
			if s.approach.pos.x ~= ax or s.approach.pos.z ~= az then
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
			if x < bounds.x1 or x > bounds.x2 or z < bounds.z1 or z > bounds.z2 or not contains(boundary, x, z) then
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
	-- A street stored past a hole in the array would escape the ipairs loop
	-- yet remain reachable by index from a frontage run.
	local street_count, street_seen = 0, 0
	for _ in pairs(plan.streets) do street_count = street_count + 1 end
	for i, s in ipairs(plan.streets) do
		street_seen = street_seen + 1
		if type(s) ~= "table" or (s.kind ~= "principal" and s.kind ~= "secondary") then return bad("street " .. i .. " is malformed") end
		local ok, why = pave(s.rect, s.material, "street " .. i); if not ok then return bad(why) end
	end
	if street_seen ~= street_count then return bad("street entries must form a gap-free sequence") end
	local function key(x, z) return x .. "," .. z end
	local min_depth = opts and opts.min_block_depth
	-- A block stored past a hole in the array would escape the ipairs loop.
	local block_count, block_seen = 0, 0
	for _ in pairs(plan.blocks) do block_count = block_count + 1 end
	for i, b in ipairs(plan.blocks) do
		block_seen = block_seen + 1
		if type(b) ~= "table" or not rect(b.rect) or type(b.frontage) ~= "table" or not inside(b.rect, bounds) then return bad("block " .. i .. " is malformed") end
		if b.id ~= nil and b.id ~= i then return bad("block " .. i .. " has wrong id") end
		for z = b.rect.z1, b.rect.z2 do for x = b.rect.x1, b.rect.x2 do
			if not contains(boundary, x, z) then return bad("block " .. i .. " leaves boundary") end
			if pavement[key(x, z)] then return bad("block " .. i .. " overlaps pavement") end
		end end
		for _, s in ipairs(landmarks) do
			if overlap(b.rect, s.rect) then return bad("block " .. i .. " overlaps landmark " .. s.name) end
		end
		for j = 1, i - 1 do
			if overlap(b.rect, plan.blocks[j].rect) then return bad("block " .. i .. " overlaps block " .. j) end
		end
		local listed = {}
		for _, f in ipairs(b.frontage) do
			if not integer(f) or type(plan.frontage[f]) ~= "table" or plan.frontage[f].block ~= i then
				return bad("block " .. i .. " references invalid frontage")
			end
			if listed[f] then return bad("block " .. i .. " lists frontage " .. f .. " twice") end
			listed[f] = true
		end
	end
	if block_seen ~= block_count then return bad("block entries must form a gap-free sequence") end
	-- Every entry must be reached by the sequence loop below; a stray entry
	-- stored past a hole in the array would otherwise escape validation.
	local frontage_count, checked = 0, 0
	for _ in pairs(plan.frontage) do frontage_count = frontage_count + 1 end
	local occupied = {}
	for i, f in ipairs(plan.frontage) do
		checked = checked + 1
		if type(f) ~= "table" or not rect(f.rect) or not inside(f.rect, bounds)
				or not integer(f.block) or not plan.blocks[f.block] then
			return bad("frontage " .. i .. " has invalid block reference")
		end
		if f.id ~= i then return bad("frontage " .. i .. " has wrong id") end
		local b = plan.blocks[f.block]
		local linked = false
		for _, fid in ipairs(b.frontage) do if fid == i then linked = true end end
		if not linked then return bad("frontage " .. i .. " is missing from its block") end
		local d = SIDES[f.side]
		if not d or type(f.facing) ~= "table" or f.facing.x ~= d.x or f.facing.z ~= d.z then
			return bad("frontage " .. i .. " side and facing disagree")
		end
		-- The run is the one-node-thick row of block edge nodes on its side.
		local br, fr = b.rect, f.rect
		local edge = inside(fr, br)
		if f.side == "-z" then edge = edge and fr.z1 == br.z1 and fr.z2 == br.z1
		elseif f.side == "+z" then edge = edge and fr.z1 == br.z2 and fr.z2 == br.z2
		elseif f.side == "-x" then edge = edge and fr.x1 == br.x1 and fr.x2 == br.x1
		else edge = edge and fr.x1 == br.x2 and fr.x2 == br.x2 end
		if not edge then return bad("frontage " .. i .. " is not on its block's edge") end
		if f.length ~= (fr.x2 - fr.x1 + 1) * (fr.z2 - fr.z1 + 1) then
			return bad("frontage " .. i .. " has wrong length")
		end
		local depth = (f.side == "-z" or f.side == "+z") and b.rect.z2 - b.rect.z1 + 1
			or b.rect.x2 - b.rect.x1 + 1
		if min_depth and depth < min_depth then
			return bad("frontage " .. i .. " block is shallower than the row depth")
		end
		local surface
		if f.square ~= nil then
			if f.street ~= nil then return bad("frontage " .. i .. " has invalid street or square reference") end
			surface = type(f.square) == "string" and sites[f.square] or nil
			if surface and surface.kind ~= "square" then surface = nil end
		elseif integer(f.street) then
			surface = plan.streets[f.street]
		end
		if not surface or not rect(surface.rect) then
			return bad("frontage " .. i .. " has invalid street or square reference")
		end
		for z = fr.z1, fr.z2 do for x = fr.x1, fr.x2 do
			local ok_key = f.block .. "," .. f.side .. "," .. key(x, z)
			if occupied[ok_key] then return bad("frontage " .. i .. " overlaps another run on its block edge") end
			occupied[ok_key] = true
			local nx, nz = x + d.x, z + d.z
			if nx < surface.rect.x1 or nx > surface.rect.x2 or nz < surface.rect.z1 or nz > surface.rect.z2 then
				return bad("frontage " .. i .. " does not face its street or square")
			end
		end end
		if f.material ~= surface.material then return bad("frontage " .. i .. " has wrong material") end
	end
	if checked ~= frontage_count then return bad("frontage entries must form a gap-free sequence") end
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
	for _, s in ipairs(squares) do
		local p = s.approach.pos
		if not pavement[key(p.x, p.z)] or not seen[key(p.x, p.z)] then
			return bad("public pavement is disconnected from square " .. s.name .. " approach")
		end
	end
	for _, s in ipairs(landmarks) do
		local p = s.approach.pos
		if not pavement[key(p.x,p.z)] or not seen[key(p.x,p.z)] then return bad("public pavement is disconnected from landmark " .. s.name .. " approach") end
	end
	for k in pairs(pavement) do
		if not seen[k] then return bad("public pavement contains a disconnected section") end
	end
	return true
end

-- Describes catalog `id` placed at `rect` (its footprint and rotation come
-- from geometry.place at rect.x1, rect.z1) as an authored landmark site. The
-- approach is the first node outside the box along the entrance front, so a
-- recessed door still has a paved node on the box edge.
function M.landmark_site(name, id, rotation, rect)
	local entry = catalog.entries[id]
	if not entry then error("landmark " .. tostring(name) .. " has unknown catalog id " .. tostring(id), 2) end
	local placed = geometry.place(entry, {x = rect.x1, y = 0, z = rect.z1}, rotation)
	local ax, az = placed.outside.x, placed.outside.z
	while ax >= rect.x1 and ax <= rect.x2 and az >= rect.z1 and az <= rect.z2 do
		ax, az = ax + placed.front.x, az + placed.front.z
	end
	return {
		name = name, kind = "landmark", id = id, rotation = rotation,
		rect = rect, size = {x = placed.size.x, z = placed.size.z},
		entrance = {x = placed.entrance.x, z = placed.entrance.z},
		facing = {x = placed.front.x, z = placed.front.z},
		approach = {pos = {x = ax, z = az}},
	}
end

-- Edge sides in the order their frontage runs are numbered.
local SIDE_ORDER = {
	{side = "-z", x = 0, z = -1}, {side = "+z", x = 0, z = 1},
	{side = "-x", x = -1, z = 0}, {side = "+x", x = 1, z = 0},
}

-- Fills plan.frontage and each block's frontage list from the block rects.
-- Along each block side, every maximal stretch of edge nodes whose outer
-- neighbour is one square or street becomes a run; stretches facing a
-- landmark or open ground get none. Squares (by name, sorted) take precedence
-- over streets. Returns true, or nil and a reason if a block gets no run.
-- Expects plan.sites, plan.streets, plan.blocks (each with name, id, rect and
-- an empty frontage list) and an empty plan.frontage.
function M.derive_frontage(plan)
	local squares = {}
	for name, site in pairs(plan.sites) do
		if site.kind == "square" then squares[#squares + 1] = name end
	end
	table.sort(squares)
	local function surface(x, z)
		for _, name in ipairs(squares) do
			local r = plan.sites[name].rect
			if x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 then return name, plan.sites[name].material end
		end
		for i, st in ipairs(plan.streets) do
			local r = st.rect
			if x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 then return i, st.material end
		end
	end
	for _, block in ipairs(plan.blocks) do
		local r = block.rect
		for _, s in ipairs(SIDE_ORDER) do
			-- Edge nodes of this side in ascending coordinate order.
			local cells = {}
			if s.x == 0 then
				local z = s.z < 0 and r.z1 or r.z2
				for x = r.x1, r.x2 do cells[#cells + 1] = {x, z} end
			else
				local x = s.x < 0 and r.x1 or r.x2
				for z = r.z1, r.z2 do cells[#cells + 1] = {x, z} end
			end
			local i = 1
			while i <= #cells do
				local owner, material = surface(cells[i][1] + s.x, cells[i][2] + s.z)
				local j = i
				if owner ~= nil then
					while j < #cells do
						local o = surface(cells[j + 1][1] + s.x, cells[j + 1][2] + s.z)
						if o ~= owner then break end
						j = j + 1
					end
					local a, b = cells[i], cells[j]
					local run = {
						id = #plan.frontage + 1, block = block.id, side = s.side,
						facing = {x = s.x, z = s.z},
						rect = {x1 = a[1], z1 = a[2], x2 = b[1], z2 = b[2]},
						length = j - i + 1, material = material,
					}
					if type(owner) == "string" then run.square = owner
					else run.street = owner; run.street_name = plan.streets[owner].name end
					plan.frontage[run.id] = run
					block.frontage[#block.frontage + 1] = run.id
				end
				i = j + 1
			end
		end
		if #block.frontage == 0 then return nil, "block " .. tostring(block.name) .. " has no frontage" end
	end
	return true
end

return M
