-- Write-capable containment test for automatic towns (#392, assumption A12).
-- Installed only in a scratch world by tools/auto_towns_containment/run.py.
--
-- For each sample it searches for a real town site, builds the town through the
-- public pipeline (towns.populated.search / towns.populated.build), and compares
-- every node that changed against the #393 envelope (src/auto_bounds.lua
-- plan_envelope). The envelope is computed from the same plan, wall, wall features
-- and ground that the build uses, at the moment build_town is entered (before any
-- node is written). The region around the envelope is snapshotted with
-- VoxelManip (content id + param2 of every node) just before the first write, again
-- at each pipeline stage boundary (by wrapping the public stage functions
-- terrain.smooth_boundary, towns.outskirts.search and towns.outskirts_build.apply, and
-- builder.build_town) and when the build reports completion. The difference between
-- consecutive snapshots is the set of nodes that stage wrote; the difference between
-- the first and last is the aggregate. No per-node interception is used.
--
-- Reads: every core.emerge_area request made while the build runs is recorded and
-- compared to the envelope's read box. (VoxelManip and get_node reads inside the
-- dependencies are not observable without interception, so the read side is the
-- emerge requests plus the search volumes the pipeline itself reports.)
local family = core.settings:get("containment_family") or "medieval-walled"
local count = tonumber(core.settings:get("containment_count")) or 3
local first_index = tonumber(core.settings:get("containment_first_index")) or 1
local first_seed = tonumber(core.settings:get("containment_first_seed")) or 1
local spacing = tonumber(core.settings:get("containment_spacing")) or 2500
local RING = tonumber(core.settings:get("containment_ring")) or 80 -- nodes around the envelope read box
local SETTLE = tonumber(core.settings:get("containment_settle_seconds")) or 30
local CONTROL_SECONDS = tonumber(core.settings:get("containment_control_seconds")) or 0
local OUT = core.get_worldpath() .. "/containment-%s.json"

-- The harness is not the Towns mod: medieval_walls.lua finds its siblings with
-- core.get_current_modname(), so loading auto_bounds (which loads them) is done under a
-- shim that reports "towns". In the real mod, auto_bounds is loaded while Towns loads.
local function as_towns(fn, ...)
	local saved = core.get_current_modname
	core.get_current_modname = function() return "towns" end
	local res = {pcall(fn, ...)}
	core.get_current_modname = saved
	if not res[1] then error(res[2], 0) end
	return unpack(res, 2)
end
local ab = as_towns(dofile, towns.modpath .. "/src/auto_bounds.lua")
local roads = towns.town_roads
local report = {family = family, samples = {}, errors = {}}

local function write_json(name, value)
	local f = assert(io.open(OUT:format(name), "w"))
	f:write(core.write_json(value, true))
	f:close()
end

local function copy_box(b)
	return {min = {x = b.min.x, y = b.min.y, z = b.min.z}, max = {x = b.max.x, y = b.max.y, z = b.max.z}}
end

local function in_box(b, x, y, z)
	return x >= b.min.x and x <= b.max.x and y >= b.min.y and y <= b.max.y and z >= b.min.z and z <= b.max.z
end

-- Distance of a point outside a box along each axis (0 when inside on that axis).
local function excess(b, x, y, z)
	return {x = math.max(b.min.x - x, x - b.max.x, 0), y = math.max(b.min.y - y, y - b.max.y, 0),
		z = math.max(b.min.z - z, z - b.max.z, 0)}
end

-- ---------------------------------------------------------------- providers
local function make_providers()
	local lv = rawget(_G, "living_villages")
	assert(lv and lv.terrain and lv.terrain.volume and lv.terrain.boundary_volume, "Living Villages terrain API missing")
	local settlements = assert(rawget(_G, "settlements"), "settlements global missing")
	local config = as_towns(ab.default_config)
	local ok, planner = pcall(dofile, core.get_modpath("living_villages") .. "/site_planner.lua")
	local v = ok and type(planner) == "table" and planner.config
	report.village_config_source = v and "living_villages/site_planner.lua M.config" or "fallback constants"
	v = v or {cell = 16, max_cells = 5, relocate_step = 8, relocate_rings = 4, radius_jitter = 2}
	config.village = {cell = v.cell, max_cells = v.max_cells, relocate_step = v.relocate_step,
		relocate_rings = v.relocate_rings, radius_jitter = v.radius_jitter}
	local rural = dofile(towns.modpath .. "/schematics/outskirts/catalog.lua")
	local outskirts = {}
	for _, id in ipairs({"farm", "shepherd_hut", "villa"}) do
		outskirts[#outskirts + 1] = {id = id, size = rural[id].size}
	end
	outskirts[#outskirts + 1] = {id = "chapel", size = towns.catalog.entries.chapel.size}
	local village = {}
	for _, s in ipairs(settlements.schematic_table) do
		village[#village + 1] = {name = s.name, hwidth = s.hwidth, hdepth = s.hdepth, hheight = s.hheight}
	end
	local wall_features = {}
	for id, e in pairs(towns.catalog.entries) do
		if id:match("^wall_") and e.size then wall_features[#wall_features + 1] = {id = id, size = e.size} end
	end
	table.sort(wall_features, function(a, b) return a.id < b.id end)
	return {
		config = config,
		assets = {outskirts = outskirts, village = village, wall_features = wall_features},
		volume = {
			terrain = function(p, s, o) return lv.terrain.volume(p, s, o) end,
			boundary = function(r, g, o) return lv.terrain.boundary_volume(r, g, o) end,
		},
	}
end

-- ----------------------------------------------------------------- snapshots
-- One mapblock is packed to its content ids and param2 values and compressed. The deflate
-- output is deterministic, so unchanged blocks compare equal without decompressing.
-- NOTE: a VoxelManip reused across read_from_map calls gets slower with every call
-- (measured: get_data 0.9 ms to 6.7 ms per mapblock over 875 blocks, versus 8 us with a
-- fresh VoxelManip each time), so every block is read with a fresh one.
local function pack_block(vm)
	return table.concat(vm:get_data(), ",", 1, 4096) .. "|" .. table.concat(vm:get_param2_data(), ",", 1, 4096)
end

local function take_snapshot(lo, hi)
	local snap = {lo = lo, hi = hi, blocks = {}, count = 0, ignore = 0}
	local ignore_id = core.get_content_id("ignore")
	for bz = math.floor(lo.z / 16), math.floor(hi.z / 16) do
		for by = math.floor(lo.y / 16), math.floor(hi.y / 16) do
			for bx = math.floor(lo.x / 16), math.floor(hi.x / 16) do
				local o = {x = bx * 16, y = by * 16, z = bz * 16}
				local vm = VoxelManip()
				vm:read_from_map(o, {x = o.x + 15, y = o.y + 15, z = o.z + 15})
				if vm:get_data()[1] == ignore_id then snap.ignore = snap.ignore + 1 end
				snap.blocks[bx .. "," .. by .. "," .. bz] = {bx, by, bz, core.compress(pack_block(vm), "deflate")}
				snap.count = snap.count + 1
			end
		end
	end
	return snap
end

-- Calls fn(x, y, z, before_id, after_id, before_p2, after_p2) for every node that differs
-- from `before`, and returns the number of changed blocks and a fresh snapshot of the same
-- blocks (so a chain of stage diffs reads each block once per mark).
local function diff_snapshot(before, fn)
	local changed_blocks = 0
	local fresh = {lo = before.lo, hi = before.hi, blocks = {}, count = before.count, ignore = before.ignore}
	for key, rec in pairs(before.blocks) do
		local o = {x = rec[1] * 16, y = rec[2] * 16, z = rec[3] * 16}
		local vm = VoxelManip()
		vm:read_from_map(o, {x = o.x + 15, y = o.y + 15, z = o.z + 15})
		local packed = pack_block(vm)
		local comp = core.compress(packed, "deflate")
		fresh.blocks[key] = {rec[1], rec[2], rec[3], comp}
		if comp ~= rec[4] then
			changed_blocks = changed_blocks + 1
			local old = core.decompress(rec[4], "deflate")
			local function split(str)
				local ids, p2, n, bar = {}, {}, 0, str:find("|", 1, true)
				for v in str:sub(1, bar - 1):gmatch("%d+") do n = n + 1; ids[n] = tonumber(v) end
				n = 0
				for v in str:sub(bar + 1):gmatch("%d+") do n = n + 1; p2[n] = tonumber(v) end
				return ids, p2
			end
			local oi, op = split(old)
			local ni, np = split(packed)
			for k = 1, 4096 do
				if oi[k] ~= ni[k] or op[k] ~= np[k] then
					local j = k - 1
					fn(o.x + j % 16, o.y + math.floor(j / 16) % 16, o.z + math.floor(j / 256), oi[k], ni[k], op[k], np[k])
				end
			end
		end
	end
	return changed_blocks, fresh
end

-- --------------------------------------------------------------- classification
-- Natural liquid reflow is not a Towns write: after chunks load, the liquid simulation moves
-- liquid into air and buildable_to nodes (snow, plants) and renews sources. A change outside
-- every allowed box counts as reflow only if it is a node becoming liquid or a liquid
-- becoming air. The control run (--control) shows these appear with no build at all. Reflow
-- inside a write box is just a change in that box.
local liquid_cache = {}
local function liquid_kind(name)
	local v = liquid_cache[name]
	if v == nil then
		local def = core.registered_nodes[name]
		v = def and def.liquidtype or "none"
		if v == nil then v = "none" end
		liquid_cache[name] = v
	end
	return v
end
local function is_reflow(oname, nname)
	if liquid_kind(nname) ~= "none" then return true end
	return liquid_kind(oname) ~= "none" and nname == "air"
end

local function base_name(name) return (name:gsub("%[%d+%]$", "")) end

local function update_bbox(bbox, x, y, z)
	if not bbox then return {min = {x = x, y = y, z = z}, max = {x = x, y = y, z = z}} end
	local a, b = bbox.min, bbox.max
	if x < a.x then a.x = x elseif x > b.x then b.x = x end
	if y < a.y then a.y = y elseif y > b.y then b.y = y end
	if z < a.z then a.z = z elseif z > b.z then b.z = z end
	return bbox
end

-- A classification record for one diff. `allowed` is a set of base stage names whose boxes
-- this diff may legitimately touch; `all_w` is every write box.
local function new_rec(label, allowed_bases, all_w, plan_bounds)
	local boxes = {}
	for _, w in ipairs(all_w) do
		if allowed_bases == true or allowed_bases[w.base] then boxes[#boxes + 1] = w end
	end
	local list = {}
	if allowed_bases == true then list = "all" else for b in pairs(allowed_bases) do list[#list + 1] = b end table.sort(list) end
	return {label = label, allowed = list, boxes = boxes, all_w = all_w, pb = plan_bounds,
		total = 0, in_allowed = 0, in_other_box = 0, outside = 0, reflow = 0,
		by_base = {}, exclusive = {}, max_reach = 0, max_reach_base = {},
		other_examples = {}, outside_examples = {}, outside_by_nearest = {}, transitions = {}}
end

local function classify(rec, x, y, z, oid, nid)
	rec.total = rec.total + 1
	local oname, nname = core.get_name_from_content_id(oid), core.get_name_from_content_id(nid)
	local rf = is_reflow(oname, nname)
	local hits, first = 0, nil
	for _, w in ipairs(rec.boxes) do
		if in_box(w.box, x, y, z) then
			hits = hits + 1
			first = first or w
			rec.by_base[w.base] = (rec.by_base[w.base] or 0) + 1
		end
	end
	if hits > 0 then
		rec.in_allowed = rec.in_allowed + 1
		if not rf then
			local pb = rec.pb
			local d = math.max(pb.x1 - x, x - pb.x2, pb.z1 - z, z - pb.z2, 0)
			if d > rec.max_reach then rec.max_reach = d end
			if hits == 1 then
				if d > (rec.max_reach_base[first.base] or 0) then rec.max_reach_base[first.base] = d end
				local eb = rec.exclusive[first.name]
				if not eb then
					rec.exclusive[first.name] = {nodes = 1, min = {x = x, y = y, z = z}, max = {x = x, y = y, z = z}}
				else
					eb.nodes = eb.nodes + 1
					update_bbox(eb, x, y, z) -- eb has min/max like a bbox
				end
			end
			rec.bbox = update_bbox(rec.bbox, x, y, z)
		end
		return
	end
	-- not inside an allowed box
	if rf then
		rec.reflow = rec.reflow + 1
		rec.reflow_bbox = update_bbox(rec.reflow_bbox, x, y, z)
		return
	end
	local tk = oname .. " -> " .. nname
	rec.transitions[tk] = (rec.transitions[tk] or 0) + 1
	-- inside some other write box?
	local other
	for _, w in ipairs(rec.all_w) do
		if in_box(w.box, x, y, z) then other = w; break end
	end
	if other then
		rec.in_other_box = rec.in_other_box + 1
		if #rec.other_examples < 10 then
			rec.other_examples[#rec.other_examples + 1] = {pos = {x = x, y = y, z = z}, before = oname, after = nname, in_box = other.name}
		end
		return
	end
	rec.outside = rec.outside + 1
	rec.outside_bbox = update_bbox(rec.outside_bbox, x, y, z)
	local best, best_e, best_d
	for _, w in ipairs(rec.all_w) do
		local e2 = excess(w.box, x, y, z)
		local d = math.max(e2.x, e2.y, e2.z)
		if not best_d or d < best_d then best, best_e, best_d = w, e2, d end
	end
	local key = best and best.base or "none"
	local nb = rec.outside_by_nearest[key]
	if not nb then nb = {count = 0, max_excess = {x = 0, y = 0, z = 0}, max_linf = 0}; rec.outside_by_nearest[key] = nb end
	nb.count = nb.count + 1
	if best_e then
		nb.max_excess.x, nb.max_excess.y, nb.max_excess.z = math.max(nb.max_excess.x, best_e.x),
			math.max(nb.max_excess.y, best_e.y), math.max(nb.max_excess.z, best_e.z)
		nb.max_linf = math.max(nb.max_linf, best_d)
	end
	if #rec.outside_examples < 25 then
		rec.outside_examples[#rec.outside_examples + 1] = {pos = {x = x, y = y, z = z}, before = oname, after = nname,
			nearest_stage = key, excess = best_e}
	end
end

local function finish_rec(rec)
	rec.boxes, rec.all_w, rec.pb = nil, nil, nil
	return rec
end

-- --------------------------------------------------------------- one sample
local env_cache
local original_emerge_area = core.emerge_area
local emerges, phase_name = {}, "idle"
core.emerge_area = function(minp, maxp, callback, ...)
	emerges[#emerges + 1] = {phase = phase_name,
		minp = {x = minp.x, y = minp.y, z = minp.z}, maxp = {x = maxp.x, y = maxp.y, z = maxp.z}}
	return original_emerge_area(minp, maxp, callback, ...)
end

local function summary_boxes(summary)
	local out = {}
	local function add(label, b)
		if type(b) == "table" and b.min and b.max then out[#out + 1] = {label = label, box = copy_box(b)}
		elseif type(b) == "table" and b.minp and b.maxp then
			out[#out + 1] = {label = label, box = copy_box({min = b.minp, max = b.maxp})}
		end
	end
	if not summary then return out end
	add("urban_write_bounds", summary.urban_write_bounds)
	add("write_bounds", summary.write_bounds)
	if summary.wall then add("wall.attempted", summary.wall.attempted_bounds) end
	if summary.roads then add("roads.attempted", summary.roads.attempted_bounds) end
	if summary.margins then
		add("margins.attempted", summary.margins.attempted_bounds)
		if summary.margins.stats then add("margins.written", summary.margins.stats.written) end
	end
	local rural = summary.outskirts
	if rural then
		for i, b in ipairs(rural.attempted or {}) do add("outskirts.attempted" .. i, b) end
		for i, b in ipairs(rural.placement_attempted or {}) do add("outskirts.placement" .. i, b) end
		for i, b in ipairs(rural.boxes or {}) do add("outskirts.box" .. i, b) end
	end
	return out
end

local function down(v) return math.floor(v / 16) * 16 end
local function up(v) return math.floor(v / 16) * 16 + 15 end

-- Stage-boundary wrappers. They are installed once per sample before towns.populated.build
-- and act through the per-sample `cur` table (cur.mark is nil outside the build hook).
local cur
local originals
local function install_wrappers()
	local lv = rawget(_G, "living_villages")
	originals = {smooth = lv.terrain.smooth_boundary, search = towns.outskirts.search, apply = towns.outskirts_build.apply}
	lv.terrain.smooth_boundary = function(...)
		if cur and cur.mark then cur.mark("before_margins", {}) end
		local res = {originals.smooth(...)}
		if cur and cur.mark then cur.mark("margins", {city_margins = true}) end
		return unpack(res)
	end
	towns.outskirts.search = function(...)
		-- Between margins and the outskirts search: the wall / feature / approach stage of a
		-- walled town, or the road-exit grading of an unwalled one.
		if cur and cur.mark then
			cur.mark("walls_or_roads", {walls = true, wall_approaches = true, wall_features = true, outside_roads = true})
		end
		return originals.search(...)
	end
	towns.outskirts_build.apply = function(...)
		if cur and cur.mark then cur.mark("before_rural", {}) end
		local res = {originals.apply(...)}
		if cur and cur.mark then cur.mark("rural", {outskirts = true}) end
		return unpack(res)
	end
end
local function remove_wrappers()
	if not originals then return end
	local lv = rawget(_G, "living_villages")
	lv.terrain.smooth_boundary = originals.smooth
	towns.outskirts.search = originals.search
	towns.outskirts_build.apply = originals.apply
	originals = nil
end

local run_sample
run_sample = function(index, done_sample, attempt)
	attempt = attempt or 0
	local seed = first_seed + index - 1
	local col, row = (index - 1) % 4, math.floor((index - 1) / 4)
	local pos = {x = col * spacing + 40 + attempt * 37, y = 9, z = row * spacing + 40 + attempt * 53}
	local sample = {index = index, seed = seed, family = family, pos = pos, attempt = attempt}
	local town_type = family == "roman" and "roman" or nil
	local force_walls
	if family == "medieval-walled" then force_walls = true elseif family == "medieval-unwalled" then force_walls = false end
	local started = core.get_us_time()
	local function finish_sample()
		remove_wrappers()
		cur = nil
		-- The fake player must stand on solid ground; if the grid point is water, a tree or
		-- unloaded, move it a little and search again (up to 8 times) before calling it no_site.
		if sample.status == "no_site" and attempt < 8 and tostring(sample.message):find("standing on solid ground", 1, true) then
			core.log("action", ("[containment] sample %d attempt %d: %s"):format(index, attempt, sample.message))
			return run_sample(index, done_sample, attempt + 1)
		end
		sample.total_s = (core.get_us_time() - started) / 1e6
		report.samples[#report.samples + 1] = sample
		write_json("sample-" .. index, sample)
		write_json("progress", report)
		core.log("action", ("[containment] %s sample %d done: %s"):format(family, index, sample.status or "?"))
		done_sample()
	end
	emerges, phase_name = {}, "start-area"
	original_emerge_area({x = pos.x - 48, y = -64, z = pos.z - 48}, {x = pos.x + 48, y = 200, z = pos.z + 48}, function(_, action, remaining)
		if remaining > 0 then return end
		if action == core.EMERGE_CANCELLED or action == core.EMERGE_ERRORED then
			sample.status = "start_area_failed"; return finish_sample()
		end
		for y = 200, -64, -1 do
			local def = core.registered_nodes[core.get_node({x = pos.x, y = y, z = pos.z}).name]
			if def and def.walkable then pos.y = y + 1; break end
		end
		phase_name = "search"
		emerges = {}
		-- The production search reads the node under the player. With no connected player the
		-- emerged start area may already be unloaded again ('ignore'), so keep it loaded.
		local pinned = {}
		for bx = math.floor((pos.x - 16) / 16), math.floor((pos.x + 16) / 16) do
			for by = math.floor((pos.y - 32) / 16), math.floor((pos.y + 16) / 16) do
				for bz = math.floor((pos.z - 16) / 16), math.floor((pos.z + 16) / 16) do
					local p = {x = bx * 16, y = by * 16, z = bz * 16}
					if core.forceload_block(p, true) then pinned[#pinned + 1] = p end
				end
			end
		end
		local function unpin() for _, p in ipairs(pinned) do core.forceload_free_block(p, true) end pinned = {} end
		local ok, err = pcall(towns.populated.search, pos, seed, town_type, function(result, msg)
			unpin()
			if not result then
				sample.status = "no_site"; sample.message = tostring(msg)
				return finish_sample()
			end
			-- The /towns_generate controller copies force_walls onto the search result (generate.lua).
			result.force_walls = force_walls
			core.log("action", "[containment] site found " .. result.center.x .. "," .. result.center.z .. " ground " .. result.ground_y)
			sample.center, sample.ground_y = result.center, result.ground_y
			sample.plan_bounds = result.plan.bounds
			sample.terrain_height_range = {min = result.min_height, max = result.max_height}
			sample.search_emerges = #emerges
			-- Generate the whole possible window now: the build hook below is synchronous.
			local c, g = result.center, result.ground_y
			-- one chunk beyond the snapshot region so neighbour generation has finished
			local H = 245 + RING + 96
			local wlo = {x = c.x - H, y = g - 128 - RING - 96, z = c.z - H}
			local whi = {x = c.x + H, y = g + 143 + RING + 96, z = c.z + H}
			sample.window = {min = wlo, max = whi}
			phase_name = "window"
			original_emerge_area(wlo, whi, function(_, action2, remaining2)
				if remaining2 > 0 then return end
				if action2 == core.EMERGE_CANCELLED or action2 == core.EMERGE_ERRORED then
					sample.status = "window_emerge_failed"; return finish_sample()
				end
				core.log("action", "[containment] window emerged; settling " .. SETTLE .. " s")
				core.after(SETTLE, function()
				local settled_ok, settled_err = pcall(function()
				if CONTROL_SECONDS > 0 then
					-- Control: no build. Snapshot, wait, diff: everything that changes is ambient.
					local lo = {x = down(c.x - 245 - RING), y = down(g - 127 - RING), z = down(c.z - 245 - RING)}
					local hi = {x = up(c.x + 245 + RING), y = up(g + 142 + RING), z = up(c.z + 245 + RING)}
					local snap = take_snapshot(lo, hi)
					sample.control = {seconds = CONTROL_SECONDS, region = {min = lo, max = hi}, blocks = snap.count}
					core.after(CONTROL_SECONDS, function()
						local trans, total, bbox = {}, 0, nil
						diff_snapshot(snap, function(x, y, z, oid, nid)
							total = total + 1
							local tk = core.get_name_from_content_id(oid) .. " -> " .. core.get_name_from_content_id(nid)
							trans[tk] = (trans[tk] or 0) + 1
							bbox = update_bbox(bbox, x, y, z)
						end)
						sample.control.changed_nodes, sample.control.transitions, sample.control.bbox = total, trans, bbox
						sample.status = "control"
						finish_sample()
					end)
					return
				end
				phase_name = "build"
				emerges = {}
				local original_build_town = towns.builder.build_town
				local snapshot, envelope, wboxes
				cur = {}
				install_wrappers()
				towns.builder.build_town = function(res, ...)
					towns.builder.build_town = original_build_town
					local st = {plan = res.plan, center = res.center, ground_y = res.ground_y, reference_y = res.ground_y,
						build_bounds = res.build_bounds, wall = res.wall, wall_features = res.wall_features}
					sample.has_wall = res.wall ~= nil
					sample.feature_count = res.wall_features and #res.wall_features or 0
					local e, why, code = as_towns(env_cache.plan_envelope, st)
					if not e then
						sample.envelope_declined = {code = code, reason = why}
						-- Measure against the uncapped envelope so the excess is still reported.
						local saved = {ab.CAPS.MAX_REQUEST_CHUNKS, ab.CAPS.MAX_SNAPSHOT_VOXELS}
						ab.CAPS.MAX_REQUEST_CHUNKS, ab.CAPS.MAX_SNAPSHOT_VOXELS = 1e9, 1e18
						e, why, code = as_towns(env_cache.plan_envelope, st)
						ab.CAPS.MAX_REQUEST_CHUNKS, ab.CAPS.MAX_SNAPSHOT_VOXELS = saved[1], saved[2]
					end
					envelope = e
					if not envelope then
						sample.envelope_failed = {code = code, reason = why}
						return original_build_town(res, ...)
					end
					wboxes = {}
					local names = {}
					for name in pairs(envelope.stages) do names[#names + 1] = name end
					table.sort(names)
					for _, name in ipairs(names) do
						local s = envelope.stages[name]
						if s.kind == "write" then wboxes[#wboxes + 1] = {name = name, base = base_name(name), box = s.box} end
					end
					local r = envelope.read
					local lo = {x = down(r.min.x - RING), y = down(r.min.y - RING), z = down(r.min.z - RING)}
					local hi = {x = up(r.max.x + RING), y = up(r.max.y + RING), z = up(r.max.z + RING)}
					sample.snapshot_region = {min = lo, max = hi}
					sample.within_window = in_box(sample.window, lo.x, lo.y, lo.z) and in_box(sample.window, hi.x, hi.y, hi.z)
					local t = core.get_us_time()
					snapshot = take_snapshot(lo, hi)
					sample.snapshot_s = (core.get_us_time() - t) / 1e6
					sample.snapshot_blocks, sample.snapshot_ignore_blocks = snapshot.count, snapshot.ignore
					-- Stage intervals: diff against the previous mark; allowed = the stage's own boxes.
					local intervals, prev, pb = {}, snapshot, res.plan.bounds
					sample.intervals = intervals
					cur.mark = function(label, allowed)
						local ok3, err3 = pcall(function()
							local rec = new_rec(label, allowed, wboxes, pb)
							local t0 = core.get_us_time()
							local _, nxt = diff_snapshot(prev, function(x, y, z, oid, nid) classify(rec, x, y, z, oid, nid) end)
							prev = nxt
							rec.seconds = (core.get_us_time() - t0) / 1e6
							intervals[#intervals + 1] = finish_rec(rec)
						end)
						if not ok3 then sample.harness_error = (sample.harness_error or "") .. " mark " .. label .. ": " .. tostring(err3) end
					end
					local values = {original_build_town(res, ...)}
					cur.mark("urban", {urban_build = true})
					return unpack(values)
				end
				local built_ok, built_err = pcall(towns.populated.build, result, function(summary, bmsg, code, extra)
					towns.builder.build_town = original_build_town
					sample.build_ok = summary ~= nil
					sample.build_message, sample.build_code = bmsg, code
					local ok2, err2 = pcall(function()
						if not envelope or not snapshot then
							sample.status = "no_envelope"
							return
						end
						if cur.mark then cur.mark("final_idle", {}) end
						cur.mark = nil
						sample.envelope = {
							chunks = envelope.chunks, snapshot_voxels = envelope.snapshot_voxels,
							largest_box_voxels = envelope.largest_box_voxels, per_box_chunks = envelope.per_box_chunks,
							read = envelope.read, write = envelope.write, stages = {}}
						for name, s in pairs(envelope.stages) do
							sample.envelope.stages[name] = {kind = s.kind, box = copy_box(s.box)}
						end
						local sboxes = summary_boxes(summary)
						sample.reported_boxes = sboxes
						local pb = result.plan.bounds
						-- Aggregate: first snapshot against the world now; allowed = every write box.
						local agg = new_rec("aggregate", true, wboxes, pb)
						local t = core.get_us_time()
						local changed_blocks = diff_snapshot(snapshot, function(x, y, z, oid, nid)
							classify(agg, x, y, z, oid, nid)
							if #agg.outside_examples <= 25 then
								local ex = agg.outside_examples[#agg.outside_examples]
								if ex and not ex.in_reported and ex.pos.x == x and ex.pos.y == y and ex.pos.z == z then
									ex.in_reported = {}
									for _, rb in ipairs(sboxes) do
										if in_box(rb.box, x, y, z) then ex.in_reported[#ex.in_reported + 1] = rb.label end
									end
								end
							end
						end)
						sample.diff_s = (core.get_us_time() - t) / 1e6
						finish_rec(agg)
						sample.changed = {nodes = agg.total, blocks = changed_blocks, inside_write = agg.in_allowed,
							by_stage = agg.by_base, bbox = agg.bbox, max_reach = agg.max_reach}
						sample.exclusive_extent = agg.exclusive
						sample.outside = {count = agg.outside + agg.reflow, non_liquid = agg.outside, liquid_reflow = agg.reflow,
							non_liquid_bbox = agg.outside_bbox, liquid_reflow_bbox = agg.reflow_bbox,
							by_nearest_stage = agg.outside_by_nearest, examples = agg.outside_examples, transitions = agg.transitions}
						local stage_overrun, intervals_outside = 0, 0
						for _, iv in ipairs(sample.intervals or {}) do
							stage_overrun = stage_overrun + iv.in_other_box
							intervals_outside = intervals_outside + iv.outside
						end
						sample.stage_overrun_nodes, sample.interval_outside_nodes = stage_overrun, intervals_outside
						if agg.bbox then
							local cc = result.center
							sample.changed.relative_to_center = {x1 = agg.bbox.min.x - cc.x, x2 = agg.bbox.max.x - cc.x,
								z1 = agg.bbox.min.z - cc.z, z2 = agg.bbox.max.z - cc.z}
							sample.changed.beyond_plan_bounds = {
								west = pb.x1 - agg.bbox.min.x, east = agg.bbox.max.x - pb.x2,
								south = pb.z1 - agg.bbox.min.z, north = agg.bbox.max.z - pb.z2}
						end
						sample.plan_bounds = pb
						-- Stage box overhang beyond plan.bounds vs stage_reach (horizontal, per side).
						local overhang = {}
						for _, w in ipairs(wboxes) do
							local o = math.max(pb.x1 - w.box.min.x, w.box.max.x - pb.x2, pb.z1 - w.box.min.z,
								w.box.max.z - pb.z2, 0)
							overhang[w.base] = math.max(overhang[w.base] or 0, o)
						end
						sample.stage_overhang = overhang
						local mr = env_cache.max_rect
						sample.max_rect = mr
						if agg.bbox then
							local rc = sample.changed.relative_to_center
							sample.within_max_rect = rc.x1 >= mr.x1 and rc.x2 <= mr.x2 and rc.z1 >= mr.z1 and rc.z2 <= mr.z2
						end
						local ws = {}
						for _, rb in ipairs(sboxes) do
							ws[#ws + 1] = {label = rb.label, contained = ab.contains_box(envelope.write, rb.box), box = rb.box}
						end
						sample.reported_vs_envelope = ws
						-- Read side: emerge requests while the build ran.
						local rbox = envelope.read
						local rd = {total = #emerges, outside_read = {}, max_excess = {x = 0, y = 0, z = 0}}
						for _, em in ipairs(emerges) do
							local ex, ex2 = excess(rbox, em.minp.x, em.minp.y, em.minp.z), excess(rbox, em.maxp.x, em.maxp.y, em.maxp.z)
							local mx = {x = math.max(ex.x, ex2.x), y = math.max(ex.y, ex2.y), z = math.max(ex.z, ex2.z)}
							-- the engine rounds requests to mapblocks: allow the rounding slack of 15
							local over = mx.x > 15 or mx.y > 15 or mx.z > 15
							rd.max_excess.x, rd.max_excess.y, rd.max_excess.z = math.max(rd.max_excess.x, mx.x),
								math.max(rd.max_excess.y, mx.y), math.max(rd.max_excess.z, mx.z)
							if mx.x > 0 or mx.y > 0 or mx.z > 0 then
								rd.outside_read[#rd.outside_read + 1] = {minp = em.minp, maxp = em.maxp, excess = mx,
									beyond_mapblock_slack = over}
							end
						end
						sample.read_side = rd
						sample.reads_beyond_slack = false
						for _, o in ipairs(rd.outside_read) do
							if o.beyond_mapblock_slack then sample.reads_beyond_slack = true end
						end
						sample.inspection_volume = result.inspection_volume
						sample.build_volume = result.build_volume
						if summary then
							sample.pipeline = {
								roads = summary.roads and {graded = summary.roads.graded, failed = summary.roads.failed},
								wall = summary.wall and {features = summary.wall.features and #summary.wall.features},
								margins = summary.margins and {status = summary.margins.status, stats = summary.margins.stats and {
									changed = summary.margins.stats.changed, cut = summary.margins.stats.cut,
									filled = summary.margins.stats.filled, steepest = summary.margins.stats.steepest,
									max_movement = summary.margins.stats.max_movement}},
								outskirts = summary.outskirts and {counts = summary.outskirts.counts,
									terraform_rows = summary.outskirts.terraform and #summary.outskirts.terraform},
								warnings = summary.warnings,
							}
						end
						sample.status = (agg.outside == 0) and "contained" or "ESCAPED"
					end)
					if not ok2 then sample.status = "harness_error"; sample.harness_error = tostring(err2) end
					towns.builder.build_town = original_build_town
					finish_sample()
				end)
				if not built_ok then
					towns.builder.build_town = original_build_town
					sample.status = "build_error"; sample.harness_error = tostring(built_err)
					finish_sample()
				end
				end)
				if not settled_ok then
					towns.builder.build_town = original_build_town
					sample.status = "harness_error"; sample.harness_error = tostring(settled_err)
					finish_sample()
				end
				end)
			end)
		end, force_walls)
		if not ok then unpin(); sample.status = "search_error"; sample.harness_error = tostring(err); finish_sample() end
	end)
end

core.register_on_mods_loaded(function() core.after(0, function()
	local ok, err = pcall(function()
		local providers = make_providers()
		local env, why = as_towns(ab.new, providers)
		if not env then error("auto_bounds.new declined: " .. tostring(why)) end
		env_cache = env
		report.env = {max_rect = env.max_rect, stage_reach = env.stage_reach, village_reach = env.village_reach,
			activation_rect = env.activation_rect, outskirts_reach = env.outskirts_reach, fit = env.fit,
			caps = {max_chunks = ab.CAPS.MAX_REQUEST_CHUNKS, max_voxels = ab.CAPS.MAX_SNAPSHOT_VOXELS}}
		write_json("env", report.env)
	end)
	local function shutdown()
		report.finished = true
		write_json("report", report)
		core.request_shutdown("containment done", false, 0)
	end
	if not ok then
		report.errors[#report.errors + 1] = tostring(err)
		return shutdown()
	end
	local i = first_index - 1
	local last = first_index + count - 1
	local function nextsample()
		i = i + 1
		if i > last then return shutdown() end
		local ok2, err2 = pcall(run_sample, i, nextsample)
		if not ok2 then
			report.errors[#report.errors + 1] = "sample " .. i .. ": " .. tostring(err2)
			return shutdown()
		end
	end
	nextsample()
end) end)
