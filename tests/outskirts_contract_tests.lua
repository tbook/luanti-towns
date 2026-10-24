-- Outskirts v1 contract checks (issue #226). Loaded by tests/run.lua:
--   loadfile("tests/outskirts_contract_tests.lua")(eq, fails, planner, catalog, geometry)
--
-- Not production code. It checks that
--   * docs/outskirts_design.md quotes every constant and rejection code;
--   * the constants agree with each other and fit the real town sizes;
--   * the worked example (tests/outskirts_fixture.lua) is consistent with
--     src/geometry.lua, the real Roman plan and the private random stream;
--   * the installed VoxeLibre schematics really have the sizes, door and
--     workstations the document states (skipped when the game is not found;
--     set TOWNS_MCL_VILLAGES to its mcl_villages/schematics directory);
--   * Living Villages (skipped when not found; set TOWNS_LIVING_VILLAGES, else
--     a living_villages directory up to six levels above the current one is
--     used) still has the footprint rule and defaults the contract relies on.
local eq, fails, planner, catalog, geometry = ...
local F = dofile("tests/outskirts_fixture.lua")
local medieval = dofile("src/medieval_planner.lua")
local C = F.constants

local function slurp(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

------------------------------------------------------------------------
-- The document quotes the constants and the rejection codes.
------------------------------------------------------------------------
local doc = slurp("docs/outskirts_design.md")
eq(doc ~= nil, true, "docs/outskirts_design.md exists")
doc = doc or ""
local names = {}
for k in pairs(C) do names[#names + 1] = k end
table.sort(names)
for _, k in ipairs(names) do
	local want = ("%s = %s"):format(k, tostring(C[k]))
	eq(doc:find(want, 1, true) ~= nil, true, "document freezes " .. want)
end
for _, code in ipairs(F.rejection_codes) do
	eq(doc:find("`" .. code .. "`", 1, true) ~= nil, true, "document lists rejection code " .. code)
end

------------------------------------------------------------------------
-- Constants agree with each other and with the real town sizes.
------------------------------------------------------------------------
eq(C.FARM_BAND_NEAR < C.FARM_BAND_FAR and C.FARM_BAND_FAR <= C.OUTER_BAND_NEAR
	and C.OUTER_BAND_NEAR < C.OUTER_BAND_FAR, true, "the two bands are ordered, farms nearer")
eq(C.FARM_BAND_NEAR >= C.PROTECT_MARGIN + C.TERRAFORM_REACH, true,
	"the nearest plot's terraform reach stays outside the protected rectangle")
eq(C.MIN_SPACING >= 2 * C.TERRAFORM_REACH, true, "neighbouring plots' terraform reaches do not overlap")
eq(C.PLAYER_MARGIN >= C.TERRAFORM_REACH, true, "the player is outside a plot's terraform reach")

-- Capacity: each band holds at least twice its buildings at the packing density
-- MIN_SPACING implies (a coarse check; the real planner may place fewer).
do
	local function ring_area(b, near, far)
		local w, h = b.x2 - b.x1 + 1, b.z2 - b.z1 + 1
		return (w + 2 * far) * (h + 2 * far) - (w + 2 * near) * (h + 2 * near)
	end
	local function check(label, b)
		local cell = (9 + C.MIN_SPACING) ^ 2
		eq(ring_area(b, C.FARM_BAND_NEAR, C.FARM_BAND_FAR) / cell >= 2 * C.FARM_COUNT, true,
			label .. ": near band holds twice the farms")
		eq(ring_area(b, C.OUTER_BAND_NEAR, C.OUTER_BAND_FAR) / cell
			>= 2 * (C.HUT_COUNT + C.VILLA_COUNT + C.CHAPEL_COUNT), true, label .. ": far band holds twice the rest")
	end
	check("roman", assert(planner.plan({x = 0, z = 0}, 1, {town_type = "roman"})).bounds)
	local profile = assert(planner.landmark_profile(catalog.snapshot()))
	local function fixed_rng(seed)
		local n = seed
		return {int = function(a, b) n = (n * 1103515245 + 12345) % 2147483648; return a + n % (b - a + 1) end}
	end
	for _, turn in ipairs({0, 90}) do
		local plan = assert(medieval.plan({x = 0, z = 0}, 1, profile, fixed_rng(1), {turn = turn}))
		check("medieval turn " .. turn, plan.bounds)
	end
end

------------------------------------------------------------------------
-- Private random stream.
------------------------------------------------------------------------
do
	local state = (F.rng.seed * 31 + C.SALT) % 2147483646 + 1
	for i, want in ipairs(F.rng.first) do
		state = state * 48271 % 2147483647
		eq(state, want, "random stream value " .. i)
	end
	eq(F.rng.first[1] % 4 * 90, 90, "the first draw rotates the first building by 90")
end

------------------------------------------------------------------------
-- Worked example.
------------------------------------------------------------------------
local roman = assert(planner.plan(F.town.center, F.town.seed, {town_type = "roman"}))
local b = roman.bounds
eq(b.x1 == F.bounds.x1 and b.z1 == F.bounds.z1 and b.x2 == F.bounds.x2 and b.z2 == F.bounds.z2, true,
	"the Roman plan.bounds at this centre")
local P = F.protected
eq(P.x1 == b.x1 - C.PROTECT_MARGIN and P.z1 == b.z1 - C.PROTECT_MARGIN
	and P.x2 == b.x2 + C.PROTECT_MARGIN and P.z2 == b.z2 + C.PROTECT_MARGIN, true,
	"protected rectangle = plan.bounds + PROTECT_MARGIN")

local function distance(bounds, r)
	return math.max(bounds.x1 - r.x2, r.x1 - bounds.x2, bounds.z1 - r.z2, r.z1 - bounds.z2)
end
local function gap(a, c)
	return math.max(a.x1 - c.x2, c.x1 - a.x2, a.z1 - c.z2, c.z1 - a.z2)
end
local function overlap(a, c) return a.x1 <= c.x2 and c.x1 <= a.x2 and a.z1 <= c.z2 and c.z1 <= a.z2 end

local band_of = {
	near = {C.FARM_BAND_NEAR, C.FARM_BAND_FAR},
	far = {C.OUTER_BAND_NEAR, C.OUTER_BAND_FAR},
}
for i, plot in ipairs(F.plots) do
	local label = plot.id
	local asset = F.assets[plot.asset]
	local st = F.structures[i]
	eq(st.plot, plot.id, label .. " structure plot")
	-- Rect = rotated footprint at the schematic origin (ground - ground_offset).
	local entry = {size = asset.size, entrance = asset.entrance or {x = 0, y = 1, z = 0}}
	local origin = {x = plot.rect.x1, y = plot.ground_y - asset.ground_offset, z = plot.rect.z1}
	local p = geometry.place(entry, origin, plot.rotation)
	eq(p.max.x, plot.rect.x2, label .. " rect x2 = rotated footprint")
	eq(p.max.z, plot.rect.z2, label .. " rect z2 = rotated footprint")
	eq(st.min.y == p.min.y and st.max.y == p.max.y and st.max.x == p.max.x and st.max.z == p.max.z, true,
		label .. " structure box")
	eq(st.size.x == p.size.x and st.size.z == p.size.z and st.size.y == p.size.y, true, label .. " structure size")
	eq(st.site_ground_y, plot.ground_y, label .. " site ground")
	if asset.entrance then
		eq(st.entrance.x == p.entrance.x and st.entrance.y == p.entrance.y and st.entrance.z == p.entrance.z, true,
			label .. " entrance node")
		eq(st.front.x == p.front.x and st.front.z == p.front.z, true, label .. " front")
		eq(st.entrance.y, st.min.y + asset.entrance.y, label .. " entrance feet = origin + entrance.y")
	else
		eq(st.kind, "object", label .. " has no door: composed as an object")
	end
	-- Band, distance, protection, spacing.
	eq(distance(F.bounds, plot.rect), plot.distance, label .. " distance to plan.bounds")
	local band = band_of[plot.band]
	eq(plot.distance >= band[1] and plot.distance < band[2], true, label .. " lies in its band")
	eq(overlap(plot.rect, P), false, label .. " lies outside the protected rectangle")
	eq(gap(plot.rect, P) >= C.TERRAFORM_REACH, true, label .. " terraform reach clears the protected rectangle")
	eq(plot.heights.max - plot.heights.min <= C.MAX_SPREAD, true, label .. " footprint spread")
	eq(plot.ground_y >= plot.heights.min and plot.ground_y <= plot.heights.max, true, label .. " ground inside the heights")
end
eq(F.plots[1].class, "farm", "the farm is in the near band")
eq(gap(F.plots[1].rect, F.plots[2].rect) >= C.MIN_SPACING, true, "plots keep MIN_SPACING")

-- Living Villages call data.
for i, call in ipairs(F.lv_calls) do
	local plot, asset = F.plots[i], F.assets[F.plots[i].asset]
	local entry, sch = call.plan[1], call.schematics[1]
	eq(entry.name, sch.name, call.plot_id .. " plan and schematic table name the same asset")
	eq(entry.pos.y, plot.ground_y, call.plot_id .. " pad y is the site ground Y")
	eq(entry.pos.x == plot.rect.x1 and entry.pos.z == plot.rect.z1, true, call.plot_id .. " pos is the minimum corner")
	eq(sch.hwidth == asset.size.x and sch.hdepth == asset.size.z and sch.hheight == asset.size.y, true,
		call.plot_id .. " schematic table holds the file size")
	-- The Living Villages footprint rule (village_terrain.footprint).
	local rotated = entry.rotat == "90" or entry.rotat == "270"
	local w, d = rotated and sch.hdepth or sch.hwidth, rotated and sch.hwidth or sch.hdepth
	eq(entry.pos.x + w - 1 == plot.rect.x2 and entry.pos.z + d - 1 == plot.rect.z2, true,
		call.plot_id .. " Living Villages footprint = plot rect")
	eq(entry.rotat, tostring(plot.rotation), call.plot_id .. " rotation")
end
do
	local box = F.lv_result.box
	local r = {x1 = box.min.x, z1 = box.min.z, x2 = box.max.x, z2 = box.max.z}
	local f = F.plots[1].rect
	eq(r.x1 <= f.x1 and r.z1 <= f.z1 and r.x2 >= f.x2 and r.z2 >= f.z2, true, "written box contains the footprint")
	eq(overlap(r, P), false, "written box stays outside the protected rectangle")
	eq(F.lv_result.stats.cut + F.lv_result.stats.filled, F.lv_result.stats.changed - 0, "cut + filled = changed (illustrative)")
end

-- Counts.
for _, class in ipairs({"farm", "hut", "villa", "chapel"}) do
	eq(F.counts.planned[class] <= F.counts.requested[class], true, class .. " planned <= requested")
end
eq(F.counts.requested.farm, C.FARM_COUNT, "requested farms")
eq(F.counts.requested.hut, C.HUT_COUNT, "requested huts")
eq(F.counts.requested.villa, C.VILLA_COUNT, "a Roman town asks for villas")
eq(F.counts.requested.chapel, 0, "...and no chapel")
do
	local short = 0
	for _, class in ipairs({"farm", "hut", "villa", "chapel"}) do
		short = short + F.counts.requested[class] - F.counts.planned[class]
	end
	local rejected = 0
	for _, n in pairs(F.counts.rejected) do rejected = rejected + n end
	eq(rejected >= short, true, "every missing building has at least one recorded rejection")
	local known = {}
	for _, code in ipairs(F.rejection_codes) do known[code] = true end
	for code in pairs(F.counts.rejected) do eq(known[code], true, "rejection " .. code .. " is documented") end
end

------------------------------------------------------------------------
-- Installed VoxeLibre schematics (optional).
------------------------------------------------------------------------
do
	local home = os.getenv("HOME") or ""
	local candidates = {
		home .. "/Library/Application Support/minetest/games/mineclone2/mods/MAPGEN/mcl_villages/schematics",
		home .. "/.minetest/games/mineclone2/mods/MAPGEN/mcl_villages/schematics",
	}
	if os.getenv("TOWNS_MCL_VILLAGES") then table.insert(candidates, 1, os.getenv("TOWNS_MCL_VILLAGES")) end
	local dir
	for _, d in ipairs(candidates) do
		if slurp(d .. "/farm.mts") then dir = d; break end
	end
	if not dir then
		print("SKIP outskirts contract: VoxeLibre mcl_villages schematics not found (set TOWNS_MCL_VILLAGES)")
	else
		local read = dofile("tests/mts_reader.lua")
		local function find(s, name)
			local out = {}
			for y = 0, s.size.y - 1 do
				for z = 0, s.size.z - 1 do
					for x = 0, s.size.x - 1 do
						if (s.at(x, y, z)) == name then out[#out + 1] = {x = x, y = y, z = z} end
					end
				end
			end
			return out
		end
		local farm = read(dir .. "/farm.mts")
		local hut = read(dir .. "/small_house.mts")
		local fa, ha = F.assets.farm, F.assets.shepherd_hut
		eq(farm.size.x == fa.size.x and farm.size.y == fa.size.y and farm.size.z == fa.size.z, true, "farm.mts size")
		eq(hut.size.x == ha.size.x and hut.size.y == ha.size.y and hut.size.z == ha.size.z, true, "small_house.mts size")
		local comp = find(farm, "mcl_composters:composter")
		eq(#comp, 1, "the farm holds one composter")
		eq(comp[1] and comp[1].x == fa.composter.x and comp[1].y == fa.composter.y and comp[1].z == fa.composter.z, true,
			"composter position")
		eq(#find(farm, "mcl_beds:bed_red_bottom"), 0, "the farm has no bed")
		local loom, bed, door = find(hut, "mcl_loom:loom"), find(hut, "mcl_beds:bed_red_bottom"), find(hut, "mcl_doors:wooden_door_b_1")
		eq(#loom, 1, "the hut holds one loom")
		eq(loom[1] and loom[1].x == ha.loom.x and loom[1].y == ha.loom.y and loom[1].z == ha.loom.z, true, "loom position")
		eq(#bed, 1, "the hut holds one bed")
		eq(bed[1] and bed[1].x == ha.bed.x and bed[1].y == ha.bed.y and bed[1].z == ha.bed.z, true, "bed position")
		eq(#door, 1, "the hut has one door")
		eq(door[1] and door[1].x == ha.entrance.x and door[1].y == ha.entrance.y and door[1].z == ha.entrance.z, true,
			"door position = the entrance")
		eq(hut.at(0, 0, 0), "mcl_core:dirt", "the hut's layer 0 is the dirt ground row")
		eq(farm.at(0, 0, 0), "mcl_core:dirt", "the farm's layer 0 is the dirt ground row")
	end
end

------------------------------------------------------------------------
-- Living Villages (optional): the current state the contract builds on.
------------------------------------------------------------------------
do
	local candidates = {}
	for n = 1, 6 do candidates[#candidates + 1] = ("../"):rep(n) .. "living_villages" end
	local from_env = os.getenv("TOWNS_LIVING_VILLAGES")
	if from_env then table.insert(candidates, 1, from_env) end
	local lv
	for _, path in ipairs(candidates) do
		if slurp(path .. "/village_smoothing.lua") then lv = path; break end
	end
	if not lv then
		print("SKIP outskirts contract: Living Villages not found (set TOWNS_LIVING_VILLAGES)")
		return
	end
	local saved = rawget(_G, "minetest")
	rawset(_G, "minetest", {get_modpath = function(name)
		assert(name == "living_villages")
		return lv
	end})
	local ok, smoothing = pcall(dofile, lv .. "/village_smoothing.lua")
	local okt, terrain = pcall(dofile, lv .. "/village_terrain.lua")
	rawset(_G, "minetest", saved)
	if not (ok and okt) then
		-- The mod may be mid-edit (the API issues are being implemented there).
		print("SKIP outskirts contract: Living Villages did not load: " .. tostring(ok and terrain or smoothing))
		return
	end
	eq(type(smoothing.terraform), "function", "village_smoothing.terraform(plan, pr, env, config) exists")
	local cfg = smoothing.config
	eq(cfg.margin + cfg.radius, C.TERRAFORM_REACH, "default margin + radius = TERRAFORM_REACH")
	for i, call in ipairs(F.lv_calls) do
		local box = terrain.footprint({name = call.plan[1].name, pos = call.plan[1].pos, rotat = call.plan[1].rotat},
			call.schematics)
		local rect = F.plots[i].rect
		eq(box ~= nil and box.minp.x == rect.x1 and box.minp.z == rect.z1 and box.maxp.x == rect.x2
			and box.maxp.z == rect.z2, true, call.plot_id .. ": village_terrain.footprint equals the plot rect")
		eq(box and box.height, call.schematics[1].hheight, call.plot_id .. ": footprint height")
	end
end
