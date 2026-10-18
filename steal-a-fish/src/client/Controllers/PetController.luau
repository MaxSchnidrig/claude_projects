--!strict
--[[
	PetController
	=============
	Egg and pet visuals on your own screen (the server decides everything):
	  - Countdown under every hatching egg ("0:35"), from its HatchEndsAt time.
	  - Eggs wiggle in their last seconds; READY eggs bounce and say
	    "READY! Hold E to hatch".
	  - Pets gently bob up and down above their pads and slowly turn.
	  - A colorful burst where an egg hatches (everyone nearby sees it).
	  - A "You hatched ...!" card for your own hatches.

	To save work, things far from the camera are not animated.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Format = require(ReplicatedStorage.Shared.Format)
local Net = require(ReplicatedStorage.Shared.Net)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local Effects = require(script.Parent.Parent.Ui.Effects)
local Sounds = require(script.Parent.Parent.Ui.Sounds)

local PetController = {}
PetController.Name = "PetController"

local ANIMATE_DISTANCE = 120
local WIGGLE_SECONDS = 3 -- eggs start wiggling this long before they hatch
local BOB_HEIGHT = 0.35
local BOB_SPEED = 2
local TURN_SPEED = 0.45 -- slow turning
local TURN_ANGLE = math.rad(22)

-- The position the server gave each egg/pet, so our local animation always
-- starts from the right place. Weak keys: destroyed eggs/pets drop out.
local basePivots: { [Instance]: CFrame } = setmetatable({}, { __mode = "k" }) :: any

local revealGui: ScreenGui

local function formatTime(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function basePivot(item: PVInstance): CFrame
	local base = basePivots[item]
	if not base then
		base = item:GetPivot()
		basePivots[item] = base
	end
	return base
end

local function updateEgg(egg: BasePart, now: number, time: number)
	local endsAt = egg:GetAttribute(Constants.Attributes.HatchEndsAt)
	if typeof(endsAt) ~= "number" then
		return
	end
	local remaining = endsAt - now

	local ready = egg:GetAttribute(Constants.Attributes.Ready) == true
	local label = egg:FindFirstChild("Label")
	local subtitle = label and label:FindFirstChild("Subtitle")
	if subtitle and subtitle:IsA("TextLabel") then
		if ready then
			subtitle.Text = "✨ READY! Hold E to hatch"
		elseif remaining > 0 then
			subtitle.Text = `⏳ {formatTime(remaining)}`
		else
			subtitle.Text = "Almost ready..."
		end
	end

	local base = basePivot(egg)
	if ready then
		-- Bouncing happily, waiting for its owner.
		local hop = math.abs(math.sin(time * 5)) * 0.8
		local angle = math.sin(time * 10) * 0.12
		egg.CFrame = base * CFrame.new(0, hop, 0) * CFrame.Angles(0, 0, angle)
	elseif remaining < WIGGLE_SECONDS then
		-- Wiggle harder as the moment gets closer.
		local strength = 1 - math.max(remaining, 0) / WIGGLE_SECONDS
		local angle = math.sin(time * 30) * 0.25 * strength
		egg.CFrame = base * CFrame.Angles(0, 0, angle)
	end
end

local function updatePet(pet: Model, time: number)
	local base = basePivot(pet)
	-- Each pet bobs (and slowly looks left and right) at its own phase, so
	-- they don't all move together. Tails and fins are animated by
	-- CreatureController.
	local phase = (base.Position.X + base.Position.Z) * 0.3
	local bob = math.sin(time * BOB_SPEED + phase) * BOB_HEIGHT
	local turn = math.sin(time * TURN_SPEED + phase * 1.7) * TURN_ANGLE
	pet:PivotTo(base * CFrame.new(0, bob, 0) * CFrame.Angles(0, turn, 0))
end

---------------------------------------------------------------------------
-- Hatch effects
---------------------------------------------------------------------------

local function burst(position: unknown, rarity: unknown)
	if typeof(position) ~= "Vector3" or typeof(rarity) ~= "string" then
		return
	end
	local camera = Workspace.CurrentCamera
	if camera and (camera.CFrame.Position - position).Magnitude > 120 then
		return
	end
	-- Rarer pets get a bigger burst.
	Effects.burst(position + Vector3.new(0, 2, 0), Rarity.color(rarity), 20 + Rarity.rank(rarity) * 8)
	Sounds.play("Hatch")
end

local function showReveal(petName: unknown, rarity: unknown, income: unknown)
	if typeof(petName) ~= "string" or typeof(rarity) ~= "string" or typeof(income) ~= "number" then
		return
	end
	local color = Rarity.color(rarity)

	local card = Instance.new("Frame")
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.4)
	card.Size = UDim2.fromOffset(320, 150)
	card.BackgroundColor3 = Color3.fromRGB(20, 30, 50)
	card.BackgroundTransparency = 0.1
	card.Parent = revealGui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 16)
	corner.Parent = card
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = 4
	stroke.Parent = card
	local scale = Instance.new("UIScale")
	scale.Scale = 0.2
	scale.Parent = card

	local function line(text: string, textColor: Color3, y: number, height: number)
		local label = Instance.new("TextLabel")
		label.Position = UDim2.new(0, 10, 0, y)
		label.Size = UDim2.new(1, -20, 0, height)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.FredokaOne
		label.TextScaled = true
		label.TextColor3 = textColor
		label.Text = text
		label.Parent = card
	end
	line("🎉 You hatched", Color3.new(1, 1, 1), 8, 28)
	line(petName, color, 38, 50)
	line(`{rarity}  •  ${Format.short(income)}/s`, color:Lerp(Color3.new(1, 1, 1), 0.4), 94, 30)

	TweenService:Create(scale, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	task.delay(Config.PetDisplay.RevealSeconds, function()
		local shrink = TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Scale = 0 })
		shrink:Play()
		shrink.Completed:Wait()
		card:Destroy()
	end)
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function PetController.Init()
	revealGui = Instance.new("ScreenGui")
	revealGui.Name = "HatchReveal"
	revealGui.ResetOnSpawn = false
	revealGui.DisplayOrder = 20
	revealGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

function PetController.Start()
	Net.event(Net.Names.PetHatched).OnClientEvent:Connect(burst)
	Net.event(Net.Names.HatchReveal).OnClientEvent:Connect(showReveal)
	-- A small golden sparkle when a fish levels up.
	Net.event(Net.Names.FishLeveledUp).OnClientEvent:Connect(function(position: unknown)
		if typeof(position) == "Vector3" then
			Effects.burst(position, Color3.fromRGB(255, 220, 80), 18)
		end
	end)

	RunService.RenderStepped:Connect(function()
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local cameraPosition = camera.CFrame.Position
		local now = Workspace:GetServerTimeNow()
		local time = os.clock()

		for _, egg in CollectionService:GetTagged(Constants.Tags.HatchingEgg) do
			if egg:IsA("BasePart") and (egg.Position - cameraPosition).Magnitude < ANIMATE_DISTANCE then
				updateEgg(egg, now, time)
			end
		end
		for _, pet in CollectionService:GetTagged(Constants.Tags.PetModel) do
			if pet:IsA("Model") and (basePivot(pet).Position - cameraPosition).Magnitude < ANIMATE_DISTANCE then
				updatePet(pet, time)
			end
		end
	end)
end

return PetController
