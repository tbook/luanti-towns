-- Stock village tavern and well templates (#35, #36): reads the real .mts
-- bytes (MTS v4: header, per-Y probs, name table, zlib node data) and checks
-- them against the catalog and the Living Villages recognition cells.
local eq, catalog = ...

-- Minimal zlib inflate (RFC 1950/1951), enough for MTS node data.
local function inflate(s)
	local pos, bitbuf, bitcnt = 3, 0, 0 -- skip the 2-byte zlib header
	local function bits(n)
		while bitcnt < n do
			bitbuf = bitbuf + s:byte(pos) * 2 ^ bitcnt
			pos, bitcnt = pos + 1, bitcnt + 8
		end
		local v = bitbuf % 2 ^ n
		bitbuf = math.floor(bitbuf / 2 ^ n)
		bitcnt = bitcnt - n
		return v
	end
	local function build(lengths, n)
		local count, offs, symbols = {}, {}, {}
		for i = 0, 15 do count[i] = 0 end
		for i = 0, n - 1 do count[lengths[i]] = count[lengths[i]] + 1 end
		count[0] = 0
		offs[1] = 0
		for i = 1, 14 do offs[i + 1] = offs[i] + count[i] end
		for i = 0, n - 1 do
			if lengths[i] ~= 0 then
				symbols[offs[lengths[i]]] = i
				offs[lengths[i]] = offs[lengths[i]] + 1
			end
		end
		return {count = count, symbols = symbols}
	end
	local function decode(h)
		local code, first, index = 0, 0, 0
		for len = 1, 15 do
			code = code + bits(1)
			local c = h.count[len]
			if code - c < first then return h.symbols[index + (code - first)] end
			index, first = index + c, (first + c) * 2
			code = code * 2
		end
		error("bad huffman code")
	end
	local LBASE = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
	local LEXT = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
	local DBASE = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
	local DEXT = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
	local out = {}
	local fixed_l, fixed_d
	repeat
		local final, kind = bits(1), bits(2)
		if kind == 0 then
			bitbuf, bitcnt = 0, 0
			local len = s:byte(pos) + s:byte(pos + 1) * 256
			pos = pos + 4
			for i = 0, len - 1 do out[#out + 1] = s:byte(pos + i) end
			pos = pos + len
		else
			local lh, dh
			if kind == 1 then
				if not fixed_l then
					local l = {}
					for i = 0, 143 do l[i] = 8 end
					for i = 144, 255 do l[i] = 9 end
					for i = 256, 279 do l[i] = 7 end
					for i = 280, 287 do l[i] = 8 end
					fixed_l = build(l, 288)
					local d = {}
					for i = 0, 29 do d[i] = 5 end
					fixed_d = build(d, 30)
				end
				lh, dh = fixed_l, fixed_d
			else
				local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
				local order = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}
				local cl = {}
				for i = 0, 18 do cl[i] = 0 end
				for i = 1, ncode do cl[order[i]] = bits(3) end
				local ch = build(cl, 19)
				local lens, i = {}, 0
				while i < nlen + ndist do
					local sym = decode(ch)
					if sym < 16 then
						lens[i] = sym; i = i + 1
					else
						local prev, rep = 0, 0
						if sym == 16 then prev, rep = lens[i - 1], 3 + bits(2)
						elseif sym == 17 then rep = 3 + bits(3)
						else rep = 11 + bits(7) end
						for _ = 1, rep do lens[i] = prev; i = i + 1 end
					end
				end
				local l, d = {}, {}
				for j = 0, nlen - 1 do l[j] = lens[j] end
				for j = 0, ndist - 1 do d[j] = lens[nlen + j] end
				lh, dh = build(l, nlen), build(d, ndist)
			end
			while true do
				local sym = decode(lh)
				if sym < 256 then
					out[#out + 1] = sym
				elseif sym == 256 then
					break
				else
					sym = sym - 256
					local len = LBASE[sym] + bits(LEXT[sym])
					local ds = decode(dh) + 1
					local dist = DBASE[ds] + bits(DEXT[ds])
					for _ = 1, len do out[#out + 1] = out[#out - dist + 1] end
				end
			end
		end
	until final == 1
	return out
end

-- Returns {size = {x,y,z}, node = function(x, y, z) -> name}.
local function read_mts(path)
	local f = assert(io.open(path, "rb"))
	local d = f:read("*a")
	f:close()
	eq(d:sub(1, 4), "MTSM", path .. " signature")
	local function u16(i) return d:byte(i) * 256 + d:byte(i + 1) end
	eq(u16(5), 4, path .. " version")
	local sx, sy, sz = u16(7), u16(9), u16(11)
	local p = 13 + sy
	local count = u16(p)
	p = p + 2
	local names = {}
	for i = 0, count - 1 do
		local len = u16(p)
		names[i] = d:sub(p + 2, p + 1 + len)
		p = p + 2 + len
	end
	local raw = inflate(d:sub(p))
	local n = sx * sy * sz
	eq(#raw, n * 4, path .. " node data length")
	return {size = {x = sx, y = sy, z = sz}, node = function(x, y, z)
		if x < 0 or y < 0 or z < 0 or x >= sx or y >= sy or z >= sz then return nil end
		local i = z * sy * sx + y * sx + x
		return names[raw[2 * i + 1] * 256 + raw[2 * i + 2] + 0]
	end}
end

local function required(id)
	local data = dofile("schematics/templates/" .. id .. ".lua")
	local set = {}
	for _, name in ipairs(data.required_nodes) do set[name] = true end
	return set
end

local function dims(id, mts)
	local e = catalog.get(id)
	eq(mts.size.x, e.size.x, id .. " mts size.x matches catalog")
	eq(mts.size.y, e.size.y, id .. " mts size.y matches catalog")
	eq(mts.size.z, e.size.z, id .. " mts size.z matches catalog")
	return e
end

-- Tavern: canonical -Z front, 10 x 12 x 12 (stock 12 x 13 x 10 rotated, dirt ground layer kept as row 0, floor on row 1, #87).
local tavern = read_mts("schematics/templates/tavern.mts")
local te = dims("tavern", tavern)
eq(catalog.get("tavern").role, "tavern", "tavern role")
eq(required("tavern")["mcl_jukebox:jukebox"], true, "tavern requires jukebox")
eq(tavern.node(7, 2, 7), "mcl_jukebox:jukebox", "tavern jukebox cell")
eq(tavern.node(6, 2, 7), "air", "jukebox west side open")
eq(tavern.node(7, 2, 6), "air", "jukebox north side open")
eq(te.entrance.y, 2, "tavern door sits on floor row 1 above the ground row")
eq(te.ground_offset or 0, 0, "tavern ground row is row 0")
eq(tavern.node(te.entrance.x, 0, te.entrance.z - 1), "mcl_core:dirt", "tavern ground row is dirt outside the door")
eq(tavern.node(te.entrance.x, te.entrance.y, te.entrance.z), "mcl_doors:wooden_door_b_1", "tavern entrance is the door")
eq(tavern.node(te.entrance.x, te.entrance.y, te.entrance.z - 1), "air", "tavern outside the door is open")
eq(tavern.node(2, 3, 5), "mcl_itemframes:plate", "tavern plate on a table")
eq(tavern.node(2, 2, 5), "mcl_decor:table_wooden", "tavern table under plate")

-- Well: front on -Z, 6 x 7 x 8, Living Villages well.lua cells.
local well = read_mts("schematics/templates/well.mts")
local we = dims("well", well)
eq(catalog.get("well").role, "well", "well role")
for x = 2, 3 do
	for z = 3, 4 do
		eq(well.node(x, 2, z), "mcl_core:water_source", ("well water %d,%d"):format(x, z))
		eq(well.node(x, 1, z), "mcl_core:cobble", ("well below water %d,%d"):format(x, z))
		eq(well.node(x, 3, z), "air", ("well above water %d,%d"):format(x, z))
	end
end
for _, c in ipairs({{1, 3}, {1, 4}, {4, 3}, {4, 4}, {2, 2}, {3, 2}, {2, 5}, {3, 5}}) do
	eq(well.node(c[1], 2, c[2]), "mcl_core:stonebrick", ("well ring %d,%d"):format(c[1], c[2]))
end
eq(well.node(we.entrance.x, we.entrance.y, we.entrance.z), "air", "well entrance cell is air")
eq(well.node(we.entrance.x, we.entrance.y + 1, we.entrance.z), "air", "well entrance head room")
eq(well.node(we.entrance.x, we.entrance.y - 1, we.entrance.z), "mcl_core:dirt", "well entrance has ground")

-- Library and blacksmith (#112): stock 12 x 9 x 12 and 8 x 8 x 11, door/opening
-- on the stock -X side (rotation 270), dirt ground row kept as row 0.
local function find(m, name)
	local found = {}
	for z = 0, m.size.z - 1 do for y = 0, m.size.y - 1 do for x = 0, m.size.x - 1 do
		if m.node(x, y, z) == name then found[#found + 1] = {x = x, y = y, z = z} end
	end end end
	return found
end

local library = read_mts("schematics/templates/library.mts")
local le = dims("library", library)
eq(catalog.get("library").role, "shop", "library role")
eq(le.size.x * le.size.z, 10 * 12, "library footprint (stock 12 x 12 minus the empty back rows)")
eq(le.entrance.y, 2, "library door sits on floor row 1 above the ground row")
eq(le.ground_offset or 0, 0, "library ground row is row 0")
eq(library.node(le.entrance.x, le.entrance.y, le.entrance.z), "mcl_doors:wooden_door_b_1", "library entrance is the door")
-- Living Villages library_schematic.lua: the lectern replaces the wooden stair.
eq(#find(library, "mcl_lectern:lectern"), 1, "library has exactly one lectern")
eq(required("library")["mcl_lectern:lectern"], true, "library requires the lectern")
eq(#find(library, "mcl_books:bookshelf") > 0, true, "library has bookshelves")

local smith = read_mts("schematics/templates/blacksmith.mts")
local se = dims("blacksmith", smith)
eq(catalog.get("blacksmith").role, "workshop", "blacksmith role")
eq(catalog.get("blacksmith").entrance_kind, "opening", "blacksmith entrance kind")
eq(se.entrance.y, 2, "blacksmith opening is on floor row 1 above the ground row")
eq(se.ground_offset or 0, 0, "blacksmith ground row is row 0")
eq(smith.node(se.entrance.x, se.entrance.y, se.entrance.z), "air", "blacksmith opening cell is air")
eq(smith.node(se.entrance.x, se.entrance.y - 1, se.entrance.z), "mcl_core:cobble", "blacksmith opening floor is solid")
eq(#find(smith, "mcl_anvils:anvil"), 1, "blacksmith anvil")
eq(#find(smith, "mcl_blast_furnace:blast_furnace"), 1, "blacksmith blast furnace")
-- The four lava sources are enclosed on every horizontal side.
local lava = find(smith, "mcl_core:lava_source")
eq(#lava, 4, "blacksmith lava sources")
for _, p in ipairs(lava) do
	for _, d in ipairs({{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) do
		local n = smith.node(p.x + d[1], p.y, p.z + d[2])
		eq(n ~= nil and n ~= "air", true, ("lava %d,%d,%d side %d,%d is enclosed"):format(p.x, p.y, p.z, d[1], d[2]))
	end
end
