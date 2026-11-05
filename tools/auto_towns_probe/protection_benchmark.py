"""Measure the installed protection provider on real planned stage boxes in a scratch server."""
import importlib.util
import pathlib
import shutil
import socket
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("probe", ROOT / "tools/auto_towns_probe/run.py")
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
world = pathlib.Path(tempfile.mkdtemp(prefix="towns-protection-bench-"))
lines = probe.copy_source_mods(probe.DEFAULT_SOURCE / "world.mt", world)
shutil.copy2(probe.DEFAULT_SOURCE / "map_meta.txt", world / "map_meta.txt")
shutil.copytree(ROOT, world / "worldmods/towns", ignore=shutil.ignore_patterns(".git", "__pycache__"))
fixture = world / "worldmods/protection_benchmark"
fixture.mkdir()
(fixture / "mod.conf").write_text("name = protection_benchmark\ndepends = towns\n")
(fixture / "init.lua").write_text('''
core.after(1, function()
 local checker = dofile(towns.modpath .. "/src/auto_protection.lua")
 local profile = assert(towns.planner.landmark_profile(towns.catalog.snapshot()))
 for _, family in ipairs({"roman", "medieval"}) do
  local seed = family == "roman" and 175458727 or 737210681
  local options = family == "roman" and {town_type = "roman"} or {landmarks = profile, force_walls = true}
  local plan = towns.planner.plan({x = 0, z = 0}, seed, options)
  plan.center = {x = 0, z = 0}
  local wall, features
  if family == "medieval" then
   wall = towns.medieval_walls.plan(plan, true)
   if wall then features = towns.medieval_wall_features.candidates(wall, 8, towns.catalog.entries, towns.medieval_walls) end
  end
  local state = {plan = plan, center = plan.center, ground_y = 8, reference_y = 8, wall = wall, wall_features = features,
   build_bounds = {min = {x = plan.bounds.x1, y = -16, z = plan.bounds.z1},
    max = {x = plan.bounds.x2, y = 48, z = plan.bounds.z2}}}
  local envelope, err = towns.auto_environment.plan_envelope(state)
  if not envelope then core.log("error", "TOWNS_PROTECTION_BENCH error=" .. tostring(err)); break end
  local start = core.get_us_time()
  local ok, reason, count = checker.check({approved = {kind = "write", box = envelope.write}}, core.is_protected, 500000000)
  core.log("action", "TOWNS_PROTECTION_BENCH family=" .. family .. " ok=" .. tostring(ok)
   .. " reason=" .. tostring(reason) .. " checks=" .. count .. " seconds=" .. ((core.get_us_time()-start)/1000000))
 end
 core.request_shutdown("benchmark complete", false, 0)
end)
''')
lines.extend(["load_mod_towns = worldmods/towns", "load_mod_protection_benchmark = worldmods/protection_benchmark"])
(world / "world.mt").write_text("\n".join(lines) + "\n")
(world / "minetest.conf").write_text("server_announce = false\ntowns_auto_mode = off\n")
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as listener:
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
command = [probe.DEFAULT_ENGINE, "--server", "--world", str(world), "--config", str(world / "minetest.conf"),
           "--port", str(port), "--logfile", str(world / "engine.log")]
print("Scratch world:", world, flush=True)
result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
(world / "benchmark-output.txt").write_text(result.stdout)
observations = [line for line in result.stdout.splitlines() if "TOWNS_PROTECTION_BENCH" in line]
print("\n".join(observations))
if result.returncode or len(observations) != 2 or any("ok=true" not in line for line in observations):
    raise SystemExit(1)
