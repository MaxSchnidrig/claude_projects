--!strict
--[[
	Hud
	===
	The always-visible buttons and stats (built the first time any
	controller requires this module):

	  left, middle:   [🛒 Shop]  (green)      [📖 Index] (blue, red badge = rewards to claim)
	                  active boost timers below them (Hud.Boosts, filled by ShopController)
	  right, middle:  [🥚] Eggs (red)          [🐟] Fish (orange)
	  bottom left:    👟 58.1K    (Speed)
	                  💵 $4.1M    (Money)
	  On phones/tablets the stats sit at the top left instead, so the
	  thumbstick doesn't cover them.

	Controllers connect to the buttons, for example:
		Hud.Shop.Activated:Connect(function() ... end)
		Hud.setIndexBadge(3)
]]

local Kit = require(script.Parent.Kit)

local Hud = {}

local gui = Kit.screenGui("Hud", 1)

-- One big rectangular menu button with an icon and a word.
local function menuButton(parent: Instance, icon: string, text: string, color: Color3, order: number): TextButton
	local button = Kit.button(parent, "", color, UDim2.fromOffset(170, 64))
	button.LayoutOrder = order
	local iconLabel = Kit.label(button, icon, UDim2.fromOffset(46, 46), UDim2.fromOffset(8, 9), Kit.Colors.Text, 2)
	iconLabel.TextXAlignment = Enum.TextXAlignment.Center
	iconLabel.ZIndex = 2
	local word = Kit.label(button, text, UDim2.new(1, -66, 0, 40), UDim2.fromOffset(58, 12), Kit.Colors.Text, 3)
	word.ZIndex = 2
	return button
end

-- One square button with just an icon.
local function squareButton(parent: Instance, icon: string, color: Color3, order: number): TextButton
	local button = Kit.button(parent, "", color, UDim2.fromOffset(72, 72))
	button.LayoutOrder = order
	local iconLabel = Kit.label(button, icon, UDim2.new(1, -16, 1, -16), UDim2.fromOffset(8, 8), Kit.Colors.Text, 2)
	iconLabel.TextXAlignment = Enum.TextXAlignment.Center
	iconLabel.ZIndex = 2
	return button
end

-- Left middle: Shop and Index.
local left = Instance.new("Frame")
left.Name = "LeftButtons"
left.AnchorPoint = Vector2.new(0, 0.5)
left.Position = UDim2.new(0, 16, 0.45, 0)
left.Size = UDim2.fromOffset(170, 140)
left.BackgroundTransparency = 1
left.Parent = gui
Kit.list(left, 12)
Kit.autoScale(left)

Hud.Shop = menuButton(left, "🛒", "Shop", Kit.Colors.Green, 1)
Hud.Index = menuButton(left, "📖", "Index", Kit.Colors.Blue, 2)
Hud.setIndexBadge = Kit.badge(Hud.Index)

-- Active boosts ("💸 2x Money 12:30") under the buttons.
local boosts = Instance.new("Frame")
boosts.Name = "Boosts"
boosts.LayoutOrder = 3
boosts.Size = UDim2.fromOffset(170, 0)
boosts.AutomaticSize = Enum.AutomaticSize.Y
boosts.BackgroundTransparency = 1
boosts.Parent = left
Kit.list(boosts, 6)
Hud.Boosts = boosts

-- Right middle: Eggs and Fish.
local right = Instance.new("Frame")
right.Name = "RightButtons"
right.AnchorPoint = Vector2.new(1, 0.5)
right.Position = UDim2.new(1, -16, 0.45, 0)
right.Size = UDim2.fromOffset(72, 156)
right.BackgroundTransparency = 1
right.Parent = gui
Kit.list(right, 12)
Kit.autoScale(right)

Hud.Eggs = squareButton(right, "🥚", Kit.Colors.Red, 1)
Hud.Fish = squareButton(right, "🐟", Kit.Colors.Orange, 2)

-- Stats: bottom left (top left on touch screens).
local stats = Instance.new("Frame")
stats.Name = "Stats"
if Kit.isTouch() then
	stats.AnchorPoint = Vector2.new(0, 0)
	stats.Position = UDim2.fromOffset(16, 60)
else
	stats.AnchorPoint = Vector2.new(0, 1)
	stats.Position = UDim2.new(0, 16, 1, -16)
end
stats.Size = UDim2.fromOffset(260, 116)
stats.BackgroundTransparency = 1
stats.Parent = gui
Kit.autoScale(stats)

local function statRow(icon: string, color: Color3, y: number): TextLabel
	local iconLabel = Kit.label(stats, icon, UDim2.fromOffset(50, 50), UDim2.fromOffset(0, y), Kit.Colors.Text, 2)
	iconLabel.TextXAlignment = Enum.TextXAlignment.Center
	return Kit.label(stats, "", UDim2.new(1, -60, 0, 50), UDim2.fromOffset(58, y), color, 4)
end

Hud.SpeedLabel = statRow("👟", Color3.new(1, 1, 1), 0)
Hud.MoneyLabel = statRow("💵", Color3.fromRGB(120, 255, 100), 60)

return Hud
