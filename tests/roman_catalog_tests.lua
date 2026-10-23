-- Real capture metadata and noncanonical entrance directions (#147).
local eq, fails, geometry, catalog, placement = ...
local read = dofile("tests/mts_reader.lua")
local preflight = dofile("src/preflight.lua")
local planner = dofile("src/planner.lua")
local builder = dofile("src/builder.lua")(placement, planner)
local fixtures = {
	-- size, entrance Y, ground depth, rotated entrance X/Z, rotated fronts
	arch = {{12,11,8}, 1, 0, {{5,0},{0,6},{6,7},{7,5}}, 1},
	temple = {{18,11,12}, 2, 0, {{3,5},{5,14},{14,6},{6,3}}, 2},
	domus = {{38,11,22}, 2, 1, {{1,9},{9,36},{36,12},{12,1}}, 2},
	theatre = {{21,11,14}, 5, 3, {{10,13},{13,10},{10,0},{0,10}}, 3},
	amphitheater = {{29,9,29}, 3, 2, {{15,0},{0,13},{13,28},{28,15}}, 1},
	bath = {{88,18,43}, 4, 2, {{4,20},{20,83},{83,22},{22,4}}, 2},
	insula = {{35,20,27}, 3, 2, {{17,2},{2,17},{17,24},{24,17}}, 1},
	vespasianum = {{10,8,8}, 3, 2, {{1,3},{3,8},{8,4},{4,1}}, 2},
	basilica = {{28,14,16}, 3, 2, {{23,7},{7,4},{4,8},{8,23}}, 4},
}
local fronts = {{0,-1},{-1,0},{0,1},{1,0}}
local cache = {}
local invalid = catalog.verify(function(path)
	local s = read(path)
	cache[path] = s
	return s
end, ".")
eq(next(invalid), nil, "actual catalog schematics pass verification")
local snapshot = catalog.snapshot()
for id, f in pairs(fixtures) do
	local e = catalog.get(id)
	local s = cache["./" .. e.path]
	eq(e.role, "landmark", id .. " fixed landmark role")
	eq(e.path, "schematics/imports/roman/" .. id .. ".mts", id .. " original capture")
	eq(e.data_path, "schematics/imports/roman/" .. id .. ".lua", id .. " original sidecar")
	local data = dofile(e.data_path)
	eq(type(data.metadata), "table", id .. " metadata readable")
	eq(type(data.required_nodes), "table", id .. " node list readable")
	for i, k in ipairs({"x","y","z"}) do eq(e.size[k], f[1][i], id .. " measured size " .. k) end
	eq(e.ground_offset, f[3], id .. " measured ground")
	eq(snapshot[id].entrance.facing, e.entrance.facing, id .. " snapshot preserves facing")
	local name = s.at(e.entrance.x, e.entrance.y, e.entrance.z)
	if e.entrance_kind == "door" then
		eq(name:find("_door_b_", 1, true) ~= nil, true, id .. " actual entrance door")
	else
		eq(name, "air", id .. " actual opening feet")
		eq(s.at(e.entrance.x, e.entrance.y + 1, e.entrance.z), "air", id .. " opening head")
	end
	eq(s.at(e.entrance.x, e.entrance.y - 1, e.entrance.z) ~= "air", true, id .. " entrance floor")
	for i, rotation in ipairs(geometry.ROTATIONS) do
		local b = geometry.place(snapshot[id], {x = 100, y = 20 - f[3], z = 200}, rotation)
		local front = fronts[(f[5] + i - 2) % 4 + 1]
		local label = id .. " at " .. rotation
		eq(b.min.y, 20 - f[3], label .. " foundation")
		eq(b.max.y, 19 - f[3] + f[1][2], label .. " top")
		eq(b.size.x, f[1][i % 2 == 1 and 1 or 3], label .. " width")
		eq(b.size.z, f[1][i % 2 == 1 and 3 or 1], label .. " depth")
		eq(b.entrance.x, 100 + f[4][i][1], label .. " entrance x")
		eq(b.entrance.z, 200 + f[4][i][2], label .. " entrance z")
		eq(b.entrance.y, 20 - f[3] + f[2], label .. " entrance y")
		eq(b.front.x, front[1], label .. " front x")
		eq(b.front.z, front[2], label .. " front z")
		eq(b.outside.x, b.entrance.x + front[1], label .. " approach x")
		eq(b.outside.z, b.entrance.z + front[2], label .. " approach z")
		local rect = {x1=b.min.x,z1=b.min.z,x2=b.max.x,z2=b.max.z}
		local composed = assert(preflight.compose({bounds=rect,sites={
			monument={kind="landmark",id=id,rotation=rotation,rect=rect},
		}}, snapshot, 20))
		local st = composed.structures[1]
		eq(st.id, id, label .. " shared composition id")
		eq(st.min.y, 20 - f[3], label .. " shared composition depth")
		eq(st.entrance.x, b.entrance.x, label .. " shared composition entrance x")
		eq(st.entrance.y, b.entrance.y, label .. " shared composition entrance y")
		eq(st.entrance.z, b.entrance.z, label .. " shared composition entrance z")
		eq(st.front.x, b.front.x, label .. " shared composition front x")
		eq(st.front.z, b.front.z, label .. " shared composition front z")
	end
end
eq(table.concat(catalog.ids_for_role("landmark"), ","),
	"amphitheater,arch,basilica,bath,domus,insula,temple,theatre,vespasianum", "exactly nine fixed Roman templates")
eq(catalog.entries.villa, nil, "villa remains import only")
eq(catalog.entries.aqueduct, nil, "aqueduct remains import only")
local profile = assert(planner.landmark_profile(snapshot))
for id in pairs(fixtures) do
	eq(profile.content[id], nil, id .. " absent from medieval random pool")
end

-- Integration regression: composition preserves a +Z facing and the shared
-- builder checks that edge. Block the other three footprint edges completely.
do
	local entry = {size={x=3,y=3,z=3}, ground_offset=0,
		entrance={x=1,y=1,z=2,facing="+Z"}}
	local entries = {oriented_test=entry}
	local g = 40
	for _, rotation in ipairs(geometry.ROTATIONS) do
		local placed = geometry.place(entry, {x=100,y=g,z=100}, rotation)
		local rect = {x1=placed.min.x,z1=placed.min.z,x2=placed.max.x,z2=placed.max.z}
		local comp = assert(preflight.compose({bounds=rect,sites={
			monument={kind="landmark",id="oriented_test",rotation=rotation,rect=rect},
		}}, entries, g))
		local st = comp.structures[1]
		eq(st.front.x, placed.front.x, "shared front x at " .. rotation)
		eq(st.front.z, placed.front.z, "shared front z at " .. rotation)
		local function node(x,y,z)
			local ring = (x == rect.x1-1 or x == rect.x2+1) and z >= rect.z1-1 and z <= rect.z2+1
				or (z == rect.z1-1 or z == rect.z2+1) and x >= rect.x1-1 and x <= rect.x2+1
			if ring and not (x == placed.outside.x and z == placed.outside.z)
					and (y == g+1 or y == g+2) then
				return {walkable=true}, "mcl_walls:stone"
			end
			if y <= g then return {walkable=true}, "mcl_core:stone" end
			if x == placed.entrance.x and z == placed.entrance.z and y == placed.entrance.y then
				return {walkable=true,door=true}, "mcl_doors:wooden_door_b_1"
			end
			return {walkable=false}, "air"
		end
		local route, why = builder.check_door(st, g, node)
		eq(route ~= nil, true, "builder finds facing approach at " .. rotation .. ": " .. tostring(why))
		if route then
			eq(route.approach.x, placed.outside.x, "builder approach x at " .. rotation)
			eq(route.approach.z, placed.outside.z, "builder approach z at " .. rotation)
		end
	end
end

-- The whole arch opening has headroom, including above its half-slab floor.
local arch = cache["./" .. catalog.get("arch").path]
for x = 5, 6 do for z = 0, 7 do for y = 2, 3 do
	eq(arch.at(x,y,z), "air", "arch through-opening headroom")
end end end
local bath = cache["./" .. catalog.get("bath").path]
eq(bath.at(0,1,0), "mcl_core:dirt", "bath lower plinth layer")
eq(bath.at(0,2,0), "mcl_core:dirt_with_grass", "bath surface datum")
eq(bath.at(40,1,33), "mcl_beds:bed_brown_bottom", "bath basement retained below datum")

-- Temple (#134): the terrain row sits below the quartz platform, so the floor
-- is row 1, the door is on it, and row 0 (the ground datum) is dirt/grass.
local temple = cache["./" .. catalog.get("temple").path]
local te = catalog.get("temple").entrance
eq(te.y, 2, "temple door sits on the platform row above the ground row")
eq(catalog.get("temple").ground_offset, 0, "temple ground row is row 0")
eq(temple.at(te.x, te.y, te.z), "mcl_doors:spruce_door_b_1", "temple entrance is the door")
eq(temple.at(te.x - 1, te.y, te.z), "air", "temple outside the door is open")
eq(temple.at(te.x - 1, 0, te.z), "mcl_core:dirt", "temple ground row is dirt outside the door")
eq(temple.at(te.x, 1, te.z), "mcl_nether:quartz_smooth", "temple floor under the door is the platform")

-- Malformed facing must be rejected before placement; explicit +X also works.
local entrance = catalog.get("temple").entrance
local facing = entrance.facing
for _, bad in ipairs({false, 90, "north", ""}) do
	entrance.facing = bad
	eq(catalog.verify(function(path) return cache[path] end, ".").temple ~= nil, true,
		"catalog rejects invalid facing " .. tostring(bad))
	fails(function() geometry.place(catalog.get("temple"), {x=0,y=0,z=0}, 0) end,
		"invalid entrance facing", "geometry rejects facing " .. tostring(bad))
end
entrance.facing = "+X"
for i, rotation in ipairs(geometry.ROTATIONS) do
	local b = geometry.place(catalog.get("temple"), {x=0,y=0,z=0}, rotation)
	local front = fronts[(i + 2) % 4 + 1]
	eq(b.front.x, front[1], "+X facing rotates x")
	eq(b.front.z, front[2], "+X facing rotates z")
end
entrance.facing = "bad"
fails(function() geometry.place(catalog.get("temple"), {x=0,y=0,z=0}, 0) end,
	"invalid entrance facing", "geometry rejects invalid facing")
entrance.facing = facing
snapshot.temple.entrance.facing = "+X"
eq(entrance.facing, "-X", "snapshot facing is independent")
catalog.verify(function(path) return cache[path] end, ".")
