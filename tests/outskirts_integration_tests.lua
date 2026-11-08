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
local terraform_calls = 0
local cleared_metadata, stopped_timers = {}, {}
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
	after = function(_, fn) core_watchdog = fn end,
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
			from_table = function(_, value)
				m.fields, m.inventory = value.fields or {}, value.inventory or {}
				cleared_metadata[k] = true
			end,
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
	get_node_timer = function(p)
		local k = key(p)
		return {stop = function() stopped_timers[k] = true end}
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
	end, terraform = function() terraform_calls = terraform_calls + 1; return true, {unloaded_blocks = 0} end}}

local urban_bounds = {x1 = 0, z1 = 0, x2 = 20, z2 = 20}
local plots = {
	{id = "f01", class = "farm", asset = "farm", rotation = 0, ground_y = 10,
		heights = {min = 10, max = 10}, rect = {x1 = 40, z1 = 40, x2 = 56, z2 = 52}},
	{id = "h01", class = "hut", asset = "shepherd_hut", rotation = 0, ground_y = 10,
		heights = {min = 10, max = 10}, rect = {x1 = 80, z1 = 40, x2 = 88, z2 = 47}},
}
local out = {entries = rural, protected = {margin = 6}, plots = plots}
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
	generate = dofile("src/generate.lua")(dofile("src/planner.lua"), dofile("src/generation_lock.lua")),
	builder = {
		read_bounds = function() return {min = {x = -1, y = 0, z = -1}, max = {x = 21, y = 20, z = 21}} end,
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
	build_town = function(_, opts)
			if opts.before_write then
				local ok, why = opts.before_write()
				if not ok then return nil, why, "before_write_denied" end
			end
		stage_order[#stage_order + 1] = "urban"
			town_calls[#town_calls + 1] = "urban_build"
			return {write_bounds = {min = {x = 0, y = 0, z = 0}, max = {x = 20, y = 20, z = 20}},
				town = {complete = true, bounds = {min = {x = 0, y = 0, z = 0}, max = {x = 20, y = 20, z = 20}},
					structures = {}, placed = 0, doors = {}, setup = {initialized = 0, placements = 0, unhandled = {}}}},
				"", nil
		end,
	},
}
towns.preflight.check = function() return {volume = {min = {x = 0, y = 0, z = 0},
	max = {x = 20, y = 20, z = 20}}} end
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

-- Automatic builder integration keeps the approved urban write gate between
-- zero-write preflight and the first urban mutation.
local auto_box = {min = {x = -500, y = -500, z = -500}, max = {x = 500, y = 500, z = 500}}
local before_writes = #town_calls
local before_calls, ensured = 0, {}
local denied_code
towns.populated.build(result, function(_, _, code) denied_code = code end, {
	read_bounds = auto_box, write_bounds = auto_box,
	ensure_loaded = function(minp, maxp, cb)
		ensured[#ensured + 1] = {min = minp, max = maxp}; cb(true)
	end,
	before_write = function() before_calls = before_calls + 1; return false, "player entered" end,
})
eq(denied_code, "before_write_denied", "automatic urban write gate reports denial")
eq(before_calls, 1, "automatic urban write gate is called once")
eq(#town_calls, before_writes, "denied automatic build performs no urban write")
eq(#ensured, 1, "automatic builder requests the approved urban volume once")

before_calls, ensured = 0, {}
local overflow_code
towns.populated.build(result, function(_, _, code) overflow_code = code end, {
	read_bounds = auto_box,
	write_bounds = {min = {x = -10, y = -10, z = -10}, max = {x = 10, y = 10, z = 10}},
	ensure_loaded = function(minp, maxp, cb) ensured[#ensured + 1] = true; cb(true) end,
	before_write = function() before_calls = before_calls + 1; return true end,
})
eq(overflow_code, "inspection_failed", "urban overflow declines before construction")
eq(before_calls, 0, "urban overflow does not call the write gate")
eq(#ensured, 0, "urban overflow is rejected before requesting additional terrain")
eq(#town_calls, before_writes, "urban overflow performs no urban write")

local read_code
towns.populated.build(result, function(_, _, c) read_code = c end, {
	read_bounds = result.build_volume, write_bounds = auto_box,
	ensure_loaded = function() error("out-of-envelope load") end,
	before_write = function() error("unexpected write") end,
})
eq(read_code, "inspection_failed", "urban inspection halo must fit the approved read envelope")
eq(#town_calls, before_writes, "read overflow performs no urban write")

local late, timed_out, timeout_code
towns.populated.build(result, function(_, _, c) timed_out = (timed_out or 0) + 1; timeout_code = c end, {
	read_bounds = auto_box, write_bounds = auto_box,
	ensure_loaded = function(_, _, cb) late = cb end,
	before_write = function() error("timed-out load must not write") end,
})
core_watchdog()
late(true)
eq(timeout_code, "emerge_failed", "urban load watchdog reports failure")
eq(timed_out, 1, "late urban load cannot resume a timed-out build")
eq(#town_calls, before_writes, "timed-out urban load performs no writes")

local pending_load, async_done = nil, 0
towns.populated.build(result, function(s) async_done = async_done + 1; auto_summary = s end, {
	read_bounds = auto_box, write_bounds = auto_box,
	ensure_loaded = function(_, _, cb) pending_load = cb end,
	before_write = function() before_calls = before_calls + 1; return true end,
})
eq(async_done, 0, "automatic build waits for bounded loading")
pending_load(true)
eq(auto_summary ~= nil, true, "automatic build resumes after bounded loading")
eq(async_done, 1, "automatic async completion fires once")

before_calls, ensured = 0, {}
local auto_summary
towns.populated.build(result, function(s) auto_summary = s end, {
	read_bounds = auto_box, write_bounds = auto_box,
	ensure_loaded = function(minp, maxp, cb)
		ensured[#ensured + 1] = {min = minp, max = maxp}; cb(true)
	end,
	before_write = function() before_calls = before_calls + 1; return true end,
})
eq(auto_summary ~= nil, true, "automatic context reuses the populated builder")
eq(before_calls, 1, "accepted automatic build enters the write gate once")
eq(#ensured > 0, true, "automatic context routes declared loading through its adapter")

local composition = assert(preflight.compose_outskirts(out, rural))
local apply_env = towns.builder.core_env()
apply_env.terrain = living_villages.terrain
apply_env.check_door = towns.builder.check_door
local before_terraform = terraform_calls
local partial_outskirts = outskirts_build.apply(out, apply_env, {
	bounds = urban_bounds, structures = composition.structures,
	automatic_context = {read_bounds = auto_box, write_bounds = {min = {x = -100, y = -100, z = -100},
		max = {x = 65, y = 100, z = 100}}},
})
eq(partial_outskirts ~= nil, true, "escaping automatic rural plot is omitted without failing the town")
eq(terraform_calls - before_terraform, 1, "only the in-envelope rural plot is terraformed")
eq(#partial_outskirts.skipped, 1, "omitted rural plot records its reason")
eq(partial_outskirts.skipped[1].code, "automatic_envelope", "rural omission identifies envelope overflow")
local real_volume = apply_env.terrain.volume
for _, failure in ipairs({"invalid", "throw"}) do
	apply_env.terrain.volume = function(plan, ...)
		if plan[1].pos.x == plots[1].rect.x1 then
			if failure == "throw" then error("volume unavailable") end
			return nil
		end
		return real_volume(plan, ...)
	end
	local prior = terraform_calls
	local mixed = outskirts_build.apply(out, apply_env, {bounds = urban_bounds,
		structures = composition.structures, automatic_context = {read_bounds = auto_box, write_bounds = auto_box}})
	eq(mixed ~= nil, true, failure .. " optional volume does not fail the town")
	eq(mixed.skipped[1].code, "unbounded_volume", failure .. " volume records omission")
	eq(mixed.skipped[1].plot, plots[1].id, failure .. " volume identifies the omitted plot")
	eq(terraform_calls - prior, 1, failure .. " volume leaves the bounded plot eligible")
	eq(mixed.structures[1].plot, plots[2].id, failure .. " volume places the bounded plot")
end
apply_env.terrain.volume = real_volume
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
towns.builder.build_town = function(_, opts)
	if opts.before_write then
		local ok, why = opts.before_write()
		if not ok then return nil, why, "before_write_denied" end
	end
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
	defs["test:building"] = {walkable = true}
	defs["test:tree"] = {walkable = true, tree = true}
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
	eq(table.concat(stage_order, ","), "margin,wall_emerge,wall_read,wall_read,wall_write,rural_search",
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
	eq(table.concat(stage_order, ","), "margin,wall_emerge,wall_read,wall_read,wall_write,rural_search",
		"wall inspection follows an incomplete margin pass")
	margin_mode = "success"
	local real_inspect = walls.inspect
	walls.inspect = function() return {}, {{x = 1, z = 2, reason = "decoration: water or obstruction",
		blocker = {x = 1, y = 10, z = 2, node = "mcl_core:stone"}}} end
	local decoration_summary
	towns.populated.build(test_result, function(s) decoration_summary = s end)
	local warning_text = table.concat(decoration_summary.warnings or {}, " ")
	eq(warning_text:find("wall decorations omitted: 1", 1, true) ~= nil, true, "decoration omission is reported")
	eq(warning_text:find("wall omitted 1 columns", 1, true) == nil, true, "decoration omission is not a missing wall column")
	local recorded_logs, real_log = {}, core.log
	core.log = function(level, message) recorded_logs[#recorded_logs + 1] = message end
	local many_omissions = {}
	for i = 1, 25 do
		many_omissions[#many_omissions + 1] = {x = i, z = 0, reason = "decoration: protected",
			blocker = {x = i, y = 4, z = 0, node = "test:tree"}}
	end
	many_omissions[#many_omissions + 1] = {x = 99, z = 0, reason = "protected",
		blocker = {x = 99, y = -2, z = 0, node = "test:chest", search_limit_y = -30}}
	walls.inspect = function() return {}, many_omissions end
	towns.populated.build(test_result, function() end)
	core.log = real_log
	local first_gap
	for _, message in ipairs(recorded_logs) do
		if message:find("wall gap kind=", 1, true) then first_gap = message; break end
	end
	eq(first_gap and first_gap:find("kind=wall column=(99,0)", 1, true) ~= nil, true,
		"capped diagnostics prioritize actual wall gaps over decorations")
	eq(first_gap and first_gap:find("blocker=(99,-2,0) node=test:chest", 1, true) ~= nil, true,
		"wall gap log includes exact blocker position and node")
	eq(first_gap and first_gap:find("search_limit_y=-30", 1, true) ~= nil, true,
		"wall gap log distinguishes the found water from the search limit")
	local summary_index, previous_cause = nil, nil
	for index, message in ipairs(recorded_logs) do
		if message:find("wall gap cause summary", 1, true) then
			summary_index = index
			local cause = message:match("count=%d+ (.*)$")
			if previous_cause then eq(cause >= previous_cause, true, "cause summaries are deterministic and sorted") end
			previous_cause = cause
		end
	end
	eq(summary_index ~= nil, true, "capped diagnostics include a cause summary")
	walls.inspect = real_inspect
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

-- An inline tower is inspected in full before force placement. Protected or
-- obstructed placement keeps the corresponding ordinary wall columns.
do
	local walls = dofile("src/medieval_walls.lua")
	local features = dofile("src/medieval_wall_features.lua")
	local real_corner_candidates, real_inline_candidates, real_inspect =
		features.corner_candidates, features.inline_candidates, walls.inspect
	local candidate = {asset = "wall_tower_inline", rotation = 180,
		min = {x = -4, y = 9, z = -4}, max = {x = 2, y = 25, z = 2}}
	features.corner_candidates = function() return {} end
	features.inline_candidates = function() return {candidate} end
	towns.medieval_walls, towns.medieval_wall_features = walls, features
	towns.geometry = dofile("src/geometry.lua")
	core.read_schematic = function(path)
		return {size = path:find("wall_tower_inline", 1, true)
			and catalog.entries.wall_tower_inline.size or catalog.entries.wall_tower.size}
	end
	local protected = false
	core.is_protected = function(pos)
		return protected and pos.x == candidate.min.x and pos.y == candidate.min.y - 32
			and pos.z == candidate.min.z
	end
	towns.schematic.validate = function() return true end
	defs[walls.BRICK], defs[walls.STAIR] = {walkable = true}, {walkable = true}
	local blocked, placed, wall_count = false, 0
	walls.inspect = function(wall) wall_count = #wall.cells; return {}, {} end
	towns.site_search.core_env = function() return {emerge = function(_, _, done) done(true) end,
		after = function() end} end
	local previous_env = towns.builder.core_env
	towns.builder.core_env = function(...)
		local env = previous_env(...)
		env.open_region = function() return {get = function(x, y, z)
			if blocked and x == -4 and z == -4 and y == 11 then return "test:building" end
			return y <= 10 and "mcl_core:stone" or "air"
		end, set = function() end, commit = function() end} end
		env.place_structure = function(st)
			if st.id == "wall_tower_inline" then placed = placed + 1 end
			return true
		end
		env.setup_nodes = function() return {failed = {}, unregistered = {}} end
		return env
	end
	local test_result = {plan = {seed = 8, town_type = "medieval", bounds = urban_bounds,
		boundary = {rects = {{x1 = 0, z1 = 0, x2 = 20, z2 = 20}}}, streets = {}},
		ground_y = 10, build_bounds = result.build_bounds, build_volume = result.build_volume,
		player_pos = result.player_pos, force_walls = true}
	local ordinary_wall_count = #walls.plan(test_result.plan, true).cells
	local masked_wall_count = 0
	for _, cell in ipairs(walls.plan(test_result.plan, true).cells) do
		if cell.x >= candidate.min.x and cell.x <= candidate.max.x
				and cell.z >= candidate.min.z and cell.z <= candidate.max.z then
			masked_wall_count = masked_wall_count + 1
		end
	end
	local summary
	wall_count = nil
	towns.populated.build(test_result, function(s) summary = s end)
	eq(summary ~= nil, true, "inline tower path completes generation")
	eq(placed, 1, "supported inline tower is placed")
	eq(#summary.wall.features, 1, "placed inline tower is reported")
	local bounded_summary, gated = nil, 0
	local prior_placed = placed
	towns.populated.build(test_result, function(s) bounded_summary = s end, {
		read_bounds = auto_box, write_bounds = auto_box,
		ensure_loaded = function(_, _, cb) cb(true) end,
		before_write = function() gated = gated + 1; return true end,
	})
	eq(bounded_summary ~= nil, true, "bounded automatic wall and feature build succeeds")
	eq(placed, prior_placed + 1, "bounded automatic build places the approved wall feature")
	eq(gated, 1, "bounded wall build enters the urban write gate once")
	eq(#test_result.wall_feature_footprints, 1, "placed inline tower stays reserved from outskirts")
	eq(wall_count, ordinary_wall_count - masked_wall_count,
		"successful inline tower removes only wall columns inside its footprint")
	local original_max_y, original_log = candidate.max.y, core.log
	local loads, logs, omitted_summary = {}, {}, nil
	candidate.max.y = auto_box.max.y + 1
	core.log = function(_, message) logs[#logs + 1] = message end
	prior_placed = placed
	towns.populated.build(test_result, function(s) omitted_summary = s end, {
		read_bounds = auto_box, write_bounds = auto_box,
		ensure_loaded = function(minp, maxp, cb) loads[#loads + 1] = {min = minp, max = maxp}; cb(true) end,
		before_write = function() return true end,
	})
	candidate.max.y, core.log = original_max_y, original_log
	eq(omitted_summary ~= nil and #omitted_summary.wall.features == 0, true,
		"out-of-envelope wall feature is omitted while ordinary walls build")
	eq(placed, prior_placed, "out-of-envelope wall feature is never placed")
	local feature_load = false
	for _, load in ipairs(loads) do if load.max.y > auto_box.max.y then feature_load = true end end
	eq(feature_load, false, "out-of-envelope feature requests no expanded load")
	local omission_logged = false
	for _, message in ipairs(logs) do
		if message:find("wall_tower_inline omitted: automatic%-town envelope") then omission_logged = true end
	end
	eq(omission_logged, true, "out-of-envelope feature records its omission reason")
	protected, blocked, placed = true, false, 0
	wall_count = nil
	towns.populated.build(test_result, function(s) summary = s end)
	eq(placed, 0, "protected inline tower is omitted")
	eq(#summary.wall.features, 0, "protected inline tower is not reported as placed")
	eq(#test_result.wall_feature_footprints, 0, "protected inline tower releases its reservation")
	eq(wall_count, ordinary_wall_count, "protected inline tower retains every ordinary wall column")
	protected = false
	blocked, placed = true, 0
	wall_count = nil
	towns.populated.build(test_result, function(s) summary = s end)
	eq(placed, 1, "inline tower clears an obstruction inside its selected footprint")
	eq(#summary.wall.features, 1, "cleared inline tower is reported as placed")
	eq(#test_result.wall_feature_footprints, 1, "placed inline tower keeps its outskirts reservation")
	eq(wall_count < ordinary_wall_count, true, "placed inline tower masks covered wall columns")
	-- Gate placement replaces its passage and clears other registered nodes in
	-- the authored footprint before installing the schematic.
	local real_gates, real_joins = walls.gatehouse_candidates, features.gate_joins
	local gate = {asset = "wall_gatehouse", rotation = 0, street = "main", material = "road",
		street_rect = {x1 = 5, x2 = 10, z1 = -8, z2 = -1}, direction = {x = 0, z = -1},
		wall_plane = {x = 5, z = -1}, bounds = {min = {x = 0, y = 10, z = -9},
			max = {x = 15, y = 24, z = -1}}}
	walls.gatehouse_candidates = function(wall)
		wall.openings = {{x = 5, z = -1, direction = {x = 0, z = -1}}}
		return {gate}
	end
	features.corner_candidates = function() return {} end
	features.gate_joins = function() return true end
	core.read_schematic = function(path)
		return {size = path:find("wall_gatehouse", 1, true) and catalog.entries.wall_gatehouse.size
			or path:find("wall_tower_inline", 1, true) and catalog.entries.wall_tower_inline.size
			or catalog.entries.wall_tower.size}
	end
	local approaches = 0
	walls.inspect = function(wall) approaches = #wall.openings; return {}, {} end
	test_result.plan.streets = {{id = "main", rect = gate.street_rect}}
	towns.builder.core_env = function(...)
		local env = previous_env(...)
		env.open_region = function() return {get = function(x, y, z)
			if x == 5 and z == -1 and y == 10 then return blocked and "test:building" or "road" end
			return y < 10 and "mcl_core:stone" or "air"
		end, set = function() end, commit = function() end} end
		env.place_structure = function(st) if st.id == "wall_gatehouse" then placed = placed + 1 end; return true end
		env.setup_nodes = function() return {failed = {}, unregistered = {}} end
		return env
	end
	blocked, placed = false, 0
	towns.populated.build(test_result, function(s) summary = s end)
	eq(placed, 1, "supported gatehouse replaces its own road")
	eq(approaches, 0, "successful gate does not overwrite its passage with the old approach")
	blocked, placed = true, 0
	towns.populated.build(test_result, function(s) summary = s end)
	eq(placed, 1, "building in the gate footprint is cleared for placement")
	eq(approaches, 0, "successful gate does not restore the old road approach")
	walls.inspect = dofile("src/medieval_walls.lua").inspect
	-- An obstructed postern must leave all four secondary-road columns open
	-- for the ordinary wall-gap inspection.
	local real_posterns, real_feature_inspect, real_postern_wall_inspect =
		walls.postern_candidates, features.inspect, walls.inspect
	local postern = {asset = "wall_postern", rotation = 0, street = "secondary", material = "road",
		street_rect = {x1 = 0, x2 = 5, z1 = -1, z2 = 2}, direction = {x = 1, z = 0},
		wall_plane = {x = 5}, min = {x = 4, y = 9, z = -5}, max = {x = 6, y = 16, z = 4},
		ground_offset = 1,
		outside_approach = {{x = 7, z = 0, direction = {x = 1, z = 0}, material = "road", pave_surface = true},
			{x = 7, z = 1, direction = {x = 1, z = 0}, material = "road", pave_surface = true}}}
	postern.bounds = {min = postern.min, max = postern.max}
	walls.gatehouse_candidates = function() return {} end
	walls.postern_candidates = function(wall)
		wall.openings = {}
		wall.road_openings = nil
		wall.feature_footprints = nil
		for z = -1, 2 do wall.openings[#wall.openings + 1] = {x = 5, z = z,
			direction = {x = 1, z = 0}, street = "secondary", kind = "secondary",
			material = "road", street_rect = postern.street_rect} end
		wall.cells = {{x = 5, z = -6, direction = {x = 1, z = 0}},
			{x = 5, z = 5, direction = {x = 1, z = 0}},
			{x = 4, z = 3, direction = {x = 1, z = 0}}}
		return {postern}
	end
	features.corner_candidates, features.inline_candidates = function() return {} end, function() return {} end
	features.gate_joins = function() return true end
	core.read_schematic = function(path)
		local id = path:find("wall_postern", 1, true) and "wall_postern"
			or path:find("wall_gatehouse", 1, true) and "wall_gatehouse"
			or path:find("wall_tower_inline", 1, true) and "wall_tower_inline" or "wall_tower"
		return {size = catalog.entries[id].size}
	end
	defs["test:building"] = {walkable = true}
	local fallback_width, cleared_postern_obstruction, staged_apron_node, staged_apron_change, staged_apron_omission, stage_cells, staged_voxels
	local inspected_asset, inspection_reason
	features.inspect = function(candidate, ...)
		inspected_asset = candidate.asset
		local region = select(1, ...)
		for _, p in ipairs(staged_voxels or {}) do
			if p.x >= candidate.min.x and p.x <= candidate.max.x
					and p.y >= candidate.min.y and p.y <= candidate.max.y
					and p.z >= candidate.min.z and p.z <= candidate.max.z then
				staged_apron_node = region.get(p.x, p.y, p.z)
				break
			end
		end
		local ok, reason, clearance = real_feature_inspect(candidate, ...)
		inspection_reason = reason
		return ok, reason, clearance
	end
	walls.inspect = function(wall, ...)
		if not stage_cells and not wall.placed_features then stage_cells = #wall.cells end
		if #wall.openings == 4 and wall.placed_features then fallback_width = #wall.openings end
		local changes, omissions = real_postern_wall_inspect(wall, ...)
		if not staged_voxels and #wall.cells == 3 and not wall.placed_features then
			staged_voxels = {}
			for _, change in ipairs(changes) do
				if change.clearance then staged_voxels[#staged_voxels + 1] = change end
			end
		end
		for _, change in ipairs(changes) do
			if change.x == 6 and change.z == 3 and change.clearance then staged_apron_change = change.y end
		end
		for _, omission in ipairs(omissions) do
			if omission.x == 4 and omission.z == 3 then staged_apron_omission = omission.reason end
		end
		return changes, omissions
	end
	test_result.plan = {seed = 8, town_type = "medieval", bounds = urban_bounds,
		boundary = {rects = {{x1 = 0, z1 = 0, x2 = 3, z2 = 3}}},
		streets = {{id = "secondary", kind = "secondary", rect = postern.street_rect}}}
	local written_nodes = {}
	local protected_obstruction = false
	local arm_protection_on_emerge = false
	local protection_pos = {x = 6, y = 13, z = 0}
	local old_is_protected = core.is_protected
	local old_site_search_env = towns.site_search.core_env
	core.is_protected = function(pos)
		return protected_obstruction and pos.x == protection_pos.x
			and pos.y == protection_pos.y and pos.z == protection_pos.z
	end
	towns.site_search.core_env = function()
		return {emerge = function(_, _, done)
			if arm_protection_on_emerge then
				protected_obstruction = true
				arm_protection_on_emerge = false
			end
			done(true)
		end, after = function() end}
	end
	local rejected_feature_writes = {}
	towns.builder.core_env = function(...)
		local env = previous_env(...)
		env.open_region = function() return {get = function(x, y, z)
			local written = written_nodes[x .. ":" .. y .. ":" .. z]
			if written then return written end
			if protected_obstruction and x == protection_pos.x and y == protection_pos.y and z == protection_pos.z then
				return "test:protected"
			end
			if x == postern.min.x and y == postern.min.y + 2 and z == postern.min.z then
				return "test:building"
			end
			if x == 6 and y == 12 and z == 3 then return "mcl_core:stone" end
			if x == postern.min.x and y == 8 and z == postern.min.z then return "test:tree" end
			return y <= 10 and "mcl_core:stone" or "air"
		end, set = function(x, y, z, name)
			written_nodes[x .. ":" .. y .. ":" .. z] = name
			rejected_feature_writes[#rejected_feature_writes + 1] = {x = x, y = y, z = z, name = name}
			if x == postern.min.x and y == postern.min.y + 2 and z == postern.min.z and name == "air" then
				cleared_postern_obstruction = true
			end
		end, commit = function() end} end
		env.place_structure = function(st) if st.id == "wall_postern" then placed = placed + 1 end; return true end
		env.setup_nodes = function() return {failed = {}, unregistered = {}} end
		return env
	end
	placed, fallback_width, inspected_asset, inspection_reason, cleared_postern_obstruction, staged_apron_node = 0, nil, nil, nil, false, nil
	staged_apron_change, staged_apron_omission, stage_cells, staged_voxels = false, nil, nil, nil
	cleared_metadata[postern.min.x .. ",8," .. postern.min.z] = nil
	stopped_timers[postern.min.x .. ",8," .. postern.min.z] = nil
	local postern_summary
	towns.populated.build(test_result, function(s) postern_summary = s end)
	eq(inspected_asset, "wall_postern", "blocked fallback reaches inspection for a selected postern")
	eq(type(inspection_reason), "table", "registered building in the postern volume is clearable")
	eq(staged_apron_node, "air", "feature inspection sees the staged wall-exterior clearance")
	-- Distance two from the wall keeps terrain up to ground + 1, so the staged cut starts at 12.
	eq(staged_apron_change, 12, "wall staging emits clearance for the feature-adjacent apron")
	eq(staged_apron_omission, nil, "feature-adjacent wall column remains eligible for staged clearance")
	eq(stage_cells, 3, "staging inspects the selected wall geometry")
	eq(cleared_postern_obstruction, true, "postern obstruction is cleared before schematic placement")
	eq(cleared_metadata[postern.min.x .. ",8," .. postern.min.z], true,
		"metadata is removed from vegetation overwritten by a feature foundation")
	eq(stopped_timers[postern.min.x .. ",8," .. postern.min.z], true,
		"timers are stopped on vegetation overwritten by a feature foundation")
	eq(placed, 1, "building obstruction inside the postern footprint no longer blocks placement")
	eq(#postern_summary.wall.features, 1, "cleared postern is reported as placed")
	eq(#test_result.wall_feature_footprints >= 1, true, "placed postern keeps its reservation")
	eq(fallback_width, nil, "successful postern does not fall back to an open road gap")
	-- A protected voxel rejects the whole feature. The ordinary wall pass may
	-- still clear its own apron and build fallback columns, but must not apply
	-- feature-only cuts elsewhere in the rejected feature footprint.
	placed, protected_obstruction, arm_protection_on_emerge, written_nodes, rejected_feature_writes =
		0, false, true, {}, {}
	inspected_asset, inspection_reason = nil, nil
	local rejected_summary
	towns.populated.build(test_result, function(s) rejected_summary = s end)
	eq(placed, 0, "protected postern is rejected")
	eq(inspected_asset, "wall_postern", "post-margin protection reaches feature inspection after selection")
	eq(inspection_reason, "protected", "feature inspection rejects the protected voxel after selection")
	eq(#rejected_summary.wall.features, 0, "rejected postern is absent from placed features")
	eq(written_nodes[protection_pos.x .. ":" .. protection_pos.y .. ":" .. protection_pos.z], nil,
		"protected feature obstruction is never overwritten")
	eq(written_nodes[postern.min.x .. ":" .. (postern.min.y + 2) .. ":" .. postern.min.z], nil,
		"rejected feature does not commit its feature-only clearance")
	local fallback_wall_writes = 0
	for _, write in ipairs(rejected_feature_writes) do
		if write.x == 5 and write.name == walls.BRICK then fallback_wall_writes = fallback_wall_writes + 1 end
	end
	eq(fallback_wall_writes > 0, true, "ordinary wall fallback still builds around rejected postern")
	protected_obstruction = false
	core.is_protected = old_is_protected
	towns.site_search.core_env = old_site_search_env
	walls.postern_candidates, features.inspect = real_posterns, real_feature_inspect
	walls.gatehouse_candidates, features.gate_joins = real_gates, real_joins
	walls.inspect = real_inspect
	local medieval = dofile("src/medieval_planner.lua")
	local profile = assert(towns.planner.landmark_profile(catalog.snapshot()))
	local planned = assert(medieval.plan({x = 0, z = 0}, 1, profile, {int = function(a) return a end},
		{quadrant = 0, castle_east = true, turn = 0}))
	local planned_wall = walls.plan(planned, true)
	local planned_gates = walls.gatehouse_candidates(planned_wall, 10, catalog.entries.wall_gatehouse)
	local target = planned_gates[1]
	local road = target.outside_approach[1]
	target.min, target.max = target.bounds.min, target.bounds.max
	local join = features.gate_join_cells(target, planned_wall)[1]
	local road_writes, gate_placements = {}, {}
	local road_blocked, join_blocked, road_rise = false, false, false
	towns.builder.core_env = function(...)
		local env = previous_env(...)
		env.open_region = function() return {get = function(x, y, z)
			if road_blocked and x == road.x and z == road.z and y == 11 then return "test:building" end
			if join_blocked and x == join.x and z == join.z and y == 11 then return "test:building" end
			local dist = (x - road.x) * target.direction.x + (z - road.z) * target.direction.z
			return y <= (road_rise and dist >= 2 and 12 or 10) and "mcl_core:stone" or "air"
		end, set = function(x, y, z, name)
			if y == 10 and name == target.material then road_writes[x .. ":" .. z] = true end
		end, commit = function() end} end
		env.place_structure = function(st)
			if st.id == "wall_gatehouse" then gate_placements[st.min.x .. ":" .. st.min.z] = true end
			return true
		end
		env.setup_nodes = function() return {failed = {}, unregistered = {}} end
		return env
	end
	test_result.plan = planned
	towns.populated.build(test_result, function(s) summary = s end)
	eq(gate_placements[target.pos.x .. ":" .. target.pos.z], true,
		"real medieval crossing places its planned gatehouse")
	for _, c in ipairs(target.outside_approach) do
		for distance = 0, 3 do
			local k = (c.x + distance * c.direction.x) .. ":" .. (c.z + distance * c.direction.z)
			eq(road_writes[k], true, "real gate paves every outside approach cell")
		end
	end
	road_rise, gate_placements = true, {}
	towns.populated.build(test_result, function(s) summary = s end)
	eq(gate_placements[target.pos.x .. ":" .. target.pos.z], true, "gate with a rising outside road still places")
	local reaches_ramp_end = false
	for _, r in ipairs(test_result.wall_feature_footprints) do
		local x, z = road.x + 4 * target.direction.x, road.z + 4 * target.direction.z
		if x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 then reaches_ramp_end = true end
	end
	eq(reaches_ramp_end, true, "ramp longer than four columns is reserved from outskirts")
	road_rise = false
	road_blocked, gate_placements, road_writes = true, {}, {}
	towns.populated.build(test_result, function(s) summary = s end)
	eq(gate_placements[target.pos.x .. ":" .. target.pos.z], nil,
		"blocked real outside approach omits its gatehouse")
	road_blocked, join_blocked, gate_placements = false, true, {}
	towns.populated.build(test_result, function(s) summary = s end)
	eq(gate_placements[target.pos.x .. ":" .. target.pos.z], true,
		"clearance removes obstruction from adjoining wall column so gatehouse places")
	features.corner_candidates, features.inline_candidates = real_corner_candidates, real_inline_candidates
	walls.inspect = real_inspect
	towns.builder.core_env = previous_env
end

-- Keep the original corner-tower fallback regression separate from inline
-- tower coverage: failed corner placement must also leave its wall intact.
do
	local walls = dofile("src/medieval_walls.lua")
	local features = dofile("src/medieval_wall_features.lua")
	local real_corner, real_inline, real_inspect =
		features.corner_candidates, features.inline_candidates, walls.inspect
	local candidate = {asset = "wall_tower", rotation = 0,
		min = {x = -4, y = 10, z = -4}, max = {x = 3, y = 26, z = 3}}
	features.corner_candidates = function() return {candidate} end
	features.inline_candidates = function() return {} end
	towns.medieval_walls, towns.medieval_wall_features = walls, features
	towns.geometry = dofile("src/geometry.lua")
	core.read_schematic = function(path)
		if path:find("wall_gatehouse", 1, true) then return {size = catalog.entries.wall_gatehouse.size} end
		if path:find("wall_tower_inline", 1, true) then return {size = catalog.entries.wall_tower_inline.size} end
		return {size = catalog.entries.wall_tower.size}
	end
	core.is_protected = function() return false end
	towns.schematic.validate = function() return true end
	defs[walls.BRICK], defs[walls.STAIR] = {walkable = true}, {walkable = true}
	local obstructed, placed, remaining_count = false, 0, nil
	walls.inspect = function(wall) remaining_count = #wall.cells; return {}, {} end
	towns.site_search.core_env = function() return {
		emerge = function(_, _, done) done(true) end, after = function() end} end
	local previous_env = towns.builder.core_env
	towns.builder.core_env = function(...)
		local env = previous_env(...)
		env.open_region = function() return {get = function(x, y, z)
			if obstructed and x == -4 and y == 11 and z == -4 then return "test:building" end
			return y <= 9 and "mcl_core:stone" or "air"
		end, set = function() end, commit = function() end} end
		env.place_structure = function(st)
			if st.id == "wall_tower" then placed = placed + 1 end
			return true
		end
		env.setup_nodes = function() return {failed = {}, unregistered = {}} end
		return env
	end
	local test_result = {plan = {seed = 9, town_type = "medieval", bounds = urban_bounds,
		boundary = {rects = {{x1 = 0, z1 = 0, x2 = 20, z2 = 20}}}, streets = {}},
		ground_y = 10, build_bounds = result.build_bounds, build_volume = result.build_volume,
		player_pos = result.player_pos, force_walls = true}
	local ordinary_count = #walls.plan(test_result.plan, true).cells
	remaining_count = nil
	towns.populated.build(test_result, function() end)
	eq(placed, 1, "corner tower still places through the shared feature path")
	obstructed, placed, remaining_count = true, 0, nil
	towns.populated.build(test_result, function() end)
		eq(placed, 1, "corner tower clears a building inside its selected footprint")
		eq(remaining_count < ordinary_count, true, "placed corner tower masks covered wall columns")
	features.corner_candidates, features.inline_candidates = real_corner, real_inline
	walls.inspect = real_inspect
	towns.builder.core_env = previous_env
end


-- Unwalled medieval and Roman towns grade their road exits between margins
-- and the outskirts search, and reserve the ramps for the outskirts layout.
do
	towns.town_roads = dofile("src/town_roads.lua")
	towns.medieval_walls = dofile("src/medieval_walls.lua")
	margin_mode, rural_search_mode = "success", "success"
	local previous_env, previous_core_env = towns.builder.core_env, towns.site_search.core_env
	local sets, emerged, search_footprints, solid
	local emerge_mode, commit_mode, pending_emerge, timer = "ok", "ok", nil, nil
	towns.site_search.core_env = function() return {
		emerge = function(a, b, done)
			emerged = {a, b}; stage_order[#stage_order + 1] = "road_emerge"
			if emerge_mode == "throw" then error("emerge boom") end
			if emerge_mode == "hang" then pending_emerge = done; return end
			done(emerge_mode == "ok")
		end,
		after = function(_, f) timer = f end,
	} end
	towns.builder.core_env = function(...)
		local env = previous_env(...)
		env.open_region = function()
			stage_order[#stage_order + 1] = "road_read"
			return {get = function(_, y) return y <= solid and "mcl_core:stone" or "air" end,
				set = function(x, y, z, name) sets[#sets + 1] = {x = x, y = y, z = z, name = name} end,
				commit = function()
					if commit_mode == "throw" then error("commit boom") end
					stage_order[#stage_order + 1] = "road_write"
				end}
		end
		return env
	end
	local real_search = towns.outskirts.search
	towns.outskirts.search = function(urban, opts, done)
		search_footprints = opts.feature_footprints
		return real_search(urban, opts, done)
	end
	local function fixture(town_type, streets)
		return {plan = {seed = 9, town_type = town_type, bounds = urban_bounds,
			boundary = {rects = {{x1 = 0, z1 = 0, x2 = 19, z2 = 19}}}, streets = streets},
			ground_y = 10, build_bounds = result.build_bounds, build_volume = result.build_volume,
			player_pos = result.player_pos, force_walls = false}
	end
	local function run(test_result)
		sets, emerged, search_footprints, stage_order, solid = {}, nil, nil, {}, 10
		local s, m
		towns.populated.build(test_result, function(a, b) s, m = a, b end)
		eq(s ~= nil, true, "unwalled road build succeeds: " .. tostring(m))
		return s
	end
	-- Medieval: a six-wide principal street and a four-wide secondary street.
	local medieval = fixture("medieval", {
		{id = 1, kind = "principal", rect = {x1 = 0, z1 = 7, x2 = 19, z2 = 12}},
		{id = 2, kind = "secondary", rect = {x1 = 8, z1 = 0, x2 = 11, z2 = 19}}})
	local s = run(medieval)
	eq(medieval.wall, nil, "unwalled medieval fixture has no wall")
	eq(table.concat(stage_order, ","):find("^margin,road_emerge,road_read,road_write,rural_search") ~= nil, true,
		"roads are graded between margins and outskirts: " .. table.concat(stage_order, ","))
	eq(#medieval.exits, 20, "exits are recorded on the result")
	eq(s.roads.graded, 4, "the four exit crossings are graded")
	eq(s.roads.failed, 0, "no exit fails on flat ground")
	local saved_margins, saved_footprints = towns.city_margins, search_footprints
	towns.city_margins = function() return {attempt = function(_, cb) cb({status = "skipped", reason = "fixture"}) end} end
	for _, kind in ipairs({"medieval", "roman"}) do
		local bounded = fixture(kind, {{id = 1, kind = "principal",
			rect = {x1 = 0, z1 = 7, x2 = 19, z2 = 12}}})
		local completed, loads, bounded_sets = nil, {}, #sets
		towns.populated.build(bounded, function(value) completed = value end, {
			read_bounds = auto_box,
			write_bounds = {min = {x = -1, y = -500, z = -1}, max = {x = 21, y = 500, z = 21}},
			ensure_loaded = function(a, b, cb) loads[#loads + 1] = {a, b}; cb(true) end,
			before_write = function() return true end,
		})
		eq(completed ~= nil and completed.roads and completed.roads.skipped, true,
			kind .. " road outside the approved envelope is omitted")
		eq(#sets, bounded_sets, kind .. " omitted roads perform no writes")
		eq(#loads, 1, kind .. " omitted roads request no additional load")
	end
	towns.city_margins = saved_margins
	search_footprints = saved_footprints
	local zs, xs = {}, {}
	for _, c in ipairs(sets) do
		if c.x >= 20 then zs[c.z] = true end
		if c.z >= 20 then xs[c.x] = true end
	end
	eq(zs[7] == nil and zs[8] == true and zs[11] == true and zs[12] == nil, true,
		"principal exit is graded four wide, centred")
	eq(xs[8] == nil and xs[9] == true and xs[10] == true and xs[11] == nil, true,
		"secondary exit is graded two wide, centred")
	eq(#search_footprints, 4, "outskirts reserves each graded ramp")
	eq(s.write_bounds.max.x >= 20 + towns.town_roads.RAMP_MAX - 1, true, "write envelope includes the road region")
	eq(report_text(s, towns.generate):find("Outside roads: 4 of 4 road exits graded", 1, true) ~= nil, true,
		"report mentions the graded roads")
	-- A failed grade warns, writes nothing for that exit and leaves no stub.
	local failing = fixture("medieval", {{id = 1, kind = "principal", rect = {x1 = 0, z1 = 7, x2 = 19, z2 = 12}}})
	towns.builder.core_env = function(...)
		local env = previous_env(...)
		env.open_region = function()
			return {get = function(_, y) return y <= 10 and "mcl_core:stone" or y == 11 and "test:building" or "air" end,
				set = function(x, y, z, name) sets[#sets + 1] = {x = x, y = y, z = z, name = name} end,
				commit = function() end}
		end
		return env
	end
	defs["test:building"] = {walkable = true}
	s = run(failing)
	eq(s.roads.failed, 2, "both obstructed exits fail")
	eq(#sets, 0, "failed exit leaves no stub")
	eq(#search_footprints, 0, "failed exit reserves nothing")
	local joined = table.concat(s.warnings or {}, "\n")
	eq(joined:find("road exit at (20,", 1, true) ~= nil and joined:find("left ungraded", 1, true) ~= nil, true,
		"failed exit is warned about")
	-- Roman: three arch exits.
	towns.builder.core_env = function(...)
		local env = previous_env(...)
		env.open_region = function()
			return {get = function(_, y) return y <= 10 and "mcl_core:stone" or "air" end,
				set = function(x, y, z, name) sets[#sets + 1] = {x = x, y = y, z = z, name = name} end,
				commit = function() end}
		end
		return env
	end
	local roman = fixture("roman", {
		{id = 1, kind = "principal", exit = true, rect = {x1 = 0, z1 = 8, x2 = 19, z2 = 11}},
		{id = 2, kind = "principal", exit = true, rect = {x1 = 8, z1 = 0, x2 = 11, z2 = 19}}})
	s = run(roman)
	eq(s.roads.graded, 4, "Roman exits are graded")
	-- No boundary: nothing to grade and the outskirts still run.
	local plain = fixture("medieval", {})
	plain.plan.boundary = nil
	s = run(plain)
	eq(s.roads, nil, "a plan without a boundary has no road stage")
	eq(table.concat(stage_order, ","), "margin,rural_search", "no road stage without exits")
	-- Emerge and write failures: the build completes exactly once.
	towns.builder.core_env = function(...)
		local env = previous_env(...)
		env.open_region = function()
			return {get = function(_, y) return y <= 10 and "mcl_core:stone" or "air" end,
				set = function() end,
				commit = function()
					if commit_mode == "throw" then error("commit boom") end
				end}
		end
		return env
	end
	local function once(label, expect_summary)
		local done_calls, got, code, extra = 0
		stage_order, timer, pending_emerge = {}, nil, nil
		towns.populated.build(fixture("medieval", {{id = 1, kind = "principal",
			rect = {x1 = 0, z1 = 7, x2 = 19, z2 = 12}}}),
			function(a, _, c, e) done_calls, got, code, extra = done_calls + 1, a, c, e end)
		return function() eq(done_calls, 1, label .. " completes exactly once")
			eq(got ~= nil, expect_summary, label .. (expect_summary and " returns the town" or " reports a write failure"))
			return got, code, extra end
	end
	emerge_mode = "fail"
	local check = once("emerge failure", true)
	local got = check()
	eq(table.concat(stage_order, ","), "margin,road_emerge,rural_search", "emerge failure still runs the outskirts")
	eq(table.concat(got.warnings or {}, "\n"):find("road exit emerge failed or timed out", 1, true) ~= nil, true,
		"emerge failure is warned about")
	emerge_mode = "throw"
	check = once("emerge throw", true)
	got = check()
	eq(table.concat(got.warnings or {}, "\n"):find("emerge boom", 1, true) ~= nil, true, "emerge error is warned about")
	emerge_mode = "hang"
	check = once("emerge timeout", true)
	eq(type(timer), "function", "a 30 second timeout is scheduled")
	timer()
	check()
	pending_emerge(true) -- a late emerge callback is ignored
	eq(select(2, table.concat(stage_order, ","):gsub("rural_search", "")), 1, "late emerge callback does not rerun the build")
	timer() -- a late timer is ignored
	emerge_mode = "hang"
	check = once("emerge success before the timer", true)
	pending_emerge(true)
	check()
	timer()
	eq(select(2, table.concat(stage_order, ","):gsub("rural_search", "")), 1, "timer after success is ignored")
	emerge_mode, commit_mode = "ok", "throw"
	check = once("road write failure", false)
	local _, code, extra = check()
	eq(code, "write_failed", "road write failure is a write failure")
	eq(extra.road_bounds ~= nil, true, "failure reports the road envelope")
	commit_mode = "ok"
	towns.builder.core_env, towns.site_search.core_env, towns.outskirts.search = previous_env, previous_core_env, real_search
end

-- Walled towns: a bare opening graded by the wall stage reserves its ramp from
-- outskirts terraforming. A failed grade reserves nothing.
do
	local walls = dofile("src/medieval_walls.lua")
	local features = dofile("src/medieval_wall_features.lua")
	local previous_env, previous_core_env = towns.builder.core_env, towns.site_search.core_env
	local previous_walls, previous_features = towns.medieval_walls, towns.medieval_wall_features
	-- No towers or gatehouses: both principal openings stay bare.
	features.candidates = function() return {} end
	towns.medieval_walls, towns.medieval_wall_features = walls, features
	towns.site_search.core_env = function() return {
		emerge = function(_, _, done) done(true) end, after = function() end,
	} end
	local obstructed = false
	towns.builder.core_env = function(...)
		local env = previous_env(...)
		env.open_region = function()
			return {get = function(_, y)
				if obstructed and y == 11 then return "test:building" end
				return y <= 10 and "mcl_core:stone" or "air"
			end, set = function() end, commit = function() end}
		end
		return env
	end
	defs["test:building"] = {walkable = true}
	local function fresh()
		return {plan = {seed = 8, town_type = "medieval", bounds = urban_bounds,
			boundary = {rects = {{x1 = 0, z1 = 0, x2 = 19, z2 = 19}}},
			streets = {{id = 1, kind = "principal", rect = {x1 = 0, z1 = 7, x2 = 19, z2 = 12}}}},
			ground_y = 10, build_bounds = result.build_bounds, build_volume = result.build_volume,
			player_pos = result.player_pos, force_walls = true}
	end
	local function reserved(footprints, x, z)
		for _, r in ipairs(footprints) do
			if x >= r.x1 and x <= r.x2 and z >= r.z1 and z <= r.z2 then return true end
		end
		return false
	end
	local graded_test = fresh()
	local graded_summary, graded_error
	towns.populated.build(graded_test, function(s, m) graded_summary, graded_error = s, m end)
	eq(graded_summary ~= nil, true, "walled build with bare openings completes: " .. tostring(graded_error))
	local footprints = graded_test.wall_feature_footprints or {}
	eq(#footprints, 2, "each graded bare opening reserves one footprint")
	eq(reserved(footprints, 21, 9) and reserved(footprints, -2, 9), true,
		"graded bare openings are reserved from outskirts terraforming")
	obstructed = true
	local failed_test = fresh()
	local failed_summary
	towns.populated.build(failed_test, function(s) failed_summary = s end)
	eq(failed_summary ~= nil, true, "walled build with obstructed openings completes")
	eq(#(failed_test.wall_feature_footprints or {}), 0, "failed bare-opening grades reserve nothing")
	eq(table.concat(failed_summary.warnings or {}, "\n"):find("left ungraded", 1, true) ~= nil, true,
		"failed bare-opening grade is warned about")
	obstructed = false
	towns.builder.core_env, towns.site_search.core_env = previous_env, previous_core_env
	towns.medieval_walls, towns.medieval_wall_features = previous_walls, previous_features
end

-- Controller driving the real populated pipeline, real residents and real record registry.
-- Its urban terrain writer is the recording fake used throughout this group.
do
 local saved_search, saved_world = towns.outskirts.search, towns.site_search.core_env
 local saved_builder = towns.builder.build_town
 towns.builder.build_town = function(...)
  local summary, message, code, extra = saved_builder(...)
  if summary and summary.town then summary.town.complete = true end
  return summary, message, code, extra
 end
 local saved_add = core.add_entity
 local registry_module = dofile("src/auto_records.lua")
 local original_dofile = dofile
 local site = {id = "controller", version = 1, seed = 8, town_type = "roman", cell = {x = 0, z = 0},
  center = {x = 0, z = 0}, max_rect = {x1 = -500, z1 = -500, x2 = 500, z2 = 500},
  activation_rect = {x1 = -500, z1 = -500, x2 = 500, z2 = 500}}
 local box = {min = {x = -10, y = -20, z = -10}, max = {x = 240, y = 40, z = 240}}
 local function run_controller(population_failure, protected, later_protection)
  storage_values = {}; nodes = {}; metadata = {}; node_state = {}; stage_order = {}; town_calls = {}
  margin_mode = "success"
  local report, pending, generated, active_state, raw, serialized, n = nil, nil, nil, nil, nil, {}, 0
  local protection_active, before_rural = protected, nil
  local registry = assert(registry_module.new({store = {get = function() return raw end,
   set = function(_, v) raw = v end}, serialize = function(v) n = n + 1; serialized[tostring(n)] = v; return tostring(n) end,
   deserialize = function(v) return serialized[v] end}))
  local session = {state = function() return active_state end, covers = function() return true end,
   finish = function() active_state = "complete" end, decline = function() active_state = "declined" end,
   on_generated = function() active_state = "inspecting"; return {{site = site}} end}
  local adapter_core = {settings = {get = function() return "on" end},
   get_mapgen_setting = function(k) return ({mg_name = "flat", chunksize = "5", seed = "42"})[k] end,
   get_connected_players = function() return {} end, get_us_time = function() return 0 end,
   is_protected = function(p) return protection_active and p.x == 220 and p.y == 20 and p.z == 220 or false end,
   log = function() end, write_json = function(v) report = v; return "report" end,
   register_on_generated = function(fn) generated = fn end, get_mapgen_object = function() return {5} end,
   after = function(delay, fn) if delay == 0 then fn() end end}
  local modules = { ["src/auto_bounds.lua"] = {PLAN_EXTENT = {}, CHUNK_ORIGIN = -32, CHUNKSIZE = 80, CAPS = {}},
   ["src/auto_sites.lua"] = {new = function() return {lookup = function() return {site} end} end},
   ["src/auto_state.lua"] = {new = function() return session end, classify = function() return "valid" end},
   ["src/auto_loader.lua"] = {new = function() return {start = function(_, _, _, cb) pending = cb; return true end} end}}
  towns.auto_environment = {}; towns.auto_records = registry; towns.auto_records_factory = registry_module
  towns.auto_village_guard = {check = function() return true end, bind = function() return true end}
  towns.generation_lock = dofile("src/generation_lock.lua")()
  towns.site_search.core_env = function() return {emerge = function(_, _, cb) cb(true) end} end
  towns.outskirts.search = function(_, _, done)
   if later_protection then before_rural = #town_calls; protection_active = true; return done(out) end
   if population_failure then done(out) else done(nil, "optional omitted") end
  end
  core.add_entity = population_failure and function() return nil end or saved_add
  local chunk_env = setmetatable({dofile = function(path) return modules[path:gsub("^%./", "")] or original_dofile(path) end}, {__index = _G})
  local chunk = assert(loadfile("src/automatic.lua")); setfenv(chunk, chunk_env)
  chunk()(towns, adapter_core, {mg_overworld_min = -1000, mg_overworld_max = 1000, mg_end_max = -2000})
  generated({x = 0, y = 0, z = 0}, {x = 0, y = 10, z = 0})
  local inspected = {center = site.center, ground_y = 10, plan = {seed = 8, town_type = "roman", bounds = urban_bounds},
   build_bounds = result.build_bounds, build_volume = result.build_volume, read_envelope = box, write_envelope = box,
   envelope = {stages = {urban = {kind = "write", box = {min = {x = 0, y = 0, z = 0},
    max = {x = 225, y = 30, z = 225}}}}}}
  pending(inspected)
  if protected then
   eq(registry:lookup(site.cell).state, "complete", "protected write envelope completes")
   eq(report.outcome, "complete", "protected write envelope is accepted")
   eq(towns.generation_lock.current(), nil, "protected site releases controller lock")
   return
  end
  if later_protection then
   eq(before_rural ~= nil, true, "protection changed after the urban stage")
   eq(registry:lookup(site.cell).state, "complete", "new protection does not interrupt an accepted build")
   eq(#town_calls > before_rural, true, "new protection does not prevent rural placement")
   eq(report.outcome, "complete", "new protection reports completion")
   eq(towns.generation_lock.current(), nil, "new protection releases controller lock")
   return
  end
  eq(registry:lookup(site.cell).state, population_failure and "interrupted" or "complete",
   population_failure and "real resident failure interrupts accepted town" or "optional rural omission completes accepted town")
  eq(towns.generation_lock.current(), nil, "real populated pipeline releases controller lock")
  eq(report.outcome, population_failure and "interrupted" or "complete", "controller reports real pipeline outcome")
 end
 run_controller(false)
 run_controller(true)
 run_controller(false, true)
 run_controller(false, false, true)
 towns.outskirts.search, towns.site_search.core_env = saved_search, saved_world
 towns.builder.build_town = saved_builder
 core.add_entity = saved_add
end

-- Aqueduct step (#417 step 3): hooked into finish_build for Roman towns only.
do
	local real_step = dofile("src/aqueduct_step.lua")
	local real_enumerate = towns.residents.enumerate
	local finalized = 0
	towns.residents.enumerate = function(...) finalized = finalized + 1; return real_enumerate(...) end
	local function roman_result(kind)
		local r = {}
		for k, v in pairs(result) do r[k] = v end
		r.plan = {seed = 8, town_type = kind, bounds = urban_bounds}
		return r
	end
	local function run_build(r, ctx)
		local n, summary, code = 0
		finalized = 0
		towns.populated.build(r, function(s, _, c) n = n + 1; summary, code = s, c end, ctx)
		return n, summary, code
	end
	local calls
	towns.aqueduct_step = {run = function(r, s, ctx, continue)
		calls = calls + 1
		eq(r.plan.town_type, "roman", "step runs only for roman towns")
		eq(#s.town.structures, 2, "step sees merged outskirts structures")
		eq(ctx.env ~= nil, true, "manual context has an environment")
		eq(type(ctx.env.authorize_strip), "function", "manual env can authorize strips")
		continue()
	end, make_env = real_step.make_env}

	calls = 0
	local n, summary = run_build(roman_result("other"))
	eq(calls, 0, "non-roman town does not run the aqueduct step")
	eq(n, 1, "non-roman build completes once")
	eq(summary.aqueduct, nil, "non-roman summary has no aqueduct")

	calls = 0
	n, summary = run_build(roman_result("roman"))
	eq(calls, 1, "roman town runs the aqueduct step once")
	eq(n, 1, "roman build completes once")
	eq(finalized, 1, "roman build finalizes once")

	-- Step throwing: the town still finishes once, aqueduct skipped.
	towns.aqueduct_step = {run = function() error("step exploded") end, make_env = real_step.make_env}
	n, summary = run_build(roman_result("roman"))
	eq(n, 1, "throwing step: town finishes once")
	eq(finalized, 1, "throwing step: exactly one finalize")
	eq(summary ~= nil, true, "throwing step: town not failed")
	eq(summary.aqueduct.status, "skipped", "throwing step: aqueduct skipped")

	-- Real step, adapter built: summary.aqueduct set, write bounds untouched.
	local captured
	-- Drive the real step with a stub adapter via ctx.build.
	towns.aqueduct_step = {run = function(r, s, ctx, continue)
		ctx.build = function(plan, env, opts, done)
			captured = {env = env, opts = opts}
			done({status = "built", side = "+x", length = 30, rise = 8, spout = {x = 1, y = 2, z = 3}})
		end
		real_step.run(r, s, ctx, continue)
	end, make_env = real_step.make_env}
	local _, plain = run_build(roman_result("other"))
	n, summary = run_build(roman_result("roman"))
	eq(n, 1, "built: town finishes once")
	eq(finalized, 1, "built: exactly one finalize")
	eq(summary.aqueduct.status, "built", "built: summary.aqueduct set")
	eq(summary.write_bounds.min.x, plain.write_bounds.min.x, "built: write bounds min unchanged")
	eq(summary.write_bounds.max.x, plain.write_bounds.max.x, "built: write bounds max unchanged")
	eq(summary.automatic_envelope_excess, nil, "built: no envelope excess")
	eq(captured.opts.ground_y, 10, "built: town ground_y passed")
	local plot_seen, bldg_seen = false, false
	for _, f in ipairs(captured.opts.footprints) do
		if f.x1 == 40 and f.z1 == 40 and f.x2 == 56 and f.z2 == 52 then plot_seen = true end
		if f.x1 == summary.town.structures[1].min.x and f.z1 == summary.town.structures[1].min.z then bldg_seen = true end
	end
	eq(plot_seen, true, "outskirts plot rect reaches the adapter")
	eq(bldg_seen, true, "outskirts structure rect reaches the adapter")
	eq(captured.env.protected({x = 0, y = 0, z = 0}), false, "manual env honours the protection check")
	eq(captured.env.check_ownership(), true, "manual env ownership check")
	local report = report_text(summary, towns.generate)
	eq(report:find("Aqueduct built", 1, true) ~= nil, true, "report mentions the aqueduct")
	summary.aqueduct = {status = "skipped", reason = "no candidate lines"}
	eq(report_text(summary, towns.generate):find("Aqueduct skipped: no candidate lines.", 1, true) ~= nil, true,
		"report explains a skipped aqueduct")
	eq(#towns.generate.report_problems(summary), 0, "skipped aqueduct is not a report problem")

	-- Automatic context with no aqueduct capability: skipped, step reports why.
	towns.aqueduct_step = real_step
	local autobox = {min = {x = -500, y = -500, z = -500}, max = {x = 500, y = 500, z = 500}}
	n, summary = run_build(roman_result("roman"), {
		read_bounds = autobox, write_bounds = autobox,
		ensure_loaded = function(_, _, cb) cb(true) end,
		before_write = function() return true end,
		check_ownership = function() return true end,
	})
	eq(n, 1, "automatic roman town finishes once")
	eq(finalized, 1, "automatic roman town finalizes once")
	eq(summary.aqueduct.status, "skipped", "automatic without capability skips the aqueduct")
	eq(summary.aqueduct.reason:find("capability", 1, true) ~= nil, true, "skip reason names the capability")

	-- Automatic town without the capability makes no emerge/open_region/set_node call.
	do
		local env_calls, set_calls, ctx_seen, env_at_entry, env_at_exit = 0, 0, nil, nil, nil
		local saved_env, saved_set = towns.site_search.core_env, core.set_node
		towns.site_search.core_env = function(...) env_calls = env_calls + 1; return saved_env(...) end
		core.set_node = function() set_calls = set_calls + 1 end
		towns.aqueduct_step = {run = function(r, s, ctx, continue)
			ctx_seen, env_at_entry = ctx, env_calls
			real_step.run(r, s, ctx, continue)
			env_at_exit = env_calls
		end, make_env = real_step.make_env}
		n, summary = run_build(roman_result("roman"), {
			read_bounds = autobox, write_bounds = autobox,
			ensure_loaded = function(_, _, cb) cb(true) end,
			before_write = function() return true end,
			check_ownership = function() return true end,
		})
		eq(ctx_seen.env, nil, "no capability: the context has no environment to emerge/open/set with")
		eq(env_at_exit, env_at_entry, "no capability: no core env (emerge) is created by the step")
		eq(set_calls, 0, "no capability: set_node never called")
		eq(summary.aqueduct.status, "skipped", "no capability: skipped")
		towns.site_search.core_env, core.set_node = saved_env, saved_set
	end

	-- A late (async) adapter done through the real hook: waits, then finishes once.
	do
		local late
		towns.aqueduct_step = {run = function(r, s, ctx, continue)
			ctx.build = function(_, _, _, done) late = done end
			real_step.run(r, s, ctx, continue)
		end, make_env = real_step.make_env}
		core_watchdog = nil
		local an, asum = 0
		finalized = 0
		towns.populated.build(roman_result("roman"), function(s_) an = an + 1; asum = s_ end)
		n = an
		eq(an, 0, "async aqueduct: town waits for the adapter")
		eq(finalized, 0, "async aqueduct: not finalized yet")
		late({status = "built", side = "+x", length = 30, rise = 8, spout = {x = 1, y = 2, z = 3}})
		late({status = "skipped", reason = "duplicate"})
		eq(an, 0, "async aqueduct: continuation leaves the adapter callback")
		core_watchdog(); core_watchdog = nil
		eq(an, 1, "async aqueduct: town finishes once")
		eq(finalized, 1, "async aqueduct: finalizes once")
		eq(asum.aqueduct.status, "built", "async aqueduct: result recorded")
	end

	-- Throwing finalize. A summary.town that rejects the `shortages` write makes
	-- finalize throw after all writes.
	do
		local real_build_town = towns.builder.build_town
		towns.builder.build_town = function(...)
			local sm, a, b, c = real_build_town(...)
			if sm then
				setmetatable(sm.town, {__newindex = function(t, k, v)
					if k == "shortages" then error("finalize boom") end
					rawset(t, k, v)
				end})
			end
			return sm, a, b, c
		end
		local function run_failing(r)
			local n2, sm, msg, code, extra = 0
			towns.populated.build(r, function(s_, m_, c_, e_) n2 = n2 + 1; sm, msg, code, extra = s_, m_, c_, e_ end)
			return n2, sm, msg, code, extra
		end
		-- Non-roman: the old path. The error reaches the outskirts callback's pcall.
		towns.aqueduct_step = real_step
		local n2, sm, msg, code, extra = run_failing(roman_result("other"))
		eq(n2, 1, "non-roman finalize error: finishes once")
		eq(sm, nil, "non-roman finalize error: build fails")
		eq(code, "write_failed", "non-roman finalize error: write_failed")
		eq(msg:find("outskirts callback failed after writes began", 1, true) ~= nil, true,
			"non-roman finalize error: old failure message")
		eq(extra.reason, "outskirts_write", "non-roman finalize error: old failure reason")
		eq(extra.bounds ~= nil and extra.urban_bounds ~= nil, true, "non-roman finalize error: combined bounds")
		-- Roman: a clean failure with the same combined bounds, reason finalize.
		local rn, rsm, rmsg, rcode, rextra = run_failing(roman_result("roman"))
		eq(rn, 1, "roman finalize error: finishes once")
		eq(rsm, nil, "roman finalize error: build fails")
		eq(rcode, "write_failed", "roman finalize error: write_failed")
		eq(rextra.reason, "finalize", "roman finalize error: reason finalize")
		eq(rmsg:find("finalization failed", 1, true) ~= nil, true, "roman finalize error: message")
		eq(rextra.urban_bounds ~= nil, true, "roman finalize error: urban bounds reported")
		eq(rextra.rural_bounds ~= nil, true, "roman finalize error: rural bounds reported")
		eq(rextra.bounds.max.x >= extra.bounds.max.x and rextra.bounds.max.z >= extra.bounds.max.z, true,
			"roman finalize error: combined bounds cover what the old path reports")
		towns.builder.build_town = real_build_town
	end

	towns.residents.enumerate = real_enumerate
	towns.aqueduct_step = nil
end

_G.core, _G.towns, _G.living_villages = nil, nil, nil
