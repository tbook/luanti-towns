-- Applies already-preflighted outskirts plots. Terraform all survivors first,
-- then place schematics, check doors and initialize functional nodes.
local M = {}
local source = debug.getinfo(1, "S").source:sub(2)
local modpath = source:match("^(.*)/src/outskirts_build.lua$") or "."
local terrain_adapter = dofile(modpath .. "/src/outskirts_terrain.lua")
local contract = dofile(modpath .. "/src/outskirts.lua")

local function box(st)
	return {min = st.min, max = st.max}
end

local function valid_volume(v)
	if type(v) ~= "table" or type(v.minp) ~= "table" or type(v.maxp) ~= "table" then return false end
	for _, a in ipairs({"x", "y", "z"}) do
		if type(v.minp[a]) ~= "number" or type(v.maxp[a]) ~= "number"
				or v.minp[a] > v.maxp[a] then return false end
	end
	return true
end

function M.apply(out, env, opts)
	opts = opts or {}
	assert(type(out) == "table" and type(out.plots) == "table", "outskirts result is required")
	assert(type(env) == "table", "outskirts build environment is required")
	local terrain = env.terrain
	local ok, code, message = terrain_adapter.available(terrain)
	if not ok then return nil, message, code end
	if type(env.place_structure) ~= "function" or type(env.get_node) ~= "function"
			or type(env.check_door) ~= "function" or type(env.setup_nodes) ~= "function" then
		return nil, "outskirts build environment is missing placement, door or node setup support",
			"write_failed", {attempted = {}, placement_attempted = {}, boxes = {}}
	end
	local entries, plots, attempted, placement_attempted, skipped, warnings, boxes, terrain_results =
		out.entries, {}, {}, {}, {}, {}, {}, {}
	if type(entries) ~= "table" or type(opts.bounds) ~= "table"
			or type(opts.structures) ~= "table" or #opts.structures ~= #out.plots then
		return nil, "outskirts entries, urban bounds and composed structures are required",
			"write_failed", {attempted = {}, placement_attempted = {}, boxes = {}}
	end
	local bounds = opts.bounds
	for i, plot in ipairs(out.plots) do
		local st = opts.structures[i]
		if not st or st.plot ~= plot.id then
			return nil, "composed outskirts structures do not match plots", "write_failed",
				{attempted = attempted, placement_attempted = placement_attempted, boxes = boxes}
		end
		local entry = entries[plot.asset]
		if not entry then return nil, "outskirts catalog entry missing", "write_failed",
			{attempted = attempted, placement_attempted = placement_attempted, boxes = boxes} end
		local plan, schematic, protected = terrain_adapter.mapping(plot, entry, bounds,
			contract.CONSTANTS.PROTECT_MARGIN)
		local volume_ok, volume = pcall(terrain_adapter.volume, terrain, plan, schematic,
			{protected = {protected}})
		local attempted_box = volume_ok and valid_volume(volume)
			and {min = volume.minp, max = volume.maxp} or box(st)
		attempted[#attempted + 1] = attempted_box -- known even if terraform throws
		if not volume_ok or not valid_volume(volume) then
			return nil, "outskirts terrain volume failed: " .. tostring(volume_ok and "invalid volume" or volume),
				"write_failed", {attempted = attempted, placement_attempted = placement_attempted, boxes = boxes}
		end
		local called, tok, stats, detail = pcall(terrain_adapter.terraform, terrain, plan, schematic, protected, opts.terrain_options)
		if not called then
			return nil, "outskirts terraform raised: " .. tostring(tok), "write_failed",
				{attempted = attempted, placement_attempted = placement_attempted,
					boxes = boxes, terraform = terrain_results, skipped = skipped, warnings = warnings}
		elseif not tok then
			if type(detail) == "table" and detail.written then boxes[#boxes + 1] = detail.written end
			terrain_results[#terrain_results + 1] = {plot = plot.id, code = stats, stats = detail}
			skipped[#skipped + 1] = {plot = plot.id, code = stats,
				reason = type(detail) == "table" and ("unloaded blocks: " .. tostring(detail.unloaded_blocks or 0))
					or tostring(detail or stats)}
		else
			if stats.written then boxes[#boxes + 1] = stats.written end
			if stats.unloaded_blocks and stats.unloaded_blocks > 0 then
				terrain_results[#terrain_results + 1] = {plot = plot.id,
					code = "terraform_incomplete", stats = stats}
				skipped[#skipped + 1] = {plot = plot.id, code = "terraform_incomplete", reason = "unloaded blocks"}
			else
				terrain_results[#terrain_results + 1] = {plot = plot.id, code = "ok", stats = stats}
				plots[#plots + 1] = {plot = plot, structure = st, entry = entry, stats = stats}
			end
		end
	end
	local placed, doors = {}, {}
	local setup_report
	local ok_apply, err = pcall(function()
		for _, item in ipairs(plots) do
			placement_attempted[#placement_attempted + 1] = box(item.structure)
			local success, reason = env.place_structure(item.structure, item.entry)
			if not success then
				warnings[#warnings + 1] = {plot = item.plot.id, code = "placement_failed", reason = tostring(reason)}
			else
				placed[#placed + 1] = item.structure
				if item.structure.entrance then
					local reachable, detail = env.check_door(item.structure, item.plot.ground_y,
						function(x, y, z)
							local name = env.get_node(x, y, z)
							if name == "air" then return {walkable = false}, name end
						return env.node_info and env.node_info(name) or {walkable = name ~= "air"}, name
						end)
					if not reachable then warnings[#warnings + 1] = {plot = item.plot.id,
						code = "door_unreachable", reason = tostring(detail)}
					else doors[#doors + 1] = {plot = item.plot.id, entrance = item.structure.entrance,
						approach = reachable.approach, steps = reachable.steps} end
				end
			end
		end
		if #placed > 0 then
			setup_report = env.setup_nodes(placed, entries)
			if type(setup_report) ~= "table" or type(setup_report.failed) ~= "table" or #setup_report.failed > 0
					or type(setup_report.unregistered) ~= "table" or #setup_report.unregistered > 0 then
				error("node_setup_failed: " .. tostring(setup_report and setup_report.failed and #setup_report.failed or "invalid report"))
			end
		end
	end)
	if not ok_apply then
		return nil, "outskirts build failed: " .. tostring(err), "write_failed",
			{attempted = attempted, placement_attempted = placement_attempted,
				boxes = boxes, terraform = terrain_results, skipped = skipped,
				warnings = warnings, placed = #placed}
	end
	return {status = #placed == 0 and "empty" or "built", structures = placed,
		skipped = skipped, warnings = warnings, boxes = boxes, attempted = attempted,
		terraform = terrain_results, placement_attempted = placement_attempted, doors = doors,
		setup = setup_report, placed = #placed, total = #out.plots}
end

return M
