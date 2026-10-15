--!strict
--[[
	UIController
	============
	Builds and updates the on-screen UI. The full HUD and windows come in
	Milestone 7. For now it shows notifications from the server as small
	messages near the top of the screen ("You stole a Rare Egg!").

	Public interface (other client code can call it):
		UIController.Notify(text)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ReplicatedStorage.Shared.Net)

local UIController = {}
UIController.Name = "UIController"

local MAX_VISIBLE = 4 -- older messages are removed when there are more
local SHOW_TIME = 3 -- seconds before a message fades out

local container: Frame

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
end

function UIController.Start()
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
