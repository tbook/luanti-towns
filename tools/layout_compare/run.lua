-- Reproducible overhead layout comparison (tickets #109, #152). From the mod root:
--   lua5.1 tools/layout_compare/run.lua [OUTDIR] [seed,seed,...] [--town-type=medieval|roman]
-- OUTDIR defaults to docs/layout_baseline (medieval only; roman needs a scratch
-- OUTDIR outside docs/). Needs no engine. See docs/layout_comparison.md for
-- metric definitions, the Roman command and the diff workflow.
local lib = dofile("tools/layout_compare/lib.lua")
local args = lib.parse_args(arg or {})
local planner = dofile("src/planner.lua")
local catalog = dofile("src/catalog.lua")
local out = lib.run(planner, catalog, {seeds = args.seeds, town_type = args.town_type})
local outdir = args.outdir
os.execute(("mkdir -p '%s'"):format(outdir))
local names = {}
for name in pairs(out.files) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
	local f = assert(io.open(outdir .. "/" .. name, "wb"))
	f:write(out.files[name])
	f:close()
end
print(("wrote %d files to %s (town type %s)"):format(#names, outdir, args.town_type))
