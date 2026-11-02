-- Issue 341: place the captured Roman buildings into a disposable TownsWorkshop
-- copy and verify them. job.mode == 'place' places and verifies in memory;
-- 'verify' re-reads the saved staged map and verifies again without changing it.
local GROUND_Y = 8
local MARGIN = 4
local natural_ground = {
	['mcl_core:dirt_with_grass'] = true, ['mcl_core:dirt'] = true, ['mcl_core:stone'] = true,
	['mcl_core:void'] = true, ['mcl_core:bedrock'] = true,
}
-- Source nodes that this game lacks are mapped here (none were needed in #341).
local replacements = {}
local SKIP_FIELDS = {villager = true, villages_last_birth = true, player = true, last_gametime = true}

local function read_json(path)
	local f = assert(io.open(path, 'r')); local v = assert(core.parse_json(f:read('*a'))); f:close(); return v
end
local function write_json(path, value)
	local f = assert(io.open(path, 'w')); f:write(assert(core.write_json(value, true))); f:close()
end
local function pstr(p) return core.pos_to_string(p) end

local wp = core.get_worldpath()
local job = read_json(wp .. '/issue341-job.json')
local mode = job.mode
local report = {mode = mode, buildings = {}, failures = {}, unavailable = {}}
local function fail(msg) report.failures[#report.failures + 1] = msg end

local function schem_path(b) return wp .. '/schems/' .. b.schematic end
local function footprint(b)
	local o, s = b.origin, b.size
	return {x1 = o.x, y1 = o.y, z1 = o.z, x2 = o.x + s.x - 1, y2 = o.y + s.y - 1, z2 = o.z + s.z - 1}
end
local function is_excluded(p)
	for _, b in ipairs(job.buildings) do
		local f = footprint(b)
		if p.x >= f.x1 and p.x <= f.x2 and p.y >= f.y1 and p.y <= f.y2 and p.z >= f.z1 and p.z <= f.z2 then return true end
	end
	return false
end

-- Hash of every cell in the emerged region outside the building volumes.
local function region_hash(lo, hi)
	local parts, n = {}, 0
	for z = lo.z, hi.z do for y = lo.y, hi.y do for x = lo.x, hi.x do
		local p = {x = x, y = y, z = z}
		if not is_excluded(p) then
			local node = core.get_node(p)
			n = n + 1; parts[n] = node.name .. ':' .. node.param2
		end
	end end end
	return core.sha1(table.concat(parts, ',')), n
end

local function same_stack(got, want)
	local ge, we = got:get_meta():to_table().fields or {}, want:get_meta():to_table().fields or {}
	if got:get_name() ~= want:get_name() or got:get_count() ~= want:get_count() or got:get_wear() ~= want:get_wear() then return false end
	for k, v in pairs(we) do if ge[k] ~= v then return false end end
	for k, v in pairs(ge) do if we[k] ~= v then return false end end
	return true
end

local function restore_metadata(b, rb)
	local restored, inv_mismatch = 0, 0
	for _, m in ipairs(b.metadata or {}) do
		local p = vector.add(b.origin, m.offset)
		local meta = core.get_meta(p)
		for k, v in pairs((m.meta and m.meta.fields) or {}) do
			if not SKIP_FIELDS[k] then meta:set_string(k, v) end
		end
		local inv = meta:get_inventory()
		for name, items in pairs((m.meta and m.meta.inventory) or {}) do
			inv:set_size(name, #items); inv:set_list(name, items)
		end
		restored = restored + 1
	end
	rb.metadata_restored = restored
end

-- Compare every captured metadata field and inventory stack with the live node.
local function check_metadata(b, rb)
	local mismatches = 0
	for _, m in ipairs(b.metadata or {}) do
		local p = vector.add(b.origin, m.offset)
		local meta = core.get_meta(p)
		for k, v in pairs((m.meta and m.meta.fields) or {}) do
			if not SKIP_FIELDS[k] and meta:get_string(k) ~= v then
				mismatches = mismatches + 1; fail(b.id .. ': metadata field ' .. k .. ' differs at ' .. pstr(p))
			end
		end
		local inv = meta:get_inventory()
		for name, items in pairs((m.meta and m.meta.inventory) or {}) do
			if inv:get_size(name) ~= #items then
				mismatches = mismatches + 1; fail(b.id .. ': inventory ' .. name .. ' size differs at ' .. pstr(p))
			end
			for i, item in ipairs(items) do
				if not same_stack(inv:get_stack(name, i), ItemStack(item)) then
					mismatches = mismatches + 1; fail(b.id .. ': inventory ' .. name .. '[' .. i .. '] differs at ' .. pstr(p))
				end
			end
		end
	end
	rb.inventory_mismatches = mismatches
end

local function verify_building(b, schem, rb)
	local s = schem.size
	local nodes, mismatches, nonair, subs = 0, 0, 0, 0
	for z = 0, s.z - 1 do for y = 0, s.y - 1 do for x = 0, s.x - 1 do
		local src = schem.data[z * s.x * s.y + y * s.x + x + 1]
		local want = replacements[src.name] or src.name
		local p = {x = b.origin.x + x, y = b.origin.y + y, z = b.origin.z + z}
		local got = core.get_node(p)
		nodes = nodes + 1
		if src.name ~= 'air' then nonair = nonair + 1; if want ~= src.name then subs = subs + 1 end end
		if got.name ~= want or got.param2 ~= src.param2 then
			mismatches = mismatches + 1
			if mismatches <= 10 then fail(b.id .. ': mismatch at ' .. pstr(p) .. ' want ' .. want .. '/' .. src.param2 .. ' got ' .. got.name .. '/' .. got.param2) end
		end
	end end end
	rb.cells = nodes; rb.non_air_nodes = nonair; rb.node_mismatches = mismatches; rb.substituted_nodes = subs
	check_metadata(b, rb)
end

core.register_on_mods_loaded(function() core.after(0, function()
	local schems, low, high = {}, {x = 31000, y = 31000, z = 31000}, {x = -31000, y = -31000, z = -31000}
	for _, b in ipairs(job.buildings) do
		local s = assert(core.read_schematic(schem_path(b), {write_yslice_prob = 'all'}))
		schems[b.id] = s; b.size = s.size
		for _, n in ipairs(s.data) do
			if not core.registered_nodes[replacements[n.name] or n.name] then report.unavailable[n.name] = true end
		end
		local f = footprint(b)
		low.x = math.min(low.x, f.x1 - MARGIN); high.x = math.max(high.x, f.x2 + MARGIN)
		low.y = math.min(low.y, f.y1 - 1); high.y = math.max(high.y, f.y2 + MARGIN)
		low.z = math.min(low.z, f.z1 - MARGIN); high.z = math.max(high.z, f.z2 + MARGIN)
	end
	if next(report.unavailable) then
		write_json(wp .. '/issue341-' .. mode .. '.json', report)
		core.request_shutdown('Issue 341 node mapping needed', false, 0); return
	end
	core.emerge_area(low, high, function(_, action, remaining)
		assert(action ~= core.EMERGE_CANCELLED and action ~= core.EMERGE_ERRORED, 'Emerge failed')
		if remaining ~= 0 then return end
		core.after(0, function()
			report.region = {min = low, max = high}
			if mode == 'place' then
				-- Preflight: the whole volume (air included, since the schematic writes air)
				-- may only hold air or natural ground at or below the ground datum.
				for _, b in ipairs(job.buildings) do
					local f = footprint(b)
					for z = f.z1, f.z2 do for y = f.y1, f.y2 do for x = f.x1, f.x2 do
						local n = core.get_node({x = x, y = y, z = z}).name
						if not (n == 'air' or (y <= GROUND_Y and natural_ground[n])) then
							fail(b.id .. ': occupied cell ' .. pstr({x = x, y = y, z = z}) .. ' (' .. n .. ')')
						end
					end end end
				end
				if #report.failures > 0 then
					write_json(wp .. '/issue341-place.json', report); core.request_shutdown('preflight failed', false, 0); return
				end
				report.outside_hash_before, report.outside_cells = region_hash(low, high)
				for _, b in ipairs(job.buildings) do
					assert(core.place_schematic(b.origin, schem_path(b), '0', replacements, true), 'Could not place ' .. b.id)
					restore_metadata(b, {})
				end
				-- Refresh display entities and node constructors that metadata alone does not rebuild.
				for _, b in ipairs(job.buildings) do
					local s = schems[b.id].size
					for z = 0, s.z - 1 do for y = 0, s.y - 1 do for x = 0, s.x - 1 do
						local p = {x = b.origin.x + x, y = b.origin.y + y, z = b.origin.z + z}
						local n = core.get_node(p).name
						if n == 'mcl_armor_stand:armor_stand' then core.registered_nodes[n].on_construct(p)
						elseif n:find('mcl_itemframes:') and mcl_itemframes then mcl_itemframes.update_entity(p)
						elseif core.get_item_group(n, 'chest_entity') > 0 and mcl_chests then mcl_chests.select_and_spawn_entity(p, core.get_node(p))
						elseif n:find('mcl_signs:') and mcl_signs then mcl_signs.update_sign(p) end
					end end end
				end
				report.outside_hash_after = region_hash(low, high)
				if report.outside_hash_after ~= report.outside_hash_before then
					fail('nodes outside the building volumes changed during placement')
				end
			else
				local before = read_json(wp .. '/issue341-place.json')
				report.outside_hash_before = before.outside_hash_before
				report.outside_hash_after = region_hash(low, high)
				if report.outside_hash_after ~= before.outside_hash_before then
					fail('nodes outside the building volumes differ from the pre-placement snapshot')
				end
			end
			for _, b in ipairs(job.buildings) do
				local rb = {id = b.id, label = b.label, origin = b.origin, size = b.size, metadata_nodes = #(b.metadata or {})}
				report.buildings[#report.buildings + 1] = rb
				verify_building(b, schems[b.id], rb)
			end
			write_json(wp .. '/issue341-' .. mode .. '.json', report)
			core.request_shutdown('Issue 341 ' .. mode .. ' done', false, 0)
		end)
	end)
end) end)
