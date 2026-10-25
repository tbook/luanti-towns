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
				local bok, berr = pcall(function()
					assert(result, msg or "urban search failed")
					local summary, bmsg, bcode = towns.populated.build(result)
					assert(summary, tostring(bcode) .. ": " .. tostring(bmsg))
					local outmod = dofile(towns.modpath .. "/src/outskirts.lua")
					local entries = assert(outmod.assets(towns.catalog.entries))
					local b = result.plan.bounds
					local rural_asset = town_type == "roman" and "villa" or "shepherd_hut"
					local rural_class = town_type == "roman" and "villa" or "hut"
					local rural_w, rural_d = rural_asset == "villa" and 46 or 9, rural_asset == "villa" and 26 or 8
					local plots = {
						{id="f01",class="farm",asset="farm",rotation=0,ground_y=result.ground_y,
							rect={x1=b.x2+22,z1=b.z1+10,x2=b.x2+30,z2=b.z1+16}},
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
							local name=core.get_node({x=x,y=y,z=z}).name
							for i=1,#name do digest=(digest*33+name:byte(i))%2147483647 end
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
					local urban_snapshot=protected_snapshot()
					core.emerge_area(lo,hi,function(_, act, rem)
						if rem>0 then return end
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
							check(applied.placed==2,"both real rural schematics placed")
							check(applied.setup and #applied.setup.failed==0 and #applied.setup.unregistered==0,"rural node setup succeeded")
							local farm=core.get_node({x=plots[1].rect.x1+4,y=plots[1].ground_y+2,z=plots[1].rect.z1}).name
							local loom= rural_asset=="shepherd_hut" and core.get_node({x=plots[2].rect.x1+3,y=plots[2].ground_y+2,z=plots[2].rect.z1+5}).name or ""
							local door_offset=rural_asset=="villa" and {x=26,z=22} or {x=4,z=2}
							local door=core.get_node({x=plots[2].rect.x1+door_offset.x,y=plots[2].ground_y+2,z=plots[2].rect.z1+door_offset.z}).name
							check(farm=="mcl_composters:composter","real farm composter placed")
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
		end)
	end)
	if not ok then report.failures[#report.failures+1]=tostring(err); report.ok=false; finish(report) end
end) end)
