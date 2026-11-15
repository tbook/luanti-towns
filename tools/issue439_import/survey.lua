-- Survey a disposable copy of TownsWorkshop for the Issue 439 Roman palace.
-- Reads issue439-survey-job.json from the world directory (min/max boxes),
-- emerges the area and writes issue439-survey.json: the bounds of every
-- non-natural node, per-name counts, bottom-half door positions, layer counts,
-- a top-down footprint and the plan slices listed in the job.
local wp = core.get_worldpath()
local job = assert(core.parse_json(assert(io.open(wp .. '/issue439-survey-job.json')):read('*a')))

-- Terrain and plants that are part of the flat workshop ground, not the building.
local natural = {
	['air'] = true, ['ignore'] = true, ['mcl_core:dirt_with_grass'] = true, ['mcl_core:dirt'] = true,
	['mcl_core:stone'] = true, ['mcl_core:bedrock'] = true, ['mcl_core:void'] = true,
	['mcl_flowers:tallgrass'] = true, ['mcl_flowers:fern'] = true,
}

local function write_json(path, value)
	local f = assert(io.open(path, 'w')); f:write(assert(core.write_json(value, true))); f:close()
end

core.register_on_mods_loaded(function() core.after(0, function()
	local lo, hi = job.min, job.max
	core.emerge_area(lo, hi, function(_, action, remaining)
		assert(action ~= core.EMERGE_CANCELLED and action ~= core.EMERGE_ERRORED, 'Emerge failed')
		if remaining ~= 0 then return end
		core.after(0, function()
			local counts, doors, layers = {}, {}, {}
			local footprint = {}
			for z = lo.z, hi.z do footprint[z - lo.z + 1] = {} end
			local bounds = {min = {x = math.huge, y = math.huge, z = math.huge}, max = {x = -math.huge, y = -math.huge, z = -math.huge}}
			local total = 0
			local vm = VoxelManip()
			local emin, emax = vm:read_from_map(lo, hi)
			local data = vm:get_data()
			local area = VoxelArea:new({MinEdge = emin, MaxEdge = emax})
			local cache = {}
			-- Plan slices at the Y values listed in the job: 'D' door, '#' other
			-- non-natural node, '.' air or natural ground. Rows are z, columns are x.
			local slices = {}
			for _, sy in ipairs(job.slice_y or {}) do
				local rows = {}
				for z = lo.z, hi.z do
					local row = {}
					for x = lo.x, hi.x do
						local name = core.get_name_from_content_id(data[area:index(x, sy, z)])
						row[#row + 1] = name:find('_door_') and 'D' or (natural[name] and '.' or '#')
					end
					rows[#rows + 1] = table.concat(row)
				end
				slices[#slices + 1] = {y = sy, rows = rows}
			end
			for z = lo.z, hi.z do for y = lo.y, hi.y do for x = lo.x, hi.x do
				local id = data[area:index(x, y, z)]
				local name = cache[id]
				if not name then name = core.get_name_from_content_id(id); cache[id] = name end
				if not natural[name] then
					counts[name] = (counts[name] or 0) + 1
					layers[y - lo.y + 1] = (layers[y - lo.y + 1] or 0) + 1
					total = total + 1
					if not footprint[z - lo.z + 1][x - lo.x + 1] then
						footprint[z - lo.z + 1][x - lo.x + 1] = '#'
					end
					local b = bounds
					if x < b.min.x then b.min.x = x end
					if y < b.min.y then b.min.y = y end
					if z < b.min.z then b.min.z = z end
					if x > b.max.x then b.max.x = x end
					if y > b.max.y then b.max.y = y end
					if z > b.max.z then b.max.z = z end
					if name:find('_door_b_') then
						doors[#doors + 1] = {x = x, y = y, z = z, name = name}
					end
				end
			end end end
			-- layers_from_min_y[i] counts non-natural nodes at Y = min.y + i - 1.
			-- Top-down footprint: one row per z (lo.z first), one column per x (lo.x first).
			-- '#' marks a column holding a non-natural node at any height in the box.
			local rows = {}
			for z = 1, hi.z - lo.z + 1 do
				local row = {}
				for x = 1, hi.x - lo.x + 1 do row[x] = footprint[z][x] or '.' end
				rows[z] = table.concat(row)
			end
			write_json(wp .. '/issue439-survey.json', {
				min = lo, max = hi, non_natural_nodes = total,
				bounds = total > 0 and bounds or nil, counts = counts, doors = doors,
				layers_from_min_y = layers, footprint = rows, slices = slices,
			})
			core.request_shutdown('survey done', false, 0)
		end)
	end)
end) end)
