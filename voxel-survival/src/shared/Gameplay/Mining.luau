--!strict
-- Classic block-breaking rules (shared: client predicts, server validates).
--
--   speed   = tool.speed if the tool kind matches the block (else 1); /5 in water; /5 airborne
--   damage  = speed / hardness / (30 if harvestable else 100)      per tick (20 ticks/s)
--   time    = ceil(1 / damage) ticks;  damage > 1 => instant
-- "harvestable" = the block drops its item: block.minTier == 0, or the right tool kind with
-- tier >= block.minTier.

local Shared = script.Parent.Parent
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local ItemRegistry = require(Shared.Items.ItemRegistry)

local Mining = {}

export type Modifiers = { inWater: boolean?, airborne: boolean? }

local function toolOf(itemKey: string?)
	local item = ItemRegistry.get(itemKey)
	return item and item.tool
end

function Mining.canHarvest(blockId: number, itemKey: string?): boolean
	local block = BlockRegistry.get(blockId)
	if not block then
		return false
	end
	if block.minTier <= 0 then
		return true
	end
	local tool = toolOf(itemKey)
	return tool ~= nil and tool.kind == block.tool and tool.tier >= block.minTier
end

-- Speed multiplier of the held item against this block.
function Mining.toolSpeed(blockId: number, itemKey: string?): number
	local block = BlockRegistry.get(blockId)
	local tool = toolOf(itemKey)
	if not block or not tool then
		return 1
	end
	if tool.blockSpeeds and tool.blockSpeeds[block.key] then
		return tool.blockSpeeds[block.key]
	end
	if tool.kind == block.tool then
		return tool.speed
	end
	return 1
end

-- Seconds to break; 0 = instant, math.huge = unbreakable.
function Mining.breakSeconds(blockId: number, itemKey: string?, mods: Modifiers?): number
	local block = BlockRegistry.get(blockId)
	if not block or block.hardness < 0 or block.liquid then
		return math.huge
	end
	if block.hardness == 0 then
		return 0
	end
	local speed = Mining.toolSpeed(blockId, itemKey)
	if mods then
		if mods.inWater then
			speed /= 5
		end
		if mods.airborne then
			speed /= 5
		end
	end
	local damage = speed / block.hardness / (if Mining.canHarvest(blockId, itemKey) then 30 else 100)
	if damage > 1 then
		return 0
	end
	return math.ceil(1 / damage - 1e-9) / 20
end

-- Durability used by breaking this block with this item (Java tool component): 0 for blocks that
-- break instantly (hardness 0) and for non-tools; swords lose 2; every other tool (pickaxe, axe,
-- shovel, hoe, shears) loses 1.
function Mining.durabilityCost(blockId: number, itemKey: string?): number
	local block = BlockRegistry.get(blockId)
	local tool = toolOf(itemKey)
	if not tool or not block or block.hardness <= 0 then
		return 0
	end
	return if tool.kind == "sword" then 2 else 1
end

return Mining
