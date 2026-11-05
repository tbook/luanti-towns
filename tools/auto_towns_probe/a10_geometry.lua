-- Scratch fixture geometry. The center convention matches Living Villages.
local M = {}

function M.select(minp, maxp, reach, max_rect, lookup)
	local cx = math.floor((minp.x + maxp.x) / 2)
	local cz = math.floor((minp.z + maxp.z) / 2)
	local candidates = assert(lookup({x1=cx-reach-max_rect.x2, z1=cz-reach-max_rect.z2,
		x2=cx+reach-max_rect.x1, z2=cz+reach-max_rect.z1}))
	for _, site in ipairs(candidates) do
		local r = site.max_rect
		if cx-reach <= r.x2 and cx+reach >= r.x1 and cz-reach <= r.z2 and cz+reach >= r.z1 then
			return site
		end
	end
end

return M
