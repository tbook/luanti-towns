-- Street layout of the medieval plan for seed 99999 (centre 0, 0, the current
-- landmark profile) as the planner produced it BEFORE issue #122: the pavement
-- and landmark rectangles only, which is all the spacing checks read. It shows
-- the reported castle-adjacent pattern: secondary streets 17 and 20 (x58..65,
-- z0..35) and 18 and 19 (x-4..3, z0..35) run side by side next to the castle,
-- each pair one 8-wide band with no building row between the two roads.
return {
	envelope = {x1 = -104, z1 = -104, x2 = 103, z2 = 103},
	boundary = {rects = {
		{x1 = -104, z1 = -47, x2 = 100, z2 = 62},
		{x1 = 29, z1 = -97, x2 = 64, z2 = 62},
		{x1 = -68, z1 = -17, x2 = 64, z2 = 90},
		{x1 = -80, z1 = 49, x2 = 76, z2 = 90},
		{x1 = 77, z1 = 25, x2 = 100, z2 = 77},
	}},
	sites = {
		cathedral = {rect = {x1 = -94, z1 = -27, x2 = -40, z2 = 31}, approach = {pos = {x = -59, z = -28}, edge = {x1 = -94, z1 = -28, x2 = -40, z2 = -28}}},
		castle = {rect = {x1 = 7, z1 = 36, x2 = 56, z2 = 89}, approach = {pos = {x = 31, z = 35}, edge = {x1 = 7, z1 = 35, x2 = 56, z2 = 35}}, gate_apron = {x1 = 28, z1 = 31, x2 = 33, z2 = 35}},
		parvis = {rect = {x1 = -65, z1 = -35, x2 = -54, z2 = -28}, approach = {pos = {x = -60, z = -36}, edge = {x1 = -65, z1 = -36, x2 = -54, z2 = -36}}},
		market = {rect = {x1 = -22, z1 = -5, x2 = -1, z2 = 17}, approach = {pos = {x = -23, z = 6}, edge = {x1 = -23, z1 = -5, x2 = -23, z2 = 17}}},
		city_hall = {rect = {x1 = -20, z1 = -26, x2 = -3, z2 = -6}, approach = {pos = {x = -12, z = -5}, edge = {x1 = -20, z1 = -5, x2 = -3, z2 = -5}}},
	},
	approaches = {
		{name = "approach_1", side = "-z", pos = {x = 44, z = -97}, edge = {x1 = 42, z1 = -97, x2 = 46, z2 = -97}},
		{name = "approach_2", side = "+z", pos = {x = 86, z = 77}, edge = {x1 = 84, z1 = 77, x2 = 88, z2 = 77}},
	},
	streets = {
		{id = 1, kind = "principal", axis = "z", rect = {x1 = 42, z1 = -97, x2 = 46, z2 = -1}},
		{id = 2, kind = "principal", axis = "x", rect = {x1 = 0, z1 = -5, x2 = 46, z2 = -1}},
		{id = 3, kind = "principal", axis = "z", rect = {x1 = 84, z1 = -5, x2 = 88, z2 = 77}},
		{id = 4, kind = "principal", axis = "x", rect = {x1 = 47, z1 = -5, x2 = 88, z2 = -1}},
		{id = 5, kind = "principal", axis = "x", rect = {x1 = -39, z1 = -4, x2 = -23, z2 = 0}},
		{id = 6, kind = "principal", axis = "z", rect = {x1 = -39, z1 = -32, x2 = -35, z2 = 0}},
		{id = 7, kind = "principal", axis = "x", rect = {x1 = -58, z1 = -32, x2 = -35, z2 = -28}},
		{id = 8, kind = "principal", axis = "z", rect = {x1 = 27, z1 = 0, x2 = 31, z2 = 35}},
		{id = 9, kind = "secondary", axis = "z", rect = {x1 = -26, z1 = 1, x2 = -23, z2 = 90}},
		{id = 10, kind = "secondary", axis = "x", rect = {x1 = -39, z1 = 39, x2 = -27, z2 = 42}},
		{id = 11, kind = "secondary", axis = "x", rect = {x1 = -104, z1 = 41, x2 = -40, z2 = 44}},
		{id = 12, kind = "secondary", axis = "x", rect = {x1 = 47, z1 = -46, x2 = 64, z2 = -43}},
		{id = 13, kind = "secondary", axis = "x", rect = {x1 = 29, z1 = -39, x2 = 41, z2 = -36}},
		{id = 14, kind = "secondary", axis = "x", rect = {x1 = 29, z1 = -43, x2 = 41, z2 = -40}},
		{id = 15, kind = "secondary", axis = "x", rect = {x1 = 47, z1 = -42, x2 = 64, z2 = -39}},
		{id = 16, kind = "secondary", axis = "z", rect = {x1 = 88, z1 = -47, x2 = 91, z2 = -6}},
		{id = 17, kind = "secondary", axis = "z", rect = {x1 = 58, z1 = 0, x2 = 61, z2 = 35}},
		{id = 18, kind = "secondary", axis = "z", rect = {x1 = 0, z1 = 0, x2 = 3, z2 = 35}},
		{id = 19, kind = "secondary", axis = "z", rect = {x1 = -4, z1 = 18, x2 = -1, z2 = 35}},
		{id = 20, kind = "secondary", axis = "z", rect = {x1 = 62, z1 = 0, x2 = 65, z2 = 35}},
		{id = 21, kind = "secondary", axis = "x", rect = {x1 = -22, z1 = 78, x2 = 6, z2 = 81}},
		{id = 22, kind = "secondary", axis = "z", rect = {x1 = -58, z1 = 45, x2 = -55, z2 = 90}},
		{id = 23, kind = "secondary", axis = "x", rect = {x1 = 57, z1 = 74, x2 = 83, z2 = 77}},
		{id = 24, kind = "secondary", axis = "z", rect = {x1 = 7, z1 = -47, x2 = 10, z2 = -6}},
	},
}
