-- Towns: reserve distributed taverns, wells and chapels (ticket #41).
-- Pure Lua 5.1: no core.* calls. Runs on a finished plan after the
-- landmarks, city hall and jail and before any ordinary building.
--
--   local svc = dofile(".../service_reservation.lua")(packer, occupied_rects)
--   local placements, shortages, counts = svc.reserve(plan, services, opts)
--
--   plan      planner plan (blocks, frontage, sites, reservations)
--   services  {tavern = entry, well = entry, chapel = entry}; entry is
--             {id, size, entrance}. A missing role is simply not reserved.
--             A well's box includes its apron.
--   opts      {seed = integer (default plan.seed),
--              targets = {tavern = n, well = n, chapel = n},
--              variants = {tavern = {entry, ...}, ...} (optional; each
--              role's catalog ids, sorted; default {services[role]}),
--              chapel_min_cathedral = nodes, chapel_min_between = nodes,
--              occupied = extra rects to avoid}
--   occupied_rects(plan, extra) -> list of rects (sites, jail, earlier
--             reservations); see jail_reservation.occupied_rects.
--
-- Variants (#114): the slots of a role are shared by all its variants. For
-- each slot a seeded draw picks the preferred variant; when it has no fitting
-- candidate the others are tried in cyclic order before a shortage is reported.
-- Roles are processed in the fixed order tavern, well, chapel; each box is
-- added to the shared occupancy before the next is chosen, so nothing ever
-- overlaps a landmark, the hall, the jail or another service. Candidates come
-- from the frontage packer over street and square frontage runs. Street boxes
-- that would consume a viable square candidate's shared corner are excluded,
-- while non-conflicting street options remain available. The first pick is a
-- seeded draw within those candidates; later picks take the candidate whose
-- entrance has the greatest minimum squared X/Z distance to the entrances
-- already chosen for that role, the first in frontage order winning ties.
-- Chapels additionally start from the cathedral entrance as an
-- existing church and must be at least chapel_min_cathedral from it and
-- chapel_min_between from every other chapel (hard filters).
--
-- Returns placements (list in role order), shortages (list of
-- {role, wanted, placed, reason} for unmet targets), counts
-- ({[role] = {wanted, placed}}).

return function(packer, occupied_rects)

local M = {}

M.ROLES = {"tavern", "well", "chapel"}
M.TARGETS = {tavern = 3, well = 3, chapel = 2}
M.CHAPEL_MIN_FROM_CATHEDRAL = 40
M.CHAPEL_MIN_BETWEEN = 70

local MOD = 2147483647

local function draw(seed, n)
	local s = seed % MOD
	for _ = 1, 8 do s = (s * 48271 + 1013904223) % MOD end
	s = (s * 48271 + 1013904223) % MOD
	return 1 + math.floor(s * n / MOD)
end

local function d2(a, b)
	local dx, dz = a.x - b.x, a.z - b.z
	return dx * dx + dz * dz
end

local function overlaps(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

function M.reserve(plan, services, opts)
	assert(type(plan) == "table" and type(plan.sites) == "table", "service: plan required")
	assert(type(services) == "table", "service: services required")
	opts = opts or {}
	local seed = opts.seed or plan.seed
	local targets = opts.targets or M.TARGETS
	local min_cath = opts.chapel_min_cathedral or M.CHAPEL_MIN_FROM_CATHEDRAL
	local min_between = opts.chapel_min_between or M.CHAPEL_MIN_BETWEEN

	local occupied = occupied_rects(plan, opts.occupied)
	local cathedral = plan.sites.cathedral and plan.sites.cathedral.entrance

	local placements, shortages, counts = {}, {}, {}
	local frontage = {}
	for _, run in ipairs(plan.frontage) do
		if run.square ~= nil then frontage[#frontage + 1] = run end
	end
	for _, run in ipairs(plan.frontage) do
		if run.street ~= nil then frontage[#frontage + 1] = run end
	end
	for ri, role in ipairs(M.ROLES) do
		local entry = services[role]
		local wanted = targets[role] or 0
		if entry and wanted > 0 then
			-- Catalog variants of the role (#114) share the same slots. Without
			-- opts.variants the role has just its one entry.
			local pool = opts.variants and opts.variants[role]
			if pool == nil or #pool == 0 then pool = {entry} end
			local chosen = {} -- placements of this role
			local reason
			-- Candidate for one variant in the slot: a placement or nil plus a reason.
			local function choose(v)
				local id = v.id or role
				local pe = {size = v.size, entrance = v.entrance}
				local square_cands, street_cands, runs = {}, {}, 0
				for _, run in ipairs(frontage) do
					runs = runs + 1
					local res = packer.pack{
						run = {id = run.id, facing = run.facing, rect = run.rect},
						block = plan.blocks[run.block], entries = {[id] = pe},
						seed = seed, occupied = occupied,
					}
					local cands = run.square and square_cands or street_cands
					for _, p in ipairs(res.placements) do cands[#cands + 1] = p end
				end
				if runs == 0 then return nil, "no street or square frontage" end
				if #square_cands + #street_cands == 0 then
					return nil, "no street or square frontage run has room for the " .. role
						.. " box (" .. v.size.x .. "x" .. v.size.z .. ")"
				end
				if role == "chapel" then
					local function keep_distant(cands)
						local kept = {}
						for _, p in ipairs(cands) do
							local ok = cathedral == nil or d2(p.entrance, cathedral) >= min_cath * min_cath
							for _, c in ipairs(chosen) do
								if d2(p.entrance, c.entrance) < min_between * min_between then ok = false end
							end
							if ok then kept[#kept + 1] = p end
						end
						return kept
					end
					square_cands = keep_distant(square_cands)
					street_cands = keep_distant(street_cands)
					if #square_cands + #street_cands == 0 then
						return nil, "no fitting chapel is at least " .. min_cath
							.. " nodes from the cathedral entrance and " .. min_between
							.. " from another chapel"
					end
				end
				-- Keep street service boxes that do not consume a viable square
				-- candidate's shared corner. When every street candidate conflicts,
				-- the square candidate wins that frontage space.
				local safe_street_cands = {}
				for _, street in ipairs(street_cands) do
					local conflicts = false
					for _, square in ipairs(square_cands) do
						if overlaps(street.rect, square.rect) then conflicts = true; break end
					end
					if not conflicts then safe_street_cands[#safe_street_cands + 1] = street end
				end
				local cands = #safe_street_cands > 0 and safe_street_cands
					or (#square_cands > 0 and square_cands or street_cands)
				local refs = {}
				for _, c in ipairs(chosen) do refs[#refs + 1] = c.entrance end
				if role == "chapel" and cathedral then refs[#refs + 1] = cathedral end
				local pick
				if #refs == 0 then
					pick = cands[draw(seed + ri * 7919, #cands)]
				else
					local best
					for _, p in ipairs(cands) do
						local m
						for _, r in ipairs(refs) do
							local d = d2(p.entrance, r)
							if m == nil or d < m then m = d end
						end
						if best == nil or m > best then best, pick = m, p end
					end
				end
				return {
					building_id = id, role = role, block = pick.block,
					frontage = pick.frontage, rect = pick.rect,
					rotation = pick.rotation, entrance = pick.entrance,
				}
			end
			while #chosen < wanted do
				local slot = #chosen + 1
				-- Seeded preferred variant for this slot, then the others in
				-- cyclic order as fallbacks. A single variant draws nothing.
				local first = #pool == 1 and 1
					or draw(seed + ri * 7919 + slot * 104729, #pool)
				local out, slot_reason
				for j = 0, #pool - 1 do
					local v = pool[(first - 1 + j) % #pool + 1]
					local p, why = choose(v)
					if p then out = p; break end
					slot_reason = slot_reason or why
				end
				if out == nil then reason = slot_reason; break end
				chosen[#chosen + 1] = out
				placements[#placements + 1] = out
				occupied[#occupied + 1] = out.rect
			end
			counts[role] = {wanted = wanted, placed = #chosen}
			if #chosen < wanted then
				shortages[#shortages + 1] = {role = role, wanted = wanted,
					placed = #chosen, reason = reason}
			end
		end
	end
	return placements, shortages, counts
end

return M

end
