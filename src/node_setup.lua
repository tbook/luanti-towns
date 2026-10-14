-- Towns: post-placement initialization of functional nodes (ticket #46).
--
-- core.place_schematic (and the .mts format) writes node names and param2 but
-- runs none of a node's registered callbacks, so a placed furnace has no
-- inventory lists or formspec, a pressure plate no timer and an item frame no
-- display. This adapter initializes only the nodes that registered Phase 3
-- templates actually contain, with the narrowest call each one needs. It is
-- deliberately NOT a copy of mcl_villages' init_nodes and does not call
-- on_construct on every node.
--
-- The supported set below was derived from the callbacks registered by
-- VoxeLibre 0.92 / Living Villages for every node in
-- schematics/templates/*.lua required_nodes (see docs/building_workflow.md,
-- "Placed node initialization"):
--
--   construct   call the node's on_construct. Used only where the engine
--               callback sets inventory sizes / formspec / timers / meta on
--               the node itself (jukebox, barrel, furnaces, brewing stand,
--               bookshelf, composter, grindstone, item frames, fence gates,
--               pressure plates, campfire, shulker box).
--   after_place for the dispenser, whose setup is its after_place_node with
--               no placer (orientation is left as authored).
--   lists       chests: the small chest's on_construct also merges adjacent
--               chests and swaps node variants, which would corrupt an
--               authored layout, so only its inventory lists are ensured
--               (main 27, input 1) and the chest entity is refreshed.
--   refresh     displays (item frame item, chest entity, armor stand).
--
-- Metadata is never reset: before a callback runs, the node's metadata is
-- snapshotted, and afterwards every saved field and inventory list is put
-- back. Beds, door state, claims ("villager" fields) and stocked inventories
-- therefore survive. Beds, doors, bells, lecterns, looms and similar nodes
-- have no registered initialization and are never touched here.
--
-- Nothing here generates loot, claims beds or spawns residents (#47, #48).
--
-- All engine access goes through the `env` table (M.core_env below), so the
-- logic runs against fakes in tests/node_setup_tests.lua.
local M = {}

-- name -> rule. Each rule may set: construct, after_place, lists, refresh.
M.SUPPORTED = {}
local function support(names, rule)
	for _, n in ipairs(names) do M.SUPPORTED[n] = rule end
end

support({"mcl_jukebox:jukebox"}, {construct = true})
support({"mcl_barrels:barrel_closed"}, {construct = true})
support({"mcl_furnaces:furnace", "mcl_smoker:smoker", "mcl_blast_furnace:blast_furnace"},
	{construct = true})
support({"mcl_brewing:stand_000"}, {construct = true})
support({"mcl_books:bookshelf"}, {construct = true})
support({"mcl_composters:composter"}, {construct = true})
support({"mcl_grindstone:grindstone"}, {construct = true})
support({"mcl_itemframes:frame", "mcl_itemframes:glow_frame", "mcl_itemframes:invisible_frame",
	"mcl_itemframes:plate"}, {construct = true, refresh = "itemframe"})
support({"mcl_fences:fence_gate", "mcl_crimson:warped_fence_gate"}, {construct = true})
support({"mesecons_pressureplates:pressure_plate_wood_off"}, {construct = true})
support({"mcl_campfires:campfire_lit"}, {construct = true})
support({"mcl_chests:black_shulker_box_small"}, {construct = true})
support({"mcl_dispensers:dispenser"}, {after_place = true})
support({"mcl_armor_stand:armor_stand"}, {refresh = "armor_stand"})
support({"mcl_chests:chest_small", "mcl_chests:chest_left", "mcl_chests:chest_right",
	"mcl_chests:trapped_chest_small", "mcl_chests:trapped_chest_left",
	"mcl_chests:trapped_chest_right"},
	{lists = {main = 27, input = 1}, refresh = "chest_entity"})

-- Nodes that have an on_construct (or are containers) but need nothing here.
-- Lua patterns against the node name; the reason is documentation.
M.NOT_REQUIRED = {
	{"leaves$", "palette/orphan check only; the authored param2 is kept"},
	{"leaves_orphan$", "palette/orphan check only; the authored param2 is kept"},
	{"^mcl_core:vine$", "palette only; the authored param2 is kept"},
	{"^mcl_core:dirt_with_grass$", "palette only; the authored param2 is kept"},
	{"^mcl_core:water_", "palette/extinguish only; liquid is handled by the engine"},
	{"^mcl_decor:hedge_", "connection recalculation; authored variants are kept"},
	{"^mcl_torches:", "flame constructor is a no-op in this VoxeLibre"},
	{"^mesecons_torch:", "torch constructor is a no-op in this VoxeLibre"},
	{"^mcl_fire:", "smoke particles / portal lighting only; not required"},
}

local function not_required(name)
	for _, rule in ipairs(M.NOT_REQUIRED) do
		if name:find(rule[1]) then return rule[2] end
	end
end

-- "supported" | "not_required" | nil
function M.classify(name)
	if M.SUPPORTED[name] then return "supported" end
	if not_required(name) then return "not_required" end
end

local function pkey(p) return p.x .. "," .. p.y .. "," .. p.z end

local function placement_key(s)
	return tostring(s.id) .. "@" .. pkey(s.min)
end

local function supported_names()
	local t = {}
	for n in pairs(M.SUPPORTED) do t[#t + 1] = n end
	table.sort(t)
	return t
end

-- Initializes one supported node. Returns true, or nil, message.
local function init_node(rule, name, pos, env)
	local snap = env.snapshot(pos)
	local function restore() env.restore(pos, snap) end
	if rule.construct then
		local fn = env.callback(name, "on_construct")
		if not fn then return nil, "node has no on_construct" end
		local ok, err = pcall(fn, pos)
		restore()
		if not ok then return nil, "on_construct failed: " .. tostring(err) end
	end
	if rule.after_place then
		local fn = env.callback(name, "after_place_node")
		if not fn then return nil, "node has no after_place_node" end
		local ok, err = pcall(fn, pos, nil, nil, nil)
		restore()
		if not ok then return nil, "after_place_node failed: " .. tostring(err) end
	end
	if rule.lists then
		for list, size in pairs(rule.lists) do
			local ok, err = pcall(env.ensure_list, pos, list, size)
			if not ok then
				restore()
				return nil, "inventory '" .. list .. "' failed: " .. tostring(err)
			end
		end
	end
	if rule.refresh then
		local ok, err = pcall(env.refresh, rule.refresh, pos, name)
		if not ok then return nil, "refresh " .. rule.refresh .. " failed: " .. tostring(err) end
	end
	return true
end

-- M.initialize(structures, env, state, opts) -> report
--   structures  list of placed structures {id, kind, min, max, ...}
--   env         see M.core_env; plus env.required_nodes(structure) ->
--               list of node names in the structure (optional: when absent
--               every supported name is searched and nothing can be flagged)
--   state       caller-owned table; completion is recorded per placement
--               (id@min corner) and per node, so a repeat call does nothing
--               to completed placements and a retry only touches nodes that
--               have not been initialized yet
-- Report:
--   ok            no failures and nothing unhandled
--   placements    number of structures examined
--   already_done  placements skipped because state marks them complete
--   initialized   nodes initialized by this call
--   by_name       {name = count} of nodes initialized by this call
--   failed        {{id, name, pos, message}}  (supported node, callback failed)
--   unregistered  {{id, name, pos}} supported name no longer registered
--   unhandled     {{name, structures = {ids}, reason}} required nodes with a
--                 constructor or inventory that this adapter does not support
function M.initialize(structures, env, state, opts)
	state = state or {}
	state.placements = state.placements or {}
	local report = {
		ok = true, placements = #structures, already_done = 0, initialized = 0,
		by_name = {}, failed = {}, unregistered = {}, unhandled = {},
	}
	local unhandled_idx = {}
	local all_names = supported_names()
	for _, s in ipairs(structures) do
		local key = placement_key(s)
		local rec = state.placements[key]
		if rec and rec.complete then
			report.already_done = report.already_done + 1
		else
			rec = rec or {nodes = {}}
			state.placements[key] = rec
			local search = all_names
			local required = env.required_nodes and env.required_nodes(s) or nil
			if required then
				search = {}
				local seen = {}
				for _, n in ipairs(required) do
					if not seen[n] then
						seen[n] = true
						local c = M.classify(n)
						if c == "supported" then
							search[#search + 1] = n
						elseif not c then
							local info = env.node_info(n)
							if info and (info.construct or info.container) then
								local u = unhandled_idx[n]
								if not u then
									u = {name = n, structures = {},
										reason = info.construct and "has on_construct"
											or "is a container"}
									unhandled_idx[n] = u
									report.unhandled[#report.unhandled + 1] = u
								end
								u.structures[#u.structures + 1] = s.id
							end
						end
					end
				end
				table.sort(search)
			end
			local clean = true
			if #search > 0 then
				for _, pos in ipairs(env.find_nodes(s.min, s.max, search)) do
					local pk = pkey(pos)
					if not rec.nodes[pk] then
						local name = env.node_name(pos)
						local rule = M.SUPPORTED[name]
						if not rule then
							-- changed since the search; not ours to initialize
							clean = false
						elseif not env.is_registered(name) then
							report.unregistered[#report.unregistered + 1] =
								{id = s.id, name = name, pos = pos}
							clean = false
						else
							local ok, msg = init_node(rule, name, pos, env)
							if ok then
								rec.nodes[pk] = true
								report.initialized = report.initialized + 1
								report.by_name[name] = (report.by_name[name] or 0) + 1
							else
								clean = false
								report.failed[#report.failed + 1] =
									{id = s.id, name = name, pos = pos, message = msg}
							end
						end
					end
				end
			end
			rec.complete = clean
		end
	end
	table.sort(report.unhandled, function(a, b) return a.name < b.name end)
	report.ok = #report.failed == 0 and #report.unhandled == 0 and #report.unregistered == 0
	return report
end

-- One-line summary for logs and chat.
function M.format(report)
	local names = {}
	for n, c in pairs(report.by_name) do names[#names + 1] = n .. " x" .. c end
	table.sort(names)
	return ("initialized %d nodes in %d placements (%d already complete)%s; %d failed, %d unregistered, %d unhandled"):format(
		report.initialized, report.placements, report.already_done,
		#names > 0 and (": " .. table.concat(names, ", ")) or "",
		#report.failed, #report.unregistered, #report.unhandled)
end

------------------------------------------------------------------------
-- core.* adapter (the only part that touches the engine)
------------------------------------------------------------------------
-- c: the engine table (core); globals: {itemframes = mcl_itemframes,
-- chests = mcl_chests} (either may be nil), and required(structure) ->
-- names, supplied by the builder's env.
function M.core_env(c, globals, required)
	globals = globals or {}
	local env = {}
	function env.required_nodes(s) return required and required(s) or nil end
	function env.find_nodes(minp, maxp, names)
		return c.find_nodes_in_area(minp, maxp, names)
	end
	function env.node_name(pos) return c.get_node(pos).name end
	function env.is_registered(name) return c.registered_nodes[name] ~= nil end
	function env.node_info(name)
		local def = c.registered_nodes[name]
		if not def then return nil end
		return {construct = def.on_construct ~= nil,
			container = (c.get_item_group(name, "container") or 0) > 0}
	end
	function env.callback(name, field)
		local def = c.registered_nodes[name]
		return def and def[field] or nil
	end
	function env.snapshot(pos) return c.get_meta(pos):to_table() end
	function env.restore(pos, snap)
		local meta = c.get_meta(pos)
		for k, v in pairs(snap.fields or {}) do meta:set_string(k, v) end
		local inv = meta:get_inventory()
		for list, items in pairs(snap.inventory or {}) do
			inv:set_size(list, #items)
			inv:set_list(list, items)
		end
	end
	function env.ensure_list(pos, list, size)
		local inv = c.get_meta(pos):get_inventory()
		if inv:get_size(list) == 0 then inv:set_size(list, size) end
	end
	function env.refresh(kind, pos, name)
		if kind == "itemframe" then
			if globals.itemframes and globals.itemframes.update_entity then
				globals.itemframes.update_entity(pos)
			end
		elseif kind == "chest_entity" then
			if globals.chests and globals.chests.select_and_spawn_entity
					and c.get_item_group(name, "chest_entity") > 0 then
				globals.chests.select_and_spawn_entity(pos, c.get_node(pos))
			end
		elseif kind == "armor_stand" then
			-- on_construct always adds an entity: only add one when none stands there.
			for _, obj in ipairs(c.get_objects_inside_radius(pos, 0)) do
				local le = obj:get_luaentity()
				if le and le.name == "mcl_armor_stand:armor_entity" then return end
			end
			local fn = c.registered_nodes[name].on_construct
			if fn then fn(pos) end
		end
	end
	return env
end

return M
