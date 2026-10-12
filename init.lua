local modpath = core.get_modpath(core.get_current_modname())

-- Internal tables for the Phase 1 placement command; not a registration API.
towns = {
	modpath = modpath,
	catalog = dofile(modpath .. "/src/catalog.lua"),
	geometry = dofile(modpath .. "/src/geometry.lua"),
}
towns.placement = dofile(modpath .. "/src/placement.lua")(towns.geometry)
-- Pure town planner (boundary + civic sites); no world access.
towns.planner = dofile(modpath .. "/src/planner.lua")

-- Read-only nearby site search and terrain inspection (no world writes).
towns.site_search = dofile(modpath .. "/src/site_search.lua")(towns.placement, towns.planner)

-- Flat-town builder: one validated plan + inspected site -> nodes (#15).
towns.builder = dofile(modpath .. "/src/builder.lua")(towns.placement, towns.planner)

-- Startup check: report missing or mismatched schematics clearly.
local invalid = towns.catalog.verify(function(path)
	return core.read_schematic(path, {})
end, modpath)
for _, id in ipairs(towns.catalog.ids()) do
	if invalid[id] then
		core.log("error", invalid[id])
	end
end

-- Privileged Phase 1 test command (overwrites its site; Testlandia only).
loadfile(modpath .. "/src/test_command.lua")(towns)

-- Privileged Phase 2 command: search near the player and build at once
-- (overwrites its site; disposable Creative worlds only).
towns.generate = dofile(modpath .. "/src/generate.lua")(towns.planner)
loadfile(modpath .. "/src/generate_command.lua")(towns)
