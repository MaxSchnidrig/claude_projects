--!strict
--[[
	UIController
	============
	Builds and updates the on-screen UI. The full HUD and windows come in the
	UI & polish milestone. For now:
	  - notifications from the server near the top of the screen
	    ("You stole a Rare Egg!")
	  - a small HUD in the top-left corner with your Speed stat, money and income
	  - a "+$X" popup when you collect money

	Public interface (other client code can call it):
		UIController.Notify(text)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)

local UIController = {}
UIController.Name = "UIController"

local MAX_VISIBLE = 4 -- older messages are removed when there are more
local SHOW_TIME = 3 -- seconds before a message fades out

local container: Frame
local speedLabel: TextLabel
local moneyLabel: TextLabel
local incomeLabel: TextLabel
local popupLayer: Frame

-- HUD panel in the top-left (below Roblox's own buttons).
local function buildHud()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "Hud"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Name = "StatsPanel"
	panel.Position = UDim2.fromOffset(16, 64)
	panel.Size = UDim2.fromOffset(210, 112)
	panel.BackgroundColor3 = Color3.fromRGB(20, 30, 50)
	panel.BackgroundTransparency = 0.2
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(90, 200, 255)
	stroke.Thickness = 2
	stroke.Parent = panel

	local function row(name: string, y: number, height: number, color: Color3): TextLabel
		local label = Instance.new("TextLabel")
		label.Name = name
		label.Position = UDim2.fromOffset(10, y)
		label.Size = UDim2.new(1, -20, 0, height)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextColor3 = color
		label.Parent = panel
		return label
	end
	speedLabel = row("SpeedStat", 4, 34, Color3.fromRGB(255, 230, 60))
	moneyLabel = row("Money", 40, 34, Color3.fromRGB(120, 255, 140))
	incomeLabel = row("Income", 76, 26, Color3.fromRGB(200, 240, 210))

	popupLayer = Instance.new("Frame")
	popupLayer.Name = "MoneyPopups"
	popupLayer.Size = UDim2.fromScale(1, 1)
	popupLayer.BackgroundTransparency = 1
	popupLayer.Parent = gui
end

local function number(value: unknown): number
	return if typeof(value) == "number" then value else 0
end

local function refreshHud()
	local player = Players.LocalPlayer
	speedLabel.Text = `⚡ {Format.short(number(player:GetAttribute(Constants.Attributes.SpeedStat)))} Speed`
	moneyLabel.Text = `💰 ${Format.short(number(player:GetAttribute(Constants.Attributes.Money)))}`
	incomeLabel.Text = `+${Format.short(number(player:GetAttribute(Constants.Attributes.Income)))}/s`
end

-- A green "+$X" that pops up near the HUD and floats away.
local function moneyPopup(amount: number)
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.fromOffset(236, 120)
	label.Size = UDim2.fromOffset(180, 44)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextColor3 = Color3.fromRGB(120, 255, 140)
	label.Text = `+${Format.short(amount)}`
	label.Parent = popupLayer
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(20, 50, 30)
	stroke.Parent = label
	local scale = Instance.new("UIScale")
	scale.Scale = 0.3
	scale.Parent = label

	TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	task.delay(0.4, function()
		local info = TweenInfo.new(0.8)
		TweenService:Create(label, info, {
			Position = label.Position - UDim2.fromOffset(0, 50),
			TextTransparency = 1,
		}):Play()
		local fade = TweenService:Create(stroke, info, { Transparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		label:Destroy()
	end)
end

local function buildGui()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "Notifications"
	gui.ResetOnSpawn = false -- keep it when the character respawns
	gui.DisplayOrder = 10
	gui.Parent = playerGui

	container = Instance.new("Frame")
	container.Name = "Container"
	container.AnchorPoint = Vector2.new(0.5, 0)
	container.Position = UDim2.new(0.5, 0, 0, 70)
	container.Size = UDim2.new(0.6, 0, 0, 200)
	container.BackgroundTransparency = 1
	container.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = container
end

local order = 0

function UIController.Notify(text: string)
	order += 1

	local label = Instance.new("TextLabel")
	label.LayoutOrder = order
	label.Size = UDim2.new(1, 0, 0, 36)
	label.BackgroundColor3 = Color3.fromRGB(20, 30, 50)
	label.BackgroundTransparency = 0.25
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = text
	label.Parent = container

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = label
	local sizeLimit = Instance.new("UITextSizeConstraint")
	sizeLimit.MaxTextSize = 26
	sizeLimit.Parent = label
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = label

	-- Too many messages? Remove the oldest.
	local labels = {}
	for _, child in container:GetChildren() do
		if child:IsA("TextLabel") then
			table.insert(labels, child)
		end
	end
	table.sort(labels, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = 1, #labels - MAX_VISIBLE do
		labels[i]:Destroy()
	end

	task.delay(SHOW_TIME, function()
		if label.Parent then
			local fade = TweenService:Create(label, TweenInfo.new(0.4), {
				TextTransparency = 1,
				BackgroundTransparency = 1,
			})
			fade:Play()
			fade.Completed:Wait()
			label:Destroy()
		end
	end)
end

function UIController.Init()
	buildGui()
	buildHud()
end

function UIController.Start()
	local player = Players.LocalPlayer
	player:GetAttributeChangedSignal(Constants.Attributes.SpeedStat):Connect(refreshHud)
	player:GetAttributeChangedSignal(Constants.Attributes.Money):Connect(refreshHud)
	player:GetAttributeChangedSignal(Constants.Attributes.Income):Connect(refreshHud)
	refreshHud()

	Net.event(Net.Names.MoneyCollected).OnClientEvent:Connect(function(amount: unknown)
		if typeof(amount) == "number" then
			moneyPopup(amount)
		end
	end)

	Net.event(Net.Names.Notify).OnClientEvent:Connect(function(message: unknown)
		-- Even messages from the server get a type check before we use them.
		if typeof(message) == "string" then
			UIController.Notify(message)
			if Config.Debug then
				print(`[{Config.GameName}] Notification: {message}`)
			end
		end
	end)
end

return UIController
