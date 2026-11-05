--!strict
-- Hotbar: 9 slots at the bottom centre. Keys 1-9, mouse wheel, gamepad bumpers, or tap a slot.
-- Original look: dark translucent tiles with a thin light border; the selected tile gets a
-- thicker bright border and lifts slightly. Icons are placeholders (phase 7 draws pixel icons):
--   block items  -> a tile in the block's colour
--   tools        -> a handle + coloured head glyph
--   other items  -> a rounded swatch
-- The item name fades in above the bar when the selection changes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local InventoryClient = require(script.Parent.Parent.Player.InventoryClient)

local SLOT = 50
local GAP = 4
local N = Config.HOTBAR_SLOTS

local Hotbar = {}

type SlotUI = { frame: TextButton, stroke: UIStroke, icon: Frame, count: TextLabel, durability: Frame, durabilityBg: Frame }
local slots: { SlotUI } = {}
local nameLabel: TextLabel

local function rgb(c: { number }): Color3
	return Color3.fromRGB(c[1], c[2], c[3])
end

local function clearIcon(icon: Frame)
	for _, c in icon:GetChildren() do
		c:Destroy()
	end
	icon.BackgroundTransparency = 1
end

local function drawIcon(icon: Frame, itemKey: string)
	clearIcon(icon)
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

local shownItems: { [number]: string? } = {}

local function refresh(selectionChanged: boolean)
	for i, ui in slots do
		local stack = InventoryClient.slots[i]
		local key = stack and stack.item
		if shownItems[i] ~= key then
			shownItems[i] = key
			if key then
				drawIcon(ui.icon, key)
			else
				clearIcon(ui.icon)
			end
		end
		ui.count.Text = if stack and stack.count > 1 then tostring(stack.count) else ""
		local def = key and ItemRegistry.get(key)
		if stack and def and def.tool and stack.durability and stack.durability < def.tool.durability then
			local f = math.clamp(stack.durability / def.tool.durability, 0, 1)
			ui.durabilityBg.Visible = true
			ui.durability.Size = UDim2.fromScale(f, 1)
			ui.durability.BackgroundColor3 = Color3.fromHSV(f * 0.33, 0.9, 0.9)
		else
			ui.durabilityBg.Visible = false
		end
		local selected = i == InventoryClient.selected
		ui.stroke.Thickness = if selected then 3 else 1
		ui.stroke.Color = if selected then Color3.fromRGB(250, 250, 255) else Color3.fromRGB(190, 192, 200)
		ui.stroke.Transparency = if selected then 0 else 0.45
		ui.frame.Position = UDim2.fromOffset((i - 1) * (SLOT + GAP), if selected then -4 else 0)
	end
	if selectionChanged then
		local stack = InventoryClient.heldStack()
		local def = stack and ItemRegistry.get(stack.item)
		nameLabel.Text = if def then def.name else ""
		nameLabel.TextTransparency = 0
		nameLabel.TextStrokeTransparency = 0.4
		TweenService:Create(nameLabel, TweenInfo.new(0.6, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, 1.4), {
			TextTransparency = 1,
			TextStrokeTransparency = 1,
		}):Play()
	end
end

function Hotbar.init()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Hotbar"
	gui.ResetOnSpawn = false

	local bar = Instance.new("Frame")
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -12)
	bar.Size = UDim2.fromOffset(N * SLOT + (N - 1) * GAP, SLOT)
	bar.Parent = gui

	nameLabel = Instance.new("TextLabel")
	nameLabel.BackgroundTransparency = 1
	nameLabel.AnchorPoint = Vector2.new(0.5, 1)
	nameLabel.Position = UDim2.new(0.5, 0, 0, -14)
	nameLabel.Size = UDim2.fromOffset(300, 22)
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 16
	nameLabel.TextColor3 = Color3.fromRGB(240, 240, 245)
	nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	nameLabel.TextTransparency = 1
	nameLabel.TextStrokeTransparency = 1
	nameLabel.Parent = bar

	for i = 1, N do
		local frame = Instance.new("TextButton")
		frame.Text = ""
		frame.AutoButtonColor = false
		frame.BackgroundColor3 = Color3.fromRGB(18, 20, 26)
		frame.BackgroundTransparency = 0.3
		frame.BorderSizePixel = 0
		frame.Size = UDim2.fromOffset(SLOT, SLOT)
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 4)
		corner.Parent = frame
		local stroke = Instance.new("UIStroke")
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = frame

		local icon = Instance.new("Frame")
		icon.BorderSizePixel = 0
		icon.BackgroundTransparency = 1
		icon.AnchorPoint = Vector2.new(0.5, 0.5)
		icon.Position = UDim2.fromScale(0.5, 0.48)
		icon.Size = UDim2.fromOffset(30, 30)
		icon.Parent = frame

		local count = Instance.new("TextLabel")
		count.BackgroundTransparency = 1
		count.AnchorPoint = Vector2.new(1, 1)
		count.Position = UDim2.new(1, -3, 1, -1)
		count.Size = UDim2.fromOffset(30, 16)
		count.Font = Enum.Font.GothamBold
		count.TextSize = 14
		count.TextXAlignment = Enum.TextXAlignment.Right
		count.TextColor3 = Color3.fromRGB(250, 250, 250)
		count.TextStrokeTransparency = 0.2
		count.ZIndex = 3
		count.Text = ""
		count.Parent = frame

		local durabilityBg = Instance.new("Frame")
		durabilityBg.BorderSizePixel = 0
		durabilityBg.BackgroundColor3 = Color3.new(0, 0, 0)
		durabilityBg.Position = UDim2.new(0, 6, 1, -6)
		durabilityBg.Size = UDim2.new(1, -12, 0, 3)
		durabilityBg.Visible = false
		durabilityBg.ZIndex = 3
		durabilityBg.Parent = frame
		local durability = Instance.new("Frame")
		durability.BorderSizePixel = 0
		durability.Size = UDim2.fromScale(1, 1)
		durability.ZIndex = 4
		durability.Parent = durabilityBg

		frame.Activated:Connect(function()
			InventoryClient.select(i)
		end)
		frame.Parent = bar
		slots[i] = { frame = frame, stroke = stroke, icon = icon, count = count, durability = durability, durabilityBg = durabilityBg }
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local k = input.KeyCode.Value - Enum.KeyCode.One.Value + 1
		if input.UserInputType == Enum.UserInputType.Keyboard and k >= 1 and k <= N then
			InventoryClient.select(k)
		elseif input.KeyCode == Enum.KeyCode.ButtonR1 then
			InventoryClient.select(InventoryClient.selected + 1)
		elseif input.KeyCode == Enum.KeyCode.ButtonL1 then
			InventoryClient.select(InventoryClient.selected - 1)
		end
	end)
	UserInputService.InputChanged:Connect(function(input, processed)
		if not processed and input.UserInputType == Enum.UserInputType.MouseWheel then
			-- wheel down = next slot, wheel up = previous
			InventoryClient.select(InventoryClient.selected + (if input.Position.Z < 0 then 1 else -1))
		end
	end)

	InventoryClient.Changed:Connect(refresh)
	refresh(true)
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

return Hotbar
