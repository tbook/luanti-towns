local modpath = core.get_modpath(core.get_current_modname())

-- Internal tables for the Phase 1 placement command; not a registration API.
towns = {
	modpath = modpath,
	catalog = dofile(modpath .. "/src/catalog.lua"),
	geometry = dofile(modpath .. "/src/geometry.lua"),
}
towns.placement = dofile(modpath .. "/src/placement.lua")(towns.geometry)

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
