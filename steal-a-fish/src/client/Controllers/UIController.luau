--!strict
--[[
	UIController
	============
	Builds and updates the on-screen UI. The full HUD and windows come in the
	UI & polish milestone. For now:
	  - notifications from the server near the top of the screen
	    ("You stole a Rare Egg!")
	  - a small HUD in the top-left corner with your Speed stat and WalkSpeed

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
local walkSpeedLabel: TextLabel

-- HUD panel in the top-left (below Roblox's own buttons).
local function buildHud()
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "Hud"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local panel = Instance.new("Frame")
	panel.Name = "SpeedPanel"
	panel.Position = UDim2.fromOffset(16, 64)
	panel.Size = UDim2.fromOffset(210, 68)
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

	speedLabel = Instance.new("TextLabel")
	speedLabel.Name = "SpeedStat"
	speedLabel.Position = UDim2.fromOffset(10, 4)
	speedLabel.Size = UDim2.new(1, -20, 0, 36)
	speedLabel.BackgroundTransparency = 1
	speedLabel.Font = Enum.Font.FredokaOne
	speedLabel.TextScaled = true
	speedLabel.TextXAlignment = Enum.TextXAlignment.Left
	speedLabel.TextColor3 = Color3.fromRGB(255, 230, 60)
	speedLabel.Parent = panel

	walkSpeedLabel = Instance.new("TextLabel")
	walkSpeedLabel.Name = "WalkSpeed"
	walkSpeedLabel.Position = UDim2.fromOffset(10, 40)
	walkSpeedLabel.Size = UDim2.new(1, -20, 0, 22)
	walkSpeedLabel.BackgroundTransparency = 1
	walkSpeedLabel.Font = Enum.Font.FredokaOne
	walkSpeedLabel.TextScaled = true
	walkSpeedLabel.TextXAlignment = Enum.TextXAlignment.Left
	walkSpeedLabel.TextColor3 = Color3.fromRGB(200, 220, 255)
	walkSpeedLabel.Parent = panel
end

local function refreshHud()
	local player = Players.LocalPlayer
	local stat = player:GetAttribute(Constants.Attributes.SpeedStat)
	local walkSpeed = player:GetAttribute(Constants.Attributes.WalkSpeed)
	speedLabel.Text = `⚡ {Format.short(if typeof(stat) == "number" then stat else 0)} Speed`
	walkSpeedLabel.Text =
		`🏃 Walk speed {Format.decimal(if typeof(walkSpeed) == "number" then walkSpeed else Config.Speed.BaseWalkSpeed, 1)}`
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
	player:GetAttributeChangedSignal(Constants.Attributes.WalkSpeed):Connect(refreshHud)
	refreshHud()

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
