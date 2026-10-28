local modpath = core.get_modpath(core.get_current_modname())

-- Internal module tables shared by the commands; not a registration API.
towns = {
	modpath = modpath,
	catalog = dofile(modpath .. "/src/catalog.lua"),
	geometry = dofile(modpath .. "/src/geometry.lua"),
	schematic = dofile(modpath .. "/src/schematic.lua"),
}
towns.placement = dofile(modpath .. "/src/placement.lua")
-- Pure town planner (boundary + civic sites); no world access.
towns.planner = dofile(modpath .. "/src/planner.lua")

-- Pure composition + preflight of a complete town build (no writes).
towns.preflight = dofile(modpath .. "/src/preflight.lua")
towns.medieval_walls = dofile(modpath .. "/src/medieval_walls.lua")

-- Read-only nearby site search and terrain inspection (no world writes).
towns.site_search = dofile(modpath .. "/src/site_search.lua")(towns.placement, towns.planner)

-- Optional Living Villages terrain adapter (#259); inject its terrain API when
-- an attempt is made so startup does not depend on that mod being available.
towns.city_margins = dofile(modpath .. "/src/city_margins.lua")

-- Scattered rural plots around an accepted urban site (#237).
towns.outskirts = dofile(modpath .. "/src/outskirts.lua")
towns.outskirts_build = dofile(modpath .. "/src/outskirts_build.lua")

-- Post-placement initialization of functional nodes (#46); used by the
-- /towns_generate only.
towns.node_setup = dofile(modpath .. "/src/node_setup.lua")

-- Valid-bed enumeration inside placed buildings (#47); read-only, used by
-- /towns_generate only.
towns.residents = dofile(modpath .. "/src/residents.lua")

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

-- Manual Issue 139 imports, separate from the town generation catalog.
loadfile(modpath .. "/src/roman_import_command.lua")(towns)

-- Small outdoor objects, available for inspection before town placement.
loadfile(modpath .. "/src/object_command.lua")(towns)

-- Privileged populated-town command: search near the player and build at once
-- (overwrites its site; disposable Creative worlds only).
towns.generate = dofile(modpath .. "/src/generate.lua")(towns.planner)
loadfile(modpath .. "/src/generate_command.lua")(towns)
