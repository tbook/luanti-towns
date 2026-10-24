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
eq(schematics[1].hwidth == 9 and schematics[1].hdepth == 7 and schematics[1].hheight == 8, true,
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

local call
api.terraform = function(...) call = {...}; return true, {unloaded_blocks = 0} end
local ok = terrain.terraform(api, plan, schematics, protected)
eq(ok, true, "successful terraform stats are accepted")
eq(#call, 3, "terraform uses the public three-argument API")
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

api.terraform = function() return true, {written = {
	minp = {x = F.bounds.x1 - protected.margin, z = F.bounds.z1},
	maxp = {x = F.bounds.x1 - protected.margin, z = F.bounds.z1},
}} end
local raised = pcall(terrain.terraform, api, plan, schematics, protected)
eq(raised, false, "write on protected margin boundary is a programming error")

local no_volume = {terraform = function() return true, {} end}
local no_box, no_box_code = terrain.volume(no_volume, candidate, schematics, opts)
eq(no_box, nil, "missing volume method has no result")
eq(no_box_code, "outskirts_dependency", "missing volume method is a dependency failure")
