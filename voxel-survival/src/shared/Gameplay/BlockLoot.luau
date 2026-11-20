--!strict
-- What a broken block drops (Phase 10c): Java loot tables with Fortune and Silk Touch, checked
-- against the Minecraft Wiki "Fortune" and "Silk Touch" pages.
--
--   silk touch   blocks that normally drop something else (or nothing) drop themselves: ores,
--                stone, grass blocks, glass and panes, ice, leaves, clay, snow blocks, gravel,
--                melons, bookshelves, campfires... and give no experience
--   fortune      ores (coal, iron, copper, gold, diamond, emerald, lapis): count x (1 + a random
--                0..level+1 minus 1, at least 0) (Java ore_drops); volt ore + 0..level; melon
--                + 0..level (max 9); gravel flint 10 / 14.3 / 25 / 100 %; leaves saplings, sticks
--                and apples by Java's table_bonus chances; crops: 3 + level seed tries; short
--                grass seeds + 0..2 x level
--   leaves       shears or silk touch: the leaves themselves
-- Pure: the server calls it in BlockActionService, tests check it.

local Shared = script.Parent.Parent
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local Mining = require(script.Parent.Mining)
local Farming = require(script.Parent.Farming)

local BlockLoot = {}

export type Stack = { item: string, count: number }

local ORE_DROPS = {
	coal_ore = true, iron_ore = true, copper_ore = true, gold_ore = true,
	diamond_ore = true, emerald_ore = true, lapis_ore = true,
}
-- Java table_bonus chances, by Fortune level (0, 1, 2, 3, 4+)
local FLINT = { 0.1, 0.14285715, 0.25, 1.0 }
local SAPLING = { 0.05, 0.0625, 0.083333336, 0.1 }
local STICK = { 0.02, 0.022222223, 0.025, 0.033333335, 0.1 }
local APPLE = { 0.005, 0.0055555557, 0.00625, 0.008333334, 0.025 }
local SAPLING_OF = { oak_leaves = "oak_sapling", birch_leaves = "birch_sapling", spruce_leaves = "spruce_sapling" }
-- what Silk Touch gives when the block's own key isn't the item
local SILK_ITEM = { snowy_grass_block = "grass_block", campfire_unlit = "campfire" }
local NO_SILK = { fire = true }

local function bonusChance(t: { number }, fortune: number): number
	return t[math.min(fortune, #t - 1) + 1]
end

-- The item Silk Touch gives for this block, or nil when it changes nothing.
function BlockLoot.silkItem(blockId: number): string?
	local def = BlockRegistry.get(blockId)
	if not def or NO_SILK[def.key] or def.family == "farmland" then
		return nil
	end
	local key = SILK_ITEM[def.key] or def.key
	if not ItemRegistry.get(key) or def.drop == key then
		return nil
	end
	return key
end

-- Drops of block `blockId` broken with `item` (key) carrying enchantment levels `fortune` and
-- `silk`. `rand()` in [0, 1), `randInt(a, b)` inclusive. Returns the stacks and whether ore
-- experience may drop (not with Silk Touch).
function BlockLoot.drops(blockId: number, item: string?, fortune: number, silk: boolean,
	rand: () -> number, randInt: (number, number) -> number): ({ Stack }, boolean)
	local out: { Stack } = {}
	local def = BlockRegistry.get(blockId)
	if not def then
		return out, false
	end
	local itemDef = ItemRegistry.get(item)
	local toolKind = if itemDef and itemDef.tool then itemDef.tool.kind else nil

	-- plants and crops (Farming: seeds, ripe crops, shears for grass)
	local farm = Farming.drops(blockId, toolKind, rand, fortune)
	if farm then
		for _, s in farm do
			if s.count > 0 then
				table.insert(out, s)
			end
		end
		return out, false
	end

	-- leaves
	if string.sub(def.key, -7) == "_leaves" then
		if toolKind == "shears" or silk then
			table.insert(out, { item = def.key, count = 1 })
			return out, false
		end
		local sapling = SAPLING_OF[def.key]
		if sapling and rand() < bonusChance(SAPLING, fortune) then
			table.insert(out, { item = sapling, count = 1 })
		end
		if rand() < bonusChance(STICK, fortune) then
			table.insert(out, { item = "stick", count = randInt(1, 2) })
		end
		if def.key == "oak_leaves" and rand() < bonusChance(APPLE, fortune) then
			table.insert(out, { item = "apple", count = 1 })
		end
		return out, false
	end

	if not Mining.canHarvest(blockId, item) then
		return out, false
	end
	if silk then
		local s = BlockLoot.silkItem(blockId)
		if s then
			table.insert(out, { item = s, count = 1 })
			return out, false
		end
	end
	local drop = def.drop
	if drop then
		local count = if def.dropMax > def.dropMin then randInt(def.dropMin, def.dropMax) else def.dropMin
		local alt = def.altDrop
		if alt and alt.item == "flint" then
			if rand() < bonusChance(FLINT, fortune) then
				drop = "flint" -- Java: gravel drops flint, more often with Fortune
			end
		elseif alt and rand() < alt.chance then
			drop = alt.item
		end
		if fortune > 0 then
			if ORE_DROPS[def.key] then
				count *= math.max(0, randInt(0, fortune + 1) - 1) + 1
			elseif def.key == "volt_ore" then
				count += randInt(0, fortune)
			elseif def.key == "melon" then
				count = math.min(9, count + randInt(0, fortune))
			end
		end
		table.insert(out, { item = drop, count = count })
	end
	for _, bonus in def.bonusDrops do
		if rand() < bonus.chance then
			table.insert(out, { item = bonus.item, count = 1 })
		end
	end
	return out, true
end

return BlockLoot
