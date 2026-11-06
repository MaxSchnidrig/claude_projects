# ROCRAFT

A voxel survival sandbox for Roblox, managed with [Rojo](https://rojo.space). The gameplay
mechanics follow the classic block-survival formula. All art, sounds, UI and every invented name
are original to this project (see `ARCHITECTURE.md` → "Naming rules").

**Status:** Phase 3 (inventory, crafting, smelting, chests, dropped items) ready for Studio testing. Next: Phase 4 (survival).

## Structure

```
voxel-survival/
├── default.project.json   Rojo tree (what goes where in the place)
├── rokit.toml             Pinned toolchain (Rojo, Lune)
├── ARCHITECTURE.md        Design, data layouts, benchmarks, phase roadmap
├── src/
│   ├── shared/  -> ReplicatedStorage.Shared          pure, deterministic, used by both sides
│   │   ├── Config, GameInfo
│   │   ├── Blocks/    BlockDefs (data), TexturePalette, BlockRegistry (lookups)
│   │   ├── Items/     ItemDefs, ItemRegistry, Recipes (data), Crafting, SlotLogic, FurnaceLogic
│   │   ├── Gameplay/  Mining (classic break-time formula, harvest tiers)
│   │   ├── World/     Noise, ChunkData, Biomes, TerrainGen, Features/{Ores,Trees}, VoxelRaycast
│   │   ├── Meshing/   SectionSampler, GreedyMesher, BoxMerger
│   │   ├── Net/       Remotes
│   │   └── Util/      Hash (deterministic RNG), Scheduler (time-sliced jobs)
│   ├── server/  -> ServerScriptService               authoritative world
│   │   ├── Main.server.luau   the only server Script
│   │   ├── World/     WorldService (chunks + diffs), ChunkStreamer (sends diffs)
│   │   ├── Interaction/ BlockActionService (validates break/place)
│   │   ├── World/     (+) ItemEntityService (dropped items), BlockEntityService (furnaces, chests)
│   │   └── Player/    SpawnService, AvatarService (blocky R6), InventoryService (windows, crafting)
│   └── client/  -> StarterPlayer.StarterPlayerScripts  rendering, input, UI
│       ├── Main.client.luau   the only client LocalScript
│       ├── World/     ClientWorld (streaming, generation, job picking)
│       ├── Render/    ChunkRenderer, EditableMeshBackend, PartsBackend, CollisionBuilder, RenderStyle
│       ├── Player/    CameraController, MovementController, InventoryClient
│       ├── Interaction/ BlockInteraction (targeting, mining, placing)
│       ├── UI/        Hotbar, Crosshair, InventoryUI, ItemIcon, CoreGuiSetup
│       └── Debug/     DebugOverlay
└── tests/lune/          headless tests + benchmarks for the pure shared modules
```

Every system is a ModuleScript. There is exactly one bootstrap script per side.

## Running in Studio

1. Install the tools: `rokit install` in this folder (or install Rojo 7.7+ yourself).
2. Install the Rojo Studio plugin: `rojo plugin install`.
3. Start the sync server:

   ```bash
   rojo serve
   ```

4. In Studio, open a new **Baseplate** place, **delete `Workspace.Baseplate` and `Workspace.SpawnLocation`**, open the Rojo plugin and click **Connect**.
5. Press **Play**. Terrain streams in around you, and the character spawns once the ground under it has collision.

Build a place file without Studio: `rojo build -o rocraft.rbxl`.

### Controls
| Input | Action |
|---|---|
| Mouse | Look (mouse is locked to the centre) |
| WASD / Space | Move / jump (jump height 1.2 blocks) |
| Left Ctrl (hold) | Sprint while moving forward |
| Left mouse (hold) | Mine the targeted block |
| Right mouse (hold) | Place the held block (repeats) |
| 1–9 / mouse wheel | Select hotbar slot |
| E | Inventory (2×2 crafting). Esc or E closes |
| Right mouse on Crafting Table / Furnace / Chest | Open it (Shift + right mouse places against it) |
| In a window | Left: pick up/put/merge/swap · Right: take half/put one · Shift-click: quick-move · Result slot: craft (Shift: craft all) · Click outside: drop carried stack |
| Q / Ctrl+Q | Drop one / the whole held stack |
| V | Camera: first person → behind → front (`Config.KEY_CAMERA`) |
| Gamepad | R2 mine, L2 place, R1/L1 hotbar, L3 sprint, right stick look |
| Touch | Drag to look, "Mine"/"Place" buttons, tap a slot |

In Studio you spawn with a test kit (pickaxes of each tier, blocks) from `Config.STUDIO_STARTER_KIT`; live servers start empty.

### Debug keys
| Key | Action |
|---|---|
| F3 | Toggle the performance overlay (FPS, chunk queues, gen/mesh ms, MeshParts, triangles, errors) |
| F4 | Switch render backend: EditableMesh ↔ greedy Parts. Rebuilds everything so you can compare. |

Set render distance for testing: select your Player in Explorer during Play and add a number attribute `RenderDistance` (2–12).

## Tests (headless, no Studio needed)

The pure modules (noise, generation, meshing, registry) run under [Lune](https://lune-org.github.io/docs):

```bash
lune run tests/lune/run
```

```bash
lune run tests/lune/bench
```

```bash
lune run tests/lune/compile_all
```

- `run`: unit tests.
- `bench`: terrain statistics, timings, and instance counts for each rendering approach.
- `compile_all`: syntax-checks every file, including Roblox-only ones.
