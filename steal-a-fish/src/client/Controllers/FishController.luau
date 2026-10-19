--!strict
--[[
	FishController
	==============
	The 🐟 Fish panel on the right side of the screen:
	  - Top: "Pads 5/8 used" and the next plot upgrade with its price (with a
	    button; you can also use the "Upgrade Plot" board in front of your plot).
	  - A list of all your fish: picture, name in its rarity color, zone,
	    level and $/s, with Upgrade and Sell buttons. Sell needs a second
	    click ("Sure?") to avoid accidents.
	The list is read from your plot (the server puts the details on each
	fish as attributes). Buttons only ASK the server ("PetAction",
	"BuyUpgrade"); the server checks ownership and money.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Fish = require(ReplicatedStorage.Shared.Fish)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local FishPicture = require(script.Parent.Parent.Ui.FishPicture)
local Hud = require(script.Parent.Parent.Ui.Hud)
local Kit = require(script.Parent.Parent.Ui.Kit)

local FishController = {}
FishController.Name = "FishController"

local REFRESH_INTERVAL = 0.5
local ROW_HEIGHT = 96

type Entry = {
	Pad: number,
	Rarity: string,
	Zone: number,
	Name: string,
	Level: number,
	BaseIncome: number,
}

local player = Players.LocalPlayer
local window: Kit.Window
local padsText: TextLabel
local nextPadText: TextLabel
local unlockButton: TextButton
local list: ScrollingFrame
local lastSignature = ""
local confirmSellPad: number? = nil
-- Fish pictures are reused between redraws (building them takes a moment).
local pictures: { [string]: ViewportFrame } = {}

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

local function attributeNumber(name: string, default: number): number
	local value = player:GetAttribute(name)
	return if typeof(value) == "number" then value else default
end

local function zoneName(zoneIndex: number): string
	local zone = Config.Zones[zoneIndex]
	return if zone then zone.Name else "?"
end

-- Every fish on my pads, best income first. Also counts the used pads.
local function collect(plot: Model): ({ Entry }, number)
	local entries: { Entry } = {}
	local used = 0
	for _, child in plot:GetChildren() do
		local pad = child:GetAttribute("PadIndex")
		if typeof(pad) ~= "number" then
			continue
		end
		if CollectionService:HasTag(child, Constants.Tags.HatchingEgg) then
			used += 1
		elseif CollectionService:HasTag(child, Constants.Tags.PetModel) then
			used += 1
			table.insert(entries, {
				Pad = pad,
				Rarity = attr(child, "Rarity", "Common"),
				Zone = attr(child, Constants.Attributes.Zone, 0),
				Name = attr(child, Constants.Attributes.PetName, child.Name),
				Level = attr(child, Constants.Attributes.Level, 1),
				BaseIncome = attr(child, Constants.Attributes.BaseIncome, 0),
			})
		end
	end
	table.sort(entries, function(a, b)
		local incomeA = Config.PetIncome(a.BaseIncome, a.Level)
		local incomeB = Config.PetIncome(b.BaseIncome, b.Level)
		if incomeA ~= incomeB then
			return incomeA > incomeB
		end
		return a.Pad < b.Pad
	end)
	return entries, used
end

local refresh: () -> ()

local function pictureFor(entry: Entry): ViewportFrame?
	local key = `{entry.Pad}:{entry.Name}`
	local picture = pictures[key]
	if picture then
		return picture
	end
	local fish = Fish.byName(entry.Name)
	if not fish then
		return nil
	end
	local holder = Instance.new("Folder") -- temporary parent
	local created = FishPicture.create(holder, fish, UDim2.fromOffset(80, 80), UDim2.fromOffset(8, 8))
	pictures[key] = created
	return created
end

local function buildRow(entry: Entry, order: number, money: number)
	local color = Rarity.color(entry.Rarity)
	local row = Instance.new("Frame")
	row.LayoutOrder = order
	row.Size = UDim2.new(1, -12, 0, ROW_HEIGHT)
	row.BackgroundColor3 = Kit.Colors.Card
	row.Parent = list
	Kit.corner(row, 12)
	Kit.stroke(row)

	local pictureBack = Instance.new("Frame")
	pictureBack.Size = UDim2.fromOffset(80, 80)
	pictureBack.Position = UDim2.fromOffset(8, 8)
	pictureBack.BackgroundColor3 = color
	pictureBack.Parent = row
	Kit.corner(pictureBack, 10)
	Kit.stroke(pictureBack)
	local picture = pictureFor(entry)
	if picture then
		picture.Position = UDim2.fromOffset(8, 8)
		picture.ZIndex = 2
		picture.Parent = row
	end

	Kit.label(row, entry.Name, UDim2.new(1, -210, 0, 28), UDim2.fromOffset(98, 8), color, 2)
	local income = Config.PetIncome(entry.BaseIncome, entry.Level)
	Kit.label(row, `${Format.short(income)}/s  •  {zoneName(entry.Zone)}`, UDim2.new(1, -210, 0, 26), UDim2.fromOffset(98, 38), Color3.fromRGB(120, 255, 100), 2)
	local levelText = if entry.Level >= Config.Upgrades.PetLevel.MaxLevel
		then `{entry.Rarity} • Lv {entry.Level} (MAX)`
		else `Lv {entry.Level} → {entry.Level + 1}: ${Format.short(income)}/s → ${Format.short(Config.PetIncome(entry.BaseIncome, entry.Level + 1))}/s`
	Kit.label(row, levelText, UDim2.new(1, -210, 0, 20), UDim2.fromOffset(98, 68), Kit.Colors.SubText)

	-- Upgrade button
	local upgrade: TextButton
	if entry.Level >= Config.Upgrades.PetLevel.MaxLevel then
		upgrade = Kit.button(row, "MAX", Kit.Colors.Gold, UDim2.fromOffset(100, 40), UDim2.new(1, -108, 0, 6))
	else
		local price = Config.PetUpgradePrice(entry.BaseIncome, entry.Level)
		upgrade = Kit.button(
			row,
			`⬆ ${Format.short(price)}`,
			if money >= price then Kit.Colors.Green else Kit.Colors.Grey,
			UDim2.fromOffset(100, 40),
			UDim2.new(1, -108, 0, 6)
		)
		upgrade.Activated:Connect(function()
			Net.event(Net.Names.PetAction):FireServer(entry.Pad, "Upgrade")
		end)
	end

	-- Sell button: first click asks "Sure?", second click sells.
	local value = Config.PetSellValue(entry.BaseIncome, entry.Level)
	local confirming = confirmSellPad == entry.Pad
	local sell = Kit.button(row, if confirming then "Sure?" else `Sell ${Format.short(value)}`, Kit.Colors.Red, UDim2.fromOffset(100, 40), UDim2.new(1, -108, 0, 50))
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
	local entries: { Entry } = {}
	local used = 0
	if plot then
		entries, used = collect(plot)
	end
	local money = attributeNumber(Constants.Attributes.Money, 0)

	-- Pads summary and the next plot upgrade.
	local unlocked = attributeNumber(Constants.Attributes.PadsUnlocked, Config.Plots.StartingPads)
	local level = attributeNumber("PlotLevel", 0)
	padsText.Text = `Pads {used}/{unlocked} used`
	local price = Config.NextPlotPrice(level)
	if not price then
		nextPadText.Text = "Plot is MAX level!"
		unlockButton.Visible = false
	else
		local what = if level + 1 == Config.Upgrades.SecondFloorLevel then "2nd floor" else "+1 pad"
		nextPadText.Text = `Plot Lv {level + 1} ({what}): ${Format.short(price)}`
		unlockButton.Visible = true
		Kit.setColor(unlockButton, if money >= price then Kit.Colors.Green else Kit.Colors.Grey)
	end

	-- Only rebuild the rows when something visible changed.
	local parts = { tostring(confirmSellPad) }
	for _, entry in entries do
		local affordable = money >= Config.PetUpgradePrice(entry.BaseIncome, entry.Level)
		table.insert(parts, `{entry.Pad}:{entry.Name}:{entry.Level}:{affordable}`)
	end
	local signature = table.concat(parts, "|")
	if signature == lastSignature then
		return
	end
	lastSignature = signature

	-- Keep the pictures, destroy the rest.
	local keep: { [string]: boolean } = {}
	for _, entry in entries do
		keep[`{entry.Pad}:{entry.Name}`] = true
	end
	for key, picture in pictures do
		if keep[key] then
			picture.Parent = nil
		else
			picture:Destroy()
			pictures[key] = nil
		end
	end
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	if #entries == 0 then
		local empty = Kit.label(list, "No fish yet! Hatch an egg on a pad 🥚", UDim2.new(1, -12, 0, 40), UDim2.new(), Kit.Colors.SubText)
		empty.TextXAlignment = Enum.TextXAlignment.Center
		return
	end
	for index, entry in entries do
		buildRow(entry, index, money)
	end
end

function FishController.Init()
	window = Kit.window("🐟 My Fish", Vector2.new(470, 560), { Color = Kit.Colors.Orange, Side = "Right" })

	local top = Instance.new("Frame")
	top.Size = UDim2.new(1, 0, 0, 74)
	top.BackgroundColor3 = Kit.Colors.Card
	top.Parent = window.Content
	Kit.corner(top, 12)
	Kit.stroke(top)
	padsText = Kit.label(top, "", UDim2.new(1, -150, 0, 32), UDim2.fromOffset(12, 6), Kit.Colors.Text, 3)
	nextPadText = Kit.label(top, "", UDim2.new(1, -150, 0, 26), UDim2.fromOffset(12, 40), Color3.fromRGB(255, 230, 90), 2)
	unlockButton = Kit.button(top, "⬆ Plot", Kit.Colors.Green, UDim2.fromOffset(124, 52), UDim2.new(1, -134, 0, 11))
	unlockButton.Activated:Connect(function()
		Net.event(Net.Names.BuyUpgrade):FireServer("Plot")
	end)

	list = Kit.scroll(window.Content, UDim2.new(1, 0, 1, -86), UDim2.fromOffset(0, 86))
	Kit.list(list, 8)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingLeft = UDim.new(0, 4)
	padding.Parent = list

	window.Opened.Event:Connect(function()
		lastSignature = ""
		refresh()
	end)
	Hud.Fish.Activated:Connect(function()
		window.Toggle()
	end)
end

function FishController.Start()
	task.spawn(function()
		while true do
			task.wait(REFRESH_INTERVAL)
			refresh()
		end
	end)
end

return FishController
