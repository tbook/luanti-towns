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
-- Planning time is printed and kept in timing.txt, not put in report.md,
-- because the report is byte-identical between runs.
local t = out.timing
local line = ("planning time: total %.1f s over %d seeds, mean %.2f s, max %.1f s (seed %s)"):format(
	t.total, #out.rows, t.total / math.max(1, #out.rows), t.max, tostring(t.max_seed))
print(line)
local tf = assert(io.open(outdir .. "/timing.txt", "wb"))
tf:write(line .. "\n")
tf:close()
