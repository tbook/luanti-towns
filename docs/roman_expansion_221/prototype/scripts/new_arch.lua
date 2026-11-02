		if spec.terminal then
			-- PROTOTYPE (#221): terminal landmark + forecourt square, centred on the street.
			local t = spec.terminal
			local sx, sz = footprint(t.id, t.rotation)
			local along, across = sz, sx
			if not vertical then along, across = sx, sz end
			if across % 2 ~= 0 then layout_error("terminal width must be even") end
			local l1, l2 = -math.floor(across / 2), math.floor(across / 2) - 1
			local depth = t.forecourt and t.forecourt.depth or 0
			if t.forecourt then
				local fr = translate(arm_rect(layout, arm, spec.length, spec.length + depth - 1, l1, l2), dx, dz)
				local ax, az = dx - 1, fr.z1
				if ARMS[arm].x ~= 0 then ax, az = fr.x1, dz - 1 end
				if ARMS[arm].x + ARMS[arm].z < 0 then
					if ARMS[arm].x ~= 0 then ax = fr.x2 else az = fr.z2 end
				end
				local sq = {}
				sq.name, sq.kind, sq.rect, sq.material = t.forecourt.name, "square", fr, layout.forum_material
				sq.size = {x = fr.x2 - fr.x1 + 1, z = fr.z2 - fr.z1 + 1}
				sq.approach = {pos = {x = ax, z = az}}
				add(sq)
			end
			local rect = translate(arm_rect(layout, arm, spec.length + depth, spec.length + depth + along - 1, l1, l2), dx, dz)
			local toward = {-ARMS[arm].x, -ARMS[arm].z}
			local extra = {}
			extra.arm, extra.terminal = arm, true
			add(landmark(t.name, t.id, t.rotation, rect, toward, extra))
			local m, d = layout.margin, ARMS[arm]
			local c = {x1 = rect.x1 - m, z1 = rect.z1 - m, x2 = rect.x2 + m, z2 = rect.z2 + m}
			if d.z > 0 then c.z1 = rect.z1 elseif d.z < 0 then c.z2 = rect.z2
			elseif d.x > 0 then c.x1 = rect.x1 else c.x2 = rect.x2 end
			compounds[#compounds + 1] = c
		else
