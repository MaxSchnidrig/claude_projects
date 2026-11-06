--!strict
-- Placeholder item icons drawn from Frames (phase 7 replaces them with generated pixel art):
--   block items  -> a tile in the block's colour with a darker lower band
--   tools        -> a handle + coloured head glyph, shaped by tool kind
--   other items  -> a round swatch

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemRegistry = require(Shared.Items.ItemRegistry)

local ItemIcon = {}

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

function ItemIcon.clear(icon: Frame)
	for _, c in icon:GetChildren() do
		c:Destroy()
	end
	icon.BackgroundTransparency = 1
end

function ItemIcon.draw(icon: Frame, itemKey: string)
	ItemIcon.clear(icon)
	local def = ItemRegistry.get(itemKey)
	if not def then
		return
	end
	local color = rgb(def.color)
	if def.block then
		icon.BackgroundTransparency = 0
		icon.BackgroundColor3 = color
		local shade = Instance.new("Frame") -- darker lower third suggests a block's side face
		shade.BorderSizePixel = 0
		shade.BackgroundColor3 = Color3.new(0, 0, 0)
		shade.BackgroundTransparency = 0.7
		shade.Size = UDim2.fromScale(1, 0.35)
		shade.Position = UDim2.fromScale(0, 0.65)
		shade.Parent = icon
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Transparency = 0.5
		stroke.Parent = icon
	elseif def.tool then
		local handle = Instance.new("Frame")
		handle.BorderSizePixel = 0
		handle.BackgroundColor3 = Color3.fromRGB(120, 88, 50)
		handle.AnchorPoint = Vector2.new(0.5, 0.5)
		handle.Position = UDim2.fromScale(0.5, 0.55)
		handle.Size = UDim2.fromScale(0.16, 0.95)
		handle.Rotation = 45
		handle.Parent = icon
		local head = Instance.new("Frame")
		head.BorderSizePixel = 0
		head.BackgroundColor3 = color
		head.AnchorPoint = Vector2.new(0.5, 0.5)
		head.Position = UDim2.fromScale(0.68, 0.32)
		local kind = def.tool.kind
		head.Size = if kind == "pickaxe" then UDim2.fromScale(0.85, 0.2)
			elseif kind == "axe" then UDim2.fromScale(0.42, 0.42)
			elseif kind == "shovel" then UDim2.fromScale(0.3, 0.42)
			else UDim2.fromScale(0.5, 0.18)
		head.Rotation = if kind == "pickaxe" then -45 else 45
		head.Parent = icon
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Transparency = 0.4
		stroke.Parent = head
	else
		icon.BackgroundTransparency = 0
		icon.BackgroundColor3 = color
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = icon
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Transparency = 0.5
		stroke.Parent = icon
	end
end

return ItemIcon
