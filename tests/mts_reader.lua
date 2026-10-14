-- Minimal pure-Lua 5.1 reader for Luanti .mts schematics (version 3/4) for
-- tests: header, name table and the zlib-compressed node data (a small
-- inflate; no bit library needed). Returns a function
--   read(path) -> {size = {x,y,z}, at = function(x, y, z) -> node name, param2}
-- indexed in the file's own orientation (x, y, z from 0).
local function inflate(data, pos)
	local out, n = {}, 0
	local bitbuf, bitcnt = 0, 0
	local function bits(need)
		while bitcnt < need do
			bitbuf = bitbuf + data:byte(pos) * 2 ^ bitcnt
			pos = pos + 1
			bitcnt = bitcnt + 8
		end
		local v = bitbuf % 2 ^ need
		bitbuf = math.floor(bitbuf / 2 ^ need)
		bitcnt = bitcnt - need
		return v
	end
	local function build(lengths, count)
		local cnt, offs, symbols = {}, {}, {}
		for i = 0, 15 do cnt[i] = 0 end
		for i = 0, count - 1 do cnt[lengths[i]] = cnt[lengths[i]] + 1 end
		offs[1] = 0
		for i = 1, 14 do offs[i + 1] = offs[i] + cnt[i] end
		for i = 0, count - 1 do
			local l = lengths[i]
			if l ~= 0 then symbols[offs[l]] = i; offs[l] = offs[l] + 1 end
		end
		return {count = cnt, symbol = symbols}
	end
	local function decode(h)
		local code, first, index = 0, 0, 0
		for len = 1, 15 do
			code = code + bits(1)
			local c = h.count[len]
			if code - c < first then return h.symbol[index + (code - first)] end
			index = index + c
			first = (first + c) * 2
			code = code * 2
		end
		error("bad huffman code")
	end
	local LBASE = {3,4,5,6,7,8,9,10,11,13,15,17,19,23,27,31,35,43,51,59,67,83,99,115,131,163,195,227,258}
	local LEXT = {0,0,0,0,0,0,0,0,1,1,1,1,2,2,2,2,3,3,3,3,4,4,4,4,5,5,5,5,0}
	local DBASE = {1,2,3,4,5,7,9,13,17,25,33,49,65,97,129,193,257,385,513,769,1025,1537,2049,3073,4097,6145,8193,12289,16385,24577}
	local DEXT = {0,0,0,0,1,1,2,2,3,3,4,4,5,5,6,6,7,7,8,8,9,9,10,10,11,11,12,12,13,13}
	local function codes(lh, dh)
		while true do
			local sym = decode(lh)
			if sym < 256 then
				n = n + 1; out[n] = sym
			elseif sym == 256 then
				return
			else
				sym = sym - 257
				local len = LBASE[sym + 1] + bits(LEXT[sym + 1])
				local ds = decode(dh)
				local dist = DBASE[ds + 1] + bits(DEXT[ds + 1])
				for _ = 1, len do
					n = n + 1
					out[n] = out[n - dist]
				end
			end
		end
	end
	local last
	repeat
		last = bits(1)
		local kind = bits(2)
		if kind == 0 then
			bitbuf, bitcnt = 0, 0
			local len = data:byte(pos) + data:byte(pos + 1) * 256
			pos = pos + 4
			for _ = 1, len do
				n = n + 1; out[n] = data:byte(pos); pos = pos + 1
			end
		else
			local lh, dh
			if kind == 1 then
				local l = {}
				for i = 0, 143 do l[i] = 8 end
				for i = 144, 255 do l[i] = 9 end
				for i = 256, 279 do l[i] = 7 end
				for i = 280, 287 do l[i] = 8 end
				lh = build(l, 288)
				local d = {}
				for i = 0, 29 do d[i] = 5 end
				dh = build(d, 30)
			else
				local nlen, ndist, ncode = bits(5) + 257, bits(5) + 1, bits(4) + 4
				local order = {16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15}
				local l = {}
				for i = 0, 18 do l[i] = 0 end
				for i = 1, ncode do l[order[i]] = bits(3) end
				local ch = build(l, 19)
				local lengths, i = {}, 0
				while i < nlen + ndist do
					local sym = decode(ch)
					if sym < 16 then
						lengths[i] = sym; i = i + 1
					else
						local prev, rep = 0, 0
						if sym == 16 then prev = lengths[i - 1]; rep = 3 + bits(2)
						elseif sym == 17 then rep = 3 + bits(3)
						else rep = 11 + bits(7) end
						for _ = 1, rep do lengths[i] = prev; i = i + 1 end
					end
				end
				local ll, dl = {}, {}
				for k = 0, nlen - 1 do ll[k] = lengths[k] end
				for k = 0, ndist - 1 do dl[k] = lengths[nlen + k] end
				lh, dh = build(ll, nlen), build(dl, ndist)
			end
			codes(lh, dh)
		end
	until last == 1
	return out, n
end

local function u16(s, p) return s:byte(p) * 256 + s:byte(p + 1) end

return function(path)
	local f = assert(io.open(path, "rb"))
	local d = f:read("*a")
	f:close()
	assert(d:sub(1, 4) == "MTSM", "not an MTS file")
	local ver = u16(d, 5)
	local sx, sy, sz = u16(d, 7), u16(d, 9), u16(d, 11)
	local p = 13
	if ver >= 3 then p = p + sy end
	local count = u16(d, p); p = p + 2
	local names = {}
	for i = 0, count - 1 do
		local l = u16(d, p); p = p + 2
		names[i] = d:sub(p, p + l - 1); p = p + l
	end
	-- zlib header: two bytes.
	local raw, n = inflate(d, p + 2)
	local total = sx * sy * sz
	assert(n >= total * 4, "short node data")
	local function at(x, y, z)
		local i = z * sy * sx + y * sx + x
		local id = raw[2 * i + 1] * 256 + raw[2 * i + 2]
		return names[id], raw[total * 3 + i + 1]
	end
	return {size = {x = sx, y = sy, z = sz}, at = at}
end
