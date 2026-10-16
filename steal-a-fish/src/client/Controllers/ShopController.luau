--!strict
--[[
	ShopController
	==============
	The 🛒 Shop window: ONLY Robux items, plus the free Daily Gift.

	  Tabs (left):  🎁 Daily  •  🎟 Passes  •  ⚡ Boosts  •  💵 Cash
	  - Daily: one free gift every 24 hours (Speed, cash or a Rare egg). The
	    button shows a countdown until it's ready. Clicking only ASKS the
	    server ("DailyGiftClaim"); the server checks the time and gives the
	    reward.
	  - Passes / Boosts / Cash: the Robux items from Config.Shop. They are
	    wired up in the Monetization milestone; for now the buttons say
	    "Coming soon".
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Hud = require(script.Parent.Parent.Ui.Hud)
local Kit = require(script.Parent.Parent.Ui.Kit)
local UIController = require(script.Parent.UIController)

local ShopController = {}
ShopController.Name = "ShopController"

local TAB_ICONS: { [string]: string } = { Daily = "🎁", Passes = "🎟", Boosts = "⚡", Cash = "💵" }
local TAB_COLORS: { [string]: Color3 } = {
	Daily = Color3.fromRGB(245, 90, 160),
	Passes = Color3.fromRGB(240, 180, 40),
	Boosts = Color3.fromRGB(60, 150, 240),
	Cash = Color3.fromRGB(80, 190, 80),
}

local player = Players.LocalPlayer
local window: Kit.Window
local pages: { [string]: Frame } = {}
local tabButtons: { [string]: TextButton } = {}
local giftButton: TextButton
local currentTab = "Daily"

local function formatCountdown(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d:%02d", seconds // 3600, (seconds // 60) % 60, seconds % 60)
end

local function secondsUntilGift(): number
	local readyAt = player:GetAttribute("DailyGiftAt")
	if typeof(readyAt) ~= "number" then
		return math.huge -- data not loaded yet
	end
	return readyAt - Workspace:GetServerTimeNow()
end

local function refreshGift()
	local left = secondsUntilGift()
	if left <= 0 then
		Kit.setText(giftButton, "CLAIM!")
		Kit.setColor(giftButton, Kit.Colors.Green)
	elseif left == math.huge then
		Kit.setText(giftButton, "...")
		Kit.setColor(giftButton, Kit.Colors.Grey)
	else
		Kit.setText(giftButton, `⏳ {formatCountdown(left)}`)
		Kit.setColor(giftButton, Kit.Colors.Grey)
	end
end

local function showTab(name: string)
	currentTab = name
	for tab, page in pages do
		page.Visible = tab == name
	end
	for tab, button in tabButtons do
		local stroke = button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = if tab == name then Color3.new(1, 1, 1) else Kit.Colors.Outline
			stroke.Thickness = if tab == name then 4 else 3
		end
	end
end

local function buildDailyPage(page: Frame)
	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, -10, 0, 250)
	card.BackgroundColor3 = TAB_COLORS.Daily
	card.Parent = page
	Kit.corner(card, 14)
	Kit.stroke(card)
	local icon = Kit.label(card, "🎁", UDim2.fromOffset(120, 120), UDim2.fromOffset(20, 20))
	icon.TextXAlignment = Enum.TextXAlignment.Center
	Kit.label(card, "Daily Gift", UDim2.new(1, -170, 0, 50), UDim2.fromOffset(150, 24), Kit.Colors.Text, 3)
	local description = Kit.label(card, "FREE every 24 hours!\nSpeed, cash or a Rare egg.", UDim2.new(1, -170, 0, 70), UDim2.fromOffset(150, 80), Kit.Colors.Text)
	description.TextYAlignment = Enum.TextYAlignment.Top
	giftButton = Kit.button(card, "", Kit.Colors.Green, UDim2.new(1, -40, 0, 64), UDim2.new(0, 20, 1, -84))
	giftButton.Activated:Connect(function()
		if secondsUntilGift() <= 0 then
			Net.event(Net.Names.DailyGiftClaim):FireServer()
		else
			UIController.Notify("Your next Daily Gift isn't ready yet!", "warning")
		end
	end)
	refreshGift()
end

local function buildItemCard(parent: Instance, item: Config.ShopItem, order: number)
	local card = Instance.new("Frame")
	card.LayoutOrder = order
	card.BackgroundColor3 = item.Color
	card.Parent = parent
	Kit.corner(card, 12)
	Kit.stroke(card)
	local icon = Kit.label(card, item.Icon, UDim2.new(1, 0, 0, 52), UDim2.fromOffset(0, 6))
	icon.TextXAlignment = Enum.TextXAlignment.Center
	local name = Kit.label(card, item.Name, UDim2.new(1, -12, 0, 26), UDim2.fromOffset(6, 60), Kit.Colors.Text, 2)
	name.TextXAlignment = Enum.TextXAlignment.Center
	local description = Kit.label(card, item.Description, UDim2.new(1, -12, 0, 34), UDim2.fromOffset(6, 88), Kit.Colors.Text, 1)
	description.TextXAlignment = Enum.TextXAlignment.Center
	local buy = Kit.button(card, `R$ {item.PriceRobux}`, Kit.Colors.Green, UDim2.new(1, -16, 0, 40), UDim2.new(0, 8, 1, -48))
	buy.Activated:Connect(function()
		-- Robux purchases are added in the Monetization milestone.
		UIController.Notify(`🛠 {item.Name} is coming soon!`, "info")
	end)
end

local function buildItemsPage(page: Frame, tab: string)
	local scroll = Kit.scroll(page, UDim2.fromScale(1, 1), UDim2.new())
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(150, 176)
	grid.CellPadding = UDim2.fromOffset(10, 10)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = scroll
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingLeft = UDim.new(0, 4)
	padding.Parent = scroll
	for index, item in Config.Shop.Items do
		if item.Tab == tab then
			buildItemCard(scroll, item, index)
		end
	end
end

function ShopController.Init()
	window = Kit.window("🛒 Shop", Vector2.new(720, 470), { Color = Kit.Colors.Green })

	local tabs = Instance.new("Frame")
	tabs.Size = UDim2.new(0, 150, 1, 0)
	tabs.BackgroundTransparency = 1
	tabs.Parent = window.Content
	Kit.list(tabs, 10)

	for order, tab in Config.Shop.Tabs do
		local button = Kit.button(tabs, `{TAB_ICONS[tab] or ""} {tab}`, TAB_COLORS[tab] or Kit.Colors.Blue, UDim2.new(1, -6, 0, 56))
		button.LayoutOrder = order
		button.Activated:Connect(function()
			showTab(tab)
		end)
		tabButtons[tab] = button

		local page = Instance.new("Frame")
		page.Name = tab
		page.Position = UDim2.fromOffset(166, 0)
		page.Size = UDim2.new(1, -166, 1, 0)
		page.BackgroundTransparency = 1
		page.Visible = false
		page.Parent = window.Content
		pages[tab] = page
		if tab == "Daily" then
			buildDailyPage(page)
		else
			buildItemsPage(page, tab)
		end
	end
	showTab(currentTab)

	Hud.Shop.Activated:Connect(function()
		window.Toggle()
	end)
end

function ShopController.Start()
	task.spawn(function()
		while true do
			if window.IsOpen() then
				refreshGift()
			end
			task.wait(1)
		end
	end)
	player:GetAttributeChangedSignal("DailyGiftAt"):Connect(refreshGift)
end

return ShopController
