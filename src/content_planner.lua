-- Towns: fill ordinary street frontage with house, shop and workshop boxes
-- (ticket #42). Pure Lua 5.1: no core.* calls, no catalog require. Runs on a
-- finished plan after the landmarks, hall, jail and services.
--
--   local content = dofile(".../content_planner.lua")(geometry, packer, occupied_rects)
--   local result = content.plan(plan, entries, opts)
--
--   plan     planner plan; plan.reservations (jail, services) is honoured
--   entries  id -> {size, entrance, role}; only roles house, shop and
--            workshop are used, iterated in sorted id order
--   opts     {seed = integer (default plan.seed), occupied = extra rects}
--
-- Every ordinary street frontage run (run.street ~= nil; never a market or
-- parvis face) is packed in plan.frontage order with the frontage packer.
-- One shared occupancy list (sites, jail, services, then every building
-- already placed) is passed to each run, so a later face of a block respects
-- the boxes of earlier faces: the first valid placement wins a corner and a
-- corner no box fits stays open ground. Nothing is stretched or cropped.
--
-- The random stream is private to this module: each run draws from a seed
-- derived from (seed, run id) through CONTENT_SALT, and never from the
-- planner's own stream, so civic planning for a seed does not depend on it.
--
-- Returns a data-only table
--   buildings    list of {building_id, role, block, frontage, rect, rotation,
--                entrance, approach = {x, z}} (approach is the first node
--                outside the box along the door's front, on the street)
--   unused       list of {frontage, block, rect, length}: run intervals no
--                box covers, in run then coordinate order
--   empty_runs   ids of ordinary runs that received no building
--   counts       {[role] = n} placed buildings per role
--   rejected     list of {frontage, building_id, reason} for packer picks that
--                failed validation (dropped, never emitted)
--   reason       text when there is no ordinary content at all, else nil
--
-- Access alleys (ticket #43), when the factory gets the interior access
-- validator (fourth argument) and opts.alleys ~= false: after packing, sealed
-- interior components (src/interior_access.lua, opts.occupied passed through)
-- are opened by alleys, at most M.MAX_ALLEYS_PER_AREA per area of touching
-- blocks, width 2 preferred else 1, running straight inward from pavement
-- through unused cells; failing that through whole ordinary buildings, which
-- are removed (then the run is repacked with the alley kept clear), and as a
-- last resort buildings bordering the component are dropped. Landmarks, jail
-- and services never move; if they alone seal ground the content plan is
-- rejected (no buildings, `reason` set). Extra result fields:
--   alleys   list of {id, block, area, rect, width, length, side}
--   removed  list of {building_id, frontage, rect, reason = alley|sealed}
--   access_error  text only when the validator itself failed (e.g. grid too
--                 large); the pass is then skipped
-- `unused` also treats alley cells as covered.
-- content.validate(plan, result, entries) re-checks full-box containment,
-- facing, door approach, non-overlap and reserved-site clearance; returns
-- true or nil plus a reason.

return function(geometry, packer, occupied_rects, access)

local M = {}

M.ROLES = {house = true, shop = true, workshop = true}
M.CONTENT_SALT = 1299709

local function intersects(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

local function same_rect(a, b)
	return a.x1 == b.x1 and a.z1 == b.z1 and a.x2 == b.x2 and a.z2 == b.z2
end

local function inside(r, o)
	return r.x1 >= o.x1 and r.x2 <= o.x2 and r.z1 >= o.z1 and r.z2 <= o.z2
end

local function has(r, x, z)
	return x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2
end

-- Solid rects a box and its door approach must stay out of: landmarks (not
-- squares), jail and services. Buildings are appended by the caller.
local function solid_rects(plan)
	local out = {}
	for _, s in pairs(plan.sites) do
		if type(s) == "table" and s.rect and s.kind ~= "square" then
			out[#out + 1] = s.rect
		end
	end
	local res = plan.reservations
	if type(res) == "table" then
		if type(res.jail) == "table" and res.jail.rect then out[#out + 1] = res.jail.rect end
		for _, p in ipairs(res.services or {}) do
			if p.rect then out[#out + 1] = p.rect end
		end
	end
	return out
end

local function pavement(plan)
	local out = {}
	for _, s in ipairs(plan.streets or {}) do out[#out + 1] = s.rect end
	for _, s in pairs(plan.sites) do
		if type(s) == "table" and s.kind == "square" and s.rect then out[#out + 1] = s.rect end
	end
	return out
end

-- First node outside `rect` walking from `from` along `front`.
local function first_outside(rect, from, front)
	local x, z = from.x, from.z
	for _ = 1, 1000 do
		x, z = x + front.x, z + front.z
		if not has(rect, x, z) then return {x = x, z = z} end
	end
end

-- Checks one building against its run and block; returns the door approach
-- node, or nil plus a reason. `solid` = rects of everything else already
-- solid (hall, jail, services, other buildings); `paved` = pavement rects.
local function check_building(b, entry, run, block, solid, paved)
	local r = b.rect
	local reserved = b.reserved_rect
	local expected = packer.reserved_rect(r, run.facing, entry.clearance)
	if not reserved or not same_rect(reserved, expected) then
		return nil, "reserved area does not match building clearance"
	end
	if not inside(reserved, block.rect) then return nil, "box or clearance leaves its block" end
	local g = geometry.place(entry, {x = r.x1, y = 0, z = r.z1}, b.rotation)
	if g.min.x ~= r.x1 or g.min.z ~= r.z1 or g.max.x ~= r.x2 or g.max.z ~= r.z2 then
		return nil, "box does not match the rotated footprint"
	end
	if g.front.x ~= run.facing.x or g.front.z ~= run.facing.z then
		return nil, "front does not face the street"
	end
	if g.entrance.x ~= b.entrance.x or g.entrance.z ~= b.entrance.z then
		return nil, "entrance does not match the rotated door"
	end
	for _, o in ipairs(solid) do
		if intersects(reserved, o) then return nil, "box or clearance overlaps a reserved or placed box" end
	end
	-- The door may be recessed (geometry.place().outside can lie inside the
	-- box): walk out through the box to the first node beyond it. That node
	-- must be street pavement and not inside any solid box.
	local a = first_outside(r, g.entrance, g.front)
	if not a then return nil, "door approach not found" end
	if has(block.rect, a.x, a.z) then return nil, "door approach lies inside the block" end
	local on = false
	for _, p in ipairs(paved) do
		if has(p, a.x, a.z) then on = true break end
	end
	if not on then return nil, "door approach is not on pavement" end
	for _, o in ipairs(solid) do
		if has(o, a.x, a.z) then return nil, "door approach is blocked" end
	end
	return a
end


-- Appends the run intervals no building (or alley) covers to `out`.
local function unused_for(run, buildings, alleys, out)
	local rr = run.rect
	local along_x = run.facing.z ~= 0
	local lo = along_x and rr.x1 or rr.z1
	local hi = along_x and rr.x2 or rr.z2
	local covered = {}
	local function cover(r)
		if not intersects(r, rr) then return end
		local a1 = along_x and r.x1 or r.z1
		local a2 = along_x and r.x2 or r.z2
		for c = math.max(a1, lo), math.min(a2, hi) do covered[c] = true end
	end
	for _, b in ipairs(buildings) do
		if b.frontage == run.id then cover(b.reserved_rect or b.rect) end
	end
	for _, a in ipairs(alleys or {}) do cover(a.rect) end
	local gap
	for c = lo, hi + 1 do
		if c <= hi and not covered[c] then
			gap = gap or c
		elseif gap then
			local rect = along_x
				and {x1 = gap, x2 = c - 1, z1 = rr.z1, z2 = rr.z2}
				or {x1 = rr.x1, x2 = rr.x2, z1 = gap, z2 = c - 1}
			out[#out + 1] = {frontage = run.id, block = run.block, rect = rect,
				length = c - gap}
			gap = nil
		end
	end
end

M.MAX_ALLEYS_PER_AREA = 2
M.ALLEY_WIDTHS = {2, 1}

-- Inward sides of a block: `edge` names the block rect field of the edge row
-- and `step` the inward direction along the other axis.
local SIDES = {
	{name = "-z", along = "x", edge = "z1", step = 1},
	{name = "+z", along = "x", edge = "z2", step = -1},
	{name = "-x", along = "z", edge = "x1", step = 1},
	{name = "+x", along = "z", edge = "x2", step = -1},
}

-- Blocks that touch (share an edge or overlap) form one area; the area id is
-- its lowest block id, so results are stable.
local function block_areas(blocks)
	local parent = {}
	for i = 1, #blocks do parent[i] = i end
	local function find(i)
		while parent[i] ~= i do i = parent[i] end
		return i
	end
	for i = 1, #blocks do
		for j = i + 1, #blocks do
			local a, b = blocks[i].rect, blocks[j].rect
			if a.x1 <= b.x2 + 1 and b.x1 <= a.x2 + 1
				and a.z1 <= b.z2 + 1 and b.z1 <= a.z2 + 1 then
				local ri, rj = find(i), find(j)
				if ri ~= rj then
					if ri < rj then parent[rj] = ri else parent[ri] = rj end
				end
			end
		end
	end
	local area = {}
	for i = 1, #blocks do area[blocks[i].id] = blocks[find(i)].id end
	return area
end

function M.plan(plan, entries, opts)
	assert(type(plan) == "table" and type(plan.sites) == "table", "content: plan required")
	assert(type(entries) == "table", "content: entries required")
	opts = opts or {}
	local seed = opts.seed or plan.seed
	local pool, roles = {}, {}
	for id, e in pairs(entries) do
		if type(e) == "table" and M.ROLES[e.role] then
			-- Leave a firebreak around the stock smithy's enclosed lava hearth.
			pool[id] = {size = e.size, entrance = e.entrance,
				clearance = id == "blacksmith" and 1 or nil}
			roles[id] = e.role
		end
	end

	local result = {buildings = {}, unused = {}, empty_runs = {}, counts = {},
		rejected = {}}
	local have = next(pool) ~= nil
	if not have then
		result.reason = "no house, shop or workshop entry in the catalog"
	end

	local occupied = occupied_rects(plan, opts.occupied)
	local solid, paved = solid_rects(plan), pavement(plan)
	local library_placed = false
	for _, r in ipairs(opts.occupied or {}) do solid[#solid + 1] = r end

	for _, run in ipairs(plan.frontage) do
		if run.street ~= nil then
			local block = plan.blocks[run.block]
			local placed = 0
			if have then
				local res = packer.pack{
					run = {id = run.id, facing = run.facing, rect = run.rect},
					block = block, entries = pool, occupied = occupied,
					seed = seed * 31 + M.CONTENT_SALT + run.id * 104729,
				}
				for _, p in ipairs(res.placements) do
					-- The catalog's library is ordinary shop content, but a town
					-- should have at most one. Keep it in the existing frontage
					-- selection so it can appear wherever it fits; just ignore any
					-- later picks after the first accepted placement.
					if not (p.building_id == "library" and library_placed) then
						local a, why = check_building(p, pool[p.building_id], run, block,
							solid, paved)
						if a then
							local b = {
								building_id = p.building_id, role = roles[p.building_id],
								block = p.block, frontage = p.frontage, rect = p.rect,
								reserved_rect = p.reserved_rect,
								rotation = p.rotation, entrance = p.entrance, approach = a,
							}
							result.buildings[#result.buildings + 1] = b
							if b.building_id == "library" then library_placed = true end
							occupied[#occupied + 1] = b.reserved_rect or b.rect
							solid[#solid + 1] = b.reserved_rect or b.rect
							placed = placed + 1
							result.counts[b.role] = (result.counts[b.role] or 0) + 1
						else
							result.rejected[#result.rejected + 1] = {frontage = run.id,
								building_id = p.building_id, reason = why}
						end
					end
				end
				-- Recompute unused from the kept buildings only: the packer
				-- counts a rejected pick as covered, but it is not placed.
				unused_for(run, result.buildings, nil, result.unused)
			else
				result.unused[#result.unused + 1] = {frontage = run.id,
					block = run.block, rect = run.rect, length = run.length}
			end
			if placed == 0 then result.empty_runs[#result.empty_runs + 1] = run.id end
		end
	end
	if access and opts.alleys ~= false and #result.buildings > 0 then
		M.open_alleys(plan, result, pool, roles, seed, opts)
	end
	return result
end

-- Access pass (ticket #43): while the validator reports a sealed component,
-- reserve an alley (width 2 preferred, else 1; at most two per touching-block
-- area) from pavement through free cells, else through whole ordinary
-- buildings (removed), else drop buildings touching the component. Services,
-- jail and landmarks never move. Modifies `result` in place.
function M.open_alleys(plan, result, pool, roles, seed, opts)
	local paved = pavement(plan)
	result.alleys, result.removed = {}, {}
	local extra = opts.occupied
	local fixed = solid_rects(plan)
	for _, r in ipairs(extra or {}) do fixed[#fixed + 1] = r end

	local function check(list)
		return access.check(plan, {buildings = list, occupied = extra})
	end
	local base, err = check({})
	if not base then
		result.access_error = err
		return
	end
	if not base.ok then
		-- Fixed sites and services alone seal ground: no ordinary content
		-- can fix that, so the content plan is rejected.
		local c = base.components[1]
		result.buildings, result.unused, result.empty_runs = {}, {}, {}
		result.counts = {}
		for _, run in ipairs(plan.frontage) do
			if run.street ~= nil then
				result.unused[#result.unused + 1] = {frontage = run.id,
					block = run.block, rect = run.rect, length = run.length}
				result.empty_runs[#result.empty_runs + 1] = run.id
			end
		end
		result.reason = ("fixed landmarks, jail and services seal %d interior cell(s)"
			.. " (first at x=%d z=%d, block %s); content plan rejected"):format(
			base.sealed_cells, c.first.x, c.first.z, tostring(c.blocks[1]))
		return
	end

	local blocks = plan.blocks
	local area = block_areas(blocks)
	local per_area = {}
	local function in_block(x, z)
		for _, b in ipairs(blocks) do
			if has(b.rect, x, z) then return true end
		end
		return false
	end
	local function on_pavement(x, z)
		for _, p in ipairs(paved) do
			if has(p, x, z) then return true end
		end
		return false
	end

	local dirty = {}
	local function remove(set, why)
		local keep = {}
		for i, b in ipairs(result.buildings) do
			if set[i] then
				result.removed[#result.removed + 1] = {building_id = b.building_id,
					frontage = b.frontage, rect = b.rect, reason = why}
				dirty[b.frontage] = true
			else
				keep[#keep + 1] = b
			end
		end
		result.buildings = keep
	end

	-- Best straight strip from a pavement-adjacent block edge inward that
	-- ends beside a cell of `comp`. Key: needs-removal, width, removed, length.
	local function best_candidate(comp)
		local cells = {}
		for _, r in ipairs(comp.rects) do
			for x = r.x1, r.x2 do cells[r.z1 * 100003 + x] = true end
		end
		local best, bkey
		for _, blk in ipairs(blocks) do
			local a = area[blk.id]
			if (per_area[a] or 0) < M.MAX_ALLEYS_PER_AREA then
				for _, side in ipairs(SIDES) do
					local r = blk.rect
					local lo = side.along == "x" and r.x1 or r.z1
					local hi = side.along == "x" and r.x2 or r.z2
					local edge = r[side.edge]
					local function cell(q, k)
						if side.along == "x" then return q, edge + side.step * k end
						return edge + side.step * k, q
					end
					for _, w in ipairs(M.ALLEY_WIDTHS) do
						for p = lo, hi - w + 1 do
							local ok = true
							for q = p, p + w - 1 do
								local x, z = cell(q, -1)
								if not on_pavement(x, z) then ok = false break end
							end
							local k, hit = 0, false
							local victims, nv = {}, 0
							while ok and not hit do
								for q = p, p + w - 1 do
									local x, z = cell(q, k)
									if not in_block(x, z) then ok = false break end
									if cells[z * 100003 + x] then hit = true end
								end
								if ok and not hit then
									for q = p, p + w - 1 do
										local x, z = cell(q, k)
										for _, o in ipairs(fixed) do
											if has(o, x, z) then ok = false break end
										end
										if not ok then break end
										for i, b in ipairs(result.buildings) do
											if has(b.rect, x, z) and not victims[i] then
												victims[i] = true
												nv = nv + 1
											end
										end
									end
									k = k + 1
								end
							end
							if ok and hit and k >= 1 then
								local key = {nv > 0 and 1 or 0, w == 2 and 0 or 1, nv, k}
								local better = not bkey
								if bkey then
									for i = 1, 4 do
										if key[i] ~= bkey[i] then
											better = key[i] < bkey[i]
											break
										end
									end
								end
								if better then
									local x1, z1 = cell(p, 0)
									local x2, z2 = cell(p + w - 1, k - 1)
									best = {block = blk.id, area = a, width = w,
										length = k, side = side.name, victims = victims,
										rect = {x1 = math.min(x1, x2), x2 = math.max(x1, x2),
											z1 = math.min(z1, z2), z2 = math.max(z1, z2)}}
									bkey = key
								end
							end
						end
					end
				end
			end
		end
		return best
	end

	local function touches(br, s)
		return br.x1 <= s.x2 + 1 and s.x1 <= br.x2 + 1
			and br.z1 <= s.z2 + 1 and s.z1 <= br.z2 + 1
	end

	local max_iter = 2 * #blocks + 8
	local r = check(result.buildings)
	local iter = 0
	while r and not r.ok and iter < max_iter do
		iter = iter + 1
		local comp = r.components[1]
		local cand = best_candidate(comp)
		if cand then
			per_area[cand.area] = (per_area[cand.area] or 0) + 1
			remove(cand.victims, "alley")
			result.alleys[#result.alleys + 1] = {id = #result.alleys + 1,
				block = cand.block, area = cand.area, rect = cand.rect,
				width = cand.width, length = cand.length, side = cand.side}
		else
			-- No alley fits: drop whole buildings bordering the component.
			local victims, n = {}, 0
			for i, b in ipairs(result.buildings) do
				for _, s in ipairs(comp.rects) do
					if touches(b.rect, s) then victims[i] = true; n = n + 1 break end
				end
			end
			if n == 0 then
				for i = 1, #result.buildings do victims[i] = true end
			end
			remove(victims, "sealed")
		end
		r = check(result.buildings)
	end
	if r and not r.ok then
		local all = {}
		for i = 1, #result.buildings do all[i] = true end
		remove(all, "sealed")
	end

	-- Refill runs that lost a building, keeping alleys clear; kept only when
	-- the validator still reports no sealed ground.
	local touched = {}
	for _, run in ipairs(plan.frontage) do
		if run.street ~= nil and dirty[run.id] then touched[#touched + 1] = run end
	end
	if #touched > 0 and next(pool) ~= nil then
		local added = {}
		local occ = occupied_rects(plan, extra)
		local solid = solid_rects(plan)
		for _, rr in ipairs(extra or {}) do solid[#solid + 1] = rr end
		for _, b in ipairs(result.buildings) do
			local reserved = b.reserved_rect or b.rect
			occ[#occ + 1] = reserved; solid[#solid + 1] = reserved
		end
		for _, a in ipairs(result.alleys) do
			occ[#occ + 1] = a.rect; solid[#solid + 1] = a.rect
		end
		for _, run in ipairs(touched) do
			local block = plan.blocks[run.block]
			local res = packer.pack{
				run = {id = run.id, facing = run.facing, rect = run.rect},
				block = block, entries = pool, occupied = occ,
				seed = seed * 31 + M.CONTENT_SALT + run.id * 104729,
			}
			for _, p in ipairs(res.placements) do
				local a = check_building(p, pool[p.building_id], run, block, solid, paved)
				if a then
					added[#added + 1] = {
						building_id = p.building_id, role = roles[p.building_id],
						block = p.block, frontage = p.frontage, rect = p.rect,
						reserved_rect = p.reserved_rect,
						rotation = p.rotation, entrance = p.entrance, approach = a,
					}
					occ[#occ + 1] = p.reserved_rect
					solid[#solid + 1] = p.reserved_rect
				end
			end
		end
		if #added > 0 then
			local list = {}
			for _, b in ipairs(result.buildings) do list[#list + 1] = b end
			for _, b in ipairs(added) do list[#list + 1] = b end
			local rc = check(list)
			if rc and rc.ok then result.buildings = list end
		end
	end

	-- Recompute derived fields from the final buildings and alleys.
	result.counts, result.unused, result.empty_runs = {}, {}, {}
	local has_run = {}
	for _, b in ipairs(result.buildings) do
		result.counts[b.role] = (result.counts[b.role] or 0) + 1
		has_run[b.frontage] = true
	end
	for _, run in ipairs(plan.frontage) do
		if run.street ~= nil then
			unused_for(run, result.buildings, result.alleys, result.unused)
			if not has_run[run.id] then
				result.empty_runs[#result.empty_runs + 1] = run.id
			end
		end
	end
end

function M.validate(plan, result, entries)
	local solid, paved = solid_rects(plan), pavement(plan)
	local list = result.buildings
	for i, b in ipairs(list) do
		local run, block = plan.frontage[b.frontage], plan.blocks[b.block]
		if not run or not block or run.street == nil or run.block ~= b.block then
			return nil, "building " .. i .. " names a bad run or block"
		end
		local source_entry = entries[b.building_id]
		if not source_entry then return nil, "building " .. i .. " has an unknown entry" end
		local entry = {size = source_entry.size, entrance = source_entry.entrance,
			clearance = b.building_id == "blacksmith" and 1 or nil}
		local others = {}
		for _, o in ipairs(solid) do others[#others + 1] = o end
		for j, o in ipairs(list) do
			if j ~= i then others[#others + 1] = o.reserved_rect or o.rect end
		end
		local a, why = check_building(b, entry, run, block, others, paved)
		if not a then return nil, "building " .. i .. ": " .. why end
		if not b.approach or b.approach.x ~= a.x or b.approach.z ~= a.z then
			return nil, "building " .. i .. ": stored approach differs from the door"
		end
	end
	-- Alleys: inside a block, clear of every solid box, first row on pavement.
	for i, a in ipairs(result.alleys or {}) do
		local blk = plan.blocks[a.block]
		if not blk or not inside(a.rect, blk.rect) then
			return nil, "alley " .. i .. " leaves its block"
		end
		local others = solid_rects(plan)
		for _, b in ipairs(list) do others[#others + 1] = b.rect end
		for _, o in ipairs(others) do
			if intersects(a.rect, o) then return nil, "alley " .. i .. " overlaps a box" end
		end
		local on = false
		local r = a.rect
		for _, probe in ipairs({{r.x1 - 1, r.z1}, {r.x2 + 1, r.z1},
				{r.x1, r.z1 - 1}, {r.x1, r.z2 + 1}}) do
			for _, p in ipairs(paved) do
				if has(p, probe[1], probe[2]) then on = true end
			end
		end
		if not on then return nil, "alley " .. i .. " does not touch pavement" end
	end
	return true
end

return M

end
