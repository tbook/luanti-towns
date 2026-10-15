-- Towns: reproducible overhead layout comparison (ticket #109).
-- Pure Lua 5.1, no engine: plans a fixed seed set with the real catalog,
-- classifies every node, and returns text/SVG artifacts plus metrics.
-- Metric definitions: docs/layout_comparison.md. Run via
-- tools/layout_compare/run.lua; this module does no file I/O.
--
--   local lib = dofile("tools/layout_compare/lib.lua")
--   local out = lib.run(planner, catalog, {seeds = {...}, centers = {...}})
--   out.files  -- name -> content (metrics.tsv, report.md, seed_N.txt/.svg)
--   out.rows   -- metrics rows (tables)

local M = {}

-- The documented fixed set, chosen before any result was inspected.
M.SEEDS = {1, 7, 42, 101, 256, 1024, 2718, 31415, 99999, 123456, 777777, 1000003}
-- Seeds are assigned round-robin. The centre only translates a layout
-- (planner determinism contract), so centres vary absolute coordinates only.
M.CENTERS = {{x = 0, z = 0}, {x = 1500, z = -2500}, {x = -4200, z = 3100}}

-- Paint order (later wins): {name, glyph, SVG colour, legend text, flags}.
-- overlay classes never affect metrics. hook = reserved for later tickets:
-- drawn only when the plan carries the named field.
local CLASSES = {
	{"boundary", ".", "#e9efe2", "town boundary (free ground)"},
	{"block", ",", "#cfe3b4", "block (free ground behind frontage)"},
	{"secondary", "=", "#b9a98a", "secondary street (4 wide)"},
	{"principal", "#", "#8a7a5e", "principal street (5 wide)"},
	{"market", "M", "#f0d98c", "market square"},
	{"parvis", "p", "#e8c4a0", "parvis (cathedral square)"},
	{"cathedral", "C", "#7b5ea7", "cathedral compound"},
	{"castle", "K", "#5b6b8c", "castle compound"},
	{"city_hall", "H", "#c0392b", "city hall"},
	{"jail", "J", "#444444", "jail"},
	{"tavern", "T", "#d4802a", "tavern"},
	{"well", "O", "#2a8fd4", "well"},
	{"chapel", "Y", "#a64ca6", "chapel"},
	{"house", "h", "#f7f7f7", "ordinary house"},
	{"shop", "s", "#9fd8d0", "ordinary shop"},
	{"workshop", "w", "#d8c19f", "ordinary workshop"},
	{"alley", "a", "#bbbbbb", "access alley"},
	{"approach", "A", "#ffd400", "boundary approach window", overlay = true},
	{"core", "o", "#ff8c00", "town core (HOOK: plan.core, not yet planned)", overlay = true},
	{"footprint", "f", "#000000", "construction footprint (HOOK: plan.footprint)", overlay = true, outline = true},
	{"exit", "x", "#00a000", "designated exit (HOOK: plan.exits)", overlay = true},
	{"strip", "!", "#ff00ff", "narrow strip cells (metric)", overlay = true},
	{"centre", "+", "#000000", "town centre (circle)", overlay = true},
}
local INDEX = {}
for i, c in ipairs(CLASSES) do INDEX[c[1]] = i end
M.CLASSES = CLASSES

local function sorted_keys(t)
	local k = {}
	for key in pairs(t) do k[#k + 1] = key end
	table.sort(k)
	return k
end

local function rect_cells(r) return (r.x2 - r.x1 + 1) * (r.z2 - r.z1 + 1) end

-- Stable 32-bit string hash (djb2-style, exact in doubles).
local function hash(s)
	local h = 5381
	for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
	return ("%08x"):format(h)
end

-- Hash of the sorted catalog snapshot: id, role, size, entrance, ground_offset.
function M.catalog_hash(snapshot)
	local parts = {}
	for _, id in ipairs(sorted_keys(snapshot)) do
		local e = snapshot[id]
		parts[#parts + 1] = ("%s|%s|%d,%d,%d|%d,%d,%d|%s"):format(id, tostring(e.role),
			e.size.x, e.size.y, e.size.z, e.entrance.x, e.entrance.y, e.entrance.z,
			tostring(e.ground_offset or 0))
	end
	return hash(table.concat(parts, ";")), #parts
end

-- Row depth D of the catalog-derived depth policy (ticket #86): the depth a
-- block must have for one row of ordinary buildings, computed by
-- planner.row_depth from the same profile the planner used (the lower median
-- of the eligible entries' depth; see src/planner.lua). Metrics that need a
-- "buildable depth" use this single number.
local planner_module
function M.row_depth(profile)
	planner_module = planner_module or dofile("src/planner.lua")
	return planner_module.row_depth(profile)
end

-- Ordered paint list {class, rect} for a finished plan.
local function layers(plan)
	local L = {}
	local function add(class, r) L[#L + 1] = {class = class, rect = r} end
	for _, r in ipairs(plan.boundary.rects) do add("boundary", r) end
	for _, b in ipairs(plan.blocks) do add("block", b.rect) end
	for _, kind in ipairs({"secondary", "principal"}) do
		for _, s in ipairs(plan.streets) do
			if s.kind == kind then add(kind, s.rect) end
		end
	end
	add("market", plan.sites.market.rect)
	add("parvis", plan.sites.parvis.rect)
	add("cathedral", plan.sites.cathedral.rect)
	add("castle", plan.sites.castle.rect)
	if plan.sites.city_hall then add("city_hall", plan.sites.city_hall.rect) end
	local res = plan.reservations or {}
	if res.jail then add("jail", res.jail.rect) end
	for _, s in ipairs(res.services or {}) do add(s.role, s.rect) end
	local content = plan.content or {}
	for _, b in ipairs(content.buildings or {}) do add(b.role, b.rect) end
	for _, a in ipairs(content.alleys or {}) do add("alley", a.rect) end
	for _, a in ipairs(plan.approaches) do add("approach", a.edge) end
	-- Hooks for later layout tickets; field names are provisional.
	if type(plan.core) == "table" and plan.core.x1 then add("core", plan.core) end
	if type(plan.footprint) == "table" and plan.footprint.x1 then add("footprint", plan.footprint) end
	for _, e in ipairs(plan.exits or {}) do
		local r = e.rect or e.edge
		if r then add("exit", r) end
	end
	return L
end

local function new_grid(b)
	local g = {}
	for z = b.z1, b.z2 do g[z] = {} end
	return g
end

local function paint(g, b, r, v)
	for z = math.max(r.z1, b.z1), math.min(r.z2, b.z2) do
		local row = g[z]
		for x = math.max(r.x1, b.x1), math.min(r.x2, b.x2) do row[x] = v end
	end
end

-- Connected components (4-neighbour) of cells where test(x, z) is true.
local function components(b, test)
	local seen = {}
	for z = b.z1, b.z2 do seen[z] = {} end
	local comps = {}
	for z0 = b.z1, b.z2 do
		for x0 = b.x1, b.x2 do
			if test(x0, z0) and not seen[z0][x0] then
				local c = {x1 = x0, x2 = x0, z1 = z0, z2 = z0, area = 0, cells = {}}
				local stack = {{x0, z0}}
				seen[z0][x0] = true
				while #stack > 0 do
					local p = table.remove(stack)
					local x, z = p[1], p[2]
					c.area = c.area + 1
					c.cells[c.area] = p
					if x < c.x1 then c.x1 = x end
					if x > c.x2 then c.x2 = x end
					if z < c.z1 then c.z1 = z end
					if z > c.z2 then c.z2 = z end
					for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
						local nx, nz = x + d[1], z + d[2]
						if nx >= b.x1 and nx <= b.x2 and nz >= b.z1 and nz <= b.z2
								and not seen[nz][nx] and test(nx, nz) then
							seen[nz][nx] = true
							stack[#stack + 1] = {nx, nz}
						end
					end
				end
				comps[#comps + 1] = c
			end
		end
	end
	return comps
end

-- Cells of `free` not inside any DxD all-free window (the "opening").
local function residue_test(b, free, D)
	local w, h = b.x2 - b.x1 + 1, b.z2 - b.z1 + 1
	local S = {}
	for j = 0, h do
		S[j] = {}
		for i = 0, w do S[j][i] = 0 end
	end
	for j = 1, h do
		for i = 1, w do
			S[j][i] = S[j - 1][i] + S[j][i - 1] - S[j - 1][i - 1]
				+ ((free[b.z1 + j - 1][b.x1 + i - 1]) and 1 or 0)
		end
	end
	local diff = {}
	for j = 1, h + 1 do
		diff[j] = {}
		for i = 1, w + 1 do diff[j][i] = 0 end
	end
	for j = 1, h - D + 1 do
		for i = 1, w - D + 1 do
			local sum = S[j + D - 1][i + D - 1] - S[j - 1][i + D - 1]
				- S[j + D - 1][i - 1] + S[j - 1][i - 1]
			if sum == D * D then
				diff[j][i] = diff[j][i] + 1
				diff[j][i + D] = diff[j][i + D] - 1
				diff[j + D][i] = diff[j + D][i] - 1
				diff[j + D][i + D] = diff[j + D][i + D] + 1
			end
		end
	end
	local covered = {}
	local acc = {}
	for j = 1, h do
		covered[j] = {}
		local run = 0
		for i = 1, w do
			run = run + diff[j][i]
			acc[i] = (acc[i] or 0) + run
			covered[j][i] = acc[i] > 0
		end
	end
	return function(x, z)
		return free[z][x] and not covered[z - b.z1 + 1][x - b.x1 + 1]
	end
end

local FREE = {boundary = true, block = true, house = true, shop = true,
	workshop = true, alley = true}

-- Classify a finished plan. Returns metrics table, class grid, paint list
-- (including the narrow-strip overlay).
function M.analyze(plan, profile)
	local b = plan.bounds
	local grid = new_grid(b)
	local over = layers(plan)
	for _, l in ipairs(over) do
		if not CLASSES[INDEX[l.class]].overlay then paint(grid, b, l.rect, l.class) end
	end
	local m = {}
	local count = {}
	local free = new_grid(b)
	for z = b.z1, b.z2 do
		for x = b.x1, b.x2 do
			local c = grid[z][x]
			if c then count[c] = (count[c] or 0) + 1 end
			free[z][x] = c ~= nil and FREE[c] == true
		end
	end
	local in_boundary = 0
	for _, n in pairs(count) do in_boundary = in_boundary + n end
	m.boundary_cells = in_boundary
	m.free_cells = (count.boundary or 0) + (count.block or 0) + (count.house or 0)
		+ (count.shop or 0) + (count.workshop or 0) + (count.alley or 0)

	-- Streets: unique pavement cells not covered by a square.
	m.street_cells_principal = count.principal or 0
	m.street_cells_secondary = count.secondary or 0
	m.street_len_principal = m.street_cells_principal / 5
	m.street_len_secondary = m.street_cells_secondary / 4
	m.street_len = m.street_len_principal + m.street_len_secondary
	local sum = 0
	for _, s in ipairs(plan.streets) do
		sum = sum + math.max(s.rect.x2 - s.rect.x1 + 1, s.rect.z2 - s.rect.z1 + 1)
	end
	m.street_rect_run_sum = sum
	m.streets = #plan.streets

	-- Blocks and frontage.
	local D = M.row_depth(profile) or 0
	m.row_depth = D
	m.blocks = #plan.blocks
	local block_by_id = {}
	local single, block_cells = 0, 0
	for _, bl in ipairs(plan.blocks) do
		block_by_id[bl.id] = bl
		block_cells = block_cells + rect_cells(bl.rect)
		if math.min(bl.size.x, bl.size.z) < 2 * D then single = single + 1 end
	end
	m.blocks_single_row = single
	m.block_cells = block_cells
	local fo, fu, fs = 0, 0, 0
	local run_by_id = {}
	for _, run in ipairs(plan.frontage) do
		run_by_id[run.id] = run
		if run.street then
			fo = fo + run.length
			local r = block_by_id[run.block].rect
			local depth = (run.side == "+z" or run.side == "-z")
				and (r.z2 - r.z1 + 1) or (r.x2 - r.x1 + 1)
			if depth >= D then fu = fu + run.length end
		else
			fs = fs + run.length
		end
	end
	m.frontage_ordinary, m.frontage_usable, m.frontage_square = fo, fu, fs

	-- Placed content.
	local content = plan.content or {}
	local counts = content.counts or {}
	m.houses, m.shops, m.workshops = counts.house or 0, counts.shop or 0, counts.workshop or 0
	m.ordinary = m.houses + m.shops + m.workshops
	local used = 0
	for _, bd in ipairs(content.buildings or {}) do
		local run = run_by_id[bd.frontage]
		if run then
			if run.side == "+z" or run.side == "-z" then
				used = used + (bd.rect.x2 - bd.rect.x1 + 1)
			else
				used = used + (bd.rect.z2 - bd.rect.z1 + 1)
			end
		end
	end
	m.frontage_used = used
	m.alleys = #(content.alleys or {})
	m.empty_runs = #(content.empty_runs or {})
	local unused = 0
	for _, u in ipairs(content.unused or {}) do unused = unused + u.length end
	m.unused_len = unused
	local res = plan.reservations or {}
	m.jail = res.jail and 1 or 0
	m.services = #(res.services or {})
	m.shortages = #(plan.shortages or {})

	-- Narrow strips: residue of the DxD opening of the free ground.
	local strips, specks, strip_cells, speck_cells = {}, 0, 0, 0
	if D > 0 then
		local test = residue_test(b, free, D)
		for _, c in ipairs(components(b, test)) do
			if math.max(c.x2 - c.x1 + 1, c.z2 - c.z1 + 1) >= D then
				strips[#strips + 1] = c
				strip_cells = strip_cells + c.area
			else
				specks = specks + 1
				speck_cells = speck_cells + c.area
			end
		end
	end
	m.strips, m.strip_cells = #strips, strip_cells
	m.specks, m.speck_cells = specks, speck_cells
	-- Strip cells as merged rectangles (horizontal runs, merged vertically).
	local sgrid = new_grid(b)
	for _, s in ipairs(strips) do
		for _, p in ipairs(s.cells) do sgrid[p[2]][p[1]] = true end
	end
	local open_runs = {}
	for z = b.z1, b.z2 + 1 do
		local now = {}
		local x = b.x1
		while z <= b.z2 and x <= b.x2 do
			if sgrid[z][x] then
				local x0 = x
				while x + 1 <= b.x2 and sgrid[z][x + 1] do x = x + 1 end
				local key = x0 .. ":" .. x
				local r = open_runs[key]
				if r then
					r.z2 = z
					open_runs[key] = nil
				else
					r = {x1 = x0, x2 = x, z1 = z, z2 = z}
					over[#over + 1] = {class = "strip", rect = r}
				end
				now[key] = r
			end
			x = x + 1
		end
		open_runs = now
	end

	-- Parvis and market.
	local pv = plan.sites.parvis
	m.parvis_x, m.parvis_z, m.parvis_area = pv.size.x, pv.size.z, rect_cells(pv.rect)
	local mk = plan.sites.market.rect
	m.market_x, m.market_z = plan.sites.market.size.x, plan.sites.market.size.z
	m.market_area = rect_cells(mk)
	local open, dp, best = 0, {}, 0
	for z = mk.z1, mk.z2 do
		dp[z] = {}
		for x = mk.x1, mk.x2 do
			if grid[z][x] == "market" then
				open = open + 1
				local v = 1
				if z > mk.z1 and x > mk.x1 then
					v = 1 + math.min(dp[z - 1][x], dp[z][x - 1], dp[z - 1][x - 1])
				end
				dp[z][x] = v
				if v > best then best = v end
			else
				dp[z][x] = 0
			end
		end
	end
	m.market_open = open
	m.market_open_share = open / m.market_area
	m.market_open_square = best
	return m, grid, over
end

------------------------------------------------------------------------
-- Rendering
------------------------------------------------------------------------

-- ASCII at 1 char = 2x2 nodes; highest paint priority of the four wins.
local function ascii(plan, grid, over)
	local b = plan.bounds
	local ov = new_grid(b)
	local function put(x, z, v)
		if x >= b.x1 and x <= b.x2 and z >= b.z1 and z <= b.z2 then ov[z][x] = v end
	end
	for _, l in ipairs(over) do
		local c = CLASSES[INDEX[l.class]]
		local r = l.rect
		if c.outline then
			for x = r.x1, r.x2 do put(x, r.z1, l.class) put(x, r.z2, l.class) end
			for z = r.z1, r.z2 do put(r.x1, z, l.class) put(r.x2, z, l.class) end
		elseif c.overlay and l.class ~= "centre" then
			paint(ov, b, r, l.class)
		end
	end
	put(plan.center.x, plan.center.z, "centre")
	local lines = {}
	for z = b.z2, b.z1, -2 do
		local row = {}
		for x = b.x1, b.x2, 2 do
			local best, name = 0, nil
			for dz = 0, -1, -1 do
				for dx = 0, 1 do
					local zz, xx = z + dz, x + dx
					if zz >= b.z1 and xx <= b.x2 then
						local c = ov[zz][xx] or grid[zz][xx]
						if c and INDEX[c] > best then best, name = INDEX[c], c end
					end
				end
			end
			row[#row + 1] = name and CLASSES[INDEX[name]][2] or " "
		end
		lines[#lines + 1] = (table.concat(row):gsub("%s+$", ""))
	end
	return table.concat(lines, "\n")
end

local SCALE = 4
local function esc(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"))
end

local function svg(plan, over, title)
	local b = plan.bounds
	local W, H = b.x2 - b.x1 + 1, b.z2 - b.z1 + 1
	local LW = 80
	local legend_h = #CLASSES * 4 + 4
	if legend_h > H then H = legend_h end
	local out = {}
	local function P(s) out[#out + 1] = s end
	P(('<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" shape-rendering="crispEdges" font-family="monospace" font-size="3">'):format(
		(W + LW) * SCALE, H * SCALE, W + LW, H))
	P("<title>" .. esc(title) .. "</title>")
	P(('<rect width="%d" height="%d" fill="#ffffff"/>'):format(W + LW, H))
	local top = b.z2
	for _, l in ipairs(over) do
		local c = CLASSES[INDEX[l.class]]
		local r = l.rect
		local x, y = r.x1 - b.x1, top - r.z2
		local w, h = r.x2 - r.x1 + 1, r.z2 - r.z1 + 1
		if c.outline then
			P(('<rect x="%d" y="%d" width="%d" height="%d" fill="none" stroke="%s" stroke-width="0.7"/>'):format(x, y, w, h, c[3]))
		elseif l.class == "house" or l.class == "shop" or l.class == "workshop" then
			P(('<rect x="%d" y="%d" width="%d" height="%d" fill="%s" stroke="#555555" stroke-width="0.3"/>'):format(x, y, w, h, c[3]))
		else
			P(('<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>'):format(x, y, w, h, c[3]))
		end
	end
	P(('<circle cx="%.1f" cy="%.1f" r="1.5" fill="none" stroke="#000000" stroke-width="0.6"/>'):format(
		plan.center.x - b.x1 + 0.5, top - plan.center.z + 0.5))
	for i, c in ipairs(CLASSES) do
		local y = 2 + (i - 1) * 4
		P(('<rect x="%d" y="%d" width="3" height="3" fill="%s" stroke="#000000" stroke-width="0.2"/>'):format(
			W + 3, y, c.outline and "#ffffff" or c[3]))
		P(('<text x="%d" y="%.1f">%s</text>'):format(W + 7, y + 2.6, esc(c[4])))
	end
	P("</svg>")
	return table.concat(out, "\n") .. "\n"
end

------------------------------------------------------------------------
-- Run
------------------------------------------------------------------------

local COLUMNS = {
	"seed", "center", "status", "attempts", "width", "depth", "boundary_cells",
	"streets", "street_len", "street_len_principal", "street_len_secondary",
	"street_cells_principal", "street_cells_secondary", "street_rect_run_sum",
	"blocks", "blocks_single_row", "block_cells", "free_cells",
	"frontage_ordinary", "frontage_usable", "frontage_square", "frontage_used",
	"ordinary", "houses", "shops", "workshops", "jail", "services", "shortages",
	"alleys", "empty_runs", "unused_len",
	"row_depth", "strips", "strip_cells", "specks", "speck_cells",
	"parvis_x", "parvis_z", "parvis_area",
	"market_x", "market_z", "market_area", "market_open", "market_open_share",
	"market_open_square",
}
M.COLUMNS = COLUMNS

local function fmt(v)
	if type(v) == "number" then
		if v == math.floor(v) then return ("%d"):format(v) end
		return ("%.3f"):format(v)
	end
	return tostring(v)
end

-- One seed at one centre -> row, files. Never raises on planning failure.
function M.one(planner, profile, seed, center)
	local row = {seed = seed, center = ("%d,%d"):format(center.x, center.z)}
	local plan, why, detail = planner.plan(center, seed, {landmarks = profile})
	if not plan then
		row.status = "FAILED"
		row.failure = tostring(why)
		row.failure_code = detail and detail.code or "?"
		row.attempts = detail and detail.attempts or 0
		return row, nil
	end
	row.status = "ok"
	row.attempts = plan.attempts
	row.width, row.depth = plan.width, plan.depth
	local m, grid, over = M.analyze(plan, profile)
	for k, v in pairs(m) do row[k] = v end
	local title = ("seed %d centre (%d,%d)"):format(seed, center.x, center.z)
	local head = {title .. (" bounds %dx%d attempts %d"):format(plan.width, plan.depth, plan.attempts),
		"scale: 1 char = 2x2 nodes, north (+Z) up, east (+X) right", "legend:"}
	for _, c in ipairs(CLASSES) do head[#head + 1] = ("  %s  %s"):format(c[2], c[4]) end
	return row, {
		txt = table.concat(head, "\n") .. "\n\n" .. ascii(plan, grid, over) .. "\n",
		svg = svg(plan, over, title),
	}
end

function M.run(planner, catalog, opts)
	opts = opts or {}
	local seeds = opts.seeds or M.SEEDS
	local centers = opts.centers or M.CENTERS
	local snapshot = catalog.snapshot()
	local profile = assert(planner.landmark_profile(snapshot))
	local chash, ncat = M.catalog_hash(snapshot)
	local C = planner.resolve_constants({landmarks = profile})
	local files, rows = {}, {}
	for i, seed in ipairs(seeds) do
		local center = centers[(i - 1) % #centers + 1]
		local row, f = M.one(planner, profile, seed, center)
		rows[#rows + 1] = row
		if f then
			files[("seed_%d.txt"):format(seed)] = f.txt
			files[("seed_%d.svg"):format(seed)] = f.svg
		end
	end

	local t = {table.concat(COLUMNS, "\t")}
	for _, r in ipairs(rows) do
		local cells = {}
		for j, c in ipairs(COLUMNS) do
			cells[j] = r[c] == nil and "-" or fmt(r[c])
		end
		t[#t + 1] = table.concat(cells, "\t")
	end
	files["metrics.tsv"] = table.concat(t, "\n") .. "\n"

	local R = {}
	local function P(s) R[#R + 1] = s end
	P("# Layout comparison report")
	P("")
	P("Generated by `tools/layout_compare/run.lua` (ticket #109). Definitions: `docs/layout_comparison.md`.")
	P("")
	P(("- Catalog: %d entries, hash `%s` (definition in the docs)"):format(ncat, chash))
	P(("- Row depth D (catalog-derived, lower median of eligible ordinary building depths) = %d"):format(M.row_depth(profile) or 0))
	P(("- Seeds: %s"):format(table.concat(seeds, ", ")))
	local cs = {}
	for i, c in ipairs(centers) do cs[i] = ("(%d,%d)"):format(c.x, c.z) end
	P(("- Centres (round-robin by seed index): %s"):format(table.concat(cs, " ")))
	P("- Planner call: `planner.plan(center, seed, {landmarks = planner.landmark_profile(catalog.snapshot())})`, default max_attempts")
	P("")
	P("## Layout constants (planner.resolve_constants with the landmark profile)")
	P("")
	P("```")
	for _, k in ipairs(sorted_keys(C)) do P(("%s = %s"):format(k, tostring(C[k]))) end
	P("```")
	P("")
	P("## Planning failures")
	P("")
	local nfail = 0
	for _, r in ipairs(rows) do
		if r.status ~= "ok" then
			nfail = nfail + 1
			P(("- seed %d centre %s: %s (code %s, attempts %s)"):format(r.seed, r.center,
				r.failure, r.failure_code, tostring(r.attempts)))
		end
	end
	if nfail == 0 then P("None: every seed in the set planned successfully.") end
	P("")
	P("## Metrics")
	P("")
	local show = {"seed", "center", "status", "attempts", "street_len", "street_len_principal",
		"street_len_secondary", "frontage_ordinary", "frontage_usable", "frontage_used",
		"ordinary", "houses", "shops", "workshops", "blocks", "blocks_single_row", "strips",
		"strip_cells", "specks", "parvis_x", "parvis_z", "market_area", "market_open_share",
		"market_open_square", "jail", "services", "alleys", "empty_runs"}
	P("| " .. table.concat(show, " | ") .. " |")
	local sep = {}
	for i = 1, #show do sep[i] = "---" end
	P("| " .. table.concat(sep, " | ") .. " |")
	local ok_rows, tot = 0, {}
	local sums = {"street_len", "frontage_ordinary", "frontage_usable", "frontage_used",
		"ordinary", "blocks", "blocks_single_row", "strips", "strip_cells", "parvis_area",
		"market_open_share"}
	for _, r in ipairs(rows) do
		local cells = {}
		for j, c in ipairs(show) do
			local v = r[c]
			if v == nil then
				cells[j] = "-"
			elseif type(v) == "number" and v ~= math.floor(v) then
				cells[j] = ("%.2f"):format(v)
			else
				cells[j] = fmt(v)
			end
		end
		P("| " .. table.concat(cells, " | ") .. " |")
		if r.status == "ok" then
			ok_rows = ok_rows + 1
			for _, c in ipairs(sums) do tot[c] = (tot[c] or 0) + r[c] end
			tot.with_strips = (tot.with_strips or 0) + (r.strips > 0 and 1 or 0)
		end
	end
	P("")
	P("## Totals over planned seeds")
	P("")
	P(("- Planned %d of %d seeds."):format(ok_rows, #rows))
	if ok_rows > 0 then
		P(("- Plans with at least one narrow strip: %d of %d."):format(tot.with_strips, ok_rows))
		P(("- Narrow strips: %d, covering %d nodes."):format(tot.strips, tot.strip_cells))
		P(("- Blocks: %d, of which single-row (shorter side < 2*D): %d (%.0f%%)."):format(
			tot.blocks, tot.blocks_single_row, 100 * tot.blocks_single_row / math.max(1, tot.blocks)))
		P(("- Per plan means: street length %.1f; ordinary frontage %.1f, usable %.1f, used by placed buildings %.1f."):format(
			tot.street_len / ok_rows, tot.frontage_ordinary / ok_rows,
			tot.frontage_usable / ok_rows, tot.frontage_used / ok_rows))
		P(("- Placed ordinary buildings: total %d, mean %.1f."):format(tot.ordinary, tot.ordinary / ok_rows))
		P(("- Parvis area mean %.0f; market open share mean %.2f."):format(
			tot.parvis_area / ok_rows, tot.market_open_share / ok_rows))
	end
	files["report.md"] = table.concat(R, "\n") .. "\n"
	return {files = files, rows = rows, catalog_hash = chash, constants = C}
end

return M
