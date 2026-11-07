# ROCRAFT: Architecture

## 0. Direction and naming rules

- **Gameplay mechanics** replicate Java Edition as exactly as possible; minecraft.wiki values are the reference for every mechanic (see 5f). Only names, models, textures and sounds are original:
  - 3×3 / 2×2 crafting with the same recipe shapes
  - smelting
  - tool tiers Wood / Stone / Iron / Gold / Diamond and mining speeds
  - hunger and saturation, health, fall damage
  - a 20-minute day, mob spawning rules, biomes, ore depth bands
  - a power-wire logic system
- **Names:** plain real-world words where the classic game uses them (Grass Block, Stone, Oak Log, Iron Ore, Zombie, Cow, TNT, Furnace…).
- **Never used:** Mojang-coined names or designs (e.g. Creeper, Enderman, Ender Dragon, Steve, Redstone, Nether, Netherite), and their textures, sounds, music, logo or UI art. Where such a thing fills a gameplay role, we make an original equivalent with its own name and design (see 9, *pending approval*).
- **Look:** all art is original 16×16 pixel art in a blocky style. Until Phase 7 every face is a flat placeholder colour.
- **Player look:** the player's own Roblox avatar. There's no default skin.

## 1. Core decisions

| Topic | Decision |
|---|---|
| Block size | 1 block = 3 studs (character ≈ 1.8 blocks tall) |
| World | y 0..127, sea level 62, bedrock floor y 0–4 |
| Chunk | 16×16×128 block IDs in one 32 KB `buffer` (u8 IDs). Index `x + z*16 + y*256` |
| Render unit | 16³ section (8 per chunk). An edit rebuilds 1 section |
| World data | Client and server generate identically from the seed. The server sends only per-chunk **diffs** (edits since generation) |
| Authority | The server owns block state. Clients send requests and render what the server confirms |
| Rendering | Client only: greedy mesh → EditableMesh → MeshPart, one per (section, texture). Fallback: greedy Parts |
| Collision | Client only: invisible merged boxes of solid blocks within 1 chunk of the player |
| Saving (Phase 6) | Player-owned worlds in **reserved servers**; friends can join. Inventories plus chunk diffs in DataStores |

## 2. Data flow

```
Server                                              Client
------                                              ------
WorldService  seed ──(attribute)──────────────────▶ ClientWorld: TerrainGen.generate(seed, chunk)
              chunks near players (validation, mobs)          │ chunk generated
              diffs[chunkKey] = {blockIdx -> id}               ▼
ChunkStreamer ◀──────── ChunkRequest {load, unload} ─────────  request diffs
              ─────── ChunkDiffs {key, packed} ─────────────▶ apply diffs → mark sections dirty
                                                                │
                                                     Scheduler picks nearest work:
                                                     collision near player > generate > mesh
                                                                │
                                                     ChunkRenderer → EditableMeshBackend (async upload)
                                                                   → PartsBackend (fallback)
                                                                   → CollisionBuilder
SpawnService  ◀──────── WorldReady (collision under spawn built)
              LoadCharacter + PivotTo(spawn)
```

## 3. Terrain generation (Phase 1, done)

All generation runs on a seeded noise implementation (our own Perlin "improved noise"). It uses only exact arithmetic, so server, client and tests produce bit-identical chunks.

| Step | How |
|---|---|
| Height | Continentalness (ocean ↔ land), rolling hills (4-octave fBm), ridged mountain ranges masked by a low-frequency field |
| Biomes | From height, temperature (cools with altitude), humidity: Ocean, Frozen Ocean, Beach, Plains, Forest, Birch Forest, Taiga, Snowy Tundra, Desert, Mountains |
| Surface | Biome surface + 3–4 subsurface; desert sandstone; mountain stone on slopes ≥ 3, snow ≥ y100; ocean floors of sand, gravel, dirt and clay; frozen seas get an ice cap |
| Caves | Two-noise "spaghetti" tunnels + deep "cheese" caverns. Density is sampled on a 4-block lattice and interpolated. Air at y ≤ 10 becomes lava. There's always a 5-block lid under water |
| Ores | Seeded random-walk veins that only replace Stone (table below) |
| Trees | Oak, Birch, Spruce by biome. Each chunk's tree list is a pure function of the seed, so canopies crossing chunk borders match exactly |

Measured over 64 chunks, seed 1337 (`lune run tests/lune/bench`):

| Ore | per chunk | y-range | | Ore | per chunk | y-range |
|---|---|---|---|---|---|---|
| Coal | 104 | 1–100 | | Gold | 8.6 | 1–34 |
| Iron | 106 | 1–66 | | Diamond | 3.5 | 1–19 |
| Copper | 44 | 1–94 | | Lapis | 4.6 | 1–28 (peak 16) |
| Volt (power) | 31 | 1–18 | | Emerald | 1.7 | 4–31, mountains only |

**Biome coverage** (6400×6400 blocks):

| Biome | Coverage |
|---|---|
| Ocean | 29% |
| Plains | 20% |
| Forest | 11% |
| Mountains | 10% |
| Taiga | 9% |
| Desert | 8% |
| Beach | 7% |
| Birch Forest | 3% |
| Snowy Tundra | 3% |
| Frozen Ocean | 1% |

**Surface height:** median y65, p90 y84, p99 y110.

**Caves:** 5.9% of underground cells are air.

## 4. Rendering: benchmark and tradeoffs

Measured with the Lune interpreter on the dev machine (the Roblox client also interprets Luau). Treat the times as relative and confirm in Studio with F3/F4 and the MicroProfiler.

Instance counts per chunk, and for render distance 6 (137 chunks):

| Approach | Instances / chunk | Instances @ RD 6 | Triangles / chunk |
|---|---:|---:|---:|
| A. 1 Part per block | 20,684 | 2,833,681 | engine |
| A2. 1 Part per exposed block | 1,040 | 142,533 | engine |
| B. 1 Part per visible face (culled) | 1,497 | 205,135 | ~3,000 |
| C. Greedy Parts per block type | 295 | 40,373 | engine |
| C2. C + buried blocks as wildcards (**fallback**) | 253 | 34,627 | engine |
| D. Greedy EditableMesh, 1 MeshPart / texture | 18 | 2,477 | ~1,340 |
| D2. Greedy EditableMesh, 1 MeshPart / material (**primary**) | **6** | **784** | **~1,340** |

In Parts mode, cave sections entirely below the surface are culled beyond 2 chunks. Those sections hold about 44% of all Parts.

Collision boxes near the player are about 215 per chunk, for 9 chunks only (~1,900 Parts).

| Work item (Lune interpreter) | avg | worst |
|---|---:|---:|
| Generate one chunk | 12–15 ms | — |
| Pad a section (copy + borders) | 0.2 ms | — |
| Classify + greedy-mesh a section | 2.3–2.9 ms | ~8.5 ms |
| Collision boxes for a section | 1.0 ms | — |

Of 288 sections, about 20% are empty sky and about 13% are buried (no visible face). Both are skipped after a quick check.

**Time-slicing:** every job yields at checkpoints, inside generation per row of columns and inside meshing per face direction. The per-frame budget is 4 ms on desktop and 2.5 ms on mobile. A full RD 6 load is about 3 s of CPU, spread over frames, nearest chunks first.

### EditableMesh memory budget (found in Phase 1 Studio test)
Roblox gives clients a small "editable memory budget". Studio-in-edit and servers are unlimited. Forum reports put the live client limit at about 8 meshes, with no fixed count: `CreateEditableMesh` simply returns nil once the budget is used. Phase 1 kept every EditableMesh alive for as long as its MeshPart existed, so the budget was gone after 8 MeshParts. That was a design flaw, not a leak.

**Fix (Phase 1.1):**
1. Build the EditableMesh.
2. `AssetService:CreateDataModelContentAsync` bakes it into static content.
3. `CreateMeshPartAsync(staticContent)` makes the MeshPart.
4. The EditableMesh is destroyed immediately.

Only meshes in flight now count (cap `MAX_LIVE_EDITABLE` = 4).

- **Live mode:** if baking is unavailable, the MeshPart must keep its EditableMesh alive. The renderer learns the device cap and gives mesh slots to the nearest sections (a nearer section demotes the farthest one to Parts). It also reduces render distance to `PARTS_RENDER_DISTANCE`.
- **Fallback is per section:** a failed section becomes Parts and retries after 10 s.
- **Fewer, larger meshes:** with vertex colours, all opaque textures of a section share one mesh, giving about 1–2 MeshParts per section instead of one per texture. Phase 7 textures will need either per-texture meshes or an atlas. An atlas can't tile across a merged quad, so it would mean un-merged quads: about 2.2× more triangles, but still 6 MeshParts per chunk.

**Tradeoffs:**
- **D (EditableMesh)** has the fewest instances and draw calls by far. Costs:
  - one async `CreateMeshPartAsync` per (section, texture);
  - a per-device **memory budget**: creation fails when it runs out, and we fall back to C automatically;
  - one texture per MeshPart: Roblox can't repeat one tile of an atlas, which is why we split by texture.
- **C (greedy Parts)** works on every device but needs 15× more instances, and each box shows one colour on all sides. Use F4 to compare live.
- **Faces before vs after merging** is 1,497 → 669 per chunk (2.2×). Caves underground account for a large share. A future optimisation is to skip sections the camera can't see into ("cave culling").

### Things I couldn't verify without Studio (Phase 1 checklist)
1. **Face winding.** If terrain is only visible from inside or behind, set `Config.FLIP_WINDING = true`. A test asserts the winding is consistent; Roblox's front-face convention is the unknown.
2. **Vertex colours.** If terrain is plain white, set `Config.USE_VERTEX_COLORS = false`.
3. **EditableMesh availability and budget.** The F3 overlay shows `fallbacks` and the last EditableMesh error.

## 5. Networking and authority

| Remote | Direction | Payload |
|---|---|---|
| `ChunkRequest` | C→S | `{load = {key…}, unload = {key…}}`, max 128 keys, 20 requests/s per player (token bucket), type-checked |
| `ChunkDiffs` | S→C | `{{key, packedDiffs}…}`. A diff record is `u16 index, u8 id` |
| `WorldReady` | C→S | Collision under the spawn point exists, so the server spawns the character |
| `BlockChanged` | S→C | Phase 2 |

Phase 2 server validation for break and place:
- integer coordinates, inside the world, chunk loaded;
- reach ≤ 4.5 blocks plus tolerance, measured from the head;
- line of sight via voxel DDA;
- the held tool comes from the server-side inventory;
- break time ≥ 80% of the expected time;
- placed blocks can't overlap players.

## 5b. Phase 2: player interaction (built)

| Piece | Design |
|---|---|
| Avatar | `CreateHumanoidModelFromDescription(desc, R6)` with all body-part packages cleared (plain box limbs), the R6 head mesh switched to a 1.5-stud cube, and accessories removed. Clothing, body colours and face are kept. R6 has no scaling, so every hitbox is 2 studs wide and 5 tall: it fits 2-block-tall and 1-block-wide gaps, never 1-block-tall gaps. Climbing is disabled so block walls can't be climbed |
| Movement | Walk 13 studs/s, sprint 16.8 (Left Ctrl, forward only, slight FOV kick), jump height 3.6 studs (1.2 blocks) |
| Camera | Scriptable camera; first person by default with the mouse locked; V cycles first → behind → front (F5 is taken by Studio on macOS). The body turns to the look yaw. Third-person cameras are pulled in front of terrain |
| Targeting | Voxel raycast from the eye (root + 1.6 studs) along the look direction, reach 4.5 blocks, using the client's block data. A thin dark SelectionBox outlines the target |
| Mining | `breakSeconds = ceil(1 / (speed / hardness / (30 or 100))) / 20`, slowed 5× airborne or under water; a 0.25 s cooldown between blocks. The client predicts; the server checks elapsed ≥ 80% of the on-ground time − 0.1 s, the same tool held, reach and line of sight |
| Placing | Against the targeted face, into air or liquid, never overlapping a character, repeats every 0.2 s while held |
| Inventory | Server-owned 36 slots (9 hotbar + 27 main), stacks of 64 (tools 1, snowballs 16), tool durability with classic values. Drops go straight into the inventory until phase 3 adds item entities |
| Corrections | Every rejected action answers the requester with the true block state, which undoes the client's prediction |

## 5c. Phase 3: inventory, crafting, smelting (built)

| Piece | Design |
|---|---|
| Authority | The server owns every slot. Clients send intentions (`InventoryAction`: click/open/close/drop); the rules are pure shared modules (`SlotLogic`, `Crafting`, `FurnaceLogic`), unit-tested headless |
| Windows | inventory (2×2 grid), crafting_table (3×3), furnace (input/fuel/output), chest (27). Opening a block window needs reach; it closes when you walk away (>6 blocks) or the block is broken. Closing returns grid and cursor items to the inventory, or drops them if full |
| Clicks | Classic: left = pick up/put/merge/swap, right = half/one, shift = quick-move (hotbar ↔ main, inventory ↔ container; furnace sorts smeltables into input and fuel into fuel), result slot crafts once or as many as fit |
| Recipes | `Items/Recipes.luau`: shaped (anywhere in the grid, mirrored) and shapeless, tags such as `#planks`. Covers planks, sticks, crafting table, chest, furnace, all tools × 5 tiers, shears, sandstone, snow and clay blocks. Validated at load time |
| Furnace | 10 s per item; fuel: coal/charcoal 80 s (8 items), planks/logs 15 s, sticks 5 s, wooden tools 10 s. Ticks on the server 4× per second; progress cools down without fire |
| Dropped items | Mined blocks, thrown items (Q) and container contents become item entities. They rest on the first solid block below and re-settle if it's mined. Picked up within 1.6 blocks (0.5 s delay, 2 s for thrown items), despawn after 5 min, max 400. Spin/bob is animated client-side |
| Not yet | Saving block entities and inventories (phase 6), item merging on the ground, drag-to-distribute |

## 5d. Phase 4: survival (built)

| Piece | Design |
|---|---|
| Rules | `Gameplay/SurvivalRules` (pure, tested): 20 HP; 20 food + saturation ≤ food; exhaustion 4.0 per point (sprint 0.1/block, jump 0.05, sprint-jump 0.2, block break 0.005, damage 0.1, healing 6.0); regen 1 HP/0.5 s at food 20 with saturation, 1 HP/4 s at food ≥ 18; starvation 1 per 4 s at food 0 (Normal: not below 1 HP); sprint needs food > 6; fall damage `ceil(blocks − 3)`, none into liquid |
| Server | `SurvivalService` owns Humanoid.Health (MaxHealth 20; Roblox's default regen script removed). Ground, water, lava and air are read from voxel data at the character's position (the server has no terrain physics). Drowning after 15 s underwater, 2 HP/s; lava 4 HP per 0.5 s; below y −64 instant death |
| Eating | Hold right-click with food: 1.6 s, server checks elapsed time, held slot and that food < 20. Food items with classic values (apple, bread, raw/cooked pork, beef/steak, chicken, mutton); meats smelt to cooked versions; apples 0.5 % and sticks 2 % from leaves |
| Death | Drops the whole inventory (incl. crafting grid and cursor) where you died, death screen with cause, Respawn button → world spawn with full health and hunger; automatic respawn after 120 s as a safety net |
| Day/night | 20-minute day (24000 ticks): 0 sunrise, 6000 noon, 12000 sunset, 18000 midnight. The server publishes a reference (ticks at server time); clients compute time locally each frame and set ClockTime, brightness, ambient and fog colour along a daylight curve (dusk 12000–13800, dawn 22200–24000) |
| Swimming | Humanoids only swim in Roblox Terrain water, so the client does it: hold jump to rise, sink slowly otherwise, 0.6× speed in liquid |

## 5e. Phase 5: mobs (built)

| Piece | Design |
|---|---|
| Simulation | Server-only data (no replicated Instances). 20 Hz: AI sets a desired velocity, then Java per-tick integration (acceleration, friction 0.546 ground / 0.91 air / 0.8 water, gravity 0.08 with drag 0.98, jump 0.42, swim-up 0.04, spiders climb 0.2) moves the box with `MobPhysics`; falls, lava, fire and daylight burning apply. Mobs only touch loaded chunks (unloaded = solid), so they never trigger chunk generation |
| Pathfinding | `Pathfinder`: A* over walkable cells (floor solid, height free), steps up 1, drops up to 3, 250 node budget, repath every second; partial paths when the goal is out of budget |
| Replication | `MobSnapshot` (UnreliableRemoteEvent) 10 Hz per player, mobs within 96 blocks: id, type code, position, yaw, pitch, flags. Clients interpolate 150 ms back and animate locally; `MobEvent` (reliable) carries hurt, death, teleport and explosion effects |
| Mobs / spawning / combat | Java values since 0.5.2: see 5f |
| New items | Swords (5 tiers), leather, feather, bone, arrow, string, gunpowder, rotten flesh, Void Shard; recipes for swords, wool from string, TNT (no ignition yet) |

## 5f. Java parity check (0.5.2)

Reference: minecraft.wiki (Java Edition, Normal difficulty). Speeds: a mob with movement value
`s` (attribute × goal modifier) walks `43.17 × s²` blocks/s. 1 block = 3 studs.

### Mobs

| Mob | Value | Before 0.5.2 | Java (now) |
|---|---|---|---|
| All hostiles | Detection | nearest player in range, no sight needed | needs line of sight (any block with collision blocks it, glass and leaves included), ±4 blocks vertically, checked about every 0.5 s; target kept while in range and seen within 3 s; hitting a mob makes it target you |
| All | Knockback | 7 b/s sideways + 5 b/s up | 0.4 blocks/tick: `v/2 + dir × 0.4`, up `min(0.4, vy/2 + 0.4)` only when on the ground; +0.5 for a full-strength sprint hit |
| All | Invulnerability | 0.5 s, later hits ignored | 0.5 s; a stronger hit deals the difference without knockback (players too) |
| All | Melee reach | centre distance ≤ reach + 0.35 | attacker box grown by 0.83 blocks horizontally touches the target box, with line of sight |
| Zombie | Speed | 2.3 b/s | 0.23 → 2.28 b/s |
| Zombie | Follow range / armor | 24 / 0 | 35 / 2 |
| Zombie | Drops | rotten flesh 0–2 | + iron ingot, carrot or potato (2.5 % total, player kills; baked potato if burning) |
| Zombie / Skeleton | Daylight | burn while in the sun | `brightness > 0.5`, chance `(b − 0.4) × 2 / 30` per tick, open sky at the eyes → 8 s of fire |
| Skeleton | Speed / height | 2.5 b/s / 1.95 | 0.25 → 2.70 b/s / 1.99 |
| Skeleton | Bow | range 14, every 2–2.6 s, 24 b/s, 2–4 damage, backs off < 5 | range 15, 1 s draw + 2 s wait, 32 b/s (1.6 b/tick, inaccuracy 6), 3–5 damage, strafes after 1 s in view, backs off < 3.75 |
| Spider | Speed | 3.0 b/s | 0.3 → 3.89 b/s |
| Spider | Neutral | daylight under open sky | targets only at brightness < 0.5; in light 1 % per tick to give up |
| Spider | Leap / climb | 6 b/s, < 3.5 blocks / 3 b/s | 0.4 b/tick from 2–4 blocks / 0.2 b/tick (4 b/s) |
| Spider | Drops | string 0–2 | + spider eye 0–1 (1/3, player kills) |
| Sneaker (Creeper) | Size / speed | 0.7 × 1.5 / 2.5 b/s | 0.6 × 1.7 / 2.70 b/s |
| Sneaker | Fuse | sight only to start, runs within 7 | starts within 3; runs only while the target is within 7 **and visible**, else cools down |
| Voidling (Enderman) | Size / follow | 0.6 × 2.6 / 24 | 0.6 × 2.9 / 64 |
| Voidling | Speed | 3.0 b/s | calm 0.3 → 3.89 b/s, angry 0.45 → 8.74 b/s |
| Voidling | Provoked by | being hit, blocks broken within 4 blocks | being hit, or a player looking at its eyes for 5 ticks within 64 blocks with clear sight (anger 20–39 s); freezes while stared at, teleports away if you come within 4, teleports toward targets beyond 16 |
| Voidling | Teleports | random every 20–50 s, 50 % when hurt, out of water | Java rules: water hurts it (1/tick) and it tries to teleport out; hits from non-living sources 90 %; dodges arrows; daylight under open sky at random |
| Cow / Pig / Sheep / Chicken | Speed | 2.0 b/s, wander at half speed | 0.2 / 0.25 / 0.23 / 0.25 → 1.73 / 2.70 / 2.28 / 2.70 b/s, stroll at full speed every ~6 s within 10 blocks |
| Cow / Pig / Sheep / Chicken | Panic | ×1.25 for 5 s | ×2 / ×1.25 / ×1.25 / ×1.4 for 5 s (cow 6.9 b/s) |
| All | Group sizes | 1–3 / 2–4 / 1–2 | 4 (zombie, skeleton, spider, sneaker, animals), voidling 1–4; weights zombie 95, others 100, voidling 10 |
| Hostile spawning | Rules | 1 attempt/s, 24–48 blocks, night sky or caves | packs at random heights in loaded chunks (server radius 8 chunks), 24–128 blocks, light: fail if sky > rand(32), then `(sky − darkening) ≤ rand(8)`; cap 70 per player |
| Hostile despawn | Rules | > 64 blocks; > 32: 1/40 per s | > 128 blocks instantly; > 32 and idle 30 s: 1/800 per tick |
| Animals | Spawning | every 6 s by day, despawn far away | with new chunks (10 % per chunk, group of 4) and every 20 s on grass with light > 8; cap 10; never despawn (parked with their chunk) |
| Burning (mobs) | Lava fire | 8 s | 15 s; fire 1 per second |

### Player

| Value | Before | Java (now) |
|---|---|---|
| Block reach / entity reach | 4.5 / 3 | same |
| Walk / sprint | 13 / 16.8 studs/s | 12.95 / 16.84 studs/s (4.317 / 5.612 b/s) |
| Jump height | 3.6 studs (1.2 blocks) | 3.757 studs (1.2522 blocks) |
| Hand attack cooldown | 0.25 s | 0.25 s (speed 4); switching items restarts the cooldown |
| Critical hits | none | charge > 0.9, falling, airborne, not sprinting, not in liquid → ×1.5 with sparks |
| Invulnerability | none | 0.5 s with the difference rule |
| Lava | 4 per 0.5 s | same + 15 s of fire (1 per second, water puts it out) |

### Tools and weapons (wood / stone / iron / gold / diamond)

| Kind | Damage | Attack speed (seconds per full hit) | Before |
|---|---|---|---|
| Sword | 4 / 5 / 6 / 4 / 7 | 1.6 (0.625 s) | same |
| Axe | 7 / 9 / 9 / 7 / 9 | 0.8 / 0.8 / 0.9 / 1.0 / 1.0 (1.25 / 1.25 / 1.11 / 1 / 1 s) | 1.1 s for all tiers |
| Pickaxe | 2 / 3 / 4 / 2 / 5 | 1.2 (0.83 s) | same |
| Shovel | 2.5 / 3.5 / 4.5 / 2.5 / 5.5 | 1.0 (1 s) | same |
| Hoe | 1 | 1 / 2 / 3 / 1 / 4 (1 / 0.5 / 0.33 / 1 / 0.25 s) | 1 s for all tiers |

Mining speeds (2 / 4 / 6 / 12 / 8) and durability (59 / 131 / 250 / 32 / 1561, shears 238) already
matched. Durability loss now follows Java: breaking a block with hardness > 0 costs swords 2 and
every other tool 1 (before: 1 for everything); hitting a mob costs swords 1, other tools 2, shears 0
(before: shears 2).

### Not replicated yet

Sword sweep attacks, experience, Voidlings picking up blocks, sneaking, block light (torches),
status effects (spider eye poison), and the attack-cooldown reset on swings that hit nothing.

## 6. Mechanics spec (later phases)

Values follow the classic formula. Speeds are in blocks/s; at 3 studs per block, walk 4.317 → 12.95 studs/s and sprint 5.612 → 16.84 studs/s.

| System | Spec |
|---|---|
| Mining | `time = hardness × (1.5 if the correct tool can harvest, else 5) / speed`. Tool speeds: hand 1, wood 2, stone 4, iron 6, diamond 8, gold 12. Harvest tiers as in `BlockDefs.minTier` |
| Health / hunger | 20 HP. 20 hunger points plus hidden saturation (capped at the hunger level). Exhaustion from actions; natural regen at hunger ≥ 18; starvation below 0 |
| Fall damage | `max(0, fallDistance − 3)` HP |
| Day / night | 20 minutes total: 10 min day, 1.5 min dusk, 7 min night, 1.5 min dawn |
| Hostile spawning | Light level ≤ 7 (night surface, caves); pack spawning; despawn beyond 128 blocks |
| Crafting | 2×2 in the inventory, 3×3 at the Crafting Table, shaped and shapeless recipes; furnace smelting with fuel values |
| Power wire | Signal strength 0–15, wire decay 1 per block, sources (lever, button, plate, Volt Torch), Volt Relay (delay/lock), Volt Comparator, pistons. Tick-based, server-side |

## 7. Things Roblox can't do directly, and our alternatives

| Wanted | Problem | Plan |
|---|---|---|
| Swimming in voxel water | Humanoid swimming only works in Roblox Terrain water, whose 4-stud grid doesn't match our blocks | Custom swim controller (buoyancy, slow movement, jump = swim up) |
| Flowing water / lava | A full fluid simulation is costly | Static at generation. Simple tick-based spreading after a player edit (later phase) |
| Pixel textures without asset uploads | Rojo syncs instances, not image assets | Generate the 16×16 art at runtime with EditableImage from palette arrays in code. Fallback: asset IDs you upload |
| Server-side terrain physics | Geometry exists only on clients | Mobs move kinematically on the voxel grid; the server validates player positions loosely |
| One shared world across servers | DataStores have no live sync | Player-owned worlds in reserved servers (decided) |

## 8. Persistence (Phase 6)
- Key `p:<userId>` holds the player's inventory, stats and position.
- Key `w:<ownerId>:meta` holds the world's seed, owner and allowed friends.
- Key `w:<ownerId>:c:<cx>:<cz>` holds the packed chunk diffs.
- All writes use `UpdateAsync` through a queue that:
  - checks `GetRequestBudgetForRequestType` before each request;
  - backs off exponentially with jitter;
  - merges writes to the same key, respecting the 6 s per-key limit;
  - flushes every 60 s, on unload, and in `BindToClose`.

## 9. Original equivalents: **approved** (designs must read clearly original)

| Gameplay role | Proposal | Notes |
|---|---|---|
| Signal-dust / logic wire system | **Volt**: Volt Ore, Volt Dust, Volt Wire, Volt Torch, Volt Relay (repeater), Volt Comparator, Volt Lamp, Volt Block | Already used in generation as `volt_ore` (purple placeholder) |
| Silent exploding hostile | **Sneaker**: a hunched, ash-grey walker with glowing cracks. It crackles audibly (clear warning) before bursting and breaking blocks | Different silhouette and colour, and it gives an audible warning instead of a silent approach |
| Tall teleporting neutral mob that moves blocks | **Voidling**: a floating crystal-limbed figure that blinks between spots and carries one block | Drops **Void Shard** (throwable teleport item) |
| Fire dimension | **The Abyss**: Scorchstone, Ashsand, Lumen Crystal (light block), Ember Quartz, portal framed with Obsidian | |
| End-game ore / tier | **Cindersteel** (upgrade above Diamond) | |
| End dimension and boss | **The Void** (floating islands) and the **Voidwyrm** boss | |
| Default player look | The player's own Roblox avatar | No default skin needed |
