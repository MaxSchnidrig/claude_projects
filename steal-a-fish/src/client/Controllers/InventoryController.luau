--!strict
--[[
	InventoryController
	===================
	The "🐟 Pets" window: everything on your pads in one list.
	  - Pets: name (in rarity color), rarity, level, income, with Upgrade and
	    Sell buttons. Sell needs a second click ("Sure?") to avoid accidents.
	  - Eggs: rarity and the time until they hatch.
	The list is read from your plot in the world (the server puts the details
	on each pet as attributes). Buttons only ASK the server ("PetAction"); the
	server checks ownership and money.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local Kit = require(script.Parent.Parent.Ui.Kit)

local InventoryController = {}
InventoryController.Name = "InventoryController"

local REFRESH_INTERVAL = 0.5
local ROW_HEIGHT = 70

type Entry = {
	Pad: number,
	Kind: string,
	Rarity: string,
	Name: string,
	Level: number,
	BaseIncome: number,
	HatchEndsAt: number,
}

local player = Players.LocalPlayer
local window: Kit.Window
local summary: TextLabel
local list: ScrollingFrame
local lastSignature = ""
local confirmSellPad: number? = nil

local function myPlot(): Model?
	local world = Workspace:FindFirstChild("World")
	local plots = world and world:FindFirstChild("Plots")
	if not plots then
		return nil
	end
	for _, plot in plots:GetChildren() do
		if plot:IsA("Model") and plot:GetAttribute("OwnerUserId") == player.UserId then
			return plot
		end
	end
	return nil
end

local function attr(instance: Instance, name: string, default: any): any
	local value = instance:GetAttribute(name)
	return if value == nil then default else value
end

-- Everything on my pads, pets first (best income first), then eggs.
local function collectEntries(plot: Model): { Entry }
	local entries: { Entry } = {}
	for _, child in plot:GetChildren() do
		local pad = child:GetAttribute("PadIndex")
		if typeof(pad) ~= "number" then
			continue
		end
		if CollectionService:HasTag(child, Constants.Tags.PetModel) then
			table.insert(entries, {
				Pad = pad,
				Kind = "Pet",
				Rarity = attr(child, "Rarity", "Common"),
				Name = attr(child, Constants.Attributes.PetName, child.Name),
				Level = attr(child, Constants.Attributes.Level, 1),
				BaseIncome = attr(child, Constants.Attributes.BaseIncome, 0),
				HatchEndsAt = 0,
			})
		elseif CollectionService:HasTag(child, Constants.Tags.HatchingEgg) then
			table.insert(entries, {
				Pad = pad,
				Kind = "Egg",
				Rarity = attr(child, "Rarity", "Common"),
				Name = `{attr(child, "Rarity", "Common")} Egg`,
				Level = 0,
				BaseIncome = 0,
				HatchEndsAt = attr(child, Constants.Attributes.HatchEndsAt, 0),
			})
		end
	end
	table.sort(entries, function(a, b)
		if a.Kind ~= b.Kind then
			return a.Kind == "Pet"
		end
		local incomeA = Config.PetIncome(a.BaseIncome, a.Level)
		local incomeB = Config.PetIncome(b.BaseIncome, b.Level)
		if incomeA ~= incomeB then
			return incomeA > incomeB
		end
		return a.Pad < b.Pad
	end)
	return entries
end

-- Defined further down; buildRow needs to call it.
local refresh: () -> ()

local function formatTime(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function buildRow(entry: Entry, order: number, money: number)
	local color = Rarity.color(entry.Rarity)
	local row = Instance.new("Frame")
	row.LayoutOrder = order
	row.Size = UDim2.new(1, -8, 0, ROW_HEIGHT)
	row.BackgroundColor3 = Kit.Colors.Card
	row.Parent = list
	Kit.corner(row, 10)

	local stripe = Instance.new("Frame")
	stripe.Size = UDim2.new(0, 8, 1, 0)
	stripe.BackgroundColor3 = color
	stripe.BorderSizePixel = 0
	stripe.Parent = row
	Kit.corner(stripe, 4)

	Kit.label(row, entry.Name, UDim2.new(0.5, -20, 0, 30), UDim2.fromOffset(18, 6), color)
	if entry.Kind == "Egg" then
		local left = entry.HatchEndsAt - Workspace:GetServerTimeNow()
		Kit.label(row, `🥚 Hatches in {formatTime(left)}`, UDim2.new(0.6, -20, 0, 24), UDim2.fromOffset(18, 38), Kit.Colors.SubText)
		return
	end

	local income = Config.PetIncome(entry.BaseIncome, entry.Level)
	Kit.label(
		row,
		`{entry.Rarity} • Lv {entry.Level} • ${Format.short(income)}/s`,
		UDim2.new(0.5, -20, 0, 24),
		UDim2.fromOffset(18, 38),
		Kit.Colors.SubText
	)

	-- Upgrade button
	local upgrade: TextButton
	if entry.Level >= Config.Upgrades.PetLevel.MaxLevel then
		upgrade = Kit.button(row, "MAX", Kit.Colors.Gold, UDim2.new(0.24, -6, 0, 48), UDim2.new(0.5, 0, 0.5, -24))
		upgrade.AutoButtonColor = false
	else
		local price = Config.PetUpgradePrice(entry.BaseIncome, entry.Level)
		upgrade = Kit.button(
			row,
			`⬆ ${Format.short(price)}`,
			if money >= price then Kit.Colors.Green else Kit.Colors.Grey,
			UDim2.new(0.24, -6, 0, 48),
			UDim2.new(0.5, 0, 0.5, -24)
		)
		upgrade.Activated:Connect(function()
			Net.event(Net.Names.PetAction):FireServer(entry.Pad, "Upgrade")
		end)
	end

	-- Sell button: first click asks "Sure?", second click sells.
	local value = Config.PetSellValue(entry.BaseIncome, entry.Level)
	local confirming = confirmSellPad == entry.Pad
	local sell = Kit.button(
		row,
		if confirming then "Sure?" else `Sell ${Format.short(value)}`,
		Kit.Colors.Red,
		UDim2.new(0.26, -10, 0, 48),
		UDim2.new(0.74, 0, 0.5, -24)
	)
	sell.Activated:Connect(function()
		if confirmSellPad == entry.Pad then
			confirmSellPad = nil
			Net.event(Net.Names.PetAction):FireServer(entry.Pad, "Sell")
		else
			confirmSellPad = entry.Pad
			lastSignature = "" -- redraw now to show "Sure?"
			refresh()
			task.delay(3, function()
				if confirmSellPad == entry.Pad then
					confirmSellPad = nil
					lastSignature = ""
					refresh()
				end
			end)
		end
	end)
end

function refresh()
	if not window.IsOpen() then
		return
	end
	local plot = myPlot()
	local entries: { Entry } = if plot then collectEntries(plot) else {}
	local money = player:GetAttribute(Constants.Attributes.Money)
	local moneyNumber = if typeof(money) == "number" then money else 0

	local pads = player:GetAttribute(Constants.Attributes.PadsUnlocked)
	local income = player:GetAttribute(Constants.Attributes.Income)
	summary.Text = `Pads used: {#entries}/{if typeof(pads) == "number" then pads else "?"}   •   Income: ${Format.short(
		if typeof(income) == "number" then income else 0
	)}/s`

	-- Only rebuild the rows when something visible changed.
	local parts = { tostring(confirmSellPad) }
	for _, entry in entries do
		local timeLeft = if entry.Kind == "Egg" then math.ceil(entry.HatchEndsAt - Workspace:GetServerTimeNow()) else 0
		local affordable = moneyNumber >= Config.PetUpgradePrice(entry.BaseIncome, math.max(entry.Level, 1))
		table.insert(parts, `{entry.Pad}:{entry.Kind}:{entry.Name}:{entry.Level}:{timeLeft}:{affordable}`)
	end
	local signature = table.concat(parts, "|")
	if signature == lastSignature then
		return
	end
	lastSignature = signature

	for _, child in list:GetChildren() do
		if child:IsA("Frame") or child:IsA("TextLabel") then
			child:Destroy()
		end
	end
	if #entries == 0 then
		local empty = Kit.label(list, "No pets yet! Steal an egg from the Danger Zone 🥚", UDim2.new(1, -8, 0, 40), UDim2.new(), Kit.Colors.SubText)
		empty.TextXAlignment = Enum.TextXAlignment.Center
		return
	end
	for index, entry in entries do
		buildRow(entry, index, moneyNumber)
	end
end

function InventoryController.Init()
	window = Kit.window("🐟 My Pets", Vector2.new(560, 440))

	summary = Kit.label(window.Content, "", UDim2.new(1, 0, 0, 26), UDim2.new(), Kit.Colors.SubText)

	list = Instance.new("ScrollingFrame")
	list.Position = UDim2.fromOffset(0, 36)
	list.Size = UDim2.new(1, 0, 1, -36)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 8
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = window.Content
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	local open = Kit.menuButton("🐟 Pets", Color3.fromRGB(60, 140, 230), 11)
	open.Activated:Connect(function()
		window.Toggle()
		lastSignature = ""
		refresh()
	end)
end

function InventoryController.Start()
	task.spawn(function()
		while true do
			task.wait(REFRESH_INTERVAL)
			refresh()
		end
	end)
end

return InventoryController
