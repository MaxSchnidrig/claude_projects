--!strict
-- Item data (non-block items). Every block also gets an item automatically (see ItemRegistry),
-- so this file only lists materials and tools.
--
-- Tool fields (classic survival values):
--   kind        "pickaxe" | "axe" | "shovel" | "hoe" | "shears"
--   tier        harvest tier: 1 wood/gold, 2 stone, 3 iron, 4 diamond (matches BlockDefs.minTier)
--   speed       mining speed multiplier on blocks of the matching tool kind
--   durability  uses before it breaks
--   blockSpeeds optional per-block speed overrides (shears)

export type ToolDef = {
	kind: string,
	tier: number,
	speed: number,
	durability: number,
	blockSpeeds: { [string]: number }?,
	attack: number?, -- melee damage (HP); hand = 1
	attackSpeed: number?, -- full-strength attacks per second (Java attribute); hand = 4
}

-- Food values (classic): hunger points restored and saturation gained.
export type FoodDef = { hunger: number, saturation: number }

export type ItemDefInput = {
	key: string,
	name: string,
	stack: number?, -- max stack size (default 64)
	tool: ToolDef?,
	food: FoodDef?,
	color: { number }?, -- placeholder icon colour (RGB)
}

local defs: { ItemDefInput } = {
	-- Materials
	{ key = "coal", name = "Coal", color = { 40, 40, 44 } },
	{ key = "charcoal", name = "Charcoal", color = { 52, 44, 36 } },
	{ key = "raw_iron", name = "Raw Iron", color = { 196, 160, 132 } },
	{ key = "raw_copper", name = "Raw Copper", color = { 190, 110, 70 } },
	{ key = "raw_gold", name = "Raw Gold", color = { 230, 190, 60 } },
	{ key = "iron_ingot", name = "Iron Ingot", color = { 214, 214, 214 } },
	{ key = "copper_ingot", name = "Copper Ingot", color = { 214, 120, 80 } },
	{ key = "gold_ingot", name = "Gold Ingot", color = { 246, 210, 60 } },
	{ key = "diamond", name = "Diamond", color = { 100, 226, 226 } },
	{ key = "emerald", name = "Emerald", color = { 60, 200, 100 } },
	{ key = "lapis_lazuli", name = "Lapis Lazuli", color = { 40, 70, 190 } },
	{ key = "volt_dust", name = "Volt Dust", color = { 170, 80, 230 } },
	{ key = "stick", name = "Stick", color = { 140, 104, 60 } },
	{ key = "flint", name = "Flint", color = { 60, 60, 64 } },
	{ key = "snowball", name = "Snowball", stack = 16, color = { 246, 250, 252 } },
	{ key = "clay_ball", name = "Clay Ball", color = { 164, 170, 186 } },
	-- Food
	-- Mob drops
	{ key = "leather", name = "Leather", color = { 150, 90, 50 } },
	{ key = "feather", name = "Feather", color = { 240, 240, 236 } },
	{ key = "bone", name = "Bone", color = { 226, 222, 206 } },
	{ key = "arrow", name = "Arrow", color = { 170, 150, 120 } },
	{ key = "string", name = "String", color = { 230, 230, 230 } },
	{ key = "gunpowder", name = "Gunpowder", color = { 80, 80, 84 } },
	{ key = "void_shard", name = "Void Shard", stack = 16, color = { 120, 90, 230 } },
	{ key = "rotten_flesh", name = "Rotten Flesh", color = { 140, 90, 70 }, food = { hunger = 4, saturation = 0.8 } },
	{ key = "spider_eye", name = "Spider Eye", color = { 150, 40, 60 }, food = { hunger = 2, saturation = 3.2 } },
	{ key = "carrot", name = "Carrot", color = { 240, 140, 30 }, food = { hunger = 3, saturation = 3.6 } },
	{ key = "potato", name = "Potato", color = { 200, 170, 90 }, food = { hunger = 1, saturation = 0.6 } },
	{ key = "baked_potato", name = "Baked Potato", color = { 214, 160, 70 }, food = { hunger = 5, saturation = 6 } },
	{ key = "apple", name = "Apple", color = { 210, 40, 40 }, food = { hunger = 4, saturation = 2.4 } },
	{ key = "bread", name = "Bread", color = { 196, 150, 80 }, food = { hunger = 5, saturation = 6 } },
	{ key = "raw_porkchop", name = "Raw Porkchop", color = { 236, 150, 150 }, food = { hunger = 3, saturation = 1.8 } },
	{ key = "cooked_porkchop", name = "Cooked Porkchop", color = { 200, 120, 80 }, food = { hunger = 8, saturation = 12.8 } },
	{ key = "raw_beef", name = "Raw Beef", color = { 200, 60, 60 }, food = { hunger = 3, saturation = 1.8 } },
	{ key = "steak", name = "Steak", color = { 130, 70, 40 }, food = { hunger = 8, saturation = 12.8 } },
	{ key = "raw_chicken", name = "Raw Chicken", color = { 240, 200, 180 }, food = { hunger = 2, saturation = 1.2 } },
	{ key = "cooked_chicken", name = "Cooked Chicken", color = { 210, 150, 90 }, food = { hunger = 6, saturation = 7.2 } },
	{ key = "raw_mutton", name = "Raw Mutton", color = { 210, 80, 80 }, food = { hunger = 2, saturation = 1.2 } },
	{ key = "cooked_mutton", name = "Cooked Mutton", color = { 150, 80, 50 }, food = { hunger = 6, saturation = 9.6 } },
}

-- Tools: generated for every material x kind, with classic stats.
local TIERS = {
	{ prefix = "wooden", label = "Wooden", tier = 1, speed = 2, durability = 59, color = { 160, 124, 72 } },
	{ prefix = "stone", label = "Stone", tier = 2, speed = 4, durability = 131, color = { 130, 130, 130 } },
	{ prefix = "iron", label = "Iron", tier = 3, speed = 6, durability = 250, color = { 220, 220, 220 } },
	{ prefix = "golden", label = "Golden", tier = 1, speed = 12, durability = 32, color = { 246, 210, 60 } },
	{ prefix = "diamond", label = "Diamond", tier = 4, speed = 8, durability = 1561, color = { 100, 226, 226 } },
}
local KINDS = {
	{ kind = "pickaxe", label = "Pickaxe" },
	{ kind = "axe", label = "Axe" },
	{ kind = "shovel", label = "Shovel" },
	{ kind = "hoe", label = "Hoe" },
	{ kind = "sword", label = "Sword" },
}
-- Melee damage and attack speed per tool kind and tier (wooden, stone, iron, golden, diamond).
-- Java Edition values; seconds per full-strength hit = 1 / speed.
local ATTACK = {
	sword = { damage = { 4, 5, 6, 4, 7 }, speed = { 1.6, 1.6, 1.6, 1.6, 1.6 } },
	axe = { damage = { 7, 9, 9, 7, 9 }, speed = { 0.8, 0.8, 0.9, 1.0, 1.0 } },
	pickaxe = { damage = { 2, 3, 4, 2, 5 }, speed = { 1.2, 1.2, 1.2, 1.2, 1.2 } },
	shovel = { damage = { 2.5, 3.5, 4.5, 2.5, 5.5 }, speed = { 1, 1, 1, 1, 1 } },
	hoe = { damage = { 1, 1, 1, 1, 1 }, speed = { 1, 2, 3, 1, 4 } },
}
for tierIndex, t in TIERS do
	for _, k in KINDS do
		local atk = ATTACK[k.kind]
		table.insert(defs, {
			key = `{t.prefix}_{k.kind}`,
			name = `{t.label} {k.label}`,
			stack = 1,
			tool = {
				kind = k.kind,
				tier = t.tier,
				speed = t.speed,
				durability = t.durability,
				attack = atk.damage[tierIndex],
				attackSpeed = atk.speed[tierIndex],
			},
			color = t.color,
		})
	end
end
table.insert(defs, {
	key = "shears",
	name = "Shears",
	stack = 1,
	tool = {
		kind = "shears",
		tier = 0,
		speed = 1,
		durability = 238,
		blockSpeeds = { oak_leaves = 15, birch_leaves = 15, spruce_leaves = 15, white_wool = 5 },
	},
	color = { 200, 200, 200 },
})

return defs
