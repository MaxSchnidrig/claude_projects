# ROCRAFT roadmap (Phase 8+)

What ROCRAFT still lacks compared with Java Edition, grouped into phases and ordered by what
players miss most. That order follows the first hours of a typical survival game: shelter,
night, food, armour and caves first; magic, machines and dimensions later.

Rules for every phase stay the same:
- Java Edition values and behaviour.
- Only names, models, textures and sounds are original.
- No Mojang-coined names or designs. Every new original equivalent (a mob, item or dimension
  block) gets a name proposal for your approval before it's built.

Effort: S = a session, M = 2–3 sessions, L = 4+ sessions.

## Phase 8 – Everyday survival (L)

The gaps a new player notices in the first night.

| Feature | Notes |
|---|---|
| Flowing water and lava | Java flow rules: source/flowing levels, 8-block spread, lava 4 in the overworld, infinite water sources, cobblestone/stone/obsidian when they meet, drowning in flow, items carried by water |
| Buckets | Empty, water and lava buckets; milk comes in phase 9 |
| Beds | Sleep from dusk to skip the night, needs no hostile mob within 8 blocks, sets your spawn point; respawn there; bed colours later |
| Armour | Leather, chainmail (loot only), iron, gold and diamond: helmet, chestplate, leggings, boots. Java armour points and toughness (the damage formula already exists in `Combat`), durability, armour slots in the inventory, armour on avatars |
| Shield | Blocking, knockback, axe disabling it, durability |
| Player bow and arrows | Draw time, power, critical arrows, picking arrows up |
| Building blocks | Doors, trapdoors, ladders (climbing), fences and gates, slabs and stairs (first non-cube shapes), glass panes, bricks, stone bricks, smooth stone, more wood types |
| Signs | Text must go through Roblox's `TextService` filtering (a platform rule) |
| Fire | Flint and steel, fire spread and burn-out, catching fire, TNT ignition (TNT already exists) |
| Menus and settings | Main menu, pause menu, and settings: render distance, field of view, sensitivity, music/sound volumes, GUI scale, view bobbing toggle. In-game world settings: friends can join, difficulty (Peaceful/Easy/Normal/Hard) |
| Polish carried over | Fill in sounds (`SOUNDS.md`), better hand/item/particle look, held item in third person, textured dropped items |

## Phase 9 – Farming and animals (M)

| Feature | Notes |
|---|---|
| Crops | Hoe tilling, farmland with hydration, wheat (seeds from grass), carrots, potatoes, beetroot, growth stages and light rules, trampling |
| Bone meal | Made from bones; grows crops, saplings and grass |
| Trees from saplings | Saplings drop from leaves, grow by Java rules |
| Plants | Sugar cane (paper), pumpkins, melons, cactus, flowers, mushrooms |
| Breeding | Love mode, babies that grow up, Java breeding foods; leads |
| Animal products | Shearing sheep, dyes and 16 wool colours, milk, eggs (thrown eggs hatch chicks), feathers into arrows |
| Food | Bread already exists; add cake, cookies, pumpkin pie and mushroom stew |
| Status effects | The shared base for later phases: poison (spider eye), saturation, regeneration, and golden apples |

## Phase 10 – Experience and enchanting (M)

| Feature | Notes |
|---|---|
| Experience | Orbs from mobs, ores, smelting and breeding; Java level formula; XP bar; dropped on death |
| Enchanting | Enchanting table, bookshelves (power), lapis cost, three offers, Java enchantment pool and levels (Sharpness, Efficiency, Unbreaking, Protection, Fortune, Silk Touch, Looting, Power, Feather Falling…) |
| Anvil and grindstone | Repair, combining, renaming and cost; grindstone removes enchantments |
| Books | Books and enchanted books |

## Phase 11 – Volt system (the power-wire logic) (L)

| Feature | Notes |
|---|---|
| Power and wiring | Volt Dust wire (signal 0–15, −1 per block), Volt Torch, Volt Relay (repeater), Volt Comparator, lever, button, pressure plates, Volt Block |
| Machines | Pistons and sticky pistons, observers, hoppers, droppers, dispensers, note blocks |
| Timing | Java update order and timing (2 game ticks per relay step), quasi-connectivity: needed for builds to behave as players expect |
| Rails | Rails and minecarts, powered/detector rails |

## Phase 12 – Villages and trading (L)

| Feature | Notes |
|---|---|
| Villages | Generated villages per biome style |
| Villagers | Professions from job blocks, Java trading (emeralds, levels, restocks), breeding, gossip |
| Defenders and threats | A village defender (original design), zombie sieges, raids with original raider mobs (names to approve) |
| Wandering trader | Original design |

## Phase 13 – World generation and more mobs (L)

| Feature | Notes |
|---|---|
| Biomes | Jungle, swamp, savanna, badlands, taiga, mountains, deep oceans, rivers |
| Structures | Dungeons with spawners, mineshafts, desert/jungle temples, shipwrecks, ruined portals, strongholds (needed for phase 16) |
| Caves | Bigger cave systems and aquifers, as in modern Java. Raising the world height (to −64…320) would be a separate, bigger decision: it affects saving and performance |
| Mobs | Witch, slime and the zombie/skeleton variants for deserts, oceans and snow. All get original designs; names to approve where the Java name is Mojang's own |

## Phase 14 – The Abyss (the fire dimension) (L)

| Feature | Notes |
|---|---|
| Getting there | Obsidian portal lit with fire, linked portals (1:8 coordinates) |
| The dimension | Scorchstone, Ashsand, Lumen Crystal, Ember Quartz, lava seas, a fortress equivalent |
| Mobs | Original equivalents of the Java Nether mobs (names to approve) |
| Cindersteel | The top-tier material: its ore, the smithing table and an upgrade template equivalent |

## Phase 15 – Brewing (M)

Brewing stand, an original brewing ingredient from The Abyss, and Java potion recipes,
durations and splash/lingering potions, built on the phase 9 status effects.

## Phase 16 – The Void and the Voidwyrm (L)

| Feature | Notes |
|---|---|
| Getting there | Finding a stronghold with a Rift Shard-based tracker item, the portal room |
| The dimension | The Void's floating islands |
| Boss | The Voidwyrm fight with Java-like phases and crystals |
| After the fight | The outer islands, a city structure, and a glider item (original design) |

## Phase 17 and later

- A second boss.
- Beacons.
- Creative mode, advancements and statistics, maps.
- Chat moderation tools, more world-management options.
- LOD for longer view distances.

## First public release

**Recommended: after Phase 9 (farming and animals), as an Early Access release.**

By then the full early-game loop works the way a Java player expects:
- trees, tools, caves and ores;
- a bed and safe nights, armour, a bow;
- water and lava that flow;
- a food farm and breeding;
- your own saved world, and friends can join.

That covers what most players do in their first several hours. Releasing earlier (after Phase 8)
is possible as a closed test with friends. Without crops and breeding, though, food runs out
and the game feels unfinished.

Must-haves before going public, besides Phases 8 and 9:
1. **Sounds:** every slot in `SOUNDS.md` filled with licensed audio, plus a few music tracks.
2. **Menus:** main menu and settings (render distance and volume especially), and a working
   mobile control layout tested on a real phone.
3. **Load test:** a server with 4–8 players exploring in different directions (server chunk
   radius 8 and up to 70 hostile mobs per player), and a check of the DataStore budget during
   the test.
4. **Text filtering:** every player-written text (signs, world names, any chat we add) goes
   through `TextService`. Roblox requires this.
5. **Store page:** the experience questionnaire, icon and thumbnails (made from our own art),
   and a short "how to play" screen.
6. **Bugs:** a bug-report path (a simple in-game report button that logs to a DataStore, or a
   group wall).

XP and enchanting (Phase 10) and the Volt system (Phase 11) make good first big updates after
the release.
