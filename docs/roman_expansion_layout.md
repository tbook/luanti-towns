# Roman expansion layout (issue #221)

Specification for the expanded Roman town: Jupiter, Vesta, the hippodrome,
extended secondary roads and the new ordinary neighbourhoods. It is the
reviewed geometry that #351, #352, #353 and #354 implement; those tickets
should not need to make urban-design choices.

Status: proposal for PM/user review. Nothing in `src/` changes with this
document. Every number below was produced by a scratch prototype of the
proposed layout (see "Verification" at the end) run through the real
planner, authored validation, frontage packer, service/jail reservation,
`preflight.compose`, `town_layout`, `site_search.boundary_columns`, the
builder's door-route check and `tools/layout_compare`.

**Amendment, 2026-11-02 (#365, PM playtest): the hippodrome moved 4 nodes
east.** Its landmark `at` is now -87 (was -91), so the footprint is
x -87..-51, z 41..65; the main entrance is (-69, 62) and the approach
(-69, 66) on ring_north_outer, which lies on the west_outer road axis
(x -72..-67). The door court is now x -50..-45, z 41..65 (6 x 25), still
unbuilt. The former west strip x -91..-88 (z 41..65) is open ground inside
`main_rect`. Where this document gives the hippodrome at x -91..-55, the
door-court numbers x -54..-45, or the approach (-73, 66) / entrance (-73, 62),
that is the pre-#365 position. The rows of sections 4, 5, 5.1, 6 and 9 are
updated to the new position, the section 2 drawing and the
`docs/roman_expansion_221/` figures (SVG, text, metrics and map) are not
redrawn and show the previous position, and section 16's ticket texts are
the historical proposals. The source of truth is `src/roman_civic_plan.lua`.

Files in `docs/roman_expansion_221/`:

- `proposed_roman_civic_plan.lua.txt`: the complete proposed
  `src/roman_civic_plan.lua` (end state after #354), in the current
  schema plus the two extensions of section 11. This is the placement table
  in machine form; the tables below are the same data, resolved to
  rectangles.
- `proposed_plan_map.txt`: plan-only overhead (streets, squares,
  landmarks, blocks; no buildings), 1 character = 2x2 nodes.
- `proposed_seed_1.svg` / `proposed_seed_1.txt`: `tools/layout_compare`
  render of the proposed layout, seed 1, with placed buildings, services
  and jail. `current_seed_1.svg` is the same render of `origin/main`.
- `proposed_metrics.tsv`, `current_metrics.tsv`: layout-compare metrics,
  seeds 1, 2, 3, 7, after and before.
- `prototype/`: the scratch-prototype scripts, the per-stage layouts and
  their raw outputs (`prototype/results/`), with a README on how to rerun
  them. Figures quoted from there are marked "prototype" below.

## 1. Conventions

- Coordinates are offsets from the planner centre (the middle of the
  forum), x east, z north, inclusive rectangles written `x1..x2, z1..z2`.
  The whole plan, including the main city rectangle, translates with the
  centre.
- Footprints are rotated `geometry.place` boxes. File-local coordinates are
  `(x, y, z)` in the `.mts` orientation (front = -Z unless a facing is
  given).
- "Approach" is the first node outside the footprint along the entrance
  front, as `authored_plan.landmark_site` computes it; it must be connected
  public pavement.
- Row depth D = 9 (catalog-derived lower median, unchanged). Every block is
  nine nodes deep, as today.

## 2. Overhead drawing

Pre-#365 figure: the hippodrome `T` in the drawing below is at x -91..-55
(the current footprint is x -87..-51, 4 nodes further east).

Lettered plan map, 1 character = 2x2 nodes. Row label `z` covers rows z and
z+1; columns start at x = -95, and `|` marks the column containing x = -80,
-60, ..., 80. `#` principal street, `=` secondary street (gravel), `Q`
square (forum, Jupiter forecourt), `.` graded open ground inside the
construction boundary, blank = outside the boundary (not graded). Capital
letters are landmarks, lower-case letters are ordinary blocks (keys below
and in section 10).

```
 109                                         ...............                                    
 107                                         ...............                                    
 105                                         ..AAAAAAAAAAA..                                    
 103                                         ..AAAAAAAAAAA..                                    
 101                                         ..AAAAAAAAAAA..                                    
  99                                         ..AAAAAAAAAAA..                                    
  97                                         ..AAAAAAAAAAA..                                    
  95                                         ..AAAAAAAAAAA..                                    
  93                                         ..AAAAAAAAAAA..                                    
  91                                         ..AAAAAAAAAAA..                                    
  89                                         ..AAAAAAAAAAA..                                    
  87                                         ..AAAAAAAAAAA..                                    
  85 ..........................................AAAAAAAAAAA......................................
  83 ..........................................AAAAAAAAAAA......................................
  81 ..........................................AAAAAAAAAAA......................................
  79 ..hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhAAAAAAAAAAAgggggggggggggggggggggggggggggggggggg..
  77 ..hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhQQQQQQQQQQQgggggggggggggggggggggggggggggggggggg..
  75 ..hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhQQQQQQQQQQQgggggggggggggggggggggggggggggggggggg..
  73 ..hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhQQQQQQQQQQQgggggggggggggggggggggggggggggggggggg..
  71 ..========================================QQQQQQQQQQQ====================================..
  69 ..=======================================================================================..
  67 ..=======================================================================================..
  65 ..TTTTTTTTTTTTTTTTTTT=======IIIIIIIIIIIIIIIIII###HHHHHHHHHHHHHHHHHH======================..
  63 ..TTTTTTTTTTTTTTTTTTT....===IIIIIIIIIIIIIIIIII###HHHHHHHHHHHHHHHHHH===.....................
  61 ..TTTTTTTTTTTTTTTTTTT....===IIIIIIIIIIIIIIIIII###HHHHHHHHHHHHHHHHHH===.....................
  59 ..TTTTTTTTTTTTTTTTTTT....===IIIIIIIIIIIIIIIIII###HHHHHHHHHHHHHHHHHH==KKKKKKKKKKKKKKKKKKKK..
  57 ..TTTTTTTTTTTTTTTTTTT....===IIIIIIIIIIIIIIIIII###HHHHHHHHHHHHHHHHHH==KKKKKKKKKKKKKKKKKKKK..
  55 ..TTTTTTTTTTTTTTTTTTT....===IIIIIIIIIIIIIIIIII###HHHHHHHHHHHHHHHHHH==KKKKKKKKKKKKKKKKKKKK..
  53 ..TTTTTTTTTTTTTTTTTTT....===IIIIIIIIIIIIIIIIII###HHHHHHHHHHHHHHHHHH==KKKKKKKKKKKKKKKKKKKK..
  51 ..TTTTTTTTTTTTTTTTTTT....===IIIIIIIIIIIIIIIIII###HHHHHHHHHHHHHHHHHH==KKKKKKKKKKKKKKKKKKKK..
  49 ..TTTTTTTTTTTTTTTTTTT....===IIIIIIIIIIIIIIIIII###HHHHHHHHHHHHHHHHHH==KKKKKKKKKKKKKKKKKKKK..
  47 ..TTTTTTTTTTTTTTTTTTT....===IIIIIIIIIIIIIIIIII###HHHHHHHHHHHHHHHHHH==KKKKKKKKKKKKKKKKKKKK..
  45 ..TTTTTTTTTTTTTTTTTTT....===IIIIIIIIIIIIIIIIII###HHHHHHHHHHHHHHHHHH==KKKKKKKKKKKKKKKKKKKK..
  43 ..TTTTTTTTTTTTTTTTTTT....===IIIIIIIIIIIIIIIIII###HHHHHHHHHHHHHHHHHH==KKKKKKKKKKKKKKKKKKKK..
  41 ..TTTTTTTTTTTTTTTTTTT....===IIIIIIIIIIIIIIIIII###HHHHHHHHHHHHHHHHHH==KKKKKKKKKKKKKKKKKKKK..
  39 .......pppp===NNNNNNNNNNNN==IIIIIIIIIIIIIIIIII###HHHHHHHHHHHHHHHHHH==KKKKKKKKKKKKKKKKKKKK..
  37 .......pppp===NNNNNNNNNNNN===============================================================..
  35 .......pppp===NNNNNNNNNNNN===============================================================..
  33 .......pppp===NNNNNNNNNNNN===============================================================..
  31 .......pppp===NNNNNNNNNNNN===kkkkkkkkkkkFFFFFF###EEEEEEfffffffffff===GGGGGGGGGGGGGGGrrrrr..
  29 .......pppp===NNNNNNNNNNNN===kkkkkkkkkkkFFFFFF###EEEEEEfffffffffff===GGGGGGGGGGGGGGGrrrrr..
  27 .......pppp===NNNNNNNNNNNN===kkkkkkkkkkkFFFFFF###EEEEEEfffffffffff===GGGGGGGGGGGGGGGrrrrr..
  25 .......pppp===NNNNNNNNNNNN===kkkkkkkkkkkFFFFFF###EEEEEEfffffffffff===GGGGGGGGGGGGGGGrrrrr..
  23 .......pppp===NNNNNNNNNNNN===llllkkkkkkkFFFFFF###EEEEEEfffffffmmmm===GGGGGGGGGGGGGGGrrrrr..
  21 .......pppp===NNNNNNNNNNNN===llll.......FFFFFF###EEEEEE.......mmmm===GGGGGGGGGGGGGGG.......
  19 .......pppp===NNNNNNNNNNNN===llll.......FFFFFF###EEEEEE.......mmmm===GGGGGGGGGGGGGGG.......
  17 .......pppp===NNNNNNNNNNNN===llll.......FFFFFF###EEEEEE.......mmmm===GGGGGGGGGGGGGGG.......
  15 .......pppp===NNNNNNNNNNNN===llll.......FFFFFF###EEEEEE.......mmmm===GGGGGGGGGGGGGGG.......
  13 .......pppp===NNNNNNNNNNNN===llll.......QQQQQQQQQQQQQQQ.......mmmm===GGGGGGGGGGGGGGG.......
  11 .......pppp===NNNNNNNNNNNN===eeeeeeeeeeeQQQQQQQQQQQQQQQaaaaaaaOOOOO==GGGGGGGGGGGGGGG.......
   9 .......pppp===NNNNNNNNNNNN===eeeeeeeeeeeQQQQQQQQQQQQQQQaaaaaaaOOOOO==GGGGGGGGGGGGGGG.......
   7 .......pppp===NNNNNNNNNNNN===eeeeeeeeeeeQQQQQQQQQQQQQQQaaaaaaaOOOOO==GGGGGGGGGGGGGGG.......
   5 ......DDDDD===NNNNNNNNNNNN===eeeeeeeeeeeQQQQQQQQQQQQQQQaaaaaaaOOOOO==GGGGGGGGGGGGGGGCCCCC..
   3 ......DDDDD===NNNNNNNNNNNN===eeeeeeeeeeeQQQQQQQQQQQQQQQaaaaaaaOOOOO==GGGGGGGGGGGGGGGCCCCC..
   1 ......DDDDD#############################QQQQQQQQQQQQQQQ############==###############CCCCC..
  -1 ......DDDDD#############################QQQQQQQQQQQQQQQ############==###############CCCCC..
  -3 ......DDDDD#############################QQQQQQQQQQQQQQQ############==###############CCCCC..
  -5 ......DDDDDdddddddddddddPPPPPPPPPPPcccccQQQQQQQQQQQQQQQLLLLLLLL...===MMMMMMMMMMMM===CCCCC..
  -7 ......DDDDDdddddddddddddPPPPPPPPPPPcccccQQQQQQQQQQQQQQQLLLLLLLL...===MMMMMMMMMMMM===CCCCC..
  -9 ..........ddddddddddddddPPPPPPPPPPPcccccQQQQQQQQQQQQQQQLLLLLLLL...===MMMMMMMMMMMM===ssss...
 -11 ..........ddddddddddddddPPPPPPPPPPPcccccQQQQQQQQQQQQQQQLLLLLLLL...===MMMMMMMMMMMM===ssss...
 -13 ..........ddddddddddddddPPPPPPPPPPPcccccQQQQQQQQQQQQQQQLLLLLLLL...===MMMMMMMMMMMM===ssss...
 -15 ........................PPPPPPPPPPP.....QQQQQQQQQQQQQQQLLLLLLLL...===MMMMMMMMMMMM===ssss...
 -17 ........................PPPPPPPPPPP...........###SSSSSSLLLLLLLL...===MMMMMMMMMMMM===ssss...
 -19 ..............................................###SSSSSSLLLLLLLL...===MMMMMMMMMMMM===ssss...
 -21 ..............................................###SSSSSSLLLLLLLL...===MMMMMMMMMMMM===ssss...
 -23 ..............................................###SSSSSSLLLLLLLL...===MMMMMMMMMMMM===ssss...
 -25 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###SSSSSSLLLLLLLL...===MMMMMMMMMMMM===ssss...
 -27 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###SSSSSSLLLLLLLL...===MMMMMMMMMMMM===ssss...
 -29 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###bbbbb.LLLLLLLL...===MMMMMMMMMMMM===ssss...
 -31 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###bbbbb.LLLLLLLL...===MMMMMMMMMMMM===ssss...
 -33 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###bbbbbjjjjjjjjjjjj===MMMMMMMMMMMM===ssss...
 -35 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###bbbbbjjjjjjjjjjjj===MMMMMMMMMMMM===ssss...
 -37 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###bbbbbjjjjjjjjjjjj===MMMMMMMMMMMM===ssss...
 -39 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###bbbbbjjjjjjjjjjjj===MMMMMMMMMMMM===ssss...
 -41 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###bbbbbjjjjjjjjjjjj===MMMMMMMMMMMM===ssss...
 -43 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###========================================..
 -45 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###========================================..
 -47 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###========================================..
 -49 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###JJJJJJJJJJJJJJJJJJ===iiiinnnnnnnnnnnnnnn..
 -51 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###JJJJJJJJJJJJJJJJJJ===iiiinnnnnnnnnnnnnnn..
 -53 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###JJJJJJJJJJJJJJJJJJ===iiiinnnnnnnnnnnnnnn..
 -55 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###JJJJJJJJJJJJJJJJJJ===iiiinnnnnnnnnnnnnnn..
 -57 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###JJJJJJJJJJJJJJJJJJ===iiiinnnnnnnnnnnnnnn..
 -59 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###JJJJJJJJJJJJJJJJJJ===iiii.................
 -61 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###JJJJJJJJJJJJJJJJJJ===iiii.................
 -63 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###JJJJJJJJJJJJJJJJJJ===iiii.................
 -65 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###JJJJJJJJJJJJJJJJJJ===iiii.................
 -67 ..RRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRRR###JJJJJJJJJJJJJJJJJJ===iiiiooooooooooooooo..
 -69 ..============================================###JJJJJJJJJJJJJJJJJJ===iiiiooooooooooooooo..
 -71 ..============================================###JJJJJJJJJJJJJJJJJJ===iiiiooooooooooooooo..
 -73 ..============================================###JJJJJJJJJJJJJJJJJJ===iiiiooooooooooooooo..
 -75 ..==========================================BBBBBBBJJJJJJJJJJJJJJJJ======================..
 -77 ..qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqBBBBBBB======================================..
 -79 ..qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqBBBBBBB======================================..
 -81 ..qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqBBBBBBB======================================..
 -83 ..qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqBBBBBBB........................................
 -85 ...........................................................................................
 -87 ...........................................................................................
            |         |         |         |         |         |         |         |         |   
x from -95 step 2; '|' marks multiples of 20
```

Key:

```
a = block east_forum_north	b = block south_east_inner	c = block west_forum_south
d = block west_end_south	e = block west_forum_north	f = block ring_north_inner_east
g = block outer_north_east	h = block outer_north_west	i = block ring_east_outer_south
j = block ring_south_inner_east	k = block ring_north_inner_west	l = block ring_west_inner_north
m = block ring_east_inner_north	n = block ring_south_outer_east	o = block ring_south_outer_inner_east
p = block west_outer_west	q = block south_west_outer	r = block east_amph_north
s = block east_outer_east	A = temple_of_jupiter	B = arch_south
C = arch_east	D = arch_west	E = temple_east
F = temple_west	G = amphitheater	H = insula_north_east
I = insula_north_west	J = insula_south	K = domus_1
L = basilica	M = domus_3	N = domus_4
O = vespasianum_east	P = theatre	R = bath
S = temple_of_vesta	T = hippodrome	
```

What changes, in one paragraph: the northern arch becomes Temple of
Jupiter on a cobbled forecourt, projecting north out of the main city
rectangle in its own compound. Vesta takes the forum's south edge just east
of the southern cardo. The hippodrome fills the empty north-west interior
between domus_4 and the outer northern road, with its portico opening onto
that road. The secondary roads are extended or added so that almost every
graded area outside the monuments is reachable from pavement: the outer
northern road runs across the whole town, the inner northern and both
southern roads run east to the main rectangle edge, and three short new
roads (north-west, south-west under the bath, south-east beside domus_3)
open the remaining corners. All other landmarks stay exactly where they are.

## 3. Main city rectangle, Jupiter compound and bounds

| item | rectangle (offsets) | size | notes |
| --- | --- | --- | --- |
| main city rectangle (authored, `main_rect`) | x -95..85, z -87..85 | 181 x 173 | Today's derived boundary is x -95..85, z -86..85; the only change is one row south (z -87) to keep the four-node apron under the new south-west block. |
| Jupiter compound (boundary rect 2) | x -14..13, z 80..110 | 28 x 31 | Jupiter's box grown by `margin` (4) on its west, east and north sides; overlaps the main rectangle in z 80..85, projects z 86..110. |
| `plan.boundary.rects` | main, compound | 32 013 columns | Grading/boundary membership is this union. |
| `plan.bounds` | x -95..85, z -87..110 | 181 x 198 | Enclosing rectangle of the union. 35 838 cells; using it as one boundary would grade 3 825 extra columns across the whole north edge, which the union avoids. |

Rules for #351: `main_rect` is authored in `src/roman_civic_plan.lua` and
translated with the centre; it is not derived from the sites. The planner
rejects the layout (layout_error) if any site other than a terminal
landmark, or any street or block, leaves `main_rect`. Each terminal
landmark adds one compound rectangle as above. `plan.bounds` is the
enclosing rectangle of all boundary rectangles. `margin` stays 4 and keeps
its other use (the compound apron).

## 4. Roads

All secondary roads are 6 wide, `mcl_core:gravel`, in the existing `bands`
schema (`arm`, `from..to` outward from the forum edge, `span` across).
Principal streets keep their cobble and slab lane.

| street | rect | change |
| --- | --- | --- |
| cardo_north | x -3..2, z 15..71 | length 59 -> 57 (ends where the forecourt starts); lane x -2..1, z 15..70 by the existing length-2 rule |
| cardo_south | x -3..2, z -74..-16 | unchanged |
| decumanus_east | x 15..73, z -3..2 | unchanged |
| decumanus_west | x -74..-16, z -3..2 | unchanged |
| ring_north (band north, 18..23) | x -44..81, z 33..38 | span -44..43 -> -44..81: east past ring_east, between the amphitheater (z <= 31) and domus_1 (z >= 39) |
| ring_north_outer (north_outer, 51..56) | x -91..81, z 66..71 | span -44..43 -> -91..81: west to x -91 (since #365 the hippodrome's west edge is x -87, so this runs 4 nodes past it), east to x 81 north of domus_1 |
| ring_south (south, 26..31) | x 3..81, z -47..-42 | span 3..37 -> 3..81: crosses ring_east |
| ring_south_outer (south_outer, 59..64) | x 6..81, z -80..-75 | span 6..37 -> 6..81 |
| ring_east (east, 23..28) | x 38..43, z -80..71 | unchanged |
| ring_west (west, 23..28) | x -44..-39, z 3..71 | unchanged |
| ring_west_outer (new band west_outer: arm west, 51..56, span 3..40) | x -72..-67, z 3..40 | new: T off the western decumanus, ends against the hippodrome's south side. It stops at z 40 and does not reach ring_north_outer (z 66..71); the hippodrome footprint (z 41..65) lies between them. Since #365 its x range contains the hippodrome entrance (-69, 62) and approach (-69, 66) |
| ring_south_west (new band south_west: arm south, 53..58, span -91..-4) | x -91..-4, z -74..-69 | new: T off the southern cardo's west side, under the bath (2 rows of grass, z -68..-67, between road and bath) |
| ring_east_outer (new band east_outer: arm east, 51..56, span -41..-4) | x 66..71, z -41..-4 | new: links the eastern decumanus to ring_south beside domus_3 (replaces block east_end_south) |

Connectivity: every new or extended road touches an existing street
(authored validation's single connected-pavement check passes; verified).
No road crosses the bath, a landmark, the forum or the forecourt.
Band list order for #353: keep the existing six in their current order and
append west_outer, south_west, east_outer (street ids, and so frontage ids
and seeded packing, depend on that order; the counts in section 12 use it).

## 5. Landmark placement table

All sites. Unchanged rows are listed so the table is complete; "new" and
"moved" rows are the work.

| site | catalog id | mechanism (layout entry) | rotation | rect | approach | status |
| --- | --- | --- | --- | --- | --- | --- |
| forum | square | forum_size 30 | - | x -15..14, z -15..14 | (0,0) | unchanged |
| jupiter_forecourt | square, cobble | terminal forecourt, north arm | - | x -10..9, z 72..79 (20 x 8) | (-1,72) | new (#351) |
| temple_of_jupiter | temple_of_jupiter | terminal landmark, north arm | 0 | x -10..9, z 80..106 (20 x 27) | (-1,79) on forecourt | new (#351), replaces arch_north |
| arch_south / arch_east / arch_west | arch | arm arch | 180 / 90 / 270 | x -6..5, z -82..-75 / x 74..81, z -6..5 / x -82..-75, z -6..5 | (0,-74) / (73,0) / (-74,-1) | unchanged |
| temple_east, temple_west | temple | arm north, +x / -x, at 0, faces forum | 270 | x 3..14 / -15..-4, z 15..32 | (9,14) / (-9,14) | unchanged |
| temple_of_vesta | temple_of_vesta | existing arm landmark: arm south, side +x, at 0, faces forum | 180 | x 3..13, z -26..-16 (11 x 11) | (8,-15) on forum | new (#352) |
| hippodrome | hippodrome | existing ring landmark: ring north_outer, side inner, at -87 (was -91 before #365) | 180 | x -87..-51, z 41..65 (37 x 25) | (-69,66) on ring_north_outer | new (#353); moved 4 east (#365) |
| amphitheater | amphitheater | arm east +z at 29 | 0 | x 44..72, z 3..31 | (59,2) | unchanged |
| insula_north_east / _north_west / _south | insula | ring north outer at 3 / -38; ring south outer at 3 | 0 / 0 / 180 | x 3..37 / -38..-4, z 39..65; x 3..37, z -74..-48 | (20,38) / (-21,38) / (20,-47) | unchanged |
| domus_1 | domus | ring east outer at 39 | 0 | x 44..81, z 39..60 | (43,48) | unchanged |
| basilica | basilica | arm east -z at 0 | 270 | x 15..30, z -31..-4 | (23,-3) | unchanged |
| domus_3 | domus | arm east -z at 29 | 90 | x 44..65, z -41..-4 | (53,-3) | unchanged |
| domus_4 | domus | arm west +z at 29 | 270 | x -66..-45, z 3..40 | (-54,2) | unchanged |
| vespasianum_east | vespasianum | arm east +z at 15 | 270 | x 30..37, z 3..12 | (34,2) | unchanged |
| theatre | theatre | arm west -z at 10 | 180 | x -46..-26, z -17..-4 | (-36,-3) | unchanged |
| bath | bath | arm south -x at 8 | 180 | x -91..-4, z -66..-24 | (-3,-44) | unchanged (see section 14) |
| roman_fountain (object) | roman_fountain | planner.lua, forum centre | 0 | x -3..1, z -3..1 | - | unchanged |

Non-overlap of all landmark, square, street and block rectangles was
checked by `authored_plan.validate` on the prototype at (0,0) and (777,-333)
and over the seed sweep.

### 5.1 New landmarks in detail

| | Jupiter | Vesta | hippodrome |
| --- | --- | --- | --- |
| catalog size (x, y, z) | 20 x 15 x 27 | 11 x 11 x 11 | 37 x 22 x 25 |
| ground_offset (file y of the site-ground row) | 1 (clay row; podium at y 2) | 0 (orange clay row) | 7 (grass/stone row; 7 buried rows below) |
| main entrance, file-local (x, y, z), facing | (9, 3, 8), -Z: the cella's south double door (spruce, x 9..10) | (5, 2, 3), -Z: the one-node gap in the cella wall at file z 3 (the -Z side, which the import notes call the north wall), the only opening into the cella | (18, 8, 3), -Z: the central gap of the arcade on the long file -Z side (north-facing once rotated), behind the projecting portico (catalog correction, section 6) |
| entrance kind | door | opening | opening |
| rotation | 0 (front -z, toward the forum) | 180 (front +z, toward the forum) | 180 (front +z, toward ring_north_outer) |
| rotated footprint | x -10..9, z 80..106 | x 3..13, z -26..-16 | x -87..-51, z 41..65 (pre-#365: x -91..-55) |
| rotated entrance (plan) | (-1, 88); door spans x -1..0, centred on the cardo axis | (8, -19) | (-69, 62) (pre-#365: (-73, 62)) |
| recess (entrance to box edge) | 8 nodes (front colonnade) | 3 nodes (step ring + colonnade) | 3 nodes (portico) |
| first approach node outside footprint | (-1, 79), forecourt | (8, -15), forum | (-69, 66), ring_north_outer |
| walkable route, entrance to approach | podium stair row (file z 0, y 2) then quartz podium floor z 1..7 at y 2, door at z 8: 9 steps, one half-step up | quartz slab step ring (file z 0..1, y 1), quartz floor z 2, opening z 3: 4 steps | stone portico floor at site-ground level (file x 14..22, z 0..2, y 7) between the diorite columns at x 17 and 19, through the central gap of the z 3 arcade: 4 level steps |

Route evidence (verified, not just a 2D approach check):

- The `.mts` files were decoded with `tests/mts_reader.lua` and each route
  was walked node by node: feet and head cells passable (air, doors), floor
  solid, rises of at most one node.
- The same entrances were run through the builder's own 3D route check
  (`builder.check_door`, the function `build_town` calls on every placed
  building), using the harness of `tests/town_build_tests.lua` `route()`
  with the real schematics, at all four rotations. Results (steps from the
  outside approach to the entrance): Jupiter 9, Vesta 4, hippodrome (18,8,3)
  4, at every rotation.

Other sides (no extra paving or validation rules; checked that no new plot
obstructs them):

- Jupiter: podium stairs on all four sides. The west and east sides face the
  compound apron (x -14..-11 and 10..13, open ground continuous with the main
  rectangle's northern apron z 81..85). The rear door (file (9,3,18), +Z,
  world (-1,98)) opens onto the rear porch and the compound's northern apron
  z 107..110. The outer_north blocks touch Jupiter only along row z 80.
- Vesta: the step ring runs all round. West side faces the cardo pavement
  (x 2); east side keeps a one-node strip (x 14) to the basilica's blank
  west wall; south side abuts block south_east_inner (z -27). Vesta has no
  other opening, so nothing is enclosed.
- Hippodrome (world x values since #365, when the footprint moved from
  x -91..-55 to x -87..-51; the pre-#365 value is in brackets): the two
  short-end doors (file (2,8,7) and (2,8,19), facing -X) turn to +x at
  rotation 180: world (-53,58) and (-53,46) [(-57,58), (-57,46)]. They open
  into a deliberately unbuilt court x -50..-45, z 41..65 (6 x 25) [x -54..-45,
  10 x 25] that reaches ring_west at x -44; the former block
  ring_west_outer_north is removed for this. The file +Z side faces south at
  world z 41: its entrance-hall arcade (gaps at file x 15, 16, 18, 20, 21 on
  z 23; world x -66..-72 [-70..-76]) faces the head of the new ring_west_outer
  road (x -72..-67, ends z 40), and the paddock gate (acacia fence gates at
  file (32..33, 8, 24) between fence posts at x 31 and 34, with a sign and
  glow frame at x 25; world x -85..-82 and -76 [-89..-86 and -80]) opens onto
  the open strip x -91..-82 between the hippodrome and block p. The file east
  end (world west end, x -87 [-91], doors at file x 35) faces the western
  apron; the former west strip x -91..-88 is now open (see section 9).
  The entrance-hall gaps at world x -67, -69, -71 and -72 now sit over the
  road head; the gap at x -66 is just east of it.

## 6. Hippodrome catalog correction (prerequisite ticket before #353)

Finding from the model (not from the import notes): on the long -Z side
the real wall is the clay wall at file z 6 behind the stands (at y 8 it is
open only at x 0, 1, 3, 34, 35). In front of it, the z 3 line is an open
pillar-and-parapet arcade, not a wall: at y 8..9 it has gaps at x 1, 3, 4,
6, 7, 15, 16, 18, 20, 21, 29, 30, 32, 33, 35. The only part that extends
outward beyond that arcade is the portico at x 14..22, z 0..2: stone floor
at site-ground level (y 7), four diorite columns at (15|17|19|21, 8..10, 1)
under a diorite lintel at y 11 and a pediment to y 13. Within the portico
span the arcade gaps are x 15, 16, 18, 20, 21; the central one, x 18, lines
up with the stair (18,8,5)-(18,9,6), which rises through the z 6 wall into
the stands. The long +Z side has only a one-row colonnade at z 24
(x 15..21) and the paddock gate (section 5.1), no projecting portico. So
the main entrance is (18, 8, 3), facing -Z: the central arcade gap behind
the portico, an opening (air at (18,8,3) and (18,9,3), stone floor at
(18,7,3)), aligned with the stair.

Change (catalog/test only; the model is not edited):

| file | change |
| --- | --- |
| `schematics/imports/roman/catalog.lua` | hippodrome `entrance = {x = 18, y = 8, z = 3}` (facing omitted = -Z), `entrance_kind = "opening"`; size and `ground_offset = 7` unchanged |
| `tests/roman_catalog_tests.lua` | fixture `hippodrome = {{37,22,25}, 8, 7, {{18,3},{3,18},{18,21},{21,18}}, 1}` (rotated entrances at 0/90/180/270; front index 1 = -Z) |
| `schematics/imports/roman/README.md` | generator-metadata row: entrance 18,8,3, facing -Z, evidence as above; note the short-end doors (2,8,7) and (2,8,19) are secondary |

Consumers checked: `src/catalog.lua` (snapshot copies entrance and
facing; verify() reads sizes), `src/geometry.lua` (default -Z facing),
`authored_plan.landmark_site`/`validate` (approach projection; nothing
places the hippodrome yet), `preflight.compose` (entrance from geometry),
`tests/roman_catalog_tests.lua` (door-or-opening check takes the opening
branch: feet and head air, floor solid), `tests/town_build_tests.lua`
(routes the hippodrome at all rotations via `check_door`; passes, 4 steps,
verified with the same harness), `tools/roman_check/init.lua` (opening
check and straight outward approach to site ground: the cells
(18, z 2..0) have stone at y 7 and air at y 8..9, then site ground; I
expect it to pass but did not run the engine), `tests/roman_check_expect_tests.lua`
(node names only, unaffected), `manifest.json`, `tools/issue139_import`,
`tools/issue341_import` (no entrance data). No other consumer.

## 7. Hippodrome excavation and foundation

- Lowest occupied level: file y 0, a solid hardened-clay layer over all
  925 columns. The passage and chambers occupy y 2..6 (lowest air at
  y 2, quartz floor at y 1); 83 buried non-solid cells, none on the
  footprint edge, so the basement is sealed against the surrounding ground.
- Placed at origin y = ground - 7, so it digs seven rows below the town
  grade (the bath digs 2, soup_shop 3, tavern_2 2).
- Existing support is sufficient; no new mechanism: `site_search` and
  `preflight.compose` include every foundation (ground - ground_offset) in
  the build bounds (prototype: lowest foundation = ground - 7, the
  hippodrome), the builder's write bounds extend to them, and the schematic
  is placed with force placement, so the capture's own 7 buried rows replace
  the terrain inside its box. `town_layout` grades only the surface and 3
  support rows, which is right: the landmark owns its box. Nothing below
  y 0 is written (as for every building).
- Not verified in engine for a whole town build at ground_offset 7 (the
  `roman_check` disposable-world check already places the hippodrome at
  every rotation at ground - 7). #353 should do one in-game build and look
  at the passage.
- Ground materials kept: grass/gravel/stone rows are the model's; the
  portico floor meets the gravel road directly, so no extra paving.

## 8. Vesta: forum-edge survey

All four forum edges, measured on `origin/main` (forum x -15..14,
z -15..14):

| edge | stretch | occupant | free depth outward | fits 11 x 11 with entrance on the forum? |
| --- | --- | --- | --- | --- |
| north | x -15..-4 / -3..2 / 3..14 | temple_west / cardo mouth / temple_east | 0 | no (protected temples, vista) |
| south | x -15..-4 | open pocket to the bath (z -23..-16) | 8 | no: 8 < 11 (would need the bath moved) |
| south | x -3..2 | cardo_south mouth | - | no (principal street) |
| south | x 3..11 | block south_east_inner (forum run 9) | 26 to ring_south | yes, replacing ordinary frontage |
| south | x 12..14 | 3-node strip west of the basilica | - | no |
| east | z -15..-4 | basilica | 0 | no (protected) |
| east | z -3..2 | decumanus_east mouth | - | no |
| east | z 3..11 | block east_forum_north | 15 (to the vespasianum at x 30) | yes, but it removes the whole block (forum 9 + decumanus 15) |
| east | z 12..14 | open, 3 rows | - | entrance row would be off the forum (z >= 15) |
| west | z -15..-13 | open, 3 rows | - | no |
| west | z -12..-4 | block west_forum_south (10 deep to the theatre) | 10 | no: 10 < 11 |
| west | z -3..2 | decumanus_west mouth | - | no |
| west | z 3..11 | block west_forum_north | 23 (to ring_west) | yes, replacing 11 of 23 decumanus nodes and the forum run |

Chosen: south edge, east of the cardo. Arm landmark `arm = "south", side =
"+x", at = 0, rotation = 180, faces = "forum"`, exactly the temples'
mechanism, so #352 needs no schema extension. Box x 3..13, z -26..-16,
flush with the cardo (west) and the forum edge (north); its entrance
(8,-19) opens north onto the forum at (8,-15). The fountain (x -3..1,
z -3..1), the cardo mouth (x -3..2), the basilica (x 15..30, one-node gap)
and the north vista (cardo_north to Jupiter) are untouched; the round temple
answers the two temples on the opposite edge.

Recorded frontage change: block south_east_inner shrinks from x 3..11,
z -41..-16 (arm south +x 0..25) to x 3..11, z -41..-27 (arm south +x
11..25). It loses its forum run (9) and 11 nodes of its cardo run; it keeps
cardo 15 and ring_south 9. This block held the tavern on `origin/main`;
the reservations move elsewhere with no shortage (section 12).

## 9. The two original gaps, the corners and what stays open

Road objective (PM, #353): roads should make essentially the whole graded
plot buildable and reachable; they need not follow a pattern. Measured
(prototype, `unused.lua`) inside the main rectangle less its 4-node apron: ground that is neither
street, square, landmark nor block falls from 9 344 of 28 372 cells
(32.9 %) on `origin/main` to 3 483 of 28 545 (12.2 %). What remains is
listed here with the reason.

Original gap 1, behind the basilica (re-measured). Bounded by the basilica
(x 15..30, z -31..-4), ring_south (z -47..-42), ring_east (x 38..43) and
block south_east_inner (x 3..11). Free ground: x 12..37, z -41..-32
(26 x 10) behind it, plus x 31..37, z -32..-4 (7 x 29) east of it and
x 12..14 (3 wide) west of it. Pavement access: ring_south (south) and
ring_east (east). Disposition: ordinary block j `ring_south_inner_east`,
x 12..37, z -41..-33 (26 x 9, runs ring_south 26 + ring_east 9). The 7-wide
strip east of the basilica stays open: a block there fails validation
(`frontage ... block is shallower than the row depth`, tried) because its
ring_east face is only 7 deep. Justified open area (the basilica's blank
east side and service yard).

Original gap 2, beside the western temple (re-measured). Bounded by
temple_west (x -15..-4, z 15..32), ring_north (z 33..38), ring_west
(x -44..-39) and block west_forum_north (z 3..11). Free ground x -38..-16,
z 12..32 (23 x 21). Access: ring_north and ring_west. Disposition: block k
`ring_north_inner_west` x -38..-16, z 24..32 (23 x 9; runs ring_north 23 +
ring_west 9), mirroring ring_north_inner_east; block l
`ring_west_inner_north` x -38..-30, z 12..23 (9 x 12; ring_west 12). The
remaining x -29..-16, z 12..23 (14 x 12) is enclosed by the two blocks, the
temple's blank side and west_forum_north: a deliberate back court, too
shallow for a second row and with no street edge. The east side gets the
same treatment: block m `ring_east_inner_north` x 29..37, z 13..23
(ring_east 11), court x 15..28, z 12..23.

Corners and outer areas:

| area | disposition |
| --- | --- |
| north-west interior (x -91..-45, z 41..65) | hippodrome at x -87..-51 (since #365; was -91..-55), plus its door court x -50..-45 (was -54..-45). Former west strip x -91..-88, z 41..65 (4 x 25) is open ground inside `main_rect`: it joins the existing open x -95..-92, so x -95..-88 is one 8-wide open strip, left unbuilt (no road or block was planned there; packing and eligibility are unchanged). `layout_compare` counts these cells as narrow strip cells. The 6-wide court is narrow too, and stays unbuilt by design |
| north-west pocket west of domus_4 (x -91..-67, z 6..40) | new road ring_west_outer + block p x -81..-73, z 6..40; x -91..-82 (10 wide incl. apron) open |
| north strip beyond ring_north_outer (z 72..80) | blocks h and g across the whole width, broken only by the forecourt |
| south-west under the bath (x -91..-7, z -86..-67) | new road ring_south_west + block q x -91..-7, z -83..-75 |
| south-east (x 53..81, z -74..-42) | ring_south and ring_south_outer extended; blocks n and o; the 9-row court x 53..81, z -65..-57 between their backs is open (no street edge; adding a crossing road gains about 6 frontage nodes) |
| east of domus_3 (x 66..81, z -41..-4) | new road ring_east_outer + block s x 72..80, z -41..-7 |
| east of the amphitheater (x 73..81, z 6..32) | ring_north extended east + block r x 73..81, z 24..32; x 73..81, z 6..23 open (9 wide, only reachable through r's back) |
| north of domus_1 (x 44..81, z 61..65) | 5 rows, too shallow; open |
| north of the bath, behind theatre and west_end_south (x -91..-26, z -23..-13) and the pocket x -15..-4, z -23..-16 | open: a road here would be flush with the bath's north wall and leaves at most 5 rows for blocks |
| between road and bath (z -68..-67) | 2 rows of grass |
| 4-node apron inside every boundary edge, Jupiter compound apron | open, as today (grading transition) |

## 10. Ordinary blocks

Current schema (`blocks`, arm or ring form), all nine deep (D = 9; every
run's block depth checked by `authored_plan.validate` with
`min_block_depth`). Depth is sufficient: the packer places the 9-deep and
shallower catalog buildings (corner_house, demo_house, butcher_shop,
leather_worker, mason_yard, soup_shop, blacksmith); deeper ones (library,
banker_house, scribe, gaboo_house, office_building, armory) never fit a
9-deep block, today or after. Making blocks deeper would be a schema change
(the planner derives block depth from the catalog) and is not proposed.

| key | block | layout entry | rect | runs (side: length, surface) | ticket |
| --- | --- | --- | --- | --- | --- |
| a | east_forum_north | arm east +z 0..14 | x 15..29, z 3..11 | -z 15 decumanus_east; -x 9 forum | unchanged |
| b | south_east_inner | arm south +x 11..25 (was 0..25) | x 3..11, z -41..-27 | -z 9 ring_south; -x 15 cardo_south | #352 |
| c | west_forum_south | arm west -z 0..9 | x -25..-16, z -12..-4 | +z 10; +x 9 forum | unchanged |
| d | west_end_south | arm west -z 31..58 | x -74..-47, z -12..-4 | +z 28 decumanus_west | unchanged |
| e | west_forum_north | arm west +z 0..22 | x -38..-16, z 3..11 | -z 23; -x 9 ring_west; +x 9 forum | unchanged |
| f | ring_north_inner_east | ring north inner 15..37 | x 15..37, z 24..32 | +z 23 ring_north; +x 9 ring_east | unchanged |
| g | outer_north_east | ring north_outer outer 10..81 (was 6..43) | x 10..81, z 72..80 | -z 72 ring_north_outer; -x 8 forecourt | #351 trims to 10..43, #354 extends to 81 |
| h | outer_north_west | ring north_outer outer -91..-11 (was -44..-7) | x -91..-11, z 72..80 | -z 81; +x 8 forecourt | #351 trims to -44..-11, #354 extends to -91 |
| i | ring_east_outer_south | ring east outer -74..-48 (was -80..-42) | x 44..52, z -74..-48 | -z 9 ring_south_outer; +z 9 ring_south; -x 27 ring_east | #353 |
| j | ring_south_inner_east | ring south inner 12..37 | x 12..37, z -41..-33 | -z 26; +x 9 ring_east | #354 (gap 1) |
| k | ring_north_inner_west | ring north inner -38..-16 | x -38..-16, z 24..32 | +z 23; -x 9 ring_west | #354 (gap 2) |
| l | ring_west_inner_north | ring west inner 12..23 | x -38..-30, z 12..23 | -x 12 ring_west | #354 (gap 2) |
| m | ring_east_inner_north | ring east inner 13..23 | x 29..37, z 13..23 | +x 11 ring_east | #354 |
| n | ring_south_outer_east | ring south outer 53..81 | x 53..81, z -56..-48 | +z 29 ring_south | #354 |
| o | ring_south_outer_inner_east | ring south_outer inner 53..81 | x 53..81, z -74..-66 | -z 29 ring_south_outer | #354 |
| p | west_outer_west | ring west_outer outer 6..40 | x -81..-73, z 6..40 | +x 35 ring_west_outer | #354 |
| q | south_west_outer | ring south_west outer -91..-7 | x -91..-7, z -83..-75 | +z 85 ring_south_west | #354 |
| r | east_amph_north | ring north inner 73..81 | x 73..81, z 24..32 | +z 9 ring_north | #354 |
| s | east_outer_east | ring east_outer outer -41..-7 | x 72..80, z -41..-7 | -z 9 ring_south; -x 35 ring_east_outer | #354 |

Removed: west_end_north (under ring_west_outer, #353), east_end_south (under
ring_east_outer, #353), ring_west_outer_north (hippodrome and its door court,
#353). Block order for #354: existing blocks in their current order, then
j..s in the order above (packing is seeded per run id).

## 11. Schema extensions

Only two, both for #351. Vesta and the hippodrome use existing mechanisms.

1. Terminal landmark per arm. An arm may give `terminal` instead of
   `arch`/`arch_rotation`:
   `north = {street = "cardo_north", length = 57, profile = "lane",
   terminal = {name = "temple_of_jupiter", id = "temple_of_jupiter",
   rotation = 0, forecourt = {name = "jupiter_forecourt", depth = 8}}}`.
   The forecourt is a square site (`kind = "square"`, `forum_material`),
   `depth` nodes from the street end (arm positions length..length+depth-1)
   and as wide as the landmark, centred on the street like the arch; its
   approach is the street-side centre node, (-1,72). The landmark box
   follows (arm positions length+depth onward), centred the same way (even
   width required, as for the arch), entrance checked to face the forum by
   the existing `landmark()` rule, site field `terminal = true`. The
   landmark's compound rectangle is its box grown by `margin` on the three
   sides away from the forum. The other three arms keep their arches.
   A second named square is already supported by every consumer
   (the medieval parvis is the precedent: `derive_frontage` square
   precedence, `town_layout` square paving, content packing of square runs
   first, `open_space`).
2. Authored main rectangle. `main_rect = {x1 = -95, z1 = -87, x2 = 85,
   z2 = 85}`; `boundary.rects = {main_rect, compounds...}`; `plan.bounds`
   = their enclosing rectangle; layout_error if a non-terminal site, street
   or block leaves main_rect. Replaces "bounding box of the sites plus
   margin" for the boundary.

The prototype implementation of both is about 45 lines in
`roman_planner.lua` `M.build` (arm loop and bounds section).

## 12. Population: measured counts and the minimum

Prototype runs of the full planner (`planner.plan(..., {town_type = "roman"})`:
authored validation, jail, services, content packing, open space) and
`tools/layout_compare --town-type=roman`, seeds 1, 2, 3, 7 at the
round-robin centres (0,0), (1500,-2500), (-4200,3100), (0,0). Plans are
translation invariant; a fifth centre (777,-333) gave identical counts.

| seed | ordinary before (house/shop/workshop) | after | jail block before -> after | services | shortages |
| --- | --- | --- | --- | --- | --- |
| 1 | 21 (8/8/5) | 56 (28/13/15) | ring_east_outer_south -> south_west_outer | 3 taverns + 3 wells, both | 0 / 0 |
| 2 | 23 (7/8/8) | 56 (19/19/18) | same | same | 0 / 0 |
| 3 | 24 (10/6/8) | 56 (29/12/15) | same | same | 0 / 0 |
| 7 | 23 (11/9/3) | 56 (23/13/20) | same | same | 0 / 0 |
| total | 91 (36/31/24) | 224 (99/57/68) | | | |

(Roman plans have no chapel, cathedral or city hall; the service targets
are the shared tavern/well ones.)

Where each number comes from. The per-seed table and the frontage, street,
boundary and bounds figures are in the committed `layout_compare` output
(`roman_expansion_221/proposed_metrics.tsv`, `current_metrics.tsv`). The
seeds 1..100 statistics, the per-district and per-stage counts, the bed
estimate and the unused-ground figures of section 9 are prototype results:
they come from the scripts and stage layouts in
`roman_expansion_221/prototype/` (see its README), and their raw outputs
are committed in `prototype/results/` (`res_0_current.txt` on `origin/main`,
`res_1`..`res_4` after #351..#354). They are reproducible from those files
but are not produced by any tool in `tools/`.

Seeds 1..100 over four centres (prototype): before min 20, max 24, mean
22.7; after min 55, max 61, mean 56.9; no planning failure, no shortage, a
jail in every plan, and every block receives at least one building or
reservation in every plan.

Other metrics (after vs before, `layout_compare`): frontage 660 vs 313
nodes, used 389..402 vs 152..168; boundary columns 32 013 vs 31 132;
`plan.bounds` 181 x 198 vs 181 x 172; site-search reach (max_radius =
320 + edge - 48, edge = farthest bounds edge from the centre) 382 vs 367.
Street length 1019 vs 658 (secondary 785 vs 422, principal 234 vs 236).
That is `layout_compare`'s convention: unique paved cells of each street
class divided by the street width (6), so a junction cell counts once and
a cell under both a principal and a secondary street counts as principal.
The sum of the long sides of the street rectangles (`street_rect_run_sum`,
which double-counts every crossing) is larger: 839 vs 464 for the
secondary roads alone, 1073 vs 700 for all streets.

Bed estimate (prototype): bed-bottom nodes in the placed ordinary
templates, an upper bound on resident beds: 257 vs 92 over the four seeds;
landmark beds unchanged at 99 per town (Jupiter, Vesta and the hippodrome
have none).

Per district, buildings per seed 1/2/3/7 (prototype, after): a 1/1/1/1,
b 1/1/1/1, c 1/1/1/1, d 3/3/3/3, e 2/2/1/2, f 1/1/1/1, g 9/8/8/8,
h 9/9/10/10, i 3/3/1/1, j 1/3/3/3, k 1/1/1/1, l 1/1/1/1, m 1/1/1/1,
n 2/3/3/3, o 3/3/2/2, p 4/4/4/4, q 8/8/9/8, r 1/1/1/1, s 4/2/4/4. Blocks
f, j, k often hold a tavern instead of houses.

Per stage (prototype; seeds 1/2/3/7 total, then seeds 1..100 min..max), so
a reviewer can tell expected dips from regressions: origin/main 91
(20..24); after #351 81 (19..23; the forecourt trims g and h); after #352
76 (18..21; Vesta takes b's forum end); after #353 52 (11..15; roads and
the hippodrome remove three blocks and trim i; new plots come in #354);
after #354 224 (55..61). Shortages stay 0 at every stage.

After #365 (hippodrome 4 nodes east; no packing, clearance or eligibility
change): measured `tools/layout_compare` roman, seeds 1/2/3/7, 56 per seed and
224 in total, the same as before the move. The per-district counts of the
real planner are unchanged for every block (the prototype per-district list
above is the pre-#365 prototype figure and is not re-measured). The
narrow-strip metric rises by one strip and 250 cells per seed: the freed
west strip (100 cells) and the narrower court (150 cells).

Proposed minimum for #354: at least 50 ordinary buildings at each of seeds
1, 2, 3 and 7, at least 210 in total, and at least one building or
reservation in every block listed in section 10 at each of those seeds.
That is 2.3 times today, leaves about 10 % slack below the measured 56 per
seed for ordering differences in the real implementation, and is below the
worst of 100 prototype seeds (55).

Limits of the estimates: planner-level only (no engine build); the packer
is seeded per frontage run id, so a different street or block order changes
individual counts by a few; the bed figure is an upper bound (the resident
adapter can skip beds); terrain rejections from the larger footprint in site
search are not estimated.

## 13. Boundary consumers: union membership vs enclosing bounds

Verified by reading each consumer and by running the prototype plan
through it where it is pure Lua.

| consumer | what it uses | proposed change |
| --- | --- | --- |
| `authored_plan.validate` | union (`contains` over `boundary.rects`) for sites, pavement, blocks; `bounds` as enclosing check | none |
| `town_layout` (grading) | union of rects; `in_town` | none (prototype: 32 013 columns) |
| `builder` | read phase over the union; writes confined to `in_town`; `build_bounds` X/Z must equal `plan.bounds` (read/emerge box) | none |
| `city_margins` | passes every rect to Living Villages `boundary_volume`/`smooth_boundary` (the medieval 3-rect union is the precedent) | none |
| `site_search` | inspects `boundary_columns(rects)` (union); emerge/inspection volume, player-inside test and reach use `plan.bounds` | none; reach grows 367 -> 382 |
| `preflight.compose` | structure rects inside `plan.bounds` | none (prototype composes; lowest foundation is the hippodrome at ground - 7) |
| `outskirts` | protected area = `plan.bounds` + margin | none; conservative: the ungraded corners of the bounds north of z 85 also stay free of outskirts plots |
| `open_space` | free ground painted from the union, indexed by `bounds` | none |
| generation/reporting (`generate.lua`, `generate_command.lua`) | bounds strings; wall code is medieval-only | none |
| `tools/layout_compare` | paints the union, width/depth from `bounds` | none |
| `tests/outskirts_contract_tests.lua`, `tests/outskirts_fixture.lua` | pinned Roman `plan.bounds` and accepted outskirts plots at one centre | see 13.1 |
| `tests/roman_plan_tests.lua`, `tests/roman_population_tests.lua` | many literal pins of the current layout | see 13.1 |

### 13.1 Test pins that must change, by ticket

Line numbers re-checked against `origin/main` 0dc6495. Each ticket updates
the pins its own change breaks; the values are the ones of this document.

| file:line | pin today | ticket and new expectation |
| --- | --- | --- |
| `tests/roman_plan_tests.lua:43`, `:48` | template census `arch = 4`, nine templates (`n == 9`) | #351 arch 3, add temple_of_jupiter 1, ten templates; #352 add temple_of_vesta, eleven; #353 add hippodrome, twelve |
| `tests/roman_plan_tests.lua:49` | `#plan.site_order == 18` | #351 19 (forecourt square + Jupiter replace arch_north); #352 20; #353 21 |
| `tests/roman_population_tests.lua:94` | `#plan.site_order == 18` per seed | same as the line above, in #351/#352/#353 |
| `tests/roman_plan_tests.lua:86-91` | every site inside `boundary.rects[1]` | #351: inside the union of `boundary.rects` (Jupiter is only in rect 2); optionally every non-terminal site inside rect 1 (main) |
| `tests/roman_plan_tests.lua:97` | `#plan.streets == 10` | #353: 13 (four arms, nine bands) |
| `tests/roman_plan_tests.lua:121-130` | `crossings` / `abutments` tables | #353, computed on the prototype with the test's own `overlap`/`abuts`: crossings = the seven of today plus ring_south/ring_east and ring_south_outer/ring_east (both move out of `abutments`); abutments = cardo_south/ring_south, decumanus_west/ring_west (today) plus cardo_south/ring_south_west, decumanus_west/ring_west_outer, decumanus_east/ring_east_outer, ring_south/ring_east_outer. No other pair touches |
| `tests/roman_plan_tests.lua:149-163` | literal band pins, e.g. north_outer -44..43 | #353: north -44,33,81,38; north_outer -91,66,81,71; south 3,-47,81,-42; south_outer 6,-80,81,-75; east and west unchanged; add west_outer -72,3,-67,40, south_west -91,-74,-4,-69, east_outer 66,-41,71,-4 |
| `tests/roman_plan_tests.lua:188-196` | bath loop: every ring street 3 nodes clear of the bath, and "outside the south-west quadrant" | #353: rewrite, not just renumber. ring_south_west (x2 -4, z2 -69) is deliberately in the south-west quadrant, 2 rows south of the bath. Keep the quadrant and clearance checks for the other bands; for ring_south_west assert no overlap with the bath, a gap of exactly 2 rows (z2 = bath.z1 - 3), and that it does not reach the bath's east (door) face |
| `tests/roman_plan_tests.lua:219-222` | every arm street is 59 long | #351: cardo_north 57, the other three 59 |
| `tests/roman_plan_tests.lua:249-266` | per-arm arch test via `plan.sites[layout.arms[arm].arch]` | #351: skip arms with a terminal (nil arch) and add the terminal checks: street ends at the forecourt, forecourt then Jupiter centred on the street axis, Jupiter approach on the forecourt, entrance faces the forum |
| `tests/roman_plan_tests.lua:294-316` | lane runs up to the arch approach (`:314` reads the arch approach) | #351: for the north arm the lane rule is the same length-2 rule (lane z 15..70) but there is no arch approach; skip or replace `:314` for terminal arms |
| `tests/roman_plan_tests.lua:731-737` | no monument overlaps `arch_north` / `arch_south` | #351: `arch_north` no longer exists; check `arch_south` (and Jupiter) only |
| `tests/roman_plan_tests.lua:739-745` | `boundary.rects[1]` 181 x 172; reach edge 95 | #351: rect 1 (main) 181 x 173; rect 2 x -14..13, z 80..110; reach edge from `plan.bounds` = 110 (reach 382) |
| `tests/roman_plan_tests.lua:747-760` | origin site rect pins | unchanged values; #351/#352/#353 may add pins for Jupiter, the forecourt, Vesta and the hippodrome |
| `tests/roman_plan_tests.lua:766-779` | 12 block pins and the block count | #351 outer_north_east 10,72,43,80 and outer_north_west -44,72,-11,80; #352 south_east_inner 3,-41,11,-27; #353 remove east_end_south, west_end_north, ring_west_outer_north, ring_east_outer_south 44,-74,52,-48 (9 blocks); #354 outer_north_east 10..81, outer_north_west -91..-11 and the ten new blocks (19) |
| `tests/outskirts_fixture.lua:71-72` (used by `tests/outskirts_contract_tests.lua:71-76`) | Roman `plan.bounds` 905..1085, -2086..-1915 and the protected rectangle at that centre | #351: bounds become z -2087..-1890 at that centre (z1 moves with `main_rect`, z2 with the compound); the fixture's accepted plots (`F.plots`, `:76` on) were found against the old bounds and at least the first (x 1000..1012, z -1895..-1879) now overlaps the new bounds, so regenerate the plots and distances rather than editing only the rectangle |

## 14. Bath alignment (PM request on #353)

Measured: the bath's main entrance is a triple door at file (4, 4, 19..21)
facing -X. At the bath's rotation 180 (world z = -66 + 42 - file z) it is at
x -8, z -45..-43, centre -44. The porch in front of it is centred on the
same line: its pillars at file x 2, z 16, 18, 22, 24 are at world z -40,
-42, -46, -48 (centre -44), and its quartz slab edge at file x 0, z 14..26,
spans world z -50..-38 (centre -44). The secondary road that ends opposite
it across the southern cardo is ring_south, z -47..-42, centre -44.5. So
the whole entrance, door and porch, is half a node off the road's axis.
That is the closest possible: the entrance is an odd number of nodes wide
and the road is six, so their centres cannot coincide. Moving the bath one
node puts the entrance centre at -45 (`at` 9: half a node off on the other
side, no better) or -43 (`at` 7: one and a half nodes off, worse).

Recommendation: do not shift the bath. If the PM saw a visible offset in a
built town, it was probably a world built before the bath trim (#171) or
the ring street change (#164, #202); a screenshot or coordinates would
settle it. Should a shift still be wanted, it is cheap and low-risk
mechanically (one `at` value in the layout plus the bath rect and door-route
pins, as with the theatre's turn in #213), but at `at = 9` the gap to
ring_south_west would drop to one row.

## 15. Materials

- Jupiter forecourt: `forum_material` (`mcl_core:cobble`), the forum and
  cardo cobble, abutting the clay podium; the schematic is not repainted.
  Jupiter's clay rows and its grass edge row stay as imported.
- Vesta keeps its orange clay row; it meets forum and cardo cobble.
- Hippodrome keeps grass, gravel and its stone portico floor; its portico
  meets the gravel road directly, so no extra access paving.
- All new and extended secondary roads: `band_material` gravel.

## 16. Implementation sequence and ticket updates

Each step leaves `tests/run.lua` passing and the town valid at the origin
and a translated centre. The prerequisite is independent of #351/#352 and
can land any time before #353.

1. #221: this document, after PM review.
2. #351 Jupiter. Add `main_rect` (final value x -95..85, z -87..85) and the
   terminal-landmark extension (section 11); north arm length 57 with
   Jupiter and `jupiter_forecourt` (section 5); trim outer_north_east to
   ring north_outer outer 10..43 and outer_north_west to -44..-11 (the
   forecourt runs between them). Boundary = main + compound x -14..13,
   z 80..110; bounds x -95..85, z -87..110. Update the #351 test pins of
   section 13.1, including the outskirts fixture.
   Expected ordinary total over seeds 1/2/3/7: 81.
3. #352 Vesta. Landmark `temple_of_vesta`: arm south, side +x, at 0,
   rotation 180, faces forum (existing mechanism, no extension); block
   south_east_inner becomes arm south +x 11..25. Approach (8,-15) on the
   forum. Update the #352 test pins of section 13.1. Expected total: 76.
4. New small ticket, "Hippodrome catalog: long-side main entrance":
   section 6 exactly (catalog entrance (18,8,3), -Z, opening; fixture;
   README row). No model edit, no layout change.
5. #353 Roads and hippodrome. Bands of section 4 (existing six re-spanned,
   three appended); hippodrome ring landmark (ring north_outer, inner,
   at -91, rotation 180); remove blocks west_end_north, east_end_south,
   ring_west_outer_north; ring_east_outer_south becomes ring east outer
   -74..-48. Update the #353 test pins of section 13.1 (including the
   rewrite of the bath/south-west-quadrant loop). Expected total: 52
   (temporary).
6. #354 Population. Extend outer_north_east to 10..81 and outer_north_west
   to -91..-11; append blocks j..s of section 10 in that order. Meet the
   minimum of section 12 and update the #354 block pins of section 13.1.
   Expected total: 224.

Proposed text to add to each ticket (the coordinator edits GitHub):

- #351: "Geometry: docs/roman_expansion_layout.md sections 3, 5, 11, 13
  and 16 step 2. main_rect = x -95..85, z -87..85 (authored, translated);
  cardo_north length 57; jupiter_forecourt square x -10..9, z 72..79
  (cobble); temple_of_jupiter rotation 0, x -10..9, z 80..106, entrance
  (-1,88), approach (-1,79); compound x -14..13, z 80..110; bounds
  x -95..85, z -87..110. Trim outer_north_east to 10..43 and
  outer_north_west to -44..-11. Schema: arm `terminal` with `forecourt`,
  and `main_rect`, as specified in section 11. Test pins: section 13.1
  rows marked #351 (census, site count, boundary containment, arm length,
  arch-per-arm and lane tests, arch_north overlap test, boundary/reach,
  block pins, outskirts fixture and plots). Expected ordinary total
  81 over seeds 1/2/3/7."
- #352: "Geometry: docs/roman_expansion_layout.md section 8. Vesta is an
  existing arm landmark (arm south, side +x, at 0, rotation 180, faces
  forum): x 3..13, z -26..-16, entrance (8,-19), approach (8,-15) on the
  forum. No forum-edge extension is needed. Neighbouring change: block
  south_east_inner from 0..25 to 11..25 (loses its forum run and 11 cardo
  nodes). Test pins: section 13.1 rows marked #352. Expected ordinary
  total 76." (Delete the 'minimal forum-edge
  extension' allowance.)
- New prerequisite ticket: "Correct the hippodrome catalog entrance to the
  long-side portico opening, per docs/roman_expansion_layout.md section 6:
  entrance (18,8,3) facing -Z, entrance_kind opening; roman_catalog_tests
  fixture rotated entrances (18,3),(3,18),(18,21),(21,18), front index 1;
  README metadata row. Do not edit the model. Run tests/run.lua and, if
  available, tools/roman_check."
- #353: "Depends on the hippodrome catalog ticket. Geometry:
  docs/roman_expansion_layout.md sections 4, 5.1, 6, 7, 9, 10 and 16 step 5.
  Roads: ring_north span -44..81, ring_north_outer -91..81, ring_south
  3..81, ring_south_outer 6..81; new bands west_outer (west 51..56, span
  3..40), south_west (south 53..58, span -91..-4), east_outer (east 51..56,
  span -41..-4), appended in that order. Hippodrome: ring north_outer,
  side inner, at -91, rotation 180, x -91..-55, z 41..65, approach (-73,66);
  ground_offset 7 and the passage kept; its door court x -54..-45,
  z 41..65 stays unbuilt. Remove blocks west_end_north, east_end_south,
  ring_west_outer_north; ring_east_outer_south becomes -74..-48. Bath not
  moved (see section 14 unless the PM decides otherwise). The ordinary
  total falls to 52 here by design; #354 restores it. Test pins: section 13.1 rows
  marked #353, including rewriting the bath/south-west-quadrant loop for
  ring_south_west. Do one in-game build and check the hippodrome passage."
- #354: "Geometry: docs/roman_expansion_layout.md sections 9, 10 and 12.
  Extend outer_north_east to 10..81 and outer_north_west to -91..-11; add
  blocks ring_south_inner_east, ring_north_inner_west, ring_west_inner_north,
  ring_east_inner_north, ring_south_outer_east, ring_south_outer_inner_east,
  west_outer_west, south_west_outer, east_amph_north, east_outer_east in
  that order. Gap dispositions: section 9. Minimum: 50 ordinary buildings
  at each of seeds 1, 2, 3, 7, 210 in total, and every listed block used at
  each of those seeds (measured 56 per seed, 224). Test pins: the #354
  block pins of section 13.1."

## 17. Decisions for the PM

1. Bath shift (#353 request): recommend no shift; door and porch are
   centred half a node off the road axis, the closest an odd-width
   entrance can be to a six-wide road, and a one-node shift only moves the
   offset to the other side (section 14). Alternative: shift anyway (cheap, no visual gain).
2. Hippodrome door court: the existing 30-node block ring_west_outer_north
   is removed so the two short-end doors open onto open ground leading to
   ring_west (about 3 buildings per town; already netted out of the counts).
   Recommend accept. Alternative: keep the block and leave the short-end
   doors facing a one-node gap.
3. The jail lands in the far south-west block (south_west_outer) in every
   seed, chosen by the unchanged jail reservation; today it is also in an
   outer block. No action proposed; noted so it is not a surprise in game.

## 18. Verification log

Verified (prototype in a scratch copy of the mod; not committed):

- Models decoded with `tests/mts_reader.lua`; entrance cells, porch,
  steps, openings and buried rows read node by node (sections 5.1, 6, 7).
- Routes: node walk plus `builder.check_door` at all four rotations for the
  three chosen entrances.
- Layout: the proposed `roman_civic_plan.lua` with the two extensions,
  planned at (0,0), (777,-333) and the round-robin centres; authored
  validation, non-overlap, connected pavement, row depth; seeds 1..100.
- Consumers run on the plan: `preflight.compose`, `town_layout.new`,
  `site_search.boundary_columns`, `open_space` (via planner),
  `tools/layout_compare`.
- Counts: section 12, from the planner and layout_compare.

Reproducibility: everything above except the `layout_compare` metrics
was produced by the scripts in `roman_expansion_221/prototype/scripts/`
on a scratch copy of the mod; outputs are in `prototype/results/`.

Not verified: an in-engine town build (hippodrome excavation at
ground - 7 in real terrain, Living Villages boundary smoothing on the
two-rect union, `tools/roman_check` with the corrected entrance), resident
spawning, and how the larger footprint affects how often site search finds
flat enough ground.
