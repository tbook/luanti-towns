-- Node setup adapter tests (ticket #46): supported nodes, unregistered
-- nodes, callback failure, repeat invocation preserving metadata, bed claims,
-- unhandled flagging, and agreement with the registered templates. Run by
-- tests/run.lua with a fake engine that implements only what node_setup.core_env
-- touches:
--   loadfile("tests/node_setup_tests.lua")(eq, fails, catalog, node_setup)
local eq, fails, catalog, ns = ...

------------------------------------------------------------------------
-- Fake engine
------------------------------------------------------------------------
local function pk(p) return p.x .. "," .. p.y .. "," .. p.z end

local function new_engine()
	local E = {nodes = {}, metas = {}, defs = {}, calls = {}, refreshed = {}, groups = {}}
	E.c = {registered_nodes = E.defs}
	function E.c.get_node(p) return {name = E.nodes[pk(p)] or "air"} end
	function E.c.get_item_group(name, g) return (E.groups[name] or {})[g] or 0 end
	E.objects = {}
	function E.c.get_objects_inside_radius()
		local out = {}
		for _, n in ipairs(E.objects) do
			out[#out + 1] = {get_luaentity = function() return {name = n} end}
		end
		return out
	end
	function E.c.find_nodes_in_area(minp, maxp, names)
		local want, out = {}, {}
		for _, n in ipairs(names) do want[n] = true end
		E.calls[#E.calls + 1] = "find:" .. pk(minp) .. ".." .. pk(maxp)
		for k, name in pairs(E.nodes) do
			if want[name] then
				local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
				x, y, z = tonumber(x), tonumber(y), tonumber(z)
				if x >= minp.x and x <= maxp.x and y >= minp.y and y <= maxp.y
						and z >= minp.z and z <= maxp.z then
					out[#out + 1] = {x = x, y = y, z = z}
				end
			end
		end
		table.sort(out, function(a, b) return pk(a) < pk(b) end)
		return out
	end
	local function meta_of(p)
		local k = pk(p)
		E.metas[k] = E.metas[k] or {fields = {}, lists = {}}
		return E.metas[k]
	end
	E.meta = meta_of
	function E.c.get_meta(p)
		local m = meta_of(p)
		local inv = {}
		function inv:set_size(name, n)
			local l = m.lists[name] or {}
			while #l < n do l[#l + 1] = "" end
			while #l > n do l[#l] = nil end
			m.lists[name] = l
			if n == 0 then m.lists[name] = nil end
		end
		function inv:get_size(name) return m.lists[name] and #m.lists[name] or 0 end
		function inv:set_list(name, items)
			m.lists[name] = {}
			for i, v in ipairs(items) do m.lists[name][i] = v end
		end
		local meta = {}
		function meta:set_string(k, v) m.fields[k] = v ~= "" and v or nil end
		function meta:get_inventory() return inv end
		function meta:to_table()
			local f, l = {}, {}
			for k, v in pairs(m.fields) do f[k] = v end
			for k, v in pairs(m.lists) do
				l[k] = {}
				for i, s in ipairs(v) do l[k][i] = s end
			end
			return {fields = f, inventory = l}
		end
		return meta
	end
	-- A constructor that sets inventory sizes and a formspec; `destructive`
	-- additionally wipes the villager claim to prove the adapter restores it.
	function E.register(name, opts)
		opts = opts or {}
		E.defs[name] = {}
		if opts.groups then E.groups[name] = opts.groups end
		if opts.construct ~= false and not opts.no_construct then
			E.defs[name].on_construct = function(p)
				E.calls[#E.calls + 1] = "construct:" .. name .. "@" .. pk(p)
				if opts.fail then error("boom") end
				local m = meta_of(p)
				m.fields.formspec = "fs"
				if opts.destructive then
					m.fields.villager = nil
					m.lists.main = nil
				end
				for l, n in pairs(opts.lists or {}) do
					local cur = m.lists[l] or {}
					while #cur < n do cur[#cur + 1] = "" end
					m.lists[l] = cur
				end
			end
		end
		if opts.after_place then
			E.defs[name].after_place_node = function(p, placer)
				E.calls[#E.calls + 1] = "after_place:" .. name .. "@" .. pk(p) .. ":" .. tostring(placer)
				meta_of(p).fields.formspec = "dispenser"
			end
		end
	end
	function E.put(p, name) E.nodes[pk(p)] = name end
	return E
end

local function structure(id, minp, maxp)
	return {id = id, kind = "content", min = minp, max = maxp}
end

local function env_for(E, required)
	local globals = {
		itemframes = {update_entity = function(p) E.refreshed[#E.refreshed + 1] = "frame@" .. pk(p) end},
		chests = {select_and_spawn_entity = function(p) E.refreshed[#E.refreshed + 1] = "chest@" .. pk(p) end},
	}
	return ns.core_env(E.c, globals, required)
end

local function count_calls(E, prefix)
	local n = 0
	for _, c in ipairs(E.calls) do
		if c:sub(1, #prefix) == prefix then n = n + 1 end
	end
	return n
end

------------------------------------------------------------------------
-- Supported nodes are initialized, only inside the box
------------------------------------------------------------------------
do
	local E = new_engine()
	E.register("mcl_jukebox:jukebox", {lists = {main = 1}})
	E.register("mcl_furnaces:furnace", {lists = {src = 1, fuel = 1, dst = 1}})
	E.register("mcl_itemframes:frame", {lists = {main = 1}})
	E.register("mcl_core:stone", {no_construct = true})
	E.put({x = 1, y = 1, z = 1}, "mcl_jukebox:jukebox")
	E.put({x = 2, y = 1, z = 1}, "mcl_furnaces:furnace")
	E.put({x = 3, y = 1, z = 1}, "mcl_itemframes:frame")
	E.put({x = 4, y = 1, z = 1}, "mcl_core:stone")
	E.put({x = 50, y = 1, z = 1}, "mcl_furnaces:furnace") -- outside the box
	local env = env_for(E, nil)
	local st = {}
	local rep = ns.initialize({structure("tavern", {x = 0, y = 0, z = 0}, {x = 10, y = 5, z = 10})}, env, st)
	eq(rep.ok, true, "supported: ok")
	eq(rep.initialized, 3, "supported: three nodes initialized")
	eq(rep.by_name["mcl_jukebox:jukebox"], 1, "supported: jukebox counted")
	eq(E.meta({x = 1, y = 1, z = 1}).lists.main ~= nil, true, "supported: jukebox inventory present")
	eq(E.meta({x = 2, y = 1, z = 1}).fields.formspec, "fs", "supported: furnace formspec")
	eq(E.meta({x = 50, y = 1, z = 1}).fields.formspec, nil, "outside the box is untouched")
	eq(count_calls(E, "construct:mcl_core:stone"), 0, "plain nodes get no constructor")
	eq(E.refreshed[1], "frame@3,1,1", "item frame display refreshed")
	eq(ns.format(rep):find("initialized 3 nodes", 1, true) ~= nil, true, "format report")
end

------------------------------------------------------------------------
-- Repeat invocation: completion state, metadata and claims preserved
------------------------------------------------------------------------
do
	local E = new_engine()
	E.register("mcl_jukebox:jukebox", {destructive = true, lists = {main = 1}})
	E.register("mcl_beds:bed_red_bottom", {no_construct = true})
	local jb, bed = {x = 1, y = 1, z = 1}, {x = 2, y = 1, z = 1}
	E.put(jb, "mcl_jukebox:jukebox")
	E.put(bed, "mcl_beds:bed_red_bottom")
	-- Authored state: a claimed jukebox holding a disc, a claimed bed.
	E.meta(jb).fields.villager = "abc"
	E.meta(jb).lists.main = {"mcl_jukebox:record_1"}
	E.meta(bed).fields.villager = "bed-owner"
	E.meta(bed).fields.last_birth = "12"
	local env = env_for(E, function() return {"mcl_jukebox:jukebox", "mcl_beds:bed_red_bottom"} end)
	local st = {}
	local s = {structure("tavern", {x = 0, y = 0, z = 0}, {x = 10, y = 5, z = 10})}
	local r1 = ns.initialize(s, env, st)
	eq(r1.initialized, 1, "repeat: first call initializes the jukebox")
	eq(E.meta(jb).fields.villager, "abc", "repeat: claim kept although the constructor wiped it")
	eq(E.meta(jb).lists.main[1], "mcl_jukebox:record_1", "repeat: inventory kept")
	eq(E.meta(jb).fields.formspec, "fs", "repeat: constructor effect kept")
	eq(E.meta(bed).fields.villager, "bed-owner", "repeat: bed claim untouched")
	eq(E.meta(bed).fields.last_birth, "12", "repeat: bed metadata untouched")
	E.meta(jb).lists.main[1] = "mcl_jukebox:record_2"
	local before = count_calls(E, "construct:")
	local r2 = ns.initialize(s, env, st)
	eq(r2.already_done, 1, "repeat: placement skipped")
	eq(r2.initialized, 0, "repeat: nothing initialized twice")
	eq(count_calls(E, "construct:"), before, "repeat: no constructor ran again")
	eq(E.meta(jb).lists.main[1], "mcl_jukebox:record_2", "repeat: inventory not reset")
	-- A fresh state (e.g. another session) is still harmless to claims.
	local r3 = ns.initialize(s, env, {})
	eq(r3.ok, true, "repeat with new state ok")
	eq(E.meta(jb).fields.villager, "abc", "repeat with new state: claim kept")
	eq(E.meta(jb).lists.main[1], "mcl_jukebox:record_2", "repeat with new state: inventory kept")
end

------------------------------------------------------------------------
-- Callback failure and retry; unregistered supported names
------------------------------------------------------------------------
do
	local E = new_engine()
	E.register("mcl_furnaces:furnace", {fail = true})
	E.register("mcl_smoker:smoker", {lists = {src = 1}})
	E.put({x = 1, y = 1, z = 1}, "mcl_furnaces:furnace")
	E.put({x = 2, y = 1, z = 1}, "mcl_smoker:smoker")
	E.put({x = 3, y = 1, z = 1}, "mcl_blast_furnace:blast_furnace") -- not registered
	E.meta({x = 1, y = 1, z = 1}).fields.infotext = "keep"
	local env = env_for(E, nil)
	local st = {}
	local s = {structure("shop", {x = 0, y = 0, z = 0}, {x = 10, y = 5, z = 10})}
	local r = ns.initialize(s, env, st)
	eq(r.ok, false, "failure: not ok")
	eq(#r.failed, 1, "failure: one failed node")
	eq(r.failed[1].name, "mcl_furnaces:furnace", "failure: names the node")
	eq(r.failed[1].message:find("boom", 1, true) ~= nil, true, "failure: carries the error")
	eq(r.failed[1].id, "shop", "failure: carries the building")
	eq(#r.unregistered, 1, "unregistered: reported")
	eq(r.unregistered[1].name, "mcl_blast_furnace:blast_furnace", "unregistered: name")
	eq(r.initialized, 1, "failure: other nodes still initialized")
	eq(E.meta({x = 1, y = 1, z = 1}).fields.infotext, "keep", "failure: metadata preserved")
	eq(st.placements["shop@0,0,0"].complete, false, "failure: placement not complete")
	-- Retry only touches the node that has not been initialized.
	E.defs["mcl_furnaces:furnace"].on_construct = function(p)
		E.calls[#E.calls + 1] = "construct:retry@" .. pk(p)
	end
	local before = count_calls(E, "construct:mcl_smoker")
	local r2 = ns.initialize(s, env, st)
	eq(count_calls(E, "construct:retry"), 1, "retry: failed node constructed again")
	eq(count_calls(E, "construct:mcl_smoker"), before, "retry: finished node left alone")
	eq(#r2.failed, 0, "retry: no failure")
end

------------------------------------------------------------------------
-- Chests: no constructor (it merges neighbours), lists ensured and kept
------------------------------------------------------------------------
do
	local E = new_engine()
	E.register("mcl_chests:chest_small", {lists = {main = 27, input = 1}, groups = {chest_entity = 1}})
	E.groups["mcl_chests:chest_small"] = {chest_entity = 1}
	local a, b = {x = 1, y = 1, z = 1}, {x = 2, y = 1, z = 1}
	E.put(a, "mcl_chests:chest_small")
	E.put(b, "mcl_chests:chest_small")
	E.meta(a).lists.main = {"mcl_core:apple", ""}
	local env = env_for(E, nil)
	local r = ns.initialize({structure("house", {x = 0, y = 0, z = 0}, {x = 5, y = 5, z = 5})}, env, {})
	eq(r.ok, true, "chests: ok")
	eq(count_calls(E, "construct:"), 0, "chests: constructor (merging) not called")
	eq(E.meta(a).lists.main[1], "mcl_core:apple", "chests: stocked list kept")
	eq(#E.meta(a).lists.main, 2, "chests: existing list size kept")
	eq(#E.meta(b).lists.main, 27, "chests: missing main list sized 27")
	eq(#E.meta(b).lists.input, 1, "chests: input list sized 1")
	eq(#E.refreshed, 2, "chests: entities refreshed")
end

------------------------------------------------------------------------
-- Entity-creating constructors run once (shulker box, campfire)
------------------------------------------------------------------------
do
	local E = new_engine()
	E.register("mcl_chests:black_shulker_box_small", {})
	E.register("mcl_campfires:campfire_lit", {})
	-- Each constructor call would add an entity / particle spawner.
	local ents = 0
	E.defs["mcl_chests:black_shulker_box_small"].on_construct = function(p)
		ents = ents + 1
		E.objects[#E.objects + 1] = "mcl_chests:shulker"
	end
	local fires = 0
	E.defs["mcl_campfires:campfire_lit"].on_construct = function(p)
		fires = fires + 1
		E.meta(p).fields.particle_spawner_id = "7"
	end
	E.put({x = 1, y = 1, z = 1}, "mcl_chests:black_shulker_box_small")
	E.put({x = 2, y = 1, z = 1}, "mcl_campfires:campfire_lit")
	local env = env_for(E, nil)
	local s = {structure("a", {x = 0, y = 0, z = 0}, {x = 5, y = 5, z = 5})}
	local st = {}
	eq(ns.initialize(s, env, st).initialized, 2, "entity nodes: initialized")
	eq(ents == 1 and fires == 1, true, "entity nodes: constructors ran once")
	ns.initialize(s, env, st)
	ns.initialize(s, env, {})
	eq(ents, 1, "shulker: no duplicate entity on repeat or fresh state")
	eq(fires, 1, "campfire: no duplicate spawner on repeat or fresh state")
end

------------------------------------------------------------------------
-- Dispenser: after_place_node without a placer
------------------------------------------------------------------------
do
	local E = new_engine()
	E.register("mcl_dispensers:dispenser", {no_construct = true, after_place = true})
	E.put({x = 1, y = 1, z = 1}, "mcl_dispensers:dispenser")
	local r = ns.initialize({structure("jail", {x = 0, y = 0, z = 0}, {x = 5, y = 5, z = 5})},
		env_for(E, nil), {})
	eq(r.ok, true, "dispenser: ok")
	eq(count_calls(E, "after_place:mcl_dispensers:dispenser@1,1,1:nil"), 1, "dispenser: no placer")
	eq(E.meta({x = 1, y = 1, z = 1}).fields.formspec, "dispenser", "dispenser: set up")
end

------------------------------------------------------------------------
-- Unhandled required initialization is flagged, not guessed
------------------------------------------------------------------------
do
	local E = new_engine()
	E.register("mcl_core:birchleaves", {})                 -- not required
	E.register("mcl_torches:torch", {})                    -- not required
	E.register("fake:gizmo", {})                           -- constructor, unknown
	E.register("fake:crate", {no_construct = true, groups = {container = 2}})
	E.register("fake:slab", {no_construct = true})         -- nothing to do
	E.register("mcl_jukebox:jukebox", {})
	local env = env_for(E, function(s)
		return {"mcl_core:birchleaves", "mcl_torches:torch", "fake:gizmo", "fake:crate",
			"fake:slab", "mcl_jukebox:jukebox", "mcl_jukebox:jukebox"}
	end)
	local s = {structure("a", {x = 0, y = 0, z = 0}, {x = 5, y = 5, z = 5}),
		structure("b", {x = 10, y = 0, z = 0}, {x = 15, y = 5, z = 5})}
	local r = ns.initialize(s, env, {})
	eq(#r.unhandled, 2, "unhandled: two flagged")
	eq(r.unhandled[1].name, "fake:crate", "unhandled: crate (container) first, sorted")
	eq(r.unhandled[2].name, "fake:gizmo", "unhandled: gizmo (on_construct)")
	eq(#r.unhandled[2].structures, 2, "unhandled: names both structures")
	eq(r.ok, false, "unhandled: report not ok")
	eq(ns.classify("mcl_core:birchleaves"), "not_required", "leaves not required")
	eq(ns.classify("mcl_jukebox:jukebox"), "supported", "jukebox supported")
	eq(ns.classify("mcl_beds:bed_red_bottom"), nil, "beds are neither (no initialization exists)")
end

------------------------------------------------------------------------
-- Registered templates: every node that needs initialization in
-- VoxeLibre 0.92.3 is supported or explicitly not required
------------------------------------------------------------------------
do
	-- Nodes of the registered templates that have an on_construct, an
	-- after_place_node initializer (dispenser) or are containers, found by
	-- probing every required node of every template in VoxeLibre 0.92.3.
	local NEEDING = {
		"mcl_armor_stand:armor_stand", "mcl_barrels:barrel_closed", "mcl_blast_furnace:blast_furnace",
		"mcl_books:bookshelf", "mcl_brewing:stand_000", "mcl_campfires:campfire_lit",
		"mcl_chests:black_shulker_box_small", "mcl_chests:chest_left", "mcl_chests:chest_right",
		"mcl_chests:chest_small", "mcl_chests:trapped_chest_left", "mcl_chests:trapped_chest_right",
		"mcl_chests:trapped_chest_small", "mcl_composters:composter", "mcl_core:birchleaves",
		"mcl_core:dirt_with_grass", "mcl_core:vine", "mcl_core:water_flowing", "mcl_core:water_source",
		"mcl_crimson:warped_fence_gate", "mcl_decor:hedge_spruce", "mcl_dispensers:dispenser",
		"mcl_fences:fence_gate", "mcl_fire:eternal_fire", "mcl_furnaces:furnace",
		"mcl_grindstone:grindstone", "mcl_itemframes:frame", "mcl_itemframes:glow_frame",
		"mcl_itemframes:invisible_frame", "mcl_itemframes:plate", "mcl_jukebox:jukebox",
		"mcl_smoker:smoker", "mcl_torches:torch", "mcl_torches:torch_wall",
		"mcl_dispensers:dispenser_up", "mcl_fences:dark_oak_fence_gate", "mcl_enchanting:table",
		"mcl_smithing_table:table",
		"mesecons_pressureplates:pressure_plate_wood_off", "mesecons_torch:mesecon_torch_off_wall",
		"mesecons_torch:mesecon_torch_on_wall",
	}
	for _, n in ipairs(NEEDING) do
		eq(ns.classify(n) ~= nil, true, "template node classified: " .. n)
	end
	-- Everything supported is really used by a registered template.
	local used = {}
	for _, e in pairs(catalog.entries) do
		if e.data_path then
			for _, n in ipairs(dofile(e.data_path).required_nodes) do used[n] = true end
		end
	end
	local names = {}
	for n in pairs(ns.SUPPORTED) do names[#names + 1] = n end
	table.sort(names)
	for _, n in ipairs(names) do
		eq(used[n] == true, true, "supported node appears in a template: " .. n)
	end
	-- Derived from every registered template (not a fixed list): any required
	-- node whose name marks it functional must be classified.
	local FUNCTIONAL = {"chest", "furnace", "smoker", "barrel", "jukebox", "frame", "plate",
		"eternal_fire", "torch", "dispenser", "shulker", "brewing", "campfire", "bookshelf",
		"composter", "grindstone", "fence_gate", "armor_stand"}
	for id, e in pairs(catalog.entries) do
		if e.data_path then
			for _, n in ipairs(dofile(e.data_path).required_nodes) do
				for _, f in ipairs(FUNCTIONAL) do
					if n:find(f, 1, true) then
						eq(ns.classify(n) ~= nil, true, id .. " functional node classified: " .. n)
						break
					end
				end
			end
		end
	end
	local t2 = {}
	for _, n in ipairs(dofile(catalog.entries.tavern_2.data_path).required_nodes) do t2[n] = true end
	eq(t2["mcl_jukebox:jukebox"], true, "tavern_2 template has the jukebox")
	-- The tavern and well carry the nodes Living Villages recognizes.
	local tav = dofile(catalog.entries.tavern.data_path).required_nodes
	local has = {}
	for _, n in ipairs(tav) do has[n] = true end
	eq(has["mcl_jukebox:jukebox"], true, "tavern template has the jukebox")
end
