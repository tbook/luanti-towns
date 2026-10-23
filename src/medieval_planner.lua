-- Towns: constructive medieval planner (issue #184).
-- Builds a cross-shaped row-grid plan in the authored-plan schema that
-- src/authored_plan.lua validates; nothing is searched or retried.
--
--   local plan, reason, detail = medieval.plan(center, seed, profile, rng)
--
-- `profile` is a landmark profile (planner.landmark_profile) and `rng` the
-- planner's seeded generator (rng.int(a, b)). Every coordinate below is built
-- from the centre, so plan(center) is a pure translation of plan({0, 0}).
--
-- Layout (canonical orientation, +Z north, +X east). Bands run along X; an
-- E-W street lies between neighbouring bands:
--
--     edge row                   (1 x ROW deep, buildings face south)
--     secondary street
--     inner row                  (2 x ROW deep, two back-to-back rows)
--     PRINCIPAL E-W street
--     inner row                  (market and city hall at the crossing)
--     secondary street
--     edge row                   (1 x ROW deep, buildings face north)
--
-- ROW is the deepest ordinary building, so every building fits every row. The
-- N-S principal street runs through all rows; each inner row on each side of
-- it is cut into blocks by 4-wide N-S secondary streets at seeded positions,
-- independently of the other rows. The cathedral stands outside the north
-- edge facing south with its door on the principal's centre line (a parvis in
-- the north edge row in front of the facade), and the castle outside the west
-- edge with its gate on the E-W principal. The market is the inner-row cell
-- north-east of the crossing, with the city hall on its far edge.
local function sibling(name)
	local c = rawget(_G, "core")
	if c and c.get_modpath and c.get_current_modname then
		return dofile(c.get_modpath(c.get_current_modname()) .. "/src/" .. name)
	end
	local source = debug.getinfo(1, "S").source:sub(2)
	local root = source:match("^(.*)/src/medieval_planner.lua$") or "."
	return dofile(root .. "/src/" .. name)
end
local catalog = sibling("catalog.lua")
local geometry = sibling("geometry.lua")
local authored_plan = sibling("authored_plan.lua")

local M = {}

M.PRINCIPAL_WIDTH = 6
M.SECONDARY_WIDTH = 4
M.PRINCIPAL_MATERIAL = "mcl_core:cobble"
M.SECONDARY_MATERIAL = "mcl_core:gravel"
M.SPAN = 75            -- inner-row length on each side of the N-S principal
M.MIN_BLOCK = 24       -- shortest block cut from an inner row
M.MARKET_LENGTH = {20, 28}
M.DEFAULT_ROW = 13     -- row depth for a profile without ordinary content (the stock
                       -- catalog's deepest building)
M.PARVIS = {x = 12, z = 8}

local function build(center, seed, profile, rng)
	local P, S = M.PRINCIPAL_WIDTH, M.SECONDARY_WIDTH
	local ROW = 0
	for _, e in pairs(profile.content or {}) do ROW = math.max(ROW, e.size.z) end
	if ROW == 0 then ROW = M.DEFAULT_ROW end
	local INNER = 2 * ROW
	local parvis_depth = math.min(M.PARVIS.z, ROW)

	local function R(x1, z1, x2, z2) return {x1 = x1, z1 = z1, x2 = x2, z2 = z2} end
	local function id_entry(L)
		return assert(catalog.entries[L.id], "unknown catalog id " .. tostring(L.id))
	end
	local function place(L, rotation)
		return geometry.place(id_entry(L), {x = 0, y = 0, z = 0}, rotation)
	end

	-- Seeded sizes first, so the extents are known before anything is placed.
	local market_len = rng.int(M.MARKET_LENGTH[1], M.MARKET_LENGTH[2])
	local hall_placed = profile.city_hall and place(profile.city_hall, 90) -- faces -x
	local west_span = M.SPAN
	local east_span = math.max(M.SPAN, market_len + (hall_placed and hall_placed.size.x or 0) + M.MIN_BLOCK)
	-- The market row is deeper than an ordinary inner row if the hall's
	-- facade needs it.
	local market_depth = math.max(INNER, hall_placed and hall_placed.size.z or 0)

	-- Origin: the centre is the middle of the principals' crossing.
	local X1 = center.x - 3 - west_span
	local Xp = X1 + west_span          -- first x of the N-S principal
	local Xq = Xp + P                  -- first x east of it
	local X2 = Xq + east_span - 1
	local Z0 = center.z - (ROW + S + INNER + 3)

	local streets, blocks = {}, {}
	local function street(kind, r)
		streets[#streets + 1] = {
			id = #streets + 1, kind = kind, rect = r,
			width = kind == "principal" and P or S,
			material = kind == "principal" and M.PRINCIPAL_MATERIAL or M.SECONDARY_MATERIAL,
		}
	end
	local function block(r)
		if r.x2 < r.x1 or r.z2 < r.z1 then return end
		blocks[#blocks + 1] = {
			id = #blocks + 1, rect = r, frontage = {},
			size = {x = r.x2 - r.x1 + 1, z = r.z2 - r.z1 + 1},
			area = (r.x2 - r.x1 + 1) * (r.z2 - r.z1 + 1),
		}
	end

	-- Bands from south to north.
	local bands, z = {}, Z0
	local streets_z = {}
	local function add_band(depth, kind) bands[#bands + 1] = {z1 = z, z2 = z + depth - 1, kind = kind}; z = z + depth end
	local function add_street(width, kind)
		streets_z[#streets_z + 1] = {kind = kind, z1 = z, z2 = z + width - 1}
		z = z + width
	end
	add_band(ROW, "edge")
	add_street(S, "secondary")
	add_band(INNER, "inner")
	add_street(P, "principal")
	local market_band = {z1 = z, z2 = z + market_depth - 1, kind = "inner"}
	bands[#bands + 1] = market_band; z = z + market_depth
	add_street(S, "secondary")
	add_band(ROW, "edge")
	local Z2 = z - 1
	local ew = streets_z[2] -- E-W principal

	street("principal", R(X1, ew.z1, X2, ew.z2))
	local parvis = R(Xp - 3, Z2 - parvis_depth + 1, Xp + 8, Z2)
	street("principal", R(Xp, Z0, Xp + P - 1, parvis.z1 - 1))
	for _, s in ipairs(streets_z) do
		if s.kind == "secondary" then street("secondary", R(X1, s.z1, X2, s.z2)) end
	end

	-- An inner-row side: one block, or two split by a N-S secondary street at
	-- a seeded position.
	local function cut(a, b, band)
		local span = b - a + 1
		if span >= 2 * M.MIN_BLOCK + S then
			local len = rng.int(M.MIN_BLOCK, span - M.MIN_BLOCK - S)
			block(R(a, band.z1, a + len - 1, band.z2))
			street("secondary", R(a + len, band.z1, a + len + S - 1, band.z2))
			block(R(a + len + S, band.z1, b, band.z2))
		else
			block(R(a, band.z1, b, band.z2))
		end
	end

	local market = R(Xq, market_band.z1, Xq + market_len - 1, market_band.z2)
	local hall_rect
	if hall_placed then
		local z1 = market_band.z1 + math.floor((market_depth - hall_placed.size.z) / 2)
		hall_rect = R(market.x2 + 1, z1, market.x2 + hall_placed.size.x, z1 + hall_placed.size.z - 1)
	end
	for _, band in ipairs(bands) do
		if band.kind == "edge" then
			if band == bands[1] then
				block(R(X1, band.z1, Xp - 1, band.z2))
				block(R(Xq, band.z1, X2, band.z2))
			else -- the north edge row leaves room for the parvis
				block(R(X1, band.z1, parvis.x1 - 1, band.z2))
				block(R(parvis.x2 + 1, band.z1, X2, band.z2))
			end
		else
			cut(X1, Xp - 1, band)
			if band == market_band then
				cut((hall_rect or market).x2 + 1, X2, band)
			else
				cut(Xq, X2, band)
			end
		end
	end

	-- Cathedral: outside the north edge, door on the principal's centre line.
	local cathedral_placed = place(profile.cathedral, 0)
	local door_x = Xp + 3
	local cathedral_rect = R(door_x - cathedral_placed.entrance.x, Z2 + 1,
		door_x - cathedral_placed.entrance.x + cathedral_placed.size.x - 1, Z2 + cathedral_placed.size.z)

	-- Castle: outside the west edge facing east, gate span on the E-W
	-- principal (a catalog gate is exactly as wide as the street).
	local castle_placed = place(profile.castle, 270)
	local castle_entry = id_entry(profile.castle)
	local e = castle_entry.entrance
	local local_gate = profile.castle.gate_span or {x1 = e.x, z1 = e.z or 0, x2 = e.x, z2 = e.z or 0}
	local gate = geometry.rotate_rect(castle_entry.size, local_gate, 270)
	local gate_width = gate.z2 - gate.z1 + 1
	local castle_z1 = ew.z1 + math.floor((P - gate_width) / 2) - gate.z1
	local castle_rect = R(X1 - castle_placed.size.x, castle_z1, X1 - 1, castle_z1 + castle_placed.size.z - 1)

	local sites, order = {}, {"market", "parvis"}
	sites.market = {
		name = "market", kind = "square", rect = market, material = M.PRINCIPAL_MATERIAL,
		size = {x = market_len, z = market_depth},
		approach = {pos = {x = market.x1, z = market.z1}},
	}
	sites.parvis = {
		name = "parvis", kind = "square", rect = parvis, material = M.PRINCIPAL_MATERIAL,
		size = {x = M.PARVIS.x, z = parvis_depth},
		approach = {pos = {x = door_x, z = parvis.z1}},
	}
	local function landmark(name, L, rotation, rect, extra)
		local site = authored_plan.landmark_site(name, L.id, rotation, rect)
		for k, v in pairs(extra) do site[k] = v end
		sites[name] = site
		order[#order + 1] = name
	end
	-- `side` is the direction the entrance faces.
	landmark("cathedral", profile.cathedral, 0, cathedral_rect, {parvis = "parvis", side = "-z"})
	landmark("castle", profile.castle, 270, castle_rect, {
		side = "+x",
		gate_span = R(castle_rect.x1 + gate.x1, castle_rect.z1 + gate.z1,
			castle_rect.x1 + gate.x2, castle_rect.z1 + gate.z2),
	})
	if hall_rect then
		landmark("city_hall", profile.city_hall, 90, hall_rect, {square = "market", side = "-x"})
	end

	local core = R(X1, Z0, X2, Z2)
	local bounds = R(core.x1, core.z1, core.x2, core.z2)
	for _, r in ipairs({cathedral_rect, castle_rect}) do
		bounds.x1, bounds.z1 = math.min(bounds.x1, r.x1), math.min(bounds.z1, r.z1)
		bounds.x2, bounds.z2 = math.max(bounds.x2, r.x2), math.max(bounds.z2, r.z2)
	end

	local plan = {
		town_type = "medieval", seed = seed, center = {x = center.x, z = center.z},
		bounds = bounds,
		width = bounds.x2 - bounds.x1 + 1, depth = bounds.z2 - bounds.z1 + 1,
		attempts = 1,
		boundary = {rects = {core, cathedral_rect, castle_rect}},
		sites = sites, site_order = order,
		streets = streets, blocks = blocks, frontage = {},
	}
	local ok, why = authored_plan.derive_frontage(plan)
	if not ok then error(why, 0) end
	return plan, ROW
end

-- Returns plan, or nil, reason, detail. Inputs are already checked by
-- planner.plan.
function M.plan(center, seed, profile, rng)
	local ok, plan, row = pcall(build, center, seed, profile, rng)
	if not ok then
		local why = "medieval layout: " .. tostring(plan)
		return nil, why, {code = "invalid_layout", attempts = 0, rejections = {}, last = why}
	end
	local valid, why = authored_plan.validate(plan, {min_block_depth = row})
	if not valid then
		return nil, why, {code = "invalid_layout", attempts = 0, rejections = {}, last = why}
	end
	return plan
end

return M
