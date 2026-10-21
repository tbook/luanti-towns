-- Minimal real-validator authored plan shared by the search and builder tests.
local catalog = dofile("src/catalog.lua")
local geometry = dofile("src/geometry.lua")
local entry = catalog.get("demo_house")

return function(center, seed)
	local dx, dz = center.x, center.z
	local function rect(x1, z1, x2, z2)
		return {x1 = x1 + dx, z1 = z1 + dz, x2 = x2 + dx, z2 = z2 + dz}
	end
	local function point(p) return {x = p.x + dx, z = p.z + dz} end
	local placed = geometry.place(entry, {x = 5 + dx, y = 0, z = dz}, 90)
	return {
		town_type = "roman", seed = seed or 1,
		center = {x = dx, z = dz},
		bounds = rect(0, 0, 15, 8), envelope = rect(0, 0, 15, 8),
		boundary = {rects = {rect(0, 0, 15, 8)}},
		site_order = {"forum", "temple"},
		sites = {
			forum = {name = "forum", kind = "square", material = "test:paving",
				rect = rect(0, 0, 2, 6), approach = {pos = point({x = 2, z = 3})}},
			temple = {name = "temple", kind = "landmark", id = "demo_house", rotation = 90,
				rect = {x1 = placed.min.x, z1 = placed.min.z,
					x2 = placed.max.x, z2 = placed.max.z},
				entrance = {x = placed.entrance.x, z = placed.entrance.z},
				approach = {pos = {x = placed.outside.x, z = placed.outside.z}},
			},
		},
		streets = {{kind = "principal", material = "test:road", rect = rect(3, 0, 4, 6)}},
		blocks = {{rect = rect(0, 7, 1, 8), frontage = {1}}},
		frontage = {{block = 1, square = "forum", material = "test:paving",
			rect = rect(0, 6, 1, 6)}},
	}
end
