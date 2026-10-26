-- Towns: /towns_generate logic (ticket #16). Pure Lua 5.1: argument parsing,
-- seed generation, message formatting and the command controller. Every
-- core.* dependency is injected (see M.new), so tests/generate_tests.lua
-- drives the whole command with fakes; src/generate_command.lua is the thin
-- layer that registers the chat command and supplies the real dependencies.
--
-- WARNING (also in the help text and README): the command overwrites the
-- chosen site immediately, with no preview and no confirmation. Disposable
-- Creative worlds only.
--
--   local generate = dofile(".../generate.lua")(planner)
--   generate.parse_args(param)         -> {town_type, seed = n|nil} | nil, message
--   generate.random_seed(entropy, rng) -> integer seed in 1..SEED_LIMIT
--   generate.format_report(summary, command) -> {lines}   (success)
--   generate.format_search_failure(message) -> string
--   generate.format_build_failure(message, code, result) -> string
--   generate.HELP                      -> help/description text
--   local c = generate.new(deps)       -> controller, c.run(name, param)
--
-- Concurrency: ONE search/build at a time per server. A second command while
-- one is in progress is refused with a message naming its owner. Only an old
-- search can be replaced as abandoned; an active build keeps the lock until
-- its callback completes.
--
-- deps (all required unless noted):
--   get_player_pos(name) -> {x,y,z} | nil   nil when the player is not online
--   search(pos, seed, town_type, done)      "medieval" | "roman"; done(result,
--                                           nil, details) / done(nil, msg, details)
--   build(result, done)                    done(summary, message, code, extra)
--   send(name, msg)    chat to the player; must tolerate an offline player
--   log(level, msg)
--   entropy() -> number                     clock/world derived (random_seed)
--   rng(lo, hi) -> integer   optional; injectable RNG for random_seed
--   now() -> seconds         optional, for the stale-search guard
--   command_name             optional text such as "/towns_generate", shown
--                            in the success report (default /towns_generate)

return function(planner)

local M = {}

local LIMIT = planner.SEED_LIMIT
M.SEED_LIMIT = LIMIT
M.STALE_SECONDS = 600

M.USAGE = "Usage: /towns_generate [medieval|roman] [seed], where seed is an integer from -"
	.. LIMIT .. " to " .. LIMIT .. "."

-- Town types selectable with the leading argument; medieval is the default.
M.TOWN_TYPES = {medieval = true, roman = true}

M.HELP = "WARNING: builds a town on the chosen site immediately, OVERWRITING it "
	.. "with no preview and no confirmation; for disposable Creative worlds "
	.. "only. Builds a populated medieval town (the default), or a Roman town "
	.. "with 'roman': the medieval town has cathedral, castle, city hall, jail, "
	.. "services and houses/shops/workshops from the catalog; the Roman town "
	.. "(first version) has the forum, four arches, temple, amphitheatre, "
	.. "theatre, bath, domus and basilica monuments on authored streets, with blocks and "
	.. "frontage, and the catalog's ordinary content where it fits (no "
	.. "cathedral, castle or city hall). Both get initialized nodes and one "
	.. "Living Villages resident per valid bed. "
	.. "Searches near you (you must stand on solid ground) for a site "
	.. "with no lava or deep water (shallow water and ice up to 6 nodes deep "
	.. "is landfilled, over at most 25% of the footprint), a middle 95% "
	.. "height range of at most 16 nodes, and "
	.. "at most 24 nodes of cut/fill per column. Searches within 320 nodes and "
	.. "inspects heights within 48 nodes above/below your ground level, flattens "
	.. "it and builds the "
	.. "town at once. The seed is an integer from -" .. LIMIT .. " to " .. LIMIT
	.. "; when omitted one is generated and printed. The same seed at the "
	.. "same centre reproduces the layout. Requires the 'server' privilege. "
	.. "Usage: /towns_generate [medieval|roman] [seed]"

-- Parses the command parameter: an optional leading town type (medieval or
-- roman, case-insensitive; medieval when omitted), then an optional seed.
-- Returns {town_type, seed = integer or nil} or nil plus a message. Rejects
-- unknown types, non-integers (1.5, 1e3, 0x10, words), more than the allowed
-- arguments, and seeds outside planner.check_seed's range (never folded).
function M.parse_args(param)
	local s = tostring(param or ""):gsub("^%s+", ""):gsub("%s+$", "")
	local tokens = {}
	for t in s:gmatch("%S+") do tokens[#tokens + 1] = t end
	local count = #tokens -- legacy count, including a leading type word
	local town_type = "medieval"
	if count > 0 and M.TOWN_TYPES[tokens[1]:lower()] then
		town_type = tokens[1]:lower()
		table.remove(tokens, 1)
	end
	if #tokens > 1 then
		return nil, "Too many arguments (" .. count .. "). " .. M.USAGE
	end
	if #tokens == 0 then return {town_type = town_type} end
	local tok = tokens[1]
	if not tok:match("^[+-]?%d+$") then
		return nil, "Invalid seed '" .. tok .. "': it must be an integer. " .. M.USAGE
	end
	local n = tonumber(tok)
	if not n then
		return nil, "Invalid seed '" .. tok .. "'. " .. M.USAGE
	end
	n = n + 0 -- turns -0 into 0
	local ok, msg = planner.check_seed(n)
	if not ok then
		return nil, "Invalid seed '" .. tok .. "': " .. msg .. ". " .. M.USAGE
	end
	return {town_type = town_type, seed = n}
end

-- A generated seed in 1..SEED_LIMIT. `entropy` is any number (clock/world
-- derived by the caller); `rng(lo, hi)` is optional and, when given, decides
-- the value (tests inject it). Pure and deterministic.
function M.random_seed(entropy, rng)
	if rng then
		local v = rng(1, LIMIT)
		if type(v) ~= "number" or v ~= math.floor(v) or v < 1 or v > LIMIT then
			error("towns generate: rng returned " .. tostring(v) .. ", expected an integer in 1.."
				.. LIMIT)
		end
		return v
	end
	local e = tonumber(entropy) or 0
	if e ~= e or e == math.huge or e == -math.huge then e = 0 end
	local s = math.floor(math.abs(e)) % 2147483648
	-- A few LCG rounds (all intermediates < 2^53) so near entropies differ.
	for _ = 1, 6 do
		s = (s * 48271 + 1013904223) % 2147483648
	end
	return s % LIMIT + 1
end

local function rect_str(r)
	return ("x %d..%d, z %d..%d"):format(r.x1, r.x2, r.z1, r.z2)
end

local function bounds_str(b)
	return ("(%d,%d,%d) to (%d,%d,%d)"):format(b.min.x, b.min.y, b.min.z,
		b.max.x, b.max.y, b.max.z)
end

local SIDE_NAME = {["-x"] = "-x (west)", ["+x"] = "+x (east)",
	["-z"] = "-z (south)", ["+z"] = "+z (north)"}

-- Post-write stages that did not complete cleanly (the town itself is
-- placed). Returns a list of short strings; empty means a clean build.
function M.report_problems(summary)
	local out = {}
	local t = type(summary) == "table" and summary.town
	if not t then return out end
	if t.beds_error then out[#out + 1] = "bed enumeration failed" end
	if t.residents_error then out[#out + 1] = "resident initialization failed" end
	local r = t.residents
	if type(r) == "table" then
		if (tonumber(r.failed) or 0) > 0 then
			out[#out + 1] = ("%d resident(s) not spawned"):format(r.failed)
		end
		if (tonumber(r.interrupted) or 0) > 0 then
			out[#out + 1] = ("%d resident initialization(s) interrupted"):format(r.interrupted)
		end
	end
	return out
end

-- Success report: array of lines (also logged). `summary` is the builder's.
-- `command` (optional) is the chat command name shown for repeating the
-- seed; the town placement entry point (ticket #45) passes its own.
-- `summary.town_type` (set by the controller; medieval when absent) selects
-- the title, the named sites listed and the repeat instruction, which names
-- the type unless it is the default.
function M.format_report(summary, command)
	local s = summary
	local town = s.town_type or "medieval"
	command = command or "/towns_generate"
	if town ~= "medieval" then command = command .. " " .. town end
	local title = town == "roman" and "Roman town" or "Town"
	local g = s.ground_y
	local lines = {}
	local function add(fmt, ...) lines[#lines + 1] = fmt:format(...) end
	local problems = M.report_problems(s)
	if #problems > 0 then
		add("%s built but INCOMPLETE (%s); the town itself is placed and the "
			.. "world was modified. Seed %d (repeat it with %s %d from the same place).",
			title, table.concat(problems, "; "), s.seed, command, s.seed)
	else
		add("%s built. Seed %d (repeat it with %s %d from the same place).",
			title, s.seed, command, s.seed)
	end
	add("Centre (%d,%d), ground level y=%d.", s.center.x, s.center.z, g)
	add("Site bounds %s.", bounds_str(s.bounds))
	if type(s.write_bounds) == "table" then
		add("Modified area %s.", bounds_str(s.write_bounds))
	else
		add("Modified area %s.", bounds_str(s.bounds))
	end
	local function landmark(label, key, door, facing)
		local site = s.sites[key]
		if not site then return end
		local e = site.entrance
		local where = ("%s at (%d,%d,%d)"):format(door, e.x, site.entrance_y or (g + 1), e.z)
		if facing then
			where = where .. " facing " .. SIDE_NAME[site.facing.x > 0 and "+x" or site.facing.x < 0 and "-x" or site.facing.z > 0 and "+z" or "-z"]
		end
		add("%s: %s; %s.", label, rect_str(site.rect), where)
	end
	local function square(label, key)
		local site = s.sites[key]
		if site then add("%s: %s.", label, rect_str(site.rect)) end
	end
	if town == "roman" then
		-- The authored sites this plan actually has, by name (sorted). A site
		-- with an entrance is a monument; one without is a square. Facing is
		-- not listed: authored sides are not entrance directions.
		local names = {}
		for name in pairs(s.sites) do names[#names + 1] = name end
		table.sort(names)
		for _, name in ipairs(names) do
			local label = name:gsub("_", " "):gsub("^%l", string.upper)
			if s.sites[name].entrance then
				landmark(label, name, "entrance", false)
			else
				square(label, name)
			end
		end
	else
		landmark("Cathedral", "cathedral", "entrance", true)
		square("Parvis", "parvis")
		square("Market", "market")
		landmark("Castle", "castle", "gate", true)
	end
	local c = s.counts
	add("Streets %d (%d principal, %d secondary), blocks %d, frontage runs %d.",
		c.streets, c.principal, c.secondary, c.blocks, c.frontage)
	if s.nodes then add("%d nodes changed.", s.nodes.changed) end
	local lq = s.liquids
	if type(lq) == "table" and (lq.buried > 0 or lq.sealed > 0) then
		add("Replaced %d buried liquid/ice nodes; sealed %d open cells beside outside water.",
			lq.buried, lq.sealed)
	end
	local site = s.site
	if type(site) == "table" then
		if site.wet and site.wet.count > 0 then
			add("Landfilled %d water/ice columns (deepest %d nodes) up to ground level y=%d.",
				site.wet.count, site.wet.max_depth, g)
		end
		if type(site.rejections) == "table" and next(site.rejections) then
			local codes = {}
			for code, n in pairs(site.rejections) do codes[#codes + 1] = code .. " x" .. n end
			table.sort(codes)
			add("Skipped %d candidate sites on the way: %s.", site.candidates_tried and
				(site.candidates_tried - 1) or 0, table.concat(codes, ", "))
		end
	end
	local outskirts = s.outskirts
	if type(outskirts) == "table" then
		local labels = {farm = "farms", hut = "huts", villa = "villas", chapel = "chapels"}
		local counts = outskirts.counts or {}
		local requested = counts.requested or {}
		local actual = {}
		for _, b in ipairs(outskirts.structures or {}) do
			local class = b.role
			if labels[class] then actual[class] = (actual[class] or 0) + 1 end
		end
		local parts = {}
		for _, class in ipairs({"farm", "hut", "villa", "chapel"}) do
			local want = tonumber(requested[class])
			if want then
				parts[#parts + 1] = ("%s %d/%d"):format(labels[class], actual[class] or 0, want)
			end
		end
		if #parts > 0 then add("Outskirts placed: %s.", table.concat(parts, ", ")) end
		local rejected = counts.rejected
		if type(rejected) == "table" and next(rejected) then
			local codes = {}
			for code, n in pairs(rejected) do codes[#codes + 1] = code .. " x" .. n end
			table.sort(codes)
			add("Outskirts candidate rejections: %s.", table.concat(codes, ", "))
		end
		local skipped = outskirts.skipped or {}
		for _, item in ipairs(skipped) do
			if item.code and item.reason then
				add("Outskirts skipped %s: %s (%s).", tostring(item.plot), tostring(item.code), tostring(item.reason))
			else
				add("Outskirts skipped %s: %s.", tostring(item.plot), tostring(item.code or item.reason))
			end
		end
		for _, item in ipairs(outskirts.warnings or {}) do
			add("Outskirts warning %s: %s (%s).", tostring(item.plot), tostring(item.code), tostring(item.reason))
		end
		local totals, has_stats = {}, false
		for _, item in ipairs(outskirts.terraform or {}) do
			local stats = item.stats
			if type(stats) == "table" then
				for _, key in ipairs({"changed", "cut", "filled", "steepest", "steps_over_one",
						"walls", "wall_max", "unloaded_blocks"}) do
					local value = tonumber(stats[key])
					if value then
						has_stats = true
						if key == "steepest" or key == "wall_max" then
							totals[key] = math.max(totals[key] or value, value)
						else
							totals[key] = (totals[key] or 0) + value
						end
					end
				end
			end
		end
		if has_stats then
			add("Outskirts terraform: %d changed columns (%d cut, %d filled), steepest %d, %d steps over one, walls %d (max %d), %d unloaded blocks.",
				totals.changed or 0, totals.cut or 0, totals.filled or 0,
				totals.steepest or 0, totals.steps_over_one or 0, totals.walls or 0,
				totals.wall_max or 0, totals.unloaded_blocks or 0)
		end
	end
	if s.town then
		local kinds, ids, idorder = {}, {}, {}
		local structures = s.town.structures or {}
		local urban_structure_count = s.town.urban_structure_count or #structures
		for index, b in ipairs(structures) do
			if index > urban_structure_count then break end
			kinds[b.kind] = (kinds[b.kind] or 0) + 1
			if not ids[b.id] then ids[b.id] = 0; idorder[#idorder + 1] = b.id end
			ids[b.id] = ids[b.id] + 1
			if b.kind == "city_hall" then
				add("City hall: %s; door at (%d,%d,%d).", rect_str(b.rect),
					b.entrance.x, b.entrance.y, b.entrance.z)
			end
		end
		local urban_placed = s.town.urban_placed or s.town.placed
		add("Placed %d buildings; all %d door approach routes are walkable.",
			urban_placed - (kinds.object or 0), #s.town.doors)
		if kinds.object then add("Outdoor objects: %d trees and gardens.", kinds.object) end
		if s.town.structures then
			-- Separate outdoor objects from all building categories; named
			-- landmarks include the Roman monuments.
			add("Buildings: %d landmarks/city hall/jail, %d services, %d houses/shops/workshops.",
				urban_structure_count - (kinds.service or 0) - (kinds.content or 0) - (kinds.object or 0),
				kinds.service or 0, kinds.content or 0)
			table.sort(idorder)
			local parts = {}
			for _, id in ipairs(idorder) do parts[#parts + 1] = id .. " x" .. ids[id] end
			add("Catalog ids: %s.", table.concat(parts, ", "))
		end
		for _, sh in ipairs(s.town.shortages or {}) do
			add("Unmet target: %s wanted %s, placed %s (%s).", tostring(sh.role),
				tostring(sh.wanted), tostring(sh.placed), tostring(sh.reason))
		end
		local st = s.town.setup
		if st then
			add("Node setup: %d functional nodes initialized (%d placements, %d unhandled).",
				st.initialized, st.placements, #st.unhandled)
			for _, u in ipairs(st.unhandled) do
				add("Unhandled initialization: %s (%s) in %s.", u.name, u.reason,
					table.concat(u.structures, ", "))
			end
		end
		local beds = s.town.beds
		if beds then
			add("Beds: %d valid, %d skipped.", beds.count, #beds.skipped)
			local by, order = {}, {}
			for _, k in ipairs(beds.skipped) do
				local key = k.category .. ", " .. k.reason
				if not by[key] then by[key] = 0; order[#order + 1] = key end
				by[key] = by[key] + 1
			end
			table.sort(order)
			for _, key in ipairs(order) do add("Skipped beds (%s): %d.", key, by[key]) end
		elseif s.town.beds_error then
			add("Bed enumeration failed: %s.", s.town.beds_error)
		end
		local res = s.town.residents
		if res then
			add("%s", res.summary)
		elseif s.town.residents_error then
			add("Resident initialization failed: %s.", s.town.residents_error)
		end
	end
	return lines
end

function M.format_search_failure(message)
	local m = tostring(message)
	if not m:find("Nothing was changed", 1, true) then
		m = m .. " Nothing was changed."
	end
	return "Town not built: " .. m
end

-- Builder failure: `code` is the builder's. Only write_failed may have
-- written anything (terrain, schematic placement, node initialization) and is
-- reported as possibly partial, with the bounds; the other codes, including a
-- failed preflight, happen before the first write ("Nothing was changed").
-- Residents are initialized after the build; their failure is a report
-- problem (report_problems), not a build failure.
function M.format_build_failure(message, code, result, extra)
	local m = tostring(message)
	if code == "write_failed" then
		if type(extra) == "table" then
			local d = {}
			if extra.reason then d[#d + 1] = "stage " .. tostring(extra.reason) end
			if type(extra.urban_bounds) == "table" then
				d[#d + 1] = "urban bounds " .. bounds_str(extra.urban_bounds)
			end
			if type(extra.terrain_attempts) == "table" and #extra.terrain_attempts > 0 then
				d[#d + 1] = tostring(#extra.terrain_attempts) .. " outskirts terrain attempts"
			end
			if type(extra.placement_attempts) == "table" and #extra.placement_attempts > 0 then
				d[#d + 1] = tostring(#extra.placement_attempts) .. " outskirts placement attempts"
			end
			if type(extra.building) == "table" then
				d[#d + 1] = "building " .. tostring(extra.building.id)
			end
			if extra.placed and extra.total then
				d[#d + 1] = ("%s of %s buildings placed"):format(
					tostring(extra.placed), tostring(extra.total))
			end
			if #d > 0 then m = m .. " (" .. table.concat(d, ", ") .. ")" end
		end
		local where = ""
		if type(extra) == "table" and type(extra.bounds) == "table" then
			return "Town construction FAILED while writing (write_failed): " .. m
				.. ". The site may be PARTIALLY written within "
				.. bounds_str(extra.bounds) .. "; nothing outside it was touched."
		end
		if type(result) == "table" and type(result.write_bounds) == "table" then
			where = bounds_str(result.write_bounds)
			return "Town construction FAILED while writing (write_failed): " .. m
				.. ". The site may be PARTIALLY written within " .. where .. "."
		end
		if type(result) == "table" and type(result.build_bounds) == "table" then
			where = " Site bounds " .. bounds_str(result.build_bounds)
				.. "; the written region may extend a few nodes below them."
		end
		return "Town construction FAILED while writing (write_failed): " .. m
			.. ". The site may be PARTIALLY written." .. where
	end
	return "Town not built (" .. tostring(code or "error") .. "): " .. m
		.. ". Nothing was changed."
end

-- The controller. See the deps contract in the header.
function M.new(deps)
	local C = {}
	local active -- {name, seed, started}

	local function now()
		return deps.now and deps.now() or 0
	end

	function C.busy()
		return active ~= nil, active and active.name
	end

	-- Runs the command. Returns ok, message for the command return value.
	-- Later outcomes arrive through deps.send as chat messages.
	function C.run(name, param)
		local args, err = M.parse_args(param)
		if not args then return false, err end
		if active then
			if active.phase == "search" and now() - active.started > M.STALE_SECONDS then
				deps.log("warning", "towns_generate: dropping stale search started by "
					.. active.name)
				active = nil
			else
				return false, "A town search or build is already in progress (started by "
					.. active.name .. "); wait for it to finish."
			end
		end
		local pos = deps.get_player_pos(name)
		if not pos then return false, "You must be in game to use this command." end

		local seed = args.seed
		local generated = false
		if not seed then
			seed = M.random_seed(deps.entropy and deps.entropy() or 0, deps.rng)
			generated = true
		end

		local town = args.town_type
		local mine = {name = name, seed = seed, started = now(), phase = "search"}
		local returning, sync_ok, sync_msg = true
		local function finish(ok, lines)
			deps.log(ok and "action" or "warning", "towns_generate (" .. name .. "): "
				.. table.concat(lines, " | "))
			if returning then
				sync_ok, sync_msg = ok, table.concat(lines, "\n")
			else
				for _, l in ipairs(lines) do
					local sent, serr = pcall(deps.send, name, (ok and "" or "Error: ") .. l)
					if not sent then
						deps.log("warning", "towns_generate (" .. name .. "): could not send chat: "
							.. tostring(serr))
						break
					end
				end
			end
		end

		active = mine
		local function release()
			if active == mine then active = nil end
		end

		local search_done = false
		local function on_done(result, message)
			if search_done then return end
			search_done = true
			local replaced = active ~= mine
			if replaced then
				-- A stale takeover started a newer search; never build for this one.
				return finish(false, {"A newer /towns_generate replaced this search; "
					.. "nothing was changed."})
			end
			if not result then
				release()
				return finish(false, {M.format_search_failure(message)})
			end
			mine.phase = "build"
			local build_done = false
			local function on_build(summary, bmsg, code, extra)
				if build_done then return end
				build_done = true
				release()
				if not summary then
					return finish(false, {M.format_build_failure(bmsg, code, result, extra)})
				end
				summary.town_type = town
				if type(summary.write_bounds) == "table" then
					deps.log("action", "towns_generate (" .. name .. "): write bounds "
						.. bounds_str(summary.write_bounds))
				end
				return finish(#M.report_problems(summary) == 0,
					M.format_report(summary, deps.command_name))
			end
			local called, build_err = pcall(deps.build, result, on_build)
			if not called and not build_done then
				on_build(nil, build_err, "write_failed")
			end
		end

		deps.log("action", ("towns_generate (%s): %s seed %d%s, searching near (%.1f,%.1f,%.1f)"):format(
			name, town, seed, generated and " (generated)" or "", pos.x, pos.y, pos.z))
		local searched, serr = pcall(deps.search, pos, seed, town, on_done)
		if not searched and not search_done then
			search_done = true
			release()
			returning = false
			return false, "Town not built: " .. tostring(serr) .. ". Nothing was changed."
		end
		returning = false
		if sync_msg then
			return sync_ok, sync_msg
		end
		return true, ("Searching for a %stown site near you with seed %d%s. This can take a "
			.. "while; you will be told when it is done. It builds immediately on the "
			.. "first suitable site, OVERWRITING it with no preview or confirmation."):format(
			town == "roman" and "Roman " or "", seed, generated and " (generated)" or "")
	end

	return C
end

return M

end
