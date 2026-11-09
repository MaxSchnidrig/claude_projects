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

-- Armour (Java values): slot "head" | "chest" | "legs" | "feet", armour points, toughness.
export type ArmorDef = { slot: string, defense: number, toughness: number, material: string }

export type ItemDefInput = {
	key: string,
	name: string,
	stack: number?, -- max stack size (default 64)
	tool: ToolDef?,
	food: FoodDef?,
	armor: ArmorDef?,
	hidden: boolean?, -- not listed in the Studio test menu (internal states like a loaded crossbow)
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
	-- Buckets (Java: empty buckets stack to 16, filled ones don't)
	{ key = "bucket", name = "Bucket", stack = 16, color = { 190, 192, 198 } },
	{ key = "water_bucket", name = "Water Bucket", stack = 1, color = { 60, 110, 220 } },
	{ key = "lava_bucket", name = "Lava Bucket", stack = 1, color = { 236, 110, 30 } },
	-- Decoration
	{ key = "item_frame", name = "Item Frame", color = { 150, 110, 70 } },
	{ key = "glow_item_frame", name = "Glow Item Frame", color = { 170, 200, 150 } },
	{ key = "glow_ink_sac", name = "Glow Ink Sac", color = { 90, 210, 190 } },
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
	key = "flint_and_steel",
	name = "Flint and Steel",
	stack = 1,
	tool = { kind = "flint_and_steel", tier = 0, speed = 1, durability = 64 },
	color = { 150, 150, 156 },
})
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

-- Armour: Java defense points (helmet, chestplate, leggings, boots), toughness, durability.
local ARMOR = {
	{ prefix = "leather", label = "Leather", defense = { 1, 3, 2, 1 }, toughness = 0, durability = { 55, 80, 75, 65 }, color = { 150, 96, 56 } },
	{ prefix = "chainmail", label = "Chainmail", defense = { 2, 5, 4, 1 }, toughness = 0, durability = { 165, 240, 225, 195 }, color = { 150, 152, 160 } },
	{ prefix = "iron", label = "Iron", defense = { 2, 6, 5, 2 }, toughness = 0, durability = { 165, 240, 225, 195 }, color = { 214, 214, 218 } },
	{ prefix = "golden", label = "Golden", defense = { 2, 5, 3, 1 }, toughness = 0, durability = { 77, 112, 105, 91 }, color = { 246, 210, 60 } },
	{ prefix = "diamond", label = "Diamond", defense = { 3, 8, 6, 3 }, toughness = 2, durability = { 363, 528, 495, 429 }, color = { 100, 226, 226 } },
}
local PIECES = {
	{ key = "helmet", label = "Helmet", slot = "head" },
	{ key = "chestplate", label = "Chestplate", slot = "chest" },
	{ key = "leggings", label = "Leggings", slot = "legs" },
	{ key = "boots", label = "Boots", slot = "feet" },
}
for _, m in ARMOR do
	for i, piece in PIECES do
		local label = if m.prefix == "leather" and piece.key == "helmet" then "Leather Cap"
			elseif m.prefix == "leather" and piece.key == "chestplate" then "Leather Tunic"
			elseif m.prefix == "leather" and piece.key == "leggings" then "Leather Pants"
			else `{m.label} {piece.label}`
		table.insert(defs, {
			key = `{m.prefix}_{piece.key}`,
			name = label,
			stack = 1,
			tool = { kind = "armor", tier = 0, speed = 1, durability = m.durability[i] },
			armor = { slot = piece.slot, defense = m.defense[i], toughness = m.toughness, material = m.prefix },
			color = m.color,
		})
	end
end
-- Tripwire hook: needed for the crossbow now; it becomes a placeable block with the Volt system.
table.insert(defs, { key = "tripwire_hook", name = "Tripwire Hook", color = { 150, 150, 156 } })
-- Shield, bow, crossbow (Java durability). A loaded crossbow is its own internal item.
table.insert(defs, { key = "shield", name = "Shield", stack = 1, tool = { kind = "shield", tier = 0, speed = 1, durability = 336 }, color = { 140, 104, 64 } })
table.insert(defs, { key = "bow", name = "Bow", stack = 1, tool = { kind = "bow", tier = 0, speed = 1, durability = 384 }, color = { 130, 92, 52 } })
table.insert(defs, { key = "crossbow", name = "Crossbow", stack = 1, tool = { kind = "crossbow", tier = 0, speed = 1, durability = 465 }, color = { 110, 80, 50 } })
table.insert(defs, { key = "crossbow_loaded", name = "Crossbow", stack = 1, hidden = true, tool = { kind = "crossbow", tier = 0, speed = 1, durability = 465 }, color = { 110, 80, 50 } })

return defs
