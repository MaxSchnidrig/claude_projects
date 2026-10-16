--!strict
--[[
	EggsController
	==============
	The 🥚 Eggs window: every egg you have.
	  - On your pads: rarity, the zone it came from, and the time left until
	    it hatches (or "READY! Hold E to hatch").
	  - In your hotbar: the eggs you carried home but haven't placed yet.
	It only shows information (read from your plot and your backpack).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local Hud = require(script.Parent.Parent.Ui.Hud)
local Kit = require(script.Parent.Parent.Ui.Kit)

local EggsController = {}
EggsController.Name = "EggsController"

local REFRESH_INTERVAL = 0.5

type EggRow = { Rarity: string, Zone: number, Text: string, Ready: boolean }

local player = Players.LocalPlayer
local window: Kit.Window
local list: ScrollingFrame
local lastSignature = ""

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

local function zoneName(zoneIndex: number): string
	local zone = Config.Zones[zoneIndex]
	return if zone then zone.Name else "?"
end

local function formatTime(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	if seconds >= 3600 then
		return string.format("%d:%02d:%02d", seconds // 3600, (seconds // 60) % 60, seconds % 60)
	end
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function numberAttribute(instance: Instance, name: string): number
	local value = instance:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

local function padEggs(): { EggRow }
	local rows: { EggRow } = {}
	local plot = myPlot()
	if not plot then
		return rows
	end
	local now = Workspace:GetServerTimeNow()
	for _, child in plot:GetChildren() do
		if CollectionService:HasTag(child, Constants.Tags.HatchingEgg) then
			local rarity = child:GetAttribute("Rarity")
			local ready = child:GetAttribute(Constants.Attributes.Ready) == true
			local left = numberAttribute(child, Constants.Attributes.HatchEndsAt) - now
			table.insert(rows, {
				Rarity = if typeof(rarity) == "string" then rarity else "Common",
				Zone = numberAttribute(child, Constants.Attributes.Zone),
				Text = if ready then "✨ READY! Hold E to hatch" elseif left > 0 then `⏳ {formatTime(left)}` else "Almost ready...",
				Ready = ready,
			})
		end
	end
	table.sort(rows, function(a, b)
		return Rarity.rank(a.Rarity) > Rarity.rank(b.Rarity)
	end)
	return rows
end

local function hotbarEggs(): { EggRow }
	local rows: { EggRow } = {}
	local containers: { Instance } = {}
	local backpack = player:FindFirstChildOfClass("Backpack")
	if backpack then
		table.insert(containers, backpack)
	end
	if player.Character then
		table.insert(containers, player.Character)
	end
	for _, container in containers do
		for _, item in container:GetChildren() do
			local rarity = item:GetAttribute(Constants.Attributes.EggRarity)
			if item:IsA("Tool") and typeof(rarity) == "string" then
				table.insert(rows, {
					Rarity = rarity,
					Zone = numberAttribute(item, Constants.Attributes.EggZone),
					Text = "🎒 Place it on a free pad (press E)",
					Ready = false,
				})
			end
		end
	end
	return rows
end

local function header(text: string, order: number)
	local label = Kit.label(list, text, UDim2.new(1, -12, 0, 32), UDim2.new(), Kit.Colors.Text, 3)
	label.LayoutOrder = order
end

local function row(entry: EggRow, order: number)
	local color = Rarity.color(entry.Rarity)
	local frame = Instance.new("Frame")
	frame.LayoutOrder = order
	frame.Size = UDim2.new(1, -12, 0, 64)
	frame.BackgroundColor3 = Kit.Colors.Card
	frame.Parent = list
	Kit.corner(frame, 10)
	Kit.stroke(frame, if entry.Ready then Kit.Colors.Green else Kit.Colors.Outline, if entry.Ready then 4 else 3)

	local icon = Instance.new("Frame")
	icon.Size = UDim2.fromOffset(50, 50)
	icon.Position = UDim2.fromOffset(7, 7)
	icon.BackgroundColor3 = color
	icon.Parent = frame
	Kit.corner(icon, 10)
	Kit.stroke(icon)
	local emoji = Kit.label(icon, "🥚", UDim2.new(1, -8, 1, -8), UDim2.fromOffset(4, 4))
	emoji.TextXAlignment = Enum.TextXAlignment.Center

	Kit.label(frame, `{entry.Rarity} Egg`, UDim2.new(0.5, -70, 0, 28), UDim2.fromOffset(66, 6), color, 2)
	Kit.label(frame, `from {zoneName(entry.Zone)}`, UDim2.new(0.5, -70, 0, 22), UDim2.fromOffset(66, 36), Kit.Colors.SubText)
	local status = Kit.label(frame, entry.Text, UDim2.new(0.5, -10, 0, 30), UDim2.new(0.5, 0, 0.5, -15), if entry.Ready then Kit.Colors.Green else Kit.Colors.Text, 2)
	status.TextXAlignment = Enum.TextXAlignment.Right
end

local function refresh()
	if not window.IsOpen() then
		return
	end
	local pads = padEggs()
	local hotbar = hotbarEggs()
	local parts = {}
	for _, entry in pads do
		table.insert(parts, entry.Rarity .. entry.Text)
	end
	table.insert(parts, tostring(#hotbar))
	local signature = table.concat(parts, "|")
	if signature == lastSignature then
		return
	end
	lastSignature = signature

	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end
	header(`On your pads ({#pads})`, nextOrder())
	if #pads == 0 then
		local empty = Kit.label(list, "No eggs on your pads.", UDim2.new(1, -12, 0, 26), UDim2.new(), Kit.Colors.SubText)
		empty.LayoutOrder = nextOrder()
	end
	for _, entry in pads do
		row(entry, nextOrder())
	end
	header(`In your hotbar ({#hotbar}/{Config.Eggs.MaxInventory})`, nextOrder())
	if #hotbar == 0 then
		local empty = Kit.label(list, "Steal eggs in the Danger Zone!", UDim2.new(1, -12, 0, 26), UDim2.new(), Kit.Colors.SubText)
		empty.LayoutOrder = nextOrder()
	end
	for _, entry in hotbar do
		row(entry, nextOrder())
	end
end

function EggsController.Init()
	window = Kit.window("🥚 My Eggs", Vector2.new(560, 480), { Color = Kit.Colors.Red })
	list = Kit.scroll(window.Content, UDim2.fromScale(1, 1), UDim2.new())
	Kit.list(list, 8)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingLeft = UDim.new(0, 4)
	padding.Parent = list
	window.Opened.Event:Connect(function()
		lastSignature = ""
		refresh()
	end)
	Hud.Eggs.Activated:Connect(function()
		window.Toggle()
	end)
end

function EggsController.Start()
	task.spawn(function()
		while true do
			task.wait(REFRESH_INTERVAL)
			refresh()
		end
	end)
end

return EggsController
