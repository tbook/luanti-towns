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
--                   ABOVE a dry column's surface (liquid at or below the
--                   surface row is buried and simply replaced, see
--                   summary.liquids)
--   write_failed    the engine raised while writing/committing (the only
--                   code that may follow a partial write); the message says
--                   so and names the bounds, and a 4th return value is
--                   {bounds, planned}. build() itself never raises.
-- Every code except write_failed guarantees that nothing was written.
--
-- Sequence: validate result -> planner.validate(plan) -> static palette ->
-- open the region read-only -> read every column's surface -> layout ->
-- full palette -> inspect every row to be written -> confinement check ->
-- write only the changed nodes -> commit. Writes lie inside
-- result.build_bounds (never outside) and inside the boundary column union.
--
-- env contract:
--   env.node_info(name)           {walkable, liquid, clearable, ice,
--                                 falling} or nil (ice counts as water;
--                                 falling = sand/gravel)
--   env.open_region(minpos, maxpos)
--       -> region | nil, err      region.get(x, y, z) -> name ("ignore" when
--                                 not loaded), region.get_param2(x, y, z),
--                                 region.set(x, y, z, name, param2),
--                                 region.commit(). It is opened over the whole
--                                 write range (write_bounds, support rows
--                                 included) and only accessed inside it. The
--                                 region must not touch the world before
--                                 commit(); an access outside the opened
--                                 range must fail or read "ignore".
--   env.log(level, msg)           optional
--
-- Summary (for the command ticket to print):
--   seed, center {x, z}, ground_y, bounds {min, max} (build_bounds),
--   write_bounds {min, max} = the exact area that may have been modified
--   (build_bounds extended down to the support rows; print this as the
--   "area modified"),
--   plan_bounds {x1, z1, x2, z2}, volume (build_volume),
--   sites = {cathedral|castle = {rect, entrance, side, opening = {...}},
--            parvis|market = {rect}},
--   approaches = {{name, side, pos}, ...},
--   counts = {streets, principal, secondary, blocks, frontage, columns,
--             paved_columns},
--   nodes = {examined, changed, by_kind = {clear, fill, support, surface, pave,
--            landmark}, by_name = {[name] = n}},
--   palette = {names}
--   liquids = {buried, wet, sealed} (ticket #104): liquid/ice nodes replaced
--             inside the owned rows (buried in terrain / in landfilled wet
--             columns) and open cells above ground kept solid or filled
--             because a liquid lies just outside the town beside them.
--             The region is opened one node wider in X/Z for that read.

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
local preflight = load_sibling("preflight.lua")
M.blockouts = blockouts
M.layout = TL
M.preflight = preflight

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
	-- Landfilled wet columns (ticket #104): {surfaces = {[x]={[z]=y}}}. Their
	-- water surface must not be above the finished ground.
	if result.wet ~= nil then
		local surfaces = type(result.wet) == "table" and result.wet.surfaces
		if type(surfaces) ~= "table" then return nil, "result.wet.surfaces missing" end
		for x, col in pairs(surfaces) do
			for z, y in pairs(col) do
				if not is_int(y) or y > result.ground_y then
					return nil, ("water surface at (%s,%s) is above the finished ground"):format(
						tostring(x), tostring(z))
				end
			end
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
		and not info.ice
end

local AIR_INFO = {walkable = false, liquid = false}

local function rects_overlap(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end

-- Town mode setup (ticket #45): composes every structure box, decides which
-- landmarks are real (no blockout) and collects alleys and unpaved holes.
-- Fills `town` {comp, real, alleys, holes}; returns true or nil, message.
function M.prepare_town(town, plan, g, bb)
	local comp, why = preflight.compose(plan, town.entries, g)
	if not comp then return nil, "town content: " .. tostring(why) end
	if #comp.structures == 0 then return nil, "the plan has no buildings to place" end
	town.comp, town.real, town.alleys, town.holes = comp, {}, {}, {}
	for _, b in ipairs(comp.structures) do
		if b.min.x < bb.min.x or b.max.x > bb.max.x or b.min.y < bb.min.y
				or b.max.y > bb.max.y or b.min.z < bb.min.z or b.max.z > bb.max.z then
			return nil, ("%s '%s' lies outside the build bounds"):format(b.kind, b.id)
		end
		if b.kind == "cathedral" or b.kind == "castle" then town.real[b.kind] = true end
		town.holes[#town.holes + 1] = b.rect
		local e = town.entries[b.id]
		if type(e) ~= "table" or type(e.path) ~= "string" then
			return nil, ("'%s' has no schematic path"):format(tostring(b.id))
		end
	end
	for _, a in ipairs(type(plan.content) == "table" and plan.content.alleys or {}) do
		for _, b in ipairs(comp.structures) do
			if rects_overlap(a.rect, b.rect) then
				return nil, ("alley %s overlaps %s '%s'"):format(tostring(a.id), b.kind, b.id)
			end
		end
		town.alleys[#town.alleys + 1] = a
	end
	return true
end

-- Walkability of the way from the door's approach node to the door.
--   st      composed structure (entrance world node, rotation, rect, box)
--   g       finished ground level (the approach is paved street at g)
--   node(x, y, z) -> info, name   info as env.node_info (nil = unknown)
-- The approach is the first node outside the box along the door's front, as
-- in the content planner. The walk is a 4-neighbour search over the box plus
-- a one-node apron (so authored stairs, ramps and gate passages count, not
-- just a straight line) over standing cells:
--   free cell   passable feet and head node and a solid node below
--   step cell   a stair, slab or carpet node itself (feet half a node up),
--               with two free nodes above
-- Doors and gates count as passable. A step may rise one node (jump) or
-- drop three. Returns {approach = {x, z}, steps = n} or nil, reason.
local function passable(i)
	return i ~= nil and not i.liquid and (not i.walkable or i.door)
end
local function solid(i)
	return i ~= nil and i.walkable and not i.liquid and not i.door
end
-- Nodes that are walkable but 1.5 high (fences, walls, panes, bars): never
-- a 1-node step and never ground to stand on; a closed route obstacle.
local function tall(name)
	if name:find("gate", 1, true) then return false end
	return name:find("^mcl_fences:") ~= nil or name:find("^mcl_walls:") ~= nil
		or name:find("_pane", 1, true) ~= nil or name:find("_bars", 1, true) ~= nil
end
-- Half-height walkable nodes on which the feet are half a node up. Double
-- slabs and top slabs are full-height supports instead.
local function partial(name)
	if name:find("slab", 1, true) then
		return name:find("_double", 1, true) == nil and name:find("_top", 1, true) == nil
	end
	return name:find("stair", 1, true) ~= nil or name:find("carpet", 1, true) ~= nil
end
local FRONTS = {[0] = {0, -1}, [90] = {-1, 0}, [180] = {0, 1}, [270] = {1, 0}}
function M.check_door(st, g, node)
	local r, e = st.rect, st.entrance
	local f = FRONTS[st.rotation]
	local ax, az = e.x, e.z
	for _ = 1, 1000 do
		ax, az = ax + f[1], az + f[2]
		if ax < r.x1 or ax > r.x2 or az < r.z1 or az > r.z2 then break end
	end
	local cache = {}
	local function at(x, y, z)
		local k = x .. "," .. y .. "," .. z
		local v = cache[k]
		if v == nil then
			local info, name = node(x, y, z)
			v = {info = info, name = name or ""}
			cache[k] = v
		end
		return v
	end
	local function free(x, y, z) return passable(at(x, y, z).info) end
	-- Height of the feet (in nodes above cell y's bottom) when standing in
	-- cell (x, y, z), or nil when it is not a standing cell.
	local function stand(x, y, z)
		local c = at(x, y, z)
		if partial(c.name) and solid(c.info) and not tall(c.name) then
			if free(x, y + 1, z) and free(x, y + 2, z) then return 0.5 end
			return nil
		end
		local below = at(x, y - 1, z)
		if passable(c.info) and free(x, y + 1, z) and solid(below.info)
				and not partial(below.name) and not tall(below.name) then
			return 0
		end
		return nil
	end
	local ylo, yhi = math.min(st.min.y, g) - 1, math.max(st.max.y, g) + 1
	local function inside(x, z, y)
		return x >= r.x1 - 1 and x <= r.x2 + 1 and z >= r.z1 - 1 and z <= r.z2 + 1
			and y >= ylo and y <= yhi
	end
	if stand(ax, g + 1, az) == nil then
		return nil, ("the approach node (%d,%d) at y=%d is not standable"):format(ax, az, g + 1)
	end
	local seen, queue, head = {}, {{ax, g + 1, az, 0, 0}}, 1
	seen[ax .. "," .. (g + 1) .. "," .. az] = true
	while head <= #queue do
		local c = queue[head]
		head = head + 1
		if c[1] == e.x and c[3] == e.z and c[2] == e.y then
			return {approach = {x = ax, z = az}, steps = c[4]}
		end
		for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
			local nx, nz = c[1] + d[1], c[3] + d[2]
			for dy = 1, -3, -1 do
				local ny = c[2] + dy
				local k = nx .. "," .. ny .. "," .. nz
				if not seen[k] and inside(nx, nz, ny) then
					local h = stand(nx, ny, nz)
					if h ~= nil then
						local rise = (ny + h) - (c[2] + c[5])
						if rise <= 1 and (c[2] + c[5]) - (ny + h) <= 3 then
							seen[k] = true
							queue[#queue + 1] = {nx, ny, nz, c[4] + 1, h}
						end
					end
				end
			end
		end
	end
	return nil, ("no walkable route from the approach (%d,%d) to the door (%d,%d,%d)"):format(
		ax, az, e.x, e.y, e.z)
end

local function build_impl(result, opts, env, st)
	opts = opts or {}
	env = env or M.core_env(core)
	-- Logging must never change the outcome: errors from env.log are swallowed.
	local log = function(level, msg)
		if opts.log ~= false and env.log then pcall(env.log, level, msg) end
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
	if st.town then
		local ok2, why2 = M.prepare_town(st.town, plan, g, bb)
		if not ok2 then return fail("invalid_plan", why2) end
	end
	log("action", ("towns builder: seed=%s center=(%d,%d) ground_y=%d bounds=%s"):format(
		tostring(plan.seed), plan.center.x, plan.center.z, g, fmt_bounds(bb)))
	log("action", "towns builder: [1/6] plan validated")

	-- 3. Static palette (landmarks, pavement, fill) before reading anything.
	local static = {TL.FILL_DIRT, TL.FILL_DEEP, TL.DEFAULT_SURFACE}
	-- A town build places real schematics: no temporary blockout is needed
	-- for a landmark that has one.
	if not st.town then
		for _, n in ipairs(blockouts.names()) do static[#static + 1] = n end
	end
	for _, name in ipairs({"market", "parvis"}) do static[#static + 1] = plan.sites[name].material end
	for _, s in ipairs(plan.streets) do static[#static + 1] = s.material end
	for _, n in ipairs(static) do
		if type(n) ~= "string" then return fail("invalid_plan", "pavement without a material name") end
	end
	local missing = palette_problem(env, static)
	if missing then return fail("invalid_palette", "node '" .. missing .. "' is not registered") end
	log("action", ("towns builder: [2/6] palette ok (%d static names)"):format(#static))

	-- 4..6. Read phase: open the region, read surfaces, derive the layout,
	-- inspect every owned row. Any failure (including an engine error) is an
	-- inspection failure with zero writes.
	-- The whole written range: build_bounds extended down to the support rows.
	local wmin_y = math.min(bb.min.y, g - TL.FILL_DIRT_DEPTH)
	if wmin_y < result.build_volume.min.y then
		return fail("bad_result", "support rows lie below the build volume")
	end
	local wbounds = {
		min = {x = bb.min.x, y = wmin_y, z = bb.min.z},
		max = {x = bb.max.x, y = bb.max.y, z = bb.max.z},
	}
	st.wbounds = wbounds
	local wet = result.wet and result.wet.surfaces or {}
	local function is_wet(x, z) return wet[x] ~= nil and wet[x][z] ~= nil end
	local approach_cols = {}
	for _, a in ipairs(plan.approaches or {}) do
		if a.pos then approach_cols[a.pos.x .. "," .. a.pos.z] = true end
	end
	local NEIGH = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	local function read_phase()
		-- One node wider in X/Z so liquids just outside the town can be
		-- seen (read only; nothing outside wbounds is ever written).
		local rmin = {x = wbounds.min.x - 1, y = wbounds.min.y, z = wbounds.min.z - 1}
		local rmax = {x = wbounds.max.x + 1, y = wbounds.max.y, z = wbounds.max.z + 1}
		local region, err = env.open_region(rmin, rmax)
		if not region then
			return fail("inspection_failed", "cannot read the build area: " .. tostring(err))
		end
		local surf, surf_p2 = {}, {}
		local seen = {}
		for _, r in ipairs(plan.boundary.rects) do
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
						if is_wet(x, z) then
							-- Landfilled lake or river bed: the new ground is the
							-- default surface, not sand/gravel/clay of the bed.
							surf[x][z] = TL.DEFAULT_SURFACE
							surf_p2[x][z] = 0
						end
					end
				end
			end
		end

		-- The intended layout.
		local lopts = {
			heights = function(x, z) return result.heights[x][z] end,
			surface = function(x, z) return surf[x][z] end,
			max_y = bb.max.y,
		}
		if st.town then
			lopts.real, lopts.alleys, lopts.holes = st.town.real, st.town.alleys, st.town.holes
		end
		local lok, L = pcall(TL.new, plan, g, lopts)
		if not lok then
			return fail("invalid_plan", (tostring(L):gsub("^[^\n]-:%d+: ", "")))
		end
		local palette = L.palette()
		local missing = palette_problem(env, palette)
		if missing then return fail("invalid_palette", "node '" .. missing .. "' is not registered") end
		log("action", ("towns builder: [3/6] layout derived for %d columns, palette %d names"):format(
			#L.columns, #palette))

		-- Inspect every owned row; collect the changes.
		local D = {L = L, palette = palette, region = region,
			cx = {}, cy = {}, cz = {}, cname = {}, cp2 = {}, n = 0, examined = 0,
			by_kind = {clear = 0, fill = 0, support = 0, surface = 0, pave = 0, landmark = 0},
			by_name = {}, paved = 0,
			liquids = {buried = 0, wet = 0, sealed = 0}}
		for _, c in ipairs(L.columns) do
			local x, z = c.x, c.z
			if L.pavement(x, z) then D.paved = D.paved + 1 end
			local ylo, yhi = L.column_range(x, z)
			if ylo < wmin_y or yhi > bb.max.y then
				return fail("bad_result", ("column (%d,%d) rows %d..%d leave the build volume"):format(
					x, z, ylo, yhi))
			end
			for y = ylo, yhi do
				local want, kind = L.node_at(x, y, z)
				local have = region.get(x, y, z)
				D.examined = D.examined + 1
				if have == "ignore" then
					return fail("inspection_failed", ("area not loaded at (%d,%d,%d)"):format(x, y, z))
				end
				local info = env.node_info(have)
				local write = false
				local wet_have = info and (info.liquid or info.ice)
				if kind == "support" then
					-- Under the finished ground: anything that is not solid,
					-- stable ground is replaced (air, liquid, ice, sand...).
					write = not (is_ground(info) and not info.falling)
					if wet_have and y <= result.heights[x][z] then D.liquids.buried = D.liquids.buried + 1 end
				else
					if wet_have then
						-- Liquid or ice is expected only in landfilled wet
						-- columns and buried in terrain (at or below the
						-- column's surface row, i.e. inside a cut or under a
						-- fill); exposed liquid above the surface is a stale
						-- inspection. Buried liquid is replaced by the
						-- intended node, so no source can flow into the town.
						if is_wet(x, z) then
							D.liquids.wet = D.liquids.wet + 1
						elseif y <= result.heights[x][z] then
							D.liquids.buried = D.liquids.buried + 1
						else
							return fail("inspection_failed", ("liquid or ice '%s' at (%d,%d,%d)"):format(
								have, x, y, z))
						end
					end
					write = want ~= nil and want ~= have
					-- Seal: open air above ground beside a liquid outside
					-- the town would be flooded. Keep natural solid terrain
					-- there, else put stone (confined to the town columns).
					-- Flow is 4-neighbour horizontal only. Paved columns and
					-- approach columns keep their headroom (y <= g+2) so no
					-- street or door approach is walled off; their sides
					-- are left to the door/approach validation.
					if want == TL.AIR and y > g
							and not (y <= g + 2 and (L.pavement(x, z) or approach_cols[x .. "," .. z])) then
						for _, d in ipairs(NEIGH) do
							local nx, nz = x + d[1], z + d[2]
							if not L.in_town(nx, nz) then
								local ninfo = env.node_info(region.get(nx, y, nz))
								if ninfo and (ninfo.liquid or ninfo.ice) then
									if is_ground(info) and not info.falling then
										write = false
									else
										want, kind, write = TL.FILL_DEEP, "fill", (have ~= TL.FILL_DEEP)
									end
									D.liquids.sealed = D.liquids.sealed + 1
									break
								end
							end
						end
					end
				end
				if write then
					if not TL.confined(L.in_town, wbounds, x, y, z) then
						return fail("bad_result", ("write at (%d,%d,%d) is outside the build volume"):format(x, y, z))
					end
					local n = D.n + 1
					D.n = n
					D.cx[n], D.cy[n], D.cz[n] = x, y, z
					D.cname[n] = want
					D.cp2[n] = (kind == "surface") and surf_p2[x][z] or 0
					D.by_kind[kind] = (D.by_kind[kind] or 0) + 1
					D.by_name[want] = (D.by_name[want] or 0) + 1
				end
			end
		end
		return D
	end
	local rok, D, rmsg, rcode = pcall(read_phase)
	if not rok then
		return fail("inspection_failed", "reading the build area failed: " .. tostring(D))
	end
	if not D then return nil, rmsg, rcode end
	local L, palette, region = D.L, D.palette, D.region
	local n_changed, examined, by_kind, by_name, paved = D.n, D.examined, D.by_kind, D.by_name, D.paved
	local cx, cy, cz, cname, cp2 = D.cx, D.cy, D.cz, D.cname, D.cp2
	log("action", ("towns builder: [4/6] inspected %d nodes; %d changes (clear %d, fill %d, support %d, surface %d, pave %d, landmark %d)")
		:format(examined, n_changed, by_kind.clear, by_kind.fill, by_kind.support, by_kind.surface,
			by_kind.pave, by_kind.landmark))

	-- 7. Write (the only phase that changes the world).
	log("action", ("towns builder: [5/6] writing %d nodes inside %s"):format(n_changed, fmt_bounds(wbounds)))
	if n_changed > 0 then
		st.writing, st.planned = true, n_changed
		local wok, werr = pcall(function()
			for i = 1, n_changed do
				region.set(cx[i], cy[i], cz[i], cname[i], cp2[i])
			end
			region.commit()
		end)
		if not wok then
			local msg = ("write failed: %s. The area %s may be partially written; %d nodes were planned"):format(
				tostring(werr), fmt_bounds(wbounds), n_changed)
			log("error", "towns builder: " .. msg)
			return nil, msg, "write_failed", {bounds = wbounds, planned = n_changed}
		end
	end
	log("action", "towns builder: [6/6] committed")

	-- 7b. Town mode: place the schematics, then verify the doors.
	local town_info
	if st.town then
		local t = st.town
		st.writing = true -- schematic writes may leave a partial town
		st.planned = (st.planned or 0) + #t.comp.structures
		local placed = {}
		local bounds = {min = {x = wbounds.min.x, y = wbounds.min.y, z = wbounds.min.z},
			max = {x = wbounds.max.x, y = wbounds.max.y, z = wbounds.max.z}}
		st.wbounds = bounds
		local function grow(b)
			for _, a in ipairs({"x", "y", "z"}) do
				if b.min[a] < bounds.min[a] then bounds.min[a] = b.min[a] end
				if b.max[a] > bounds.max[a] then bounds.max[a] = b.max[a] end
			end
		end
		local total = #t.comp.structures
		local function partial(building, reason, why)
			local msg = ("write failed: %s '%s' (%s): %s. %d of %d buildings were placed; "
				.. "the area %s may be partially written"):format(
				building.kind, tostring(building.id), reason, why, #placed, total, fmt_bounds(bounds))
			log("error", "towns builder: " .. msg)
			return nil, msg, "write_failed", {bounds = bounds, planned = n_changed,
				reason = reason, building = {id = building.id, kind = building.kind,
				role = building.role, rect = building.rect, min = building.min, max = building.max},
				placed = #placed, total = total}
		end
		for _, b in ipairs(t.comp.structures) do
			local entry = t.entries[b.id]
			-- The box is attempted (and so may be partly written) from here.
			grow(b)
			local pok, r1, r2 = pcall(env.place_structure, b, entry)
			if not pok then return partial(b, "engine_error", tostring(r1)) end
			if not r1 then return partial(b, "placement_failed", tostring(r2 or "placement failed")) end
			placed[#placed + 1] = b.id
		end
		log("action", ("towns builder: [6b/6] placed %d schematics"):format(#placed))
		-- Door approach routes (recessed doors lie inside the box).
		local doors = {}
		for _, b in ipairs(t.comp.structures) do
			local dok, route, why = pcall(M.check_door, b, g, function(x, y, z)
				local name = env.get_node(x, y, z)
				if name == "air" then return AIR_INFO, name end
				return env.node_info(name), name
			end)
			if not dok then return partial(b, "door_check_error", tostring(route)) end
			if not route then return partial(b, "door_unreachable", tostring(why)) end
			doors[#doors + 1] = {id = b.id, kind = b.kind, approach = route.approach,
				entrance = b.entrance, steps = route.steps}
		end
		-- Functional node initialization (ticket #46): only inside the placed
		-- boxes, only after every schematic and door check succeeded.
		local setup
		if env.setup_nodes then
			local sok, rep = pcall(env.setup_nodes, t.comp.structures, t.entries)
			if not sok then
				local msg = ("write failed: node setup raised: %s. %d buildings were placed; "
					.. "the area %s may be partially initialized"):format(tostring(rep), #placed, fmt_bounds(bounds))
				log("error", "towns builder: " .. msg)
				return nil, msg, "write_failed", {bounds = bounds, planned = n_changed,
					reason = "node_setup_error", placed = #placed, total = total}
			end
			setup = rep
			if #rep.failed > 0 or #rep.unregistered > 0 then
				local first = rep.failed[1] or rep.unregistered[1]
				local msg = ("write failed: node setup of %d nodes failed (first: %s at (%d,%d,%d) in '%s'%s). "
					.. "%d buildings were placed; the area %s is built but not fully initialized"):format(
					#rep.failed + #rep.unregistered, first.name, first.pos.x, first.pos.y, first.pos.z,
					tostring(first.id), first.message and (": " .. first.message) or ", not registered",
					#placed, fmt_bounds(bounds))
				log("error", "towns builder: " .. msg)
				return nil, msg, "write_failed", {bounds = bounds, planned = n_changed,
					reason = "node_setup_failed", setup = rep, placed = #placed, total = total}
			end
			for _, u in ipairs(rep.unhandled) do
				log("warning", ("towns builder: node '%s' (%s) in %s needs initialization this adapter does not support"):format(
					u.name, u.reason, table.concat(u.structures, ", ")))
			end
			log("action", "towns builder: [6c/6] node setup: " .. (env.format_setup and env.format_setup(rep) or "done"))
		end
		town_info = {structures = t.comp.structures, bounds = bounds, doors = doors,
			alleys = t.alleys, placed = #placed, setup = setup}
	end
	log("action", "towns builder: construction complete")

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
		write_bounds = wbounds,
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
		liquids = D.liquids,
		palette = palette,
	}
	if town_info then
		summary.town = {
			complete = true,
			structures = town_info.structures, placed = town_info.placed,
			doors = town_info.doors, alleys = #town_info.alleys,
			bounds = town_info.bounds,
			setup = town_info.setup,
		}
		summary.write_bounds = town_info.bounds
		-- The real door height (recessed landmark doors sit above ground).
		for _, b in ipairs(town_info.structures) do
			if summary.sites[b.kind] then summary.sites[b.kind].entrance_y = b.entrance.y end
		end
	end
	log("action", ("towns builder: done seed=%s center=(%d,%d) ground_y=%d bounds=%s streets=%d blocks=%d frontage=%d nodes=%d")
		:format(tostring(plan.seed), plan.center.x, plan.center.z, g, fmt_bounds(bb),
			#plan.streets, #plan.blocks, #plan.frontage, n_changed))
	return summary
end

-- Never raises. Anything unexpected before the first write is a failed
-- inspection (zero writes); anything that throws after writing began is
-- write_failed.
local function run(result, opts, env, st)
	local function unwrap(ok, ...)
		if ok then return ... end
		if st.writing then
			-- Anything that throws once writing began may leave a partial town.
			local msg = ("write failed: %s. The area %s may be partially written; %d nodes were planned"):format(
				tostring((...)), fmt_bounds(st.wbounds), st.planned or 0)
			return nil, msg, "write_failed", {bounds = st.wbounds, planned = st.planned}
		end
		return nil, "internal error before any write: " .. tostring((...)), "inspection_failed"
	end
	return unwrap(pcall(build_impl, result, opts, env, st))
end

-- builder.build(result, opts, env): the Phase 2 flat town with blockouts.
function M.build(result, opts, env)
	return run(result, opts, env, {})
end

-- builder.build_town(result, opts, env): ticket #45. Everything build() does
-- except that real cathedral and castle schematics replace the blockouts,
-- planned alleys are paved, and then every composed structure is placed in
-- stable order (preflight.compose order: cathedral, castle, city hall, jail,
-- services, ordinary buildings) with its explicit rotation at its minimum
-- corner. Afterwards each door's approach route is checked.
--   opts.entries  id -> catalog entry {size, entrance, ground_offset, path}
--                 (catalog.entries); required.
--   env additionally provides
--     env.place_structure(structure, entry) -> true | nil, reason
--                 places one composed structure (box = structure.min..max,
--                 rotation = structure.rotation) and must write nothing
--                 outside that box
--     env.get_node(x, y, z) -> node name ("ignore" when not loaded)
--     env.setup_nodes(structures, entries) -> report   (optional, ticket #46)
--                 initializes functional nodes inside the placed boxes once
--                 every schematic and door check succeeded (node_setup.lua);
--                 report.failed/unregistered entries fail the build as
--                 write_failed (reason node_setup_failed); report.unhandled
--                 is logged and returned in summary.town.setup
-- Failure codes are those of build(); everything after the terrain commit is
-- reported as write_failed with extra {bounds = actual attempted bounds,
-- building = {id, kind, rect, min, max}, placed, total, reason} where reason
-- is placement_failed, engine_error, door_unreachable, door_check_error,
-- node_setup_failed or node_setup_error.
-- Success: the build() summary plus summary.town {complete = true, structures,
-- placed, doors, alleys, bounds}; write_bounds then covers every structure.
-- The caller runs preflight.check first (files, node registration, emerge).
function M.build_town(result, opts, env)
	opts = opts or {}
	if type(opts.entries) ~= "table" then
		return nil, "builder.build_town needs opts.entries", "bad_result"
	end
	env = env or M.core_env(core)
	if type(env.place_structure) ~= "function" or type(env.get_node) ~= "function" then
		return nil, "env cannot place schematics (place_structure/get_node)", "bad_result"
	end
	return run(result, opts, env, {town = {entries = opts.entries}})
end

------------------------------------------------------------------------
-- core.* adapter (the only part that touches the engine)
------------------------------------------------------------------------
-- extras (town placement): {schematic = towns.schematic, modpath = string}
function M.core_env(c, extras)
	extras = extras or {}
	local env
	env = {
		get_node = function(x, y, z)
			return c.get_node({x = x, y = y, z = z}).name
		end,
		-- Places one composed structure through the towns schematic helper
		-- (decoration and inventory restoration included). The schematic
		-- file must have exactly the validated size, so no air is written
		-- outside the structure's box.
		place_structure = function(b, entry)
			if not extras.schematic then return nil, "no schematic helper" end
			local path = extras.modpath .. "/" .. entry.path
			local sc = c.read_schematic(path, {})
			if not sc or not sc.size then return nil, "schematic " .. entry.path .. " unreadable" end
			local sx, sz = sc.size.x, sc.size.z
			if b.rotation == 90 or b.rotation == 270 then sx, sz = sz, sx end
			if sx ~= b.size.x or sc.size.y ~= b.size.y or sz ~= b.size.z then
				return nil, "schematic " .. entry.path .. " does not have the validated size"
			end
			-- With the node setup adapter present the blanket constructors are
			-- skipped; the adapter runs once, after every schematic is placed.
			return extras.schematic.place(entry, b.min, b.rotation, extras.modpath,
				extras.node_setup and {initialize = false} or nil)
		end,
		node_info = function(name)
			return placement.node_info(c.registered_nodes, name)
		end,
		log = function(level, msg) c.log(level, msg) end,
		open_region = function(minpos, maxpos)
			local vm = c.get_voxel_manip()
			local emin, emax = vm:read_from_map(minpos, maxpos)
			-- The emerged area is snapped to whole mapblocks; it must hold
			-- the requested range, and every access is checked against it
			-- (VoxelArea:index does no bounds check and would alias).
			if emin.x > minpos.x or emin.y > minpos.y or emin.z > minpos.z
					or emax.x < maxpos.x or emax.y < maxpos.y or emax.z < maxpos.z then
				error("voxel area does not contain the requested range")
			end
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
			local function inside(x, y, z)
				return x >= emin.x and x <= emax.x and y >= emin.y and y <= emax.y
					and z >= emin.z and z <= emax.z
			end
			local r = {}
			function r.get(x, y, z)
				if not inside(x, y, z) then return "ignore" end
				local id = data[area:index(x, y, z)]
				if id == nil then return "ignore" end
				return name_of(id)
			end
			function r.get_param2(x, y, z)
				if not inside(x, y, z) then return 0 end
				return p2[area:index(x, y, z)] or 0
			end
			function r.set(x, y, z, name, param2)
				if not inside(x, y, z) then
					error(("write at (%d,%d,%d) is outside the voxel area"):format(x, y, z))
				end
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
	-- Functional node initialization (ticket #46). extras.node_setup is the
	-- src/node_setup.lua module, extras.globals {itemframes, chests}. The
	-- state table makes a repeated call a no-op for completed placements.
	if extras.node_setup and extras.schematic then
		local setup_state = {}
		env.setup_nodes = function(structures, entries)
			local hooks = extras.node_setup.core_env(c, extras.globals, function(b)
				local entry = entries[b.id]
				return entry and extras.schematic.required_nodes(entry, extras.modpath) or nil
			end)
			return extras.node_setup.initialize(structures, hooks, setup_state)
		end
		env.format_setup = extras.node_setup.format
	end
	return env
end

return M

end
