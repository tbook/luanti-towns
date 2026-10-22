-- Roman civic plan: counts, separation, connectivity and invariance (issue #148).
local eq, fails, planner = ...
local roman = dofile("src/roman_planner.lua")

local function copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = copy(v) end
	return out
end
local function plan_at(x, z, seed)
	local plan, why = planner.plan({x = x, z = z}, seed, {town_type = "roman"})
	assert(plan, why)
	return plan
end
local function overlap(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end
local function landmarks(plan)
	local list = {}
	for _, name in ipairs(plan.site_order) do
		if plan.sites[name].kind == "landmark" then list[#list + 1] = plan.sites[name] end
	end
	return list
end

local plan = plan_at(100, -50, 7)
eq(plan.town_type, "roman", "Roman plan carries its town type")
eq(planner.validate(plan), true, "selected Roman plan passes authored validation")

-- Exact monument census: 13 placements from six templates.
local list = landmarks(plan)
eq(#list, 13, "13 monument placements")
local counts, names, n = {}, {}, 0
for _, s in ipairs(list) do
	counts[s.id] = (counts[s.id] or 0) + 1
	eq(names[s.name], nil, s.name .. " name is unique")
	names[s.name] = true
	eq(plan.sites[s.name], s, s.name .. " is keyed by its own name")
end
for id, want in pairs({arch = 4, temple = 2, domus = 4, theatre = 1, amphitheater = 1, bath = 1}) do
	eq(counts[id], want, id .. " count")
	n = n + 1
end
eq(n, 6, "six templates")
eq(#plan.site_order, 14, "forum plus 13 monuments in site order")

-- Arms: the theatre and amphitheater differ, and the bath uses the south arm.
eq(plan.sites.theatre.arm, "west", "theatre on the west arm")
eq(plan.sites.amphitheater.arm, "north", "amphitheater on the north arm")
eq(plan.sites.bath.arm, "south", "bath on the south arm")
for _, name in ipairs({"temple_east", "temple_west"}) do
	eq(plan.sites[name].arm, "north", name .. " beside the cardo")
	local r, f = plan.sites[name].rect, plan.sites.forum.rect
	eq(r.z1 - f.z2 <= 5, true, name .. " is near the forum")
end

-- No overlaps among monuments, forum and streets; all inside the boundary.
local solids = {}
for _, name in ipairs(plan.site_order) do solids[#solids + 1] = plan.sites[name] end
for i = 1, #solids do
	local r = solids[i].rect
	local b = plan.boundary.rects[1]
	eq(r.x1 >= b.x1 and r.z1 >= b.z1 and r.x2 <= b.x2 and r.z2 <= b.z2, true,
		solids[i].name .. " inside the construction boundary")
	for j = i + 1, #solids do
		eq(overlap(r, solids[j].rect), false, solids[i].name .. " / " .. solids[j].name .. " disjoint")
	end
end
eq(#plan.streets, 4, "four street arms")
for _, st in ipairs(plan.streets) do
	for _, s in ipairs(list) do
		eq(overlap(st.rect, s.rect), false, st.name .. " does not enter " .. s.name)
	end
end
for i = 1, #plan.streets do for j = i + 1, #plan.streets do
	eq(overlap(plan.streets[i].rect, plan.streets[j].rect), false, "streets are disjoint")
end end

-- Pavement: every approach node is paved and connected to the forum.
local paved = {}
local function pave(r)
	for z = r.z1, r.z2 do for x = r.x1, r.x2 do paved[x .. "," .. z] = true end end
end
pave(plan.sites.forum.rect)
for _, st in ipairs(plan.streets) do pave(st.rect) end
local seen, queue = {}, {{plan.sites.forum.approach.pos.x, plan.sites.forum.approach.pos.z}}
seen[queue[1][1] .. "," .. queue[1][2]] = true
local qi = 1
while qi <= #queue do
	local p = queue[qi]; qi = qi + 1
	for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
		local x, z = p[1] + d[1], p[2] + d[2]
		local k = x .. "," .. z
		if paved[k] and not seen[k] then seen[k] = true; queue[#queue + 1] = {x, z} end
	end
end
for _, s in ipairs(list) do
	local k = s.approach.pos.x .. "," .. s.approach.pos.z
	eq(paved[k], true, s.name .. " approach is paved")
	eq(seen[k], true, s.name .. " approach reaches the forum")
end

-- Each street ends at its arch's near face with the opening on the centreline.
local cx, cz = plan.center.x, plan.center.z
local by_arm = {}
for _, st in ipairs(plan.streets) do by_arm[st.arm] = st end
for arm, st in pairs(by_arm) do
	local arch = plan.sites[roman.layout.arms[arm].arch]
	local a = arch.approach.pos
	eq(st.rect.x1 <= a.x and a.x <= st.rect.x2 and st.rect.z1 <= a.z and a.z <= st.rect.z2, true,
		arm .. " arch approach lies on its street")
	local step = ({north = {0, 1}, south = {0, -1}, east = {1, 0}, west = {-1, 0}})[arm]
	eq(paved[(a.x + step[1]) .. "," .. (a.z + step[2])], nil, arm .. " street stops at the arch")
	eq(arch.facing.x, -step[1], arm .. " arch faces the forum x")
	eq(arch.facing.z, -step[2], arm .. " arch faces the forum z")
	local lateral = step[1] == 0 and a.x - cx or a.z - cz
	eq(lateral == -1 or lateral == 0, true, arm .. " arch opening sits mid-street")
	local entry = dofile("src/catalog.lua").entries.arch
	eq(arch.size.x * arch.size.z, entry.size.x * entry.size.z, arm .. " arch uses the full catalog box")
end

-- Doors face their streets, including the recessed temple and bath doors.
for _, name in ipairs({"temple_east", "temple_west", "bath"}) do
	local s = plan.sites[name]
	local e, a = s.entrance, s.approach.pos
	eq(overlap(s.rect, {x1 = a.x, z1 = a.z, x2 = a.x, z2 = a.z}), false,
		name .. " approach is outside its box")
	eq((a.x - e.x) * s.facing.x + (a.z - e.z) * s.facing.z > 1, true, name .. " door is recessed")
end

-- Same arrangement for every seed; a different centre only translates it.
local function normalise(p, dx, dz)
	local out = copy(p)
	out.seed, out.center = nil, nil
	local function shift(t)
		if type(t) ~= "table" then return end
		for _, k in ipairs({"x", "x1", "x2"}) do if t[k] then t[k] = t[k] - dx end end
		for _, k in ipairs({"z", "z1", "z2"}) do if t[k] then t[k] = t[k] - dz end end
		for k, v in pairs(t) do
			if k ~= "size" and k ~= "facing" and k ~= "width" and k ~= "depth" then shift(v) end
		end
	end
	shift(out)
	return out
end
local function same(a, b, path, bad)
	if type(a) ~= "table" or type(b) ~= "table" then
		if a ~= b then bad[#bad + 1] = path end
		return
	end
	for k, v in pairs(a) do same(v, b[k], path .. "." .. tostring(k), bad) end
	for k in pairs(b) do if a[k] == nil then bad[#bad + 1] = path .. "." .. tostring(k) end end
end
local base = normalise(plan, 100, -50)
for _, c in ipairs({{100, -50, 123456}, {100, -50, 1}, {-3000, 777, 42}, {0, 0, 0}}) do
	local other = normalise(plan_at(c[1], c[2], c[3]), c[1], c[2])
	local bad = {}
	same(base, other, "plan", bad)
	eq(#bad, 0, ("civic geometry identical at (%d,%d) seed %d %s"):format(c[1], c[2], c[3], bad[1] or ""))
end
eq(plan_at(0, 0, 9).seed, 9, "seed is recorded")

-- Bad layouts are reported, not built.
local bad_layout = copy(roman.layout)
bad_layout.landmarks[1].rotation = 90
local none, why = roman.plan({x = 0, z = 0}, 1, bad_layout)
eq(none, nil, "a door turned away from its street is rejected")
eq(why:find("does not face its street", 1, true) ~= nil, true, "rotation mismatch reason")
bad_layout = copy(roman.layout)
bad_layout.landmarks[1].at = bad_layout.landmarks[4].at
none, why = roman.plan({x = 0, z = 0}, 1, bad_layout)
eq(none, nil, "overlapping monuments fail validation")
eq(why:find("overlap", 1, true) ~= nil, true, "overlap reason")

-- Input checks are shared with the medieval entry point; medieval stays default.
fails(function() planner.plan({x = 0.5, z = 0}, 1, {town_type = "roman"}) end,
	"site_center", "Roman planning checks the centre")
fails(function() planner.plan({x = 0, z = 0}, 2 ^ 40, {town_type = "roman"}) end,
	"seed", "Roman planning checks the seed")
local medieval = planner.plan({x = 0, z = 0}, 1)
eq(medieval.town_type, "medieval", "default town type remains medieval")
eq(medieval.sites.cathedral ~= nil, true, "default plan keeps medieval civic sites")
