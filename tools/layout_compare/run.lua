-- Reproducible overhead layout comparison (ticket #109). From the mod root:
--   lua5.1 tools/layout_compare/run.lua [OUTDIR] [seed,seed,...]
-- OUTDIR defaults to docs/layout_baseline. Needs no engine. See
-- docs/layout_comparison.md for metric definitions and the diff workflow.
local outdir = arg and arg[1] or "docs/layout_baseline"
local seeds
if arg and arg[2] then
	seeds = {}
	for s in arg[2]:gmatch("[^,]+") do seeds[#seeds + 1] = assert(tonumber(s)) end
end
local planner = dofile("src/planner.lua")
local catalog = dofile("src/catalog.lua")
local lib = dofile("tools/layout_compare/lib.lua")
local out = lib.run(planner, catalog, {seeds = seeds})
os.execute(("mkdir -p '%s'"):format(outdir))
local names = {}
for name in pairs(out.files) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
	local f = assert(io.open(outdir .. "/" .. name, "wb"))
	f:write(out.files[name])
	f:close()
end
print(("wrote %d files to %s"):format(#names, outdir))
