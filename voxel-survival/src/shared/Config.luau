--!strict
-- Central tunables. Anything a designer might want to tweak lives here, not in system code.

local Config = {}

-- World dimensions --------------------------------------------------------------------------
Config.BLOCK_SIZE = 3 -- studs per block edge (default character ≈ 1.8 blocks tall)
Config.CHUNK_SIZE = 16 -- blocks per chunk edge (X and Z)
-- Java Edition height: y = -64 .. 319. Internally blocks are stored at y = 0 .. 383
-- (internal y = Java y + Y_OFFSET); Java coordinates are what players see (F3).
Config.WORLD_HEIGHT = 384 -- blocks, internal y = 0 .. 383
Config.Y_OFFSET = 64 -- internal y - Y_OFFSET = Java y
Config.SECTION_SIZE = 16 -- render/collision sections are 16³ slices of a chunk
Config.SECTIONS_PER_CHUNK = Config.WORLD_HEIGHT // Config.SECTION_SIZE
Config.SEA_LEVEL = 126 -- internal y of the water surface (Java y = 62)

-- Default world seed (Phase 6 replaces this with the owning player's world seed).
Config.DEFAULT_SEED = 1337

-- Streaming ---------------------------------------------------------------------------------
Config.RENDER_DISTANCE_DESKTOP = 6 -- chunks (radius)
Config.RENDER_DISTANCE_MOBILE = 4
Config.RENDER_DISTANCE_MIN = 2
Config.RENDER_DISTANCE_MAX = 12
Config.UNLOAD_MARGIN = 2 -- chunks beyond render distance before data is dropped (hysteresis)
Config.COLLISION_RADIUS = 1 -- chunks around the player that get collision boxes
Config.SERVER_CHUNK_RADIUS = 8 -- chunks the server keeps around each player (Java mob spawning reaches 128 blocks)

-- Frame budgets (milliseconds of Luau work per frame for the cooperative scheduler)
Config.FRAME_BUDGET_MS_DESKTOP = 4
Config.FRAME_BUDGET_MS_MOBILE = 2.5
Config.FRAME_BUDGET_MS_SERVER = 6
Config.MAX_MESH_UPLOADS_IN_FLIGHT = 3 -- concurrent mesh uploads (bake + CreateMeshPartAsync)
-- EditableMeshes alive at the same time. On live clients the editable memory budget is small
-- (forum reports: ~8 meshes), so meshes are baked to static content and destroyed right after
-- upload; this caps how many exist while waiting/uploading.
Config.MAX_LIVE_EDITABLE = 2
-- Live EditableMeshes kept ready for instant block edits (LiveEditPool), one per slot (opaque
-- terrain only; water etc. are Parts). Edited sections bake straight from their slot (no extra
-- mesh), so the total is 3 + MAX_LIVE_EDITABLE (+1 priority) = 6. The Phase 2.x test hit the
-- budget at 8. 3 slots cover an edit on a section corner (up to 3 sections). 0 disables.
Config.LIVE_EDIT_SLOTS = 3
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
Config.CAVE_RENDER_RADIUS = 2 -- chunks: deep sections drawn around you while above ground (cave culling)

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
-- Per-direction brightness baked into vertex colours (Java's directional face shading).
Config.FACE_SHADE = {
	top = 1.0,
	bottom = 0.5,
	north = 0.8,
	south = 0.8,
	east = 0.6,
	west = 0.6,
}
-- Phase 7: textured terrain (atlas, one quad per face with smooth light + ambient occlusion).
-- false = the old flat colours with merged quads (lighter on weak devices; also the F4 Parts mode).
Config.TEXTURES = true
Config.MESH_MAX_TRIANGLES = 19000 -- split a section into several meshes above this
Config.TORCH_POINT_LIGHTS = 24 -- nearest torches that also carry a Roblox PointLight
Config.SKY_MODE = "atmosphere" -- "atmosphere" (Roblox Atmosphere sky + haze) or "fog" (our fog dome)
Config.ATMOSPHERE_DENSITY = 0.45 -- haze density at render distance 6 (scaled for others)
Config.DEBUG_KEY_SKY_MODE = "F7" -- Studio only: switch the sky mode to compare
Config.CLOUD_Y = 196 -- cloud layer height (blocks); low enough to stay inside the fog distance

-- Player & interaction (phase 2) -----------------------------------------------------------
Config.REACH = 4.5 -- blocks, from the eye (classic survival reach)
Config.REACH_TOLERANCE = 1.0 -- extra blocks the server allows for latency/position error
Config.BREAK_TIME_TOLERANCE = 0.8 -- server accepts a break after >= 80% of the expected time
Config.BREAK_LATENCY_SLACK = 0.1 -- seconds of extra slack on top of that
Config.BREAK_COOLDOWN = 0.25 -- seconds between finishing one block and starting the next
Config.PLACE_REPEAT = 0.2 -- seconds between placements while right mouse is held
Config.ACTIONS_PER_SECOND = 30 -- server rate limit for block actions
Config.EYE_HEIGHT = 1.86 -- studs above HumanoidRootPart centre (feet + 4.86 studs = Java 1.62 blocks)
Config.EYE_HEIGHT_SNEAK = 0.81 -- sneaking: feet + 3.81 studs = Java 1.27 blocks

Config.WALK_SPEED = 12.95 -- studs/s (Java 4.317 blocks/s)
Config.SPRINT_SPEED = 16.84 -- studs/s (Java 5.612 blocks/s)
Config.JUMP_HEIGHT = 3.757 -- studs (Java 1.2522 blocks): clears 1-block steps, never 2
-- Sprinting: double-tap W (gamepad: click the left stick). No sprint key on purpose.
Config.SPRINT_DOUBLE_TAP = 0.35 -- Java: a second W press within 7 ticks of the first starts a sprint
Config.KEY_SNEAK = "LeftShift" -- hold to sneak
Config.SNEAK_SPEED_FACTOR = 0.3 -- Java sneaking: movement input x 0.3
Config.ITEM_USE_SPEED_FACTOR = 0.2 -- Java: movement input x 0.2 while eating / using an item
Config.GRAVITY = 96 -- studs/s^2 (Java 0.08 blocks/tick^2 = 32 blocks/s^2)
Config.TERMINAL_FALL_SPEED = 235 -- studs/s (Java 3.92 blocks/tick)
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

Config.KEY_INVENTORY = "E" -- open/close the inventory (and close any container)
Config.KEY_DROP = "Q" -- drop one of the held item (Ctrl+Q: the whole stack)
Config.ITEM_PICKUP_RADIUS = 1.6 -- blocks, from the player's centre to a dropped item
Config.ITEM_PICKUP_DELAY = 0.5 -- seconds before a mined drop can be picked up
Config.ITEM_DROP_PICKUP_DELAY = 2 -- seconds before an item you threw can be picked up again
Config.ITEM_DESPAWN_SECONDS = 300
Config.MAX_ITEM_ENTITIES = 400
Config.CONTAINER_REACH = 6 -- blocks: further away and an open container window closes

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
	{ "apple", 16 },
	{ "steak", 16 },
	{ "raw_iron", 16 },
	{ "coal", 16 },
	{ "oak_log", 32 },
}

-- Roblox default UI turned off on the client (our UI replaces them). Remove entries to test.
Config.CORE_GUI_DISABLE = { "Backpack", "Health", "EmotesMenu" }

-- Survival (phase 4) ---------------------------------------------------------------------------
Config.DAY_LENGTH_SECONDS = 1200 -- classic 20-minute day (24000 ticks at 20 ticks/s)
Config.START_TIME_TICKS = 1000 -- morning (0 = sunrise, 6000 = noon, 18000 = midnight)
Config.AUTO_RESPAWN_SECONDS = 120 -- safety net if the death screen never sends "respawn"
Config.DIFFICULTY = "normal" -- "easy": starvation stops at 10 HP, "normal": 1 HP, "hard": no limit

-- Mobs (phase 5) ------------------------------------------------------------------------------
-- Java Edition values: monster cap 70 and creature cap 10 per player area (17x17 chunks).
Config.MOB_CAP_HOSTILE_PER_PLAYER = 70
Config.MOB_CAP_PASSIVE_PER_PLAYER = 10
Config.MOB_SPAWN_MIN_DISTANCE = 24 -- blocks from every player
Config.MOB_SPAWN_MAX_DISTANCE = 128 -- spawning happens in loaded chunks; farther = instant despawn
Config.MOB_DESPAWN_DISTANCE = 128 -- hostiles beyond this from every player vanish at once
Config.MOB_DESPAWN_RANDOM_DISTANCE = 32 -- beyond this (and idle 30 s): 1/800 chance per tick
Config.MOB_SEND_DISTANCE = 96 -- mobs within this range are sent to a client (bandwidth limit)
Config.MOB_SNAPSHOT_HZ = 10
Config.SHIFT_CLICK_INTO_CRAFT_GRID = true -- Java: shift-click from the inventory fills the 3x3 grid first (slots 1-9, merging first), then hotbar <-> inventory

-- World simulation (phase 8) ----------------------------------------------------------------
Config.MAX_BLOCK_TICKS_PER_TICK = 3000 -- scheduled block ticks per game tick (fluids, fire...)
Config.DIFFICULTY_FIRE = 2 -- Java fire spread uses the difficulty id (Normal = 2)

-- Saving (phase 6) ----------------------------------------------------------------------------
Config.DATASTORE_NAME = "RocraftWorlds_v1" -- Studio uses DATASTORE_NAME .. "_Studio" (never live data)
Config.AUTOSAVE_SECONDS = 60
Config.STUDIO_OWNER_ID = 0 -- 0: in Studio the first player to join owns the world
Config.ACTIVE_WORLDS_MAP = "RocraftActiveWorlds" -- MemoryStore: worlds running now (for friends)

-- Debug -------------------------------------------------------------------------------------
-- KeyCode names (strings, so this module stays loadable in headless tests).
Config.DEBUG_KEY_OVERLAY = "F3" -- toggle the performance overlay
Config.DEBUG_KEY_BACKEND = "F4" -- switch render backend (A/B test)
Config.DEBUG_KEY_KEEP_TEMP = "F6" -- keep edited sections on their live mesh (compare to baked)
-- Letter keys: F-keys collide with Roblox/Studio/macOS shortcuts (F9 opens the Dev Console).
Config.DEBUG_KEY_SKIP_TIME = "J" -- Studio only: +6 game hours (quarter day)
Config.DEBUG_KEY_HURT_SELF = "K" -- Studio only: take 3 damage
Config.DEBUG_KEY_SPAWN_MOB = "L" -- Studio only: spawn the next mob type in front of you
Config.DEBUG_KEY_SPECTATOR = "N" -- Studio only: spectator flying (no collision); Space up, Shift down, double-tap W sprints
Config.SPECTATOR_SPEED = 10.92 -- blocks/s (Java flying speed; Ctrl doubles it)
Config.TERRAIN_MATERIAL = "Plastic" -- rougher than SmoothPlastic: less shine on blocks
Config.DEBUG_KEY_GIVE_KIT = "G" -- Studio only: test kit (torches, coal, buckets, flint and steel, TNT, sand, gravel, campfires, beef, planks)

return Config
