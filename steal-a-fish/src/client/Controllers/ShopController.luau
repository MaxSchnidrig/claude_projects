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
	  - Passes / Boosts / Cash: the Robux items from Config.Shop. The buy
	    button only ASKS the server ("ShopBuy"); the server opens Roblox's
	    purchase window (see MonetizationService). Owned passes say
	    "OWNED ✓", running boosts show their time left, and the real Robux
	    price is loaded from Roblox when the item has an ID.
	  - Active boosts are shown as timers under the HUD buttons.
	  - After a purchase: sound + confetti ("PurchaseThanks").
	  - VIP players get a gold [👑 VIP] tag in the chat.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)
local Effects = require(script.Parent.Parent.Ui.Effects)
local Hud = require(script.Parent.Parent.Ui.Hud)
local Kit = require(script.Parent.Parent.Ui.Kit)
local Sounds = require(script.Parent.Parent.Ui.Sounds)
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

-- Buy buttons and timer labels, by item Key.
type Card = { Item: Config.ShopItem, Buy: TextButton, Timer: TextLabel, Price: number }
local cards: { Card } = {}
-- Which boost each product feeds (for its timer).
local BOOST_OF: { [string]: string } = { Money15 = "Money", Speed15 = "Speed", Luck15 = "Luck" }
local HUD_BOOSTS = {
	{ Attribute = "BoostMoneyEndsAt", Text = "💸 2x Money", Color = Color3.fromRGB(70, 190, 90) },
	{ Attribute = "BoostSpeedEndsAt", Text = "⚡ 2x Speed", Color = Color3.fromRGB(60, 150, 240) },
	{ Attribute = "BoostLuckEndsAt", Text = "🍀 2x Luck", Color = Color3.fromRGB(60, 200, 90) },
	{ Attribute = "ServerLuckEndsAt", Text = "🌟 Server Luck", Color = Color3.fromRGB(240, 190, 40), OnWorkspace = true },
}
local hudPills: { [string]: TextLabel } = {}

local function formatCountdown(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d:%02d", seconds // 3600, (seconds // 60) % 60, seconds % 60)
end

local function shortCountdown(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	if seconds >= 3600 then
		return string.format("%d:%02d:%02d", seconds // 3600, (seconds // 60) % 60, seconds % 60)
	end
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

-- Seconds left on a boost (0 = not running).
local function boostLeft(attribute: string, onWorkspace: boolean?): number
	local endsAt = if onWorkspace then Workspace:GetAttribute(attribute) else player:GetAttribute(attribute)
	if typeof(endsAt) ~= "number" then
		return 0
	end
	return math.max(0, endsAt - Workspace:GetServerTimeNow())
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
	-- Time left on a running boost (boost cards only).
	local timer = Kit.label(card, "", UDim2.new(1, -12, 0, 22), UDim2.new(0, 6, 1, -74), Color3.fromRGB(255, 240, 120), 2)
	timer.TextXAlignment = Enum.TextXAlignment.Center
	local entry: Card = { Item = item, Buy = buy, Timer = timer, Price = item.PriceRobux }
	table.insert(cards, entry)
	buy.Activated:Connect(function()
		if item.Kind == "Pass" and player:GetAttribute(`Pass_{item.Key}`) == true then
			UIController.Notify(`You already own {item.Name}!`, "info")
			return
		end
		Sounds.play("Click")
		-- The server checks it and opens Roblox's purchase window.
		Net.event(Net.Names.ShopBuy):FireServer(item.Key)
	end)
	-- Show the real price from Roblox (the Config price is only a placeholder).
	if item.Id ~= 0 then
		task.spawn(function()
			local infoType = if item.Kind == "Pass" then Enum.InfoType.GamePass else Enum.InfoType.Product
			local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, item.Id, infoType)
			if ok and typeof(info) == "table" and typeof(info.PriceInRobux) == "number" then
				entry.Price = info.PriceInRobux
			end
		end)
	end
end

-- Owned passes, prices and boost timers on the cards.
local function refreshCards()
	for _, card in cards do
		local item = card.Item
		if item.Kind == "Pass" and player:GetAttribute(`Pass_{item.Key}`) == true then
			Kit.setText(card.Buy, "OWNED ✓")
			Kit.setColor(card.Buy, Kit.Colors.Grey)
		else
			Kit.setText(card.Buy, `R$ {card.Price}`)
			Kit.setColor(card.Buy, Kit.Colors.Green)
		end
		local boost = BOOST_OF[item.Key]
		local left = if boost then boostLeft(`Boost{boost}EndsAt`)
			elseif item.Key == "ServerLuck" then boostLeft("ServerLuckEndsAt", true)
			else 0
		card.Timer.Text = if left > 0 then `⏳ {shortCountdown(left)} left` else ""
	end
end

-- The boost timers under the HUD buttons.
local function refreshHudBoosts()
	for order, info in HUD_BOOSTS do
		local left = boostLeft(info.Attribute, info.OnWorkspace)
		local pill = hudPills[info.Attribute]
		if left > 0 then
			if not pill then
				local frame = Instance.new("Frame")
				frame.LayoutOrder = order
				frame.Size = UDim2.fromOffset(170, 34)
				frame.BackgroundColor3 = info.Color
				frame.Parent = Hud.Boosts
				Kit.corner(frame, 10)
				Kit.stroke(frame, Kit.Colors.Outline, 3)
				local label = Kit.label(frame, "", UDim2.new(1, -12, 1, -6), UDim2.fromOffset(6, 3), Kit.Colors.Text, 2)
				label.TextXAlignment = Enum.TextXAlignment.Center
				hudPills[info.Attribute] = label
				pill = label
			end
			(pill :: TextLabel).Text = `{info.Text}  {shortCountdown(left)}`
		elseif pill then
			(pill.Parent :: Instance):Destroy()
			hudPills[info.Attribute] = nil
		end
	end
end

local function onPurchaseThanks(icon: unknown, name: unknown)
	Sounds.play("Purchase")
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		Effects.confetti(root.Position + Vector3.new(0, 4, 0), 80)
		Effects.burst(root.Position + Vector3.new(0, 2, 0), Color3.fromRGB(255, 215, 70), 40)
	end
	if typeof(icon) == "string" and typeof(name) == "string" then
		UIController.Notify(`{icon} {name}: thank you for your support!`, "purchase")
	end
	refreshCards()
end

-- A gold [👑 VIP] tag in front of VIP players' chat messages.
local function setUpVipChatTag()
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		return
	end
	TextChatService.OnIncomingMessage = function(message: TextChatMessage)
		local properties = Instance.new("TextChatMessageProperties")
		local source = message.TextSource
		local sender = if source then Players:GetPlayerByUserId(source.UserId) else nil
		if sender and sender:GetAttribute("Pass_VIP") == true then
			properties.PrefixText = `<font color="#FFC83C">[👑 VIP]</font> {message.PrefixText}`
		end
		return properties
	end
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
				refreshCards()
			end
			refreshHudBoosts()
			task.wait(1)
		end
	end)
	player:GetAttributeChangedSignal("DailyGiftAt"):Connect(refreshGift)
	player.AttributeChanged:Connect(function(name: string)
		if string.sub(name, 1, 5) == "Pass_" or string.sub(name, 1, 5) == "Boost" then
			refreshCards()
			refreshHudBoosts()
		end
	end)
	Net.event(Net.Names.PurchaseThanks).OnClientEvent:Connect(onPurchaseThanks)
	setUpVipChatTag()
	refreshCards()
end

return ShopController
