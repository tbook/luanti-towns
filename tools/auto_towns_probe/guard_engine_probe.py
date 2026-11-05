import importlib.util, pathlib, shutil, subprocess, tempfile, sys, socket
root=pathlib.Path(__file__).resolve().parents[2]
fallback = "--vanilla-fallback" in sys.argv[1:]
spec=importlib.util.spec_from_file_location('probe',root/'tools/auto_towns_probe/run.py')
p=importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
w=pathlib.Path(tempfile.mkdtemp(prefix='towns400-engine-'))
lines=p.copy_source_mods(p.DEFAULT_SOURCE/'world.mt',w)
shutil.copy2(p.DEFAULT_SOURCE/'map_meta.txt',w/'map_meta.txt')
shutil.copytree(root,w/'worldmods/towns',ignore=shutil.ignore_patterns('.git','__pycache__'))
f=w/'worldmods/guard_fixture';f.mkdir()
(f/'mod.conf').write_text('name = guard_fixture\ndepends = towns\n')
(f/'init.lua').write_text('''
core.after(1, function()
 local function emit(s) core.log("action", "TOWNS400_PROBE " .. s) end
 local guard = towns.auto_village_guard
 if not guard then emit("FAIL startup " .. tostring(towns.auto_disabled)); core.request_shutdown(); return end
 local fallback = core.settings:get_bool("guard_probe_fallback", false)
 local healthy = guard:check()
 emit(((fallback and not healthy and towns.auto_disabled) or (not fallback and healthy)) and "PASS startup" or "FAIL startup")
 emit("INFO reach=" .. guard.reach .. " check=" .. tostring(healthy))
 local record = {cell={x=0,z=0},version=1,seed=1,town_type="medieval",center={x=150,y=10,z=150},
 envelope={min={x=100,y=0,z=100},max={x=200,y=20,z=200}},state="building"}
 local ok, why=towns.auto_records:begin(record)
 if not ok then emit("FAIL record " .. tostring(why)); core.request_shutdown(); return end
 local original=guard.original
 local calls=0
 guard.original=function(maxp,minp,pr,extra) calls=calls+1; pr.count=pr.count+1; return "passed", nil, extra end
 local pr={count=0}
 local maxp={x=200,y=47,z=150};local minp={x=200,y=-32,z=150}
 local denied=settlements.create_site_plan(maxp,minp,pr,"argument")
 emit((denied==false and calls==0 and pr.count==0 and "PASS" or "FAIL") .. " accepted_off suppressed=" .. tostring(denied==false) .. " original_calls=" .. calls .. " rng=" .. pr.count)
 local x=200+guard.reach+1
 local a,b,c=settlements.create_site_plan({x=x,y=47,z=150},{x=x,y=-32,z=150},pr,"argument")
 emit((a=="passed" and b==nil and c=="argument" and calls==1 and pr.count==1 and "PASS" or "FAIL") .. " near_miss original_calls=" .. calls .. " rng=" .. pr.count .. " return=" .. tostring(a))
 guard.original=original
 emit("INFO planner_identity_assumed A10_unverified stub_used_for_pass_through")
 core.request_shutdown("towns400 fixture complete",false,0)
end)
''')
lines.extend(['load_mod_towns = worldmods/towns','load_mod_guard_fixture = worldmods/guard_fixture'])
(w/'world.mt').write_text('\n'.join(lines)+'\n')
(w/'minetest.conf').write_text('server_announce = false\nenable_damage = false\n' + ('living_villages_smooth_villages = false\nguard_probe_fallback = true\n' if fallback else ''))
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as listener:
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
cmd=[p.DEFAULT_ENGINE,'--server','--world',str(w),'--config',str(w/'minetest.conf'),'--port',str(port),'--logfile',str(w/'engine.log')]
print('WORLD',w,flush=True)
print('COMMAND',cmd,flush=True)
r=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=120)
(w/'guard-output.txt').write_text(r.stdout)
lines = [line for line in r.stdout.splitlines() if 'TOWNS400_PROBE' in line]
print('\n'.join(lines))
print('EXIT',r.returncode)
if r.returncode != 0 or len([line for line in lines if 'TOWNS400_PROBE PASS' in line]) != 3 or any('TOWNS400_PROBE FAIL' in line for line in lines):
    raise SystemExit(1)
