--!strict
-- Crafting, smelting and fuel data. Adding a recipe = adding one entry here.
--
-- Shaped recipes: `pattern` rows (top to bottom), each character a key in `key`; " " = empty.
--   Patterns match anywhere in the grid and also mirrored left-right (classic behaviour).
--   A 2x2 inventory grid can craft any recipe that fits in 2x2.
-- Shapeless recipes: `ingredients` list; order and position don't matter.
-- Ingredients are item keys or tags ("#planks" = any planks), see TAGS.

export type Result = { item: string, count: number }
export type Shaped = { pattern: { string }, key: { [string]: string }, result: Result }
export type Shapeless = { ingredients: { string }, result: Result }

local Recipes = {}

Recipes.TAGS = {
	["#planks"] = { "oak_planks", "birch_planks", "spruce_planks" },
	["#logs"] = { "oak_log", "birch_log", "spruce_log" },
	["#coals"] = { "coal", "charcoal" },
}

local shaped: { Shaped } = {
	{ pattern = { "P", "P" }, key = { P = "#planks" }, result = { item = "stick", count = 4 } },
	{ pattern = { "PP", "PP" }, key = { P = "#planks" }, result = { item = "crafting_table", count = 1 } },
	{ pattern = { "PPP", "P P", "PPP" }, key = { P = "#planks" }, result = { item = "chest", count = 1 } },
	{ pattern = { "CCC", "C C", "CCC" }, key = { C = "cobblestone" }, result = { item = "furnace", count = 1 } },
	{ pattern = { "SS", "SS" }, key = { S = "sand" }, result = { item = "sandstone", count = 1 } },
	{ pattern = { "ss", "ss" }, key = { s = "snowball" }, result = { item = "snow_block", count = 1 } },
	{ pattern = { "cc", "cc" }, key = { c = "clay_ball" }, result = { item = "clay", count = 1 } },
	{ pattern = { " I", "I " }, key = { I = "iron_ingot" }, result = { item = "shears", count = 1 } },
}

-- Tools: same shapes for every material tier.
local TOOL_MATERIALS = {
	{ prefix = "wooden", material = "#planks" },
	{ prefix = "stone", material = "cobblestone" },
	{ prefix = "iron", material = "iron_ingot" },
	{ prefix = "golden", material = "gold_ingot" },
	{ prefix = "diamond", material = "diamond" },
}
local TOOL_SHAPES = {
	pickaxe = { "MMM", " S ", " S " },
	axe = { "MM", "MS", " S" },
	shovel = { "M", "S", "S" },
	hoe = { "MM", " S", " S" },
}
for _, m in TOOL_MATERIALS do
	for kind, pattern in TOOL_SHAPES do
		table.insert(shaped, {
			pattern = pattern,
			key = { M = m.material, S = "stick" },
			result = { item = `{m.prefix}_{kind}`, count = 1 },
		})
	end
end

local shapeless: { Shapeless } = {
	{ ingredients = { "oak_log" }, result = { item = "oak_planks", count = 4 } },
	{ ingredients = { "birch_log" }, result = { item = "birch_planks", count = 4 } },
	{ ingredients = { "spruce_log" }, result = { item = "spruce_planks", count = 4 } },
}

Recipes.shaped = shaped
Recipes.shapeless = shapeless

-- Furnace: input item -> output item (one per SMELT_SECONDS).
Recipes.SMELT_SECONDS = 10
Recipes.smelting = {
	raw_iron = "iron_ingot",
	raw_gold = "gold_ingot",
	raw_copper = "copper_ingot",
	sand = "glass",
	cobblestone = "stone",
	oak_log = "charcoal",
	birch_log = "charcoal",
	spruce_log = "charcoal",
} :: { [string]: string }

-- Fuel burn time in seconds (one coal smelts 8 items).
Recipes.fuel = {
	coal = 80,
	charcoal = 80,
	oak_planks = 15,
	birch_planks = 15,
	spruce_planks = 15,
	oak_log = 15,
	birch_log = 15,
	spruce_log = 15,
	stick = 5,
	crafting_table = 15,
	chest = 15,
	wooden_pickaxe = 10,
	wooden_axe = 10,
	wooden_shovel = 10,
	wooden_hoe = 10,
} :: { [string]: number }

return Recipes
