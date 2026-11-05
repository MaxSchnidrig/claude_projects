# ROCRAFT: Architecture

## 0. Direction and naming rules

- **Gameplay mechanics** follow the classic block-survival formula as closely as possible:
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

## 6. Mechanics spec (later phases)

Values follow the classic formula. Speeds are in blocks/s; at 3 studs per block, walk 4.317 → 13 studs/s and sprint 5.612 → 16.8 studs/s.

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
| Silent exploding hostile | **Cinderhusk**: a hunched, ash-grey walker with glowing cracks. It crackles audibly (clear warning) before bursting and breaking blocks | Different silhouette and colour, and it gives an audible warning instead of a silent approach |
| Tall teleporting neutral mob that moves blocks | **Shiftling**: a floating crystal-limbed figure that blinks between spots and carries one block | Drops **Rift Shard** (throwable teleport item) |
| Fire dimension | **The Underburn**: Scorchstone, Ashsand, Lumen Crystal (light block), Ember Quartz, portal framed with Obsidian | |
| End-game ore / tier | **Cindersteel** (upgrade above Diamond) | |
| End dimension and boss | **The Rim** (floating islands) and the **Voidwyrm** boss | |
| Default player look | The player's own Roblox avatar | No default skin needed |
