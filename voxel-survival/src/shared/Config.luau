--!strict
-- Central tunables. Anything a designer might want to tweak lives here, not in system code.

local Config = {}

-- World dimensions --------------------------------------------------------------------------
Config.BLOCK_SIZE = 3 -- studs per block edge (default character ≈ 1.8 blocks tall)
Config.CHUNK_SIZE = 16 -- blocks per chunk edge (X and Z)
Config.WORLD_HEIGHT = 128 -- blocks, y = 0 .. 127
Config.SECTION_SIZE = 16 -- render/collision sections are 16³ slices of a chunk
Config.SECTIONS_PER_CHUNK = Config.WORLD_HEIGHT // Config.SECTION_SIZE
Config.SEA_LEVEL = 62 -- water surface is at y = SEA_LEVEL

-- Default world seed (Phase 6 replaces this with the owning player's world seed).
Config.DEFAULT_SEED = 1337

-- Streaming ---------------------------------------------------------------------------------
Config.RENDER_DISTANCE_DESKTOP = 6 -- chunks (radius)
Config.RENDER_DISTANCE_MOBILE = 4
Config.RENDER_DISTANCE_MIN = 2
Config.RENDER_DISTANCE_MAX = 12
Config.UNLOAD_MARGIN = 2 -- chunks beyond render distance before data is dropped (hysteresis)
Config.COLLISION_RADIUS = 1 -- chunks around the player that get collision boxes
Config.SERVER_CHUNK_RADIUS = 3 -- chunks the server keeps generated around each player

-- Frame budgets (milliseconds of Luau work per frame for the cooperative scheduler)
Config.FRAME_BUDGET_MS_DESKTOP = 4
Config.FRAME_BUDGET_MS_MOBILE = 2.5
Config.FRAME_BUDGET_MS_SERVER = 6
Config.MAX_MESH_UPLOADS_IN_FLIGHT = 3 -- concurrent mesh uploads (bake + CreateMeshPartAsync)
-- EditableMeshes alive at the same time. On live clients the editable memory budget is small
-- (forum reports: ~8 meshes), so meshes are baked to static content and destroyed right after
-- upload; this caps how many exist while waiting/uploading.
Config.MAX_LIVE_EDITABLE = 4
-- How long a section that fell back to Parts waits before trying EditableMesh again (seconds).
Config.EDITABLE_RETRY_SECONDS = 10
-- Render distance cap while degraded to Parts (Parts backend selected, or EditableMesh can't be
-- baked and its live budget is exhausted). Parts are ~15x more instances than meshes.
Config.PARTS_RENDER_DISTANCE = 4
-- In Parts mode, sections entirely below the surface (cave interiors, ~44% of all Parts) are only
-- built within this many chunks of the player.
Config.PARTS_CAVE_RADIUS = 2

-- Rendering ---------------------------------------------------------------------------------
-- "editable" = greedy mesh -> EditableMesh -> MeshPart (primary)
-- "parts"    = greedy-merged Parts (fallback; also used automatically if EditableMesh fails)
Config.RENDER_BACKEND = "editable"
-- If faces render inside-out in Studio (you only see them from behind), flip this.
Config.FLIP_WINDING = false
-- Bake colour + shading into EditableMesh vertex colours (MeshPart.Color stays white).
-- If terrain renders plain white in Studio, set this to false: the part colour is used instead
-- and per-face shading is lost.
Config.USE_VERTEX_COLORS = true
-- Per-texture render style overrides (texture key -> properties).
Config.TEXTURE_STYLE = {
	water = { transparency = 0.35 },
	ice = { transparency = 0.2 },
	glass = { transparency = 0.6 },
	lava = { neon = true },
}
-- Per-direction brightness multipliers baked into vertex colours (cheap fake lighting).
Config.FACE_SHADE = {
	top = 1.0,
	bottom = 0.55,
	north = 0.8,
	south = 0.8,
	east = 0.7,
	west = 0.7,
}

-- Debug -------------------------------------------------------------------------------------
-- KeyCode names (strings, so this module stays loadable in headless tests).
Config.DEBUG_KEY_OVERLAY = "F3" -- toggle the performance overlay
Config.DEBUG_KEY_BACKEND = "F4" -- switch render backend (A/B test)

return Config
