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
-- content.validate(plan, result, entries) re-checks full-box containment,
-- facing, door approach, non-overlap and reserved-site clearance; returns
-- true or nil plus a reason.

return function(geometry, packer, occupied_rects)

local M = {}

M.ROLES = {house = true, shop = true, workshop = true}
M.CONTENT_SALT = 1299709

local function intersects(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
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
	if not inside(r, block.rect) then return nil, "box leaves its block" end
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
		if intersects(r, o) then return nil, "box overlaps a reserved or placed box" end
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

function M.plan(plan, entries, opts)
	assert(type(plan) == "table" and type(plan.sites) == "table", "content: plan required")
	assert(type(entries) == "table", "content: entries required")
	opts = opts or {}
	local seed = opts.seed or plan.seed
	local pool, roles = {}, {}
	for id, e in pairs(entries) do
		if type(e) == "table" and M.ROLES[e.role] then
			pool[id] = {size = e.size, entrance = e.entrance}
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
					local a, why = check_building(p, pool[p.building_id], run, block,
						solid, paved)
					if a then
						local b = {
							building_id = p.building_id, role = roles[p.building_id],
							block = p.block, frontage = p.frontage, rect = p.rect,
							rotation = p.rotation, entrance = p.entrance, approach = a,
						}
						result.buildings[#result.buildings + 1] = b
						occupied[#occupied + 1] = b.rect
						solid[#solid + 1] = b.rect
						placed = placed + 1
						result.counts[b.role] = (result.counts[b.role] or 0) + 1
					else
						result.rejected[#result.rejected + 1] = {frontage = run.id,
							building_id = p.building_id, reason = why}
					end
				end
				for _, u in ipairs(res.unused) do
					result.unused[#result.unused + 1] = {frontage = run.id,
						block = run.block, rect = u.rect, length = u.length}
				end
			else
				result.unused[#result.unused + 1] = {frontage = run.id,
					block = run.block, rect = run.rect, length = run.length}
			end
			if placed == 0 then result.empty_runs[#result.empty_runs + 1] = run.id end
		end
	end
	return result
end

function M.validate(plan, result, entries)
	local solid, paved = solid_rects(plan), pavement(plan)
	local list = result.buildings
	for i, b in ipairs(list) do
		local run, block = plan.frontage[b.frontage], plan.blocks[b.block]
		if not run or not block or run.street == nil or run.block ~= b.block then
			return nil, "building " .. i .. " names a bad run or block"
		end
		local entry = entries[b.building_id]
		if not entry then return nil, "building " .. i .. " has an unknown entry" end
		local others = {}
		for _, o in ipairs(solid) do others[#others + 1] = o end
		for j, o in ipairs(list) do
			if j ~= i then others[#others + 1] = o.rect end
		end
		local a, why = check_building(b, entry, run, block, others, paved)
		if not a then return nil, "building " .. i .. ": " .. why end
	end
	return true
end

return M

end
