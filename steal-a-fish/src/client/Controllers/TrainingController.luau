--!strict
--[[
	TrainingController
	==================
	Everything you SEE while training on your treadmill. The server does the
	real work (locking you in place, adding Speed); this only shows it:
	  - plays a running animation on your character
	  - shows the hint "Press Space to stop" (or "Tap Jump to stop" on touch)
	  - pressing jump (Space or the mobile jump button) asks the server to let
	    you off
	  - shows a bouncy, colorful "+X Speed" popup for every gain
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Constants = require(ReplicatedStorage.Shared.Constants)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)

local TrainingController = {}
TrainingController.Name = "TrainingController"

local player = Players.LocalPlayer

-- Roblox's default run animations, used if the character has no Animate script.
local DEFAULT_RUN_R15 = "rbxassetid://913376220"
local DEFAULT_RUN_R6 = "rbxassetid://180426354"
local RUN_ANIMATION_SPEED = 1.4

local MAX_POPUPS = 12 -- never more than this many popups on screen at once
-- The server adds Speed once per second; the screen shows it as a fast
-- stream of small popups: STREAM_PARTS popups, STREAM_STEP seconds apart,
-- each with 1/STREAM_PARTS of the amount (the total stays the same).
local STREAM_PARTS = 10
local STREAM_STEP = 0.1
local POPUP_COLORS = {
	Color3.fromRGB(255, 230, 60),
	Color3.fromRGB(90, 255, 140),
	Color3.fromRGB(80, 210, 255),
	Color3.fromRGB(255, 120, 200),
	Color3.fromRGB(255, 160, 60),
	Color3.fromRGB(190, 130, 255),
}

local gui: ScreenGui
local hint: TextLabel
local popupLayer: Frame
local runTrack: AnimationTrack? = nil
local lastStopRequest = 0
local rng = Random.new()

local function isTraining(): boolean
	return player:GetAttribute(Constants.Attributes.Training) == true
end

---------------------------------------------------------------------------
-- Running animation
---------------------------------------------------------------------------

local function findRunAnimationId(character: Model, humanoid: Humanoid): string
	local animate = character:FindFirstChild("Animate")
	local run = animate and animate:FindFirstChild("run")
	local animation = run and run:FindFirstChildOfClass("Animation")
	if animation and animation.AnimationId ~= "" then
		return animation.AnimationId
	end
	return if humanoid.RigType == Enum.HumanoidRigType.R6 then DEFAULT_RUN_R6 else DEFAULT_RUN_R15
end

local function startRunAnimation()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (character and humanoid) then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = findRunAnimationId(character, humanoid)
	local track = animator:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	track:Play(0.15, 1, RUN_ANIMATION_SPEED)
	runTrack = track
end

local function stopRunAnimation()
	if runTrack then
		runTrack:Stop(0.2)
		runTrack = nil
	end
end

local function onTrainingChanged()
	if isTraining() then
		hint.Visible = true
		startRunAnimation()
	else
		hint.Visible = false
		stopRunAnimation()
	end
end

---------------------------------------------------------------------------
-- "+X Speed" popups
---------------------------------------------------------------------------

local visiblePopups: { TextLabel } = {}

local function showPopup(amount: number)
	-- Too many on screen? The oldest one makes room (so it never covers
	-- the screen or lags).
	while #visiblePopups >= MAX_POPUPS do
		local oldest = table.remove(visiblePopups, 1)
		if oldest then
			oldest:Destroy()
		end
	end

	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	-- A random spot in the middle area of the screen (not over the HUD).
	label.Position = UDim2.fromScale(rng:NextNumber(0.2, 0.8), rng:NextNumber(0.25, 0.65))
	label.Size = UDim2.fromOffset(120, 32)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	-- Small amounts keep one decimal (2.5), bigger ones are shortened (1.2K).
	local amountText = if amount < 10 and amount % 1 ~= 0 then string.format("%.1f", amount) else Format.short(amount)
	label.Text = `+{amountText} Speed`
	label.TextColor3 = POPUP_COLORS[rng:NextInteger(1, #POPUP_COLORS)]
	label.Rotation = rng:NextNumber(-12, 12)
	label.Parent = popupLayer
	table.insert(visiblePopups, label)

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(30, 30, 50)
	stroke.Parent = label

	local scale = Instance.new("UIScale")
	scale.Scale = 0.2
	scale.Parent = label

	-- 1) Pop in with a bounce.
	TweenService:Create(scale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()

	-- 2) Float up and fade out.
	task.delay(0.2, function()
		if label.Parent == nil then
			return -- already removed to make room
		end
		local info = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(label, info, {
			Position = label.Position - UDim2.fromOffset(0, 60),
			TextTransparency = 1,
		}):Play()
		local fade = TweenService:Create(stroke, info, { Transparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		local index = table.find(visiblePopups, label)
		if index then
			table.remove(visiblePopups, index)
		end
		label:Destroy()
	end)
end

-- Show one second's gain as a quick stream of small popups.
local function streamPopups(amount: number)
	local part = amount / STREAM_PARTS
	task.spawn(function()
		for _ = 1, STREAM_PARTS do
			showPopup(part)
			task.wait(STREAM_STEP)
		end
	end)
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------

local function buildGui()
	gui = Instance.new("ScreenGui")
	gui.Name = "Training"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 5
	gui.Parent = player:WaitForChild("PlayerGui")

	popupLayer = Instance.new("Frame")
	popupLayer.Name = "Popups"
	popupLayer.Size = UDim2.fromScale(1, 1)
	popupLayer.BackgroundTransparency = 1
	popupLayer.Parent = gui

	hint = Instance.new("TextLabel")
	hint.Name = "StopHint"
	hint.AnchorPoint = Vector2.new(0.5, 1)
	hint.Position = UDim2.new(0.5, 0, 1, -110)
	hint.Size = UDim2.fromOffset(260, 40)
	hint.BackgroundColor3 = Color3.fromRGB(20, 30, 50)
	hint.BackgroundTransparency = 0.25
	hint.TextColor3 = Color3.new(1, 1, 1)
	hint.Font = Enum.Font.FredokaOne
	hint.TextScaled = true
	local touchOnly = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	hint.Text = if touchOnly then "Tap Jump to stop" else "Press Space to stop"
	hint.Visible = false
	hint.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = hint
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	padding.Parent = hint
end

function TrainingController.Init()
	buildGui()
end

function TrainingController.Start()
	player:GetAttributeChangedSignal(Constants.Attributes.Training):Connect(onTrainingChanged)
	-- A new character needs the animation again if training is still on.
	player.CharacterAdded:Connect(function()
		runTrack = nil
		onTrainingChanged()
	end)
	onTrainingChanged()

	-- JumpRequest fires for Space AND for the mobile jump button.
	UserInputService.JumpRequest:Connect(function()
		local now = os.clock()
		if isTraining() and now - lastStopRequest > 0.3 then
			lastStopRequest = now
			Net.event(Net.Names.StopTraining):FireServer()
		end
	end)

	Net.event(Net.Names.SpeedGained).OnClientEvent:Connect(function(amount: unknown)
		if typeof(amount) == "number" then
			streamPopups(amount)
		end
	end)
end

return TrainingController
