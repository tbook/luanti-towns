-- Scan a disposable copy of TownsWorkshop around each building box: report
-- non-natural, non-air nodes outside the box (within a margin) and, inside the
-- box, the occupied Y range. Writes issue341-scan.json into the world.
local natural = {air = true, ignore = true, ['mcl_core:dirt_with_grass'] = true, ['mcl_core:dirt'] = true,
	['mcl_core:stone'] = true, ['mcl_core:bedrock'] = true, ['mcl_core:void'] = true}
local wp = core.get_worldpath()
local f = assert(io.open(wp .. '/issue341-scan-job.json')); local job = assert(core.parse_json(f:read('*a'))); f:close()
core.register_on_mods_loaded(function() core.after(0, function()
	local lo, hi = {x = 31000, y = 31000, z = 31000}, {x = -31000, y = -31000, z = -31000}
	local m = job.margin
	for _, b in ipairs(job.buildings) do
		for _, k in ipairs({'x', 'y', 'z'}) do
			lo[k] = math.min(lo[k], b.min[k] - m); hi[k] = math.max(hi[k], b.max[k] + m)
		end
	end
	lo.y = math.max(lo.y, -3)
	core.emerge_area(lo, hi, function(_, action, remaining)
		assert(action ~= core.EMERGE_CANCELLED and action ~= core.EMERGE_ERRORED, 'Emerge failed')
		if remaining ~= 0 then return end
		core.after(0, function()
			local out = {}
			for _, b in ipairs(job.buildings) do
				local r = {id = b.id, outside = 0, samples = {}, inside_y = {}, inside_non_air = 0}
				local bb = {min = {x = 31000, y = 31000, z = 31000}, max = {x = -31000, y = -31000, z = -31000}}
				for z = b.min.z - m, b.max.z + m do for y = math.max(b.min.y - m, -3), b.max.y + m do for x = b.min.x - m, b.max.x + m do
					local p = {x = x, y = y, z = z}
					local n = core.get_node(p).name
					local inside = x >= b.min.x and x <= b.max.x and y >= b.min.y and y <= b.max.y and z >= b.min.z and z <= b.max.z
					if inside then
						if n ~= 'air' then
							r.inside_non_air = r.inside_non_air + 1
							local k = tostring(y - b.min.y)
							r.inside_y[k] = (r.inside_y[k] or 0) + 1
						end
					elseif not natural[n] then
						r.outside = r.outside + 1
						for k, v in pairs(p) do bb.min[k] = math.min(bb.min[k], v); bb.max[k] = math.max(bb.max[k], v) end
						if #r.samples < 12 then r.samples[#r.samples + 1] = core.pos_to_string(p) .. ' ' .. n end
					end
				end end end
				if r.outside > 0 then r.outside_bounds = bb end
				out[#out + 1] = r
			end
			local w = assert(io.open(wp .. '/issue341-scan.json', 'w')); w:write(assert(core.write_json(out, true))); w:close()
			core.request_shutdown('scan done', false, 0)
		end)
	end)
end) end)
