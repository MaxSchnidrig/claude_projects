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
Config.MAX_LIVE_EDITABLE = 2
-- Live EditableMeshes kept ready for instant block edits (LiveEditPool). Each slot holds 2 meshes
-- (opaque terrain + water), so 2 slots = 4 meshes. Edited sections bake straight from their slot
-- (no extra mesh), so the total stays at 4 + MAX_LIVE_EDITABLE (+1 priority) = 7. The Phase 2.x
-- test hit the budget at 8. 0 disables instant live edits.
Config.LIVE_EDIT_SLOTS = 2
-- Seconds the old geometry of a rebuilt section stays visible after the new geometry is parented
-- (prevents a see-through flash while the new MeshPart starts drawing). Raise if you still see it.
Config.RENDER_SWAP_OVERLAP = 0.15
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

-- Player & interaction (phase 2) -----------------------------------------------------------
Config.REACH = 4.5 -- blocks, from the eye (classic survival reach)
Config.REACH_TOLERANCE = 1.0 -- extra blocks the server allows for latency/position error
Config.BREAK_TIME_TOLERANCE = 0.8 -- server accepts a break after >= 80% of the expected time
Config.BREAK_LATENCY_SLACK = 0.1 -- seconds of extra slack on top of that
Config.BREAK_COOLDOWN = 0.25 -- seconds between finishing one block and starting the next
Config.PLACE_REPEAT = 0.2 -- seconds between placements while right mouse is held
Config.ACTIONS_PER_SECOND = 30 -- server rate limit for block actions
Config.EYE_HEIGHT = 1.6 -- studs above HumanoidRootPart centre (feet + 4.6 studs ≈ 1.53 blocks)

Config.WALK_SPEED = 13 -- studs/s (4.317 blocks/s)
Config.SPRINT_SPEED = 16.8 -- studs/s (5.612 blocks/s)
Config.JUMP_HEIGHT = 3.6 -- studs (1.2 blocks): clears 1-block steps, never 2
Config.KEY_SPRINT = "LeftControl"
Config.KEY_CAMERA = "V" -- cycle first person -> third person behind -> third person front
Config.MOUSE_SENSITIVITY = 0.2 -- degrees per pixel (multiplied by Roblox's own sensitivity setting)
Config.TOUCH_SENSITIVITY = 0.25 -- degrees per pixel of touch drag
Config.THIRD_PERSON_DISTANCE = 12 -- studs (4 blocks)

-- Avatar: every player is a blocky R6 rig with a cube head, keeping clothing and body colours.
Config.AVATAR_HEAD_SIZE = 1.5 -- studs, edge of the cube head
Config.KEEP_ACCESSORIES = false -- hats/hair would poke through blocks and break the blocky look
-- Print every asset ID on each player's HumanoidDescription when their character is built
-- (to track down "asset type does not match" errors).
Config.DEBUG_AVATAR = false

Config.HOTBAR_SLOTS = 9
Config.INVENTORY_SLOTS = 36 -- 9 hotbar + 27 main (main inventory UI arrives in phase 3)
-- Items given on spawn while testing in Studio (ignored in live games).
Config.STUDIO_STARTER_KIT = {
	{ "wooden_pickaxe", 1 },
	{ "stone_pickaxe", 1 },
	{ "iron_pickaxe", 1 },
	{ "diamond_pickaxe", 1 },
	{ "iron_shovel", 1 },
	{ "iron_axe", 1 },
	{ "oak_planks", 64 },
	{ "cobblestone", 64 },
	{ "glass", 64 },
}

-- Debug -------------------------------------------------------------------------------------
-- KeyCode names (strings, so this module stays loadable in headless tests).
Config.DEBUG_KEY_OVERLAY = "F3" -- toggle the performance overlay
Config.DEBUG_KEY_BACKEND = "F4" -- switch render backend (A/B test)
Config.DEBUG_KEY_KEEP_TEMP = "F6" -- keep edited sections on their live mesh (compare to baked)

return Config
