local eq = ...
local catalog = dofile("src/catalog.lua")
local residents = dofile("src/residents.lua")
local node_setup = dofile("src/node_setup.lua")
local outskirts = dofile("src/outskirts.lua")
local preflight = dofile("src/preflight.lua")
local outskirts_build = dofile("src/outskirts_build.lua")
local rural = assert(outskirts.assets(catalog.entries))
local assets = dofile("schematics/outskirts/catalog.lua")

local nodes, metadata, storage_values, constructed = {}, {}, {}, 0
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
		heights = {min = 10, max = 10}, rect = {x1 = 40, z1 = 40, x2 = 48, z2 = 46}},
	{id = "h01", class = "hut", asset = "shepherd_hut", rotation = 0, ground_y = 10,
		heights = {min = 10, max = 10}, rect = {x1 = 80, z1 = 40, x2 = 88, z2 = 47}},
}
local out = {entries = rural, protected = {margin = 4}, plots = plots}
local result = {plan = {seed = 8, town_type = "medieval", bounds = urban_bounds},
	ground_y = 10, build_bounds = {min = {x = 0, y = 0, z = 0}, max = {x = 20, y = 20, z = 20}},
	build_volume = {min = {x = 0, y = 0, z = 0}, max = {x = 20, y = 20, z = 20}},
	player_pos = {x = -100, y = 10, z = -100}, outskirts = out}

local town_calls, node_state = {}, {}
local towns = {
	modpath = ".", catalog = catalog, schematic = {}, node_setup = node_setup,
	planner = dofile("src/planner.lua"),
	preflight = preflight, residents = residents, outskirts = outskirts,
	outskirts_build = outskirts_build,
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
	eq(opts.player_pos.x, 4, "outskirts search receives the command player position")
	eq(opts.terrain, living_villages.terrain, "outskirts search receives the Living Villages API")
	done(out)
end
_G.towns = towns
loadfile("src/generate_command.lua")(towns)

local searched
towns.populated.search({x = 4, y = 11, z = 5}, 8, "medieval", function(r) searched = r end)
eq(searched.outskirts, out, "accepted urban result receives its outskirts plan")
eq(searched.player_pos.x, 4, "accepted player position is retained for preflight")

local summary, msg, code = towns.populated.build(result)
eq(summary ~= nil, true, "integrated urban and outskirts build succeeds: " .. tostring(msg or code))
eq(town_calls[1], "urban_build", "urban builder runs first")
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

local urban_calls = 0
towns.builder.build_town = function() urban_calls = urban_calls + 1; return nil, "unused" end
_G.living_villages = nil
local missing, _, missing_code = towns.populated.build(result)
eq(missing, nil, "missing runtime terrain API stops build")
eq(missing_code, "outskirts_dependency", "missing runtime API is a dependency error")
eq(urban_calls, 0, "terrain API dependency fails before urban writes")

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
local partial, _, partial_code, extra = towns.populated.build(result)
eq(partial, nil, "rural runtime failure stops residents")
eq(partial_code, "write_failed", "rural failure after urban success is a write failure")
eq(extra.urban_bounds.min.x, 0, "partial failure retains urban bounds")
eq(#extra.terrain_attempts, 1, "partial failure retains rural terrain attempts")
eq(extra.bounds.max.x > extra.urban_bounds.max.x, true, "partial failure bounds include outskirts attempts")

_G.core, _G.towns, _G.living_villages = nil, nil, nil
