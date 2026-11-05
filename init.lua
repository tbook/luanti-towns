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
-- Outside-road and ramp helpers shared by Roman and medieval towns (#357).
towns.town_roads = dofile(modpath .. "/src/town_roads.lua")
towns.medieval_walls = dofile(modpath .. "/src/medieval_walls.lua")
towns.medieval_wall_features = dofile(modpath .. "/src/medieval_wall_features.lua")

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

-- Shared in-memory ownership for command and automatic town operations.
towns.generation_lock_factory = dofile(modpath .. "/src/generation_lock.lua")
towns.generation_lock = towns.generation_lock_factory()

-- Accepted automatic-town records (#399). No automatic job is started here.
towns.auto_records_factory = dofile(modpath .. "/src/auto_records.lua")
local auto_serialize, auto_deserialize = towns.auto_records_factory.core_serializers(core)
towns.auto_records = towns.auto_records_factory.new({
	store = towns.auto_records_factory.core_store(core.get_mod_storage()),
	serialize = auto_serialize,
	deserialize = auto_deserialize,
	log = function(level, message) core.log(level, message) end,
})
towns.auto_records_command = dofile(modpath .. "/src/auto_records_command.lua")
towns.auto_records_command.register(core, towns.auto_records)

-- Village guard factory; the automatic coordinator installs it when its bounds
-- environment and session are available.
towns.auto_villages = dofile(modpath .. "/src/auto_villages.lua")
local env_ok, env = pcall(dofile(modpath .. "/src/auto_environment.lua"),
	towns, core, rawget(_G, "settlements"), rawget(_G, "living_villages"))
if env_ok then
	towns.auto_environment = env
	local inactive_session = {state = function() end, decline = function() end}
	towns.auto_village_guard = towns.auto_villages.install({
		settlements = rawget(_G, "settlements"), env = env, session = inactive_session,
		mcl_vars = rawget(_G, "mcl_vars"), max_height_difference = rawget(_G, "max_height_difference"),
		planner_enabled = not core.settings or core.settings:get_bool("living_villages_smooth_villages", true) ~= false,
		lookup = function() return {} end, enabled = function() return false end,
		registry = towns.auto_records,
		disable = function(reason) towns.auto_disabled = reason end,
		log = function(reason) core.log("error", "[towns] automatic village guard: " .. reason) end,
	})
else
	towns.auto_disabled = tostring(env)
	core.log("error", "[towns] automatic village guard: " .. towns.auto_disabled)
end


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
towns.generate = dofile(modpath .. "/src/generate.lua")(towns.planner, towns.generation_lock_factory)
loadfile(modpath .. "/src/generate_command.lua")(towns)
