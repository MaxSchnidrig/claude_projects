--!strict
--[[
	UpgradesController
	==================
	  - The "⬆ Upgrades" button in the left column opens the Upgrades window:
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
local Kit = require(script.Parent.Parent.Ui.Kit)

local UpgradesController = {}
UpgradesController.Name = "UpgradesController"

local player = Players.LocalPlayer

type Card = {
	Description: TextLabel,
	Button: TextButton,
}

local window: Kit.Window
local padsCard: Card
local treadmillCard: Card

local function attributeNumber(name: string, default: number): number
	local value = player:GetAttribute(name)
	return if typeof(value) == "number" then value else default
end

local function makeCard(parent: Instance, order: number, title: string, upgradeName: string): Card
	local card = Instance.new("Frame")
	card.LayoutOrder = order
	card.Size = UDim2.new(1, 0, 0, 84)
	card.BackgroundColor3 = Kit.Colors.Card
	card.Parent = parent
	Kit.corner(card, 12)

	Kit.label(card, title, UDim2.new(0.62, -12, 0, 34), UDim2.fromOffset(12, 8))
	local description = Kit.label(card, "", UDim2.new(0.62, -12, 0, 26), UDim2.fromOffset(12, 46), Kit.Colors.SubText)
	local button = Kit.button(card, "", Kit.Colors.Green, UDim2.new(0.38, -12, 0, 56), UDim2.new(0.62, 0, 0.5, -28))
	button.Activated:Connect(function()
		Net.event(Net.Names.BuyUpgrade):FireServer(upgradeName)
	end)
	return { Description = description, Button = button }
end

local function setButton(card: Card, price: number?)
	if price == nil then
		card.Button.Text = "MAX"
		card.Button.BackgroundColor3 = Kit.Colors.Gold
		card.Button.AutoButtonColor = false
		return
	end
	card.Button.Text = `${Format.short(price)}`
	card.Button.AutoButtonColor = true
	local money = attributeNumber(Constants.Attributes.Money, 0)
	card.Button.BackgroundColor3 = if money >= price then Kit.Colors.Green else Kit.Colors.Grey
end

local function refresh()
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

-- Only show Upgrade/Sell prompts on your own pets.
local function refreshPetPrompt(prompt: Instance)
	if prompt:IsA("ProximityPrompt") then
		prompt.Enabled = prompt:GetAttribute(Constants.Attributes.OwnerUserId) == player.UserId
	end
end

function UpgradesController.Init()
	window = Kit.window("⬆ Upgrades", Vector2.new(460, 290))
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 12)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = window.Content
	padsCard = makeCard(window.Content, 1, "🟩 Plot Space", "Pads")
	treadmillCard = makeCard(window.Content, 2, "🏃 Treadmill", "Treadmill")

	local open = Kit.menuButton("⬆ Upgrades", Kit.Colors.Green, 10)
	open.Activated:Connect(function()
		refresh()
		window.Toggle()
	end)
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
