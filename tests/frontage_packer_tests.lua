-- Focused tests for ticket #40: single-frontage packer.
-- Loaded by tests/run.lua with its helpers, or run alone:
--   lua5.1 tests/frontage_packer_tests.lua
local eq, fails, geometry = ...
local standalone = eq == nil
local failures, count = 0, 0
if standalone then
	geometry = dofile("src/geometry.lua")
	eq = function(a, e, label)
		count = count + 1
		if a ~= e then
			failures = failures + 1
			print(("FAIL %s: expected %s, got %s"):format(label, tostring(e), tostring(a)))
		end
	end
	fails = function(fn, pat, label)
		count = count + 1
		local ok, err = pcall(fn)
		if ok or not tostring(err):find(pat, 1, true) then
			failures = failures + 1
			print("FAIL " .. label)
		end
	end
end
local packer = dofile("src/frontage_packer.lua")(geometry)

local function R(x1, z1, x2, z2) return {x1 = x1, z1 = z1, x2 = x2, z2 = z2} end
local function overlap(a, b)
	return a.x1 <= b.x2 and b.x1 <= a.x2 and a.z1 <= b.z2 and b.z1 <= a.z2
end
local function inside(a, o)
	return a.x1 >= o.x1 and a.x2 <= o.x2 and a.z1 >= o.z1 and a.z2 <= o.z2
end

-- Unequal widths/depths; door offsets inside the box. File front is -Z.
local E = {
	narrow = {size = {x = 3, y = 5, z = 4}, entrance = {x = 1, y = 1, z = 0}},
	wide   = {size = {x = 6, y = 5, z = 7}, entrance = {x = 2, y = 1, z = 0}},
	deep   = {size = {x = 4, y = 5, z = 12}, entrance = {x = 3, y = 1, z = 0}},
}

-- Block 20x20 at (10..29); the run is the block edge row on each side.
local block = {id = 7, rect = R(10, 10, 29, 29)}
local RUNS = {
	["-z"] = {id = 3, facing = {x = 0, z = -1}, rect = R(10, 10, 29, 10), rot = 0},
	["+z"] = {id = 4, facing = {x = 0, z = 1}, rect = R(10, 29, 29, 29), rot = 180},
	["-x"] = {id = 5, facing = {x = -1, z = 0}, rect = R(10, 10, 10, 29), rot = 90},
	["+x"] = {id = 6, facing = {x = 1, z = 0}, rect = R(29, 10, 29, 29), rot = 270},
}

for _, side in ipairs({"-z", "+z", "-x", "+x"}) do
	local run = RUNS[side]
	local res = packer.pack{run = run, block = block, entries = E, seed = 11}
	eq(#res.placements > 1, true, side .. " packs several")
	local covered, prev_end = 0, nil
	local horiz = side == "-z" or side == "+z"
	for i, p in ipairs(res.placements) do
		local lbl = side .. " #" .. i
		eq(p.rotation, run.rot, lbl .. " rotation")
		eq(p.block, 7, lbl .. " block")
		eq(p.frontage, run.id, lbl .. " frontage")
		eq(inside(p.rect, block.rect), true, lbl .. " inside block")
		for j = 1, i - 1 do
			eq(overlap(p.rect, res.placements[j].rect), false, lbl .. " no overlap " .. j)
		end
		-- Rect matches geometry's rotated footprint and door.
		local g = geometry.place(E[p.building_id], {x = p.rect.x1, y = 0, z = p.rect.z1}, run.rot)
		eq(g.max.x, p.rect.x2, lbl .. " max x")
		eq(g.max.z, p.rect.z2, lbl .. " max z")
		eq(p.entrance.x, g.entrance.x, lbl .. " door x")
		eq(p.entrance.z, g.entrance.z, lbl .. " door z")
		-- Front edge flush on the run row, door's outside node on the street.
		local ok
		if side == "-z" then ok = p.rect.z1 == 10 and g.outside.z == 9
		elseif side == "+z" then ok = p.rect.z2 == 29 and g.outside.z == 30
		elseif side == "-x" then ok = p.rect.x1 == 10 and g.outside.x == 9
		else ok = p.rect.x2 == 29 and g.outside.x == 30 end
		eq(ok, true, lbl .. " front on street row")
		local a1 = horiz and p.rect.x1 or p.rect.z1
		local a2 = horiz and p.rect.x2 or p.rect.z2
		eq(a1 >= 10 and a2 <= 29, true, lbl .. " within run")
		local door = horiz and p.entrance.x or p.entrance.z
		eq(door >= 10 and door <= 29, true, lbl .. " door aligned with run")
		if prev_end then eq(a1 > prev_end, true, lbl .. " ordered") end
		prev_end = a2
		covered = covered + (a2 - a1 + 1)
	end
	eq(res.placed_length, covered, side .. " placed_length")
	local gap_total = 0
	for _, u in ipairs(res.unused) do gap_total = gap_total + u.length end
	eq(covered + gap_total, 20, side .. " run fully accounted")
end

-- Touching: a single 5-wide entry fills a 20-run with four boxes, zero gap.
local one = {a = {size = {x = 5, y = 3, z = 5}, entrance = {x = 2, z = 0}}}
local res = packer.pack{run = RUNS["-z"], block = block, entries = one, seed = 1}
eq(#res.placements, 4, "four touching boxes")
eq(#res.unused, 0, "no unused")
for i = 2, #res.placements do
	eq(res.placements[i].rect.x1, res.placements[i - 1].rect.x2 + 1, "touch " .. i)
end

-- Remainder reported explicitly (23-node run, 5-wide boxes -> 3 left over).
res = packer.pack{run = {id = 1, facing = {x = 0, z = -1}, rect = R(10, 10, 32, 10)},
	block = {id = 1, rect = R(10, 10, 32, 29)}, entries = one, seed = 1}
eq(#res.placements, 4, "23-run holds four")
eq(#res.unused, 1, "one leftover")
eq(res.unused[1].length, 3, "leftover length")
eq(res.unused[1].rect.x1, 30, "leftover x1")
eq(res.unused[1].rect.x2, 32, "leftover x2")

-- Obstacles: occupied rect blocks one slot; nothing overlaps it.
local obst = R(15, 10, 19, 14)
res = packer.pack{run = RUNS["-z"], block = block, entries = one, seed = 1, occupied = {obst}}
for i, p in ipairs(res.placements) do eq(overlap(p.rect, obst), false, "obstacle clear " .. i) end
eq(#res.placements, 3, "three fit around obstacle")
local u = 0
for _, x in ipairs(res.unused) do u = u + x.length end
eq(u, 5, "obstacle gap unused")

-- Depth: entries deeper than the block are excluded.
res = packer.pack{run = RUNS["-z"], block = {id = 7, rect = R(10, 10, 29, 14)},
	entries = {deep = E.deep, narrow = E.narrow}, seed = 2}
for _, p in ipairs(res.placements) do eq(p.building_id, "narrow", "deep excluded") end
eq(#res.placements > 0, true, "narrow still packs")

-- No fit: empty placements and one full-run unused interval.
res = packer.pack{run = RUNS["-x"], block = block, entries = {w = E.wide}, seed = 3,
	occupied = {R(10, 10, 29, 29)}}
eq(#res.placements, 0, "no-fit empty")
eq(#res.unused, 1, "no-fit one interval")
eq(res.unused[1].length, 20, "no-fit interval length")
res = packer.pack{run = RUNS["-x"], block = block, entries = {}, seed = 3}
eq(#res.placements, 0, "empty catalog")
res = packer.pack{run = {id = 1, facing = {x = 0, z = -1}, rect = R(10, 10, 11, 10)},
	block = block, entries = one, seed = 3}
eq(#res.placements, 0, "run shorter than any entry")

-- Stable seeds.
local function sig(seed)
	local out = packer.pack{run = RUNS["+z"], block = block, entries = E, seed = seed}
	local t = {}
	for _, p in ipairs(out.placements) do t[#t + 1] = p.building_id .. "@" .. p.rect.x1 end
	return table.concat(t, ",")
end
eq(sig(5), sig(5), "same seed same result")
local differ = false
for s = 6, 20 do if sig(s) ~= sig(5) then differ = true end end
eq(differ, true, "seeds vary result")

fails(function() packer.pack{run = RUNS["-z"], block = block, entries = E, seed = 1.5} end,
	"integer seed", "non-integer seed rejected")

if standalone then
	print(("%d checks, %d failures"):format(count, failures))
	os.exit(failures == 0 and 0 or 1)
end
