-- Small adapter for Living Villages' public living_villages.terrain API.
-- It deliberately knows only how to describe and apply one plot.
local M = {}
local SOURCE = debug.getinfo(1, "S").source:sub(2)
local MODPATH = SOURCE:match("^(.*)/src/outskirts_terrain.lua$") or "."

local function load_sibling(name)
	return dofile(MODPATH .. "/src/" .. name)
end
local DEFAULT_PROTECT_MARGIN = load_sibling("outskirts.lua").CONSTANTS.PROTECT_MARGIN

function M.available(terrain)
	if type(terrain) ~= "table" or type(terrain.volume) ~= "function"
			or type(terrain.terraform) ~= "function" then
		return false, "outskirts_dependency", "Living Villages terrain API requires volume and terraform"
	end
	return true
end

-- Convert a plot and catalog entry into the settlement-style records expected
-- by Living Villages. bounds is the urban plan.bounds rectangle.
function M.mapping(plot, entry, bounds, protect_margin)
	assert(type(plot) == "table" and type(entry) == "table", "plot and catalog entry are required")
	assert(type(plot.rect) == "table" and type(plot.rect.x1) == "number"
		and type(plot.rect.z1) == "number", "plot.rect minimum is required")
	assert(type(plot.rotation) == "number", "plot.rotation is required")
	assert(type(entry.id) == "string" and type(entry.size) == "table", "catalog entry id and size are required")
	assert(type(bounds) == "table", "urban bounds are required")
	local protected = {
		x0 = bounds.x1, z0 = bounds.z1, x1 = bounds.x2, z1 = bounds.z2,
		margin = protect_margin == nil and DEFAULT_PROTECT_MARGIN or protect_margin,
	}
	local plan_entry = {
		name = entry.id,
		pos = {x = plot.rect.x1, z = plot.rect.z1},
		rotat = tostring(plot.rotation),
	}
	if plot.ground_y ~= nil then plan_entry.pos.y = plot.ground_y end
	local schematic = {
		name = entry.id,
		hwidth = entry.size.x,
		hdepth = entry.size.z,
		hheight = entry.size.y,
	}
	return {plan_entry}, {schematic}, protected
end

-- Read-only volume query. Unknown candidate heights use the full search window
-- around the urban surface; Living Villages supplies mapblock alignment/margins.
function M.volume(terrain, plan, schematic_table, options)
	local ok, code, message = M.available(terrain)
	if not ok then return nil, code, message end
	return terrain.volume(plan, schematic_table, options or {})
end

-- Apply exactly one plot. The public API takes three arguments; its optional
-- environment belongs in options.env. A declined or incomplete operation is
-- an omission. Living Villages enforces protected columns while applying
-- writes; stats.written is only an envelope and may overlap protection even
-- when every individual write is outside it.
function M.terraform(terrain, plan, schematic_table, protected, options)
	local ok, code, message = M.available(terrain)
	if not ok then return nil, code, message end
	local opts = {}
	for k, v in pairs(options or {}) do opts[k] = v end
	opts.schematic_table = schematic_table
	opts.protected = {protected}
	for _, feature in ipairs((options or {}).feature_footprints or {}) do
		opts.protected[#opts.protected + 1] = {x0 = feature.x1, z0 = feature.z1,
			x1 = feature.x2, z1 = feature.z2, margin = 0}
	end
	opts.feature_footprints = nil
	local accepted, result = terrain.terraform(plan, nil, opts)
	if not accepted then return nil, "terraform_declined", result end
	local stats = result or {}
	if (stats.unloaded_blocks or 0) > 0 then return nil, "terraform_incomplete", stats end
	return true, stats
end

return M
