-- Outside-box scan for tools/reimport.py (#377). Runs in a disposable copy of
-- TownsWorkshop. For every capture box it looks at a ring of `margin` nodes around
-- the box and reports non-natural nodes there that could be architecture clipped by
-- the box. Expected noise is filtered out:
--   * everything at or below the ground level (the most common top-most node level
--     of the ring's columns), which is terrain, paving and platform gravel;
--   * natural terrain, plants and leaves;
--   * cells inside any other box in the job (a neighbouring registered building);
--   * non-natural cells that do not touch the box: a neighbour separated from the
--     box by a gap is another structure, not a clipped one. Only cells that are
--     face-adjacent to a non-natural, non-air node inside the box are reported.
-- Reads job reimport-scan-job.json, writes reimport-scan.json into the world.
local natural_names = {air = true, ignore = true}
for _, n in ipairs({'dirt_with_grass', 'dirt', 'coarse_dirt', 'podzol', 'stone', 'bedrock', 'void', 'gravel',
		'sand', 'redsand', 'grass_path', 'snow', 'water_source', 'water_flowing', 'lava_source',
		'lava_flowing', 'mycelium', 'clay', 'ice'}) do natural_names['mcl_core:' .. n] = true end
local natural_patterns = {'^mcl_flowers:', ':tallgrass', ':fern', ':double_grass', ':leaves', ':deadbush', ':sapling'}

local wp = core.get_worldpath()
local f = assert(io.open(wp .. '/reimport-scan-job.json'))
local job = assert(core.parse_json(f:read('*a')))
f:close()

local cache = {}
local function is_natural(cid)
	local v = cache[cid]
	if v == nil then
		local name = core.get_name_from_content_id(cid)
		v = natural_names[name] or false
		if not v then
			for _, p in ipairs(natural_patterns) do
				if name:find(p) then v = true break end
			end
		end
		cache[cid] = v
	end
	return v
end
local air = core.CONTENT_AIR
local ignore = core.CONTENT_IGNORE

local function inside(b, x, y, z)
	return x >= b.min.x and x <= b.max.x and y >= b.min.y and y <= b.max.y and z >= b.min.z and z <= b.max.z
end

core.register_on_mods_loaded(function() core.after(0, function()
	local m = job.margin
	local out = {}
	for _, b in ipairs(job.boxes) do
		local lo = {x = b.min.x - m, y = math.max(b.min.y - m, -3), z = b.min.z - m}
		local hi = {x = b.max.x + m, y = b.max.y + m, z = b.max.z + m}
		local vm = VoxelManip()
		local emin, emax = vm:read_from_map(lo, hi)
		local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
		local data = vm:get_data()
		-- Ground level: mode of the top-most non-air node over the ring columns.
		local tops = {}
		for z = lo.z, hi.z do for x = lo.x, hi.x do
			if not (x >= b.min.x and x <= b.max.x and z >= b.min.z and z <= b.max.z) then
				for y = hi.y, lo.y, -1 do
					local c = data[area:index(x, y, z)]
					if c ~= air and c ~= ignore then tops[y] = (tops[y] or 0) + 1 break end
				end
			end
		end end
		local ground, best = b.min.y, 0
		for y, n in pairs(tops) do if n > best then ground, best = y, n end end
		local r = {id = b.id, ground_y = ground, touching = 0, other_above_ground = 0, names = {}, samples = {}}
		local bb = {min = {x = 31000, y = 31000, z = 31000}, max = {x = -31000, y = -31000, z = -31000}}
		local dirs = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
		for z = lo.z, hi.z do for y = math.max(lo.y, ground + 1), hi.y do for x = lo.x, hi.x do
			if not inside(b, x, y, z) then
				local c = data[area:index(x, y, z)]
				if not is_natural(c) then
					local in_other = false
					for _, o in ipairs(job.boxes) do
						if o.id ~= b.id and inside(o, x, y, z) then in_other = true break end
					end
					if not in_other then
						local touches = false
						for _, d in ipairs(dirs) do
							local nx, ny, nz = x + d[1], y + d[2], z + d[3]
							if inside(b, nx, ny, nz) and not is_natural(data[area:index(nx, ny, nz)]) then
								touches = true break
							end
						end
						if touches then
							r.touching = r.touching + 1
							local name = core.get_name_from_content_id(c)
							r.names[name] = (r.names[name] or 0) + 1
							for k, v in pairs({x = x, y = y, z = z}) do
								bb.min[k] = math.min(bb.min[k], v); bb.max[k] = math.max(bb.max[k], v)
							end
							if #r.samples < 12 then r.samples[#r.samples + 1] = x .. ',' .. y .. ',' .. z .. ' ' .. name end
						else
							r.other_above_ground = r.other_above_ground + 1
						end
					end
				end
			end
		end end end
		if r.touching > 0 then r.bounds = bb end
		out[#out + 1] = r
	end
	local w = assert(io.open(wp .. '/reimport-scan.json', 'w'))
	w:write(assert(core.write_json(out, true)))
	w:close()
	core.request_shutdown('scan done', false, 0)
end) end)
