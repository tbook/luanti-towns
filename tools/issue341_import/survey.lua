-- Survey a world copy: mark every (x,z) column that holds anything other than
-- natural flat-world ground. Writes issue341-survey.json into the world.
local wp = core.get_worldpath()
local conf = assert(core.parse_json(assert(io.open(wp .. '/issue341-survey-job.json')):read('*a')))
local natural = {
	['air'] = true, ['ignore'] = true, ['mcl_core:dirt_with_grass'] = true, ['mcl_core:dirt'] = true,
	['mcl_core:stone'] = true, ['mcl_core:bedrock'] = true, ['mcl_core:void'] = true, ['mcl_flowers:tallgrass'] = true,
	['mcl_flowers:fern'] = true, ['mcl_core:water_source'] = false,
}
local function write_json(path, value)
	local f = assert(io.open(path, 'w')); f:write(assert(core.write_json(value))); f:close()
end
core.register_on_mods_loaded(function() core.after(0, function()
	local lo, hi = conf.min, conf.max
	core.emerge_area(lo, hi, function(_, action, remaining)
		assert(action ~= core.EMERGE_CANCELLED and action ~= core.EMERGE_ERRORED, 'Emerge failed')
		if remaining ~= 0 then return end
		core.after(0, function()
			local rows, other = {}, {}
			for z = lo.z, hi.z do rows[z - lo.z + 1] = {} end
			local step = 64
			for z0 = lo.z, hi.z, step do for x0 = lo.x, hi.x, step do
				local z1, x1 = math.min(z0 + step - 1, hi.z), math.min(x0 + step - 1, hi.x)
				local vm = VoxelManip(); local emin, emax = vm:read_from_map({x = x0, y = lo.y, z = z0}, {x = x1, y = hi.y, z = z1})
				local data = vm:get_data(); local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
				local cache = {}
				for z = z0, z1 do for x = x0, x1 do
					local mark = '.'
					for y = lo.y, hi.y do
						local id = data[area:index(x, y, z)]
						local name = cache[id]; if not name then name = core.get_name_from_content_id(id); cache[id] = name end
						if not natural[name] then
							local ok = false
							if name:find('^mcl_flowers:') or name == 'mcl_core:snow' then ok = (y == 9) end
							if not ok then mark = '#'; other[name] = (other[name] or 0) + 1; break end
						end
					end
					rows[z - lo.z + 1][x - lo.x + 1] = mark
				end end
			end end
			local out = {}
			for i, r in ipairs(rows) do out[i] = table.concat(r) end
			write_json(wp .. '/issue341-survey.json', {min = lo, max = hi, rows = out, other = other})
			core.request_shutdown('survey done', false, 0)
		end)
	end)
end) end)
