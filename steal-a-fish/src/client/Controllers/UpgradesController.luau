--!strict
--[[
	UpgradesController
	==================
	  - A big "⬆ Upgrades" button under the HUD opens the Upgrades window:
	      * Plot Space: unlock the next pad
	      * Treadmill: buy the next treadmill tier
	    Prices come from the shared Config, so they always match the server.
	    Clicking Buy only ASKS the server; the server checks and takes the money.
	  - Pet prompts (Upgrade / Sell) are only shown on YOUR OWN pets.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)

local UpgradesController = {}
UpgradesController.Name = "UpgradesController"

local player = Players.LocalPlayer

local AFFORD_COLOR = Color3.fromRGB(70, 200, 100)
local CANT_AFFORD_COLOR = Color3.fromRGB(110, 110, 125)
local MAX_COLOR = Color3.fromRGB(240, 180, 40)

type Card = {
	Description: TextLabel,
	Button: TextButton,
}

local window: Frame
local padsCard: Card
local treadmillCard: Card

local function attributeNumber(name: string, default: number): number
	local value = player:GetAttribute(name)
	return if typeof(value) == "number" then value else default
end

local function corner(parent: GuiObject, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function textLabel(parent: Instance, text: string, size: UDim2, position: UDim2, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = color
	label.Text = text
	label.Size = size
	label.Position = position
	label.Parent = parent
	return label
end

local function makeCard(parent: Instance, order: number, title: string, upgradeName: string): Card
	local card = Instance.new("Frame")
	card.LayoutOrder = order
	card.Size = UDim2.new(1, 0, 0, 84)
	card.BackgroundColor3 = Color3.fromRGB(35, 50, 80)
	card.Parent = parent
	corner(card, 12)

	textLabel(card, title, UDim2.new(0.62, -12, 0, 34), UDim2.fromOffset(12, 8), Color3.new(1, 1, 1))
	local description = textLabel(card, "", UDim2.new(0.62, -12, 0, 26), UDim2.fromOffset(12, 46), Color3.fromRGB(190, 210, 240))

	local button = Instance.new("TextButton")
	button.AnchorPoint = Vector2.new(1, 0.5)
	button.Position = UDim2.new(1, -12, 0.5, 0)
	button.Size = UDim2.new(0.38, -12, 0, 56)
	button.BackgroundColor3 = AFFORD_COLOR
	button.Font = Enum.Font.FredokaOne
	button.TextScaled = true
	button.TextColor3 = Color3.new(1, 1, 1)
	button.Parent = card
	corner(button, 10)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.Parent = button

	button.Activated:Connect(function()
		Net.event(Net.Names.BuyUpgrade):FireServer(upgradeName)
	end)

	return { Description = description, Button = button }
end

local function setButton(card: Card, price: number?)
	if price == nil then
		card.Button.Text = "MAX"
		card.Button.BackgroundColor3 = MAX_COLOR
		card.Button.AutoButtonColor = false
		return
	end
	card.Button.Text = `${Format.short(price)}`
	card.Button.AutoButtonColor = true
	local money = attributeNumber(Constants.Attributes.Money, 0)
	card.Button.BackgroundColor3 = if money >= price then AFFORD_COLOR else CANT_AFFORD_COLOR
end

local function refresh()
	if not window then
		return
	end
	-- Plot space
	local maxPads = Config.Plots.PadsPerSide * 2
	local unlocked = attributeNumber(Constants.Attributes.PadsUnlocked, Config.Plots.StartingPads)
	if unlocked >= maxPads then
		padsCard.Description.Text = `Pads: {unlocked}/{maxPads}`
		setButton(padsCard, nil)
	else
		local bought = unlocked - Config.Plots.StartingPads
		padsCard.Description.Text = `Pads: {unlocked}/{maxPads}  →  +1 pad`
		setButton(padsCard, Config.UpgradePrice(Config.Upgrades.Pads.Base, Config.Upgrades.Pads.Growth, bought))
	end

	-- Treadmill
	local tiers = Config.Treadmill.Tiers
	local current = attributeNumber(Constants.Attributes.TreadmillTier, 1)
	local nextTier = tiers[current + 1]
	if nextTier then
		treadmillCard.Description.Text = `{tiers[current].Name} → {nextTier.Name}  (+{Format.short(nextTier.Gain)}/s)`
		setButton(treadmillCard, nextTier.Price)
	else
		treadmillCard.Description.Text = `{tiers[current].Name} (+{Format.short(tiers[current].Gain)}/s)`
		setButton(treadmillCard, nil)
	end
end

local function buildGui()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Upgrades"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 15
	gui.Parent = player:WaitForChild("PlayerGui")

	-- Open button under the HUD panel.
	local open = Instance.new("TextButton")
	open.Name = "OpenUpgrades"
	open.Position = UDim2.fromOffset(16, 184)
	open.Size = UDim2.fromOffset(210, 48)
	open.BackgroundColor3 = AFFORD_COLOR
	open.Font = Enum.Font.FredokaOne
	open.TextScaled = true
	open.TextColor3 = Color3.new(1, 1, 1)
	open.Text = "⬆ Upgrades"
	open.Parent = gui
	corner(open, 12)
	local openPadding = Instance.new("UIPadding")
	openPadding.PaddingTop = UDim.new(0, 8)
	openPadding.PaddingBottom = UDim.new(0, 8)
	openPadding.Parent = open

	-- The window itself.
	window = Instance.new("Frame")
	window.Name = "Window"
	window.AnchorPoint = Vector2.new(0.5, 0.5)
	window.Position = UDim2.fromScale(0.5, 0.5)
	window.Size = UDim2.new(0.9, 0, 0, 290)
	window.BackgroundColor3 = Color3.fromRGB(20, 30, 50)
	window.Visible = false
	window.Parent = gui
	corner(window, 16)
	local limit = Instance.new("UISizeConstraint")
	limit.MaxSize = Vector2.new(460, 290)
	limit.Parent = window
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(90, 200, 255)
	stroke.Thickness = 3
	stroke.Parent = window

	textLabel(window, "⬆ Upgrades", UDim2.new(1, -80, 0, 40), UDim2.fromOffset(16, 10), Color3.new(1, 1, 1))

	local close = Instance.new("TextButton")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -10, 0, 10)
	close.Size = UDim2.fromOffset(44, 44)
	close.BackgroundColor3 = Color3.fromRGB(220, 70, 70)
	close.Font = Enum.Font.FredokaOne
	close.TextScaled = true
	close.TextColor3 = Color3.new(1, 1, 1)
	close.Text = "✕"
	close.Parent = window
	corner(close, 10)

	local list = Instance.new("Frame")
	list.Position = UDim2.fromOffset(16, 64)
	list.Size = UDim2.new(1, -32, 1, -80)
	list.BackgroundTransparency = 1
	list.Parent = window
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 12)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	padsCard = makeCard(list, 1, "🟩 Plot Space", "Pads")
	treadmillCard = makeCard(list, 2, "🏃 Treadmill", "Treadmill")

	open.Activated:Connect(function()
		window.Visible = not window.Visible
		refresh()
	end)
	close.Activated:Connect(function()
		window.Visible = false
	end)
end

-- Only show Upgrade/Sell prompts on your own pets.
local function refreshPetPrompt(prompt: Instance)
	if prompt:IsA("ProximityPrompt") then
		prompt.Enabled = prompt:GetAttribute(Constants.Attributes.OwnerUserId) == player.UserId
	end
end

function UpgradesController.Init()
	buildGui()
end

function UpgradesController.Start()
	for _, name in { Constants.Attributes.Money, Constants.Attributes.PadsUnlocked, Constants.Attributes.TreadmillTier } do
		player:GetAttributeChangedSignal(name):Connect(refresh)
	end
	refresh()

	CollectionService:GetInstanceAddedSignal(Constants.Tags.PetPrompt):Connect(refreshPetPrompt)
	for _, prompt in CollectionService:GetTagged(Constants.Tags.PetPrompt) do
		refreshPetPrompt(prompt)
	end
end

return UpgradesController
