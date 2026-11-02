-- Towns: pure Roman civic planner (issue #148).
-- Turns the authored layout in src/roman_civic_plan.lua into an authored plan
-- (the schema src/authored_plan.lua validates). No core.* dependency.
--
--   local roman = dofile("src/roman_planner.lua")
--   local plan, reason, detail = roman.plan({x = cx, z = cz}, seed)
--
-- Every seed gives the same civic geometry; the seed is only recorded. The
-- centre merely translates the layout. Plans are returned only after authored
-- validation.
--
-- Blocks (issue #149) are the layout's explicit rectangles, as deep as the
-- shared catalog row depth (planner.row_depth, passed in as `row_depth`).
-- Frontage is derived from them: along each block side, every maximal stretch
-- of edge nodes whose outer neighbour is the forum or one street becomes a run
-- (the shared run schema in planner.lua). Stretches facing a monument, an arch
-- or open ground get none, so runs never touch monuments or their approaches.
-- A block may instead be flush against a ring band (issue #164): ring and side
-- "inner" or "outer" replace arm and side, and from..to are compass coordinates
-- along the band; frontage is derived the same way.
-- Ids follow layout order, then sides -z, +z, -x, +x, then coordinate.
local function sibling(name)
	local c = rawget(_G, "core")
	if c and c.get_modpath and c.get_current_modname then
		return dofile(c.get_modpath(c.get_current_modname()) .. "/src/" .. name)
	end
	local source = debug.getinfo(1, "S").source:sub(2)
	local root = source:match("^(.*)/src/roman_planner.lua$") or "."
	return dofile(root .. "/src/" .. name)
end
local catalog = sibling("catalog.lua")
local geometry = sibling("geometry.lua")
local authored_plan = sibling("authored_plan.lua")

local M = {}
M.layout = sibling("roman_civic_plan.lua")

-- Outward unit vector of each arm; its axis is the street's long axis.
local ARMS = {
	north = {x = 0, z = 1}, south = {x = 0, z = -1},
	east = {x = 1, z = 0}, west = {x = -1, z = 0},
}
-- Direction a building's entrance must face to look at the street it is on.
local TOWARD = {["+x"] = {-1, 0}, ["-x"] = {1, 0}, ["+z"] = {0, -1}, ["-z"] = {0, 1}}

local function layout_error(msg) error("roman layout: " .. msg, 0) end

-- Offset-space rectangle (relative to the forum centre) for an extent
-- [t1, t2] outward along `arm` and [l1, l2] across it in compass axes.
local function arm_rect(layout, arm, t1, t2, l1, l2)
	local h = math.floor(layout.forum_size / 2)
	local d = ARMS[arm]
	local a1, a2
	if d.x + d.z > 0 then a1, a2 = h + t1, h + t2 else a1, a2 = -h - 1 - t2, -h - 1 - t1 end
	if d.x ~= 0 then return {x1 = a1, z1 = l1, x2 = a2, z2 = l2} end
	return {x1 = l1, z1 = a1, x2 = l2, z2 = a2}
end

local function translate(r, dx, dz)
	return {x1 = r.x1 + dx, z1 = r.z1 + dz, x2 = r.x2 + dx, z2 = r.z2 + dz}
end

local function entry_of(id)
	local entry = catalog.entries[id]
	if not entry then layout_error("unknown catalog id " .. tostring(id)) end
	return entry
end

-- Place `id` at `rect` as an authored landmark site (authored_plan.landmark_site)
-- whose entrance must face `toward`; `extra` fields are merged in.
local function landmark(name, id, rotation, rect, toward, extra)
	local site = authored_plan.landmark_site(name, id, rotation, rect)
	if site.facing.x ~= toward[1] or site.facing.z ~= toward[2] then
		layout_error(name .. " rotation " .. rotation .. " does not face its street")
	end
	for k, v in pairs(extra) do site[k] = v end
	return site
end

local function footprint(id, rotation)
	local size = geometry.place(entry_of(id), {x = 0, y = 0, z = 0}, rotation).size
	return size.x, size.z
end

-- Ring landmark (issue #201): stands flush against a ring band on its "inner"
-- or "outer" side, as a ring block does. `at` is the compass coordinate of the
-- low edge along the band. Its door must face the band (landmark checks it).
local function ring_landmark(layout, streets, spec, dx, dz)
	if spec.arm ~= nil then layout_error(spec.name .. " sets both ring and arm") end
	if spec.faces ~= nil then layout_error(spec.name .. " sets faces on a ring landmark") end
	local band, street
	for _, b in ipairs(layout.bands or {}) do if b.name == spec.ring then band = b end end
	for _, st in ipairs(streets) do if st.ring == spec.ring then street = st end end
	if not band or not street or (spec.side ~= "inner" and spec.side ~= "outer") then
		layout_error(spec.name .. " has an invalid ring or side")
	end
	if type(spec.at) ~= "number" or spec.at ~= math.floor(spec.at) then
		layout_error(spec.name .. " has a missing or malformed at")
	end
	local d = ARMS[band.arm]
	local out = spec.side == "outer" and 1 or -1
	local sign = (d.x + d.z) * out
	local sx, sz = footprint(spec.id, spec.rotation)
	local thin = d.x ~= 0 and "x" or "z" -- the band's thin axis
	local across, along = sx, sz
	if thin == "z" then across, along = sz, sx end
	local a1, a2 = street.rect[thin .. "1"], street.rect[thin .. "2"]
	local lo, hi
	if sign > 0 then lo, hi = a2 + 1, a2 + across else lo, hi = a1 - across, a1 - 1 end
	local r, side
	if thin == "x" then
		r = {x1 = lo, z1 = spec.at + dz, x2 = hi, z2 = spec.at + dz + along - 1}
		side = sign > 0 and "+x" or "-x"
	else
		r = {x1 = spec.at + dx, z1 = lo, x2 = spec.at + dx + along - 1, z2 = hi}
		side = sign > 0 and "+z" or "-z"
	end
	return landmark(spec.name, spec.id, spec.rotation, r, TOWARD[side], {ring = spec.ring})
end

-- Ordinary content profile for planner.row_depth: the house, shop and
-- workshop catalog entries (the roles content_planner packs).
function M.content_profile()
	local content = {}
	for id, e in pairs(catalog.snapshot()) do
		if e.role == "house" or e.role == "shop" or e.role == "workshop" then
			content[id] = {id = id, size = e.size, role = e.role}
		end
	end
	return {content = content}
end

-- Adds plan.blocks from the layout's block rectangles, then derives their
-- frontage (authored_plan.derive_frontage).
local function add_blocks(layout, plan, row_depth, dx, dz)
	local half = math.floor(layout.street_width / 2)
	if type(row_depth) ~= "number" or row_depth < 1 or row_depth ~= math.floor(row_depth) then
		layout_error("blocks need a catalog row depth")
	end
	local seen = {}
	for _, spec in ipairs(layout.blocks or {}) do
		if seen[spec.name] then layout_error("duplicate block name " .. tostring(spec.name)) end
		seen[spec.name] = true
		local r, arm, side
		if spec.ring ~= nil then
			local band, street
			for _, b in ipairs(layout.bands or {}) do if b.name == spec.ring then band = b end end
			for _, st in ipairs(plan.streets) do if st.ring == spec.ring then street = st end end
			if not band or not street or (spec.side ~= "inner" and spec.side ~= "outer") then
				layout_error("block " .. tostring(spec.name) .. " has an invalid ring or side")
			end
			local d = ARMS[band.arm]
			local out = spec.side == "outer" and 1 or -1
			local sign = (d.x + d.z) * out
			local along = d.x ~= 0 and "x" or "z" -- the band's thin axis
			local a1, a2 = street.rect[along .. "1"], street.rect[along .. "2"]
			local lo, hi
			if sign > 0 then lo, hi = a2 + 1, a2 + row_depth else lo, hi = a1 - row_depth, a1 - 1 end
			if d.x ~= 0 then
				r = {x1 = lo, z1 = spec.from + dz, x2 = hi, z2 = spec.to + dz}
				side = sign > 0 and "+x" or "-x"
			else
				r = {x1 = spec.from + dx, z1 = lo, x2 = spec.to + dx, z2 = hi}
				side = sign > 0 and "+z" or "-z"
			end
		else
			local d = ARMS[spec.arm]
			local toward = TOWARD[spec.side]
			if not d or not toward or (toward[1] ~= 0) == (d.x ~= 0) or not layout.arms[spec.arm] then
				layout_error("block " .. tostring(spec.name) .. " has an invalid arm or side")
			end
			local l1, l2
			if spec.side:sub(1, 1) == "+" then l1, l2 = half, half + row_depth - 1
			else l1, l2 = -half - row_depth, -half - 1 end
			r = translate(arm_rect(layout, spec.arm, spec.from, spec.to, l1, l2), dx, dz)
			arm, side = spec.arm, spec.side
		end
		local block = {
			id = #plan.blocks + 1, name = spec.name, arm = arm, ring = spec.ring, side = side,
			rect = r, size = {x = r.x2 - r.x1 + 1, z = r.z2 - r.z1 + 1},
			area = (r.x2 - r.x1 + 1) * (r.z2 - r.z1 + 1), frontage = {},
		}
		plan.blocks[#plan.blocks + 1] = block
	end
	local ok, why = authored_plan.derive_frontage(plan)
	if not ok then layout_error(why) end
end

function M.build(layout, center, seed, row_depth)
	local W, h = layout.street_width, math.floor(layout.forum_size / 2)
	if W % 2 ~= 0 or layout.forum_size % 2 ~= 0 then
		layout_error("street_width and forum_size must be even")
	end
	local half = math.floor(W / 2)
	local dx, dz = center.x, center.z
	local sites, order, streets = {}, {"forum"}, {}
	local forum = translate({x1 = -h, z1 = -h, x2 = h - 1, z2 = h - 1}, dx, dz)
	sites.forum = {
		name = "forum", kind = "square", rect = forum,
		size = {x = layout.forum_size, z = layout.forum_size},
		material = layout.forum_material,
		approach = {pos = {x = dx, z = dz}},
	}

	local function add(site)
		if sites[site.name] then layout_error("duplicate site name " .. tostring(site.name)) end
		sites[site.name] = site; order[#order + 1] = site.name
	end
	local compounds, arch_exits = {}, {}
	local arm_names = {"north", "south", "east", "west"}
	for _, arm in ipairs(arm_names) do
		local spec = layout.arms[arm]
		if not spec then layout_error("missing arm " .. arm) end
		local vertical = ARMS[arm].x == 0
		local street = {
			id = #streets + 1, name = spec.street, arm = arm, kind = "principal",
			width = W, material = layout.street_material,
			rect = translate(arm_rect(layout, arm, 0, spec.length - 1, -half, half - 1), dx, dz),
		}
		streets[#streets + 1] = street
		if spec.profile ~= nil then
			-- Lane (issue #172): centred, leaving an edge node each side as a
			-- block, from the forum edge to the node before the arch so the arch
			-- approach stays a full block.
			local profile = layout.profiles and layout.profiles[spec.profile]
			if not profile or type(profile.material) ~= "string" then
				layout_error("arm " .. arm .. " has an unknown profile")
			end
			local lane_w = profile.width
			if type(lane_w) ~= "number" or lane_w < 2 or lane_w % 2 ~= 0 or lane_w > W - 2 or spec.length < 2 then
				layout_error("profile " .. spec.profile .. " does not fit the street of " .. arm)
			end
			local inset = (W - lane_w) / 2
			street.lane = {
				material = profile.material,
				rect = translate(arm_rect(layout, arm, 0, spec.length - 2, -half + inset, half - 1 - inset), dx, dz),
			}
		end
		-- The arch's (or terminal landmark's) opening is mid-street, so the box is
		-- centred on the street.
		local toward = {-ARMS[arm].x, -ARMS[arm].z}
		local t = spec.terminal
		local id, rotation = layout.arch_id, spec.arch_rotation
		local depth = 0
		if t then
			-- Terminal landmark (issue #351): an optional paved forecourt square,
			-- then the landmark, instead of an arch.
			id, rotation = t.id, t.rotation
			depth = t.forecourt and t.forecourt.depth or 0
		end
		local sx, sz = footprint(id, rotation)
		local along, across = sz, sx
		if not vertical then along, across = sx, sz end
		if across % 2 ~= 0 then layout_error("landmark width must be even to centre on the street") end
		local l1, l2 = -math.floor(across / 2), math.floor(across / 2) - 1
		if t then
			if t.forecourt then
				local fr = translate(arm_rect(layout, arm, spec.length, spec.length + depth - 1, l1, l2), dx, dz)
				-- Approach: the street-side node just left of the axis.
				local ax, az = dx - 1, ARMS[arm].z > 0 and fr.z1 or fr.z2
				if not vertical then ax, az = ARMS[arm].x > 0 and fr.x1 or fr.x2, dz - 1 end
				add({
					name = t.forecourt.name, kind = "square", rect = fr,
					size = {x = fr.x2 - fr.x1 + 1, z = fr.z2 - fr.z1 + 1},
					material = layout.forum_material, approach = {pos = {x = ax, z = az}},
				})
			end
			local rect = translate(arm_rect(layout, arm, spec.length + depth,
				spec.length + depth + along - 1, l1, l2), dx, dz)
			add(landmark(t.name, t.id, t.rotation, rect, toward, {arm = arm, terminal = true}))
			-- Compound: the box grown by the margin on the three sides away from the forum.
			local m, d = layout.margin, ARMS[arm]
			local c = {x1 = rect.x1 - m, z1 = rect.z1 - m, x2 = rect.x2 + m, z2 = rect.z2 + m}
			if d.z > 0 then c.z1 = rect.z1 elseif d.z < 0 then c.z2 = rect.z2
			elseif d.x > 0 then c.x1 = rect.x1 else c.x2 = rect.x2 end
			compounds[#compounds + 1] = c
		else
			local rect = translate(arm_rect(layout, arm, spec.length, spec.length + along - 1, l1, l2), dx, dz)
			-- The arch's through-passage is the four middle street columns; it is
			-- not pavement but joins the street to its exit (issue #385).
			local d = ARMS[arm]
			local pass = {x1 = rect.x1, x2 = rect.x2, z1 = rect.z1, z2 = rect.z2}
			if d.x ~= 0 then pass.z1, pass.z2 = dz - half + 1, dz + half - 2
			else pass.x1, pass.x2 = dx - half + 1, dx + half - 2 end
			add(landmark(spec.arch, layout.arch_id, spec.arch_rotation, rect, toward, {arm = arm, passage = pass}))
			-- Exit: the street continues from the arch's outer face to the main
			-- rectangle's edge over the passage columns.
			local main = layout.main_rect and translate(layout.main_rect, dx, dz)
			if main then
				local ex = {x1 = pass.x1, x2 = pass.x2, z1 = pass.z1, z2 = pass.z2}
				if d.x ~= 0 then
					if d.x > 0 then ex.x1, ex.x2 = rect.x2 + 1, main.x2 else ex.x1, ex.x2 = main.x1, rect.x1 - 1 end
				else
					if d.z > 0 then ex.z1, ex.z2 = rect.z2 + 1, main.z2 else ex.z1, ex.z2 = main.z1, rect.z1 - 1 end
				end
				arch_exits[#arch_exits + 1] = {arm = arm, rect = ex, name = spec.street .. "_exit"}
			end
		end
	end

	-- Ring bands (issue #164): see the layout for each band's extent.
	local seen_band = {}
	for _, band in ipairs(layout.bands or {}) do
		if type(band) ~= "table" then layout_error("band entries must be tables") end
		local name = band.name
		if type(name) ~= "string" then layout_error("band name must be a string") end
		if seen_band[name] then layout_error("duplicate band name " .. name) end
		seen_band[name] = true
		if not ARMS[band.arm] then layout_error("band " .. name .. " has an unknown arm") end
		if type(band.from) ~= "number" or type(band.to) ~= "number" then
			layout_error("band " .. name .. " has a missing or malformed from..to")
		end
		if band.from ~= math.floor(band.from) or band.to ~= math.floor(band.to) then
			layout_error("band " .. name .. " from..to must be whole nodes")
		end
		if band.from > band.to then layout_error("band " .. name .. " has from past to") end
		local span = band.span
		if type(span) ~= "table" or type(span[1]) ~= "number" or type(span[2]) ~= "number" or span[1] > span[2] then
			layout_error("band " .. name .. " has a missing or malformed span")
		end
		streets[#streets + 1] = {
			id = #streets + 1, name = "ring_" .. name, ring = name, kind = "secondary",
			width = W,
			material = layout.band_material or layout.street_material,
			rect = translate(arm_rect(layout, band.arm, band.from, band.to, span[1], span[2]), dx, dz),
		}
	end

	-- Arch exits (issue #385) follow the ring bands in street order.
	for _, ex in ipairs(arch_exits) do
		streets[#streets + 1] = {
			id = #streets + 1, name = ex.name, arm = ex.arm, kind = "principal", exit = true,
			width = 4, material = layout.street_material, rect = ex.rect,
		}
	end

	for _, spec in ipairs(layout.landmarks) do
		if spec.ring ~= nil then
			add(ring_landmark(layout, streets, spec, dx, dz))
		else
			local d = ARMS[spec.arm]
			local toward = TOWARD[spec.side]
			if not d or not toward or (toward[1] ~= 0) == (d.x ~= 0) then
				layout_error(spec.name .. " has an invalid arm or side")
			end
			-- faces = "forum" turns the entrance toward the forum instead (temples).
			if spec.faces == "forum" then toward = {-d.x, -d.z}
			elseif spec.faces ~= nil then layout_error(spec.name .. " has an invalid faces") end
			local sx, sz = footprint(spec.id, spec.rotation)
			local along, across = sz, sx
			if d.x ~= 0 then along, across = sx, sz end
			local l1, l2
			if spec.side:sub(1, 1) == "+" then l1, l2 = half, half + across - 1
			else l1, l2 = -half - across, -half - 1 end
			local rect = translate(arm_rect(layout, spec.arm, spec.at, spec.at + along - 1, l1, l2), dx, dz)
			add(landmark(spec.name, spec.id, spec.rotation, rect, toward, {arm = spec.arm}))
		end
	end

	-- Boundary (issue #351): the authored main rectangle plus one compound per
	-- terminal landmark; bounds is their enclosing rectangle. Without a
	-- main_rect, the bounding box of the sites plus the margin.
	local rects
	if layout.main_rect then
		rects = {translate(layout.main_rect, dx, dz)}
		for _, c in ipairs(compounds) do rects[#rects + 1] = c end
		local main = rects[1]
		local function inside(r)
			return r.x1 >= main.x1 and r.x2 <= main.x2 and r.z1 >= main.z1 and r.z2 <= main.z2
		end
		for _, name in ipairs(order) do
			if not sites[name].terminal and not inside(sites[name].rect) then
				layout_error("site " .. name .. " leaves the main rectangle")
			end
		end
		for _, st in ipairs(streets) do
			if not inside(st.rect) then layout_error("street " .. st.name .. " leaves the main rectangle") end
		end
	else
		local b
		for _, name in ipairs(order) do
			local r = sites[name].rect
			b = b or {x1 = r.x1, z1 = r.z1, x2 = r.x2, z2 = r.z2}
			b.x1, b.z1 = math.min(b.x1, r.x1), math.min(b.z1, r.z1)
			b.x2, b.z2 = math.max(b.x2, r.x2), math.max(b.z2, r.z2)
		end
		local m = layout.margin
		rects = {{x1 = b.x1 - m, z1 = b.z1 - m, x2 = b.x2 + m, z2 = b.z2 + m}}
	end
	local bounds = {x1 = rects[1].x1, z1 = rects[1].z1, x2 = rects[1].x2, z2 = rects[1].z2}
	for _, r in ipairs(rects) do
		bounds.x1, bounds.z1 = math.min(bounds.x1, r.x1), math.min(bounds.z1, r.z1)
		bounds.x2, bounds.z2 = math.max(bounds.x2, r.x2), math.max(bounds.z2, r.z2)
	end
	local plan = {
		town_type = "roman", seed = seed, center = {x = dx, z = dz},
		bounds = bounds,
		boundary = {rects = rects},
		sites = sites, site_order = order,
		streets = streets, blocks = {}, frontage = {},
	}
	add_blocks(layout, plan, row_depth, dx, dz)
	return plan
end

-- Inputs are already checked by planner.plan. Returns plan or nil, reason, detail.
-- row_depth is the shared catalog row depth (planner.row_depth over
-- content_profile()); blocks are built that deep and validated against it.
function M.plan(center, seed, layout, row_depth)
	local ok, plan = pcall(M.build, layout or M.layout, center, seed, row_depth)
	if not ok then
		local why = tostring(plan)
		return nil, why, {code = "invalid_layout", last = why}
	end
	local valid, why = authored_plan.validate(plan, {min_block_depth = row_depth})
	if not valid then
		return nil, why, {code = "invalid_layout", last = why}
	end
	return plan
end

return M
