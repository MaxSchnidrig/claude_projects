--!strict
-- Block data. Adding a block = adding one entry here (plus a texture colour in TexturePalette).
--
-- IDs ARE PERMANENT: saved worlds store block IDs, so never renumber or reuse an ID.
-- Leave gaps instead of deleting.
--
-- Fields:
--   id          permanent numeric ID (1..4095, 0 is air; stored as u16)
--   key         internal string key (snake_case)
--   name        display name
--   hardness    seconds-scale hardness (same scale as classic voxel-survival games); -1 = unbreakable
--   tool        preferred tool type: "pickaxe" | "axe" | "shovel" | "hoe" | "shears" | nil
--   minTier     tool tier needed to get a drop: 0 hand, 1 wood/gold, 2 stone, 3 iron, 4 diamond
--   drop        item key dropped when harvested (nil = drops itself; false = drops nothing)
--   dropMin/dropMax  drop count range (default 1)
--   textures    { all = key } or { top = , side = , bottom = }
--   solid       blocks movement (default true)
--   transparent light/vision passes through; neighbours' faces stay visible (default false)
--   liquid      fluid block (default false)
--   cullSelf    hide faces between two blocks of this same type (glass, water) (default true)
--   bonusDrops  extra chance drops when broken by hand or any tool: { { item, chance } }
--   light       light emitted, 0-15 (lava 15, torch 14)
--   opacity     how much light it removes passing through (0 clear .. 15 opaque); default 15
--               for opaque blocks, 0 otherwise; leaves, water and ice are 1
--   sound       material sound group (Audio/SoundConfig); default from the tool type
--   shape       "cube" (meshed); "slab", "stairs", "fence", "door", "ladder" (meshed boxes, see
--               Blocks/Shapes); "torch", "wall_torch", "fire", "campfire", "sign", "wall_sign"
--               (own small models); default "cube"
--   facing      wall torches: the side it leans towards ("east" = its wall is at x - 1)
--   fluid / fluidLevel   water and lava: one block id per level (Java fluid states)
--   gravity     falls like sand when nothing is below
--   flammable   Java fire spread values { encouragement, flammability }
--   altDrop     replaces the normal drop with this chance (gravel drops flint 10 %)
--   state / family / noItem / icon   shaped blocks (Blocks/ShapedDefs, Blocks/Shapes)

export type BlockDefInput = {
	id: number,
	key: string,
	name: string,
	hardness: number,
	tool: string?,
	minTier: number?,
	drop: (string | boolean)?,
	dropMin: number?,
	dropMax: number?,
	textures: { [string]: string },
	solid: boolean?,
	transparent: boolean?,
	liquid: boolean?,
	cullSelf: boolean?,
	bonusDrops: { { item: string, chance: number } }?,
	light: number?,
	opacity: number?,
	sound: string?,
	shape: string?,
	facing: string?,
	fluid: string?, -- "water" | "lava" for every fluid block
	fluidLevel: number?, -- 0 source, 1..7 flowing (higher = farther), 8 falling
	gravity: boolean?, -- falls when unsupported (sand, gravel)
	flammable: { number }?, -- Java fire values { encouragement, flammability }
	altDrop: { item: string, chance: number }?, -- drops this instead, with this chance (gravel -> flint)
	state: { [string]: any }?, -- shaped blocks: half, facing, open, hinge, upper, rotation
	family: string?, -- shaped blocks: all states of one block share this key (= its item)
	noItem: boolean?, -- this state has no item of its own (it drops / picks its family)
	shearsOnly: boolean?, -- drops only when broken with shears (vines)
	icon: string?, -- item icon shape instead of the flat texture ("slab", "stairs", "door", ...)
}

local defs: { BlockDefInput } = {
	-- Terrain ---------------------------------------------------------------------------------
	{ id = 1, key = "stone", name = "Stone", hardness = 1.5, tool = "pickaxe", minTier = 1, drop = "cobblestone", textures = { all = "stone" } },
	{ id = 2, key = "grass_block", name = "Grass Block", hardness = 0.6, tool = "shovel", drop = "dirt", textures = { top = "grass_top", side = "grass_side", bottom = "dirt" }, sound = "grass" },
	{ id = 3, key = "dirt", name = "Dirt", hardness = 0.5, tool = "shovel", textures = { all = "dirt" }, sound = "gravel" },
	{ id = 4, key = "cobblestone", name = "Cobblestone", hardness = 2.0, tool = "pickaxe", minTier = 1, textures = { all = "cobblestone" } },
	{ id = 5, key = "bedrock", name = "Bedrock", hardness = -1, drop = false, textures = { all = "bedrock" } },
	{ id = 6, key = "sand", name = "Sand", hardness = 0.5, tool = "shovel", textures = { all = "sand" }, sound = "sand", gravity = true },
	{ id = 7, key = "gravel", name = "Gravel", hardness = 0.6, tool = "shovel", textures = { all = "gravel" }, sound = "gravel", gravity = true, altDrop = { item = "flint", chance = 0.1 } },
	{ id = 8, key = "sandstone", name = "Sandstone", hardness = 0.8, tool = "pickaxe", minTier = 1, textures = { top = "sandstone_top", side = "sandstone_side", bottom = "sandstone_top" } },
	{ id = 9, key = "water", name = "Water", hardness = 100, drop = false, textures = { all = "water" }, solid = false, transparent = true, liquid = true, opacity = 1, sound = "water", fluid = "water", fluidLevel = 0 },
	{ id = 10, key = "lava", name = "Lava", hardness = 100, drop = false, textures = { all = "lava" }, solid = false, transparent = true, liquid = true, light = 15, sound = "lava", fluid = "lava", fluidLevel = 0 },
	{ id = 28, key = "snow_block", name = "Snow Block", hardness = 0.2, tool = "shovel", minTier = 1, drop = "snowball", dropMin = 4, dropMax = 4, textures = { all = "snow" }, sound = "snow" },
	{ id = 29, key = "ice", name = "Ice", hardness = 0.5, tool = "pickaxe", drop = false, textures = { all = "ice" }, transparent = true, opacity = 1, sound = "glass" },
	{ id = 30, key = "clay", name = "Clay", hardness = 0.6, tool = "shovel", drop = "clay_ball", dropMin = 4, dropMax = 4, textures = { all = "clay" }, sound = "gravel" },
	{ id = 38, key = "snowy_grass_block", name = "Snowy Grass Block", hardness = 0.6, tool = "shovel", drop = "dirt", textures = { top = "snow", side = "snowy_grass_side", bottom = "dirt" }, sound = "grass" },

	-- Wood ------------------------------------------------------------------------------------
	{ id = 11, key = "oak_log", name = "Oak Log", hardness = 2.0, tool = "axe", textures = { top = "oak_log_top", side = "oak_log", bottom = "oak_log_top" }, flammable = { 5, 5 } },
	{ id = 12, key = "oak_leaves", name = "Oak Leaves", hardness = 0.2, tool = "hoe", drop = false, textures = { all = "oak_leaves" }, bonusDrops = { { item = "apple", chance = 0.005 }, { item = "stick", chance = 0.02 } }, opacity = 1, sound = "grass", flammable = { 30, 60 } },
	{ id = 13, key = "oak_planks", name = "Oak Planks", hardness = 2.0, tool = "axe", textures = { all = "oak_planks" }, flammable = { 5, 20 } },
	{ id = 14, key = "birch_log", name = "Birch Log", hardness = 2.0, tool = "axe", textures = { top = "birch_log_top", side = "birch_log", bottom = "birch_log_top" }, flammable = { 5, 5 } },
	{ id = 15, key = "birch_leaves", name = "Birch Leaves", hardness = 0.2, tool = "hoe", drop = false, textures = { all = "birch_leaves" }, bonusDrops = { { item = "stick", chance = 0.02 } }, opacity = 1, sound = "grass", flammable = { 30, 60 } },
	{ id = 16, key = "birch_planks", name = "Birch Planks", hardness = 2.0, tool = "axe", textures = { all = "birch_planks" }, flammable = { 5, 20 } },
	{ id = 17, key = "spruce_log", name = "Spruce Log", hardness = 2.0, tool = "axe", textures = { top = "spruce_log_top", side = "spruce_log", bottom = "spruce_log_top" }, flammable = { 5, 5 } },
	{ id = 18, key = "spruce_leaves", name = "Spruce Leaves", hardness = 0.2, tool = "hoe", drop = false, textures = { all = "spruce_leaves" }, bonusDrops = { { item = "stick", chance = 0.02 } }, opacity = 1, sound = "grass", flammable = { 30, 60 } },
	{ id = 19, key = "spruce_planks", name = "Spruce Planks", hardness = 2.0, tool = "axe", textures = { all = "spruce_planks" }, flammable = { 5, 20 } },

	-- Ores ------------------------------------------------------------------------------------
	{ id = 20, key = "coal_ore", name = "Coal Ore", hardness = 3.0, tool = "pickaxe", minTier = 1, drop = "coal", textures = { all = "coal_ore" } },
	{ id = 21, key = "iron_ore", name = "Iron Ore", hardness = 3.0, tool = "pickaxe", minTier = 2, drop = "raw_iron", textures = { all = "iron_ore" } },
	{ id = 22, key = "copper_ore", name = "Copper Ore", hardness = 3.0, tool = "pickaxe", minTier = 2, drop = "raw_copper", dropMin = 2, dropMax = 5, textures = { all = "copper_ore" } },
	{ id = 23, key = "gold_ore", name = "Gold Ore", hardness = 3.0, tool = "pickaxe", minTier = 3, drop = "raw_gold", textures = { all = "gold_ore" } },
	{ id = 24, key = "diamond_ore", name = "Diamond Ore", hardness = 3.0, tool = "pickaxe", minTier = 3, drop = "diamond", textures = { all = "diamond_ore" } },
	{ id = 25, key = "emerald_ore", name = "Emerald Ore", hardness = 3.0, tool = "pickaxe", minTier = 3, drop = "emerald", textures = { all = "emerald_ore" } },
	{ id = 26, key = "lapis_ore", name = "Lapis Ore", hardness = 3.0, tool = "pickaxe", minTier = 2, drop = "lapis_lazuli", dropMin = 4, dropMax = 9, textures = { all = "lapis_ore" } },
	-- Power-wire ore (our original equivalent of the classic signal-dust ore). Name pending approval.
	{ id = 27, key = "volt_ore", name = "Volt Ore", hardness = 3.0, tool = "pickaxe", minTier = 3, drop = "volt_dust", dropMin = 4, dropMax = 5, textures = { all = "volt_ore" } },

	-- Crafted / utility (used from phase 2-3 onward) -----------------------------------------
	{ id = 31, key = "glass", name = "Glass", hardness = 0.3, drop = false, textures = { all = "glass" }, transparent = true, sound = "glass" },
	{ id = 32, key = "obsidian", name = "Obsidian", hardness = 50, tool = "pickaxe", minTier = 4, textures = { all = "obsidian" } },
	{ id = 33, key = "crafting_table", name = "Crafting Table", hardness = 2.5, tool = "axe", textures = { top = "crafting_table_top", side = "crafting_table_side", bottom = "oak_planks" } },
	{ id = 34, key = "furnace", name = "Furnace", hardness = 3.5, tool = "pickaxe", minTier = 1, textures = { top = "furnace_top", side = "furnace_side", bottom = "furnace_top" } },
	{ id = 35, key = "chest", name = "Chest", hardness = 2.5, tool = "axe", textures = { all = "chest" } },
	{ id = 36, key = "tnt", name = "TNT", hardness = 0, textures = { top = "tnt_top", side = "tnt_side", bottom = "tnt_top" }, sound = "grass", flammable = { 15, 100 } },
	{ id = 39, key = "torch", name = "Torch", hardness = 0, textures = { all = "torch" }, solid = false, transparent = true, light = 14, opacity = 0, sound = "wood", shape = "torch" },
	-- Torches on walls: one id per side, `facing` = the direction it leans (away from its wall).
	{ id = 40, key = "wall_torch_east", name = "Torch", hardness = 0, drop = "torch", textures = { all = "torch" }, solid = false, transparent = true, light = 14, opacity = 0, sound = "wood", shape = "wall_torch", facing = "east" },
	{ id = 41, key = "wall_torch_west", name = "Torch", hardness = 0, drop = "torch", textures = { all = "torch" }, solid = false, transparent = true, light = 14, opacity = 0, sound = "wood", shape = "wall_torch", facing = "west" },
	{ id = 42, key = "wall_torch_south", name = "Torch", hardness = 0, drop = "torch", textures = { all = "torch" }, solid = false, transparent = true, light = 14, opacity = 0, sound = "wood", shape = "wall_torch", facing = "south" },
	{ id = 43, key = "wall_torch_north", name = "Torch", hardness = 0, drop = "torch", textures = { all = "torch" }, solid = false, transparent = true, light = 14, opacity = 0, sound = "wood", shape = "wall_torch", facing = "north" },

	-- Flowing water and lava: one id per Java fluid level (1..7 flowing, 8 falling) --------------
	{ id = 44, key = "water_flowing_1", name = "Water", hardness = 100, drop = false, textures = { all = "water_1" }, solid = false, transparent = true, liquid = true, opacity = 1, sound = "water", fluid = "water", fluidLevel = 1 },
	{ id = 45, key = "water_flowing_2", name = "Water", hardness = 100, drop = false, textures = { all = "water_2" }, solid = false, transparent = true, liquid = true, opacity = 1, sound = "water", fluid = "water", fluidLevel = 2 },
	{ id = 46, key = "water_flowing_3", name = "Water", hardness = 100, drop = false, textures = { all = "water_3" }, solid = false, transparent = true, liquid = true, opacity = 1, sound = "water", fluid = "water", fluidLevel = 3 },
	{ id = 47, key = "water_flowing_4", name = "Water", hardness = 100, drop = false, textures = { all = "water_4" }, solid = false, transparent = true, liquid = true, opacity = 1, sound = "water", fluid = "water", fluidLevel = 4 },
	{ id = 48, key = "water_flowing_5", name = "Water", hardness = 100, drop = false, textures = { all = "water_5" }, solid = false, transparent = true, liquid = true, opacity = 1, sound = "water", fluid = "water", fluidLevel = 5 },
	{ id = 49, key = "water_flowing_6", name = "Water", hardness = 100, drop = false, textures = { all = "water_6" }, solid = false, transparent = true, liquid = true, opacity = 1, sound = "water", fluid = "water", fluidLevel = 6 },
	{ id = 50, key = "water_flowing_7", name = "Water", hardness = 100, drop = false, textures = { all = "water_7" }, solid = false, transparent = true, liquid = true, opacity = 1, sound = "water", fluid = "water", fluidLevel = 7 },
	{ id = 51, key = "water_falling", name = "Water", hardness = 100, drop = false, textures = { all = "water_falling" }, solid = false, transparent = true, liquid = true, opacity = 1, sound = "water", fluid = "water", fluidLevel = 8 },
	{ id = 52, key = "lava_flowing_1", name = "Lava", hardness = 100, drop = false, textures = { all = "lava_1" }, solid = false, transparent = true, liquid = true, opacity = 0, light = 15, sound = "lava", fluid = "lava", fluidLevel = 1 },
	{ id = 53, key = "lava_flowing_2", name = "Lava", hardness = 100, drop = false, textures = { all = "lava_2" }, solid = false, transparent = true, liquid = true, opacity = 0, light = 15, sound = "lava", fluid = "lava", fluidLevel = 2 },
	{ id = 54, key = "lava_flowing_3", name = "Lava", hardness = 100, drop = false, textures = { all = "lava_3" }, solid = false, transparent = true, liquid = true, opacity = 0, light = 15, sound = "lava", fluid = "lava", fluidLevel = 3 },
	{ id = 55, key = "lava_flowing_4", name = "Lava", hardness = 100, drop = false, textures = { all = "lava_4" }, solid = false, transparent = true, liquid = true, opacity = 0, light = 15, sound = "lava", fluid = "lava", fluidLevel = 4 },
	{ id = 56, key = "lava_flowing_5", name = "Lava", hardness = 100, drop = false, textures = { all = "lava_5" }, solid = false, transparent = true, liquid = true, opacity = 0, light = 15, sound = "lava", fluid = "lava", fluidLevel = 5 },
	{ id = 57, key = "lava_flowing_6", name = "Lava", hardness = 100, drop = false, textures = { all = "lava_6" }, solid = false, transparent = true, liquid = true, opacity = 0, light = 15, sound = "lava", fluid = "lava", fluidLevel = 6 },
	{ id = 58, key = "lava_flowing_7", name = "Lava", hardness = 100, drop = false, textures = { all = "lava_7" }, solid = false, transparent = true, liquid = true, opacity = 0, light = 15, sound = "lava", fluid = "lava", fluidLevel = 7 },
	{ id = 59, key = "lava_falling", name = "Lava", hardness = 100, drop = false, textures = { all = "lava_falling" }, solid = false, transparent = true, liquid = true, opacity = 0, light = 15, sound = "lava", fluid = "lava", fluidLevel = 8 },
	-- Fire and campfires --------------------------------------------------------------------
	{ id = 60, key = "fire", name = "Fire", hardness = 0, drop = false, textures = { all = "fire" }, solid = false, transparent = true, light = 15, opacity = 0, sound = "wool", shape = "fire" },
	{ id = 61, key = "campfire", name = "Campfire", hardness = 2, tool = "axe", drop = "charcoal", dropMin = 2, dropMax = 2, textures = { top = "campfire_top", side = "campfire_log", bottom = "campfire_log" }, transparent = true, light = 15, opacity = 0, sound = "wood", shape = "campfire" },
	{ id = 62, key = "campfire_unlit", name = "Campfire", hardness = 2, tool = "axe", drop = "charcoal", dropMin = 2, dropMax = 2, textures = { top = "campfire_top", side = "campfire_log", bottom = "campfire_log" }, transparent = true, opacity = 0, sound = "wood", shape = "campfire" },
	{ id = 37, key = "white_wool", name = "White Wool", hardness = 0.8, tool = "shears", textures = { all = "white_wool" }, sound = "wool", flammable = { 30, 60 } },
}

-- Slabs, stairs, fences, doors, ladders, signs (ids 100+; see ShapedDefs).
for _, d in require(script.Parent.ShapedDefs).list() do
	table.insert(defs, d :: any)
end

return defs
