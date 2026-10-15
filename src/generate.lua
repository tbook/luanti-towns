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
--   generate.parse_args(param)         -> {seed = n|nil} | nil, message
--   generate.random_seed(entropy, rng) -> integer seed in 1..SEED_LIMIT
--   generate.format_report(summary)    -> {lines}   (success)
--   generate.format_search_failure(message) -> string
--   generate.format_build_failure(message, code, result) -> string
--   generate.HELP                      -> help/description text
--   local c = generate.new(deps)       -> controller, c.run(name, param)
--
-- Concurrency: ONE search/build at a time per server (searches emerge a lot
-- of map and the builder is synchronous). A second command while one is in
-- progress is refused with a message naming the player who started it. A
-- start older than STALE_SECONDS is considered abandoned and replaced.
--
-- deps (all required unless noted):
--   get_player_pos(name) -> {x,y,z} | nil   nil when the player is not online
--   search(pos, seed, opts, done)           site_search.search; done(result,
--                                           nil, details) / done(nil, msg, details)
--   build(result) -> summary | nil, message, code[, {bounds, planned}]   builder.build
--   send(name, msg)    chat to the player; must tolerate an offline player
--   log(level, msg)
--   entropy() -> number                     clock/world derived (random_seed)
--   rng(lo, hi) -> integer   optional; injectable RNG for random_seed
--   now() -> seconds         optional, for the stale-search guard
--   command_name             optional text such as "/towns_place_town", shown
--                            in the success report (default /towns_generate)

return function(planner)

local M = {}

local LIMIT = planner.SEED_LIMIT
M.SEED_LIMIT = LIMIT
M.STALE_SECONDS = 600

M.USAGE = "Usage: /towns_generate [seed], where seed is an integer from -"
	.. LIMIT .. " to " .. LIMIT .. "."

M.HELP = "WARNING: builds a town on the chosen site immediately, OVERWRITING it "
	.. "with no preview and no confirmation; for disposable Creative worlds "
	.. "only. Searches near you (you must stand on solid ground) for a site "
	.. "with no water, a middle 95% height range of at most 16 nodes, and "
	.. "at most 24 nodes of cut/fill per column. Searches within 320 nodes and "
	.. "inspects heights within 48 nodes above/below your ground level, flattens "
	.. "it and builds the "
	.. "town at once. The seed is an integer from -" .. LIMIT .. " to " .. LIMIT
	.. "; when omitted one is generated and printed. The same seed at the "
	.. "same centre reproduces the layout. Requires the 'server' privilege. "
	.. "Usage: /towns_generate [seed]"

-- Parses the command parameter. Returns {seed = integer or nil} or nil plus
-- a message. Rejects non-integers (1.5, 1e3, 0x10, words), more than one
-- argument, and seeds outside planner.check_seed's range (never folded).
function M.parse_args(param)
	local s = tostring(param or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if s == "" then return {} end
	local tokens = {}
	for t in s:gmatch("%S+") do tokens[#tokens + 1] = t end
	if #tokens > 1 then
		return nil, "Too many arguments (" .. #tokens .. "). " .. M.USAGE
	end
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
	return {seed = n}
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

-- Success report: array of lines (also logged). `summary` is the builder's.
-- `command` (optional) is the chat command name shown for repeating the
-- seed; the town placement entry point (ticket #45) passes its own.
function M.format_report(summary, command)
	local s = summary
	command = command or "/towns_generate"
	local g = s.ground_y
	local lines = {}
	local function add(fmt, ...) lines[#lines + 1] = fmt:format(...) end
	add("Town built. Seed %d (repeat it with %s %d from the same place).",
		s.seed, command, s.seed)
	add("Centre (%d,%d), ground level y=%d.", s.center.x, s.center.z, g)
	add("Site bounds %s.", bounds_str(s.bounds))
	if type(s.write_bounds) == "table" then
		add("Modified area %s.", bounds_str(s.write_bounds))
	else
		add("Modified area %s.", bounds_str(s.bounds))
	end
	local function landmark(label, key, door)
		local site = s.sites[key]
		if not site then return end
		local e = site.entrance
		add("%s: %s; %s at (%d,%d,%d) facing %s.", label, rect_str(site.rect), door,
			e.x, site.entrance_y or (g + 1), e.z, SIDE_NAME[site.side] or tostring(site.side))
	end
	local function square(label, key)
		local site = s.sites[key]
		if site then add("%s: %s.", label, rect_str(site.rect)) end
	end
	landmark("Cathedral", "cathedral", "entrance")
	square("Parvis", "parvis")
	square("Market", "market")
	landmark("Castle", "castle", "gate")
	for _, a in ipairs(s.approaches or {}) do
		add("Boundary approach %s: (%d,%d) on side %s.", tostring(a.name), a.pos.x, a.pos.z,
			SIDE_NAME[a.side] or tostring(a.side))
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
	if s.town then
		add("Placed %d buildings (%d alleys paved); all %d door approach routes are walkable.",
			s.town.placed, s.town.alleys, #s.town.doors)
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
-- written anything and is reported as possibly partial, with the bounds.
function M.format_build_failure(message, code, result, extra)
	local m = tostring(message)
	if code == "write_failed" then
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
			if now() - active.started > M.STALE_SECONDS then
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

		local mine = {name = name, seed = seed, started = now()}
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

		local function on_done(result, message)
			local replaced = active ~= mine
			release()
			if replaced then
				-- A stale takeover started a newer search; never build for this one.
				return finish(false, {"A newer /towns_generate replaced this search; "
					.. "nothing was changed."})
			end
			if not result then
				return finish(false, {M.format_search_failure(message)})
			end
			local ok, summary, bmsg, code, extra = pcall(deps.build, result)
			if not ok then
				return finish(false, {M.format_build_failure(summary, "write_failed", result)})
			end
			if not summary then
				return finish(false, {M.format_build_failure(bmsg, code, result, extra)})
			end
			if type(summary.write_bounds) == "table" then
				deps.log("action", "towns_generate (" .. name .. "): write bounds "
					.. bounds_str(summary.write_bounds))
			end
			return finish(true, M.format_report(summary, deps.command_name))
		end

		deps.log("action", ("towns_generate (%s): seed %d%s, searching near (%.1f,%.1f,%.1f)"):format(
			name, seed, generated and " (generated)" or "", pos.x, pos.y, pos.z))
		local searched, serr = pcall(deps.search, pos, seed, nil, on_done)
		if not searched then
			release()
			returning = false
			return false, "Town not built: " .. tostring(serr) .. ". Nothing was changed."
		end
		returning = false
		if sync_msg then
			return sync_ok, sync_msg
		end
		return true, ("Searching for a town site near you with seed %d%s. This can take a "
			.. "while; you will be told when it is done. It builds immediately on the "
			.. "first suitable site, OVERWRITING it with no preview or confirmation."):format(
			seed, generated and " (generated)" or "")
	end

	return C
end

return M

end
