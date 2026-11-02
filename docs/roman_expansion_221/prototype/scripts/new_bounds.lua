	local rects = {{x1 = bounds.x1, z1 = bounds.z1, x2 = bounds.x2, z2 = bounds.z2}}
	if layout.main_rect then
		rects = {translate(layout.main_rect, dx, dz)}
		for _, c in ipairs(compounds) do rects[#rects + 1] = c end
		local b = {x1 = rects[1].x1, z1 = rects[1].z1, x2 = rects[1].x2, z2 = rects[1].z2}
		for _, r in ipairs(rects) do
			b.x1, b.z1 = math.min(b.x1, r.x1), math.min(b.z1, r.z1)
			b.x2, b.z2 = math.max(b.x2, r.x2), math.max(b.z2, r.z2)
		end
		bounds = b
	end
