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
-- Phase 9e: any wool / carpet / bed (dyeing recipes accept every colour)
local COLORS = { "white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray", "light_gray", "cyan",
	"purple", "blue", "brown", "green", "red", "black" }
Recipes.COLORS = COLORS
Recipes.TAGS["#wool"] = {}
Recipes.TAGS["#carpets"] = {}
Recipes.TAGS["#beds"] = {}
for _, c in COLORS do
	table.insert(Recipes.TAGS["#wool"], `{c}_wool`)
	table.insert(Recipes.TAGS["#carpets"], `{c}_carpet`)
	table.insert(Recipes.TAGS["#beds"], `{c}_bed`)
end

local shaped: { Shaped } = {
	{ pattern = { "  S", " ST", "S T" }, key = { S = "stick", T = "string" }, result = { item = "fishing_rod", count = 1 } },
	{ pattern = { "P", "P" }, key = { P = "#planks" }, result = { item = "stick", count = 4 } },
	{ pattern = { "PP", "PP" }, key = { P = "#planks" }, result = { item = "crafting_table", count = 1 } },
	-- TEMPORARY stand-in: the iron ingot replaces Java's blaze rod until the Nether exists
	{ pattern = { " I ", "CCC" }, key = { I = "iron_ingot", C = "cobblestone" }, result = { item = "brewing_stand", count = 1 } },
	{ pattern = { "G G", " G " }, key = { G = "glass" }, result = { item = "glass_bottle", count = 3 } },
	{ pattern = { "PPP", "P P", "PPP" }, key = { P = "#planks" }, result = { item = "chest", count = 1 } },
	{ pattern = { "CCC", "C C", "CCC" }, key = { C = "cobblestone" }, result = { item = "furnace", count = 1 } },
	{ pattern = { "SS", "SS" }, key = { S = "sand" }, result = { item = "sandstone", count = 1 } },
	{ pattern = { "ss", "ss" }, key = { s = "snowball" }, result = { item = "snow_block", count = 1 } },
	{ pattern = { "cc", "cc" }, key = { c = "clay_ball" }, result = { item = "clay", count = 1 } },
	{ pattern = { " I", "I " }, key = { I = "iron_ingot" }, result = { item = "shears", count = 1 } },
	{ pattern = { "ss", "ss" }, key = { s = "string" }, result = { item = "white_wool", count = 1 } },
	{ pattern = { "GSG", "SGS", "GSG" }, key = { G = "gunpowder", S = "sand" }, result = { item = "tnt", count = 1 } },
	{ pattern = { "C", "S" }, key = { C = "#coals", S = "stick" }, result = { item = "torch", count = 4 } },
	{ pattern = { "I I", " I " }, key = { I = "iron_ingot" }, result = { item = "bucket", count = 1 } },
	{ pattern = { " S ", "SCS", "LLL" }, key = { S = "stick", C = "#coals", L = "#logs" }, result = { item = "campfire", count = 1 } },
	-- Farming (Phase 9a)
	{ pattern = { "WWW" }, key = { W = "wheat" }, result = { item = "bread", count = 1 } },
	{ pattern = { "P P", " P " }, key = { P = "#planks" }, result = { item = "bowl", count = 4 } },
	-- Phase 9b
	{ pattern = { "MMM", "MMM", "MMM" }, key = { M = "melon_slice" }, result = { item = "melon", count = 1 } },
	{ pattern = { "SSS" }, key = { S = "sugar_cane" }, result = { item = "paper", count = 3 } },
	-- Phase 10b (Java)
	{ pattern = { "PPP", "BBB", "PPP" }, key = { P = "#planks", B = "book" }, result = { item = "bookshelf", count = 1 } },
	{ pattern = { " B ", "DOD", "OOO" }, key = { B = "book", D = "diamond", O = "obsidian" }, result = { item = "enchanting_table", count = 1 } },
	-- Phase 9c
	{ pattern = { "GGG", "GAG", "GGG" }, key = { G = "gold_ingot", A = "apple" }, result = { item = "golden_apple", count = 1 } },
	{ pattern = { "NNN", "NCN", "NNN" }, key = { N = "gold_nugget", C = "carrot" }, result = { item = "golden_carrot", count = 1 } },
	{ pattern = { "NNN", "NNN", "NNN" }, key = { N = "gold_nugget" }, result = { item = "gold_ingot", count = 1 } },
}

-- Building blocks (Phase 8b)
do
	local ShapedDefs = require(script.Parent.Parent.Blocks.ShapedDefs)
	for _, m in ShapedDefs.MATERIALS do
		local base = ShapedDefs.BASE_BLOCK[m.key]
		table.insert(shaped, { pattern = { "MMM" }, key = { M = base }, result = { item = `{m.key}_slab`, count = 6 } })
		table.insert(shaped, { pattern = { "M  ", "MM ", "MMM" }, key = { M = base }, result = { item = `{m.key}_stairs`, count = 4 } })
	end
	for _, w in ShapedDefs.WOODS do
		local planks = `{w}_planks`
		table.insert(shaped, { pattern = { "PSP", "PSP" }, key = { P = planks, S = "stick" }, result = { item = `{w}_fence`, count = 3 } })
		table.insert(shaped, { pattern = { "PP", "PP", "PP" }, key = { P = planks }, result = { item = `{w}_door`, count = 3 } })
		table.insert(shaped, { pattern = { "PPP", "PPP", " S " }, key = { P = planks, S = "stick" }, result = { item = `{w}_sign`, count = 3 } })
	end
	table.insert(shaped, { pattern = { "II", "II", "II" }, key = { I = "iron_ingot" }, result = { item = "iron_door", count = 3 } })
	-- 8b2
	for _, w in ShapedDefs.WOODS do
		local planks = `{w}_planks`
		table.insert(shaped, { pattern = { "PPP", "PPP" }, key = { P = planks }, result = { item = `{w}_trapdoor`, count = 2 } })
		table.insert(shaped, { pattern = { "SPS", "SPS" }, key = { P = planks, S = "stick" }, result = { item = `{w}_fence_gate`, count = 1 } })
	end
	table.insert(shaped, { pattern = { "II", "II" }, key = { I = "iron_ingot" }, result = { item = "iron_trapdoor", count = 1 } })
	table.insert(shaped, { pattern = { "CCC", "CCC" }, key = { C = "cobblestone" }, result = { item = "cobblestone_wall", count = 6 } })
	table.insert(shaped, { pattern = { "CCC", "CCC" }, key = { C = "sandstone" }, result = { item = "sandstone_wall", count = 6 } })
	table.insert(shaped, { pattern = { "GGG", "GGG" }, key = { G = "glass" }, result = { item = "glass_pane", count = 16 } })
	table.insert(shaped, { pattern = { "III", "III" }, key = { I = "iron_ingot" }, result = { item = "iron_bars", count = 16 } })
	-- hanging signs need chains and stripped logs (phase 12); until then only the test menu has them
	table.insert(shaped, { pattern = { "S S", "SSS", "S S" }, key = { S = "stick" }, result = { item = "ladder", count = 3 } })
	table.insert(shaped, { pattern = { "SSS", "SLS", "SSS" }, key = { S = "stick", L = "leather" }, result = { item = "item_frame", count = 1 } })
end

-- Armour, shield, ranged weapons (Phase 8c)
do
	local ARMOR_SHAPES = {
		helmet = { "MMM", "M M" },
		chestplate = { "M M", "MMM", "MMM" },
		leggings = { "MMM", "M M", "M M" },
		boots = { "M M", "M M" },
	}
	for prefix, material in { leather = "leather", iron = "iron_ingot", golden = "gold_ingot", diamond = "diamond" } do
		for piece, pattern in ARMOR_SHAPES do
			table.insert(shaped, { pattern = pattern, key = { M = material }, result = { item = `{prefix}_{piece}`, count = 1 } })
		end
	end
	-- chainmail has no recipe in Java (trades and mob drops)
	-- beds: 3 wool of the bed's colour + 3 planks (Java)
	for _, c in COLORS do
		table.insert(shaped, { pattern = { "WWW", "PPP" }, key = { W = `{c}_wool`, P = "#planks" }, result = { item = `{c}_bed`, count = 1 } })
	end
	table.insert(shaped, { pattern = { "WIW", "WWW", " W " }, key = { W = "#planks", I = "iron_ingot" }, result = { item = "shield", count = 1 } })
	table.insert(shaped, { pattern = { " SX", "S X", " SX" }, key = { S = "stick", X = "string" }, result = { item = "bow", count = 1 } })
	table.insert(shaped, { pattern = { "SIS", "XTX", " S " }, key = { S = "stick", I = "iron_ingot", X = "string", T = "tripwire_hook" }, result = { item = "crossbow", count = 1 } })
	table.insert(shaped, { pattern = { "I", "S", "P" }, key = { I = "iron_ingot", S = "stick", P = "#planks" }, result = { item = "tripwire_hook", count = 2 } })
	table.insert(shaped, { pattern = { "F", "S", "E" }, key = { F = "flint", S = "stick", E = "feather" }, result = { item = "arrow", count = 4 } })
end

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
	sword = { "M", "M", "S" },
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
	{ ingredients = { "iron_ingot", "flint" }, result = { item = "flint_and_steel", count = 1 } },
	{ ingredients = { "item_frame", "glow_ink_sac" }, result = { item = "glow_item_frame", count = 1 } },
	{ ingredients = { "oak_log" }, result = { item = "oak_planks", count = 4 } },
	{ ingredients = { "birch_log" }, result = { item = "birch_planks", count = 4 } },
	{ ingredients = { "spruce_log" }, result = { item = "spruce_planks", count = 4 } },
	{ ingredients = { "bone" }, result = { item = "bone_meal", count = 3 } },
	{ ingredients = { "pumpkin" }, result = { item = "pumpkin_seeds", count = 4 } },
	{ ingredients = { "melon_slice" }, result = { item = "melon_seeds", count = 1 } },
	{ ingredients = { "sugar_cane" }, result = { item = "sugar", count = 1 } },
	{ ingredients = { "paper", "paper", "paper", "leather" }, result = { item = "book", count = 1 } },
	{ ingredients = { "gold_ingot" }, result = { item = "gold_nugget", count = 9 } },
	{ ingredients = { "pumpkin", "sugar", "egg" }, result = { item = "pumpkin_pie", count = 1 } },
	{ ingredients = { "beetroot", "beetroot", "beetroot", "beetroot", "beetroot", "beetroot", "bowl" }, result = { item = "beetroot_soup", count = 1 } },
}

-- Fuel that leaves an item behind in the fuel slot.
Recipes.fuelRemainder = { lava_bucket = "bucket" } :: { [string]: string }

-- Phase 9e: carpets, stained glass and panes in every colour (Java)
for _, c in COLORS do
	-- 2 wool side by side -> 3 carpets; 8 carpets around a dye -> 8 carpets of its colour
	table.insert(shaped, { pattern = { "WW" }, key = { W = `{c}_wool` }, result = { item = `{c}_carpet`, count = 3 } })
	table.insert(shaped, { pattern = { "CCC", "CDC", "CCC" }, key = { C = "#carpets", D = `{c}_dye` }, result = { item = `{c}_carpet`, count = 8 } })
	-- 8 glass around a dye -> 8 stained glass; 6 stained glass -> 16 panes; 8 panes around a dye
	table.insert(shaped, { pattern = { "GGG", "GDG", "GGG" }, key = { G = "glass", D = `{c}_dye` }, result = { item = `{c}_stained_glass`, count = 8 } })
	table.insert(shaped, { pattern = { "GGG", "GGG" }, key = { G = `{c}_stained_glass` }, result = { item = `{c}_stained_glass_pane`, count = 16 } })
	table.insert(shaped, { pattern = { "PPP", "PDP", "PPP" }, key = { P = "glass_pane", D = `{c}_dye` }, result = { item = `{c}_stained_glass_pane`, count = 8 } })
end

Recipes.shaped = shaped
-- Phase 9e: dyes (Java). From plants and materials, and mixed from other dyes.
for _, r in {
	{ { "bone_meal" }, "white_dye", 1 },
	{ { "azure_bluet" }, "light_gray_dye", 1 }, { { "oxeye_daisy" }, "light_gray_dye", 1 },
	{ { "poppy" }, "red_dye", 1 }, { { "red_tulip" }, "red_dye", 1 }, { { "beetroot" }, "red_dye", 1 },
	{ { "dandelion" }, "yellow_dye", 1 },
	{ { "lapis_lazuli" }, "blue_dye", 1 }, { { "cornflower" }, "blue_dye", 1 },
	{ { "red_dye", "yellow_dye" }, "orange_dye", 2 },
	{ { "green_dye", "white_dye" }, "lime_dye", 2 },
	{ { "red_dye", "white_dye" }, "pink_dye", 2 },
	{ { "black_dye", "white_dye" }, "gray_dye", 2 },
	{ { "gray_dye", "white_dye" }, "light_gray_dye", 2 },
	{ { "black_dye", "white_dye", "white_dye" }, "light_gray_dye", 3 },
	{ { "blue_dye", "green_dye" }, "cyan_dye", 2 },
	{ { "blue_dye", "white_dye" }, "light_blue_dye", 2 },
	{ { "blue_dye", "red_dye" }, "purple_dye", 2 },
	{ { "purple_dye", "pink_dye" }, "magenta_dye", 2 },
	{ { "blue_dye", "red_dye", "red_dye", "white_dye" }, "magenta_dye", 4 },
	{ { "pink_dye", "red_dye", "blue_dye" }, "magenta_dye", 3 },
} do
	table.insert(shapeless, { ingredients = r[1], result = { item = r[2], count = r[3] } })
end
-- dyeing: any wool + a dye -> wool of that colour; any bed + a dye -> a bed of that colour
for _, c in COLORS do
	table.insert(shapeless, { ingredients = { "#wool", `{c}_dye` }, result = { item = `{c}_wool`, count = 1 } })
	table.insert(shapeless, { ingredients = { "#beds", `{c}_dye` }, result = { item = `{c}_bed`, count = 1 } })
end

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
	raw_porkchop = "cooked_porkchop",
	potato = "baked_potato",
	raw_beef = "steak",
	raw_chicken = "cooked_chicken",
	raw_mutton = "cooked_mutton",
	cactus = "green_dye", -- Phase 9e (Java)
} :: { [string]: string }

-- Fuel burn time in seconds (one coal smelts 8 items).
Recipes.fuel = {
	lava_bucket = 1000, -- leaves an empty bucket behind (Recipes.fuelRemainder)
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
	wooden_sword = 10,
	-- Java burn times in ticks / 20
	oak_slab = 7.5, spruce_slab = 7.5, birch_slab = 7.5,
	oak_stairs = 15, spruce_stairs = 15, birch_stairs = 15,
	oak_fence = 15, spruce_fence = 15, birch_fence = 15,
	oak_door = 10, spruce_door = 10, birch_door = 10,
	oak_sign = 10, spruce_sign = 10, birch_sign = 10,
	ladder = 15,
	oak_trapdoor = 15, spruce_trapdoor = 15, birch_trapdoor = 15,
	oak_fence_gate = 15, spruce_fence_gate = 15, birch_fence_gate = 15,
	oak_hanging_sign = 10, spruce_hanging_sign = 10, birch_hanging_sign = 10,
	bow = 15, crossbow = 15, shield = 15,
} :: { [string]: number }

for _, fish in require(script.Parent.Fishing).SPECIES do
	if fish.key ~= "pufferfish" then Recipes.smelting[fish.key] = "cooked_fish" end
end
return Recipes
