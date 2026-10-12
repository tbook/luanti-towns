-- Towns: flat-town builder (ticket #15). Turns one validated plan plus its
-- inspected site (site_search result) into nodes: flat supported ground at the
-- median level, paved streets and squares, and temporary cathedral and castle
-- blockouts. The intended layout is pure Lua (src/town_layout.lua,
-- src/blockouts.lua); this module orchestrates checks and writes through an
-- injectable `env`, so the whole thing runs under plain Lua 5.1 in tests.
--
--   local builder = dofile(".../builder.lua")(placement, planner)
--   local summary, message, code = builder.build(result [, opts [, env]])
--
--   result  a site_search result (needs plan, ground_y, heights, build_bounds,
--           build_volume; center and min/max_height are used when present)
--   opts    optional table; opts.log = false silences env.log
--   env     defaults to builder.core_env(core), see below
--
-- Success: summary table (see below). Failure: nil, message, code with code
-- one of
--   bad_result      result is not a complete site_search result
--   invalid_plan    planner.validate rejected the plan, or the blockouts do
--                   not fit it
--   invalid_palette a required node name is not registered
--   inspection_failed  the area could not be opened, is not loaded (ignore
--                   nodes), a surface node is missing, or liquid appeared
--   write_failed    the engine raised while committing (the only code that
--                   may follow a partial write)
-- Every code except write_failed guarantees that nothing was written.
--
-- Sequence: validate result -> planner.validate(plan) -> static palette ->
-- open the region read-only -> read every column's surface -> layout ->
-- full palette -> inspect every row to be written -> confinement check ->
-- write only the changed nodes -> commit. Writes lie inside
-- result.build_bounds (never outside) and inside the boundary column union.
--
-- env contract:
--   env.node_info(name)           {walkable, liquid, clearable} or nil
--   env.open_region(minpos, maxpos)
--       -> region | nil, err      region.get(x, y, z) -> name ("ignore" when
--                                 not loaded), region.get_param2(x, y, z),
--                                 region.set(x, y, z, name, param2),
--                                 region.commit(). The region must not touch
--                                 the world before commit().
--   env.log(level, msg)           optional
--
-- Summary (for the command ticket to print):
--   seed, center {x, z}, ground_y, bounds {min, max} (build_bounds),
--   plan_bounds {x1, z1, x2, z2}, volume (build_volume),
--   sites = {cathedral|castle = {rect, entrance, side, opening = {...}},
--            parvis|market = {rect}},
--   approaches = {{name, side, pos}, ...},
--   counts = {streets, principal, secondary, blocks, frontage, columns,
--             paved_columns},
--   nodes = {examined, changed, by_kind = {clear, fill, surface, pave,
--            landmark}, by_name = {[name] = n}},
--   palette = {names}

return function(placement, planner)

local M = {}

local function load_sibling(name)
	local c = rawget(_G, "core")
	if c and c.get_modpath and c.get_current_modname then
		return dofile(c.get_modpath(c.get_current_modname()) .. "/src/" .. name)
	end
	return dofile("src/" .. name)
end
local blockouts = load_sibling("blockouts.lua")
local TL = load_sibling("town_layout.lua")(blockouts)
M.blockouts = blockouts
M.layout = TL

local function is_int(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
		and v == math.floor(v)
end

local function check_vec(v)
	return type(v) == "table" and is_int(v.x) and is_int(v.y) and is_int(v.z)
end

local function fmt_bounds(b)
	return ("(%d,%d,%d) to (%d,%d,%d)"):format(b.min.x, b.min.y, b.min.z, b.max.x, b.max.y, b.max.z)
end

-- Validates the structural shape of a site_search result. Returns true or
-- nil, message[, code].
function M.check_result(result)
	if type(result) ~= "table" then return nil, "result is not a table" end
	if type(result.plan) ~= "table" then return nil, "result.plan missing" end
	if not is_int(result.ground_y) then return nil, "result.ground_y must be an integer" end
	if type(result.heights) ~= "table" then return nil, "result.heights missing" end
	for _, k in ipairs({"build_bounds", "build_volume"}) do
		local b = result[k]
		if type(b) ~= "table" or not check_vec(b.min) or not check_vec(b.max) then
			return nil, "result." .. k .. " missing or malformed"
		end
		for _, a in ipairs({"x", "y", "z"}) do
			if b.min[a] > b.max[a] then return nil, "result." .. k .. " is empty" end
		end
	end
	local pb, bb, vol = result.plan.bounds, result.build_bounds, result.build_volume
	if type(pb) ~= "table" then return nil, "plan.bounds missing", "invalid_plan" end
	if bb.min.x ~= pb.x1 or bb.max.x ~= pb.x2 or bb.min.z ~= pb.z1 or bb.max.z ~= pb.z2 then
		return nil, "build_bounds X/Z differ from the plan bounds"
	end
	for _, a in ipairs({"x", "y", "z"}) do
		if vol.min[a] > bb.min[a] or vol.max[a] < bb.max[a] then
			return nil, "build_volume does not contain build_bounds"
		end
	end
	return true
end

local function palette_problem(env, names)
	for _, name in ipairs(names) do
		if name ~= "air" and not env.node_info(name) then
			return name
		end
	end
end

local function is_ground(info)
	return info ~= nil and info.walkable and not info.liquid and not info.clearable
end

function M.build(result, opts, env)
	opts = opts or {}
	env = env or M.core_env(core)
	local log = function(level, msg)
		if opts.log ~= false and env.log then env.log(level, msg) end
	end
	local function fail(code, msg)
		log("warning", "towns builder: rejected (" .. code .. "): " .. msg .. ". Nothing was written.")
		return nil, msg, code
	end

	-- 1. The inspected site.
	local ok, why, why_code = M.check_result(result)
	if not ok then return fail(why_code or "bad_result", why) end
	local plan, g = result.plan, result.ground_y
	local bb = result.build_bounds

	-- 2. The plan must still validate.
	local vok, vwhy = planner.validate(plan)
	if not vok then return fail("invalid_plan", tostring(vwhy)) end
	if type(plan.seed) ~= "number" or type(plan.center) ~= "table" then
		return fail("invalid_plan", "plan has no seed or centre")
	end
	log("action", ("towns builder: seed=%s center=(%d,%d) ground_y=%d bounds=%s"):format(
		tostring(plan.seed), plan.center.x, plan.center.z, g, fmt_bounds(bb)))
	log("action", "towns builder: [1/6] plan validated")

	-- 3. Static palette (landmarks, pavement, fill) before reading anything.
	local static = {TL.FILL_DIRT, TL.FILL_DEEP, TL.DEFAULT_SURFACE}
	for _, n in ipairs(blockouts.names()) do static[#static + 1] = n end
	for _, name in ipairs({"market", "parvis"}) do static[#static + 1] = plan.sites[name].material end
	for _, s in ipairs(plan.streets) do static[#static + 1] = s.material end
	for _, n in ipairs(static) do
		if type(n) ~= "string" then return fail("invalid_plan", "pavement without a material name") end
	end
	local missing = palette_problem(env, static)
	if missing then return fail("invalid_palette", "node '" .. missing .. "' is not registered") end
	log("action", ("towns builder: [2/6] palette ok (%d static names)"):format(#static))

	-- 4. Open the region and read each column's surface.
	local region, err = env.open_region(bb.min, bb.max)
	if not region then
		return fail("inspection_failed", "cannot read the build area: " .. tostring(err))
	end
	local surf, surf_p2 = {}, {}
	local rects = plan.boundary.rects
	do
		local seen = {}
		for _, r in ipairs(rects) do
			for x = r.x1, r.x2 do
				for z = r.z1, r.z2 do
					seen[x] = seen[x] or {}
					if not seen[x][z] then
						seen[x][z] = true
						local h = result.heights[x] and result.heights[x][z]
						if not is_int(h) then
							return fail("bad_result", ("no surface height for column (%d,%d)"):format(x, z))
						end
						if h < bb.min.y or h > bb.max.y then
							return fail("bad_result", ("surface (%d,%d,%d) outside the build bounds"):format(x, h, z))
						end
						local name = region.get(x, h, z)
						if name == "ignore" then
							return fail("inspection_failed",
								("area not loaded at (%d,%d,%d)"):format(x, h, z))
						end
						if not is_ground(env.node_info(name)) then
							return fail("inspection_failed",
								("surface node at (%d,%d,%d) is '%s', not solid ground (stale inspection)")
									:format(x, h, z, tostring(name)))
						end
						surf[x] = surf[x] or {}
						surf[x][z] = name
						surf_p2[x] = surf_p2[x] or {}
						surf_p2[x][z] = region.get_param2 and region.get_param2(x, h, z) or 0
					end
				end
			end
		end
	end

	-- 5. The intended layout.
	local lok, L = pcall(TL.new, plan, g, {
		heights = function(x, z) return result.heights[x][z] end,
		surface = function(x, z) return surf[x][z] end,
		max_y = bb.max.y,
	})
	if not lok then
		return fail("invalid_plan", (tostring(L):gsub("^[^\n]-:%d+: ", "")))
	end
	local palette = L.palette()
	missing = palette_problem(env, palette)
	if missing then return fail("invalid_palette", "node '" .. missing .. "' is not registered") end
	log("action", ("towns builder: [3/6] layout derived for %d columns, palette %d names"):format(
		#L.columns, #palette))

	-- 6. Inspect every row to be written; collect the changes.
	local cx, cy, cz, cname, cp2, ckind = {}, {}, {}, {}, {}, {}
	local n_changed, examined = 0, 0
	local by_kind = {clear = 0, fill = 0, surface = 0, pave = 0, landmark = 0}
	local by_name = {}
	local paved = 0
	for _, c in ipairs(L.columns) do
		local x, z = c.x, c.z
		if L.pavement(x, z) then paved = paved + 1 end
		local ylo, yhi = L.column_range(x, z)
		if ylo < bb.min.y or yhi > bb.max.y then
			return fail("bad_result", ("column (%d,%d) rows %d..%d leave the build bounds"):format(
				x, z, ylo, yhi))
		end
		for y = ylo, yhi do
			local want, kind = L.node_at(x, y, z)
			local have = region.get(x, y, z)
			examined = examined + 1
			if have == "ignore" then
				return fail("inspection_failed", ("area not loaded at (%d,%d,%d)"):format(x, y, z))
			end
			local info = env.node_info(have)
			if info and info.liquid then
				return fail("inspection_failed", ("liquid '%s' at (%d,%d,%d)"):format(have, x, y, z))
			end
			if want and want ~= have then
				if not TL.confined(L.in_town, bb, x, y, z) then
					return fail("bad_result", ("write at (%d,%d,%d) is outside the build bounds"):format(x, y, z))
				end
				n_changed = n_changed + 1
				cx[n_changed], cy[n_changed], cz[n_changed] = x, y, z
				cname[n_changed] = want
				cp2[n_changed] = (kind == "surface") and surf_p2[x][z] or 0
				ckind[n_changed] = kind
				by_kind[kind] = (by_kind[kind] or 0) + 1
				by_name[want] = (by_name[want] or 0) + 1
			end
		end
	end
	log("action", ("towns builder: [4/6] inspected %d nodes; %d changes (clear %d, fill %d, surface %d, pave %d, landmark %d)")
		:format(examined, n_changed, by_kind.clear, by_kind.fill, by_kind.surface,
			by_kind.pave, by_kind.landmark))

	-- 7. Write (the only phase that changes the world).
	log("action", ("towns builder: [5/6] writing %d nodes inside %s"):format(n_changed, fmt_bounds(bb)))
	if n_changed > 0 then
		local wok, werr = pcall(function()
			for i = 1, n_changed do
				region.set(cx[i], cy[i], cz[i], cname[i], cp2[i])
			end
			region.commit()
		end)
		if not wok then
			log("error", "towns builder: write failed: " .. tostring(werr))
			return nil, "write failed: " .. tostring(werr), "write_failed"
		end
	end
	log("action", "towns builder: [6/6] committed; construction complete")

	-- 8. Summary.
	local sites = {}
	for _, name in ipairs(plan.site_order) do
		local s = plan.sites[name]
		sites[name] = {rect = s.rect, side = s.side, entrance = s.entrance,
			opening = L.openings[name]}
	end
	local principal, secondary = 0, 0
	for _, s in ipairs(plan.streets) do
		if s.kind == "principal" then principal = principal + 1 else secondary = secondary + 1 end
	end
	local summary = {
		seed = plan.seed,
		center = {x = plan.center.x, z = plan.center.z},
		ground_y = g,
		bounds = bb,
		plan_bounds = plan.bounds,
		volume = result.build_volume,
		sites = sites,
		approaches = plan.approaches,
		counts = {
			streets = #plan.streets, principal = principal, secondary = secondary,
			blocks = #plan.blocks, frontage = #plan.frontage,
			columns = #L.columns, paved_columns = paved,
		},
		nodes = {examined = examined, changed = n_changed, by_kind = by_kind, by_name = by_name},
		palette = palette,
	}
	log("action", ("towns builder: done seed=%s center=(%d,%d) ground_y=%d bounds=%s streets=%d blocks=%d frontage=%d nodes=%d")
		:format(tostring(plan.seed), plan.center.x, plan.center.z, g, fmt_bounds(bb),
			#plan.streets, #plan.blocks, #plan.frontage, n_changed))
	return summary
end

------------------------------------------------------------------------
-- core.* adapter (the only part that touches the engine)
------------------------------------------------------------------------
function M.core_env(c)
	return {
		node_info = function(name)
			return placement.node_info(c.registered_nodes, name)
		end,
		log = function(level, msg) c.log(level, msg) end,
		open_region = function(minpos, maxpos)
			local vm = c.get_voxel_manip()
			local emin, emax = vm:read_from_map(minpos, maxpos)
			local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
			local data, p2 = vm:get_data(), vm:get_param2_data()
			local ids, names = {}, {}
			local function id_of(name)
				local id = ids[name]
				if not id then id = c.get_content_id(name); ids[name] = id end
				return id
			end
			local function name_of(id)
				local n = names[id]
				if not n then n = c.get_name_from_content_id(id); names[id] = n end
				return n
			end
			local r = {}
			function r.get(x, y, z) return name_of(data[area:index(x, y, z)]) end
			function r.get_param2(x, y, z) return p2[area:index(x, y, z)] end
			function r.set(x, y, z, name, param2)
				local i = area:index(x, y, z)
				data[i] = id_of(name)
				p2[i] = param2 or 0
			end
			function r.commit()
				vm:set_data(data)
				vm:set_param2_data(p2)
				vm:write_to_map(true)
			end
			return r
		end,
	}
end

return M

end
