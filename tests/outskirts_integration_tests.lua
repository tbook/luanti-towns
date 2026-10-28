local eq = ...
local catalog = dofile("src/catalog.lua")
local residents = dofile("src/residents.lua")
local node_setup = dofile("src/node_setup.lua")
local outskirts = dofile("src/outskirts.lua")
local preflight = dofile("src/preflight.lua")
local real_outskirts_preflight = preflight.check_outskirts
local outskirts_build = dofile("src/outskirts_build.lua")
local rural = assert(outskirts.assets(catalog.entries))
local assets = dofile("schematics/outskirts/catalog.lua")

local nodes, metadata, storage_values, constructed = {}, {}, {}, 0
local stage_order = {}
local margin_mode = "success"
local rural_search_mode = "success"
local rural_search_calls = 0
local function key(p) return p.x .. "," .. p.y .. "," .. p.z end
local function put(p, name, param2)
	nodes[key(p)] = {name = name, param2 = param2 or 0}
end
local function get(p)
	return nodes[key(p)] or {name = "air", param2 = 0}
end
local defs = {
	air = {walkable = false}, ["mcl_core:stone"] = {walkable = true},
	["mcl_beds:bed_red_bottom"] = {walkable = false},
	["mcl_beds:bed_red_top"] = {walkable = false},
	["mcl_loom:loom"] = {walkable = true},
	["mcl_composters:composter"] = {walkable = true, on_construct = function() constructed = constructed + 1 end},
}
local core = {
	registered_nodes = defs, EMERGE_CANCELLED = 1, EMERGE_ERRORED = 2,
	get_mod_storage = function()
		return {get_string = function(_, k) return storage_values[k] or "" end,
			set_string = function(_, k, v) storage_values[k] = v end}
	end,
	get_node = get, get_node_or_nil = get,
	get_player_by_name = function() return nil end,
	register_chatcommand = function() end,
	get_mapgen_setting = function() return "0" end,
	get_us_time = function() return 0 end,
	get_item_group = function(name, group)
		if group == "bed" then
			if name == "mcl_beds:bed_red_bottom" then return 1 end
			if name == "mcl_beds:bed_red_top" then return 2 end
		end
		return 0
	end,
	find_nodes_in_area = function(minp, maxp, wanted)
		local found = {}
		for k, node in pairs(nodes) do
			local x, y, z = k:match("(-?%d+),(-?%d+),(-?%d+)")
			x, y, z = tonumber(x), tonumber(y), tonumber(z)
			if x >= minp.x and x <= maxp.x and y >= minp.y and y <= maxp.y
					and z >= minp.z and z <= maxp.z then
				for _, n in ipairs(wanted) do
					if n == node.name or (n == "group:bed" and core.get_item_group(node.name, "bed") > 0) then
						found[#found + 1] = {x = x, y = y, z = z}; break
					end
				end
			end
		end
		return found
	end,
	get_meta = function(p)
		local k = key(p); metadata[k] = metadata[k] or {fields = {}, inventory = {}}
		local m = metadata[k]
		return {
			get_string = function(_, field) return m.fields[field] or "" end,
			set_string = function(_, field, value) m.fields[field] = value end,
			to_table = function() return {fields = m.fields, inventory = m.inventory} end,
			get_inventory = function() return {
				get_size = function(_, list) return #(m.inventory[list] or {}) end,
				set_size = function(_, list, size) m.inventory[list] = m.inventory[list] or {}; m.inventory[list][size] = m.inventory[list][size] end,
				get_list = function(_, list) return m.inventory[list] or {} end,
				set_list = function(_, list, v) m.inventory[list] = v end,
			} end,
		}
	end,
	add_entity = function()
		return {get_luaentity = function() return {_id = "resident-1"} end, remove = function() end}
	end,
	log = function() end,
}
_G.core = core
_G.living_villages = {terrain = {volume = function(plan)
		local p = plan[1].pos
		return {minp = {x = p.x - 10, y = p.y - 10, z = p.z - 10},
			maxp = {x = p.x + 20, y = p.y + 20, z = p.z + 20}}
	end, terraform = function() return true, {unloaded_blocks = 0} end}}

local urban_bounds = {x1 = 0, z1 = 0, x2 = 20, z2 = 20}
local plots = {
	{id = "f01", class = "farm", asset = "farm", rotation = 0, ground_y = 10,
		heights = {min = 10, max = 10}, rect = {x1 = 40, z1 = 40, x2 = 56, z2 = 52}},
	{id = "h01", class = "hut", asset = "shepherd_hut", rotation = 0, ground_y = 10,
		heights = {min = 10, max = 10}, rect = {x1 = 80, z1 = 40, x2 = 88, z2 = 47}},
}
local out = {entries = rural, protected = {margin = 4}, plots = plots}
local result = {plan = {seed = 8, town_type = "medieval", bounds = urban_bounds},
	ground_y = 10, build_bounds = {min = {x = 0, y = 0, z = 0}, max = {x = 20, y = 20, z = 20}},
	build_volume = {min = {x = 0, y = 0, z = 0}, max = {x = 20, y = 20, z = 20}},
	player_pos = {x = 4, y = 11, z = 5}, outskirts = out}

local town_calls, node_state = {}, {}
local function report_text(summary, generate)
	summary.seed, summary.center, summary.ground_y = 8, {x = 0, z = 0}, 10
	summary.bounds = summary.town.bounds
	summary.sites = summary.sites or {}
	summary.counts = {streets = 0, principal = 0, secondary = 0, blocks = 0, frontage = 0}
	return table.concat(generate.format_report(summary), "\n")
end
local towns = {
	modpath = ".", catalog = catalog, schematic = {}, node_setup = node_setup,
	planner = dofile("src/planner.lua"),
	preflight = preflight, residents = residents, outskirts = outskirts,
	outskirts_build = outskirts_build,
	city_margins = function()
		return {attempt = function(_, done)
			stage_order[#stage_order + 1] = "margin"
			if margin_mode == "throw" then error("margin adapter failure") end
			if margin_mode == "timeout" then
				done({status = "skipped", reason = "emerge timed out"})
				return
			end
			if margin_mode == "incomplete" then
				done({status = "incomplete", reason = "partial smoothing",
					stats = {changed = 7, cut = 2, filled = 3, max_movement = 4, steps_over_one = 1, tree_removed = 2,
						written = {minp = {x = 220, y = 0, z = 220}, maxp = {x = 225, y = 20, z = 225}}},
					attempted_bounds = {minp = {x = 190, y = 0, z = 190},
						maxp = {x = 210, y = 20, z = 210}}})
				return
			end
			put({x = 200, y = 10, z = 200}, "mcl_core:stone")
			done({status = "smoothed", stats = {changed = 7, cut = 2, filled = 3, max_movement = 4,
				steps_over_one = 1, tree_removed = 2,
				written = {minp = {x = 220, y = 0, z = 220}, maxp = {x = 225, y = 20, z = 225}}},
				attempted_bounds = {minp = {x = 190, y = 0, z = 190},
				maxp = {x = 210, y = 20, z = 210}}})
			if margin_mode == "duplicate" then done({status = "smoothed"}) end
		end}
	end,
	site_search = {WET_DEFAULTS = {}, core_env = function() return {} end},
	generate = dofile("src/generate.lua")(dofile("src/planner.lua")),
	builder = {
		check_door = function() return {approach = {x = 90, z = 40}, steps = 1} end,
		core_env = function()
			return {
				get_node = function(x, y, z) return get({x = x, y = y, z = z}).name end,
				node_info = function(name) return defs[name] end,
				place_structure = function(st, entry)
					town_calls[#town_calls + 1] = "place:" .. st.id
					if st.id == "farm" then
						put({x = st.min.x + assets.farm.composter.x, y = st.min.y + assets.farm.composter.y,
							z = st.min.z + assets.farm.composter.z}, "mcl_composters:composter")
					else
						local b = assets.shepherd_hut.bed
						put({x = st.min.x + b.x, y = st.min.y + b.y, z = st.min.z + b.z}, "mcl_beds:bed_red_bottom", 0)
						put({x = st.min.x + b.x, y = st.min.y + b.y, z = st.min.z + b.z + 1}, "mcl_beds:bed_red_top", 0)
						put({x = st.min.x + b.x + 1, y = st.min.y + b.y - 1, z = st.min.z + b.z}, "mcl_core:stone")
					end
					return true
				end,
				setup_nodes = function(structures, entries)
					return node_setup.initialize(structures, node_setup.core_env(core, {}, function(st)
						return st.id == "farm" and {"mcl_composters:composter"} or {"mcl_loom:loom"}
					end), node_state)
				end,
			}
		end,
	build_town = function()
		stage_order[#stage_order + 1] = "urban"
			town_calls[#town_calls + 1] = "urban_build"
			return {write_bounds = {min = {x = 0, y = 0, z = 0}, max = {x = 20, y = 20, z = 20}},
				town = {bounds = {min = {x = 0, y = 0, z = 0}, max = {x = 20, y = 20, z = 20}},
					structures = {}, placed = 0, doors = {}, setup = {initialized = 0, placements = 0, unhandled = {}}}},
				"", nil
		end,
	},
}
towns.preflight.check = function() return {} end
local function read_schematic(path)
	if path:find("farm", 1, true) then
		return {size = assets.farm.size, data = {{name = "mcl_composters:composter"}}}
	end
	return {size = assets.shepherd_hut.size, data = {{name = "mcl_loom:loom"},
		{name = "mcl_beds:bed_red_bottom"}, {name = "mcl_beds:bed_red_top"}}}
end
local preflight_env = {read_schematic = read_schematic,
	read_data = function() return {required_nodes = {}} end, node_registered = function() return true end}
preflight.core_env = function() return preflight_env end
towns.site_search.search = function(pos, seed, opts, done)
	eq(opts.planner_opts ~= nil, true, "urban search retains planner options")
	done({plan = {seed = seed}, ground_y = 10, center = {x = 0, z = 0}}, nil, {urban = true})
end
towns.outskirts.search = function(urban, opts, done)
	rural_search_calls = rural_search_calls + 1
	stage_order[#stage_order + 1] = "rural_search"
	eq(opts.player_pos.x, 4, "outskirts search receives the command player position")
	eq(opts.terrain, living_villages.terrain, "outskirts search receives the Living Villages API")
	eq(get({x = 200, y = 10, z = 200}).name, "mcl_core:stone",
		"rural search reads terrain after city margins complete")
	if rural_search_mode == "failure" then return done(nil, "search timeout", "outskirts_dependency") end
	done(out)
	if margin_mode == "duplicate" then done(out) end
end
_G.towns = towns
loadfile("src/generate_command.lua")(towns)

local searched
towns.populated.search({x = 4, y = 11, z = 5}, 8, "medieval", function(r) searched = r end)
eq(searched.outskirts, nil, "urban search defers outskirts planning until after margins")
eq(searched.player_pos.x, 4, "accepted player position is retained for preflight")

local summary, msg, code
towns.populated.build(result, function(s, m, c) summary, msg, code = s, m, c end)
eq(summary ~= nil, true, "integrated urban and outskirts build succeeds: " .. tostring(msg or code))
eq(stage_order[1], "urban", "urban builder runs first")
eq(stage_order[2], "margin", "city margins run after urban build")
eq(stage_order[3], "rural_search", "rural search runs after margins")
eq(town_calls[1], "urban_build", "urban builder runs before rural writes")
eq(town_calls[2], "place:farm", "farm is placed after urban build")
eq(town_calls[3], "place:shepherd_hut", "hut is placed after urban build")
eq(#summary.town.structures, 2, "only placed rural structures join the urban structures")
eq(summary.town.structures[1].id, "farm", "placed farm joins resident enumeration")
eq(summary.town.structures[2].id, "shepherd_hut", "placed hut joins resident enumeration")
eq(summary.outskirts.setup.initialized, 1, "real node setup initializes the farm composter")
eq(constructed, 1, "farm composter constructor runs")
eq(summary.town.beds.count, 1, "real resident enumeration counts the hut bed and no farm bed")
eq(summary.town.beds.by_structure[1].valid, 0, "farm has no resident bed")
eq(summary.town.beds.by_structure[2].valid, 1, "hut contributes one resident bed")
eq(summary.town.residents.spawned, 1, "unchanged resident initialization spawns for the hut bed")
eq(summary.margins.status, "smoothed", "margin outcome is retained for reporting")
local report = report_text(summary, towns.generate)
eq(report:find("City margins smoothed (changed 7, cut 2, filled 3, max_movement 4, steps_over_one 1, tree_removed 2).", 1, true) ~= nil,
	true, "successful margin stats are reported")
eq(report:find("Urban builder write envelope (0,0,0) to (20,20,20).", 1, true) ~= nil,
	true, "urban write envelope remains separately reported")
eq(report:find("Possible overall write envelope", 1, true) ~= nil, true,
	"conservative envelope reports attempted volumes")
eq(report:find("Margin recorded write envelope (220,0,220) to (225,20,225).", 1, true) ~= nil,
	true, "recorded margin envelope is reported separately")
eq(report:find("to (225,20,225)", 1, true) ~= nil, true,
	"union includes recorded writes outside the attempted margin box")
eq(report:find("every node changed", 1, true) ~= nil, true,
	"overall envelope does not claim every node changed")

margin_mode = "throw"
local search_before = rural_search_calls
local recovered
towns.populated.build(result, function(s) recovered = s end)
eq(recovered ~= nil, true, "thrown optional margin stage still builds rural outskirts")
eq(recovered.margins.status, "incomplete", "thrown margin stage is reported as incomplete")
report = report_text(recovered, towns.generate)
eq(report:find("City margins incomplete:", 1, true) ~= nil
	and report:find("margin adapter failure", 1, true) ~= nil, true,
	"incomplete margin reason is reported once")
eq(select(2, report:gsub("margin adapter failure", "")), 1,
	"margin warning does not duplicate the reason")
eq(rural_search_calls, search_before + 1, "rural search continues after margin throw")

margin_mode = "timeout"
search_before = rural_search_calls
towns.populated.build(result, function(s) recovered = s end)
eq(recovered.margins.status, "skipped", "timed-out margin attempt is reported as skipped")
report = report_text(recovered, towns.generate)
eq(report:find("City margins skipped: emerge timed out.", 1, true) ~= nil, true,
	"skipped margin reason is reported")
eq(rural_search_calls, search_before + 1, "rural search continues after margin timeout")

margin_mode, rural_search_mode = "success", "failure"
local rural_recovery
towns.populated.build(result, function(s) rural_recovery = s end)
eq(rural_recovery ~= nil, true, "rural search failure returns the completed urban town")
eq(rural_recovery.town.beds ~= nil, true, "rural search recovery runs resident enumeration")
report = report_text(rural_recovery, towns.generate)
eq(report:find("Residents:", 1, true) ~= nil, true,
	"rural search fallback preserves the urban residents report")
eq(report:find("Build warning: outskirts search failed after urban build", 1, true) ~= nil,
	true, "rural search fallback is reported as a warning")
eq(report:find("Nothing was changed", 1, true) ~= nil, false,
	"rural search fallback does not claim no writes")

margin_mode = "duplicate"
towns.preflight.check_outskirts = function() error("rural preflight failed") end
local real_initialize, initialize_calls = towns.residents.initialize, 0
towns.residents.initialize = function(...)
	initialize_calls = initialize_calls + 1
	return real_initialize(...)
end
local preflight_recovery, preflight_done = nil, 0
towns.populated.build(result, function(s) preflight_recovery, preflight_done = s, preflight_done + 1 end)
eq(preflight_recovery ~= nil, true, "rural preflight throw returns the completed urban town")
eq(preflight_done, 1, "duplicate callbacks and rural preflight throw complete once")
eq(initialize_calls, 1, "duplicate callbacks still initialize residents once")
towns.residents.initialize = real_initialize
towns.preflight.check_outskirts = real_outskirts_preflight
margin_mode, rural_search_mode = "success", "success"

local urban_calls = 0
towns.builder.build_town = function() urban_calls = urban_calls + 1; return nil, "unused" end
_G.living_villages = nil
local missing, _, missing_code
towns.populated.build(result, function(s, _, c) missing, missing_code = s, c end)
eq(missing, nil, "missing runtime terrain API stops build")
eq(missing_code, "outskirts_dependency", "missing runtime API is a dependency error")
eq(urban_calls, 0, "terrain API dependency fails before urban writes")

margin_mode = "incomplete"
_G.living_villages = {terrain = {volume = function(plan)
	local p = plan[1].pos
	return {minp = {x = p.x - 10, y = p.y - 10, z = p.z - 10},
		maxp = {x = p.x + 20, y = p.y + 20, z = p.z + 20}}
end, terraform = function() error("terraform runtime failure") end}}
towns.builder.build_town = function()
	return {write_bounds = {min = {x = 0, y = 0, z = 0}, max = {x = 20, y = 20, z = 20}},
		town = {bounds = {min = {x = 0, y = 0, z = 0}, max = {x = 20, y = 20, z = 20}},
			structures = {}, placed = 0, doors = {}}}
end
local partial, _, partial_code, extra
towns.populated.build(result, function(s, _, c, e) partial, partial_code, extra = s, c, e end)
eq(partial, nil, "rural runtime failure stops residents")
eq(partial_code, "write_failed", "rural failure after urban success is a write failure")
eq(extra.urban_bounds.min.x, 0, "partial failure retains urban bounds")
eq(#extra.terrain_attempts, 1, "partial failure retains rural terrain attempts")
eq(extra.bounds.max.x > extra.urban_bounds.max.x, true, "partial failure bounds include outskirts attempts")
eq(extra.bounds.max.x >= 225, true, "partial failure union includes margin recorded writes")
eq(extra.margin_bounds.min.x, 190, "partial failure retains attempted margin bounds")
eq(extra.rural_bounds ~= nil, true, "partial failure retains rural bounds")
local failure_report = towns.generate.format_build_failure("terraform runtime failure",
	partial_code, result, extra)
eq(failure_report:find("PARTIALLY written within possible envelope", 1, true) ~= nil,
	true, "later fatal report labels combined possible bounds")
eq(failure_report:find("margin possible bounds (190,0,190) to (225,20,225)", 1, true) ~= nil,
	true, "later fatal report includes attempted and recorded margin bounds")
eq(failure_report:find("Nothing was changed", 1, true) ~= nil, false,
	"partial failure does not claim no writes")

local real_apply = towns.outskirts_build.apply
towns.outskirts_build.apply = function()
	return {status = "built", structures = nil, placed = 1,
		attempted = {{min = {x = 300, y = 1, z = 300}, max = {x = 320, y = 30, z = 320}}},
		placement_attempted = {}, boxes = {}}
end
local late_failure, late_code, late_extra
towns.populated.build(result, function(s, _, c, e) late_failure, late_code, late_extra = s, c, e end)
eq(late_failure, nil, "post-writer bookkeeping failure remains fatal")
eq(late_code, "write_failed", "post-writer bookkeeping failure is a write failure")
eq(late_extra.rural_bounds.min.x <= 300, true, "post-writer failure includes composed rural structures")
eq(late_extra.bounds.max.x >= 320, true, "post-writer failure includes returned rural bounds")
towns.outskirts_build.apply = real_apply

-- The wall stage must inspect the smoothed terrain and finish before rural
-- search. Use a tiny footprint so this exercises the real wall writer.
do
	local walls = dofile("src/medieval_walls.lua")
	towns.medieval_walls = walls
	defs[walls.BRICK], defs[walls.STAIR] = {walkable = true}, {walkable = true}
	core.is_protected = function() return false end
	margin_mode, rural_search_mode = "success", "success"
	_G.living_villages.terrain.terraform = function() return true, {unloaded_blocks = 0} end
	stage_order = {}
	towns.site_search.core_env = function() return {
		emerge = function(_, _, done) stage_order[#stage_order + 1] = "wall_emerge"; done(true) end,
		after = function() end,
	} end
	local previous_env = towns.builder.core_env
	towns.builder.core_env = function(...)
		local env = previous_env(...)
		env.open_region = function()
			stage_order[#stage_order + 1] = "wall_read"
			return {get = function(_, y) return y == 10 and "mcl_core:stone" or "air" end,
				set = function() end, commit = function() stage_order[#stage_order + 1] = "wall_write" end}
		end
		return env
	end
	local test_result = {plan = {seed = 8, town_type = "medieval", bounds = urban_bounds,
		boundary = {rects = {{x1 = 0, z1 = 0, x2 = 3, z2 = 3}}}, streets = {}},
		ground_y = 10, build_bounds = result.build_bounds, build_volume = result.build_volume,
		player_pos = result.player_pos, force_walls = true}
	local wall_summary, wall_error
	towns.populated.build(test_result, function(s, m) wall_summary, wall_error = s, m end)
	eq(wall_summary ~= nil, true, "wall stage builds: " .. tostring(wall_error))
	eq(table.concat(stage_order, ","), "margin,wall_emerge,wall_read,wall_write,rural_search",
		"walls are written between margins and outskirts")
	eq(wall_summary.wall.placed > 0, true, "wall nodes were written")
	eq(wall_summary.wall.attempted_bounds.min.y, 10 - walls.DEPTH,
		"wall emerge and reported bounds include the full tall-foundation depth")
	-- A partial city-margin pass still lets the wall inspector build supported
	-- columns and report any local terrain obstructions.
	margin_mode, stage_order = "incomplete", {}
	local rough_wall
	towns.populated.build(test_result, function(s) rough_wall = s end)
	eq(rough_wall ~= nil, true, "partial margins do not suppress wall generation")
	eq(rough_wall.wall.placed > 0, true, "supported wall sections are built after partial margins")
	eq(table.concat(stage_order, ","), "margin,wall_emerge,wall_read,wall_write,rural_search",
		"wall inspection follows an incomplete margin pass")
	margin_mode = "success"
	local pending, failure_code, failure_extra
	towns.site_search.core_env = function() return {
		emerge = function(_, _, done) pending = done end, after = function() end,
	} end
	local original_inspect = walls.inspect
	walls.inspect = function() return nil, {} end
	towns.populated.build(test_result, function(_, _, code, extra) failure_code, failure_extra = code, extra end)
	eq(type(pending), "function", "wall emerge may complete asynchronously")
	pending(true)
	eq(failure_code, "write_failed", "asynchronous wall callback exceptions finish the build")
	eq(failure_extra.wall_bounds.min.y, 10 - walls.DEPTH,
		"asynchronous failure reports the full wall envelope")
	walls.inspect = original_inspect
	towns.builder.core_env = previous_env
end

_G.core, _G.towns, _G.living_villages = nil, nil, nil
