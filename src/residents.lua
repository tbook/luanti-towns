-- Towns: resident adapter. Ticket #47: enumerate the valid beds inside placed
-- schematic boxes (M.enumerate, read-only). Ticket #48: spawn one villager per
-- valid bed once and claim the bed (M.initialize, below).
--
-- Bed convention (VoxeLibre mcl_beds/api.lua and functions.lua, and Living
-- Villages births.lua, verified against the installed code):
--   * a bed is two nodes of one colour: "<base>_bottom" (group bed=1) and
--     "<base>_top" (group bed=2) with the SAME param2 (facedir);
--   * the top half lies at bottom + facedir_to_dir(param2)
--     (mcl_beds.get_bed_top); facedir 0..3 = (0,0,1) (1,0,0) (0,0,-1) (-1,0,0);
--   * the bottom node's position IS the bed: villagers claim it by writing
--     their id into that node's "villager" meta field and set entity._bed to
--     it; a "player" field marks a player's bed.
-- Colours are not listed here: every node in group "bed" is considered.
--
-- A bed is VALID when it is a paired, consistently oriented bottom/top whose
-- two halves both lie in the owned box, with clear space above both halves
-- and a standing cell beside it, on a long side or an end of the pair: a
-- feet node that is open or a carpet (walkable but 1/16 high, so a villager
-- stands on it), an open head node, and a walkable harmless floor below.
-- That cell is returned as the bed's spawn position.
-- Sibling rule: a bed without a cell of its own is also valid when orthogonally
-- adjacent to a valid bed with headroom; it then spawns at the sibling's cell.
--
-- Note: villagers can still claim any bed within 48 blocks regardless of this
-- enumeration (mobs_mc take_bed). "Skipped" only means "not counted for
-- spawning a resident".
--
-- Searches only inside the given boxes (no nearby search). All engine access
-- is through `env` (M.core_env), so the logic runs against fakes.
local M = {}

local DIRS = {[0] = {x = 0, z = 1}, [1] = {x = 1, z = 0}, [2] = {x = 0, z = -1}, [3] = {x = -1, z = 0}}
local SIDES = {{x = 1, z = 0}, {x = -1, z = 0}, {x = 0, z = 1}, {x = 0, z = -1}}

local function pkey(p) return p.x .. "," .. p.y .. "," .. p.z end

local function inside(box, p)
	return p.x >= box.min.x and p.x <= box.max.x and p.y >= box.min.y and p.y <= box.max.y
		and p.z >= box.min.z and p.z <= box.max.z
end

local function sort_pos(a, b)
	if a.x ~= b.x then return a.x < b.x end
	if a.y ~= b.y then return a.y < b.y end
	return a.z < b.z
end

-- Skip reasons and their category: malformed (not a complete, consistent
-- bed) or inaccessible (a bed, but nobody can use it).
M.REASONS = {
	orphan_top = "malformed", missing_top = "malformed", bad_orientation = "malformed",
	straddles_box = "malformed",
	blocked_above = "inaccessible", no_standing_space = "inaccessible",
	not_loaded = "inaccessible",
}

-- M.enumerate(boxes, env) -> report
--   boxes  list of {id, kind, min, max, ...} (preflight.compose structures)
--   env    env.find_beds(min, max) -> positions of nodes in group "bed"
--          env.get_node(pos) -> {name, param2} | nil (not loaded)
--          env.bed_part(name) -> 1 (bottom), 2 (top) or nil
--          env.is_passable(name) -> bool (feet/head/above: not walkable,
--                                   not liquid, harmless; beds are not)
--          env.is_floor(name) -> bool (walkable, not liquid, harmless)
--          env.is_low(name) -> bool (walkable but a thin covering such as a
--                                   carpet: a feet node a villager stands on)
-- Report:
--   beds          sorted list of {pos, top, name, param2, spawn, id, kind}
--   skipped       sorted list of {pos, name, reason, category, id, kind}
--   count         #beds
--   by_structure  list parallel to boxes: {id, kind, min, valid, skipped}
--   by_color      {bed name without "_bottom" = n}
function M.enumerate(boxes, env)
	local report = {beds = {}, skipped = {}, by_structure = {}, by_color = {}}
	local seen = {}
	local pending = {}

	local function passable(p)
		local n = env.get_node(p)
		return n ~= nil and env.is_passable(n.name)
	end
	local function floor(p)
		local n = env.get_node(p)
		return n ~= nil and env.is_floor(n.name)
	end
	local function feet_ok(p)
		local n = env.get_node(p)
		return n ~= nil and (env.is_passable(n.name) or env.is_low(n.name))
	end
	local function standing_cell(p, other)
		for _, s in ipairs(SIDES) do
			local c = {x = p.x + s.x, y = p.y, z = p.z + s.z}
			if not (c.x == other.x and c.z == other.z)
					and feet_ok(c)
					and passable({x = c.x, y = c.y + 1, z = c.z})
					and floor({x = c.x, y = c.y - 1, z = c.z}) then
				return c
			end
		end
	end

	for _, box in ipairs(boxes) do
		local sum = {id = box.id, kind = box.kind, min = box.min, valid = 0, skipped = 0}
		report.by_structure[#report.by_structure + 1] = sum
		local function skip(p, name, reason)
			report.skipped[#report.skipped + 1] = {pos = p, name = name, reason = reason,
				category = M.REASONS[reason], id = box.id, kind = box.kind}
			sum.skipped = sum.skipped + 1
		end
		local bottoms, tops = {}, {}
		for _, p in ipairs(env.find_beds(box.min, box.max)) do
			if not seen[pkey(p)] then
				seen[pkey(p)] = true
				local node = env.get_node(p)
				if not node then
					skip(p, "ignore", "not_loaded")
				else
					local part = env.bed_part(node.name)
					if part == 1 then bottoms[#bottoms + 1] = {p = p, node = node}
					elseif part == 2 then tops[#tops + 1] = {p = p, node = node} end
				end
			end
		end

		-- Bottoms decide the pair; the top is then consumed so it is not
		-- also reported as an orphan.
		local consumed = {}
		for _, b in ipairs(bottoms) do
			local p, node = b.p, b.node
			local dir = DIRS[node.param2]
			if not dir then
				skip(p, node.name, "bad_orientation")
			else
				local tp = {x = p.x + dir.x, y = p.y, z = p.z + dir.z}
				local top = env.get_node(tp)
				local base = node.name:gsub("_bottom$", "")
				if not top then
					skip(p, node.name, "not_loaded")
				elseif env.bed_part(top.name) ~= 2 or top.name ~= base .. "_top"
						or top.param2 ~= node.param2 then
					skip(p, node.name, "missing_top")
				elseif not inside(box, tp) then
					skip(p, node.name, "straddles_box")
				else
					consumed[pkey(tp)] = true
					seen[pkey(tp)] = true
					local spawn
					if not (passable({x = p.x, y = p.y + 1, z = p.z})
							and passable({x = tp.x, y = tp.y + 1, z = tp.z})) then
						skip(p, node.name, "blocked_above")
					else
						spawn = standing_cell(p, tp) or standing_cell(tp, p)
						if not spawn then
							-- Maybe usable through a sibling bed; decided below.
							pending[#pending + 1] = {p = p, tp = tp, node = node, base = base,
								box = box, sum = sum, skip = skip}
						else
							report.beds[#report.beds + 1] = {pos = p, top = tp, name = node.name,
								param2 = node.param2, spawn = spawn, id = box.id, kind = box.kind}
							sum.valid = sum.valid + 1
							report.by_color[base] = (report.by_color[base] or 0) + 1
						end
					end
				end
			end
		end
		for _, t in ipairs(tops) do
			if not consumed[pkey(t.p)] then skip(t.p, t.node.name, "orphan_top") end
		end
	end
	-- Sibling-bed rule: a bed with no standing cell of its own is valid when
	-- it is orthogonally adjacent (same level) to a bed that has its own
	-- standing cell and headroom above the adjoining half. A villager stands
	-- on the walkable sibling and reaches this bed from there; the spawn is
	-- the sibling's own standing cell. Only beds with their own cell count as
	-- siblings, so a chain of enclosed beds stays skipped.
	local own = {}
	for _, b in ipairs(report.beds) do own[#own + 1] = b end
	for _, q in ipairs(pending) do
		local found
		for _, sib in ipairs(own) do
			for _, sh in ipairs({sib.pos, sib.top}) do
				for _, h in ipairs({q.p, q.tp}) do
					if not found and sh.y == h.y
							and math.abs(sh.x - h.x) + math.abs(sh.z - h.z) == 1
							and passable({x = sh.x, y = sh.y + 1, z = sh.z})
							and passable({x = sh.x, y = sh.y + 2, z = sh.z}) then
						found = sib
					end
				end
			end
		end
		if found then
			report.beds[#report.beds + 1] = {pos = q.p, top = q.tp, name = q.node.name,
				param2 = q.node.param2, spawn = found.spawn, via = found.pos,
				id = q.box.id, kind = q.box.kind}
			q.sum.valid = q.sum.valid + 1
			report.by_color[q.base] = (report.by_color[q.base] or 0) + 1
		else
			q.skip(q.p, q.node.name, "no_standing_space")
		end
	end
	table.sort(report.beds, function(a, b) return sort_pos(a.pos, b.pos) end)
	table.sort(report.skipped, function(a, b) return sort_pos(a.pos, b.pos) end)
	report.count = #report.beds
	return report
end

-- One-line summary for chat and logs.
function M.format(report)
	local reasons = {}
	for _, s in ipairs(report.skipped) do reasons[s.reason] = (reasons[s.reason] or 0) + 1 end
	local parts = {}
	for r, n in pairs(reasons) do parts[#parts + 1] = r .. " x" .. n end
	table.sort(parts)
	return ("%d valid beds, %d skipped%s"):format(report.count, #report.skipped,
		#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or "")
end

------------------------------------------------------------------------
-- Spawn and claim (ticket #48)
------------------------------------------------------------------------
-- VoxeLibre convention (mobs_mc/villager.lua take_bed, Living Villages
-- births.lua create_child): the villager is a "mobs_mc:villager" whose
-- on_spawn assigns entity._id (a uuid); it claims a bed by setting
-- entity._bed to the BOTTOM node position and writing its _id into that
-- node's "villager" meta field. A non-empty "player" field means a player
-- owns the bed. A villager with no _bed claims the nearest free bed itself
-- (within 48), so the claim made here keeps it at its own bed.
--
-- M.initialize(beds, env, store) -> result
--   beds    list from enumerate (report.beds)
--   store   {get(key) -> string|nil, set(key, string|nil)}: persistent
--           record, one key per bed position
--   env     env.bed_owner(bed) -> {villager, player} strings, or nil when
--                not loaded (player is read from both halves)
--           env.spawn(pos) -> handle | nil   (add_entity; nil = failed)
--           env.entity_id(handle) -> string | nil (nil/"" = unusable object)
--           env.claim(handle, pos, id) -> bool (sets _bed and meta; verified)
--           env.remove(handle)
--           env.unclaim(pos, id)
-- Record per bed: "pending" before the spawn, "done:<id>" after the claim.
-- A missing record means untouched; a failed attempt clears its record so
-- it can be retried. A leftover "pending" is an attempt interrupted by a
-- crash or shutdown: it is reported (result.interrupted_beds) and NOT
-- retried, because the villager may already exist. Dead residents keep
-- their "done" record and are never replaced. A throw while processing one
-- bed is caught: that bed is reported as failed (reason "error"), the spawned
-- object is cleaned up if possible, and the loop continues.
--
-- CAVEATS
--   * Records are keyed by bed position and never validated against the
--     world. Re-placing or clearing a town on identical coordinates reports
--     "already initialized" and spawns nothing until the records are cleared
--     (stop the server; sqlite3 <world>/mod_storage.sqlite "delete from
--     entries where modname='towns' and key like 'resident:%'"; also remove
--     existing villagers and bed claims, which are respected).
--   * Mod storage is flushed periodically, so a hard crash can lose a record:
--     a lost "pending" with a spawned villager is protected by the bed's
--     claim meta only if that was saved; a lost "done" can allow a duplicate
--     if the bed meta was not saved either. A clean shutdown is safe.
--   * Skipped beds can be filled with children by Living Villages' own
--     births. That is not a population cap or replenishment by Towns.
function M.record_key(pos) return "resident:" .. pkey(pos) end

function M.initialize(beds, env, store)
	local r = {spawned = 0, already_done = 0, claimed = 0, interrupted = 0, failed = 0,
		failures = {}, interrupted_beds = {}}
	local function fail(b, reason)
		r.failed = r.failed + 1
		r.failures[#r.failures + 1] = {pos = b.pos, reason = reason, id = b.id, kind = b.kind}
	end
	for _, b in ipairs(beds) do
		local key = M.record_key(b.pos)
		-- State visible to the error path below.
		local h, wrote_pending
		local function process()
			local rec = store.get(key)
			if rec == "pending" then
				r.interrupted = r.interrupted + 1
				r.interrupted_beds[#r.interrupted_beds + 1] = {pos = b.pos, id = b.id, kind = b.kind}
				return
			elseif rec and rec ~= "" then
				r.already_done = r.already_done + 1
				return
			end
			local owner = env.bed_owner(b)
			if not owner then return fail(b, "not_loaded") end
			if owner.villager ~= "" or owner.player ~= "" then
				r.claimed = r.claimed + 1
				return
			end
			store.set(key, "pending")
			wrote_pending = true
			h = env.spawn(b.spawn)
			if not h then
				store.set(key, nil)
				return fail(b, "spawn_failed")
			end
			local id = env.entity_id(h)
			if type(id) ~= "string" or id == "" then
				env.remove(h)
				h = nil
				store.set(key, nil)
				return fail(b, "invalid_entity")
			end
			if not env.claim(h, b.pos, id) then
				env.unclaim(b.pos, id)
				env.remove(h)
				h = nil
				store.set(key, nil)
				return fail(b, "claim_failed")
			end
			-- From here the resident exists; done is recorded last.
			store.set(key, "done:" .. id)
			r.spawned = r.spawned + 1
		end
		local ok, err = pcall(process)
		if not ok then
			fail(b, "error")
			r.failures[#r.failures].detail = tostring(err)
			-- Best-effort cleanup. The pending record is cleared only when
			-- the object (if any) is confirmed removed and unclaimed;
			-- otherwise it stays so the next run reports it, not respawns.
			local clean = true
			if h then
				local okc = pcall(function()
					local id = env.entity_id(h)
					if type(id) == "string" and id ~= "" then env.unclaim(b.pos, id) end
					env.remove(h)
				end)
				clean = okc
			end
			if wrote_pending and clean then
				pcall(store.set, key, nil)
			end
		end
	end
	r.summary = M.format_init(r)
	return r
end

-- One line for chat (the per-bed detail goes to the log).
function M.format_init(r)
	local parts = {}
	if r.already_done > 0 then parts[#parts + 1] = r.already_done .. " already initialized" end
	if r.claimed > 0 then parts[#parts + 1] = r.claimed .. " already claimed" end
	if r.interrupted > 0 then parts[#parts + 1] = r.interrupted .. " interrupted earlier, not retried" end
	if r.failed > 0 then parts[#parts + 1] = r.failed .. " failed" end
	return ("Residents: %d spawned, %d skipped, %d failed%s"):format(r.spawned,
		r.already_done + r.claimed + r.interrupted, r.failed,
		#parts > 0 and (" (" .. table.concat(parts, ", ") .. ")") or "")
end

-- Persistent record backed by mod storage (core.get_mod_storage()).
function M.core_store(storage)
	return {
		get = function(k) local v = storage:get_string(k); return v ~= "" and v or nil end,
		set = function(k, v) storage:set_string(k, v or "") end,
	}
end

------------------------------------------------------------------------
-- core.* adapter (the only part that touches the engine)
------------------------------------------------------------------------
function M.core_env(c)
	local env = {}
	function env.find_beds(minp, maxp)
		return c.find_nodes_in_area(minp, maxp, {"group:bed"})
	end
	function env.get_node(p)
		local n = c.get_node_or_nil(p)
		if not n or n.name == "ignore" then return nil end
		return n
	end
	function env.bed_part(name)
		local g = c.get_item_group(name, "bed")
		if g == 1 and name:find("_bottom$") then return 1 end
		if g == 2 and name:find("_top$") then return 2 end
		return nil
	end
	local function harmless(def)
		return (def.damage_per_second or 0) <= 0
			and (def.liquidtype == nil or def.liquidtype == "none")
	end
	function env.is_passable(name)
		local def = c.registered_nodes[name]
		return def ~= nil and def.walkable == false and harmless(def)
	end
	function env.is_low(name)
		return c.get_item_group(name, "carpet") > 0
	end
	function env.is_floor(name)
		local def = c.registered_nodes[name]
		return def ~= nil and def.walkable ~= false and harmless(def)
	end
	-- Spawn / claim (ticket #48).
	function env.bed_owner(b)
		if not c.get_node_or_nil(b.pos) or not c.get_node_or_nil(b.top) then return nil end
		local player = c.get_meta(b.pos):get_string("player")
		if player == "" then player = c.get_meta(b.top):get_string("player") end
		return {villager = c.get_meta(b.pos):get_string("villager"), player = player}
	end
	function env.spawn(p)
		return c.add_entity({x = p.x, y = p.y, z = p.z}, "mobs_mc:villager")
	end
	function env.entity_id(obj)
		local ent = obj:get_luaentity()
		return ent and ent._id or nil
	end
	function env.claim(obj, p, id)
		local ent = obj:get_luaentity()
		if not ent then return false end
		local meta = c.get_meta(p)
		if meta:get_string("villager") ~= "" then return false end
		ent._bed = {x = p.x, y = p.y, z = p.z}
		meta:set_string("villager", id)
		return meta:get_string("villager") == id
	end
	function env.remove(obj) pcall(obj.remove, obj) end
	function env.unclaim(p, id)
		local meta = c.get_meta(p)
		if meta:get_string("villager") == id then meta:set_string("villager", "") end
	end
	return env
end

return M
