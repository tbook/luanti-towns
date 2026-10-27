-- Disposable-world direct API probe for issue #236. This deliberately calls
-- the new search/preflight/build APIs after the unchanged urban builder.
local seed = tonumber(core.settings:get("outskirts_check_seed")) or 5
local town_type = core.settings:get("outskirts_check_town_type")
if town_type == "" then town_type = nil end
local function finish(report)
	local f = assert(io.open(core.get_worldpath() .. "/outskirts-check.json", "w"))
	f:write(core.write_json(report, true)); f:close()
	core.request_shutdown("outskirts check done", false, 0)
end

core.register_on_mods_loaded(function() core.after(0, function()
	local report = {seed = seed, town_type = town_type or "medieval", checks = {}, failures = {}}
	local function check(ok, label)
		report.checks[#report.checks + 1] = {ok = ok and true or false, label = label}
		if not ok then report.failures[#report.failures + 1] = label end
	end
	local ok, err = pcall(function()
		core.emerge_area({x=-48,y=-8,z=-48},{x=48,y=40,z=48},function(_, action, remaining)
			if remaining > 0 then return end
			assert(action ~= core.EMERGE_CANCELLED and action ~= core.EMERGE_ERRORED, "spawn emerge failed")
			towns.populated.search({x=0,y=9,z=0}, seed, town_type, function(result, msg)
				if not result then
					report.failures[#report.failures+1] = tostring(msg or "urban search failed")
					report.ok = false
					return finish(report)
				end
				local build_callback_called = false
				local build_ok, build_error = pcall(towns.populated.build, result,
				function(summary, bmsg, bcode)
				if build_callback_called then return end
				build_callback_called = true
				local bok, berr = pcall(function()
					assert(summary, tostring(bcode) .. ": " .. tostring(bmsg))
					local outmod = dofile(towns.modpath .. "/src/outskirts.lua")
					local entries = assert(outmod.assets(towns.catalog.entries))
					local b = result.plan.bounds
					local rural_asset = town_type == "roman" and "villa" or "shepherd_hut"
					local rural_class = town_type == "roman" and "villa" or "hut"
					local rural_w, rural_d = rural_asset == "villa" and 46 or 9, rural_asset == "villa" and 26 or 8
					local plots = {
						{id="f01",class="farm",asset="farm",rotation=90,ground_y=result.ground_y,
							rect={x1=b.x2+5,z1=b.z1+5,x2=b.x2+17,z2=b.z1+21}},
						{id="r01",class=rural_class,asset=rural_asset,rotation=0,ground_y=result.ground_y,
							rect={x1=b.x2+85,z1=b.z1+10,x2=b.x2+84+rural_w,z2=b.z1+9+rural_d}},
					}
					local out={entries=entries,plots=plots,protected={margin=4}}
					local comp=assert(towns.preflight.compose_outskirts(out,entries))
					local check_env=towns.preflight.core_env(core)
					local pre=assert(towns.preflight.check_outskirts(out,check_env,
						{entries=entries,plan=result.plan,player={x=-1000,z=-1000},modpath=towns.modpath}))
					local terrain=assert(rawget(_G,"living_villages") and living_villages.terrain)
					local adapter=dofile(towns.modpath .. "/src/outskirts_terrain.lua")
					local lo,hi
					local function protected_snapshot()
						local digest, count=0,0
						local ylo=math.min(result.build_bounds.min.y,lo.y)
						local yhi=math.max(result.build_bounds.max.y,hi.y)
						for x=b.x1-4,b.x2+4 do for y=ylo,yhi do for z=b.z1-4,b.z2+4 do
							local node=core.get_node({x=x,y=y,z=z})
							for i=1,#node.name do digest=(digest*33+node.name:byte(i))%2147483647 end
							digest=(digest*33+(node.param2 or 0))%2147483647
							count=count+1
						end end end
						return {digest=digest,count=count}
					end
					for _,plot in ipairs(plots) do
						local plan,sch=adapter.mapping(plot,entries[plot.asset],b)
						local vol=assert(terrain.volume(plan,sch,{}))
						lo=lo and {x=math.min(lo.x,vol.minp.x),y=math.min(lo.y,vol.minp.y),z=math.min(lo.z,vol.minp.z)} or vol.minp
						hi=hi and {x=math.max(hi.x,vol.maxp.x),y=math.max(hi.y,vol.maxp.y),z=math.max(hi.z,vol.maxp.z)} or vol.maxp
					end
					core.emerge_area(lo,hi,function(_, act, rem)
						if rem>0 then return end
						-- Put two single-node tree seeds just outside different protected
						-- edges. Both writes are safe individually, while their bbox spans
						-- the protected corner. LV clears these from the farm terraform zone.
						core.set_node({x=b.x2+5,y=result.ground_y+1,z=b.z1},{name="mcl_core:tree"})
						core.set_node({x=b.x2,y=result.ground_y+1,z=b.z1-5},{name="mcl_core:tree"})
						local urban_snapshot=protected_snapshot()
						local e=towns.builder.core_env(core,{schematic=towns.schematic,modpath=towns.modpath,
							node_setup=towns.node_setup,globals={itemframes=rawget(_G,"mcl_itemframes"),chests=rawget(_G,"mcl_chests")}})
						e.terrain=terrain
						e.check_door=towns.builder.check_door
						local applied,msg,code,extra=dofile(towns.modpath .. "/src/outskirts_build.lua").apply(out,e,
							{bounds=b,structures=comp.structures})
						check(act~=core.EMERGE_CANCELLED and act~=core.EMERGE_ERRORED,"rural volume emerged")
						check(applied~=nil, "direct outskirts apply" .. (msg and (": "..msg) or ""))
						if applied then
							local after=protected_snapshot()
							local same=after.digest==urban_snapshot.digest and after.count==urban_snapshot.count
							report.urban_snapshot=urban_snapshot
							check(same,"urban structure nodes unchanged after outskirts")
							local farm_stats=applied.terraform[1] and applied.terraform[1].stats or {}
							local farm_box=farm_stats.written
							local protected_box={x1=b.x1-4,z1=b.z1-4,x2=b.x2+4,z2=b.z2+4}
							local envelope_overlap=farm_box and farm_box.minp.x<=protected_box.x2
								and farm_box.maxp.x>=protected_box.x1 and farm_box.minp.z<=protected_box.z2
								and farm_box.maxp.z>=protected_box.z1
							check((farm_stats.tree_removed or 0)>0,"corner farm terrain cleared nonzero tree nodes")
							check(core.get_node({x=b.x2+5,y=result.ground_y+1,z=b.z1}).name=="air"
								and core.get_node({x=b.x2,y=result.ground_y+1,z=b.z1-5}).name=="air",
								"both safe corner tree writes were applied")
							check(envelope_overlap,"corner farm written envelope overlaps protection")
							report.protection_regression={bounds=b,protected_box=protected_box,farm_box=farm_box}
							check(applied.placed==2,"both real rural schematics placed")
							check(applied.setup and #applied.setup.failed==0 and #applied.setup.unregistered==0,"rural node setup succeeded")
							local fx,fz=plots[1].rect.x1,plots[1].rect.z1
							local farm=core.get_node({x=fx+6,y=plots[1].ground_y+1,z=fz+8}).name
							local water=core.find_nodes_in_area({x=fx,y=plots[1].ground_y,z=fz},
								{x=fx+12,y=plots[1].ground_y,z=fz+16},{"mcl_core:water_source"})
							local wet=core.find_nodes_in_area({x=fx,y=plots[1].ground_y,z=fz},
								{x=fx+12,y=plots[1].ground_y,z=fz+16},{"mcl_farming:soil_wet"})
							local crops=core.find_nodes_in_area({x=fx,y=plots[1].ground_y+1,z=fz},
								{x=fx+12,y=plots[1].ground_y+1,z=fz+16},
								{"mcl_farming:wheat","mcl_farming:carrot","mcl_farming:potato"})
							local composters=core.find_nodes_in_area({x=fx,y=plots[1].ground_y+1,z=fz},
								{x=fx+12,y=plots[1].ground_y+1,z=fz+16},{"mcl_composters:composter"})
							local watered=true
							for _,p in ipairs(wet) do
								local near=false
								for _,w in ipairs(water) do
									if math.abs(p.x-w.x)<=4 and math.abs(p.z-w.z)<=4 then near=true end
								end
								if not near then watered=false end
							end
							local loom= rural_asset=="shepherd_hut" and core.get_node({x=plots[2].rect.x1+3,y=plots[2].ground_y+2,z=plots[2].rect.z1+5}).name or ""
							local door_offset=rural_asset=="villa" and {x=26,z=22} or {x=4,z=2}
							local door=core.get_node({x=plots[2].rect.x1+door_offset.x,y=plots[2].ground_y+2,z=plots[2].rect.z1+door_offset.z}).name
							check(farm=="mcl_composters:composter","real farm composter placed")
							check(#composters==1,"exactly one real composter is placed")
							check(#water==4,"four real farm water sources remain placed")
							check(#wet==188,"188 real farm blocks remain wet farmland")
							check(#crops==188,"188 real farm crops remain planted")
							check(watered,"real farm farmland is within water's four-node axis range")
							local clear={{5,8},{6,9},{6,7},{7,8}}
							for i,p in ipairs(clear) do
								check(core.get_node({x=fx+p[1],y=plots[1].ground_y+1,z=fz+p[2]}).name=="air",
									"rotated composter standing space "..i)
							end
							check(applied.setup and (applied.setup.by_name or {})["mcl_composters:composter"]==1,
								"real composter is initialized once")
							if rural_asset=="shepherd_hut" then check(loom=="mcl_loom:loom","real hut loom placed") end
							check(door:find("door")~=nil,"real rural door placed")
							report.outskirts={placed=applied.placed,warnings=applied.warnings,skipped=applied.skipped,
							boxes=applied.boxes,attempted=applied.attempted,terraform=applied.terraform,
							placement_attempted=applied.placement_attempted,doors=applied.doors,
							setup=applied.setup,preflight_files=pre.files}
						end
						report.ok=#report.failures==0; finish(report)
					end)
				end)
				if not bok then report.failures[#report.failures+1]=tostring(berr); report.ok=false; finish(report) end
				end)
				if not build_ok and not build_callback_called then
					report.failures[#report.failures+1] = tostring(build_error)
					report.ok = false
					finish(report)
				end
			end)
		end)
	end)
	if not ok then report.failures[#report.failures+1]=tostring(err); report.ok=false; finish(report) end
end) end)
