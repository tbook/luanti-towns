-- Chunk-cap sweep for A12 (#392): for N seeds per family, build the #393 envelope from the real
-- planner and the real Living Villages volume queries, and count distinct engine chunks at
-- every alignment of the town to the chunk grid (steps of STEP nodes on each axis). Pure Lua
-- 5.1, no world. Run from the mod root:
--   TOWNS_LIVING_VILLAGES=/path/to/living_villages lua5.1 tools/auto_towns_containment/cap_sweep.lua [N] [STEP]
local N = tonumber(arg and arg[1]) or 100
local STEP = tonumber(arg and arg[2]) or 8
local lv_path = assert(os.getenv("TOWNS_LIVING_VILLAGES"), "set TOWNS_LIVING_VILLAGES to a living_villages checkout")
local ab = dofile("src/auto_bounds.lua")
local geometry = dofile("src/geometry.lua")
local catalog = dofile("src/catalog.lua")
local placement = dofile("src/placement.lua")
local planner = dofile("src/planner.lua")
local walls = dofile("src/medieval_walls.lua")
local features = dofile("src/medieval_wall_features.lua")
local rural = dofile("schematics/outskirts/catalog.lua")

minetest = {get_modpath = function() return lv_path end}
local smoothing = dofile(lv_path .. "/village_smoothing.lua")
local engine = {registered_nodes = {}}
local VILLAGE = {
	{name = "belltower", hwidth = 5, hdepth = 5, hheight = 9}, {name = "large_house", hwidth = 12, hdepth = 12, hheight = 9},
	{name = "blacksmith", hwidth = 8, hdepth = 11, hheight = 13}, {name = "butcher", hwidth = 12, hdepth = 8, hheight = 10},
	{name = "church", hwidth = 13, hdepth = 13, hheight = 14}, {name = "farm", hwidth = 9, hdepth = 7, hheight = 13},
	{name = "lamp", hwidth = 3, hdepth = 4, hheight = 13}, {name = "library", hwidth = 12, hdepth = 12, hheight = 8},
	{name = "medium_house", hwidth = 9, hdepth = 12, hheight = 8}, {name = "small_house", hwidth = 9, hdepth = 8, hheight = 8},
	{name = "tavern", hwidth = 12, hdepth = 10, hheight = 10}, {name = "well", hwidth = 6, hdepth = 8, hheight = 6},
}
local outskirts = {}
for _, id in ipairs({"farm", "shepherd_hut", "villa"}) do outskirts[#outskirts + 1] = {id = id, size = rural[id].size} end
outskirts[#outskirts + 1] = {id = "chapel", size = catalog.entries.chapel.size}
local wf_assets = {}
for id, e in pairs(catalog.entries) do
	if id:match("^wall_") and e.size then wf_assets[#wf_assets + 1] = {id = id, size = e.size} end
end
local config = ab.default_config()
config.village = {cell = 16, max_cells = 5, relocate_step = 8, relocate_rings = 4, radius_jitter = 2}
local env = assert(ab.new({config = config, assets = {outskirts = outskirts, village = VILLAGE, wall_features = wf_assets},
	volume = {terrain = function(p, s, o) return smoothing.volume(p, s, o, engine) end,
		boundary = function(r, g, o) return smoothing.boundary_volume(r, g, o) end}}))
local profile = assert(planner.landmark_profile(catalog.snapshot()))

local function state_for(plan, wall, wf, ground)
	return {plan = plan, center = plan.center, ground_y = ground, reference_y = ground, wall = wall, wall_features = wf,
		build_bounds = {min = {x = plan.bounds.x1, y = ground - 24, z = plan.bounds.z1},
			max = {x = plan.bounds.x2, y = ground + 40, z = plan.bounds.z2}}}
end

local function shifted(e, dx, dy, dz)
	local boxes = {}
	for _, s in pairs(e.stages) do
		local b = s.box
		boxes[#boxes + 1] = {min = {x = b.min.x + dx, y = b.min.y + dy, z = b.min.z + dz},
			max = {x = b.max.x + dx, y = b.max.y + dy, z = b.max.z + dz}}
	end
	return boxes
end

local function base(name) return (name:gsub("%[%d+%]$", "")) end
local function overhang(e, pb)
	local out = {}
	for name, st in pairs(e.stages) do
		if st.kind == "write" then
			local b = st.box
			local o = math.max(pb.x1 - b.min.x, b.max.x - pb.x2, pb.z1 - b.min.z, b.max.z - pb.z2, 0)
			out[base(name)] = math.max(out[base(name)] or 0, o)
		end
	end
	return out
end

local families = {"medieval-walled", "medieval-unwalled", "roman"}
local grand_max, grand_aligned_max, over_cap = 0, 0, 0
for _, family in ipairs(families) do
	local fam_max, fam_aligned_max, declined = 0, 0, 0
	local fam_over = {}
	local shown
	for seed = 1, N do
		local plan, wall, wf
		if family == "roman" then
			plan = planner.plan({x = 0, z = 0}, seed, {town_type = "roman"})
		else
			plan = planner.plan({x = 0, z = 0}, seed, {landmarks = profile, force_walls = family == "medieval-walled"})
		end
		plan.center = {x = 0, z = 0}
		if family == "medieval-walled" then
			wall = walls.plan(plan, true)
			wf = {}
			if wall then
				local cands = features.candidates(wall, 64, catalog.entries, walls, function() end)
				wf = features.select(cands, {}, plan.streets, function() return false end) or {}
			end
		end
		for _, ground in ipairs({64}) do
			local e, why, code = env.plan_envelope(state_for(plan, wall, wf, ground))
			if not e then
				declined = declined + 1
				if not shown then shown = (code or "?") .. ": " .. tostring(why); print("DECLINED", family, seed, shown) end
			else
				fam_aligned_max = math.max(fam_aligned_max, e.chunks)
				for stage, o in pairs(overhang(e, plan.bounds)) do fam_over[stage] = math.max(fam_over[stage] or 0, o) end
				for dx = 0, 79, STEP do
					for dz = 0, 79, STEP do
						for dy = 0, 79, STEP do
							local n = ab.chunk_accounting(shifted(e, dx, dy, dz)).chunks
							if n > fam_max then fam_max = n end
						end
					end
				end
			end
		end
	end
	print(("%-18s seeds=%d declined=%d  chunks at the planner origin alignment: max %d   max over all alignments: %d"):format(
		family, N, declined, fam_aligned_max, fam_max))
	local names = {}
	for stage in pairs(fam_over) do names[#names + 1] = stage end
	table.sort(names)
	local parts = {}
	for _, stage in ipairs(names) do
		parts[#parts + 1] = ("%s %d/%d"):format(stage, fam_over[stage], env.stage_reach[stage] or -1)
	end
	print("  stage box overhang beyond plan.bounds, max / stage_reach: " .. table.concat(parts, ", "))
	grand_max, grand_aligned_max = math.max(grand_max, fam_max), math.max(grand_aligned_max, fam_aligned_max)
end
print(("overall: origin alignment max %d, any alignment max %d, cap %d, snapshot cap %d voxels (%d chunks)"):format(
	grand_aligned_max, grand_max, ab.CAPS.MAX_REQUEST_CHUNKS, ab.CAPS.MAX_SNAPSHOT_VOXELS,
	ab.CAPS.MAX_SNAPSHOT_VOXELS / ab.CHUNK_VOXELS))
