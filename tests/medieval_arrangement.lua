-- Orientation-free geometry checks for a medieval plan (issue #184, stage 4).
-- The planner varies the market quadrant, the castle side and the turn of the
-- whole plan, so nothing here assumes a compass direction: every rule is
-- stated along the cathedral's facing f (from the cathedral into the town)
-- and the castle's facing g.
--
--   local A = dofile("tests/medieval_arrangement.lua")
--   A.problems(plan)    -> list of names of the rules the plan breaks (empty: fine)
--   A.arrangement(plan) -> "f=..,market=..,castle=.." key identifying the arrangement
local A = {}

-- Largest coordinate of rect r measured along unit vector f.
local function far(r, f)
	if f.x > 0 then return r.x2 elseif f.x < 0 then return -r.x1
	elseif f.z > 0 then return r.z2 else return -r.z1 end
end
local function near(r, f) return -far(r, {x = -f.x, z = -f.z}) end
local function neg(f) return {x = -f.x, z = -f.z} end
local function perp(f) return {x = -f.z, z = f.x} end
local function dot(p, f) return p.x * f.x + p.z * f.z end
local function centre(r) return {x = (r.x1 + r.x2) / 2, z = (r.z1 + r.z2) / 2} end
local function inside(p, r) return p.x >= r.x1 and p.x <= r.x2 and p.z >= r.z1 and p.z <= r.z2 end
local function overlap(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end
-- Disjoint rects sharing a full edge line (no diagonal contact).
local function adjacent(a, b)
	local gx = math.max(a.x1 - b.x2, b.x1 - a.x2) - 1
	local gz = math.max(a.z1 - b.z2, b.z1 - a.z2) - 1
	return (gx == 0 and gz < 0) or (gz == 0 and gx < 0)
end
local function is_axis(f) return f and math.abs(f.x) + math.abs(f.z) == 1 end

function A.arrangement(plan)
	local f = plan.sites.cathedral.facing
	local l = perp(f)
	local c = plan.center
	local m, k = plan.sites.market.rect, plan.sites.castle.rect
	local function rel(r, v) return dot(centre(r), v) - dot(c, v) end
	local function sign(v) return v < 0 and "-" or "+" end
	return ("f=%d,%d;market=%s%s;castle=%s"):format(f.x, f.z, sign(rel(m, f)), sign(rel(m, l)), sign(rel(k, l)))
end

function A.problems(plan)
	local out = {}
	local function check(name, ok) if not ok then out[#out + 1] = name end end
	local sites = plan.sites
	local cath, parvis, castle, market, hall = sites.cathedral, sites.parvis, sites.castle,
		sites.market, sites.city_hall
	local core = plan.boundary.rects[1]
	local f, g = cath.facing, castle.facing
	check("cathedral and castle faces are axis vectors", is_axis(f) and is_axis(g))
	if not (is_axis(f) and is_axis(g)) then return out end
	local lateral = perp(f)

	-- The principals: ns runs along f, ew along g.
	local ns, ew
	for _, s in ipairs(plan.streets) do
		if s.kind == "principal" then
			local alongf = far(s.rect, f) - near(s.rect, f) + 1
			if alongf > 6 then ns = s.rect else ew = s.rect end
		end
	end
	check("two principals", ns ~= nil and ew ~= nil)
	if not (ns and ew) then return out end
	check("centre is the principals' crossing", inside(plan.center, ns) and inside(plan.center, ew))
	check("castle faces along the east-west principal", math.abs(g.x) ~= math.abs(f.x)
		and near(ew, g) == near(core, g) and far(ew, g) == far(core, g))

	-- Cathedral: outside the core at the f-low edge, door on ns's centre line,
	-- parvis in the edge row between them, principal ending in the parvis.
	check("cathedral outside the core", far(cath.rect, f) + 1 == near(core, f))
	local door = cath.entrance
	local off = dot(door, lateral) - near(ns, lateral)
	check("cathedral door on the principal's centre line", off == 2 or off == 3)
	check("parvis in the core's edge row", far(parvis.rect, neg(f)) == far(core, neg(f))
		and far(parvis.rect, f) - near(parvis.rect, f) + 1 == 8
		and far(parvis.rect, lateral) - near(parvis.rect, lateral) + 1 == 12)
	check("parvis centred on the door",
		dot(door, lateral) - near(parvis.rect, lateral) >= 5 and far(parvis.rect, lateral) - dot(door, lateral) >= 5)
	check("principal ends in the parvis", far(ns, neg(f)) + 1 == near(parvis.rect, neg(f))
		and far(ns, neg(f)) < far(core, neg(f)) and near(ns, neg(f)) == near(core, neg(f)))
	check("cathedral approach on the parvis", inside(cath.approach.pos, parvis.rect)
		and dot(cath.approach.pos, lateral) == dot(door, lateral)
		and dot(cath.approach.pos, neg(f)) == far(parvis.rect, neg(f)))

	-- Castle: outside the core, gate span across ew on the wall facing the town.
	check("castle outside the core", far(castle.rect, g) + 1 == near(core, g))
	local gate = castle.gate_span
	local gl = perp(g)
	check("gate covers the principal", gate ~= nil and near(gate, gl) == near(ew, gl) and far(gate, gl) == far(ew, gl))
	check("gate on the castle's wall facing the town", gate ~= nil and far(gate, g) == far(castle.rect, g)
		and near(gate, g) == far(gate, g))
	local a = castle.approach.pos
	check("castle approach on the principal", inside(a, ew) and dot(a, g) == near(core, g))
	check("castle door in line with the gate", gate ~= nil
		and dot(castle.entrance, gl) >= near(gate, gl) and dot(castle.entrance, gl) <= far(gate, gl))

	-- Market at a corner of the crossing, hall on its far side facing back.
	check("market beside both principals", adjacent(market.rect, ns) and adjacent(market.rect, ew))
	check("market is not on the crossing", not overlap(market.rect, ns) and not overlap(market.rect, ew))
	if hall then
		local h = hall.facing
		check("hall faces along the east-west principal", is_axis(h) and math.abs(h.x) == math.abs(g.x))
		if is_axis(h) then
			local hl = perp(h)
			check("hall touches the market edge it faces", adjacent(hall.rect, market.rect)
				and far(hall.rect, h) + 1 == near(market.rect, h))
			check("hall on the market's far side from the north-south principal",
				near(ns, h) > far(hall.rect, h) and near(ns, h) == far(market.rect, h) + 1)
			check("hall facade within the market", near(hall.rect, hl) >= near(market.rect, hl)
				and far(hall.rect, hl) <= far(market.rect, hl))
			check("hall centred on the market", math.abs((near(hall.rect, hl) + far(hall.rect, hl))
				- (near(market.rect, hl) + far(market.rect, hl))) <= 1)
			check("hall entrance within its footprint", inside(hall.entrance, hall.rect))
			check("hall square is the market", hall.square == "market")
			local ap = hall.approach.pos
			check("hall approach on the market", inside(ap, market.rect) and not inside(ap, hall.rect)
				and dot(ap, h) == far(hall.rect, h) + 1 and dot(ap, hl) == dot(hall.entrance, hl))
			local clear = true
			for i = 0, 4 do
				local p = {x = ap.x + h.x * i, z = ap.z + h.z * i}
				if not inside(p, market.rect) or inside(p, hall.rect) then clear = false end
			end
			check("market pavement in front of the hall door", clear)
			for _, other in ipairs({cath.rect, castle.rect, parvis.rect}) do
				check("hall clear of other sites", not overlap(hall.rect, other))
			end
		end
	end
	return out
end

return A
