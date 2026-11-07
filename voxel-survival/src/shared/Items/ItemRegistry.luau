--!strict
-- Item registry: block items (one per block, generated) + ItemDefs (materials, tools).
-- Item keys are strings (stable for saving). Block items use the block's key.

local Shared = script.Parent.Parent
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local ItemDefs = require(script.Parent.ItemDefs)

export type ItemDef = {
	key: string,
	name: string,
	stack: number,
	block: number?, -- block id placed by this item
	tool: ItemDefs.ToolDef?,
	food: ItemDefs.FoodDef?,
	color: { number },
}

local ItemRegistry = {}
local byKey: { [string]: ItemDef } = {}
ItemRegistry.byKey = byKey

-- Blocks that are never items (fluids).
local NOT_ITEMS = { water = true, lava = true }

for _, def in BlockRegistry.byId do
	if not NOT_ITEMS[def.key] then
		byKey[def.key] = {
			key = def.key,
			name = def.name,
			stack = 64,
			block = def.id,
			tool = nil,
			color = BlockRegistry.textureColor(def.faceTexture[BlockRegistry.Dir.TOP]),
		}
	end
end

for _, d in ItemDefs do
	assert(byKey[d.key] == nil, `ItemRegistry: duplicate item key {d.key}`)
	byKey[d.key] = {
		key = d.key,
		name = d.name,
		stack = d.stack or 64,
		block = nil,
		tool = d.tool,
		food = d.food,
		color = d.color or { 255, 0, 255 },
	}
end

-- Every block drop must be a real item (catches typos in BlockDefs at load time).
for _, def in BlockRegistry.byId do
	if def.drop then
		assert(byKey[def.drop], `ItemRegistry: block {def.key} drops unknown item '{def.drop}'`)
	end
end

function ItemRegistry.get(key: string?): ItemDef?
	if key == nil then
		return nil
	end
	return byKey[key]
end

return ItemRegistry
