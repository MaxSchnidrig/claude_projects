--!strict
--[[
	EffectsController
	=================
	Effects that happen to YOUR character:
	  - Picking up an egg: a sparkle burst in the egg's color and a sound.
	  - Caught by a shark: a big "🦈 CAUGHT!" on screen, a splash burst, a
	    sound and the knockback push.
	  - Reaching the safe zone with an egg: confetti, a sparkle burst, a
	    sound and a big green "SAFE!".

	Knockback: the server sends a velocity. Your own computer controls your
	character's physics, so the push has to be applied here. The velocity is
	checked and capped before use.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Net = require(ReplicatedStorage.Shared.Net)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local Effects = require(script.Parent.Parent.Ui.Effects)
local Kit = require(script.Parent.Parent.Ui.Kit)
local Sounds = require(script.Parent.Parent.Ui.Sounds)

local EffectsController = {}
EffectsController.Name = "EffectsController"

local MAX_KNOCKBACK_SPEED = 200 -- safety cap
local WATER_COLOR = Color3.fromRGB(90, 190, 255)

local player = Players.LocalPlayer
local splashGui: ScreenGui

local function getRoot(): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Big bouncy text in the middle of the screen.
local function splash(text: string, color: Color3, seconds: number?)
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.35)
	label.Size = UDim2.fromOffset(520, 110)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = color
	label.Text = text
	label.Rotation = -4
	label.Parent = splashGui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 5
	stroke.Color = Color3.fromRGB(30, 10, 10)
	stroke.Parent = label
	local scale = Kit.autoScale(label, Vector2.new(520, 110))
	local target = scale.Scale
	scale.Scale = target * 0.2
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = target }):Play()

	task.delay(seconds or Config.UI.CaughtSplashSeconds, function()
		local info = TweenInfo.new(0.3)
		TweenService:Create(label, info, { TextTransparency = 1 }):Play()
		local fade = TweenService:Create(stroke, info, { Transparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		label:Destroy()
	end)
end

local function onCaught(velocity: unknown)
	local root = getRoot()
	Sounds.play("Caught")
	splash("🦈 CAUGHT!", Color3.fromRGB(255, 80, 80))
	if root then
		Effects.burst(root.Position, WATER_COLOR, 40)
	end

	if typeof(velocity) ~= "Vector3" or velocity.Magnitude > MAX_KNOCKBACK_SPEED then
		return
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if root and humanoid then
		-- Jump state first, so walking doesn't immediately cancel the push.
		humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		root.AssemblyLinearVelocity = velocity
	end
end

local function onCarryingChanged()
	local rarity = player:GetAttribute(Constants.Attributes.CarryingEgg)
	if typeof(rarity) ~= "string" then
		return -- egg delivered or lost
	end
	Sounds.play("Pickup")
	local root = getRoot()
	if root then
		Effects.burst(root.Position + Vector3.new(0, 4, 0), Rarity.color(rarity), 15 + Rarity.rank(rarity) * 4)
	end
end

local function onEggSaved(rarity: unknown)
	Sounds.play("Safe")
	splash("✅ SAFE!", Color3.fromRGB(110, 255, 110), Config.UI.SafeSplashSeconds)
	local root = getRoot()
	if root then
		Effects.confetti(root.Position + Vector3.new(0, 5, 0), 70)
		local color = if typeof(rarity) == "string" then Rarity.color(rarity) else Color3.new(1, 1, 1)
		Effects.burst(root.Position + Vector3.new(0, 3, 0), color, 30)
	end
end

function EffectsController.Init()
	splashGui = Kit.screenGui("Splash", 30)
end

function EffectsController.Start()
	Net.event(Net.Names.Knockback).OnClientEvent:Connect(onCaught)
	Net.event(Net.Names.EggSaved).OnClientEvent:Connect(onEggSaved)
	player:GetAttributeChangedSignal(Constants.Attributes.CarryingEgg):Connect(onCarryingChanged)
end

return EffectsController
