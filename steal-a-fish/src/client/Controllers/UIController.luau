--!strict
--[[
	UIController
	============
	The always-visible UI:
	  - The Speed (👟) and Money (💵) numbers of the HUD (Ui/Hud).
	  - Notifications near the top of the screen, colored by kind (info,
	    success, warning, danger, epic, purchase), with a sound for some kinds.
	  - A green "+$X" popup and coin sound when you collect money.

	Everything scales with the screen size (see Ui/Kit).

	Public interface (other client code can call it):
		UIController.Notify(text, kind?)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local Hud = require(script.Parent.Parent.Ui.Hud)
local Kit = require(script.Parent.Parent.Ui.Kit)
local Sounds = require(script.Parent.Parent.Ui.Sounds)

local UIController = {}
UIController.Name = "UIController"

local MAX_VISIBLE = 4 -- older messages are removed when there are more
local SHOW_TIME = 3.5 -- seconds before a message fades out

-- Background color and sound for each notification kind.
local KINDS: { [string]: { Color: Color3, Sound: string? } } = {
	info = { Color = Color3.fromRGB(30, 60, 110) },
	success = { Color = Color3.fromRGB(30, 120, 70) },
	warning = { Color = Color3.fromRGB(170, 120, 20), Sound = "Warning" },
	danger = { Color = Color3.fromRGB(170, 40, 40) },
	epic = { Color = Color3.fromRGB(120, 50, 180) },
	purchase = { Color = Color3.fromRGB(190, 140, 20), Sound = "Purchase" },
}

local player = Players.LocalPlayer

local notificationList: Frame
local popupLayer: Frame

---------------------------------------------------------------------------
-- Stats
---------------------------------------------------------------------------

local function buildPopupLayer()
	local gui = Kit.screenGui("Popups", 12)
	popupLayer = Instance.new("Frame")
	popupLayer.Size = UDim2.fromScale(1, 1)
	popupLayer.BackgroundTransparency = 1
	popupLayer.Parent = gui
end

local function number(value: unknown): number
	return if typeof(value) == "number" then value else 0
end

local function refreshStats()
	Hud.SpeedLabel.Text = Format.short(number(player:GetAttribute(Constants.Attributes.SpeedStat)))
	Hud.MoneyLabel.Text = `${Format.short(number(player:GetAttribute(Constants.Attributes.Money)))}`
end

-- A green "+$X" that pops up next to the stats panel and floats away.
local function moneyPopup(amount: number)
	Sounds.play("Coins")
	local moneyLabel = Hud.MoneyLabel
	local anchor = moneyLabel.AbsolutePosition + Vector2.new(moneyLabel.TextBounds.X + 16, moneyLabel.AbsoluteSize.Y * 0.5)

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.fromOffset(anchor.X, anchor.Y)
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

---------------------------------------------------------------------------
-- Notifications
---------------------------------------------------------------------------

local function buildNotifications()
	local gui = Kit.screenGui("Notifications", 10)
	notificationList = Instance.new("Frame")
	notificationList.Name = "List"
	notificationList.AnchorPoint = Vector2.new(0.5, 0)
	notificationList.Position = UDim2.new(0.5, 0, 0, 150) -- below the zone name banner
	notificationList.Size = UDim2.fromOffset(520, 220)
	notificationList.BackgroundTransparency = 1
	notificationList.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = notificationList
	Kit.autoScale(notificationList, Vector2.new(520, 220))
end

local order = 0

function UIController.Notify(text: string, kind: string?)
	local style = KINDS[kind or "info"] or KINDS.info
	if style.Sound then
		Sounds.play(style.Sound)
	end
	order += 1

	local label = Instance.new("TextLabel")
	label.LayoutOrder = order
	label.Size = UDim2.new(1, 0, 0, 38)
	label.BackgroundColor3 = style.Color
	label.BackgroundTransparency = 0.1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = text
	label.Parent = notificationList
	Kit.corner(label, 10)
	Kit.stroke(label, style.Color:Lerp(Color3.new(1, 1, 1), 0.4), 2)
	local sizeLimit = Instance.new("UITextSizeConstraint")
	sizeLimit.MaxTextSize = 26
	sizeLimit.Parent = label
	local padding = Instance.new("UIPadding")
	padding.PaddingLeft = UDim.new(0, 12)
	padding.PaddingRight = UDim.new(0, 12)
	padding.PaddingTop = UDim.new(0, 4)
	padding.PaddingBottom = UDim.new(0, 4)
	padding.Parent = label

	-- Slide in with a small pop.
	local scale = Instance.new("UIScale")
	scale.Scale = 0.6
	scale.Parent = label
	TweenService:Create(scale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	-- Too many messages? Remove the oldest.
	local labels = {}
	for _, child in notificationList:GetChildren() do
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

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function UIController.Init()
	buildNotifications()
	buildPopupLayer()
end

function UIController.Start()
	for _, name in { Constants.Attributes.SpeedStat, Constants.Attributes.Money } do
		player:GetAttributeChangedSignal(name):Connect(refreshStats)
	end
	refreshStats()

	Net.event(Net.Names.MoneyCollected).OnClientEvent:Connect(function(amount: unknown)
		if typeof(amount) == "number" then
			moneyPopup(amount)
		end
	end)

	Net.event(Net.Names.Notify).OnClientEvent:Connect(function(message: unknown, kind: unknown)
		-- Even messages from the server get a type check before we use them.
		if typeof(message) == "string" then
			UIController.Notify(message, if typeof(kind) == "string" then kind else nil)
			if Config.Debug then
				print(`[{Config.GameName}] Notification: {message}`)
			end
		end
	end)
end

return UIController
