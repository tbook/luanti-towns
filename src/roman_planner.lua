-- Towns: pure Roman civic planner (issue #148).
-- Turns the authored layout in src/roman_civic_plan.lua into an authored plan
-- (the schema src/authored_plan.lua validates). No core.* dependency.
--
--   local roman = dofile("src/roman_planner.lua")
--   local plan, reason, detail = roman.plan({x = cx, z = cz}, seed)
--
-- Every seed gives the same civic geometry; the seed is only recorded. The
-- centre merely translates the layout. Ordinary blocks and frontage are empty
-- until later tickets. Plans are returned only after authored validation.
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

-- Place `id` at `rect` and describe it as an authored landmark site. The
-- approach is the first node outside the box along the entrance front, so a
-- recessed door still has a paved node on the box edge.
local function landmark(name, id, rotation, rect, toward, extra)
	local placed = geometry.place(entry_of(id), {x = rect.x1, y = 0, z = rect.z1}, rotation)
	if placed.front.x ~= toward[1] or placed.front.z ~= toward[2] then
		layout_error(name .. " rotation " .. rotation .. " does not face its street")
	end
	local ax, az = placed.outside.x, placed.outside.z
	while ax >= rect.x1 and ax <= rect.x2 and az >= rect.z1 and az <= rect.z2 do
		ax, az = ax + placed.front.x, az + placed.front.z
	end
	local site = {
		name = name, kind = "landmark", id = id, rotation = rotation,
		rect = rect, size = {x = placed.size.x, z = placed.size.z},
		entrance = {x = placed.entrance.x, z = placed.entrance.z},
		facing = {x = placed.front.x, z = placed.front.z},
		approach = {pos = {x = ax, z = az}},
	}
	for k, v in pairs(extra) do site[k] = v end
	return site
end

local function footprint(id, rotation)
	local size = geometry.place(entry_of(id), {x = 0, y = 0, z = 0}, rotation).size
	return size.x, size.z
end

function M.build(layout, center, seed)
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
	local arm_names = {"north", "south", "east", "west"}
	for _, arm in ipairs(arm_names) do
		local spec = layout.arms[arm]
		if not spec then layout_error("missing arm " .. arm) end
		local vertical = ARMS[arm].x == 0
		streets[#streets + 1] = {
			id = #streets + 1, name = spec.street, arm = arm, kind = "principal",
			width = W, axis = vertical and "z" or "x", material = layout.street_material,
			rect = translate(arm_rect(layout, arm, 0, spec.length - 1, -half, half - 1), dx, dz),
		}
		-- The arch's opening is mid-street, so the box is centred on the street.
		local sx, sz = footprint(layout.arch_id, spec.arch_rotation)
		local along, across = sz, sx
		if not vertical then along, across = sx, sz end
		if across % 2 ~= 0 then layout_error("arch width must be even to centre on the street") end
		local rect = translate(arm_rect(layout, arm, spec.length, spec.length + along - 1,
			-math.floor(across / 2), math.floor(across / 2) - 1), dx, dz)
		local toward = {-ARMS[arm].x, -ARMS[arm].z}
		add(landmark(spec.arch, layout.arch_id, spec.arch_rotation, rect, toward, {arm = arm}))
	end

	for _, spec in ipairs(layout.landmarks) do
		local d = ARMS[spec.arm]
		local toward = TOWARD[spec.side]
		if not d or not toward or (toward[1] ~= 0) == (d.x ~= 0) then
			layout_error(spec.name .. " has an invalid arm or side")
		end
		local sx, sz = footprint(spec.id, spec.rotation)
		local along, across = sz, sx
		if d.x ~= 0 then along, across = sx, sz end
		local l1, l2
		if spec.side:sub(1, 1) == "+" then l1, l2 = half, half + across - 1
		else l1, l2 = -half - across, -half - 1 end
		local rect = translate(arm_rect(layout, spec.arm, spec.at, spec.at + along - 1, l1, l2), dx, dz)
		add(landmark(spec.name, spec.id, spec.rotation, rect, toward, {arm = spec.arm, side = spec.side}))
	end

	local bounds
	for _, name in ipairs(order) do
		local r = sites[name].rect
		bounds = bounds or {x1 = r.x1, z1 = r.z1, x2 = r.x2, z2 = r.z2}
		bounds.x1, bounds.z1 = math.min(bounds.x1, r.x1), math.min(bounds.z1, r.z1)
		bounds.x2, bounds.z2 = math.max(bounds.x2, r.x2), math.max(bounds.z2, r.z2)
	end
	local m = layout.margin
	bounds = {x1 = bounds.x1 - m, z1 = bounds.z1 - m, x2 = bounds.x2 + m, z2 = bounds.z2 + m}
	return {
		town_type = "roman", seed = seed, center = {x = dx, z = dz},
		envelope = {x1 = bounds.x1, z1 = bounds.z1, x2 = bounds.x2, z2 = bounds.z2},
		bounds = bounds,
		width = bounds.x2 - bounds.x1 + 1, depth = bounds.z2 - bounds.z1 + 1,
		boundary = {rects = {{x1 = bounds.x1, z1 = bounds.z1, x2 = bounds.x2, z2 = bounds.z2}}},
		sites = sites, site_order = order,
		streets = streets, blocks = {}, frontage = {},
		attempts = 1,
	}
end

-- Inputs are already checked by planner.plan. Returns plan or nil, reason, detail.
function M.plan(center, seed, layout)
	local ok, plan = pcall(M.build, layout or M.layout, center, seed)
	if not ok then
		local why = tostring(plan)
		return nil, why, {code = "invalid_layout", attempts = 0, rejections = {}, last = why}
	end
	local valid, why = authored_plan.validate(plan)
	if not valid then
		return nil, why, {code = "invalid_layout", attempts = 0, rejections = {}, last = why}
	end
	return plan
end

return M
