-- Exhaustive, synchronous protection check for approved write stages.
-- The generic provider exposes no region query, so this checks every position.
local M = {}

local function integer(n)
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge and n == math.floor(n)
end

local function valid_box(b)
	if type(b) ~= "table" or type(b.min) ~= "table" or type(b.max) ~= "table" then return false end
	for _, axis in ipairs({"x", "y", "z"}) do
		if not integer(b.min[axis]) or not integer(b.max[axis]) or b.min[axis] > b.max[axis]
				or b.min[axis] < -31000 or b.max[axis] > 31000 then return false end
	end
	return true
end

-- Returns true, nil, tested_count; false, reason, tested_count, position.
-- The conservative cap bounds callback calls, including overlapping boxes.
-- A protected point or a thrown provider declines; nothing is sampled.
function M.check(stages, is_protected, max_checks)
	if type(stages) ~= "table" or type(is_protected) ~= "function" or not integer(max_checks) or max_checks <= 0 then
		return false, "invalid_options", 0
	end
	local boxes, total = {}, 0
	for _, stage in pairs(stages) do
		if type(stage) ~= "table" or (stage.kind ~= "read" and stage.kind ~= "write") or not valid_box(stage.box) then
			return false, "invalid_stage", 0
		end
		if stage.kind == "write" then
			local b = stage.box
			local volume = (b.max.x - b.min.x + 1) * (b.max.y - b.min.y + 1) * (b.max.z - b.min.z + 1)
			if volume > max_checks - total then return false, "check_cap", 0 end
			total = total + volume
			boxes[#boxes + 1] = b
		end
	end
	if #boxes == 0 then return false, "no_write_stages", 0 end
	local tested = 0
	for _, b in ipairs(boxes) do
		for z = b.min.z, b.max.z do
			for y = b.min.y, b.max.y do
				for x = b.min.x, b.max.x do
					local p = {x = x, y = y, z = z}
					local ok, protected = pcall(is_protected, p, "")
					tested = tested + 1
					if not ok then return false, "provider_error", tested, p end
					if protected ~= false then return false, protected and "protected" or "invalid_response", tested, p end
				end
			end
		end
	end
	return true, nil, tested
end

return M
