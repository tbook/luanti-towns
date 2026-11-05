-- Shared in-memory ownership lock for manual and automatic town operations.
-- A token is the sole authority to change phase or release an operation.
--
-- Handoff for a future automatic orchestrator: call acquire(site_id,
-- "loading", now) before creating a reservation or asking auto_loader to
-- load. Omit stale_seconds so any current operation makes this site decline.
-- After acceptance and fresh coverage, call set_phase(token, "build") before
-- handing the result to the builder. At terminal completion (success, decline,
-- timeout, or error), call release(token) once. owns(token) protects callbacks
-- after invalidation. Only the command controller opts into stale SEARCH
-- replacement; BUILD is never replaceable.
return function()
	local current
	local lock = {}

	function lock.acquire(owner, phase, now, stale_seconds)
		assert(owner ~= nil, "generation_lock: owner is required")
		assert(type(phase) == "string", "generation_lock: phase is required")
		now = tonumber(now) or 0
		if current then
			local stale_search = stale_seconds ~= nil and current.phase == "search"
				and now - current.started > stale_seconds
			if not stale_search then return nil, current.owner, current.phase end
		end
		local token = {owner = owner, phase = phase, started = now}
		current = token
		return token
	end

	function lock.owns(token)
		return current == token
	end

	function lock.set_phase(token, phase)
		if current ~= token then return false end
		assert(type(phase) == "string", "generation_lock: phase is required")
		token.phase = phase
		return true
	end

	function lock.release(token)
		if current ~= token then return false end
		current = nil
		return true
	end

	function lock.current()
		if not current then return nil end
		return {owner = current.owner, phase = current.phase, started = current.started}
	end

	return lock
end
