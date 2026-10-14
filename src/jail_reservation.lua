-- Towns: reserve the single jail on ordinary street frontage (ticket #69).
-- Pure Lua 5.1: no core.* calls. Runs on a finished plan, after the
-- landmarks and the city hall and before any other building is placed.
--
--   local jail = dofile(".../jail_reservation.lua")(packer)
--   local placement, shortage = jail.reserve(plan, entry, opts)
--
--   plan   a planner plan (streets, blocks, frontage, sites)
--   entry  catalog snapshot entry of the jail: {id, size, entrance}
--   opts   optional {seed = integer (default plan.seed),
--                    bias = JAIL_MARKET_BIAS override,
--                    occupied = extra rects to avoid}
--
-- Candidates come from the frontage packer run over every ordinary street
-- frontage run (never a market or parvis face) with every site rectangle
-- (landmarks, hall, squares) as occupancy. The jail is the candidate whose
-- entrance is farthest from the market square centre (bias 1; -1 prefers
-- the nearest). Exact ties are broken by a seeded draw over the candidates
-- in frontage order, so a seed and catalog always give the same result.
--
-- Returns placement, nil on success:
--   {building_id, role = "jail", block, frontage, rect, rotation, entrance,
--    distance = squared entrance-to-market-centre distance}
-- or nil, shortage when none fits (planning is not failed):
--   {role = "jail", wanted = 1, placed = 0, reason = "<text>"}

return function(packer)

local M = {}

M.JAIL_MARKET_BIAS = 1 -- 1: farthest from the market centre, -1: nearest

local MOD = 2147483647

local function draw(seed, n)
	local s = seed % MOD
	for _ = 1, 8 do s = (s * 48271 + 1013904223) % MOD end
	s = (s * 48271 + 1013904223) % MOD
	return 1 + math.floor(s * n / MOD)
end

local function shortage(reason)
	return nil, {role = "jail", wanted = 1, placed = 0, reason = reason}
end

function M.reserve(plan, entry, opts)
	assert(type(plan) == "table" and type(plan.sites) == "table", "jail: plan required")
	assert(type(entry) == "table" and type(entry.size) == "table", "jail: catalog entry required")
	opts = opts or {}
	local seed = opts.seed or plan.seed
	local bias = opts.bias or M.JAIL_MARKET_BIAS
	local id = entry.id or "jail"

	-- Occupancy is a set, so pairs order cannot leak into the result.
	local occupied = {}
	for _, s in pairs(plan.sites) do
		if type(s) == "table" and s.rect then occupied[#occupied + 1] = s.rect end
	end
	for _, r in ipairs(opts.occupied or {}) do occupied[#occupied + 1] = r end

	local market = plan.sites.market and plan.sites.market.rect
	if not market then return shortage("plan has no market square") end
	local mx = (market.x1 + market.x2) / 2
	local mz = (market.z1 + market.z2) / 2

	local pe = {size = entry.size, entrance = entry.entrance}
	local cands, runs = {}, 0
	for _, run in ipairs(plan.frontage) do
		if run.street ~= nil then -- ordinary street frontage only
			runs = runs + 1
			local res = packer.pack{
				run = {id = run.id, facing = run.facing, rect = run.rect},
				block = plan.blocks[run.block], entries = {[id] = pe}, seed = seed,
				occupied = occupied,
			}
			for _, p in ipairs(res.placements) do
				local dx, dz = p.entrance.x - mx, p.entrance.z - mz
				cands[#cands + 1] = {p = p, d = dx * dx + dz * dz}
			end
		end
	end
	if runs == 0 then return shortage("no ordinary street frontage") end
	if #cands == 0 then
		return shortage("no street frontage run has room for the jail box ("
			.. entry.size.x .. "x" .. entry.size.z .. ")")
	end

	local best, ties = nil, {}
	for _, c in ipairs(cands) do
		local score = bias * c.d
		if best == nil or score > best then
			best, ties = score, {c}
		elseif score == best then
			ties[#ties + 1] = c
		end
	end
	local pick = ties[draw(seed, #ties)]
	local p = pick.p
	return {
		building_id = id, role = "jail", block = p.block, frontage = p.frontage,
		rect = p.rect, rotation = p.rotation, entrance = p.entrance,
		distance = pick.d,
	}
end

return M

end
