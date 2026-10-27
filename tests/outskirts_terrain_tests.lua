local eq = ...
local terrain = dofile("src/outskirts_terrain.lua")
local F = dofile("tests/outskirts_fixture.lua")
local plot, entry = F.plots[1], dofile("schematics/outskirts/catalog.lua").farm

local available, missing_code = terrain.available(nil)
eq(available, false, "missing Living Villages terrain API is unavailable")
eq(missing_code, "outskirts_dependency", "missing terrain API is a dependency failure")
eq(terrain.available({volume = function() end}), false, "both terrain methods are required")
local api = {volume = function() return {minp = {}, maxp = {}} end, terraform = function() return true, {} end}
eq(terrain.available(api), true, "public terrain API is available")

local plan, schematics, protected = terrain.mapping(plot, entry, F.bounds)
local p = plan[1]
eq(p.name, "farm", "mapped plan names catalog entry")
eq(p.pos.x == plot.rect.x1 and p.pos.y == plot.ground_y and p.pos.z == plot.rect.z1, true,
	"mapped plan uses plot minimum and ground")
eq(p.rotat, "90", "mapped rotation uses Living Villages spelling")
eq(schematics[1].hwidth == 17 and schematics[1].hdepth == 13 and schematics[1].hheight == 2, true,
	"mapped schematic dimensions use catalog size")
eq(protected.margin, 4, "protected rectangle carries the margin once")

local candidate = {{name = "farm", pos = {x = 10, z = 20}, rotat = "0"}}
local opts = {surface_y = {min = 14, max = 110}}
local volume_calls, volume_result = 0, {minp = {x = 0}, maxp = {x = 16}}
api.volume = function(got_plan, got_schematics, got_options)
	volume_calls = volume_calls + 1
	eq(got_plan, candidate, "volume receives candidate plan")
	eq(got_schematics, schematics, "volume receives schematic table")
	eq(got_options, opts, "volume receives caller options")
	return volume_result
end
local queried = terrain.volume(api, candidate, schematics, opts)
eq(queried, volume_result, "volume result is passed through")
eq(volume_calls, 1, "volume is queried once")

local call, call_count
api.terraform = function(...) call, call_count = {...}, select("#", ...); return true, {unloaded_blocks = 0} end
local ok = terrain.terraform(api, plan, schematics, protected)
eq(ok, true, "successful terraform stats are accepted")
eq(call_count, 3, "terraform uses the public three-argument API")
eq(call[1], plan, "terraform receives the single plot plan")
eq(call[3].schematic_table, schematics, "schematic table is passed in options")
eq(call[3].protected[1], protected, "protected rectangle is passed as the API list")

api.terraform = function() return true, {unloaded_blocks = 0, written = {
	minp = {x = 1090, y = 40, z = -2100}, maxp = {x = 1100, y = 60, z = -2095},
}} end
eq(terrain.terraform(api, plan, schematics, protected), true, "writes outside protection are accepted")

api.terraform = function() return false, "no surface" end
local result, code, reason = terrain.terraform(api, plan, schematics, protected)
eq(result, nil, "decline is an omission")
eq(code, "terraform_declined", "decline omission code")
eq(reason, "no surface", "decline reason is preserved")

api.terraform = function() return true, {unloaded_blocks = 2} end
result, code = terrain.terraform(api, plan, schematics, protected)
eq(result, nil, "unloaded blocks are an omission")
eq(code, "terraform_incomplete", "unloaded omission code")

local safe_corner_writes = {
	{x = F.bounds.x1 - protected.margin - 1, z = F.bounds.z1 - protected.margin - 1},
	{x = F.bounds.x2 + protected.margin + 1, z = F.bounds.z2 + protected.margin + 1},
}
for _, pos in ipairs(safe_corner_writes) do
	local inside = pos.x >= protected.x0 - protected.margin and pos.x <= protected.x1 + protected.margin
		and pos.z >= protected.z0 - protected.margin and pos.z <= protected.z1 + protected.margin
	eq(inside, false, "each corner write is outside protected rectangle")
end
api.terraform = function() return true, {written = {
	-- The axis-aligned envelope of the two disjoint safe writes crosses protection.
	minp = {x = safe_corner_writes[1].x, z = safe_corner_writes[1].z},
	maxp = {x = safe_corner_writes[2].x, z = safe_corner_writes[2].z},
}} end
local corner_ok, corner_stats = terrain.terraform(api, plan, schematics, protected)
eq(corner_ok, true, "overlapping written envelope does not imply a protected write")
eq(corner_stats.written.minp.x, F.bounds.x1 - protected.margin - 1, "corner envelope stats are preserved")
eq(call[3].protected[1], protected, "corner call passes protected rectangle unchanged")

local no_volume = {terraform = function() return true, {} end}
local no_box, no_box_code = terrain.volume(no_volume, candidate, schematics, opts)
eq(no_box, nil, "missing volume method has no result")
eq(no_box_code, "outskirts_dependency", "missing volume method is a dependency failure")
