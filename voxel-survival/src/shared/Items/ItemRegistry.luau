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
	icon: string?, -- block items drawn as a shape icon (ItemIconGen) instead of the flat texture
	iconTexture: string?, -- texture key that icon is painted with
}

local ItemRegistry = {}
local byKey: { [string]: ItemDef } = {}
ItemRegistry.byKey = byKey

-- Blocks that are never items (fluids).
local NOT_ITEMS = {
	water = true,
	lava = true,
	wall_torch_east = true,
	wall_torch_west = true,
	wall_torch_south = true,
	wall_torch_north = true,
	fire = true,
}

for _, def in BlockRegistry.byId do
	if not NOT_ITEMS[def.key] and not def.fluid and def.key ~= "campfire_unlit" and not def.noItem then
		byKey[def.key] = {
			key = def.key,
			name = def.name,
			stack = if def.shape == "sign" then 16 else 64,
			block = def.id,
			tool = nil,
			color = BlockRegistry.textureColor(def.faceTexture[BlockRegistry.Dir.TOP]),
			icon = def.icon,
			iconTexture = BlockRegistry.textureKeys[def.faceTexture[BlockRegistry.Dir.EAST]],
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

-- Every item, sorted by key (stable order for icon sheets).
local sorted: { ItemDef } = {}
for _, def in byKey do
	table.insert(sorted, def)
end
table.sort(sorted, function(a, b)
	return a.key < b.key
end)
function ItemRegistry.list(): { ItemDef }
	return sorted
end

function ItemRegistry.get(key: string?): ItemDef?
	if key == nil then
		return nil
	end
	return byKey[key]
end

return ItemRegistry
