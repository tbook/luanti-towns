-- Stable iteration over the named sites in a town plan.
-- Sites are returned in the plan's declared order, followed by any extra
-- named sites in alphabetical order. The name is the identity: two sites may
-- safely refer to the same catalog entry.
local M = {}

function M.list(plan)
	local sites = type(plan) == "table" and plan.sites or nil
	if type(sites) ~= "table" then return {} end
	local out, seen = {}, {}
	local function add(name)
		if type(name) == "string" and not seen[name] and type(sites[name]) == "table" then
			seen[name] = true
			out[#out + 1] = {name = name, site = sites[name]}
		end
	end
	for _, name in ipairs(type(plan.site_order) == "table" and plan.site_order or {}) do add(name) end
	local remaining = {}
	for name, site in pairs(sites) do
		if type(name) == "string" and type(site) == "table" and not seen[name] then
			remaining[#remaining + 1] = name
		end
	end
	table.sort(remaining)
	for _, name in ipairs(remaining) do add(name) end
	return out
end

return M
