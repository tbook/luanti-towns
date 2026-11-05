local eq = ...
local guard = dofile("src/auto_protection.lua")
local stages = {a = {kind = "write", box = {min = {x = -1, y = 2, z = 0}, max = {x = 1, y = 3, z = 0}}},
	b = {kind = "read", box = {min = {x = 4, y = 4, z = 4}, max = {x = 4, y = 4, z = 4}}}}
local seen = {}
local ok, reason, count = guard.check(stages, function(p, name)
	eq(name, "", "protection checked for automatic actor")
	seen[p.x .. ":" .. p.y .. ":" .. p.z] = true
	return false
end, 6)
eq(ok, true, "all unprotected write voxels pass")
eq(count, 6, "all six voxels are checked")
eq(seen["-1:2:0"] and seen["1:3:0"], true, "inclusive endpoints checked")
eq(seen["4:4:4"], nil, "read-only stage is not checked")
ok, reason, count = guard.check(stages, function(p) return p.x == 0 and p.y == 3 end, 6)
eq(ok, false, "protected voxel rejects")
eq(reason, "protected", "protected reason")
ok, reason, count = guard.check(stages, function() error("provider failure") end, 6)
eq(reason, "provider_error", "provider failure rejects")
ok, reason, count = guard.check(stages, function() return nil end, 6)
eq(reason, "invalid_response", "indeterminate result rejects")
ok, reason, count = guard.check(stages, function() error("must not run") end, 5)
eq(reason, "check_cap", "cap declines before checking")
eq(count, 0, "cap does not call provider")
ok, reason = guard.check({b = stages.b}, function() return false end, 6)
eq(reason, "no_write_stages", "missing write stages reject")
