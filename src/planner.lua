-- Towns: pure town planner dispatcher. No core.* dependency, so it runs under
-- plain Lua 5.1 and the tests.
--
--   local planner = dofile("src/planner.lua")
--   local plan, reason, detail = planner.plan({x = cx, z = cz}, seed [, opts])
--
-- Inputs are validated with error() (programmer errors): the centre must be
-- a table with integer x and z (|v| <= 31000), the seed an integer with
-- |seed| <= planner.SEED_LIMIT (2^30 - 1, so distinct seeds never alias).
-- planner.check_seed(seed) returns true or nil plus a message, for callers
-- that want to pre-validate without pcall.
--
-- opts:
--   town_type : "medieval" (default) or "roman" (fixed authored civic plan,
--               src/roman_planner.lua; no landmarks option).
--   landmarks : required for medieval plans: the catalog-derived landmark
--               profile (planner.landmark_profile, ticket #38). It names the
--               cathedral and castle and may carry city_hall (ticket #39),
--               jail (#69), services = {tavern, well, chapel} with
--               service_variants (#41, #114) and content = {id -> entry} with
--               roles house, shop and workshop (#42), which also sets the
--               row depth of the blocks.
--
-- Plans are plain tables in the schema documented and validated by
-- src/authored_plan.lua, which is the single validator for both town types
-- (planner.validate is authored_plan.validate). Medieval layouts come from
-- src/medieval_planner.lua, Roman ones from src/roman_planner.lua. After the
-- layout, planner.populate places the jail, services and ordinary content;
-- shortages are reported on the plan, never returned as an error. Finally,
-- plan.objects holds occasional trees/gardens in reachable unused clearings.
--
-- Determinism
-- -----------
-- The plan depends only on (seed, opts). The centre merely translates the
-- layout. Randomness comes from an internal integer PRNG (a 31-bit LCG, every
-- intermediate stays below 2^53 so it is exact in Lua 5.1 doubles);
-- math.random and core.PseudoRandom are never used and nothing depends on
-- pairs() order.

local M = {}

-- Sibling module: via the mod path inside Luanti, else relative to the mod
-- root (tests run from there).
local function load_sibling(name)
	local c = rawget(_G, "core")
	if c and c.get_modpath and c.get_current_modname then
		return dofile(c.get_modpath(c.get_current_modname()) .. "/src/" .. name)
	end
	return dofile("src/" .. name)
end
local geometry = load_sibling("geometry.lua")
local frontage_packer = load_sibling("frontage_packer.lua")(geometry)
local jail_reservation = load_sibling("jail_reservation.lua")(frontage_packer)
local service_reservation = load_sibling("service_reservation.lua")(
	frontage_packer, jail_reservation.occupied_rects)
local content_planner = load_sibling("content_planner.lua")(
	geometry, frontage_packer, jail_reservation.occupied_rects)
local authored_plan = load_sibling("authored_plan.lua")
local roman_planner = load_sibling("roman_planner.lua")
local medieval_planner = load_sibling("medieval_planner.lua")
local catalog = load_sibling("catalog.lua")
local open_space = load_sibling("open_space.lua")
local walls = load_sibling("medieval_walls.lua")
local wall_features = load_sibling("medieval_wall_features.lua")

M.CONSTANTS = {
	-- Population (populate): jail, services and chapels.
	JAIL_MARKET_BIAS = 1,     -- 1: jail entrance farthest from the market
	SERVICE_TAVERNS = 3,      -- target counts
	SERVICE_WELLS = 3,
	SERVICE_CHAPELS = 2,
	CHAPEL_MIN_FROM_CATHEDRAL = 40, -- entrance to cathedral entrance, nodes
	CHAPEL_MIN_BETWEEN = 70,        -- entrance to another chapel's entrance
}

-- Row depth (ticket #86). The depth a street frontage must be given for one
-- row of ordinary buildings, derived from the catalog content of a landmark
-- profile: the packer puts every box with its depth (file Z) side behind the
-- street and its door on the street, so a block that is `d` deep admits
-- exactly the eligible entries whose depth is at most `d` (the door approach
-- lies on the pavement, no extra clearance inside the block). The row depth
-- is the smallest depth that admits at least half of the eligible entries
-- (lower median): not the smallest sample house alone, and not the deepest.
-- Returns nil when the profile has no ordinary content.
function M.row_depth(profile)
	if type(profile) ~= "table" or type(profile.content) ~= "table" then return nil end
	local depths = {}
	for _, e in pairs(profile.content) do
		if type(e) == "table" and type(e.size) == "table" then
			depths[#depths + 1] = e.size.z
		end
	end
	if #depths == 0 then return nil end
	table.sort(depths)
	return depths[math.ceil(#depths / 2)]
end

------------------------------------------------------------------------
-- PRNG (MINSTD; all products < 2^53)
------------------------------------------------------------------------
local MOD = 2147483647
local SEED_LIMIT = 2 ^ 30 - 1 -- |seed| <= this keeps the seed -> state map injective
M.SEED_LIMIT = SEED_LIMIT

local function is_int(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
		and v == math.floor(v)
end

-- true, or nil plus a message saying what to do.
function M.check_seed(seed)
	if is_int(seed) and math.abs(seed) <= SEED_LIMIT then return true end
	return nil, ("seed must be an integer between %d and %d, got %s"):format(
		-SEED_LIMIT, SEED_LIMIT, tostring(seed))
end

-- One LCG step. The affine map has exactly one fixed point (1144636272, i.e.
-- seed 70894448), where the stream would stay forever; it is stepped off by
-- one so no seed locks up. 48271 is a primitive root of MOD, so every other
-- state lies on a single cycle of length MOD - 1.
local function step(s)
	local nxt = (s * 48271 + 1013904223) % MOD
	if nxt == s then nxt = (s + 1) % MOD end
	return nxt
end

-- Every step is an affine bijection of Z_MOD, so distinct seeds in
-- [-SEED_LIMIT, SEED_LIMIT] (mapped to 1 .. MOD) give distinct start states
-- and the first draw of each differs. The state space is only 31 bits, which
-- is why larger seeds are rejected rather than silently aliased.
local function new_rng(seed)
	local s = (seed + 1073741824) % MOD
	for _ = 1, 8 do
		s = step(s)
	end
	local rng = {}
	function rng.int(a, b) -- uniform integer in [a, b]
		s = step(s)
		return a + math.floor(s * (b - a + 1) / MOD)
	end
	function rng.pick(list)
		return list[rng.int(1, #list)]
	end
	return rng
end

------------------------------------------------------------------------
-- Landmark profile
------------------------------------------------------------------------
local function pos_int(v) return is_int(v) and v > 0 end

local function check_landmark(name, L)
	if type(L) ~= "table" or type(L.size) ~= "table" or type(L.entrance) ~= "table" then
		return nil, name .. " landmark needs size and entrance"
	end
	local sz, e = L.size, L.entrance
	if not (pos_int(sz.x) and pos_int(sz.y) and pos_int(sz.z)) then
		return nil, name .. " size must be positive integers"
	end
	if not (is_int(e.x) and is_int(e.z) and e.x >= 0 and e.x < sz.x
			and e.z >= 0 and e.z < sz.z) then
		return nil, name .. " entrance lies outside its box"
	end
	local ey = e.y == nil and 1 or e.y
	local go = L.ground_offset == nil and 0 or L.ground_offset
	if not (is_int(ey) and ey >= 0 and ey < sz.y) then
		return nil, name .. " entrance height lies outside its box"
	end
	if not (is_int(go) and go >= 0 and go < sz.y) then
		return nil, name .. " ground_offset lies outside its box"
	end
	local gs = L.gate_span
	if gs ~= nil and (type(gs) ~= "table" or not is_int(gs.x1) or not is_int(gs.z1)
			or not is_int(gs.x2) or not is_int(gs.z2) or gs.x1 < 0 or gs.z1 < 0
			or gs.x1 > gs.x2 or gs.z1 > gs.z2 or gs.x2 >= sz.x or gs.z2 >= sz.z) then
		return nil, name .. " gate span lies outside its box or is malformed"
	end
	if gs ~= nil and name == "castle" then
		if gs.z1 ~= 0 or gs.z2 ~= 0 or gs.x2 - gs.x1 + 1 ~= 6
				or e.x < gs.x1 or e.x > gs.x2 then
			return nil, "castle gate span must be a six-node line on the canonical -Z wall containing the entrance"
		end
	end
	return {
		id = L.id, size = {x = sz.x, y = sz.y, z = sz.z},
		entrance = {x = e.x, y = ey, z = e.z}, ground_offset = go,
		gate_span = L.gate_span,
	}
end

-- Builds a landmark profile from a catalog snapshot (catalog.snapshot():
-- id -> {size, entrance, ground_offset, role}). The cathedral and castle are
-- the entries with role "cathedral" and "castle"; `ids` optionally names them
-- ({cathedral = id, castle = id}), otherwise the first id in sorted order
-- with that role is used. Returns profile, or nil plus a message. The profile
-- is plain data and may be passed as opts.landmarks to plan().
function M.landmark_profile(snapshot, ids)
	if type(snapshot) ~= "table" then return nil, "catalog snapshot is not a table" end
	local profile = {}
	for _, name in ipairs({"cathedral", "castle"}) do
		local id = ids and ids[name]
		if id == nil then
			local list = {}
			for k, e in pairs(snapshot) do
				if type(e) == "table" and e.role == name then list[#list + 1] = k end
			end
			table.sort(list)
			id = list[1]
			if id == nil then return nil, "catalog has no entry with role " .. name end
		end
		local e = snapshot[id]
		if type(e) ~= "table" then
			return nil, "catalog has no entry '" .. tostring(id) .. "' for the " .. name
		end
		local L, why = check_landmark(name, {id = id, size = e.size,
			entrance = e.entrance, ground_offset = e.ground_offset, gate_span = e.gate_span})
		if not L then return nil, why end
		profile[name] = L
	end
	-- The city hall (ticket #39) is optional: a catalog without a city_hall
	-- entry simply plans no hall.
	local hid = ids and ids.city_hall
	if hid == nil then
		local list = {}
		for k, e in pairs(snapshot) do
			if type(e) == "table" and e.role == "city_hall" then list[#list + 1] = k end
		end
		table.sort(list)
		hid = list[1]
	end
	if hid ~= nil then
		local e = snapshot[hid]
		if type(e) ~= "table" then
			return nil, "catalog has no entry '" .. tostring(hid) .. "' for the city_hall"
		end
		local L, why = check_landmark("city_hall", {id = hid, size = e.size,
			entrance = e.entrance, ground_offset = e.ground_offset})
		if not L then return nil, why end
		profile.city_hall = L
	end
	-- The jail (ticket #69) is optional the same way.
	local jid = ids and ids.jail
	if jid == nil then
		local list = {}
		for k, e in pairs(snapshot) do
			if type(e) == "table" and e.role == "jail" then list[#list + 1] = k end
		end
		table.sort(list)
		jid = list[1]
	end
	if jid ~= nil then
		local e = snapshot[jid]
		if type(e) ~= "table" then
			return nil, "catalog has no entry '" .. tostring(jid) .. "' for the jail"
		end
		local L, why = check_landmark("jail", {id = jid, size = e.size,
			entrance = e.entrance, ground_offset = e.ground_offset})
		if not L then return nil, why end
		profile.jail = L
	end
	-- Distributed services (ticket #41): tavern, well and chapel, each
	-- optional. Every catalog id of a role is a variant (#114) sharing the
	-- role's slots; profile.services[role] stays the first id in sorted
	-- order, and profile.service_variants[role] lists all of them.
	for _, role in ipairs(service_reservation.ROLES) do
		local list = {}
		if ids and ids[role] ~= nil then
			list[1] = ids[role]
		else
			for k, e in pairs(snapshot) do
				if type(e) == "table" and e.role == role then list[#list + 1] = k end
			end
			table.sort(list)
		end
		if #list > 0 then
			local variants = {}
			for _, sid in ipairs(list) do
				local e = snapshot[sid]
				if type(e) ~= "table" then
					return nil, "catalog has no entry '" .. tostring(sid) .. "' for the " .. role
				end
				local L, why = check_landmark(role, {id = sid, size = e.size,
					entrance = e.entrance, ground_offset = e.ground_offset})
				if not L then return nil, why end
				variants[#variants + 1] = L
			end
			profile.services = profile.services or {}
			profile.services[role] = variants[1]
			profile.service_variants = profile.service_variants or {}
			profile.service_variants[role] = variants
		end
	end
	-- Ordinary content (ticket #42): every house, shop and workshop entry.
	for k, e in pairs(snapshot) do
		if type(e) == "table" and content_planner.ROLES[e.role] then
			local L, why = check_landmark(e.role, {id = k, size = e.size,
				entrance = e.entrance, ground_offset = e.ground_offset})
			if not L then return nil, "catalog entry '" .. k .. "': " .. tostring(why) end
			L.role = e.role
			profile.content = profile.content or {}
			profile.content[k] = L
		end
	end
	return profile
end

-- Roman population profile (issue #150): the shared profile for a catalog
-- snapshot minus the medieval-only roles. Ordinary house, shop and workshop
-- entries, tavern, well and jail stay; the cathedral, castle, city hall and
-- chapel are dropped (no chapel stands in for a temple), and monument entries
-- (role "landmark") are never ordinary content. Returns profile, or nil plus
-- a message.
function M.roman_profile(snapshot)
	local profile, why = M.landmark_profile(snapshot)
	if not profile then return nil, why end
	profile.cathedral, profile.castle, profile.city_hall = nil, nil, nil
	if profile.services then profile.services.chapel = nil end
	if profile.service_variants then profile.service_variants.chapel = nil end
	return profile
end
-- Public validator for both town types (authored plans, src/authored_plan.lua).
function M.validate(plan)
	if type(plan) == "table" and plan.town_type ~= nil and plan.town_type ~= "roman"
			and plan.town_type ~= "medieval" then
		return nil, "unknown town type " .. tostring(plan.town_type)
	end
	return authored_plan.validate(plan)
end

-- Shared frontage population for every town type (tickets #69, #41, #42, #150):
-- jail, distributed services, then ordinary content, each best effort. Runs on
-- a finished plan with plan.frontage; sets plan.reservations, plan.shortages
-- and plan.content. A shortage never fails the plan. `profile` is a landmark
-- profile (jail, services and content are optional).
function M.populate(full, profile, seed, occupied)
	local C = M.CONSTANTS
	if not (profile and (profile.jail or profile.services or profile.content)) then
		return
	end
	full.reservations = {}
	full.shortages = {}
	if profile.jail then
		local placed, short = jail_reservation.reserve(full,
			profile.jail, {seed = seed, bias = C.JAIL_MARKET_BIAS, occupied = occupied})
		full.reservations.jail = placed
		if short then full.shortages[1] = short end
	end
	if profile.services then
		local placed, shorts, counts = service_reservation.reserve(
			full, profile.services, {seed = seed,
				variants = profile.service_variants, occupied = occupied,
				targets = {tavern = C.SERVICE_TAVERNS,
					well = C.SERVICE_WELLS, chapel = C.SERVICE_CHAPELS},
				chapel_min_cathedral = C.CHAPEL_MIN_FROM_CATHEDRAL,
				chapel_min_between = C.CHAPEL_MIN_BETWEEN})
		full.reservations.services = placed
		full.reservations.service_counts = counts
		for _, sh in ipairs(shorts) do
			full.shortages[#full.shortages + 1] = sh
		end
	end
	if profile.content then
		-- Private random stream: derived from the seed, never drawn from the
		-- planner's `rng`.
		full.content = content_planner.plan(full, profile.content, {seed = seed, occupied = occupied})
		full.objects = open_space.plan(full, seed, occupied)
	end
end

function M.plan(center, seed, opts)
	if type(center) ~= "table" or not is_int(center.x) or not is_int(center.z)
			or math.abs(center.x) > 31000 or math.abs(center.z) > 31000 then
		error("towns planner: site_center must be a table with integer x and z "
			.. "(|value| <= 31000)", 2)
	end
	local seed_ok, seed_msg = M.check_seed(seed)
	if not seed_ok then
		error("towns planner: " .. seed_msg, 2)
	end
	local profile
	if opts == nil then
		error("towns planner: medieval plans need opts.landmarks, a landmark "
			.. "profile (planner.landmark_profile)", 2)
	end
	if type(opts) ~= "table" then
		error("towns planner: opts must be a table", 2)
	end
	if opts.town_type ~= nil and opts.town_type ~= "medieval" then
		if opts.town_type == "roman" then
			-- Fixed authored civic plan; medieval-only options do not apply.
			local profile, pwhy = M.roman_profile(catalog.snapshot())
			if not profile then error("towns planner: " .. tostring(pwhy), 2) end
			local plan, why, detail = roman_planner.plan(center, seed, nil,
				M.row_depth(profile))
			if plan then M.populate(plan, profile, seed) end
			if plan then
				-- A 30-node forum has a four-node centre; use the lower
				-- coordinate of that centre for this odd-sized fountain.
				local r = plan.sites.forum.rect
				local x, z = math.floor((r.x1 + r.x2) / 2), math.floor((r.z1 + r.z2) / 2)
				plan.objects = plan.objects or {}
				plan.objects[#plan.objects + 1] = {id = "roman_fountain", rotation = 0,
					rect = {x1 = x - 2, z1 = z - 2, x2 = x + 2, z2 = z + 2}}
			end
			return plan, why, detail
		end
		error("towns planner: unknown town type " .. tostring(opts.town_type), 2)
	end
	if opts.landmarks == nil then
		error("towns planner: medieval plans need opts.landmarks, a landmark "
			.. "profile (planner.landmark_profile)", 2)
	end
	local lm = opts.landmarks
	if type(lm) ~= "table" then
		error("towns planner: opts.landmarks must be a landmark profile", 2)
	end
	profile = {}
	local names = {"cathedral", "castle"}
	if lm.city_hall ~= nil then names[#names + 1] = "city_hall" end
	if lm.jail ~= nil then names[#names + 1] = "jail" end
	for _, name in ipairs(names) do
		local L, why = check_landmark(name, lm[name] and {
			id = lm[name].id, size = lm[name].size, entrance = lm[name].entrance,
			ground_offset = lm[name].ground_offset, gate_span = lm[name].gate_span})
		if not L then
			error("towns planner: opts.landmarks: " .. tostring(why or name .. " missing"), 2)
		end
		profile[name] = L
	end
	if lm.services ~= nil then
		if type(lm.services) ~= "table" then
			error("towns planner: opts.landmarks.services must be a table", 2)
		end
		profile.services = {}
		for _, role in ipairs(service_reservation.ROLES) do
			local sv = lm.services[role]
			if sv ~= nil then
				local L, why = check_landmark(role, {id = sv.id, size = sv.size,
					entrance = sv.entrance, ground_offset = sv.ground_offset})
				if not L then
					error("towns planner: opts.landmarks.services: " .. tostring(why), 2)
				end
				profile.services[role] = L
				-- Variants (#114) default to the one given entry.
				local given = lm.service_variants and lm.service_variants[role]
				if type(given) ~= "table" or #given == 0 then given = {sv} end
				local variants = {}
				for _, v in ipairs(given) do
					local V, vwhy = check_landmark(role, {id = v.id, size = v.size,
						entrance = v.entrance, ground_offset = v.ground_offset})
					if not V then
						error("towns planner: opts.landmarks.service_variants: "
							.. tostring(vwhy), 2)
					end
					variants[#variants + 1] = V
				end
				profile.service_variants = profile.service_variants or {}
				profile.service_variants[role] = variants
			end
		end
	end
	if opts.landmarks.content ~= nil then
		local ct = opts.landmarks.content
		if type(ct) ~= "table" then
			error("towns planner: opts.landmarks.content must be a table", 2)
		end
		profile.content = {}
		for k, e in pairs(ct) do
			local L, why = nil, "entry is not a table"
			if type(e) == "table" then
				if not content_planner.ROLES[e.role] then
					why = "role must be house, shop or workshop"
				else
					L, why = check_landmark(e.role, {id = k, size = e.size,
						entrance = e.entrance, ground_offset = e.ground_offset})
				end
			end
			if not L then
				error("towns planner: opts.landmarks.content: " .. tostring(k)
					.. ": " .. tostring(why), 2)
			end
			L.role = e.role
			profile.content[k] = L
		end
	end
	local plan, why, detail = medieval_planner.plan(center, seed, profile, new_rng(seed))
	if not plan then return nil, why, detail end
	local wall = walls.plan(plan, opts.force_walls)
 local occupied
 if wall then
  local structures = {}
  for _, site in pairs(plan.sites) do structures[#structures + 1] = site end
  local candidates = wall_features.candidates(wall, 0, opts.wall_feature_entries or catalog.entries, walls)
  local _, rects = wall_features.select(candidates, structures, plan.streets, nil, true)
  occupied = rects
 end
 M.populate(plan, profile, seed, occupied)
 return plan
end

return M
