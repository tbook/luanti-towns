-- Public integration API (#458): src/towns_api.lua over a real registry, a real
-- generation lock and a fake session. Loaded by tests/run.lua:
--   loadfile("tests/towns_api_tests.lua")(eq)
local eq = ...
local records_mod = dofile("src/auto_records.lua")
local api_mod = dofile("src/towns_api.lua")
local lock_factory = dofile("src/generation_lock.lua")

local function literal(v)
	if type(v) == "number" or type(v) == "boolean" then return tostring(v) end
	if type(v) == "string" then return string.format("%q", v) end
	local fields = {}
	for k, x in pairs(v) do fields[#fields + 1] = "[" .. literal(k) .. "]=" .. literal(x) end
	table.sort(fields)
	return "{" .. table.concat(fields, ",") .. "}"
end
local function serializers()
	return function(v) return literal(v) end, function(s)
		local chunk, err = loadstring("return " .. s)
		if not chunk then error(err) end
		return chunk()
	end
end

local function new_registry(values)
	values = values or {}
	local serialize, deserialize = serializers()
	return records_mod.new({store = {get = function(k) return values[k] end,
		set = function(k, v) values[k] = v end}, serialize = serialize, deserialize = deserialize}), values
end

local function record(cx, cz, x, z)
	return {cell = {x = cx, z = cz}, version = 2, seed = 41, town_type = "medieval",
		center = {x = x, y = 22, z = z},
		envelope = {min = {x = x - 100, y = -20, z = z - 100}, max = {x = x + 100, y = 100, z = z + 100}},
		state = "building", site_id = "2:" .. cx .. ":" .. cz .. ":0:medieval:41:" .. x .. ":" .. z}
end

local function flat_exit(x, z, dir)
	local profile = {}
	for n = 1, 4 do profile[n] = {y = 22, name = "mcl_core:cobble", param2 = 0} end
	local columns = dir.x ~= 0 and {{x = x, z = z}, {x = x, z = z + 1}} or {{x = x, z = z}, {x = x + 1, z = z}}
	local label = ({["1:0"] = "+x", ["-1:0"] = "-x", ["0:1"] = "+z", ["0:-1"] = "-z"})[dir.x .. ":" .. dir.z]
	return {id = label .. ":" .. x .. ":" .. z, source = "street", direction = dir, columns = columns,
		length = 4, profile = profile}
end

local function published(x, z, exits_list)
	return {format = 1, core = {x1 = x - 30, z1 = z - 30, x2 = x + 30, z2 = z + 30},
		structures = {{x1 = x + 60, z1 = z, x2 = x + 70, z2 = z + 10}},
		exits = exits_list or {flat_exit(x + 31, z, {x = 1, z = 0}), flat_exit(x - 31, z + 9, {x = -1, z = 0})},
		omitted = {}}
end

local function complete(reg, cx, cz, x, z, pub)
	assert(reg:begin(record(cx, cz, x, z)))
	assert(reg:update({x = cx, z = cz}, "complete", pub == nil and published(x, z) or pub or nil))
end

local lock = lock_factory()
local reg, values = new_registry()
local live_list = {}
local session = {live = function(_, rect)
	local out = {}
	for _, c in ipairs(live_list) do
		local m = c.max_rect
		if m.x1 <= rect.x2 and rect.x1 <= m.x2 and m.z1 <= rect.z2 and rect.z1 <= m.z2 then out[#out + 1] = c end
	end
	return out
end}
local have_session = true
local api = api_mod.new({registry = function() return reg end,
	session = function() return have_session and session or nil end, lock = lock})

eq(api.version, 1, "api version")
eq(api.available(), true, "available with a healthy registry")

-- Nothing recorded yet.
local list = api.settlements({x = 0, y = 0, z = 0}, 500)
eq(#list, 0, "no settlements before any town completes")

-- Fixtures: A complete+published, B complete (old, unsupported), C building, D interrupted,
-- E complete+published, further away.
complete(reg, 1, 0, 1000, 0)
do
	assert(reg:begin(record(2, 0, 2000, 0)))
	assert(reg:update({x = 2, z = 0}, "complete"))
end
assert(reg:begin(record(3, 0, 3000, 0)))
assert(reg:begin(record(4, 0, 4000, 0)))
assert(reg:update({x = 4, z = 0}, "interrupted"))
complete(reg, 0, 1, 0, 1010)

-- Completion filtering: only complete + published settlements are listed.
list = api.settlements({x = 0, y = 0, z = 0}, 1024)
eq(#list, 2, "only complete published settlements are listed")
eq(list[1].id, "auto:1:0", "nearest first")
eq(list[2].id, "auto:0:1", "then farther")
list = api.settlements({x = 0, y = 0, z = 0}, 1024)
eq(#list, 2, "radius includes both (1000 and 1010 away)")
list = api.settlements({x = 0, y = 0, z = 0}, 1005)
eq(#list, 1, "radius bounds the result")
eq(api.settlements({x = 5000, z = 0}, 1000) ~= nil, true, "far query is empty, not an error")
eq(#api.settlements({x = 5000, z = 0}, 1000), 0, "far query returns no settlements")

-- Shape.
do
	local s = api.settlements({x = 1000, y = 0, z = 0}, 10)[1]
	eq(s.id, "auto:1:0", "id from the record cell")
	eq(s.site_id, "2:1:0:0:medieval:41:1000:0", "site id kept as information")
	eq(s.state, "complete", "state")
	eq(s.town_type, "medieval", "town type")
	eq(s.center.x, 1000, "center")
	eq(s.reservation.min.x, 900, "reservation min")
	eq(s.reservation.max.y, 100, "reservation max")
	eq(s.core.x1, 970, "core")
	eq(#s.structures, 1, "structures")
	eq(#s.exits, 2, "exits")
	eq(s.exits[1].id, "+x:1031:0", "exits sorted by id (+ before -)")
	eq(s.exits[2].id, "-x:969:9", "second exit id")
	eq(s.exits[1].length, 4, "exit length")
	eq(#s.exits[1].profile, 4, "exit profile")
	-- Results are copies.
	s.exits[1].profile[1].name = "changed"
	s.core.x1 = -1
	local again = api.settlement("auto:1:0")
	eq(again.exits[1].profile[1].name, "mcl_core:cobble", "returned shape is a copy (profile)")
	eq(again.core.x1, 970, "returned shape is a copy (core)")
end

-- Ordering: distance, then id. Two towns equidistant.
do
	local r2 = new_registry()
	local a = api_mod.new({registry = function() return r2 end, lock = lock})
	complete(r2, 5, 0, 300, 0)
	complete(r2, 0, 5, 0, 300)
	complete(r2, 3, 3, -300, 0)
	local out = a.settlements({x = 0, z = 0}, 400)
	eq(out[1].id .. "," .. out[2].id .. "," .. out[3].id, "auto:0:5,auto:3:3,auto:5:0",
		"equal distances order by id, no matter the insertion order")
end

-- Cap at 32.
do
	local r3 = new_registry()
	local a = api_mod.new({registry = function() return r3 end, lock = lock})
	for i = 0, 6 do for j = 0, 6 do complete(r3, i, j, (i - 3) * 210, (j - 3) * 210) end end
	local out = a.settlements({x = 0, z = 0}, 1024)
	eq(#out, 32, "results capped at 32")
	eq(out[1].id, "auto:3:3", "nearest kept")
	for n = 2, #out do eq(out[n - 1].center.x ^ 2 + out[n - 1].center.z ^ 2 <= out[n].center.x ^ 2 + out[n].center.z ^ 2, true, "cap keeps distance order") end
end
do
	local r3 = new_registry()
	local a = api_mod.new({registry = function() return r3 end, lock = lock})
	for i = 0, 39 do assert(r3:begin(record(i, 0, i * 250, 0))) end
	eq(#a.settlements({x = 0, z = 0}, 1024), 0, "building towns are never listed")
end

-- Invalid input.
for _, case in ipairs({
	{{x = 0, z = 0}, 2000, "invalid_radius"}, {{x = 0, z = 0}, -1, "invalid_radius"},
	{{x = 0, z = 0}, "x", "invalid_radius"}, {{x = 0, z = 0}, 0 / 0, "invalid_radius"},
	{nil, 10, "invalid_position"}, {{x = 0}, 10, "invalid_position"},
	{{x = math.huge, z = 0}, 10, "invalid_position"}, {"pos", 10, "invalid_position"}}) do
	local out, why, code = api.settlements(case[1], case[2])
	eq(out, nil, "invalid settlements input rejected: " .. case[3])
	eq(code, case[3], "invalid settlements code: " .. case[3])
	eq(type(why), "string", "reason given")
end

-- settlement(id) statuses.
do
	eq(api.settlement("auto:1:0").id, "auto:1:0", "published settlement found")
	local s, status = api.settlement("auto:9:9")
	eq(s, nil, "unknown settlement")
	eq(status, "not_found", "not_found status")
	s, status = api.settlement("auto:3:0")
	eq(status, "incomplete", "building settlement is incomplete")
	s, status = api.settlement("auto:4:0")
	eq(status, "incomplete", "interrupted settlement is incomplete")
	s, status = api.settlement("auto:2:0")
	eq(s, nil, "complete settlement without published data is not returned")
	eq(status, "unsupported", "unsupported status")
	for _, bad in ipairs({"", "auto:1", "auto:1:0:0", "auto:01:0", "auto:a:b", 5, "1:0:0:0:medieval:1:2:3"}) do
		s, status = api.settlement(bad)
		eq(status, "not_found", "malformed id is not_found: " .. tostring(bad))
	end
	s, status = api.settlement(nil)
	eq(status, "not_found", "nil id is not_found")
end

-- Malformed stored published data: reported invalid, registry still enabled.
do
	local r4, store4 = new_registry()
	complete(r4, 1, 0, 1000, 0)
	local serialize, deserialize = serializers()
	local decoded = deserialize(store4["towns.auto_records.v1"])
	decoded["1:0"].published.core = {x1 = "bad"}
	store4["towns.auto_records.v1"] = serialize(decoded)
	local reloaded = new_registry(store4)
	local a = api_mod.new({registry = function() return reloaded end, lock = lock})
	eq(a.available(), true, "malformed published data keeps the registry available")
	local s, status = a.settlement("auto:1:0")
	eq(s, nil, "invalid settlement not returned")
	eq(status, "invalid", "invalid status")
	eq(#a.settlements({x = 1000, z = 0}, 100), 0, "invalid settlement not listed")
	local items = a.exclusions({x1 = 950, z1 = -10, x2 = 1050, z2 = 10})
	eq(#items, 1, "invalid settlement is still an exclusion")
	eq(items[1].rects[1].x1, 900, "invalid settlement excludes its whole reservation")
end

-- Exclusions.
do
	local items = api.exclusions({x1 = 950, z1 = -10, x2 = 1050, z2 = 10})
	eq(#items, 1, "complete settlement overlapping its core")
	eq(items[1].id, "auto:1:0", "settlement id")
	eq(items[1].kind, "settlement", "settlement kind")
	eq(items[1].state, "complete", "complete state")
	eq(#items[1].rects, 2, "core plus one structure")
	eq(items[1].rects[1].x1, 970, "core first")
	eq(items[1].y_min, -20, "vertical bounds")
	-- Reserved land outside core and structures is not an exclusion (PM decision Q1).
	eq(#api.exclusions({x1 = 905, z1 = 80, x2 = 920, z2 = 95}), 0, "belt outside core/structures is not excluded")
	-- Structure rect alone triggers.
	eq(#api.exclusions({x1 = 1065, z1 = 5, x2 = 1068, z2 = 6}), 1, "structure rect triggers the exclusion")
	-- Building and interrupted: whole reservation.
	local b = api.exclusions({x1 = 2910, z1 = 90, x2 = 2920, z2 = 95})
	eq(#b, 1, "building reservation overlaps")
	eq(b[1].state, "building", "building state")
	eq(b[1].kind, "settlement", "building kind is settlement")
	eq(#b[1].rects, 1, "whole envelope")
	local i = api.exclusions({x1 = 3910, z1 = 90, x2 = 3920, z2 = 95})
	eq(i[1].state, "interrupted", "interrupted state")
	-- Complete without published data: whole reservation.
	local u = api.exclusions({x1 = 1910, z1 = 90, x2 = 1920, z2 = 95})
	eq(#u, 1, "unsupported complete settlement excludes its reservation")
	eq(u[1].rects[1].x1, 1900, "unsupported envelope")
	-- Candidates.
	live_list[1] = {id = "2:7:7:0:medieval:41:200:200", state = "inspecting",
		max_rect = {x1 = 100, z1 = 100, x2 = 300, z2 = 300}}
	live_list[2] = {id = "2:7:7:1:medieval:41:250:250", state = "contacted",
		max_rect = {x1 = 150, z1 = 150, x2 = 350, z2 = 350}}
	local c = api.exclusions({x1 = 200, z1 = 200, x2 = 210, z2 = 210})
	eq(#c, 2, "contacted and inspecting candidates are exclusions")
	eq(c[1].kind, "candidate", "candidate kind")
	eq(c[1].id < c[2].id, true, "sorted by id within kind")
	eq(c[1].state, "inspecting", "candidate state")
	eq(c[1].y_min < -30000 and c[1].y_max > 30000, true, "candidates are unbounded vertically")
	-- Kind ordering: candidates before settlements.
	local mixed = api.exclusions({x1 = 0, z1 = 0, x2 = 1100, z2 = 300})
	eq(mixed[1].kind, "candidate", "candidate sorts first")
	eq(mixed[#mixed].kind, "settlement", "settlement sorts last")
	live_list = {}
	-- No automatic session: only settlements.
	live_list[1] = {id = "x", state = "contacted", max_rect = {x1 = 0, z1 = 0, x2 = 10, z2 = 10}}
	have_session = false
	eq(#api.exclusions({x1 = 0, z1 = 0, x2 = 10, z2 = 10}), 0, "nil auto_session means no candidate exclusions")
	have_session = true
	live_list = {}
	-- Returned items are copies.
	items = api.exclusions({x1 = 950, z1 = -10, x2 = 1050, z2 = 10})
	items[1].rects[1].x1 = -999
	eq(api.exclusions({x1 = 950, z1 = -10, x2 = 1050, z2 = 10})[1].rects[1].x1, 970, "exclusions are copies")
	-- Invalid rects and caps.
	for _, bad in ipairs({{}, {x1 = 5, z1 = 0, x2 = 1, z2 = 1}, {x1 = 0, z1 = 0, x2 = 2048, z2 = 1},
		{x1 = 0, z1 = 0, x2 = 1.5, z2 = 1}, "rect"}) do
		local out, _, code = api.exclusions(bad)
		eq(out, nil, "invalid exclusion rect rejected")
		eq(code, "invalid_rect", "invalid rect code")
	end
	eq(api.exclusions({x1 = 0, z1 = 0, x2 = 2047, z2 = 2047}) ~= nil, true, "a 2048 wide rect is accepted")
	for n = 1, 300 do
		live_list[n] = {id = ("c%03d"):format(n), state = "contacted", max_rect = {x1 = 0, z1 = 0, x2 = 10, z2 = 10}}
	end
	local out, _, code = api.exclusions({x1 = 0, z1 = 0, x2 = 10, z2 = 10})
	eq(out, nil, "too many exclusions")
	eq(code, "too_many", "too_many code")
	live_list = {}
end

-- writer() follows the generation lock.
do
	eq(api.writer(), nil, "idle lock: no writer")
	local manual = lock.acquire("someplayer", "search", 5)
	local w = api.writer()
	eq(w.kind, "manual", "player-owned lock is manual")
	eq(w.phase, "search", "phase reported")
	eq(w.since, 5, "start time reported")
	lock.set_phase(manual, "build")
	eq(api.writer().phase, "build", "phase follows the lock")
	w.phase = "changed"
	eq(api.writer().phase, "build", "writer result is a copy")
	lock.release(manual)
	eq(api.writer(), nil, "released lock: no writer")
	local auto = lock.acquire("2:1:0:3:medieval:41:1000:0", "loading", 9)
	eq(api.writer().kind, "automatic", "site-id owner is automatic")
	lock.release(auto)
	auto = lock.acquire("2:-1:-2:3:roman:41:-1000:-2000", "build", 9)
	eq(api.writer().kind, "automatic", "negative cell id is automatic")
	lock.release(auto)
	eq(api.writer(), nil, "idle again")
end

-- Disabled registry: unavailable, never an empty answer.
do
	local bad = records_mod.new({store = {get = function() return "broken" end, set = function() end},
		serialize = function() return "" end, deserialize = function() error("bad") end})
	local a = api_mod.new({registry = function() return bad end, lock = lock})
	local ok, why = a.available()
	eq(ok, false, "disabled registry is not available")
	eq(type(why), "string", "unavailable reason")
	local _, _, code = a.settlements({x = 0, z = 0}, 10)
	eq(code, "unavailable", "settlements unavailable")
	_, _, code = a.exclusions({x1 = 0, z1 = 0, x2 = 1, z2 = 1})
	eq(code, "unavailable", "exclusions unavailable")
	local _, status = a.settlement("auto:1:1")
	eq(status, "unavailable", "settlement unavailable")
	eq(a.writer(), nil, "writer still answers")
	local none = api_mod.new({registry = function() return nil end, lock = lock})
	eq((none.available()), false, "no registry is not available")
end
