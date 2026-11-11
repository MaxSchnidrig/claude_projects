# ROCRAFT roadmap: complete Java Edition gameplay

**Goal:** replicate Java Edition gameplay completely: mechanics, values, recipes, AI and
world-generation rules.

**Original, always:**
- Names Mojang invented.
- Mob designs.
- Textures, sounds and music.
- Structure designs.

Every new original equivalent gets a name proposal for approval before it's built. Never copies,
never slightly altered copies. Real-world names stay (cow, zombie, iron, village...).

**Skipped on purpose:**
1. Trial chambers, with their mobs, items and mechanics.
2. The deep dark and ancient cities, with their mobs, blocks and mechanics (including anything
   that depends on them).
3. The sulfur cave update content.

**Effort:** S = one session · M = 2–3 sessions · L = 4–6 sessions · XL = 7+ sessions.
**⚠ Roblox** marks a planned compromise for performance or platform reasons. Each one is
listed again at the end.

**Release:** one public release when everything below is done. Friends tests between phases
are fine.

---

## Phase 7.2 – Fixes from the 0.7.1 test (S)

| Issue | Cause | Fix |
|---|---|---|
| Visible box walls at the render distance | The fog shell panels sit just past the fog end and are lit and shaded by Roblox, so they don't come out as exactly the fog colour | Remove the shell. Hide Roblox's skybox a different way, and make the sky dome itself fade fully into the fog colour (a horizon band plus the zenith plane), checked in all four directions |
| Torch light arrives late | The torch's own section rebuilds at once; neighbouring sections whose light changed rebuild in the background | Rebuild light-changed sections on the same frame through the live-edit pool, up to a per-frame cap; background bakes only for the rest |

## Done before Phase 8

- 7.2: atmosphere sky (default), faster torch light.
- 7.3: Java world height −64…320 (internal 0…383), save format v2 with conversion, Java ore height bands, cave culling.

## Phase 8 progress

- 8a (done): flowing water and lava, buckets, falling sand and gravel, fire, campfires, TNT.
- 8b (done, 0.8.2): 2-byte block ids (up to 4095 block states; save format v3 converts old
  saves), the shape system (mesher boxes, collision parts, mob physics with step-up, shape
  raycasts), slabs and stairs (oak, spruce, birch, cobblestone, stone, sandstone) with Java
  corner shapes, wooden fences, doors (3 woods + iron), ladders with climbing, signs with
  filtered text on both sides, item frames.
- 0.8.3: the texture atlas was full (64 slots, 8b needed 69) and textures switched off; now
  121 slots (each texture drawn 5x instead of 7x), overflow only warns, and a test checks the
  fit. Before Phase 12 (hundreds of textures) the atlas needs several pages.
- 0.8.4: door use reached only the local view (fixed); no jumping over fences (Java body box in
  the air); calmer step-up and camera; break effects follow the shape.
- 8b2 (done, 0.8.5): trapdoors (3 woods + iron), fence gates, cobblestone and sandstone walls,
  glass panes, iron bars, vines (climbable, shears only), hanging signs (ceiling and wall),
  glow item frames; sprint FOV x1.15 like Java.
  Left for later: vines spreading (random ticks, phase 9); hanging sign recipe (chains and
  stripped logs, phase 12); glow ink sacs (glow squid, phase 14); gates lowering in walls.
- 0.8.6: server reach uses block shapes (open doors no longer block clicks); held jump re-jumps
  on the landing tick; ladders climb by walking into them, Shift holds still; a height guard
  stops the Roblox body sliding up edges (fences, walls, 1.5 and 2+ block ledges); glass panes
  without inner lines.
- 0.8.7: sign / item frame saves load again (they were saved but skipped on load); glass pane
  seams merged; height guard only resets on real ground, no landing while rising, fence /
  wall / gate collision 2 blocks tall for the Roblox body.
- 8c (done, 0.8.7): beds in 16 colours (sleep, skip the night, respawn point, bounce, half
  fall damage), armour (leather, chainmail, iron, gold, diamond with Java points, toughness,
  durability, shown on the character), armour and off-hand slots (F swaps), shield (blocks
  from the front after 5 ticks), bow (draw power, critical arrows, FOV zoom), crossbow (load,
  fire, always critical), arrow pickup.
  Left for later: coloured wool / dyes (only the white bed is craftable), phantoms (the rest
  counter is kept), axes disabling shields (needs attacking players or axe mobs), multishot and
  other enchantments (phase 10), leather dyeing, thunderstorm sleeping (weather, phase 9).
- 0.8.8: our own player physics. The Roblox Humanoid no longer moves the player (it kept
  snapping onto ledges, cutting jumps short and stopping at ceilings); Gameplay/PlayerMotor runs
  Java's player tick on a 0.6 x 1.8 box against the real block shapes, tested headless for the
  reported cases. Off-hand items are used (blocks, food) and shown; glass panes connect to glass
  and hide faces against it.
- 0.8.11: the player physics rebuilt for exactness. The box's position is kept in full
  precision (as a 32-bit Vector3 it ended up a hair inside walls and walked through them away
  from the world origin), the body's position is never read back (a long frame used to drop the
  player through the floor; spectators sank), the body has no weight and collides with nothing,
  and the old "anchor while collision rebuilds" safety net is gone (it froze the motor). Java
  details added: jump delay, fall distance by accumulation, sneak edge back-off, ladder / vine
  rules, swimming out of water, ice. tests/lune/FakeRoblox + ClientMovementTests run the real
  MovementController frame by frame in a simulated Roblox. F3 shows a "motor" line.

## Phase 8 – Survival foundations (XL)

**Liquids and gravity blocks**
- Java flow for water and lava: source and flowing levels, 7-block spread, lava 3 in the
  overworld, flow ticks, infinite water sources, waterlogging basics.
- Where liquids meet: obsidian, cobblestone, stone (basalt comes in phase 16).
- Currents push entities and items; buckets (empty, water, lava, plus fish/axolotl buckets
  later).
- Gravity blocks: sand, gravel, concrete powder (phase 12) fall and break on non-full blocks.
- ⚠ Roblox: flow is ticked in batches on the server; the client predicts nothing.

**Sleep and spawn**
- Beds in 16 colours: skip the night, need monsters away, set the spawn point.
- Phantom-role insomnia counter (the mob arrives in phase 14).
- Respawn rules.

**Combat gear**
- Armour: leather (dyeable), chainmail, iron, gold, diamond, with Java points, toughness,
  durability and the knockback resistance foundation.
- Armour slots, armour shown on the avatar.
- Shield: blocking, axe disabling, durability, banner patterns later.

**Ranged weapons**
- Bow: draw, power, crit arrows, pickup rules, arrows stuck in entities.
- Crossbow: charging, multishot foundation.

**Fire and explosives**
- Fire: flint and steel, spread, burn-out, fire damage, setting entities on fire.
- Campfire: cooking, smoke.
- TNT: ignition by fire, the Volt system later and explosions; chain reactions.

**Building blocks**
- Doors, trapdoors, fence gates, ladders, climbing and vines.
- Fences, walls, glass panes, iron bars.
- Slabs and stairs: the first non-cube shapes. ⚠ Roblox: the mesher gains a shape system;
  collision builds boxes per shape.

**Text and items**
- Signs and hanging signs. ⚠ Roblox: all player text goes through `TextService` filtering.
- Item frames, glow item frames.

**Game setup**
- Difficulty: Peaceful, Easy, Normal and Hard with Java rules; Hardcore.
- Main menu, pause menu, settings (render distance, FOV, sensitivity, volumes, GUI scale,
  bobbing, brightness), world settings (friends can join, difficulty).

## Phase 9 – Farming, food, weather, status effects (L)

**Farming**
- Farmland with hydration and trampling.
- Crops: wheat, carrots, potatoes, beetroot, pumpkins, melons (stems), sugar cane, cactus,
  bamboo, sweet berries, cocoa.
- Growth by random ticks and light; bone meal.
- Saplings and tree growth (all trees of the current biomes); mushrooms (incl. huge mushrooms);
  flowers, tall grass, ferns, dead bushes.

**Food**
- Every Java food with its hunger and saturation values: cake, cookies, pie, stews, suspicious
  stew, golden carrot, honey bottle, dried kelp...

**Status effects and weather**
- The status-effect system with Java durations and amplifiers for all effects, plus golden
  and enchanted golden apples.
- Weather: rain, snow, thunderstorms, lightning (fire, conversions, the charged Sneaker),
  weather effects on mobs and crops.

**Animals**
- Breeding, babies and growth for every animal that exists so far.
- Shearing; dyes and 16 colours (wool, carpets, beds, glass).
- Milk, eggs (thrown, hatching), leads, name tags, saddles.

**Fishing**
- Fishing rod with the Java loot table (fish, treasure, junk), plus cod, salmon, pufferfish and
  tropical fish as items.

## Phase 9b – Caves and mineshafts (L)

Caves are where players spend much of their time, so they get their own phase before the big
world-generation overhaul.

**Cave shapes:** Java's modern noise caves:
- Cheese caves: huge open caverns with pillars.
- Spaghetti caves: long winding tunnels.
- Noodle caves: thin squiggly tunnels.
- Carved canyons (ravines) and cave openings to the surface.
- Aquifers: underground water and lava levels instead of floating water.
- Lava lakes below Java y 0 only.

**Underground stone and ores**
- A deepslate-role stone layer below Java y 0 (name to approve), with its own cobbled variant
  and ore variants.
- Tuff and granite/diorite/andesite blobs.
- Java's exact ore shapes and height curves: triangular bands, fewer ores where exposed to air,
  large copper/iron veins.

**Cave features:** dripstone and pointed dripstone (falling, damage), moss and glow lichen on cave
walls, amethyst geodes, fossils.

**Structures** (Java placement and loot tables, our own designs)
- **Mineshafts:** corridors, crossings and stairs, rails, wooden supports, cobwebs, chest
  minecarts, cave-spider spawners. The badlands variant comes with phase 13.
- **Dungeons:** spawner rooms with loot chests.

**Look:** better cave textures and lighting contrast, cave ambience sounds (licensed).

**Hostile spawning** follows the new cave light levels.

## Phase 10 – Experience, enchanting, anvils, smithing (L)

**Experience**
- XP orbs (mobs, ores, smelting, breeding, fishing, trading).
- Java level curve; dropping on death.

**Enchanting**
- Enchanting table, bookshelves (power), lapis, Java offer generation.
- Every enchantment with its levels, weights, conflicts and treasure-only flags. Excluded:
  trial-chamber and deep-dark enchantments (Wind Burst, Density, Breach, Swift Sneak).
  Mending and other treasure enchantments come from loot and trading.

**Repair and upgrades**
- Anvil: repair, combining, renaming, prior-work penalty, damage.
- Grindstone, books.
- Smithing table and the top-tier upgrade (with the phase 16 material).
- Armour trims: Java mechanics; template and pattern art all our own designs.

## Phase 11 – Volt system: power and machines (XL)

**Signal parts**
- Volt Dust (signal 0–15, −1 per block, connection shapes), Volt Torch (burnout), Volt Block.
- Volt Relay (the repeater: delay, locking) and Volt Comparator (compare/subtract, reading
  containers).

**Inputs**
- Levers, buttons (wood/stone), pressure plates (incl. weighted), tripwire and hooks.
- Daylight detector, target block, trapped chest, lectern output.

**Machines**
- Pistons and sticky pistons with Java push rules (12-block limit, immovable blocks), slime and
  honey blocks.
- Observers; hoppers (transfer timing, minecart hoppers); droppers, dispensers (all dispense
  behaviours).
- Note blocks (instrument by block; our own sounds), jukebox (our own music discs), redstone
  lamp, copper doors/trapdoors/grates/bulbs.
- Crafter and copper bulb: they came in the same update as trial chambers but aren't part of
  the chambers, so they're included unless you'd rather drop them.

**Rails**
- Rails, powered, detector and activator rails; minecarts (normal, chest, hopper, furnace, TNT,
  command later); boats and chest boats.

**Timing and performance**
- Java tick timing: 20 ticks per second, 2-tick relay steps, block update order,
  quasi-connectivity, zero-tick behaviour where Java has it.
- ⚠ Roblox: a dedicated 20 TPS logic loop on the server and a budget for very large
  contraptions.
- ⚠ Roblox: minecarts and boats are custom kinematic vehicles, not Roblox physics.

## Phase 12 – Complete overworld block set and decoration (L)

**Stone**
- Granite, diorite, andesite, calcite, tuff, deepslate (and cobbled/polished/bricks/tiles),
  smooth stone.
- Stone bricks (mossy/cracked/chiseled), bricks, mud bricks, packed mud, prismarine set
  (phase 13 ocean monument).

**Wood**
- Every wood set: oak, spruce, birch, jungle, acacia, dark oak, mangrove, cherry, bamboo;
  crimson and warped in phase 16.
- For each: log, wood, stripped variants, planks, slab, stairs, fence, gate, door, trapdoor,
  button, pressure plate, sign, hanging sign, boat.

**Colours**
- Terracotta and 16 glazed terracotta (our own patterns), concrete and concrete powder,
  stained glass and panes, candles.

**Light, utility and decoration**
- Light and utility: lanterns, soul variants, chains, torches of each type, end rod-role (phase
  18), sea lantern-role, glowstone-role (phase 16), shroomlight-role.
- Decoration:
  - Flower pots, paintings (all our own art), armour stands, banners (patterns: Java crafting
    rules, our own pattern art), loom, cartography table, fletching table.
  - Composter, barrel, smoker, blast furnace, stonecutter, bell, scaffolding.
  - Chiseled bookshelf, lectern, decorated pots and sherds (our own designs).
  - Moss, dripleaf, spore blossom, azalea, glow lichen, hanging roots (with lush caves in
    phase 13).
- Snow layers, powder snow (freezing), ice types, coral blocks, kelp, seagrass, sea pickles.

**Stonecutter recipes and colour recipes for all of the above.**

## Phase 13 – Overworld generation overhaul (XL)

**Terrain**
- Java 1.18+ multi-noise terrain: continents, erosion, peaks and valleys, rivers. (Caves,
  aquifers, ore shapes and mineshafts already come in phase 9b.)
- Java ore distribution by height and biome.
- World height −64 to 320 is already in place (0.7.3). Remaining here: deepslate-role stone
  below Java y 0 (name to approve) and the exact 1.18 ore shapes.
- (Original note) ⚠ Roblox: world height −64 to 320 (from 0–127) was the biggest change in this plan: 3× the
  blocks per chunk, plus memory, meshing load, a save-format migration and mobile limits. We
  measure on mobile first; fallback options are a smaller vertical range or lower view
  distance on phones. Existing worlds must be converted (a versioned migration, tested before
  release).

**Biomes:** all overworld biomes with Java temperatures, colours (grass, foliage and water
tints) and features.
- Plains and forests: plains (and sunflower), forests (flower, birch, old-growth birch, dark),
  taiga (old-growth pine and spruce, snowy).
- Hot and wet: jungle (sparse, bamboo), savanna (windswept, plateau), badlands (eroded, wooded),
  desert, swamp, mangrove swamp, mushroom fields.
- Mountains: meadow, cherry grove, grove, snowy slopes, frozen, jagged and stony peaks,
  windswept hills (gravelly, forest).
- Snow and coast: snowy plains and ice spikes, beaches (stony, snowy), rivers (frozen).
- Oceans: warm, lukewarm, cold, frozen and their deep versions.
- Caves: lush caves, dripstone caves. The deep dark is excluded.

**Features**
- Every tree shape.
- Flowers per biome, icebergs, ice spikes, coral reefs, kelp forests, geodes (amethyst),
  fossils, lava lakes, springs, mossy boulders, dripstone.

**Structures** (Java placement rules and loot tables; buildings all our own designs)
- Villages in 5 styles; pillager outposts.
- Badlands mineshafts (regular mineshafts and dungeons come in phase 9b).
- Desert pyramid, jungle temple, swamp hut, igloo.
- Shipwrecks, ocean ruins, buried treasure with maps, ocean monument.
- Woodland mansion, ruined portals, strongholds.
- Trail ruins and archaeology (brush, suspicious sand and gravel).
- ⚠ Roblox: big structures generate in time slices across chunks, with a deterministic jigsaw
  layout so client and server agree.

## Phase 14 – All overworld mobs (XL)

Original designs throughout; a name proposal wherever the Java name is Mojang's own.

**Passive and neutral**
- Rabbit, horse, donkey, mule (riding, taming, stats, breeding genetics, horse armour), llama
  and trader llama, cat, ocelot.
- Wolf (taming, wolf armour from armadillo scutes, variants), parrot (dancing, imitation), fox,
  panda (personalities), polar bear, turtle (eggs, scute, helmet), frog and tadpole (froglights),
  axolotl.
- Goat (ramming, horns: our own sounds), bee (hives, pollination, honey, anger), camel,
  armadillo.
- Squid, glow squid, dolphin, the four fish, bat.
- Snow golem-role, iron golem-role (designs and names to approve).
- Mooshroom-role, sniffer-role (ancient seeds, torchflower and pitcher plant: names to
  approve), allay-role (name to approve).

**Hostile**
- Zombie variants: husk, drowned (trident, conversion), zombie villager (phase 15 curing).
- Stray, cave spider, slime, witch, silverfish (infested blocks), guardian and elder guardian
  roles (mining fatigue).
- Phantom role (insomnia from phase 8; name to approve), endermite role (with the Voidling).
- Spawners for all dungeon mobs.
- Excluded: Bogged, Breeze (trial chambers), Warden (deep dark).

**AI and mechanics:** Java goals, sensing, pathfinding for land, swimming and flying mobs;
riding, taming, leashing; mob equipment and drop chances; spawn tables per biome.
- ⚠ Roblox: flying and swimming pathfinding are new systems.
- ⚠ Roblox: per-player mob caps stay at Java values, but simulation detail drops for mobs far
  from all players.

## Phase 15 – Villagers, trading, raids (L)

**Villagers**
- Professions from job-site blocks, Java trade tables and levels, restocking, demand and
  pricing, gossip and reputation.
- Schedules (work, gather, sleep), breeding by beds and food, iron golem-role spawning.
- Zombie sieges, zombie villager curing (weakness + golden apple).
- Wandering trader and trader llamas.

**Raids**
- Illager-role mobs: pillager, vindicator, evoker (fangs, vex-role), ravager-role, witch.
  Names and designs to approve.
- Patrols, outposts, the Bad Omen effect, raid waves by difficulty, Hero of the Village.
- Woodland mansion inhabitants.

## Phase 16 – The Abyss (the fire dimension) (XL)

**Biomes:** all five. Equivalents of Nether wastes, soul sand valley, crimson and warped
forests, basalt deltas (names to approve).

**Blocks:** Scorchstone, Ashsand, soul soil-role, basalt, blackstone set, Ember Quartz ore and
quartz blocks, gold ore variant, Lumen Crystal, magma, the wart-role crop and blocks.
- The fungi, nylium, roots, vines, stems and hyphae (two wood sets), shroomlight-role.
- Respawn anchor-role, lodestone-role, ancient debris-role leading to Cindersteel.

**Structures** (all our own designs): fortress-role, bastion-role, ruined portals.

**Mobs:** original equivalents of ghast, blaze, magma cube, piglin and piglin brute (bartering
table, gold rules), zombified piglin, hoglin and zoglin, wither skeleton, strider (riding with
warped fungus on a stick).

**Mechanics**
- Portal ignition and shape rules, 1:8 coordinate linking and portal search.
- No water, beds explode, lava spreads further, compasses spin.
- ⚠ Roblox: all dimensions run on the same server as separate worlds (own chunk sets, mobs,
  saving), so friends stay together. The alternative, separate places, would split groups
  across servers. The cost is memory when players are in several dimensions at once, so we
  set a per-dimension view radius.

## Phase 17 – Brewing and all potions (M)

- Brewing stand and blaze powder-role fuel.
- Every Java potion and its modifiers (extended, level II, splash, lingering) with Java
  durations.
- Tipped arrows, cauldrons (filling, dyeing leather, washing banners), dragon's breath-role
  (phase 18).

## Phase 18 – The Void and the Voidwyrm (XL)

**Getting there:** Rift Shard + blaze-powder-role → a tracker item (name to approve) thrown to
find strongholds; end portal-role frame, filling and activation.

**The boss:** the Voidwyrm fight with Java behaviour (crystals and cages, perching, breath,
charging, healing). Respawning the boss with crystals, the egg-role trophy, and gateway portals.

**The outer islands:** chorus-role plants and fruit (teleport), purpur-role blocks, end
rod-role, and the city-role and ship-role structures (our own designs).
- Shulker-role mob and shulker box-role storage.
- **The glider** (our elytra equivalent: Java flight model, durability, repair, firework
  boosting, kinetic damage).

**Mechanics:** fireworks (stars, colours, shapes, boosting) and end crystals.
- ⚠ Roblox: glider flight is client-simulated with server-side speed and position checks.

## Phase 19 – The second boss, beacons, conduits (L)

- Second boss (Wither-role; name and design to approve): summoning shape, phases, explosions,
  the star-role drop.
- Beacon: pyramid tiers, powers, beam.
- Conduit: heart-role, prismarine frame, attacks.
- Respawn anchor and lodestone finishing touches if not done.

## Phase 20 – Navigation, books, maps, remaining items (M)

- Maps:
  - Exploring and zoom levels, locked and cloned maps, banners on maps, item frame display.
  - Explorer maps from cartographers.
  - ⚠ Roblox: map pixels are drawn with EditableImage, and the number of maps open at once is
    capped (editable memory budget).
- Compass, lodestone compass, clock, spyglass, recovery compass excluded (deep dark).
- Book and quill and written books. ⚠ Roblox: text filtering.
- Trident (loyalty, riptide, channeling), goat horns and music discs (our own sounds and
  music), name tags, saddles, totems (evoker-role drop), bundles.

## Phase 21 – Game modes, game rules, commands, multiplayer (L)

- Game modes: Survival, Creative (flight, instant break, creative inventory with search, pick
  block), Adventure, Spectator, Hardcore.
- All Java game rules (keepInventory, doDaylightCycle, doMobSpawning, mobGriefing,
  randomTickSpeed, doFireTick, naturalRegeneration, playersSleepingPercentage, ...).
- Commands with Java syntax and entity selectors:
  - Player and world: `/gamemode /tp /give /clear /time /weather /gamerule /difficulty
    /kill /effect /enchant /xp /spawnpoint /setworldspawn`.
  - Blocks and entities: `/summon /setblock /fill /clone /locate /seed /data`.
  - Logic and chat: `/execute /scoreboard /tellraw` (subset per need).
  - ⚠ Roblox: only the world owner and players they trust can run commands, through
    TextChatService; every chat message is filtered.
- Advancements (our own titles and icons where Java's are Mojang wording), statistics, death
  messages.
- Chat, player list, PvP toggle, per-world friend/trust lists, banning from your world.

## Phase 22 – Remodeling (L–XL)

A consistent, polished look for everything, all our own original designs:
- **Mobs:** every model redone, with Java-style animations (walk, attack, idle, special moves).
- **Textures:** every block texture, plus connected details (grass/foliage biome tints, animated
  water, lava, fire and portals).
- **Items and held items:** every item icon; held items as 3D extruded pixel sprites; third-person
  held items; armour and trims on avatars.
- **Effects and UI:**
  - A full Java-style particle set.
  - Every menu and container screen (furnaces, brewing, enchanting, anvil, loom, villager
    trading, beacon...) in one visual style.
  - HUD polish, accessibility (colour-blind-safe UI, subtitles for sounds).
- **Audio:** final licensed sounds for every slot and a complete licensed music set.

## Phase 23 – Release preparation (M)

- **Performance pass:** mobile memory and FPS, view distance per device, server load with full
  servers in several dimensions.
- **Tests:** DataStore budget and save-migration tests, long-session stability.
- **Store and platform:** Roblox platform requirements (experience questionnaire, text
  filtering audit), store page with our own art, how-to-play screens, bug reporting,
  localization.
- **Public release.**

---

## Roblox compromises (summary)

| Area | Compromise |
|---|---|
| World height −64…320 | 3× the blocks; needs a mobile memory check, a save migration, and possibly a lower view distance on phones |
| Tick rate | Game logic (Volt system, fluids, crops, mobs) runs in our own 20 TPS loops, not on Roblox's frame rate |
| Volt system | Very large machines get a per-tick work budget; Java order and timing are replicated, raw speed may differ |
| Vehicles | Minecarts, boats, horses and the glider are custom kinematic movement, not Roblox physics |
| Dimensions | One server holds all dimensions (friends stay together); memory limits per-dimension view radius |
| Light through slabs and stairs | Light passes through slabs and stairs as if they were open (Java blocks it by shape); a slab roof doesn't darken a room |
| Item frames | Show the item as a flat icon, not a 3D model |
| Player movement | The Humanoid only animates the body; Java physics runs in our own motor (Roblox's built-in walking, jumping and climbing are off) |
| Vines | Drawn as a thin leafy sheet without see-through gaps (the terrain mesh has no cut-out transparency) |
| Text | Every player-written text (signs, books, chat, names) uses Roblox filtering; commands only for the owner and players they trust |
| Maps | EditableImage memory budget caps the number of maps visible at once |
| Mobs | Java caps are kept; mobs far from players are simulated in less detail |
| Skins | Players use their Roblox avatar (blocky R6); armour is drawn over it |
| Audio and art | Licensed or our own only; music discs, note-block instruments, mob sounds and all art are our own |
