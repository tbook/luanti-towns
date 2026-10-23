-- Small explicit plan for the reservation and frontage-content tests: one
-- block with one street run, no planner involved. Only the fields the
-- reservation modules read are present (sites, blocks, frontage, streets).
--
--   local row_plan = dofile("tests/frontage_plan_fixture.lua")
--   local plan = row_plan{length = 100, sites = {...}, square_face = false}
--
--   length       block/run length along x (default 100)
--   depth        block depth along z (default 12)
--   sites        extra or replacement sites (default market far from the block)
--   market       rect of the default market site (default far away)
--   square_face  the run fronts a market square (run.square) instead of a street
--   seed         plan seed (default 5)
-- The run lies on z = 0 facing -z; the street (or square) is the row z = -4..-1.
return function(opts)
	opts = opts or {}
	local length = opts.length or 100
	local sites = {market = {rect = opts.market or {x1 = 200, z1 = 200, x2 = 210, z2 = 210}}}
	for k, v in pairs(opts.sites or {}) do sites[k] = v end
	local row = {x1 = 0, z1 = -4, x2 = length - 1, z2 = -1}
	local run = {id = 1, block = 1, facing = {x = 0, z = -1},
		rect = {x1 = 0, z1 = 0, x2 = length - 1, z2 = 0}}
	local streets = {}
	if opts.square_face then
		run.square = "market"
		sites.market = {kind = "square", rect = row}
	else
		run.street = 1
		streets[1] = {kind = "principal", rect = row}
	end
	return {
		seed = opts.seed or 5, sites = sites, streets = streets,
		blocks = {{id = 1, rect = {x1 = 0, z1 = 0, x2 = length - 1, z2 = (opts.depth or 12) - 1}}},
		frontage = {run},
	}
end
