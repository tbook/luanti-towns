-- Towns: resident adapter, step one (ticket #47): enumerate the valid beds
-- inside placed schematic boxes. Nothing is spawned or claimed here; ticket
-- #48 extends this module with spawning and the claim.
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
	return env
end

return M
