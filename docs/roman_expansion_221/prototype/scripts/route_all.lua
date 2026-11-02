local root = arg[1]
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)/")
local function run(id, x, y, z, facing)
  for _, r in ipairs({0, 90, 180, 270}) do
    arg = {}
    arg[1], arg[2], arg[3], arg[4], arg[5], arg[6], arg[7] = root, id, tostring(r), tostring(x), tostring(y), tostring(z), facing
    dofile(here .. "/route_check.lua")
  end
end
run("temple_of_jupiter", 9, 3, 8)
run("temple_of_vesta", 5, 2, 3)
run("hippodrome", 18, 8, 3)
run("hippodrome", 18, 8, 0)
run("hippodrome", 2, 8, 7, "-X")
