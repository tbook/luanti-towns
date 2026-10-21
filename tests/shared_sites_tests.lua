-- Shared named-site composition and square paving (issue #144).
local eq = ...
local sites = dofile("src/plan_sites.lua")
local preflight = dofile("src/preflight.lua")
local blockouts = dofile("src/blockouts.lua")
local layout = dofile("src/town_layout.lua")(blockouts)

local a = {kind = "landmark", id = "temple", rotation = 0,
	rect = {x1 = 0, z1 = 0, x2 = 1, z2 = 1}}
local b = {kind = "landmark", id = "temple", rotation = 0,
	rect = {x1 = 4, z1 = 0, x2 = 5, z2 = 1}}
local forum = {kind = "square", material = "test:stone", rect = {x1 = 0, z1 = 0, x2 = 5, z2 = 1}}
local plan = {
	site_order = {"forum", "temple_west"},
	sites = {forum = forum, temple_west = a, temple_east = b},
	bounds = {x1 = 0, z1 = 0, x2 = 9, z2 = 9}, streets = {},
}
local ordered = sites.list(plan)
eq(#ordered, 3, "all named sites listed")
eq(ordered[1].name, "forum", "site_order first")
eq(ordered[2].name, "temple_west", "site_order second")
eq(ordered[3].name, "temple_east", "remaining names sorted")

local entries = {temple = {size = {x = 2, y = 3, z = 2}, entrance = {x = 0, z = 0}}}
local comp = assert(preflight.compose(plan, entries, 10))
eq(#comp.structures, 2, "both named temple sites composed")
eq(comp.structures[1].role, "temple_west", "first landmark keeps its site identity")
eq(comp.structures[2].role, "temple_east", "reused catalog id stays a separate site")

local pave = layout.pavement_map(plan)
eq(pave[2] and pave[2][1], "test:stone", "generic forum square is paved")
local legacy = layout.pavement_map({sites = {
	market = {rect = {x1 = 0, z1 = 0, x2 = 2, z2 = 2}, material = "test:market"},
	parvis = {rect = {x1 = 2, z1 = 2, x2 = 4, z2 = 4}, material = "test:parvis"},
}, streets = {}})
eq(legacy[2][2], "test:market", "legacy market remains ahead of parvis")

local bare = {
	sites = {}, streets = {}, bounds = {x1 = 0, z1 = 0, x2 = 1, z2 = 1},
	boundary = {rects = {{x1 = 0, z1 = 0, x2 = 1, z2 = 1}}},
}
local bare_comp = assert(preflight.compose(bare, {}, 10))
eq(#bare_comp.structures, 0, "composition accepts a plan without medieval landmarks")
local L = layout.new(bare, 10, {heights = function() return 10 end, max_y = 20})
eq(L.landmark_dy(0, 0), nil, "missing medieval sites create no blockout")
eq(L.node_at(0, 10, 0), nil, "bare plan keeps natural ground")
