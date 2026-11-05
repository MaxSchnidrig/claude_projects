# ROCRAFT

A voxel survival sandbox for Roblox, managed with [Rojo](https://rojo.space). The gameplay
mechanics follow the classic block-survival formula. All art, sounds, UI and every invented name
are original to this project (see `ARCHITECTURE.md` → "Naming rules").

**Status:** Phase 1 (terrain) complete. Next: Phase 2 (player interaction).

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
│   │   ├── World/     Noise, ChunkData, Biomes, TerrainGen, Features/{Ores,Trees}
│   │   ├── Meshing/   SectionSampler, GreedyMesher, BoxMerger
│   │   ├── Net/       Remotes
│   │   └── Util/      Hash (deterministic RNG), Scheduler (time-sliced jobs)
│   ├── server/  -> ServerScriptService               authoritative world
│   │   ├── Main.server.luau   the only server Script
│   │   ├── World/     WorldService (chunks + diffs), ChunkStreamer (sends diffs)
│   │   └── Player/    SpawnService
│   └── client/  -> StarterPlayer.StarterPlayerScripts  rendering, input, UI
│       ├── Main.client.luau   the only client LocalScript
│       ├── World/     ClientWorld (streaming, generation, job picking)
│       ├── Render/    ChunkRenderer, EditableMeshBackend, PartsBackend, CollisionBuilder, RenderStyle
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
