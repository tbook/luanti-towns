-- Landmark profile tests (ticket #38): reservations sized from the actual
-- schematic boxes and entrance offsets. Loaded by tests/run.lua:
--   loadfile("tests/landmark_profile_tests.lua")(eq, fails, planner, catalog, geometry, site_search)
local eq, fails, planner, catalog, geometry, site_search = ...

-- Fixed seed set recorded in the ticket report.
local SEEDS = {1, 2, 3, 4, 5, 6, 7, 8}

local function in_rect(r, x, z)
	return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2
end

local function in_boundary(plan, x, z)
	for _, r in ipairs(plan.boundary.rects) do
		if in_rect(r, x, z) then return true end
	end
	return false
end

local function rect_in_boundary(plan, r)
	for z = r.z1, r.z2 do
		for x = r.x1, r.x2 do
			if not in_boundary(plan, x, z) then return false end
		end
	end
	return true
end

local snapshot = catalog.snapshot()
local profile = assert(planner.landmark_profile(snapshot))

-- The profile carries the real, off-centre entrances.
eq(profile.cathedral.id, "cathedral", "profile cathedral id")
eq(profile.castle.id, "castle", "profile castle id")
eq(profile.cathedral.size.x, 55, "cathedral size x")
eq(profile.cathedral.size.z, 59, "cathedral size z")
eq(profile.cathedral.entrance.x, 35, "cathedral entrance x")
eq(profile.cathedral.entrance.z, 8, "cathedral entrance z")
eq(profile.castle.size.x, 50, "castle size x")
eq(profile.castle.size.z, 54, "castle size z")
eq(profile.castle.entrance.x, 24, "castle entrance x")
eq(profile.castle.entrance.z, 3, "castle entrance z")
eq(profile.castle.ground_offset, 5, "castle ground offset")

do
	local p, why = planner.landmark_profile({})
	eq(p, nil, "empty catalog has no profile")
	eq(type(why), "string", "empty catalog reason")
end

-- Check one plan against the real boxes.
local function check_plan(plan, prof, label)
	eq(planner.validate(plan), true, label .. " validates")
	local n = plan.envelope.x2 - plan.envelope.x1 + 1
	eq(n, planner.LANDMARK_ENVELOPE, label .. " envelope")
	eq(#plan.blocks >= planner.CONSTANTS.MIN_BLOCKS, true, label .. " blocks remain")
	eq(#plan.frontage > 0, true, label .. " frontage remains")
	for _, name in ipairs({"cathedral", "castle"}) do
		local site, L = plan.sites[name], prof[name]
		local g = geometry.place({size = L.size, entrance = L.entrance},
			{x = site.rect.x1, y = 0, z = site.rect.z1}, site.rotation)
		local tag = label .. " " .. name
		-- Complete rotated box, inside the boundary.
		eq(site.rect.x2 - site.rect.x1 + 1, g.size.x, tag .. " box width")
		eq(site.rect.z2 - site.rect.z1 + 1, g.size.z, tag .. " box depth")
		eq(rect_in_boundary(plan, site.rect), true, tag .. " box inside boundary")
		-- Real door, not the middle of the edge.
		eq(site.entrance.x, g.entrance.x, tag .. " entrance x")
		eq(site.entrance.z, g.entrance.z, tag .. " entrance z")
		eq(site.door.outside.x, g.outside.x, tag .. " outside x")
		eq(site.door.outside.z, g.outside.z, tag .. " outside z")
		eq(site.door.rise, L.entrance.y - L.ground_offset, tag .. " rise")
		eq(site.id, name, tag .. " catalog id")
		eq(site.facing.x, g.front.x, tag .. " facing x")
		eq(site.facing.z, g.front.z, tag .. " facing z")
		-- Approach node is the pavement node in line with the door, on the
		-- row just outside the box side.
		local pos, f = site.approach.pos, site.facing
		eq(in_rect(site.approach.edge, pos.x, pos.z), true, tag .. " approach pos on edge")
		eq(in_rect(site.rect, pos.x, pos.z), false, tag .. " approach pos outside box")
		eq(in_boundary(plan, pos.x, pos.z), true, tag .. " approach pos in boundary")
		if f.x == 0 then
			eq(pos.x, site.entrance.x, tag .. " approach aligned with door")
		else
			eq(pos.z, site.entrance.z, tag .. " approach aligned with door")
		end
		-- The recess is inside the box: the cell outside the door is part of
		-- the landmark obstacle, not street.
		eq(in_rect(site.rect, site.door.outside.x, site.door.outside.z), true,
			tag .. " outside-door cell inside box")
	end
	eq(plan.sites.castle.door.recess, 3, label .. " castle recess")
	eq(plan.sites.castle.door.rise, 1, label .. " castle rise")
	eq(plan.sites.cathedral.door.recess, 8, label .. " cathedral recess")
	eq(plan.sites.cathedral.door.rise, 4, label .. " cathedral rise")
	-- The parvis is adjacent on the entrance side, PARVIS_WIDTH x
	-- PARVIS_FRONT_DEPTH, centred on the real (off-centre) door (#105); it
	-- need not span the compound, and contains the door's approach node.
	local c, pv = plan.sites.cathedral, plan.sites.parvis
	do
		local K = planner.CONSTANTS
		local pr, f = pv.rect, c.facing
		local w, d = pr.x2 - pr.x1 + 1, pr.z2 - pr.z1 + 1
		local lat, lo, depth, width
		if f.x == 0 then lat, lo, width, depth = c.entrance.x, pr.x1, w, d
		else lat, lo, width, depth = c.entrance.z, pr.z1, d, w end
		eq(width, K.PARVIS_WIDTH, label .. " parvis width")
		eq(depth, K.PARVIS_FRONT_DEPTH, label .. " parvis depth")
		eq(lo, lat - math.floor(K.PARVIS_WIDTH / 2), label .. " parvis centred on door")
		-- Clear approach: the node in front of the door edge is parvis.
		eq(in_rect(pr, c.approach.pos.x, c.approach.pos.z), true, label .. " parvis fronts door")
	end
	eq(in_rect(pv.rect, c.approach.pos.x, c.approach.pos.z), true,
		label .. " parvis contains the door approach")
end

for _, seed in ipairs(SEEDS) do
	local plan, why = planner.plan({x = 100, z = -40}, seed, {landmarks = profile})
	eq(plan ~= nil, true, "profile seed " .. seed .. " planned: " .. tostring(why))
	if plan then
		check_plan(plan, profile, "seed " .. seed)
		-- Repeat reproduces the plan.
		local again = planner.plan({x = 100, z = -40}, seed, {landmarks = profile})
		eq(again ~= nil and again.attempts == plan.attempts, true,
			"seed " .. seed .. " attempts repeat")
		eq(again ~= nil and again.sites.castle.entrance.x == plan.sites.castle.entrance.x
			and again.sites.cathedral.rect.z1 == plan.sites.cathedral.rect.z1
			and #again.streets == #plan.streets and #again.blocks == #plan.blocks, true,
			"seed " .. seed .. " layout repeats")
	end
end

-- Translation: same shape at another centre.
do
	local a = planner.plan({x = 0, z = 0}, 3, {landmarks = profile})
	local b = planner.plan({x = 700, z = -900}, 3, {landmarks = profile})
	eq(a ~= nil and b ~= nil, true, "translation plans")
	if a and b then
		eq(b.sites.castle.entrance.x - a.sites.castle.entrance.x, 700, "translated castle door x")
		eq(b.sites.castle.entrance.z - a.sites.castle.entrance.z, -900, "translated castle door z")
		eq(b.sites.cathedral.rect.x1 - a.sites.cathedral.rect.x1, 700, "translated cathedral x")
	end
end

-- A synthetic small, off-centre profile on an explicit (legacy-size)
-- envelope: derived dimensions follow the envelope together.
do
	local small = {
		cathedral = {id = "t_cath", size = {x = 20, y = 18, z = 30},
			entrance = {x = 5, y = 3, z = 2}, ground_offset = 1},
		castle = {id = "t_castle", size = {x = 24, y = 20, z = 26},
			entrance = {x = 17, y = 5, z = 3}, ground_offset = 2},
	}
	local opts = {landmarks = small, constants = {ENVELOPE = 96}}
	local C = planner.resolve_constants(opts)
	eq(C.ENVELOPE, 96, "explicit envelope")
	eq(C.MIN_LONG_SPAN, 80, "derived long span at 96")
	local plan, why = planner.plan({x = 0, z = 0}, 11, opts)
	eq(plan ~= nil, true, "synthetic profile planned: " .. tostring(why))
	if plan then
		eq(planner.validate(plan), true, "synthetic profile validates")
		eq(plan.envelope.x2 - plan.envelope.x1 + 1, 96, "synthetic envelope")
		eq(plan.sites.castle.door.rise, 3, "synthetic castle rise")
		eq(plan.sites.castle.door.recess ~= nil, true, "synthetic castle recess")
	end
	local CL = planner.resolve_constants({landmarks = small})
	eq(CL.ENVELOPE, planner.LANDMARK_ENVELOPE, "profile envelope default")
	eq(planner.LANDMARK_ENVELOPE, 208, "landmark envelope (#89)")
	eq(CL.MIN_LONG_SPAN, 173, "derived long span at 208")
	eq(CL.MIN_SHORT_SPAN, 130, "derived short span at 208")
	eq(CL.CENTER_JITTER, 17, "derived jitter at 208")
	-- Block tuning (#86, #89) applies to profile plans only.
	eq(CL.MAX_BLOCK_DEPTH, 24, "profile max block depth")
	eq(CL.MIN_BLOCK_SIDE, 12, "profile min block side")
	eq(planner.resolve_constants().MAX_BLOCK_DEPTH, 12, "legacy max block depth")
	eq(planner.resolve_constants().MIN_BLOCK_SIDE, 8, "legacy min block side")
	eq(planner.CONSTANTS.STREET_WIDTH, 5, "principal street width (#88)")
	eq(planner.CONSTANTS.CITY_HALL_MARGIN, 5, "hall margin follows the street width")
	eq(planner.resolve_constants().ENVELOPE, 96, "legacy envelope default")
end

-- Legacy fixtures are untouched: no profile means Phase 2 sizes and no door.
do
	local plan = planner.plan({x = 0, z = 0}, 3)
	eq(plan ~= nil, true, "legacy plan")
	if plan then
		eq(plan.envelope.x2 - plan.envelope.x1 + 1, 96, "legacy envelope")
		eq(plan.sites.castle.door, nil, "legacy castle has no door record")
		eq(plan.sites.cathedral.id, nil, "legacy cathedral has no catalog id")
	end
end

-- Unsupported fit fails clearly, immediately and without consuming attempts.
do
	local plan, why, detail = planner.plan({x = 0, z = 0}, 1,
		{landmarks = profile, constants = {ENVELOPE = 64}})
	eq(plan, nil, "unfit profile has no plan")
	eq(detail.code, "unsupported_fit", "unfit code")
	eq(detail.attempts, 0, "unfit attempts")
	eq(tostring(why):find("does not fit", 1, true) ~= nil, true, "unfit reason names the cause")
	fails(function()
		planner.plan({x = 0, z = 0}, 1, {landmarks = {cathedral = profile.cathedral}})
	end, "opts.landmarks", "incomplete profile is an error")
	fails(function()
		planner.plan({x = 0, z = 0}, 1, {landmarks = {
			cathedral = {size = {x = 5, y = 5, z = 5}, entrance = {x = 9, z = 0}},
			castle = profile.castle}})
	end, "entrance lies outside", "entrance outside box is an error")
end

-- Bounded retries still apply with a profile.
do
	local plan, _, detail = planner.plan({x = 0, z = 0}, 1,
		{landmarks = profile, max_attempts = 0})
	eq(plan, nil, "zero budget with profile")
	eq(detail.code, "retries_exhausted", "zero budget code with profile")
end

-- A tampered door is rejected by the validator.
do
	local plan = planner.plan({x = 0, z = 0}, 2, {landmarks = profile})
	eq(plan ~= nil, true, "tamper base plan")
	if plan then
		plan.sites.castle.approach.pos.x = plan.sites.castle.approach.pos.x + 100
		eq(planner.validate(plan), nil, "tampered approach pos rejected")
	end
	plan = planner.plan({x = 0, z = 0}, 2, {landmarks = profile})
	if plan then
		plan.sites.castle.door.recess = plan.sites.castle.door.recess + 1
		eq(planner.validate(plan), nil, "tampered recess rejected")
	end
end

-- Site search: the default reach grows with the envelope; terrain limits do
-- not. (The player is not on solid ground, so the search stops at once and
-- only reports the candidate count.)
do
	local env = {
		emerge = function() end, after = function() end,
		get_node_name = function() return "air" end,
		node_info = function() return nil end,
	}
	local function total(opts)
		local t
		site_search.search({x = 0, y = 10, z = 0}, 1, opts, function(_, _, d)
			t = d.candidates_total
		end, env)
		return t
	end
	local legacy = total({})
	local grown = total({planner_opts = {landmarks = profile}})
	eq(grown > legacy, true, "profile search reach grows")
	eq(total({planner_opts = {landmarks = profile}, max_radius = 320}), legacy,
		"explicit max_radius is not grown")
	eq(site_search.CONSTANTS.MAX_RANGE, 16, "terrain range unchanged")
	eq(site_search.CONSTANTS.MAX_CUT_FILL, 24, "terrain cut/fill unchanged")
end
