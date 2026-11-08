--!strict
-- Item icons from ROCRAFT's generated pixel art (Render/TextureAtlas):
--   block items  -> the block's side texture from the block atlas
--   other items  -> the item's 16x16 icon from the icon sheet
-- Both are drawn with Pixelated resampling (sharp pixels). Until the atlas exists (or if
-- textures are off) the old flat drawings below are used.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemRegistry = require(Shared.Items.ItemRegistry)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local TextureAtlas = require(script.Parent.Parent.Render.TextureAtlas)

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

-- Pixel-art icon; returns false if the art isn't available.
local function drawArt(icon: Frame, def: ItemRegistry.ItemDef): boolean
	local content: Content? = nil
	local offset: Vector2?, size: Vector2? = nil, nil
	if def.block and not def.icon then
		local b = BlockRegistry.byId[def.block]
		content = TextureAtlas.content
		if b then
			offset, size = TextureAtlas.pixelRect(b.faceTexture[BlockRegistry.Dir.EAST])
		end
	else
		content = TextureAtlas.iconContent
		offset, size = TextureAtlas.iconRect(def.key)
	end
	if not content or not offset or not size then
		return false
	end
	local img = Instance.new("ImageLabel")
	img.Name = "Art"
	img.BackgroundTransparency = 1
	img.Size = UDim2.fromScale(1, 1)
	img.ResampleMode = Enum.ResamplerMode.Pixelated
	img.ImageRectOffset = offset
	img.ImageRectSize = size
	local ok = pcall(function()
		(img :: any).ImageContent = content
	end)
	if not ok then
		img:Destroy()
		return false
	end
	img.Parent = icon
	return true
end

function ItemIcon.draw(icon: Frame, itemKey: string)
	ItemIcon.clear(icon)
	local def = ItemRegistry.get(itemKey)
	if not def then
		return
	end
	if drawArt(icon, def) then
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
