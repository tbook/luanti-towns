-- Pure solver research for docs/city_margins_design.md; no world writes.
-- From Towns: lua5.1 tools/issue256_margin_probe.lua [living_villages path]
local modpath = arg[1] or "../living_villages"
minetest = {get_modpath = function() return modpath end}
local smoothing = dofile(modpath .. "/village_smoothing.lua")
local config = {}
for k, v in pairs(smoothing.config) do config[k] = v end
config.margin, config.radius, config.cap = 0, 20, 20

local function run(label, rects, ground, outside, protected)
	local pads = {}
	local function inside(x, z)
		for _, r in ipairs(rects) do
			if x >= r[1] and x <= r[3] and z >= r[2] and z <= r[4] then return true end
		end
		return false
	end
	for _, r in ipairs(rects) do
		pads[#pads + 1] = {
			x0 = r[1], z0 = r[2], x1 = r[3], z1 = r[4],
			yx0 = r[1], yz0 = r[2], yx1 = r[3], yz1 = r[4], y = ground,
		}
	end
	local started = os.clock()
	local targets = smoothing.targets(pads, function(x, z)
		return inside(x, z) and ground or outside
	end, config, protected)
	local changed, maxmove, changed_inside = 0, 0, 0
	for z = targets.z0, targets.z1 do
		for x = targets.x0, targets.x1 do
			local target, was = targets.at(x, z), targets.was(x, z)
			if target and was and target ~= was then
				changed = changed + 1
				maxmove = math.max(maxmove, math.abs(target - was))
				if inside(x, z) then changed_inside = changed_inside + 1 end
			end
		end
	end
	assert(changed_inside == 0 and maxmove <= 20)
	print(label, "seconds=" .. string.format("%.3f", os.clock() - started),
		"changed=" .. changed, "maxmove=" .. maxmove,
		"violations=" .. targets.violations, "edge=" .. tostring(targets.at(-1, 30)),
		"at_radius=" .. tostring(targets.at(-20, 30)))
end

run("raised rectangle", {{0, 0, 180, 170}}, 20, 8)
run("cut rectangle", {{0, 0, 180, 170}}, 8, 20)
run("extreme rectangle", {{0, 0, 180, 170}}, 35, 5)
run("protected extreme", {{0, 0, 180, 170}}, 35, 5,
	{{x0 = 0, z0 = 0, x1 = 180, z1 = 170}})
run("irregular union", {{0, 0, 120, 100}, {30, 101, 70, 140}, {121, 20, 160, 65}}, 20, 8)
