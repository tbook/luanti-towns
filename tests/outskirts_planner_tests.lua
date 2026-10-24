local eq = ...
local outskirts = dofile("src/outskirts.lua")
local rural = dofile("schematics/outskirts/catalog.lua")
local urban_catalog = dofile("src/catalog.lua")
local urban = urban_catalog.snapshot()
local entries = {}
for id, entry in pairs(urban) do entries[id] = entry end
for id, entry in pairs(rural) do entries[id] = entry end
local fixture = dofile("tests/outskirts_fixture.lua")

local C = outskirts.CONSTANTS
local main_planner = dofile("src/planner.lua")
local medieval_planner = dofile("src/medieval_planner.lua")
for name, value in pairs(fixture.constants) do
	eq(C[name], value, "production constant matches fixture: " .. name)
end
eq(C.FARM_COUNT == 18 and C.HUT_COUNT == 6 and C.VILLA_COUNT == 2 and C.CHAPEL_COUNT == 1,
	true, "production class counts match the contract")
eq(C.FARM_BAND_NEAR == 14 and C.FARM_BAND_FAR == 48 and C.OUTER_BAND_NEAR == 48
	and C.OUTER_BAND_FAR == 116 and C.MIN_SPACING == 20 and C.PROTECT_MARGIN == 4
	and C.PLAYER_MARGIN == 16 and C.ATTEMPTS_PER_BUILDING == 6 and C.SAMPLE_LIMIT == 50,
	true, "production bands and limits match the contract")

local function gap(a, b)
	return math.max(b.x1-a.x2, a.x1-b.x2, b.z1-a.z2, a.z1-b.z2)
end
local bounds = {x1 = 905, z1 = -2086, x2 = 1085, z2 = -1915}
local plan = {town_type = "roman", seed = 8, center = {x = 1000, z = -2000}, bounds = bounds}

-- Independent seeds reproduce the contract's private stream and complete plan.
local rng = outskirts.new_rng(8)
eq(rng.next(), 22928725, "private stream first draw")
eq(outskirts.new_rng(8).int(0, 3) * 90, 90, "first rotation draw")
local function complete(p)
	local s = outskirts.new(p, 8, entries)
	while true do
		local candidate = s:next()
		if not candidate then break end
		s:accept(candidate, {min = 60, max = 62}, 61)
	end
	return s:result(62)
end
local first, again = complete(plan), complete(plan)
eq(first.status, "planned", "accepted plots produce a planned result")
local function signature(result)
	local out = {}
	for _, p in ipairs(result.plots) do
		out[#out + 1] = table.concat({p.id,p.asset,p.rotation,p.rect.x1,p.rect.z1,p.rect.x2,p.rect.z2,p.distance}, ",")
	end
	for _, r in ipairs(result.rejections) do out[#out + 1] = r.subject .. ":" .. r.code end
	return table.concat(out, "|")
end
eq(signature(first), signature(again), "seed reproduces plots and rejection sequence")
eq(fixture.plots[1].rotation, 90, "worked fixture uses a quarter-turn farm")
eq(first.counts.requested.farm, 18, "all farms requested")
eq(first.counts.requested.hut, 6, "all huts requested")
eq(first.counts.requested.villa, 2, "Roman villas requested")
eq(first.counts.requested.chapel, 0, "Roman chapel omitted")
eq(first.counts.planned.farm, #((function() local r={} for _,p in ipairs(first.plots) do if p.class=="farm" then r[#r+1]=p end end return r end)()),
	"farm planned count matches plot list")

for i, p in ipairs(first.plots) do
	eq(p.id, (p.class == "farm" and "f" or p.class == "hut" and "h" or "v") .. (p.id:sub(2)), "stable class id " .. i)
	local near = p.class == "farm"
	local min, max = near and C.FARM_BAND_NEAR or C.OUTER_BAND_NEAR, near and C.FARM_BAND_FAR or C.OUTER_BAND_FAR
	eq(p.distance >= min and p.distance < max, true, p.id .. " stays within its band")
	eq(gap(p.rect, {x1 = bounds.x1-C.PROTECT_MARGIN, z1 = bounds.z1-C.PROTECT_MARGIN,
		x2 = bounds.x2+C.PROTECT_MARGIN, z2 = bounds.z2+C.PROTECT_MARGIN}) > 0, true,
		p.id .. " stays outside protected margin")
	for j = 1, i - 1 do eq(gap(p.rect, first.plots[j].rect) >= C.MIN_SPACING, true, p.id .. " keeps plot spacing") end
	if p.class == "farm" then eq(p.asset, "farm", p.id .. " selects the farm asset")
	elseif p.class == "hut" then eq(p.asset, "shepherd_hut", p.id .. " selects the hut asset")
	else eq(p.asset, "villa", p.id .. " selects the villa asset") end
end

-- Translating the completed urban bounds translates all selected plots exactly.
local shifted = {town_type = "roman", seed = 8, center = {x = 1100, z = -1800},
	bounds = {x1 = bounds.x1+100, z1 = bounds.z1+200, x2 = bounds.x2+100, z2 = bounds.z2+200}}
local moved = complete(shifted)
eq(#moved.plots, #first.plots, "translation preserves planned count")
for i, p in ipairs(first.plots) do
	local q = moved.plots[i]
	eq(q.rect.x1 == p.rect.x1+100 and q.rect.x2 == p.rect.x2+100
		and q.rect.z1 == p.rect.z1+200 and q.rect.z2 == p.rect.z2+200, true, p.id .. " translates")
end

-- The candidate can be handed to terrain inspection and resumed at the next attempt.
local retry = outskirts.new(plan, 8, entries)
local one = assert(retry:next())
local rot, id, attempt = one.rotation, one.id, one.attempt
retry:reject(one, "plot_water", "water under the footprint")
local two = assert(retry:next())
eq(two.id, id, "terrain rejection retries same building")
eq(two.attempt, attempt + 1, "terrain rejection advances bounded attempt")
eq(two.rotation, rot, "rotation is fixed across attempts")
retry:accept(two, {min=61,max=63}, 62)
eq(retry.plots[1], two, "accept records the candidate")
eq(retry.rejections[1].subject, id .. ":a" .. attempt, "rejection identifies attempt")

local bounded = outskirts.new(plan, 8, entries)
local first_rotation
for i = 1, C.ATTEMPTS_PER_BUILDING do
	local candidate = assert(bounded:next())
	if i == 1 then first_rotation = candidate.rotation end
	eq(candidate.id, "f01", "bounded retries stay on first farm")
	eq(candidate.attempt, i, "attempt index is bounded and ordered")
	eq(candidate.rotation, first_rotation, "bounded retries keep one rotation")
	bounded:reject(candidate, "plot_water", "test retry")
end
eq(bounded.counts.rejected.plot_water, C.ATTEMPTS_PER_BUILDING, "all bounded rejections are recorded")
eq(bounded:next().id, "f02", "planner advances after the attempt limit")

-- Exact spatial boundaries and deterministic no-site exhaustion.
local protected = {x0=0,z0=0,x1=10,z1=10,margin=4}
local fits = outskirts.fits
eq(fits({x1=14,z1=0,x2=17,z2=2}, {}, protected, nil), false, "touching protection rejected")
local ok, code = fits({x1=15,z1=20,x2=17,z2=22}, {}, protected, nil)
eq(ok, true, "clear plot accepted")
local player_ok, player_code = fits({x1=40,z1=40,x2=42,z2=42}, {}, protected, {x=25,z=41})
eq(player_ok, false, "plot inside player margin rejected")
eq(player_code, "plot_player", "player boundary reason")
eq(fits({x1=41,z1=40,x2=43,z2=42}, {}, protected, {x=25,z=41}), true,
	"exact PLAYER_MARGIN distance is accepted")
local spacing_ok, spacing_code = fits({x1=38,z1=20,x2=40,z2=22},
	{{rect={x1=20,z1=20,x2=22,z2=22}}}, protected, nil)
eq(spacing_ok, false, "plot closer than exact spacing rejected")
eq(spacing_code, "plot_spacing", "spacing boundary reason")
eq(fits({x1=42,z1=20,x2=44,z2=22}, {{rect={x1=20,z1=20,x2=22,z2=22}}}, protected, nil), true,
	"exact MIN_SPACING is accepted")
local range_ok, range_code = fits({x1=31000,z1=20,x2=31002,z2=22}, {}, protected, nil)
eq(range_ok, false, "coordinates beyond map range rejected")
eq(range_code, "plot_out_of_range", "map range reason")
local draws = 0
local no_site = outskirts.sample({near=10000,far=10001}, {x=9,z=7}, bounds, {
	int = function(a) draws = draws + 1; return a end,
})
eq(no_site, nil, "sample is bounded and can report no site")
eq(draws, C.SAMPLE_LIMIT * 2, "sample stops after the exact draw limit")

local medieval_plan = {town_type = "medieval", seed = 8, center = plan.center, bounds = bounds}
local medieval_result = complete(medieval_plan)
eq(medieval_result.counts.requested.villa, 0, "medieval villas omitted")
eq(medieval_result.counts.requested.chapel, 1, "medieval chapel requested")
for _, p in ipairs(medieval_result.plots) do
	if p.class == "chapel" then eq(p.asset, "chapel", "shared urban chapel asset is selected") end
end

-- Exercise the planner against all 32 real medieval arrangements and ensure
-- it does not alter the accepted urban plan or consume its random stream.
local catalog = dofile("src/catalog.lua")
local profile = assert(main_planner.landmark_profile(catalog.snapshot()))
local function fixed_rng(seed)
	local n = seed
	return {int = function(a, b) n = (n * 1103515245 + 12345) % 2147483648; return a + n % (b-a+1) end}
end
local function urban_signature(p)
	local out = {p.town_type, p.seed, p.center.x, p.center.z,
		p.bounds.x1, p.bounds.z1, p.bounds.x2, p.bounds.z2}
	for _, name in ipairs(p.site_order or {}) do
		local s = p.sites[name]
		out[#out+1] = table.concat({name,s.rotation or "",s.rect.x1,s.rect.z1,s.rect.x2,s.rect.z2}, ":")
	end
	for _, list in ipairs({p.streets or {},p.blocks or {}}) do
		for _, item in ipairs(list) do
			local r = item.rect
			out[#out+1] = table.concat({item.kind or "",item.id or "",r.x1,r.z1,r.x2,r.z2}, ":")
		end
	end
	return table.concat(out, "|")
end
local arrangements = {}
for quadrant = 0, 3 do
	for _, castle_east in ipairs({false, true}) do
		for turn = 0, 270, 90 do
			local real_plan = assert(medieval_planner.plan({x=320,z=-640}, 8, profile, fixed_rng(8),
				{quadrant=quadrant,castle_east=castle_east,turn=turn}))
			local before = urban_signature(real_plan)
			local rural_state = outskirts.new(real_plan, 8, entries)
			local candidate = assert(rural_state:next())
		rural_state:accept(candidate, {min=60,max=62}, 61)
			local after = urban_signature(real_plan)
			eq(after, before, "outskirts leaves real medieval urban plan unchanged")
			arrangements[quadrant .. ":" .. tostring(castle_east) .. ":" .. turn] = true
		end
	end
end
local arrangement_count = 0
for _ in pairs(arrangements) do arrangement_count = arrangement_count + 1 end
eq(arrangement_count, 32, "all real medieval arrangements are covered")

local real_roman_before = assert(main_planner.plan({x=320,z=-640}, 11, {town_type="roman"}))
local roman_signature = urban_signature(real_roman_before)
local real_roman_after = assert(main_planner.plan({x=320,z=-640}, 11, {town_type="roman"}))
local roman_state = outskirts.new(real_roman_after, 11, entries)
local roman_candidate = assert(roman_state:next())
roman_state:accept(roman_candidate, {min=60,max=62}, 61)
eq(urban_signature(real_roman_after), roman_signature, "outskirts leaves real Roman urban plan unchanged")

local empty_plan = {town_type = "roman", center = plan.center, bounds = {x1=0,z1=0,x2=2,z2=2}}
local empty_state = outskirts.new(empty_plan, 8, entries)
while true do
	local candidate = empty_state:next()
	if not candidate then break end
	empty_state:reject(candidate, "plot_water", "test omission")
end
local empty = empty_state:result(62)
eq(empty.status, "empty", "no accepted plots produce empty status")
eq(#empty.rejections > 0, true, "omissions are recorded")
