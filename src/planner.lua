-- Towns: pure town planner (boundary, civic sites, streets, blocks, frontage).
-- No core.* dependency, so it runs under plain Lua 5.1 and the tests.
--
--   local planner = dofile("src/planner.lua")
--   local plan, reason, detail = planner.plan({x = cx, z = cz}, seed [, opts])
--
-- Inputs are validated with error() (programmer errors): the centre must be
-- a table with integer x and z (|v| <= 31000), the seed an integer with
-- |seed| <= planner.SEED_LIMIT (2^30 - 1, so distinct seeds never alias).
-- planner.check_seed(seed) returns true or nil plus a message, for callers
-- that want to pre-validate without pcall. When bounded retries are
-- exhausted, plan returns
-- nil, "<readable reason>", {code = "retries_exhausted", attempts = n,
-- rejections = {[stage] = count, ...}}.
--
-- opts (all optional, mainly for tests / tuning):
--   max_attempts : integer >= 0, overrides MAX_ATTEMPTS
--   constants    : table overriding any named constant in planner.CONSTANTS
--   landmarks    : catalog-derived landmark profile (planner.landmark_profile,
--                  ticket #38). Cathedral and castle reservations are then
--                  the complete rotated schematic boxes with their real,
--                  possibly off-centre and recessed doors, and the envelope
--                  defaults to planner.LANDMARK_ENVELOPE (208) with
--                  MIN_LONG_SPAN, MIN_SHORT_SPAN, CENTER_JITTER, MAX_SECONDARY
--                  and MAX_BLOCK_SCAN scaled with it, and the LANDMARK_TUNING
--                  block constants applied (planner.resolve_constants).
--                  Without it the Phase 2 nominal footprints and the 96-node
--                  envelope are used. A profile that cannot fit the envelope
--                  returns nil, reason, {code = "unsupported_fit"} at once.
--                  A profile may also carry city_hall (tickets #39, #106):
--                  plan.sites.city_hall (kind "landmark", square = "market",
--                  outside site_order) is a complete rotated box OUTSIDE the
--                  open market rectangle, touching one market edge with its
--                  facade within that edge and its real (off-centre, recessed)
--                  door facing across it, so the door approach is a market
--                  pavement node. The open market is sized independently of
--                  the hall (it only has to be as long as the facade); the
--                  hall is an obstacle for streets, routing and the other
--                  landmarks, keeping a street width clear of them.
--                  A profile may also carry jail (ticket #69): the finished
--                  plan then has plan.reservations.jail (src/jail_reservation.lua:
--                  one box on ordinary street frontage, entrance farthest from
--                  the market centre) or, when nothing fits, plan.shortages =
--                  {{role = "jail", wanted = 1, placed = 0, reason}}. Plans
--                  without a jail profile carry neither field.
--                  A profile may also carry services = {tavern, well, chapel}
--                  (ticket #41, src/service_reservation.lua): after the jail the
--                  plan gets plan.reservations.services (list of placements),
--                  plan.reservations.service_counts and unmet targets appended
--                  to plan.shortages. Plans without services carry none of it.
--                  service_variants = {role -> list of entries} (#114) lists
--                  every catalog id of a role; the variants share that role's
--                  slots. Without it each role has only services[role].
--                  A profile may also carry content = {id -> {id, size,
--                  entrance, role}} with roles house, shop and workshop
--                  (ticket #42, src/content_planner.lua): after the services
--                  the plan gets plan.content = {buildings, unused,
--                  empty_runs, counts, rejected, reason}, ordinary frontage
--                  packed on the shared occupancy with a private random
--                  stream. Plans without content carry no plan.content.
--
-- Determinism
-- -----------
-- The plan depends only on (seed, constants). The centre merely translates
-- the layout, so the same seed gives the same shape at any centre. Randomness
-- comes from an internal integer PRNG (a 31-bit LCG, every intermediate stays
-- below 2^53 so it is exact in Lua 5.1 doubles); math.random and
-- core.PseudoRandom are never used and nothing depends on pairs() order.
--
-- Plan schema (plain tables only; coordinates are absolute node X/Z)
-- ------------------------------------------------------------------
-- World axes as in geometry.lua: +X east, +Z north, -Z south. Sides are named
-- by axis: "-x", "+x", "-z", "+z". A rectangle is inclusive min/max
-- {x1, z1, x2, z2} (same convention as geometry.place min/max).
--
-- plan = {
--   seed     = integer,
--   center   = {x, z},                    -- the input centre (inside boundary)
--   envelope = rect,                      -- center-48 .. center+47 on both axes
--   bounds   = rect,                      -- exact bounding box of the boundary
--   width, depth = integer,               -- bounds extent along X and Z
--   boundary = {                          -- connected orthogonal union
--     rects = { rect, ... },              -- broad overlapping rectangles
--   },                                    --  (membership: inside ANY rect)
--   sites = {                             -- keyed by name, see site_order
--     cathedral = site, parvis = site, market = site, castle = site,
--   },
--   site_order = {"cathedral", "parvis", "market", "castle"},
--   approaches = {                        -- boundary entrances for routing
--     {name = "approach_1", side = "+z", edge = rect, pos = {x, z}}, ...
--   },
--   streets  = { street, ... },           -- see "Streets" below (src/streets.lua)
--   blocks   = { block, ... },
--   frontage = { run, ... },
--   attempts = integer,                   -- 1-based attempt that succeeded
-- }
--
-- site = {
--   name     = "cathedral" | "parvis" | "market" | "castle",
--   kind     = "landmark" | "square",
--   rect     = rect,                      -- reserved footprint
--   size     = {x, z},                    -- rect extent
--   side     = "-z"|"+z"|"-x"|"+x",       -- entrance/outward side of the rect
--   facing   = {x, z},                    -- unit vector for `side`
--   rotation = 0|90|180|270,              -- geometry.lua rotation whose front
--                                         --  vector equals `facing`
--   approach = {side, edge, pos},         -- see below
--   -- landmark only:
--   entrance = {x, z},                    -- door node on the footprint edge
--   -- profile landmarks only (opts.landmarks):
--   --   id   = catalog id,
--   --   door = {recess, rise, outside = {x, z}}: recess is how many nodes the
--   --          door lies behind the footprint edge on the entrance side (the
--   --          cell outside the door is inside the rect, i.e. part of the
--   --          landmark obstacle), rise how many nodes the door sits above
--   --          site ground (entrance y - ground_offset), outside the cell
--   --          one node out from the door. `entrance` is then the real door
--   --          node (inside the rect) and approach.pos the edge node in line
--   --          with it, not the middle of the edge.
--   -- cathedral only: parvis = "parvis"   -- name of its adjacent square
--   -- castle only:    outer_side, edge_gap -- side lying on the boundary edge
--   --                  and how many nodes of boundary lie beyond it (0 =
--   --                  touching, <= CASTLE_EDGE_SLACK)
-- }
--
-- Approach: `edge` is a 1-node-thick rect of the nodes just outside the
-- footprint along `side`; `pos` is the node of that edge in front of the
-- entrance (landmarks) or its middle (squares). For the cathedral the
-- approach is its entrance edge, which lies inside the parvis; streets reach
-- the cathedral through the parvis, whose approach is its far edge. The
-- market and parvis squares are open to routing from any side that is not the
-- cathedral; their approach is a preferred attachment point only.
--
-- Boundary approaches: `edge` is a STREET_WIDTH (5) wide, 1-deep rect of
-- boundary nodes on an outer edge, `pos` its middle node (x1 + 2 or z1 + 2,
-- two nodes each side; with an even width it would be floor-middle, not
-- centred), `side` the outward direction. The two approaches are on
-- different sides and their STREET_WIDTH-square inward windows never overlap. Site `approach.pos` follows the same
-- floor-middle rule along the site's edge.
--
-- Streets, blocks, frontage (filled by src/streets.lua on every accepted
-- boundary/sites attempt; a street failure counts as a rejected attempt and
-- is retried within the same budget). Squares (market, parvis) gain
-- `material` = SQUARE_MATERIAL.
--
-- street = {
--   id       = integer (index in plan.streets; principal streets come first),
--   kind     = "principal" | "secondary",
--   width    = 5 | 4,                     -- equals the rect's short side
--   rect     = rect,                      -- full-width straight run
--   axis     = "x" | "z",                 -- long axis ("x" for a square corner)
--   material = "mcl_core:stonebrick" (principal) | "mcl_core:cobble",
--   route    = "approach_1>market" | "approach_2>market" | "network>parvis"
--              | "network>castle" | "secondary",
-- }
-- A route is several straight street rects (one per run between bends);
-- rects may overlap each other and squares at bends and junctions. The
-- pavement is the union of all street rects and the market/parvis rects; a
-- cell takes the material of the first of: squares, then streets in id order.
-- Principal streets never lie wholly on existing pavement (such runs are
-- dropped, and fully paved run ends are trimmed so streets abut squares).
--
-- block = {
--   id = integer, rect = rect, size = {x, z}, area = integer,
--   frontage = { frontage ids },          -- always at least one run
-- }
-- Blocks are free interior cells (inside the boundary, off streets, squares
-- and landmark footprints), at least MIN_BLOCK_SIDE on both sides. Adjacent
-- block rects may abut where a leftover area was not rectangular; there is
-- no street between them and so no frontage between them.
--
-- run (plan.frontage) = {
--   id = integer, block = block id,
--   side   = "-z"|"+z"|"-x"|"+x",         -- outward direction from the block
--   facing = {x, z},                      -- unit vector for `side`
--   rect   = rect,                        -- 1-thick run of block edge nodes
--   length = integer (>= MIN_FRONTAGE_RUN),
--   street = street id  | square = "market"|"parvis",  -- what it faces
--   material = that street's / the square's material,
-- }
-- Every node one step from the run along `facing` is pavement of the named
-- street or square.
--
-- The market is placed with its centre within MARKET_CENTER_RADIUS of the
-- town centre; it is not guaranteed to contain the centre node.
--
-- Validation: planner.validate(plan[, constants]) is pure and works on a
-- finished plan in world coordinates (it can be re-run before any world
-- write). It returns true, or nil plus a reason. plan() runs it as its final
-- accept gate, so generator and validator cannot diverge. It checks:
-- boundary connectivity, size and feature size (steps, notches, arms >=
-- MIN_FEATURE), exact bounds inside the envelope, centre inside the
-- boundary, site containment, no overlaps and >= STREET_WIDTH between sites
-- (cathedral and parvis touch by design; the parvis is centred on the door),
-- the market near the centre, the castle on a straight outer edge, the two
-- approaches (different sides, non-overlapping windows), and route space:
-- with the cathedral and castle footprints as obstacles, a chain of free
-- STREET_WIDTH-square windows must join the two approaches and cover the approach `pos` node
-- of the market, parvis, cathedral and castle (so each door has a full street
-- width of free space in front of it).
-- Then streets.validate always runs (a plan without streets is rejected):
-- street widths, kinds, materials and axes; containment in the boundary; no
-- landmark overlap; no dead-end principal streets (each end joins a street,
-- square, landmark, or the town entrance / a door node); both approaches
-- connected by pavement (and by principal streets alone) to the market and
-- parvis; fully paved STREET_WIDTH-wide windows reachable from both approaches that
-- cover the castle and cathedral approach.pos (so the castle route reaches
-- the door, not merely the approach edge); blocks off the pavement, at least
-- MIN_BLOCK_SIDE with frontage; frontage runs on their block's edge facing
-- the street or square they name. plan() additionally requires MIN_BLOCKS
-- blocks and runs this check once, as its final accept gate.

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
local streets = load_sibling("streets.lua")
local geometry = load_sibling("geometry.lua")
local frontage_packer = load_sibling("frontage_packer.lua")(geometry)
local jail_reservation = load_sibling("jail_reservation.lua")(frontage_packer)
local service_reservation = load_sibling("service_reservation.lua")(
	frontage_packer, jail_reservation.occupied_rects)
local interior_access = load_sibling("interior_access.lua")
local content_planner = load_sibling("content_planner.lua")(
	geometry, frontage_packer, jail_reservation.occupied_rects, interior_access)
local authored_plan = load_sibling("authored_plan.lua")
local roman_planner = load_sibling("roman_planner.lua")
local catalog = load_sibling("catalog.lua")

M.CONSTANTS = {
	ENVELOPE = 96,            -- town envelope, nodes per side
	MIN_LONG_SPAN = 80,       -- boundary bbox: longer side at least
	MIN_SHORT_SPAN = 60,      --                 shorter side at least
	MIN_ASPECT_DELTA = 12,    -- |width - depth| at least (non-square)
	MIN_FEATURE = 12,         -- min edge length, step depth, notch, arm width
	CENTER_JITTER = 8,        -- bbox centre vs town centre, nodes per axis
	MIN_FILL = 0.60,          -- boundary area / bbox area range
	MAX_FILL = 0.90,
	RECT_COUNT_MIN = 3,       -- target broad overlapping rectangles per boundary
	RECT_COUNT_MAX = 5,       --   (extras are skipped if they would not overlap)
	STREET_WIDTH = 5,         -- principal street width / route clearance (#88)
	CATHEDRAL_LONG = 32,      -- footprint, long axis (entrance on short end)
	CATHEDRAL_SHORT = 20,
	PARVIS_DEPTH = 12,        -- legacy (no profile) parvis depth
	PARVIS_MARGIN = 4,        -- legacy: extra width each side of the whole front
	-- Profile plans (#105): the parvis is a PARVIS_WIDTH x PARVIS_FRONT_DEPTH
	-- rect on the entrance side, touching the box edge and centred on the
	-- door's lateral coordinate e: it spans e - floor(W/2) .. that + W - 1,
	-- so an even width puts the extra node on the lower-coordinate (-x / -z)
	-- side in world space, for every rotation. It need not span the footprint.
	PARVIS_WIDTH = 12,        -- along the facade
	PARVIS_FRONT_DEPTH = 8,   -- perpendicular to the entrance side
	MARKET_MIN = 20, MARKET_MAX = 28, -- market side lengths (varied per axis)
	MARKET_CENTER_RADIUS = 12, -- market centre within this of the town centre
	CASTLE_X = 30, CASTLE_Z = 26, -- footprint (axes swapped half the time)
	CASTLE_EDGE_SLACK = 2,    -- max nodes between castle and outer edge
	MARKET_TRIES = 40,        -- random market placements tried per attempt
	MAX_ATTEMPTS = 256,        -- bounded retries
	-- Streets, blocks, frontage (src/streets.lua)
	SECONDARY_WIDTH = 4,
	TURN_PENALTY = 6,         -- route cost of a bend, in nodes
	MAX_BLOCK_DEPTH = 12,     -- free cells farther than this from any road
	                          --  trigger a secondary street
	MIN_SECONDARY_LEN = 12,
	SECONDARY_FAIL_SKIP = 0,  -- cells round a failed candidate also skipped
	MAX_SECONDARY = 8,
	MIN_BLOCK_SIDE = 8,
	MAX_BLOCK_SCAN = 64,
	MIN_FRONTAGE_RUN = 4,
	MAX_EDGE_FRACTION = 0.3,  -- secondary street: max share of a long side that
	                          --  may be outside the boundary or a landmark
	MIN_BLOCKS = 3,           -- fewer blocks with frontage reject the attempt
	PRINCIPAL_MATERIAL = "mcl_core:stonebrick",
	SECONDARY_MATERIAL = "mcl_core:cobble",
	SQUARE_MATERIAL = "mcl_core:stonebrick",
	-- Jail reservation (profile planning only, ticket #69)
	JAIL_MARKET_BIAS = 1,     -- 1: jail entrance farthest from the market
	                          --  centre, -1: nearest
	-- Service reservations (profile planning only, ticket #41)
	SERVICE_TAVERNS = 3,      -- target counts
	SERVICE_WELLS = 3,
	SERVICE_CHAPELS = 2,
	CHAPEL_MIN_FROM_CATHEDRAL = 40, -- entrance to cathedral entrance, nodes
	CHAPEL_MIN_BETWEEN = 70,        -- entrance to another chapel's entrance
}

-- Landmark profile (ticket #38)
-- ----------------------------
-- By default the planner uses the Phase 2 nominal landmark footprints above
-- (CATHEDRAL_*, CASTLE_*) and the 96-node envelope. opts.landmarks selects a
-- catalog-derived profile instead (see M.landmark_profile): the cathedral and
-- castle reservations are then the complete rotated schematic boxes, doors
-- sit at their real (possibly off-centre, recessed) offsets, and the envelope
-- grows to LANDMARK_ENVELOPE with the dimensions that depend on it. The 208
-- is an engineering trial value, not a product size: tune it here only.
M.LEGACY_ENVELOPE = 96
M.LANDMARK_ENVELOPE = 208

-- Block tuning for profile plans (tickets #86, #89): fewer, wider-spaced
-- streets and no sliver rows. Applied with the envelope-derived set when
-- opts.landmarks is given (explicit opts.constants still win); the legacy
-- 96-node constants are untouched. The validator only needs lower bounds, so
-- it accepts these plans with the defaults.
M.LANDMARK_TUNING = {
	MAX_BLOCK_DEPTH = 24,     -- farthest free cell from a road before a
	                          --  secondary street is added (default 12)
	SECONDARY_FAIL_SKIP = 5,  -- after a candidate cell yields no street, skip
	                          --  the (2k+1)-square round it (default 0: just
	                          --  the cell) so far, hopeless cells do not
	                          --  exhaust the bounded tries
	MIN_BLOCK_SIDE = 12,      -- no block thinner than this: a thinner strip
	                          --  between a road and the boundary (or a
	                          --  landmark) fits only the smallest house and
	                          --  is left open instead (default 8). The walls
	                          --  ticket (#95) may claim such a gap. Replaced
	                          --  by the catalog-derived row depth when the
	                          --  profile has ordinary content (depth_policy).
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

-- The constants the street spacing policy (ticket #86) derives from a
-- landmark profile's ordinary content; empty when it has none, which plans
-- without the policy. Applied by resolve_constants; explicit
-- opts.constants still win.
function M.depth_policy(profile)
	local depth = M.row_depth(profile)
	if not depth then return {} end
	return {
		ROW_DEPTH = depth,
		-- Intentionally the larger of the row depth and the #89 product
		-- value: a block is at least one row deep, and the thin strips the
		-- #89 tuning refused stay refused.
		MIN_BLOCK_SIDE = math.max(depth, M.LANDMARK_TUNING.MIN_BLOCK_SIDE),
		ROAD_GAP = 2 * depth,       -- road to road: two opposing rows
		SQUARE_GAP = depth,         -- square to road: one row
		LANDMARK_GAP = depth,       -- landmark to road: one row
		BOUNDARY_GAP = depth,       -- road to town edge: one row; the walls
		                            --  ticket (#95) claims this ground
		NARROW_PENALTY = 4,         -- router cost of a narrow street side
		SLIVER_WEIGHT = 4,          -- block carving: cost per sliver node
	}
end

-- Names the depth policy may set (valid in opts.constants).
local DEPTH_POLICY_KEYS = M.depth_policy({content = {x = {size = {z = 1}}}})

-- Dimensions that scale with the envelope. Reference values are the Phase 2
-- constants at LEGACY_ENVELOPE; explicit opts.constants still override them.
local function envelope_derived(envelope)
	local r = envelope / M.LEGACY_ENVELOPE
	return {
		ENVELOPE = envelope,
		MIN_LONG_SPAN = math.floor(80 * r),
		MIN_SHORT_SPAN = math.floor(60 * r),
		CENTER_JITTER = math.floor(8 * r),
		MAX_SECONDARY = math.ceil(8 * r),
		MAX_BLOCK_SCAN = math.ceil(64 * r),
	}
end

-- The constants plan() uses for `opts` (planner opts): defaults, then the
-- envelope-derived set when opts.landmarks is given, then opts.constants.
-- Pure; site_search uses it to size its own envelope-dependent distances.
function M.resolve_constants(opts)
	local C = {}
	for k, v in pairs(M.CONSTANTS) do C[k] = v end
	if type(opts) ~= "table" then return C end
	local explicit = opts.constants
	if opts.landmarks ~= nil then
		local env = (type(explicit) == "table" and explicit.ENVELOPE) or M.LANDMARK_ENVELOPE
		for k, v in pairs(envelope_derived(env)) do C[k] = v end
		for k, v in pairs(M.LANDMARK_TUNING) do C[k] = v end
		for k, v in pairs(M.depth_policy(opts.landmarks)) do C[k] = v end
	end
	if type(explicit) == "table" then
		for k, v in pairs(explicit) do C[k] = v end
	end
	return C
end

local SIDES = {"-z", "+z", "-x", "+x"}
local ORDER = {"cathedral", "parvis", "market", "castle"}
local FACING = {
	["-z"] = {x = 0, z = -1}, ["+z"] = {x = 0, z = 1},
	["-x"] = {x = -1, z = 0}, ["+x"] = {x = 1, z = 0},
}
local ROTATION = {["-z"] = 0, ["-x"] = 90, ["+z"] = 180, ["+x"] = 270}
local OPPOSITE = {["-z"] = "+z", ["+z"] = "-z", ["-x"] = "+x", ["+x"] = "-x"}

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

-- Rotated box of landmark L when its entrance faces `side`: world X/Z extent,
-- door offset from the box's minimum corner, and how many nodes the door lies
-- behind the box edge on the entrance side (the recess).
local function landmark_box(L, side)
	local g = geometry.place(L, {x = 0, y = 0, z = 0}, ROTATION[side])
	local ex, ez = g.entrance.x, g.entrance.z
	local recess
	if side == "-z" then recess = ez
	elseif side == "+z" then recess = g.size.z - 1 - ez
	elseif side == "-x" then recess = ex
	else recess = g.size.x - 1 - ex end
	return {w = g.size.x, d = g.size.z, ex = ex, ez = ez, recess = recess}
end

-- Minimum market side for the city hall (#106): the hall stands beside the
-- open market with its facade along one market edge, so the market must be at
-- least as long as that facade (the catalog size.x, whatever the rotation).
-- It is not enlarged by any ring round the hall. nil without a city hall.
local function hall_facade(profile)
	local h = profile and profile.city_hall
	return h and h.size.x or nil
end

-- Cheap static check that the cathedral (with its parvis) and the castle
-- boxes fit the envelope at all, so an unsupported profile fails at once
-- instead of exhausting the retry budget.
local function fit_check(C, profile)
	local n = C.ENVELOPE
	local best
	for _, side in ipairs(SIDES) do
		local b = landmark_box(profile.cathedral, side)
		local horiz = side == "-z" or side == "+z"
		local ax = horiz and math.max(b.w, C.PARVIS_WIDTH) or (b.w + C.PARVIS_FRONT_DEPTH)
		local az = horiz and (b.d + C.PARVIS_FRONT_DEPTH) or math.max(b.d, C.PARVIS_WIDTH)
		if ax <= n and az <= n then best = true end
	end
	if not best then
		return nil, "the cathedral box with its parvis does not fit a "
			.. n .. "-node envelope"
	end
	local k = profile.castle
	local fits = (k.size.x <= n and k.size.z <= n)
	if not fits then
		return nil, "the castle box does not fit a " .. n .. "-node envelope"
	end
	local facade = hall_facade(profile)
	if facade then
		-- Market (at least the hall's facade long) plus the hall's depth
		-- beyond one edge, within the half span the market centre allows.
		local need = math.max(C.MARKET_MIN, facade) + profile.city_hall.size.z
		if need > math.floor(C.MIN_SHORT_SPAN / 2) then
			return nil, "the city hall box beside a " .. math.max(C.MARKET_MIN, facade)
				.. "-node market needs " .. need
				.. " nodes, too large for a " .. n .. "-node envelope"
		end
	end
	return true
end

------------------------------------------------------------------------
-- Rectangle helpers (inclusive {x1, z1, x2, z2})
------------------------------------------------------------------------
local function rect(x1, z1, x2, z2) return {x1 = x1, z1 = z1, x2 = x2, z2 = z2} end

local function area(r) return (r.x2 - r.x1 + 1) * (r.z2 - r.z1 + 1) end

-- Chebyshev gap in free nodes between two rects; < 0 when they overlap.
local function gap(a, b)
	local gx = math.max(a.x1 - b.x2 - 1, b.x1 - a.x2 - 1)
	local gz = math.max(a.z1 - b.z2 - 1, b.z1 - a.z2 - 1)
	return math.max(gx, gz)
end

local function same_rect(a, b)
	return a.x1 == b.x1 and a.z1 == b.z1 and a.x2 == b.x2 and a.z2 == b.z2
end

local function inflate(r, n)
	return rect(r.x1 - n, r.z1 - n, r.x2 + n, r.z2 + n)
end

local function intersects(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

local function shift_rect(r, ox, oz)
	return rect(r.x1 + ox, r.z1 + oz, r.x2 + ox, r.z2 + oz)
end

-- The 1-node-thick row of nodes at distance d outside side `side` of r.
local function outer_row(r, side, d)
	if side == "-z" then return rect(r.x1, r.z1 - d, r.x2, r.z1 - d) end
	if side == "+z" then return rect(r.x1, r.z2 + d, r.x2, r.z2 + d) end
	if side == "-x" then return rect(r.x1 - d, r.z1, r.x1 - d, r.z2) end
	return rect(r.x2 + d, r.z1, r.x2 + d, r.z2)
end

local function mid(a, b) return a + math.floor((b - a) / 2) end

------------------------------------------------------------------------
-- Occupancy grid with prefix sums, local coordinates 0 .. n-1
------------------------------------------------------------------------
local function new_grid(n, rects)
	local cells = {}
	for z = 0, n - 1 do
		local row = {}
		for x = 0, n - 1 do row[x] = 0 end
		cells[z] = row
	end
	for _, r in ipairs(rects) do
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do cells[z][x] = 1 end
		end
	end
	return cells
end

-- count(cells, n) -> function(x1, z1, x2, z2) = filled cells (clipped)
local function prefix(cells, n)
	local P = {}
	for z = 0, n do
		local row = {}
		for x = 0, n do row[x] = 0 end
		P[z] = row
	end
	for z = 1, n do
		local acc = 0
		for x = 1, n do
			acc = acc + cells[z - 1][x - 1]
			P[z][x] = P[z - 1][x] + acc
		end
	end
	local function clip(v) if v < 0 then return 0 elseif v > n then return n end return v end
	return function(x1, z1, x2, z2)
		if x1 > x2 or z1 > z2 then return 0 end
		local a, b = clip(x1), clip(z1)
		local c, d = clip(x2 + 1), clip(z2 + 1)
		if c <= a or d <= b then return 0 end
		return P[d][c] - P[b][c] - P[d][a] + P[b][a]
	end
end

-- True when every cell of r (which may poke outside the grid) is filled.
local function all_filled(count, r)
	return count(r.x1, r.z1, r.x2, r.z2) == area(r)
end

local function none_filled(count, r)
	return count(r.x1, r.z1, r.x2, r.z2) == 0
end

------------------------------------------------------------------------
-- Boundary generation and shape validation
------------------------------------------------------------------------
-- Edges lie on lattice lines spaced MIN_FEATURE apart plus a nondecreasing
-- seeded jitter, so two distinct edge coordinates always differ by at least
-- MIN_FEATURE: steps, notches and arms cannot be smaller than that. The last
-- line sits exactly at `span`.
local function lattice(rng, C, span)
	local f = C.MIN_FEATURE
	local max_n = math.floor(span / f)
	local intervals = rng.int(math.max(3, max_n - 1), max_n)
	local total = span - f * intervals
	local j = {}
	for i = 1, intervals - 1 do j[#j + 1] = rng.int(0, total) end
	table.sort(j)
	table.insert(j, 1, 0)
	j[intervals + 1] = total
	-- j is 1-based here: line i uses j[i + 1].
	local lines = {}
	for i = 0, intervals do lines[i] = i * f + j[i + 1] end
	return lines, intervals
end

local function gen_boundary(rng, C)
	local n = C.ENVELOPE
	-- u is the long axis (envelope-filling spine), v the shorter one; the
	-- pair is transposed onto X/Z half the time so both orientations occur.
	local long = rng.int(C.MIN_LONG_SPAN, n)
	local short = rng.int(C.MIN_SHORT_SPAN, math.max(C.MIN_SHORT_SPAN, long - C.MIN_ASPECT_DELTA))
	local us, nu = lattice(rng, C, long)
	local vs, nv = lattice(rng, C, short)
	local transpose = rng.int(0, 1) == 1
	local xs, zs = us, vs
	if transpose then xs, zs = vs, us end
	local nx, nz = nu, nv
	if transpose then nx, nz = nv, nu end
	-- Offset the box so the town centre stays near the middle of the boundary.
	local function offset(span)
		local mid0 = math.floor((n - span) / 2)
		local lo = math.max(0, mid0 - C.CENTER_JITTER)
		local hi = math.min(n - span, mid0 + C.CENTER_JITTER)
		return rng.int(lo, hi)
	end
	local ox = offset(xs[nx])
	local oz = offset(zs[nz])
	local rects = {}
	local function add(u1, v1, u2, v2)
		if transpose then u1, v1, u2, v2 = v1, u1, v2, u2 end
		rects[#rects + 1] = rect(ox + xs[u1], oz + zs[v1],
			ox + xs[u2] - 1, oz + zs[v2] - 1)
	end
	-- Spine: spans the whole u extent over a band of v.
	local v1 = rng.int(0, nv - 2)
	local v2 = rng.int(v1 + 2, nv)
	add(0, v1, nu, v2)
	-- Wings reach the v extremes so the bounding box is fully used.
	if v1 > 0 then
		local u1 = rng.int(0, nu - 2)
		local u2 = rng.int(u1 + 2, nu)
		add(u1, 0, u2, rng.int(v1 + 1, v2))
	end
	if v2 < nv then
		local u1 = rng.int(0, nu - 2)
		local u2 = rng.int(u1 + 2, nu)
		add(u1, rng.int(v1, v2 - 1), u2, nv)
	end
	-- Optional extras: further broad rectangles overlapping the spine.
	local target = rng.int(C.RECT_COUNT_MIN, C.RECT_COUNT_MAX)
	for _ = 1, 3 * C.RECT_COUNT_MAX do
		if #rects >= target then break end
		local u1 = rng.int(0, nu - 2)
		local u2 = rng.int(u1 + 2, nu)
		local a1 = rng.int(0, nv - 2)
		local a2 = rng.int(a1 + 2, nv)
		if a1 < v2 and a2 > v1 then add(u1, a1, u2, a2) end
	end
	return rects
end

-- Edge profile check: constant runs >= feat long, consecutive values
-- differing by >= feat.
local function profile_ok(vals, first, last, feat)
	local runv, runlen, prev = nil, 0, nil
	for i = first, last do
		local v = vals[i]
		if v == runv then
			runlen = runlen + 1
		else
			if runv ~= nil then
				if runlen < feat then return false end
				if math.abs(v - runv) < feat then return false end
			end
			runv, runlen = v, 1
		end
		prev = v
	end
	return prev == nil or runlen >= feat
end

-- Returns bbox (rect) or nil, reason.
local function check_boundary(cells, C)
	local n = C.ENVELOPE
	local feat = C.MIN_FEATURE
	local x1, z1, x2, z2 = n, n, -1, -1
	local filled = 0
	for z = 0, n - 1 do
		for x = 0, n - 1 do
			if cells[z][x] == 1 then
				filled = filled + 1
				if x < x1 then x1 = x end
				if x > x2 then x2 = x end
				if z < z1 then z1 = z end
				if z > z2 then z2 = z end
			end
		end
	end
	if filled == 0 then return nil, "empty boundary" end
	local bbox = rect(x1, z1, x2, z2)
	local w, d = x2 - x1 + 1, z2 - z1 + 1
	if math.max(w, d) < C.MIN_LONG_SPAN or math.min(w, d) < C.MIN_SHORT_SPAN then
		return nil, "boundary too small"
	end
	if math.abs(w - d) < C.MIN_ASPECT_DELTA then
		return nil, "boundary square-ish"
	end
	local fill = filled / (w * d)
	if fill > C.MAX_FILL then return nil, "boundary too rectangular" end
	if fill < C.MIN_FILL then return nil, "boundary too sparse" end

	-- Connectivity (4-neighbour flood fill).
	local seen, reached = {}, 0
	local stack = {}
	for z = z1, z2 do
		for x = x1, x2 do
			if cells[z][x] == 1 and #stack == 0 and reached == 0 then
				stack[1] = {x, z}
				seen[z * n + x] = true
			end
		end
	end
	while #stack > 0 do
		local c = table.remove(stack)
		reached = reached + 1
		local dirs = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
		for k = 1, 4 do
			local nx, nz = c[1] + dirs[k][1], c[2] + dirs[k][2]
			if nx >= 0 and nx < n and nz >= 0 and nz < n
					and cells[nz][nx] == 1 and not seen[nz * n + nx] then
				seen[nz * n + nx] = true
				stack[#stack + 1] = {nx, nz}
			end
		end
	end
	if reached ~= filled then return nil, "boundary disconnected" end

	-- Row/column profiles: extents, internal gaps.
	local L, R, T, B = {}, {}, {}, {}
	for z = z1, z2 do
		local last, first = nil, nil
		for x = x1, x2 do
			if cells[z][x] == 1 then
				if last and x - last - 1 > 0 and x - last - 1 < feat then
					return nil, "boundary notch narrower than feature size"
				end
				first = first or x
				last = x
			end
		end
		L[z], R[z] = first, last
	end
	for x = x1, x2 do
		local last, first = nil, nil
		for z = z1, z2 do
			if cells[z][x] == 1 then
				if last and z - last - 1 > 0 and z - last - 1 < feat then
					return nil, "boundary notch narrower than feature size"
				end
				first = first or z
				last = z
			end
		end
		T[x], B[x] = first, last
	end
	if not (profile_ok(L, z1, z2, feat) and profile_ok(R, z1, z2, feat)
			and profile_ok(T, x1, x2, feat) and profile_ok(B, x1, x2, feat)) then
		return nil, "boundary step or edge shorter than feature size"
	end

	-- Opening by a feat x feat square: no arm narrower than feat.
	local count = prefix(cells, n)
	local diff = {}
	for z = 0, n + 1 do
		diff[z] = {}
		for x = 0, n + 1 do diff[z][x] = 0 end
	end
	for z = z1, z2 - feat + 1 do
		for x = x1, x2 - feat + 1 do
			if count(x, z, x + feat - 1, z + feat - 1) == feat * feat then
				diff[z][x] = diff[z][x] + 1
				diff[z][x + feat] = diff[z][x + feat] - 1
				diff[z + feat][x] = diff[z + feat][x] - 1
				diff[z + feat][x + feat] = diff[z + feat][x + feat] + 1
			end
		end
	end
	local cov = {}
	for z = 0, n - 1 do
		cov[z] = {}
		for x = 0, n - 1 do
			local v = diff[z][x]
			if x > 0 then v = v + cov[z][x - 1] end
			if z > 0 then v = v + cov[z - 1][x] end
			if x > 0 and z > 0 then v = v - cov[z - 1][x - 1] end
			cov[z][x] = v
			if cells[z][x] == 1 and v <= 0 then
				return nil, "boundary arm narrower than feature size"
			end
		end
	end
	return bbox
end

------------------------------------------------------------------------
-- Site placement
------------------------------------------------------------------------
-- Slide a w x d rect inward from outside bbox side `side` at coordinate
-- `along` until it is wholly inside the boundary. Returns rect or nil.
local function slide_in(count, bbox, side, w, d, along, n)
	local r
	if side == "-z" then
		r = rect(along, bbox.z1 - d, along + w - 1, bbox.z1 - 1)
	elseif side == "+z" then
		r = rect(along, bbox.z2 + 1, along + w - 1, bbox.z2 + d)
	elseif side == "-x" then
		r = rect(bbox.x1 - w, along, bbox.x1 - 1, along + d - 1)
	else
		r = rect(bbox.x2 + 1, along, bbox.x2 + w, along + d - 1)
	end
	local step = FACING[OPPOSITE[side]]
	for _ = 1, n do
		if all_filled(count, r) then return r end
		r = shift_rect(r, step.x, step.z)
	end
	return nil
end

-- Number of boundary nodes between r and the outer edge beyond `side`, or
-- nil when the boundary there is not a straight edge parallel to the side.
local function edge_gap(count, r, side, limit)
	for g = 0, limit do
		local row = outer_row(r, side, g + 1)
		if none_filled(count, row) then return g end
		if not all_filled(count, row) then return nil end
	end
	return nil
end

-- `L` (landmarks only, optional) is the catalog profile entry: the door is
-- then at its real offset inside the box (rect), the approach node is the
-- edge node in line with it, and `door` records the recess behind the box
-- edge, the rise above site ground and the cell just outside the door.
local function shape_site(name, kind, r, side, L)
	local s = {
		name = name, kind = kind, rect = r, side = side,
		size = {x = r.x2 - r.x1 + 1, z = r.z2 - r.z1 + 1},
		facing = {x = FACING[side].x, z = FACING[side].z},
		rotation = ROTATION[side],
	}
	local e = outer_row(r, side, 1)
	local pos
	if side == "-z" or side == "+z" then
		pos = {x = mid(r.x1, r.x2), z = e.z1}
	else
		pos = {x = e.x1, z = mid(r.z1, r.z2)}
	end
	s.approach = {side = side, edge = e, pos = pos}
	if kind == "landmark" and L then
		local b = landmark_box(L, side)
		local ent = {x = r.x1 + b.ex, z = r.z1 + b.ez}
		if side == "-z" or side == "+z" then pos.x = ent.x else pos.z = ent.z end
		s.entrance = ent
		s.id = L.id
		s.door = {
			recess = b.recess,
			rise = L.entrance.y - L.ground_offset,
			outside = {x = ent.x + s.facing.x, z = ent.z + s.facing.z},
		}
		if name == "castle" and L.gate_span then
			local rotated = geometry.rotate_rect(L.size, L.gate_span, s.rotation)
			s.gate_span = {x1 = r.x1 + rotated.x1, z1 = r.z1 + rotated.z1,
				x2 = r.x1 + rotated.x2, z2 = r.z1 + rotated.z2}
			s.gate_apron = geometry.exterior_apron(r, s.gate_span, s.facing, 5)
		end
	elseif kind == "landmark" then
		local p = {x = pos.x, z = pos.z}
		if side == "-z" then p.z = r.z1 elseif side == "+z" then p.z = r.z2
		elseif side == "-x" then p.x = r.x1 else p.x = r.x2 end
		s.entrance = p
	end
	return s
end

-- `min_side` (optional) enlarges the square to at least the city hall's
-- facade length, so the hall can stand along one of its edges (#106).
local function sample_market(rng, C, count, n, min_side)
	for _ = 1, C.MARKET_TRIES do
		local w = rng.int(C.MARKET_MIN, C.MARKET_MAX)
		local d = rng.int(C.MARKET_MIN, C.MARKET_MAX)
		if min_side then w, d = math.max(w, min_side), math.max(d, min_side) end
		local cx = math.floor(n / 2) + rng.int(-C.MARKET_CENTER_RADIUS, C.MARKET_CENTER_RADIUS)
		local cz = math.floor(n / 2) + rng.int(-C.MARKET_CENTER_RADIUS, C.MARKET_CENTER_RADIUS)
		local x1 = math.floor(cx - w / 2)
		local z1 = math.floor(cz - d / 2)
		local r = rect(x1, z1, x1 + w - 1, z1 + d - 1)
		if all_filled(count, r) then return r end
	end
end

-- City hall beside the market (profile only, #106). The hall is outside the
-- open market rectangle, touching one of its four edges, with its entrance
-- side facing across that edge: the node in front of the real (possibly
-- off-centre, recessed) door is then a market pavement node on the edge row.
-- Its whole facade lies within the market edge, so the corners and the other
-- three sides stay free for streets and building frontage. Candidates need
-- the complete box inside the boundary. Along an edge the stable order is
-- centred first, then flush to either end; the seeded rng breaks ties
-- between the first tier that has any candidate. Returns rect, side (the
-- entrance side, facing the market) or nil.
local function sample_city_hall(rng, C, count, market, L)
	local tiers = {{}, {}}
	for _, mside in ipairs(SIDES) do
		-- The hall lies beyond market edge `mside`, facing back across it.
		local side = OPPOSITE[mside]
		local b = landmark_box(L, side)
		local horiz = (side == "-z" or side == "+z")
		local lat = horiz and b.w or b.d
		local lo = horiz and market.x1 or market.z1
		local hi = (horiz and market.x2 or market.z2) - lat + 1
		if lo <= hi then
			for t, along in ipairs({lo + math.floor((hi - lo) / 2), lo, hi}) do
				local r
				if mside == "+z" then r = rect(along, market.z2 + 1, along + b.w - 1, market.z2 + b.d)
				elseif mside == "-z" then r = rect(along, market.z1 - b.d, along + b.w - 1, market.z1 - 1)
				elseif mside == "+x" then r = rect(market.x2 + 1, along, market.x2 + b.w, along + b.d - 1)
				else r = rect(market.x1 - b.w, along, market.x1 - 1, along + b.d - 1) end
				local tier = tiers[t == 1 and 1 or 2]
				local dup = false
				for _, c in ipairs(tier) do
					if c.side == side and same_rect(c.r, r) then dup = true end
				end
				if not dup and all_filled(count, r) then
					tier[#tier + 1] = {r = r, side = side}
				end
			end
		end
	end
	for _, tier in ipairs(tiers) do
		if #tier > 0 then
			local pick = tier[rng.int(1, #tier)]
			return pick.r, pick.side
		end
	end
end

-- Candidate lists are enumerated in a fixed order and one is picked with the
-- seeded rng, so a feasible layout is found whenever one exists.
local function sample_cathedral(rng, C, count, bbox, market, profile, hall)
	local sw = C.STREET_WIDTH
	local m, p = C.PARVIS_MARGIN, C.PARVIS_DEPTH
	local found, roomy = {}, {}
	for k = 1, 4 do
		local side = SIDES[k]
		local long_x = (side == "-x" or side == "+x")
		local w = long_x and C.CATHEDRAL_LONG or C.CATHEDRAL_SHORT
		local d = long_x and C.CATHEDRAL_SHORT or C.CATHEDRAL_LONG
		local b
		if profile then
			b = landmark_box(profile.cathedral, side)
			w, d = b.w, b.d
		end
		local hw, pd = math.floor(C.PARVIS_WIDTH / 2), C.PARVIS_FRONT_DEPTH
		for z1 = bbox.z1, bbox.z2 - d + 1, 2 do
			for x1 = bbox.x1, bbox.x2 - w + 1, 2 do
				local c = rect(x1, z1, x1 + w - 1, z1 + d - 1)
				local pr
				if b then
					-- Centred on the real door, not the compound (#105).
					local lat = (side == "-z" or side == "+z") and (x1 + b.ex) or (z1 + b.ez)
					local a1 = lat - hw
					local a2 = a1 + C.PARVIS_WIDTH - 1
					if side == "-z" then pr = rect(a1, c.z1 - pd, a2, c.z1 - 1)
					elseif side == "+z" then pr = rect(a1, c.z2 + 1, a2, c.z2 + pd)
					elseif side == "-x" then pr = rect(c.x1 - pd, a1, c.x1 - 1, a2)
					else pr = rect(c.x2 + 1, a1, c.x2 + pd, a2) end
				elseif side == "-z" then pr = rect(c.x1 - m, c.z1 - p, c.x2 + m, c.z1 - 1)
				elseif side == "+z" then pr = rect(c.x1 - m, c.z2 + 1, c.x2 + m, c.z2 + p)
				elseif side == "-x" then pr = rect(c.x1 - p, c.z1 - m, c.x1 - 1, c.z2 + m)
				else pr = rect(c.x2 + 1, c.z1 - m, c.x2 + p, c.z2 + m) end
				if gap(c, market) >= sw and gap(pr, market) >= sw
						and (not hall or (gap(c, hall) >= sw and gap(pr, hall) >= sw))
						and all_filled(count, c) and all_filled(count, pr) then
					found[#found + 1] = {c, pr, side}
					-- Preferred: a street's width of boundary all round.
					if all_filled(count, inflate(c, sw))
							and all_filled(count, inflate(pr, sw)) then
						roomy[#roomy + 1] = found[#found]
					end
				end
			end
		end
	end
	if #roomy > 0 then found = roomy end
	if #found == 0 then return nil end
	local pick = found[rng.int(1, #found)]
	return pick[1], pick[2], pick[3]
end

-- True when some street-wide window containing the node in front of the
-- middle of `r`'s `side` edge lies inside the boundary, clear of `blocker`.
local function door_clear(count, C, r, side, blocker)
	local sw = C.STREET_WIDTH
	local e = outer_row(r, side, 1)
	local px, pz = mid(e.x1, e.x2), mid(e.z1, e.z2)
	local f = FACING[side]
	for s = 0, sw - 1 do
		local w
		if side == "-z" or side == "+z" then
			local x1 = px - s
			local z1 = f.z < 0 and pz - sw + 1 or pz
			w = rect(x1, z1, x1 + sw - 1, z1 + sw - 1)
		else
			local z1 = pz - s
			local x1 = f.x < 0 and px - sw + 1 or px
			w = rect(x1, z1, x1 + sw - 1, z1 + sw - 1)
		end
		if all_filled(count, w) and not (blocker and intersects(w, blocker)) then
			return true
		end
	end
	return false
end

local function sample_castle(rng, C, count, bbox, n, others, profile)
	local sw = C.STREET_WIDTH
	local found = {}
	for k = 1, 4 do
		local side = SIDES[k]
		local horizontal = (side == "-z" or side == "+z")
		-- With a profile the gate faces the side opposite the outer edge and
		-- that rotation fixes the box, so only one orientation exists.
		for o = 0, profile and 0 or 1 do
			local w, d = C.CASTLE_X, C.CASTLE_Z
			if o == 1 then w, d = d, w end
			if profile then
				local b = landmark_box(profile.castle, OPPOSITE[side])
				w, d = b.w, b.d
			end
			local lo = horizontal and bbox.x1 or bbox.z1
			local hi = (horizontal and bbox.x2 - w + 1 or bbox.z2 - d + 1)
			for along = lo, hi do
				local r0 = slide_in(count, bbox, side, w, d, along, n)
				for extra = 0, C.CASTLE_EDGE_SLACK do
					local r = r0
					if r then
						local step = FACING[OPPOSITE[side]]
						r = shift_rect(r, step.x * extra, step.z * extra)
					end
					local g = r and all_filled(count, r)
						and edge_gap(count, r, side, C.CASTLE_EDGE_SLACK)
					if g then
						local ok = true
						for j = 1, #others do
							ok = ok and gap(r, others[j]) >= sw
						end
						if ok then
							-- Touching edges are weighted over slack ones.
							for _ = 1, (extra == 0) and 3 or 1 do
								found[#found + 1] = {r, side, g}
							end
						end
					end
				end
			end
		end
	end
	if #found == 0 then return nil end
	local pick = found[rng.int(1, #found)]
	return pick[1], pick[2], pick[3]
end

local function sample_approach(rng, C, count, bbox, n, side, obstacles, avoid)
	local sw = C.STREET_WIDTH
	local horizontal = (side == "-z" or side == "+z")
	local lo = horizontal and bbox.x1 or bbox.z1
	local hi = (horizontal and bbox.x2 or bbox.z2) - sw + 1
	local found = {}
	for along = lo, hi do
		local r = slide_in(count, bbox, side, sw, sw, along, n)
		if r and edge_gap(count, r, side, 0) == 0 then
			local clear = true
			for j = 1, #obstacles do
				clear = clear and not intersects(r, obstacles[j])
			end
			if avoid and intersects(r, avoid) then clear = false end
			if clear then found[#found + 1] = r end
		end
	end
	if #found == 0 then return nil end
	return found[rng.int(1, #found)]
end

-- BFS over top-left corners of free sw x sw windows from `start` (a window
-- rect). Returns the visited set keyed z * n + x.
local function reachable_windows(free_count, start, sw, n)
	local function free(x, z)
		return x >= 0 and z >= 0 and x + sw <= n and z + sw <= n
			and free_count(x, z, x + sw - 1, z + sw - 1) == sw * sw
	end
	local seen = {}
	if not free(start.x1, start.z1) then return seen end
	local queue, head = {{start.x1, start.z1}}, 1
	seen[start.z1 * n + start.x1] = true
	local dirs = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	while head <= #queue do
		local c = queue[head]
		head = head + 1
		for k = 1, 4 do
			local nx, nz = c[1] + dirs[k][1], c[2] + dirs[k][2]
			local key = nz * n + nx
			if not seen[key] and free(nx, nz) then
				seen[key] = true
				queue[#queue + 1] = {nx, nz}
			end
		end
	end
	return seen
end

-- Is some reachable free window covering node (px, pz)?
local function covers(seen, px, pz, sw, n)
	for z = pz - sw + 1, pz do
		for x = px - sw + 1, px do
			if x >= 0 and z >= 0 and seen[z * n + x] then return true end
		end
	end
	return false
end

-- The sw x sw window of an approach edge, extending inward.
local function approach_window(edge, side, sw)
	if side == "-z" then return rect(edge.x1, edge.z1, edge.x2, edge.z1 + sw - 1) end
	if side == "+z" then return rect(edge.x1, edge.z2 - sw + 1, edge.x2, edge.z2) end
	if side == "-x" then return rect(edge.x1, edge.z1, edge.x1 + sw - 1, edge.z2) end
	return rect(edge.x2 - sw + 1, edge.z1, edge.x2, edge.z2)
end

local function valid_side(s) return FACING[s] ~= nil end

local function validate_impl(plan, C)
	local sw, n = C.STREET_WIDTH, C.ENVELOPE
	local env = plan.envelope
	if not M.check_seed(plan.seed) then
		return nil, "seed is not an integer within the allowed range"
	end
	local cen = plan.center
	if not (is_int(cen.x) and is_int(cen.z)) then
		return nil, "centre is not an integer pair"
	end
	do
		local half = math.floor(n / 2)
		if not same_rect(env, rect(cen.x - half, cen.z - half,
				cen.x + half - 1, cen.z + half - 1)) then
			return nil, "envelope is not the town centre -" .. half .. " .. +" .. (half - 1)
		end
	end
	for i = 1, #ORDER do
		if plan.site_order[i] ~= ORDER[i] then
			return nil, "site_order is not " .. table.concat(ORDER, ",")
		end
	end
	if #plan.site_order ~= #ORDER then
		return nil, "site_order is not " .. table.concat(ORDER, ",")
	end
	local ox, oz = env.x1, env.z1
	local function L(r) return shift_rect(r, -ox, -oz) end
	local function inside_env(r)
		return r.x1 <= r.x2 and r.z1 <= r.z2 and r.x1 >= 0 and r.z1 >= 0
			and r.x2 < n and r.z2 < n
	end

	-- Boundary.
	local rects = {}
	if #plan.boundary.rects == 0 then return nil, "boundary has no rectangles" end
	for i, r in ipairs(plan.boundary.rects) do
		rects[i] = L(r)
		if not inside_env(rects[i]) then
			return nil, "boundary rectangle outside envelope"
		end
	end
	local cells = new_grid(n, rects)
	local bbox, why = check_boundary(cells, C)
	if not bbox then return nil, why end
	if not same_rect(L(plan.bounds), bbox) then
		return nil, "bounds are not the exact bounding box of the boundary"
	end
	if plan.width ~= bbox.x2 - bbox.x1 + 1 or plan.depth ~= bbox.z2 - bbox.z1 + 1 then
		return nil, "width/depth do not match bounds"
	end
	local count = prefix(cells, n)
	local ctr = {x = plan.center.x - ox, z = plan.center.z - oz}
	if count(ctr.x, ctr.z, ctr.x, ctr.z) ~= 1 then
		return nil, "town centre outside boundary"
	end

	-- Sites.
	local sites = {}
	-- The city hall (ticket #39) is an extra site outside site_order, present
	-- only in profile plans; it is validated as a landmark, then against the
	-- market it stands on.
	local names = {}
	for i, name in ipairs(ORDER) do names[i] = name end
	if plan.sites.city_hall ~= nil then names[#names + 1] = "city_hall" end
	for _, name in ipairs(names) do
		local s = plan.sites[name]
		if type(s) ~= "table" or s.name ~= name then
			return nil, "missing site " .. name
		end
		if not valid_side(s.side) then return nil, name .. " has invalid side" end
		local r = L(s.rect)
		if not inside_env(r) or not all_filled(count, r) then
			return nil, name .. " not contained in boundary"
		end
		local e = outer_row(r, s.side, 1)
		if not same_rect(L(s.approach.edge), e) or s.approach.side ~= s.side then
			return nil, name .. " approach edge is not the row outside its " .. s.side .. " side"
		end
		local pos = s.approach.pos
		local px, pz = pos.x - ox, pos.z - oz
		local kind = (name == "cathedral" or name == "castle" or name == "city_hall")
			and "landmark" or "square"
		if kind == "landmark" and s.door ~= nil then
			-- Profile landmark: the approach node is the edge node in line with
			-- the real (off-centre, recessed) door, not the middle of the edge.
			local inline
			if s.side == "-z" or s.side == "+z" then
				inline = px >= e.x1 and px <= e.x2 and pz == e.z1
			else
				inline = pz >= e.z1 and pz <= e.z2 and px == e.x1
			end
			if not inline then
				return nil, name .. " approach pos is not on its edge"
			end
		elseif px ~= mid(e.x1, e.x2) or pz ~= mid(e.z1, e.z2) then
			return nil, name .. " approach pos is not the middle node of its edge"
		end
		if s.kind ~= kind then return nil, name .. " has wrong kind" end
		if s.door ~= nil and kind ~= "landmark" then
			return nil, name .. " is a square but has a door"
		end
		if s.size.x ~= r.x2 - r.x1 + 1 or s.size.z ~= r.z2 - r.z1 + 1 then
			return nil, name .. " size does not match its rect"
		end
		if s.facing.x ~= FACING[s.side].x or s.facing.z ~= FACING[s.side].z then
			return nil, name .. " facing does not match its side"
		end
		if s.rotation ~= ROTATION[s.side] then
			return nil, name .. " rotation does not match its side"
		end
		if kind == "landmark" then
			-- Door node: on the footprint edge of the entrance side, in line
			-- with approach.pos.
			local ex, ez = px, pz
			local back = 0
			local d = s.door
			if d ~= nil then
				if type(d) ~= "table" or not is_int(d.recess) or d.recess < 0
						or not is_int(d.rise) or type(d.outside) ~= "table" then
					return nil, name .. " door is malformed"
				end
				back = d.recess
			end
			if s.side == "-z" then ez = r.z1 + back elseif s.side == "+z" then ez = r.z2 - back
			elseif s.side == "-x" then ex = r.x1 + back else ex = r.x2 - back end
			if type(s.entrance) ~= "table" or s.entrance.x - ox ~= ex
					or s.entrance.z - oz ~= ez then
				return nil, name .. " entrance is not the door node on its entrance edge"
			end
			if d ~= nil then
				local f = FACING[s.side]
				if not inside_env(rect(ex, ez, ex, ez)) or not all_filled(count, rect(ex, ez, ex, ez))
						or d.outside.x - ox ~= ex + f.x or d.outside.z - oz ~= ez + f.z then
					return nil, name .. " door outside cell does not follow its entrance"
				end
			end
		elseif s.entrance ~= nil then
			return nil, name .. " is a square but has an entrance"
		end
		if name == "cathedral" and s.parvis ~= "parvis" then
			return nil, "cathedral does not reference the parvis"
		end
		if name == "city_hall" and s.door == nil then
			return nil, "city_hall has no door record"
		end
		sites[name] = {s = s, r = r, pos = {x = px, z = pz}}
	end
	for i = 1, #ORDER do
		for j = i + 1, #ORDER do
			local a, b = ORDER[i], ORDER[j]
			local g = gap(sites[a].r, sites[b].r)
			if a == "cathedral" and b == "parvis" then
				if g ~= 0 then return nil, "parvis does not touch the cathedral" end
			elseif g < 0 then
				return nil, a .. " and " .. b .. " overlap"
			elseif g < sw then
				return nil, a .. " and " .. b .. " are closer than a street width"
			end
		end
	end

	-- City hall (#106): outside the open market, touching one market edge,
	-- its facade within that edge and its entrance side facing across it, so
	-- the node in front of the door is a market pavement node. It keeps a
	-- street width clear of the other landmarks and the parvis.
	if sites.city_hall then
		local h, mk = sites.city_hall, sites.market.r
		if h.s.square ~= "market" then return nil, "city_hall does not name the market" end
		local side, r = h.s.side, h.r
		local touch, within
		if side == "-z" then
			touch = r.z1 == mk.z2 + 1
			within = r.x1 >= mk.x1 and r.x2 <= mk.x2
		elseif side == "+z" then
			touch = r.z2 == mk.z1 - 1
			within = r.x1 >= mk.x1 and r.x2 <= mk.x2
		elseif side == "-x" then
			touch = r.x1 == mk.x2 + 1
			within = r.z1 >= mk.z1 and r.z2 <= mk.z2
		else
			touch = r.x2 == mk.x1 - 1
			within = r.z1 >= mk.z1 and r.z2 <= mk.z2
		end
		if intersects(r, mk) then return nil, "city_hall overlaps the open market" end
		if not touch or not within then
			return nil, "city_hall is not beside the market with its entrance side facing it"
		end
		if not (h.pos.x >= mk.x1 and h.pos.x <= mk.x2 and h.pos.z >= mk.z1
				and h.pos.z <= mk.z2) then
			return nil, "city_hall door approach is not on the market"
		end
		for _, name in ipairs({"cathedral", "parvis", "castle"}) do
			local g = gap(r, sites[name].r)
			if g < 0 then return nil, "city_hall and " .. name .. " overlap" end
			if g < sw then return nil, "city_hall and " .. name .. " are closer than a street width" end
		end
	end

	-- Cathedral and parvis.
	local cath, parv = sites.cathedral, sites.parvis
	if parv.s.side ~= cath.s.side then return nil, "parvis not on the cathedral entrance side" end
	do
		local side, c, p = cath.s.side, cath.r, parv.r
		local touch
		if side == "-z" then touch = p.z2 == c.z1 - 1
		elseif side == "+z" then touch = p.z1 == c.z2 + 1
		elseif side == "-x" then touch = p.x2 == c.x1 - 1
		else touch = p.x1 == c.x2 + 1 end
		if not touch then return nil, "parvis not adjacent on the entrance side" end
		if cath.s.door ~= nil then
			-- Profile plan (#105): fixed size, centred on the real door.
			local e = cath.s.entrance
			local horiz = side == "-z" or side == "+z"
			local lo, hi = p.x1, p.x2
			local dlo, dhi = p.z1, p.z2
			local lat = e.x - ox
			if not horiz then lo, hi, dlo, dhi = p.z1, p.z2, p.x1, p.x2; lat = e.z - oz end
			if hi - lo + 1 ~= C.PARVIS_WIDTH or lo ~= lat - math.floor(C.PARVIS_WIDTH / 2) then
				return nil, "parvis is not " .. C.PARVIS_WIDTH .. " wide and centred on the door"
			end
			if dhi - dlo + 1 ~= C.PARVIS_FRONT_DEPTH then
				return nil, "parvis is not " .. C.PARVIS_FRONT_DEPTH .. " deep"
			end
		else
			local spans
			if side == "-z" or side == "+z" then spans = p.x1 <= c.x1 and p.x2 >= c.x2
			else spans = p.z1 <= c.z1 and p.z2 >= c.z2 end
			if not spans then return nil, "parvis does not span the cathedral front" end
		end
	end

	-- Market near the centre.
	do
		local m = sites.market.r
		local mx, mz = (m.x1 + m.x2) / 2, (m.z1 + m.z2) / 2
		local rad = C.MARKET_CENTER_RADIUS + 1
		if math.abs(mx - ctr.x) > rad or math.abs(mz - ctr.z) > rad then
			return nil, "market not near the town centre"
		end
	end

	-- Castle on an outer edge.
	do
		local k = sites.castle
		local o = k.s.outer_side
		if not valid_side(o) or k.s.side ~= OPPOSITE[o] then
			return nil, "castle does not face away from its outer edge"
		end
		local g = edge_gap(count, k.r, o, C.CASTLE_EDGE_SLACK)
		if g == nil or g ~= k.s.edge_gap then
			return nil, "castle is not on a straight outer edge within slack"
		end
	end

	-- Boundary approaches.
	if #plan.approaches ~= 2 then return nil, "expected two boundary approaches" end
	local wins = {}
	for i, a in ipairs(plan.approaches) do
		if not valid_side(a.side) then return nil, "approach has invalid side" end
		local e = L(a.edge)
		local w = (e.x2 - e.x1 + 1) * (e.z2 - e.z1 + 1)
		local len = math.max(e.x2 - e.x1 + 1, e.z2 - e.z1 + 1)
		local horizontal = a.side == "-z" or a.side == "+z"
		if not inside_env(e) or w ~= sw
				or (horizontal and e.z1 ~= e.z2) or (not horizontal and e.x1 ~= e.x2)
				or len ~= sw then
			return nil, "approach edge is not a street-wide boundary row"
		end
		if not all_filled(count, e) or edge_gap(count, e, a.side, 0) ~= 0 then
			return nil, "approach edge is not on the outer boundary"
		end
		if a.name ~= "approach_" .. i then
			return nil, "approach " .. i .. " has wrong name"
		end
		if a.pos.x - ox ~= mid(e.x1, e.x2) or a.pos.z - oz ~= mid(e.z1, e.z2) then
			return nil, "approach pos is not the middle node of its edge"
		end
		local win = approach_window(e, a.side, sw)
		if not all_filled(count, win) then
			return nil, "approach has less than a street width of boundary inside"
		end
		local blockers = {}
		for k, name in ipairs(ORDER) do blockers[k] = name end
		if sites.city_hall then blockers[#blockers + 1] = "city_hall" end
		for _, name in ipairs(blockers) do
			if intersects(win, sites[name].r) and (name == "cathedral" or name == "castle" or name == "city_hall") then
				return nil, "approach window blocked by " .. name
			end
			if intersects(e, sites[name].r) then
				return nil, "approach overlaps " .. name
			end
		end
		wins[i] = win
	end
	if plan.approaches[1].side == plan.approaches[2].side then
		return nil, "approaches are on the same side"
	end
	if intersects(wins[1], wins[2]) then
		return nil, "approach windows overlap"
	end

	-- Route space: street-wide free windows (cathedral and castle are
	-- obstacles; squares are open) must connect both approaches, and cover
	-- the approach node of every site.
	local free = new_grid(n, {})
	for z = 0, n - 1 do
		for x = 0, n - 1 do
			local f = cells[z][x] == 1
			if f and (x >= cath.r.x1 and x <= cath.r.x2 and z >= cath.r.z1 and z <= cath.r.z2) then
				f = false
			end
			local k = sites.castle.r
			if f and (x >= k.x1 and x <= k.x2 and z >= k.z1 and z <= k.z2) then
				f = false
			end
			local h = sites.city_hall and sites.city_hall.r
			if f and h and (x >= h.x1 and x <= h.x2 and z >= h.z1 and z <= h.z2) then
				f = false
			end
			free[z][x] = f and 1 or 0
		end
	end
	local seen = reachable_windows(prefix(free, n), wins[1], sw, n)
	if not seen[wins[2].z1 * n + wins[2].x1] then
		return nil, "boundary approaches not connected by a street-wide route"
	end
	local route_names = {"market", "parvis", "cathedral", "castle"}
	if sites.city_hall then route_names[#route_names + 1] = "city_hall" end
	for _, name in ipairs(route_names) do
		local p = sites[name].pos
		if not covers(seen, p.x, p.z, sw, n) then
			return nil, "no street-wide route to the " .. name .. " approach"
		end
	end
	return true
end

-- Validate a plan in world coordinates. Pure; returns true, or nil plus a
-- reason. `constants` optionally overrides planner.CONSTANTS (as in plan()).
-- With `base_only` the street, block and frontage checks are skipped (used
-- internally before streets are planned); a public call always checks them.
local function validate_with(plan, constants, base_only)
	local C = {}
	for k, v in pairs(M.CONSTANTS) do C[k] = v end
	if constants then
		for k, v in pairs(constants) do C[k] = v end
	end
	local function malformed(err)
		-- Drop any "file:line:" prefix so no internal locations leak.
		local msg = tostring(err):gsub("^[^\n]-:%d+: ", "")
		return nil, "malformed plan: " .. msg
	end
	if (constants == nil or constants.ENVELOPE == nil) and type(plan) == "table"
			and type(plan.envelope) == "table" then
		-- A plan planned with a profile carries its own (larger) envelope.
		local e = plan.envelope
		if is_int(e.x1) and is_int(e.x2) and is_int(e.z1) and is_int(e.z2)
				and e.x2 - e.x1 == e.z2 - e.z1 and e.x2 > e.x1 then
			C.ENVELOPE = e.x2 - e.x1 + 1
		end
	end
	local ok, a, b = pcall(validate_impl, plan, C)
	if not ok then return malformed(a) end
	if not a or base_only then return a, b end
	local sok, sa, sb = pcall(streets.validate, plan, C)
	if not sok then return malformed(sa) end
	if not sa then return nil, sb end
	return true
end

function M.validate(plan, constants)
	if type(plan) == "table" and plan.town_type ~= nil then
		if plan.town_type == "roman" then return authored_plan.validate(plan) end
		if plan.town_type ~= "medieval" then
			return nil, "unknown town type " .. tostring(plan.town_type)
		end
	end
	return validate_with(plan, constants, false)
end

-- One attempt. Returns plan (local coords) or nil, stage.
local function attempt(rng, C, profile)
	local n = C.ENVELOPE
	local rects = gen_boundary(rng, C)
	local cells = new_grid(n, rects)
	local bbox, why = check_boundary(cells, C)
	if not bbox then return nil, "boundary", why end
	local count = prefix(cells, n)
	local c = math.floor(n / 2)
	if cells[c][c] ~= 1 then return nil, "boundary", "centre outside boundary" end

	local market = sample_market(rng, C, count, n, hall_facade(profile))
	if not market then return nil, "market", "no market square fits near centre" end
	-- City hall beside the market (#106; profile with a city_hall entry
	-- only), reserved before the other landmarks so they keep clear of it.
	local hall, hside
	if profile and profile.city_hall then
		hall, hside = sample_city_hall(rng, C, count, market, profile.city_hall)
		if not hall then
			return nil, "market", "no city hall placement beside the market square"
		end
	end
	local cathedral, parvis, cside = sample_cathedral(rng, C, count, bbox, market,
		profile, hall)
	if not cathedral then return nil, "cathedral", "no cathedral and parvis placement" end
	local others = {cathedral, parvis, market}
	if hall then others[#others + 1] = hall end
	local castle, outer_side, egap = sample_castle(rng, C, count, bbox, n,
		others, profile)
	if not castle then return nil, "castle", "no castle placement on an outer edge" end

	local sites = {
		cathedral = shape_site("cathedral", "landmark", cathedral, cside,
			profile and profile.cathedral),
		castle = shape_site("castle", "landmark", castle, OPPOSITE[outer_side],
			profile and profile.castle),
	}
	sites.cathedral.parvis = "parvis"
	sites.castle.outer_side = outer_side
	sites.castle.edge_gap = egap
	-- Market approach: side facing the cathedral along the dominant axis.
	local dx = mid(cathedral.x1, cathedral.x2) - mid(market.x1, market.x2)
	local dz = mid(cathedral.z1, cathedral.z2) - mid(market.z1, market.z2)
	local mside
	if math.abs(dx) >= math.abs(dz) then mside = dx >= 0 and "+x" or "-x"
	else mside = dz >= 0 and "+z" or "-z" end
	if hall and mside == OPPOSITE[hside] then
		-- The hall stands beside that market edge: approach the market over
		-- the other axis toward the cathedral instead (then the far sides).
		local alt
		if mside == "+x" or mside == "-x" then alt = dz >= 0 and "+z" or "-z"
		else alt = dx >= 0 and "+x" or "-x" end
		mside = alt
	end
	sites.market = shape_site("market", "square", market, mside)
	-- Parvis approach is its far edge (away from the cathedral).
	sites.parvis = shape_site("parvis", "square", parvis, cside)

	-- Boundary approaches on two different outer sides.
	local s1 = rng.pick(SIDES)
	local s2
	repeat s2 = rng.pick(SIDES) until s2 ~= s1
	local obstacles = {cathedral, parvis, market, castle}
	if hall then obstacles[#obstacles + 1] = hall end
	local a1 = sample_approach(rng, C, count, bbox, n, s1, obstacles)
	if not a1 then
		return nil, "approach", "no boundary approach window on two outer sides"
	end
	local a2 = sample_approach(rng, C, count, bbox, n, s2, obstacles, a1)
	if not a2 then
		return nil, "approach", "no boundary approach window on two outer sides"
	end

	if hall then
		sites.city_hall = shape_site("city_hall", "landmark", hall, hside, profile.city_hall)
		sites.city_hall.square = "market"
	end
	local function approach_of(name, r, side)
		-- The outermost row of the window on the boundary edge.
		local edge
		if side == "-z" then edge = rect(r.x1, r.z1, r.x2, r.z1)
		elseif side == "+z" then edge = rect(r.x1, r.z2, r.x2, r.z2)
		elseif side == "-x" then edge = rect(r.x1, r.z1, r.x1, r.z2)
		else edge = rect(r.x2, r.z1, r.x2, r.z2) end
		return {name = name, side = side, edge = edge,
			pos = {x = mid(edge.x1, edge.x2), z = mid(edge.z1, edge.z2)}}
	end

	return {
		rects = rects, bbox = bbox, sites = sites,
		approaches = {approach_of("approach_1", a1, s1), approach_of("approach_2", a2, s2)},
	}
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

local function xz_rect(r, ox, oz)
	return {x1 = r.x1 + ox, z1 = r.z1 + oz, x2 = r.x2 + ox, z2 = r.z2 + oz}
end

local function xz_pos(p, ox, oz) return {x = p.x + ox, z = p.z + oz} end

local function to_world(local_plan, seed, center, C, attempts)
	local n = C.ENVELOPE
	local half = math.floor(n / 2)
	local ox, oz = center.x - half, center.z - half
	local sites = {}
	local names = {}
	for i, name in ipairs(ORDER) do names[i] = name end
	if local_plan.sites.city_hall then names[#names + 1] = "city_hall" end
	for _, name in ipairs(names) do
		local s = local_plan.sites[name]
		local out = {
			name = s.name, kind = s.kind,
			rect = xz_rect(s.rect, ox, oz),
			size = {x = s.size.x, z = s.size.z},
			side = s.side,
			facing = {x = s.facing.x, z = s.facing.z},
			rotation = s.rotation,
			approach = {
				side = s.approach.side,
				edge = xz_rect(s.approach.edge, ox, oz),
				pos = xz_pos(s.approach.pos, ox, oz),
			},
		}
		if s.entrance then out.entrance = xz_pos(s.entrance, ox, oz) end
		if s.id then out.id = s.id end
		if s.door then
			out.door = {recess = s.door.recess, rise = s.door.rise,
				outside = xz_pos(s.door.outside, ox, oz)}
		end
		if s.gate_span then out.gate_span = xz_rect(s.gate_span, ox, oz) end
		if s.gate_apron then out.gate_apron = xz_rect(s.gate_apron, ox, oz) end
		if s.parvis then out.parvis = s.parvis end
		if s.square then out.square = s.square end
		if s.outer_side then
			out.outer_side = s.outer_side
			out.edge_gap = s.edge_gap
		end
		sites[name] = out
	end
	local approaches = {}
	for i, a in ipairs(local_plan.approaches) do
		approaches[i] = {
			name = a.name, side = a.side,
			edge = xz_rect(a.edge, ox, oz), pos = xz_pos(a.pos, ox, oz),
		}
	end
	local brects = {}
	for i, r in ipairs(local_plan.rects) do brects[i] = xz_rect(r, ox, oz) end
	local bounds = xz_rect(local_plan.bbox, ox, oz)
	return {
		seed = seed,
		center = {x = center.x, z = center.z},
		envelope = rect(center.x - half, center.z - half, center.x + half - 1, center.z + half - 1),
		bounds = bounds,
		width = bounds.x2 - bounds.x1 + 1,
		depth = bounds.z2 - bounds.z1 + 1,
		boundary = {rects = brects},
		sites = sites,
		site_order = {"cathedral", "parvis", "market", "castle"},
		approaches = approaches,
		streets = {}, blocks = {}, frontage = {},
		attempts = attempts,
	}
end

-- Shared frontage population for every town type (tickets #69, #41, #42, #150):
-- jail, distributed services, then ordinary content, each best effort. Runs on
-- a finished plan with plan.frontage; sets plan.reservations, plan.shortages
-- and plan.content. A shortage never fails the plan. `profile` is a landmark
-- profile (jail, services and content are optional) and C the constants.
function M.populate(full, profile, seed, C)
	if not (profile and (profile.jail or profile.services or profile.content)) then
		return
	end
	full.reservations = {}
	full.shortages = {}
	if profile.jail then
		local placed, short = jail_reservation.reserve(full,
			profile.jail, {seed = seed, bias = C.JAIL_MARKET_BIAS})
		full.reservations.jail = placed
		if short then full.shortages[1] = short end
	end
	if profile.services then
		local placed, shorts, counts = service_reservation.reserve(
			full, profile.services, {seed = seed,
				variants = profile.service_variants,
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
		full.content = content_planner.plan(full, profile.content, {seed = seed})
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
	local max_attempts = M.CONSTANTS.MAX_ATTEMPTS
	local profile
	if opts ~= nil then
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
				if plan then M.populate(plan, profile, seed, M.resolve_constants(nil)) end
				return plan, why, detail
			end
			error("towns planner: unknown town type " .. tostring(opts.town_type), 2)
		end
		if opts.constants then
			for k in pairs(opts.constants) do
				if M.CONSTANTS[k] == nil and DEPTH_POLICY_KEYS[k] == nil then
					error("towns planner: unknown constant " .. tostring(k), 2)
				end
			end
			local skip = opts.constants.SECONDARY_FAIL_SKIP
			if skip ~= nil and not (is_int(skip) and skip >= 0) then
				error("towns planner: SECONDARY_FAIL_SKIP must be an integer >= 0", 2)
			end
		end
		if opts.landmarks ~= nil then
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
		end
		if opts.landmarks ~= nil and opts.landmarks.content ~= nil then
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
		if opts.max_attempts ~= nil then
			if not is_int(opts.max_attempts) or opts.max_attempts < 0 then
				error("towns planner: max_attempts must be an integer >= 0", 2)
			end
			max_attempts = opts.max_attempts
		end
	end

	local C = M.resolve_constants(opts)
	if profile then
		local fits, why = fit_check(C, profile)
		if not fits then
			return nil, "unsupported landmark profile: " .. why,
				{code = "unsupported_fit", attempts = 0, rejections = {}, last = why}
		end
	end

	local rng = new_rng(seed)
	local rejections = {}
	local last
	for i = 1, max_attempts do
		local p, stage, why = attempt(rng, C, profile)
		if p then
			local world = to_world(p, seed, center, C, i)
			world.town_type = "medieval"
			local ok, vwhy = validate_with(world, C, true)
			if ok then
				local full, swhy = streets.fill(world, rng, C)
				if full then
					ok, vwhy = M.validate(full, C)
					if ok then
						M.populate(full, profile, seed, C)
						return full
					end
					stage, why = "validate", vwhy
				else
					stage, why = "streets", swhy
				end
			else
				stage, why = "validate", vwhy
			end
		end
		rejections[stage] = (rejections[stage] or 0) + 1
		last = why
	end

	local parts = {}
	for _, stage in ipairs({"boundary", "market", "cathedral", "castle", "approach", "validate", "streets"}) do
		if rejections[stage] then
			parts[#parts + 1] = stage .. " x" .. rejections[stage]
		end
	end
	local reason = ("no valid town plan for seed %d after %d attempts"):format(seed, max_attempts)
	if #parts > 0 then
		reason = reason .. " (rejected: " .. table.concat(parts, ", ")
			.. "; last: " .. tostring(last) .. ")"
	end
	return nil, reason, {
		code = "retries_exhausted", attempts = max_attempts,
		rejections = rejections, last = last,
	}
end

-- ASCII top-down rendering for debugging. North (+Z) is up, east (+X) right.
-- Legend: . boundary  # principal street  = secondary street  b block
--         ^ v < > frontage run, pointing at the street it faces (outward)
--         C cathedral  p parvis  M market  K castle  H city hall  A approach
--         + centre  e entrance  (blank = outside)
function M.render(plan)
	local b = plan.bounds
	local grid = {}
	local function put(x, z, ch)
		if x >= b.x1 and x <= b.x2 and z >= b.z1 and z <= b.z2 then
			grid[z][x] = ch
		end
	end
	for z = b.z1, b.z2 do
		grid[z] = {}
		for x = b.x1, b.x2 do grid[z][x] = " " end
	end
	for _, r in ipairs(plan.boundary.rects) do
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do put(x, z, ".") end
		end
	end
	for _, bl in ipairs(plan.blocks) do
		local r = bl.rect
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do put(x, z, "b") end
		end
	end
	for _, kind in ipairs({"secondary", "principal"}) do
		for _, st in ipairs(plan.streets) do
			if st.kind == kind then
				local r = st.rect
				for z = r.z1, r.z2 do
					for x = r.x1, r.x2 do put(x, z, kind == "principal" and "#" or "=") end
				end
			end
		end
	end
	local arrow = {["+z"] = "^", ["-z"] = "v", ["-x"] = "<", ["+x"] = ">"}
	for _, f in ipairs(plan.frontage) do
		for z = f.rect.z1, f.rect.z2 do
			for x = f.rect.x1, f.rect.x2 do put(x, z, arrow[f.side]) end
		end
	end
	local glyph = {cathedral = "C", parvis = "p", market = "M", castle = "K",
		city_hall = "H"}
	local drawn = {}
	for i, name in ipairs(plan.site_order) do drawn[i] = name end
	if plan.sites.city_hall then drawn[#drawn + 1] = "city_hall" end
	for _, name in ipairs(drawn) do
		local r = plan.sites[name].rect
		for z = r.z1, r.z2 do
			for x = r.x1, r.x2 do put(x, z, glyph[name]) end
		end
	end
	for _, a in ipairs(plan.approaches) do
		local e = a.edge
		for z = e.z1, e.z2 do
			for x = e.x1, e.x2 do put(x, z, "A") end
		end
	end
	for _, name in ipairs(drawn) do
		local e = plan.sites[name].entrance
		if e then put(e.x, e.z, "e") end
	end
	put(plan.center.x, plan.center.z, "+")
	local lines = {}
	lines[1] = ("seed %d center (%d,%d) bounds (%d,%d)-(%d,%d) %dx%d attempts %d"):format(
		plan.seed, plan.center.x, plan.center.z, b.x1, b.z1, b.x2, b.z2,
		plan.width, plan.depth, plan.attempts)
	for z = b.z2, b.z1, -1 do
		local row = {}
		for x = b.x1, b.x2 do row[#row + 1] = grid[z][x] end
		lines[#lines + 1] = (table.concat(row):gsub("%s+$", ""))
	end
	return table.concat(lines, "\n")
end

return M
