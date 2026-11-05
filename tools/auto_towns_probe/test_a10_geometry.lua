local geometry = dofile("tools/auto_towns_probe/a10_geometry.lua")
local minp, maxp = {x=-192,z=128}, {x=-113,z=207}
local extent = {x1=-245,x2=245,z1=-245,z2=245}
-- Living Villages floors both centers: (-153, 167), including negative half values.
local cases = {
	{-331, 167, true}, {-332, 167, false}, {25, 167, true}, {26, 167, false},
	{-153, -11, true}, {-153, -12, false}, {-153, 345, true}, {-153, 346, false},
}
for i, c in ipairs(cases) do
	local site = {max_rect={x1=c[1],x2=c[1],z1=c[2],z2=c[2]}}
	local result = geometry.select(minp, maxp, 178, extent, function(rect)
		assert(rect.x1 == -576 and rect.x2 == 270 and rect.z1 == -256 and rect.z2 == 590,
			"wrong lookup rectangle or planner center")
		return {site}
	end)
	assert((result ~= nil) == c[3], "boundary/near miss case " .. i)
end
print("PASS scratch A10 candidate boundaries (8 cases)")
