# Towns Mod — Medieval Town Generation Design Brief

## Overview

`Towns` is a new Luanti mod intended to generate large, convincing settlements that feel qualitatively different from ordinary VoxeLibre villages.

The first target is a **medieval town** with roughly a hundred inhabitants. The town should have a recognizable urban center, major civic and religious landmarks, dense streets of buildings, secondary public spaces, optional fortifications, and a looser fringe of development outside the walls.

The mod should build naturally on the ideas and systems in **Living Villages**, but Towns should primarily be responsible for the **settlement itself**: generation, layout, buildings, public spaces, streets, walls, and settlement-level metadata.

Living Villages can continue to be responsible for individual villager behavior.

The long-term vision includes other town styles, such as classical towns, but the initial design should focus on making one medieval town type work well.

---

# Design Goals

A generated medieval town should:

- look intentionally planned rather than like a large random village;
- be recognizable from a distance and from above;
- have a dense urban core;
- contain major landmarks that establish a visual hierarchy;
- have streets that clearly connect important places;
- contain enough repeated public services such as taverns and wells to support a large population;
- use handmade buildings rather than relying primarily on procedurally generated architecture;
- have enough variation that towns do not all look identical;
- transition naturally from dense urban development to scattered development and countryside;
- work well with Living Villages and ordinary VoxeLibre villagers;
- remain understandable and debuggable as a procedural-generation system.

The initial implementation should favor **simple, robust rules that produce good-looking towns** over simulation complexity or historically perfect urban planning.

---

# Scope of the First Town Type

The first town style is:

## Medieval Town

The defining features are:

- a large cathedral;
- a castle;
- a cathedral parvis;
- a market square;
- a dense network of mostly orthogonal streets;
- secondary streets and alleys;
- dense street-front buildings;
- repeated taverns, wells, and possibly small churches or chapels;
- optional town walls;
- gatehouses where major streets cross the walls;
- wall towers;
- simple activity or decoration inside blocks;
- scattered development outside the walls.

Later town styles may use a substantially different visual language and planning logic.

Do not design the medieval system in a way that assumes every future town must have the same landmarks, street pattern, or wall system.

---

# Overall Generation Philosophy

Town generation should conceptually happen in two stages:

1. **Plan the town**
2. **Build the town**

The planning stage should produce a town-plan object describing the important elements of the settlement.

The planner should make decisions such as:

- town footprint;
- boundary;
- landmark positions;
- streets;
- squares;
- alleys;
- blocks;
- building positions;
- public-service locations;
- walls;
- gates;
- exterior development.

The actual world should not need to be modified while these decisions are being made.

This separation is useful because it allows:

- validation before construction;
- easier debugging;
- visualization of proposed towns;
- deterministic reproduction of generation problems;
- future replacement or refinement of individual planning stages.

The precise representation of the town plan is an implementation detail.

---

# Site Selection and Terrain

For the first version, towns should be built on **large, relatively flat sites**.

This is intentional.

Handling steep hills, cliffs, complicated rivers, and irregular terrain would substantially complicate:

- street planning;
- wall generation;
- building placement;
- navigation;
- visual composition.

The initial town generator should therefore prefer terrain that is already reasonably suitable.

Some terraforming is acceptable.

The system may flatten or smooth the town site sufficiently to create a practical building surface, but it should avoid creating absurd artificial plateaus in terrain that was obviously unsuitable.

Very difficult sites should simply be rejected.

The exact tolerances should be discovered through testing rather than being treated as fixed design requirements.

For the initial implementation, significant rivers or bodies of water inside the proposed town site may also be considered grounds for rejection.

River towns and bridges can be addressed later.

---

# Town Boundary

The medieval town should have a clear overall boundary.

Even when a town is not walled, this boundary defines the dense urban area.

The desired shape is:

- broadly square or rectangular;
- entirely or almost entirely orthogonal;
- irregular enough to avoid looking like a single rectangle.

A useful visual model is **several large rectangles overlapping or stacked together**.

From above, this might produce a shape with:

- projecting sections;
- recessed sections;
- convex corners;
- occasional concave corners;
- runs of different lengths.

The result should still feel simple and deliberate.

Avoid overly noisy outlines, tiny notches, narrow appendages, or excessive small turns.

The boundary is important because it influences:

- walls;
- gates;
- street endpoints;
- urban density;
- the transition to the exterior fringe.

---

# Major Landmarks

Every medieval town should contain two primary landmarks:

## Cathedral

The cathedral should be one of the dominant visual features of the town.

It should have:

- a substantial footprint;
- a prominent position;
- a parvis or open square in front of its principal entrance.

The cathedral does not need to sit exactly in the geographic center of the town, but it should normally be relatively central and well connected to the principal streets.

The parvis is part of the cathedral site rather than an unrelated open area.

The cathedral site may later grow to include related structures such as:

- cemetery;
- clergy buildings;
- cloister;
- smaller religious structures.

These are not required initially.

## Castle

The castle should normally be associated with the town wall or outer edge rather than appearing randomly in the middle of an urban block.

The preferred relationship is that the castle is:

- built into the defensive perimeter;
- adjacent to it;
- or otherwise occupying a prominent edge position.

The castle should be connected to the principal street network.

The castle may eventually include a larger coordinated site, such as:

- bailey;
- courtyard;
- service buildings;
- defensive works.

The initial implementation does not need to model all of these.

---

# Squares and Public Spaces

The first medieval towns should include at least two important public spaces.

## Cathedral Parvis

A formal open space associated directly with the cathedral entrance.

This should help give the cathedral a monumental setting rather than placing it tightly between ordinary buildings.

## Market Square

A major urban square elsewhere in the town.

For the initial implementation, the market square does **not** need functional or procedural market stalls.

It should primarily provide:

- open civic space;
- visual variety;
- a destination within the street network;
- a location for later town activity.

Other smaller public spaces may appear where useful.

These could include:

- small well squares;
- widened intersections;
- bell squares;
- small churchyards;
- minor plazas.

They should be relatively restrained so the town does not become dominated by empty space.

---

# Streets

The street network should be predominantly orthogonal.

This simplifies:

- building placement;
- schematic rotation;
- street-facing architecture;
- wall gates;
- procedural reasoning.

The town should contain several street classes.

## Principal Streets

A small number of relatively wide streets should form the main structure of the town.

They should connect important destinations such as:

- gates;
- cathedral/parvis;
- castle;
- market square;
- other major public sites.

They should feel purposeful.

The exact width should be treated as a tunable visual parameter.

An initial value might be in the neighborhood of six nodes, but this should not be considered a hard requirement.

## Secondary Streets

Narrower streets should divide the town into manageable blocks.

Their main purpose is to:

- provide access;
- create appropriately sized urban blocks;
- prevent enormous uninterrupted building areas.

An initial width around four nodes may be reasonable, but again this is primarily a play-testing question.

## Alleys

Narrow alleys may appear between or through blocks.

They provide:

- visual complexity;
- pedestrian-scale passages;
- access to some interior areas;
- a stronger medieval feel.

Alleys should remain a secondary feature rather than turning the town into a maze.

A town should still be easy to understand and navigate.

---

# Street Materials

Street surfaces may vary.

Possible materials include:

- stone brick;
- cobblestone;
- gravel;
- coarse dirt;
- dirt;
- grass or worn grass.

Variation should generally occur by **street or coherent street segment**, rather than through noisy per-node randomization.

Possible biases include:

- major streets using more substantial paving;
- central streets being better maintained;
- alleys and peripheral streets using rougher surfaces.

The exact palette should remain flexible.

The purpose is visual variety, not an elaborate road-quality simulation.

---

# Street Network Principles

The street network should generally connect meaningful places.

Avoid producing arbitrary disconnected fragments or purely decorative street segments.

A useful planning order is:

1. establish important destinations;
2. establish gates;
3. connect major destinations with principal streets;
4. add secondary streets where needed;
5. add alleys for local complexity.

The exact graph or routing algorithm should be chosen by the implementation agent.

The design goal is that the player should be able to intuitively understand:

- where the important roads go;
- which roads are major;
- where the center of town is;
- where the gates are.

---

# Blocks

Streets divide the town into urban blocks.

Blocks do not need to represent legal property parcels or historically accurate lot systems.

For the initial version, they are primarily a practical generation structure.

A block consists of:

- street-facing edges;
- buildings arranged along those edges;
- some leftover interior space.

Blocks should generally be small enough that their interior space remains manageable.

Secondary streets should be added if a block becomes excessively large.

---

# Street-Front Building Placement

The initial implementation does **not** need a sophisticated lot system.

Instead, buildings can be packed along usable street frontage.

A simple conceptual approach is:

1. identify usable frontage along a block;
2. reserve space needed for corners, alleys, monuments, or access;
3. choose a building that fits;
4. place it facing the street;
5. continue along the frontage until no appropriate building fits.

This should produce dense urban streets without requiring a separate simulation of property ownership or parcel boundaries.

If a future feature benefits from true lots, the system can evolve in that direction later.

---

# Building Density and Adjacency

Buildings in the urban core should normally sit close to one another.

A major visual goal is to create recognizable **street walls**, rather than village cottages distributed on individual open plots.

Typical relationships may include:

- buildings directly abutting;
- buildings separated by a narrow one-node passage;
- occasional wider gaps where appropriate.

The generator should avoid placing one-node gaps everywhere, since that would create repetitive narrow slots.

Building metadata may indicate whether a structure is intended to:

- abut its neighbors;
- allow a narrow side passage;
- stand independently.

Dense central streets should strongly favor attached or nearly attached buildings.

Peripheral areas may become progressively less dense.

---

# Handmade Buildings

Most important buildings should be created manually in Creative mode.

This includes:

- cathedral;
- castle;
- town houses;
- shops;
- taverns;
- churches;
- workshops;
- public buildings;
- wall components;
- gatehouses;
- towers;
- exterior rural buildings.

The desired workflow is:

1. build a structure manually in Creative;
2. capture or export it as a schematic;
3. register it with Towns;
4. provide simple metadata describing how it can be used.

The exact capture workflow should be designed for convenience.

The project should make it easy to add new handmade structures without touching significant parts of the procedural-generation code.

---

# Building Metadata

Each registered building should provide enough metadata for the town planner to use it sensibly.

Potentially useful information includes:

- identifier;
- town theme;
- building category;
- width and depth;
- canonical facing direction;
- primary entrance location or facade;
- whether it can abut neighboring buildings;
- whether it may stand independently;
- whether it requires a corner;
- whether it is suitable for central or peripheral areas;
- possible functional roles.

Do not over-design the metadata model before actual buildings demonstrate that additional fields are needed.

The initial registry should remain relatively small and understandable.

---

# Building Orientation

Handmade buildings should use a consistent canonical orientation.

For example, all primary street entrances might face the same direction when captured.

The town generator can then rotate structures to match the street frontage.

The particular canonical direction is not important as long as it is consistent.

---

# Generic Building Variety

The town should not require every visible building to have a unique schematic.

Instead, a modest library of handmade structures should support variation.

A building might conceptually have independent characteristics such as:

- base structure;
- material palette;
- functional role;
- interior contents;
- decorative variation.

For example:

- commercial building 3;
- material style 2;
- business: tanner.

This kind of variation is desirable, but it should be introduced carefully.

The first priority is to make the town layout and base buildings look good.

Generalized material substitution or extensive procedural decoration should not be allowed to delay the basic town generator.

---

# Building Categories

The precise taxonomy should evolve with the building library.

Likely useful categories include:

- ordinary residential;
- merchant/commercial;
- workshop/craft;
- tavern;
- small church or chapel;
- civic;
- warehouse/storage;
- special urban building;
- rural/peripheral building.

The category system should serve generation needs rather than trying to model every medieval profession.

---

# Public Services and Distribution

A town with roughly a hundred inhabitants needs repeated public destinations.

These should not be placed purely by chance.

The planner should ensure a reasonable distribution of at least:

## Taverns

There should be multiple taverns distributed through the town.

They should not all cluster around the same square or street.

The exact target number should be tuned based on:

- town size;
- Living Villages behavior;
- walking distances;
- visual density.

## Wells

Multiple wells or similar water points should be distributed around town.

Some may occupy small squares or widened street areas.

Again, exact spacing and quantity should remain tunable.

## Smaller Churches or Chapels

The cathedral is the dominant religious structure, but a town may also include smaller churches or chapels.

These should be less monumental and may serve outlying neighborhoods.

Their presence and number can be probabilistic or based on town size.

The initial implementation does not need a sophisticated parish model.

## Bells

Bells may appear as part of:

- churches;
- civic spaces;
- towers;
- small public squares.

These can help integrate with Living Villages' existing communal behavior.

---

# Secondary Monuments and Major Buildings

After the cathedral, castle, and primary street structure are established, the town may place additional notable buildings or public features.

Examples include:

- small churches;
- civic hall;
- guild-like building;
- large inn;
- bell tower;
- well;
- fountain;
- substantial merchant house;
- other visually distinctive structures.

These should generally be positioned deliberately:

- along important streets;
- at intersections;
- beside squares;
- at meaningful visual endpoints.

They should not simply be scattered randomly through remaining space.

A relatively small number of secondary landmarks is preferable to making every block special.

---

# Block Interiors

After street-front buildings are placed, blocks may retain irregular open areas behind them.

These spaces should receive simple treatment.

Possible elements include:

- gardens;
- sheds;
- small workshops;
- trees;
- animal pens;
- storage areas;
- yards;
- wells;
- grass;
- miscellaneous medieval clutter.

The initial version should keep this system simple.

Not every interior space needs:

- formal access;
- an alley;
- a path;
- a fully simulated purpose.

Some enclosed or irregular backlands are acceptable and may actually improve the medieval appearance.

---

# Walls

Medieval towns may be surrounded by walls.

Wall generation should use a relatively small set of reusable handmade components.

Likely components include:

- straight wall section;
- extendable or repeatable wall section;
- large tower;
- small tower;
- gatehouse;
- corner solutions where needed.

The wall follows the town boundary.

Because the initial town boundary is orthogonal, the wall system should also remain predominantly orthogonal.

---

# Wall Towers

Towers should provide both:

- defensive visual logic;
- rhythm along long stretches of wall.

Potential placement includes:

- major convex corners;
- selected other corners;
- intervals along long straight wall runs;
- important gate locations.

Do not mechanically place a large tower at every tiny change in wall direction.

Tower density should be tuned visually.

---

# Gatehouses

Major roads crossing the town wall should pass through gatehouses.

Gate placement should therefore be coordinated with principal-street planning.

The planner should not create the road network and wall network independently and then attempt to reconcile them afterward.

Gatehouses should provide strong visual landmarks and clear entrances to the town.

---

# Castle and Wall Relationship

The castle should usually be physically associated with the defensive perimeter.

Possible relationships include:

- the castle replacing part of the town wall;
- castle walls merging into town walls;
- the castle sitting immediately inside the wall;
- the castle controlling a major edge or gate.

The exact arrangement may vary between towns.

The purpose is to make the castle feel strategically positioned rather than randomly inserted.

---

# Space Along the Interior Wall

The generator does not need to pack ordinary buildings tightly against every section of wall.

Some portions of the interior perimeter may contain:

- open space;
- a narrow lane;
- yards;
- defensive clearance;
- scattered buildings.

This can improve wall visibility and prevent the urban fabric from becoming visually unreadable.

Other sections may have buildings close to the wall where that looks natural.

Variety is desirable.

---

# Exterior Development

The wall or urban boundary should not represent an abrupt transition from dense town directly to untouched wilderness.

A broader settlement fringe should eventually surround the town.

This should be substantially less dense than the urban core.

Possible elements include:

- ordinary VoxeLibre-style village houses;
- cottages;
- farms;
- barns;
- gardens;
- orchards;
- workshops;
- roadside inns;
- animal enclosures;
- scattered religious buildings.

This outer development can initially reuse or adapt village structures rather than requiring a large dedicated building library.

---

# Exterior Roads

Major town roads should conceptually continue beyond the gates.

In the first implementation, they do not necessarily need to connect to distant villages or generated road networks.

However, development outside the walls should tend to relate to these roads.

For example:

- cottages beside a gate road;
- roadside inn;
- farmstead;
- workshop;
- small chapel.

This helps make the town feel connected to a larger world.

---

# Country Landmarks

A later phase should allow occasional major structures outside the town.

Examples include:

- monastery;
- abbey;
- villa;
- manor house;
- substantial farm;
- mill;
- cemetery;
- isolated chapel;
- other large rural monument.

These should be relatively uncommon and should feel distinct from ordinary fringe development.

This is not required for the initial playable town generator, but the town plan should not make such additions difficult later.

---

# Settlement Zones

It may be helpful conceptually to think of the generated area as three broad zones:

## Urban Core

Inside the main town boundary.

Characteristics:

- dense;
- structured streets;
- major landmarks;
- closely packed buildings;
- public services;
- possible walls.

## Extramural Fringe

Immediately outside the core.

Characteristics:

- scattered buildings;
- lower density;
- more gardens and agricultural uses;
- development related to roads and gates.

## Countryside Landmark Zone

A broader surrounding area that may occasionally contain major rural sites.

This conceptual distinction does not require a complicated formal zoning system.

It is mainly useful for producing a believable density gradient.

---

# Population Target

The medieval town is intended to support roughly **one hundred villagers**, with flexibility depending on the resulting building stock.

The town planner does not need to simulate population in detail.

Instead, generation should produce enough:

- beds;
- job sites;
- public destinations;
- taverns;
- wells;
- religious spaces;
- circulation space.

The actual population should emerge naturally from the available housing and Living Villages behavior.

Do not force exactly 100 villagers.

The goal is the scale of settlement that would reasonably support that order of population.

---

# Relationship to Living Villages

Towns should work naturally with Living Villages.

Where appropriate, Towns should expose or preserve things Living Villages already understands, such as:

- beds;
- workstations;
- taverns;
- churches;
- bells;
- wells;
- walking destinations.

Avoid duplicating villager-AI systems inside Towns unless there is a clear need.

A useful division of responsibility is:

**Towns:**  
Where the settlement is and what exists there.

**Living Villages:**  
What individual villagers do within that settlement.

Some future integration may benefit from knowing which town a villager belongs to.

It may therefore be useful for generated towns to have:

- persistent identity;
- center position;
- bounds or region.

Do not build a complicated citizenship system in the first version.

---

# Town Identity

Each generated town should have a stable identity.

At minimum, this probably means:

- deterministic generation seed or identity;
- center;
- bounds;
- town type.

Later, this may include characteristics such as:

- name;
- wealth;
- primary trade;
- age;
- prosperity;
- fortification style;
- visual palette.

These should remain future possibilities rather than initial requirements.

---

# Determinism

Given the same world and town location, the same town should normally generate the same way.

This is valuable for:

- debugging;
- reproducible testing;
- comparing generation changes;
- reporting bad seeds;
- future world compatibility.

The implementation should therefore avoid uncontrolled global randomness.

The precise random-number strategy is an implementation concern.

---

# Debugging and Visualization

Town generation is complex enough that strong development tools will be valuable.

Useful capabilities may include:

- generating a town plan without building it;
- inspecting the resulting plan;
- visualizing:
  - town boundary;
  - streets;
  - blocks;
  - landmark footprints;
  - gates;
  - walls;
  - building footprints;
- regenerating or testing specific town seeds;
- teleporting to test towns.

The exact tools should be chosen during implementation.

The important design requirement is that the town generator should not be a black box whose only debugging method is visually inspecting a fully generated town.

---

# Building Capture Workflow

Adding handmade buildings should be easy.

A desirable workflow is:

1. build structure in Creative mode;
2. select or identify its bounds;
3. capture/export it;
4. assign a stable name;
5. add lightweight metadata;
6. immediately make it available to the generator.

The project should favor developer convenience here.

The person building schematics should not need to manually construct large Lua tables or perform repetitive conversions unless the platform makes that unavoidable.

---

# Initial Building Library

The exact number of structures is flexible.

A useful initial playable set might include:

## Major

- cathedral;
- castle.

## Public / Special

- market-square edge building or civic building;
- small church;
- tavern;
- perhaps one additional prominent civic or commercial building.

## Ordinary Urban

A modest selection of:

- narrow houses;
- wider houses;
- merchant houses;
- mixed shop/residential buildings;
- workshops.

Some should be designed to abut neighboring structures.

## Block Interior

A few small structures such as:

- shed;
- workshop;
- stable.

## Walls

- wall section;
- gatehouse;
- large tower;
- small tower;
- necessary corner/end pieces.

The town generator should become useful before a very large building library exists.

The procedural system should not require dozens of buildings before it can be tested.

---

# Generation Order

The exact mechanics are open to implementation choices, but the conceptual order should be approximately:

1. Find a suitable town site.
2. Determine a target ground level and prepare the site.
3. Generate the overall town boundary.
4. Position the cathedral and its parvis.
5. Position the castle in relation to the boundary.
6. Choose important gates.
7. Lay out principal streets connecting major destinations.
8. Place or determine the market square.
9. Add secondary streets to produce manageable blocks.
10. Add selected alleys.
11. Place secondary monuments and important public buildings.
12. Ensure appropriate distribution of taverns, wells, and smaller churches.
13. Identify usable block street frontages.
14. Pack ordinary buildings along those frontages.
15. Add simple interest to block interiors.
16. Generate walls, towers, and gatehouses if this town is walled.
17. Add exterior fringe development.
18. Materialize the final plan into the world.

This sequence is a guide, not a requirement that every internal implementation step correspond exactly to one code module.

If implementation experience suggests a simpler or more robust ordering, prefer that.

---

# Variability Between Towns

Even within the medieval town type, towns should not be identical.

Variation can come from:

- boundary shape;
- landmark placement;
- castle position;
- street network;
- market-square position;
- gate count and position;
- wall presence;
- building selection;
- street materials;
- building-density differences;
- public-service locations;
- exterior development.

The goal is not maximum randomness.

A town should still feel internally coherent.

Prefer a smaller number of meaningful variations over randomizing every available property.

---

# Walls as an Option

Not every medieval town necessarily needs walls.

The system should allow the medieval town type to support:

- walled towns;
- unwalled towns.

The initial development may focus on one first if that simplifies implementation.

The urban boundary should exist conceptually either way.

---

# Long-Term Town Themes

The architecture should leave room for substantially different town styles.

Examples might include:

- medieval;
- classical;
- later European;
- other culturally distinct town types.

A future classical town might differ in:

- street planning;
- major monuments;
- square design;
- building setbacks;
- density;
- wall style;
- road materials;
- public-building types.

Therefore, avoid assuming that concepts specific to medieval towns are universal requirements of the base Towns system.

For example:

- every town does not need a cathedral;
- every town does not need a castle;
- every town does not need medieval walls.

The reusable concepts are more likely to be:

- town plan;
- site;
- street;
- block;
- building;
- landmark;
- public space;
- boundary.

---

# Non-Goals for the Initial Version

The first medieval-town implementation does **not** need to solve:

- steep hill towns;
- irregular hillside streets;
- rivers through town;
- bridges;
- ports;
- diagonal or curving streets;
- sophisticated parcel ownership;
- a simulated town economy;
- market-stall simulation;
- dynamic town growth;
- construction over time;
- changing walls;
- complex class systems;
- detailed household simulation;
- regional trade;
- roads connecting multiple settlements;
- advanced material-palette generation;
- deep procedural building generation;
- every imaginable medieval occupation;
- perfect historical accuracy.

These may be interesting later, but they should not distract from the initial goal:

> Generate a large medieval town that looks good, feels coherent, supports Living Villages, and is enjoyable to explore.

---

# Early Success Criteria

The first strong milestone is not feature completeness.

It is a town that succeeds visually.

From a nearby hill or from creative-mode flight, it should clearly read as:

**a town, not an oversized village.**

Important signs of success include:

- cathedral and castle immediately establish hierarchy;
- walls, if present, clearly define the town;
- gates align naturally with major streets;
- major streets lead somewhere meaningful;
- the parvis and market square break up the dense urban fabric;
- the central area has continuous or near-continuous street frontage;
- buildings vary enough to avoid obvious repetition;
- taverns, wells, churches, and other public destinations are reasonably distributed;
- alleys and block interiors provide smaller-scale detail;
- density decreases naturally outside the walls;
- the town is pleasant to explore on foot.

A second important success criterion is development usability:

> It should be easy to build a new structure in Creative mode, capture it, register it, and see the town generator begin using it.

---

# Guidance for Implementation Planning

When turning this brief into engineering tickets:

- favor small vertical slices that produce something visible in game;
- keep tunable aesthetic choices configurable or easy to change;
- avoid designing elaborate abstractions before concrete generation problems require them;
- use the existing Living Villages work where appropriate rather than rebuilding solved systems;
- preserve a clean distinction between planning and world modification;
- prioritize tooling that makes visual iteration fast;
- expect street widths, block sizes, building spacing, tower intervals, service density, and similar values to change repeatedly during play testing.

When there is a choice between:

1. a sophisticated general solution, and
2. a simpler approach that produces convincing medieval towns,

prefer the simpler approach until experience demonstrates that it is insufficient.