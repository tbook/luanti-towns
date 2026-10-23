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
-- Layout (canonical orientation, +Z north, +X east, market north-east of the
-- crossing, castle west). Bands run along X; an E-W street lies between
-- neighbouring bands:
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
--
-- Variation (all seeded, drawn before anything else): the market's quadrant
-- (which corner of the principals' crossing it fills; the hall stands on its
-- far side, the market band is the one that may be deeper), the castle's side
-- (west or east end), and a rigid 0/90/180/270 turn of the whole plan about
-- the centre, applied last. Four quadrants x two castle sides x four turns
-- give 32 arrangements; tests/medieval_variation_tests.lua checks them all.
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

-- Turns a plan (before its frontage is derived) by `turn` degrees about its
-- centre: (dx, dz) -> (dz, -dx) per 90, the same map geometry.place applies to
-- a landmark, so a landmark's rotation just gains `turn`. Landmark sites are
-- rebuilt from their turned rect; everything else is a rect or a point.
function M.turn(plan, turn)
	local c = plan.center
	local function point(x, z)
		local dx, dz = x - c.x, z - c.z
		if turn == 90 then dx, dz = dz, -dx
		elseif turn == 180 then dx, dz = -dx, -dz
		else dx, dz = -dz, dx end
		return c.x + dx, c.z + dz
	end
	local function rect(r)
		local x1, z1 = point(r.x1, r.z1)
		local x2, z2 = point(r.x2, r.z2)
		return {x1 = math.min(x1, x2), z1 = math.min(z1, z2), x2 = math.max(x1, x2), z2 = math.max(z1, z2)}
	end
	local swap = turn ~= 180
	plan.bounds = rect(plan.bounds)
	for i, r in ipairs(plan.boundary.rects) do plan.boundary.rects[i] = rect(r) end
	for _, st in ipairs(plan.streets) do st.rect = rect(st.rect) end
	for _, b in ipairs(plan.blocks) do
		b.rect = rect(b.rect)
		b.size = {x = b.rect.x2 - b.rect.x1 + 1, z = b.rect.z2 - b.rect.z1 + 1}
	end
	for name, site in pairs(plan.sites) do
		local r = rect(site.rect)
		if site.kind == "landmark" then
			local turned = authored_plan.landmark_site(name, site.id, (site.rotation + turn) % 360, r)
			for k, v in pairs(site) do if turned[k] == nil then turned[k] = v end end
			if site.gate_span then turned.gate_span = rect(site.gate_span) end
			plan.sites[name] = turned
		else
			site.rect = r
			local x, z = point(site.approach.pos.x, site.approach.pos.z)
			site.approach.pos = {x = x, z = z}
			if swap then site.size = {x = site.size.z, z = site.size.x} end
		end
	end
end

local function build(center, seed, profile, rng, variant)
	local P, S = M.PRINCIPAL_WIDTH, M.SECONDARY_WIDTH
	local ROW = 0
	for _, e in pairs(profile.content or {}) do ROW = math.max(ROW, e.size.z) end
	if ROW == 0 then ROW = M.DEFAULT_ROW end
	local INNER = 2 * ROW
	local min_block = math.max(M.MIN_BLOCK, ROW) -- a block must hold a row
	local parvis_depth = math.min(M.PARVIS.z, ROW)

	local function R(x1, z1, x2, z2) return {x1 = x1, z1 = z1, x2 = x2, z2 = z2} end
	local function id_entry(L)
		return assert(catalog.entries[L.id], "unknown catalog id " .. tostring(L.id))
	end
	local function place(L, rotation)
		return geometry.place(id_entry(L), {x = 0, y = 0, z = 0}, rotation)
	end

	-- Seeded sizes first, so the extents are known before anything is placed.
	-- `variant` (tests) forces an arrangement; the draws are made either way
	-- so a forced field never shifts the others.
	variant = variant or {}
	local quadrant = rng.int(0, 3)        -- bit 0: market west, bit 1: market south
	local castle_east = rng.int(0, 1) == 1
	local turn = 90 * rng.int(0, 3)
	if variant.quadrant ~= nil then quadrant = variant.quadrant end
	if variant.castle_east ~= nil then castle_east = variant.castle_east end
	if variant.turn ~= nil then turn = variant.turn end
	local market_west, market_south = quadrant % 2 == 1, quadrant >= 2
	local market_len = rng.int(M.MARKET_LENGTH[1], M.MARKET_LENGTH[2])
	local hall_rotation = market_west and 270 or 90 -- faces across the market
	local hall_placed = profile.city_hall and place(profile.city_hall, hall_rotation)
	local market_span = math.max(M.SPAN, market_len + (hall_placed and hall_placed.size.x or 0) + min_block)
	local west_span = market_west and market_span or M.SPAN
	local east_span = market_west and M.SPAN or market_span
	-- The market row is deeper than an ordinary inner row if the hall's
	-- facade needs it.
	local market_depth = math.max(INNER, hall_placed and hall_placed.size.z or 0)

	-- Origin: the centre is the middle of the principals' crossing.
	local X1 = center.x - 3 - west_span
	local Xp = X1 + west_span          -- first x of the N-S principal
	local Xq = Xp + P                  -- first x east of it
	local X2 = Xq + east_span - 1
	local south_depth = market_south and market_depth or INNER
	local Z0 = center.z - (ROW + S + south_depth + 3)

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
	local market_band
	if market_south then
		market_band = {z1 = z, z2 = z + market_depth - 1, kind = "inner"}
		bands[#bands + 1] = market_band; z = z + market_depth
	else
		add_band(INNER, "inner")
	end
	add_street(P, "principal")
	if market_south then
		add_band(INNER, "inner")
	else
		market_band = {z1 = z, z2 = z + market_depth - 1, kind = "inner"}
		bands[#bands + 1] = market_band; z = z + market_depth
	end
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
		if span >= 2 * min_block + S then
			local len = rng.int(min_block, span - min_block - S)
			block(R(a, band.z1, a + len - 1, band.z2))
			street("secondary", R(a + len, band.z1, a + len + S - 1, band.z2))
			block(R(a + len + S, band.z1, b, band.z2))
		else
			block(R(a, band.z1, b, band.z2))
		end
	end

	local market = market_west and R(Xp - market_len, market_band.z1, Xp - 1, market_band.z2)
		or R(Xq, market_band.z1, Xq + market_len - 1, market_band.z2)
	local hall_rect
	if hall_placed then
		local z1 = market_band.z1 + math.floor((market_depth - hall_placed.size.z) / 2)
		local x1 = market_west and market.x1 - hall_placed.size.x or market.x2 + 1
		hall_rect = R(x1, z1, x1 + hall_placed.size.x - 1, z1 + hall_placed.size.z - 1)
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
			if band == market_band and market_west then
				cut(X1, (hall_rect or market).x1 - 1, band)
			else
				cut(X1, Xp - 1, band)
			end
			if band == market_band and not market_west then
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

	-- Castle: outside the west (or east) edge facing the town, gate span on
	-- the E-W principal (a catalog gate is exactly as wide as the street).
	local castle_rotation = castle_east and 90 or 270
	local castle_placed = place(profile.castle, castle_rotation)
	local castle_entry = id_entry(profile.castle)
	local e = castle_entry.entrance
	local local_gate = profile.castle.gate_span or {x1 = e.x, z1 = e.z or 0, x2 = e.x, z2 = e.z or 0}
	local gate = geometry.rotate_rect(castle_entry.size, local_gate, castle_rotation)
	local gate_width = gate.z2 - gate.z1 + 1
	local castle_z1 = ew.z1 + math.floor((P - gate_width) / 2) - gate.z1
	local castle_x1 = castle_east and X2 + 1 or X1 - castle_placed.size.x
	local castle_rect = R(castle_x1, castle_z1, castle_x1 + castle_placed.size.x - 1,
		castle_z1 + castle_placed.size.z - 1)

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
	landmark("cathedral", profile.cathedral, 0, cathedral_rect, {parvis = "parvis"})
	landmark("castle", profile.castle, castle_rotation, castle_rect, {
		gate_span = R(castle_rect.x1 + gate.x1, castle_rect.z1 + gate.z1,
			castle_rect.x1 + gate.x2, castle_rect.z1 + gate.z2),
	})
	if hall_rect then
		landmark("city_hall", profile.city_hall, hall_rotation, hall_rect, {square = "market"})
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
		boundary = {rects = {core, cathedral_rect, castle_rect}},
		sites = sites, site_order = order,
		streets = streets, blocks = blocks, frontage = {},
	}
	if turn ~= 0 then M.turn(plan, turn) end
	local ok, why = authored_plan.derive_frontage(plan)
	if not ok then error(why, 0) end
	return plan, ROW
end

-- Returns plan, or nil, reason, detail. Inputs are already checked by
-- planner.plan. `variant` ({quadrant = 0..3, castle_east = bool, turn = 0, 90,
-- 180 or 270}, any field optional) forces an arrangement; tests only.
function M.plan(center, seed, profile, rng, variant)
	local ok, plan, row = pcall(build, center, seed, profile, rng, variant)
	if not ok then
		local why = "medieval layout: " .. tostring(plan)
		return nil, why, {code = "invalid_layout", last = why}
	end
	local valid, why = authored_plan.validate(plan, {min_block_depth = row})
	if not valid then
		return nil, why, {code = "invalid_layout", last = why}
	end
	return plan
end

return M
