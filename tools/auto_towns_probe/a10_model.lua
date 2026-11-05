-- Scratch-only synchronous adapter for the pure state and geometry contracts.
-- It is an experiment, not the future production engine adapter or village guard.
return function(root, wt)
	local original_modpath, original_name = core.get_modpath, core.get_current_modname
	core.get_current_modname = function() return "towns" end
	core.get_modpath = function(name)
		if name == "towns" then return root end
		return original_modpath(name)
	end
	local ok, result = pcall(function()
		local bounds = dofile(root .. "/src/auto_bounds.lua")
		local geometry = dofile(core.get_modpath("auto_towns_probe") .. "/a10_geometry.lua")
		local sites = dofile(root .. "/src/auto_sites.lua")
		local state = dofile(root .. "/src/auto_state.lua")
		local catalog = dofile(root .. "/src/catalog.lua")
		local rural = dofile(root .. "/schematics/outskirts/catalog.lua")
		local lv = assert(living_villages and living_villages.terrain)
		local v = assert(dofile(core.get_modpath("living_villages") .. "/site_planner.lua").config)
		local config = bounds.default_config()
		config.village = {cell=v.cell, max_cells=v.max_cells, relocate_step=v.relocate_step,
			relocate_rings=v.relocate_rings, radius_jitter=v.radius_jitter}
		local outskirts, wall_features, village = {}, {}, {}
		for _, id in ipairs({"farm", "shepherd_hut", "villa"}) do
			outskirts[#outskirts+1] = {id=id, size=rural[id].size}
		end
		outskirts[#outskirts+1] = {id="chapel", size=catalog.entries.chapel.size}
		for id, e in pairs(catalog.entries) do
			if id:match("^wall_") and e.size then wall_features[#wall_features+1] = {id=id, size=e.size} end
		end
		for _, s in ipairs(settlements.schematic_table) do
			village[#village+1] = {name=s.name, hwidth=s.hwidth, hdepth=s.hdepth, hheight=s.hheight}
		end
		local env, why = bounds.new({config=config, assets={outskirts=outskirts, village=village, wall_features=wall_features},
			volume={terrain=lv.volume, boundary=lv.boundary_volume}})
		assert(env, why)
		local lookup = assert(sites.new(env))
		local seed = assert(core.get_mapgen_setting("seed"))
		local function new_session()
			return assert(state.new({lookup=function(rect) return lookup.lookup(seed, rect) end,
				adapter={origin=bounds.CHUNK_ORIGIN, size=bounds.CHUNKSIZE, accepts=function() return true end},
				footprint=bounds.PLAN_EXTENT}))
		end
		local fresh, inactive = new_session(), new_session()
		local selected, target
		wt({kind="wt_a10_geometry", fixture_version=2, seed=seed, max_rect=env.max_rect, activation_rect=env.activation_rect,
			village_reach=env.village_reach, fit=env.fit})
		local function generated(minp, maxp, heightmap)
			if not heightmap then return end
			local heights, i, valid = {}, 1, 0
			for z=minp.z,maxp.z do
				local row = {}; heights[z] = row
				for x=minp.x,maxp.x do
					row[x] = heightmap[i]
					if type(row[x]) == "number" and row[x] > minp.y and row[x] < maxp.y and math.abs(row[x]) < 30000 then valid=valid+1 end
					i=i+1
				end
			end
			local event = {minp=minp, maxp=maxp, heights=heights}
			local actions, err = fresh:on_generated(event); assert(actions, err)
			for _, action in ipairs(actions) do
				wt({kind="wt_a10_fresh", state="activate", site=action.site, minp=minp, maxp=maxp})
			end
			if valid > 0 then
				local candidates = assert(lookup.lookup(seed, {x1=minp.x,z1=minp.z,x2=maxp.x,z2=maxp.z}))
				for _, d in ipairs(candidates) do
					local r=d.activation_rect
					if minp.x <= r.x2 and maxp.x >= r.x1 and minp.z <= r.z2 and maxp.z >= r.z1 then
						wt({kind="wt_a10_surface", site=d.id, minp=minp, maxp=maxp, valid=valid, site_state=fresh:state(d.id)})
					end
				end
			end
			if selected and target and minp.x == target.x and minp.y == target.y and minp.z == target.z then
				local before = inactive:state(selected.id)
				local after_actions, err2 = inactive:on_generated(event); assert(after_actions, err2)
				wt({kind="wt_a10_competing", state="callback", site=selected.id, before=before,
					after=inactive:state(selected.id), activations=#after_actions, valid=valid, minp=minp, maxp=maxp})
			end
		end
		local function planner(minp, maxp)
			selected = geometry.select(minp, maxp, env.village_reach, env.max_rect,
				function(rect) return lookup.lookup(seed, rect) end)
			if not selected then wt({kind="wt_a10_planner", state="no_candidate", minp=minp}); return end
			wt({kind="wt_a10_planner", state="entry", minp=minp, site=selected,
				fresh_state=fresh:state(selected.id), inactive_before=inactive:state(selected.id)})
			inactive:decline(selected.id)
			wt({kind="wt_a10_planner", state="declined", site=selected.id, inactive_after=inactive:state(selected.id)})
			local x,z=selected.center.x,selected.center.z
			target={x=bounds.CHUNK_ORIGIN+bounds.CHUNKSIZE*bounds.chunk_index(x), y=minp.y,
				z=bounds.CHUNK_ORIGIN+bounds.CHUNKSIZE*bounds.chunk_index(z)}
			wt({kind="wt_a10_competing", state="request", site=selected.id, minp=target})
			core.emerge_area({x=x,y=minp.y+32,z=z}, {x=x,y=minp.y+32,z=z})
		end
		return {generated=generated, planner=planner}
	end)
	core.get_modpath, core.get_current_modname = original_modpath, original_name
	if not ok then error(result) end
	return result
end
