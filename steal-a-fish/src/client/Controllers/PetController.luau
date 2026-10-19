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
-- starts from the right place. It's remembered ON the instance (a local
-- attribute, set once), never in a weak table: Roblox may forget weak-table
-- entries at any time, and then we'd re-measure an already moved/grown egg.
local BASE_PIVOT = "ClientBasePivot"
local BASE_SIZE = "ClientBaseSize"
local BASE_C0 = "ClientBaseC0"

local revealGui: ScreenGui

local function formatTime(seconds: number): string
	seconds = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

local function basePivot(item: PVInstance): CFrame
	local base = item:GetAttribute(BASE_PIVOT)
	if typeof(base) == "CFrame" then
		return base
	end
	local pivot = item:GetPivot()
	item:SetAttribute(BASE_PIVOT, pivot)
	return pivot
end

---------------------------------------------------------------------------
-- Growing eggs: while an egg counts down it grows (Config.Eggs.GrowByRarity),
-- upward from the pad. Only on screen: every part of the egg is resized and
-- its welds stretched, so the whole egg grows together.
---------------------------------------------------------------------------

-- The ORIGINAL size of each part and joint offset of an egg is stored once,
-- on the part/joint itself (local attributes). Sizes are always
-- original x growth, so nothing can ever grow twice.
type EggParts = {
	Parts: { { Part: BasePart, Size: Vector3 } },
	Joints: { { Joint: JointInstance, C0: CFrame } },
	LabelOffset: Vector3?,
	Scale: number,
}
local eggParts: { [BasePart]: EggParts } = {}

local function originalSize(part: BasePart): Vector3
	local saved = part:GetAttribute(BASE_SIZE)
	if typeof(saved) == "Vector3" then
		return saved
	end
	part:SetAttribute(BASE_SIZE, part.Size)
	return part.Size
end

local function originalC0(joint: JointInstance): CFrame
	local saved = joint:GetAttribute(BASE_C0)
	if typeof(saved) == "CFrame" then
		return saved
	end
	joint:SetAttribute(BASE_C0, joint.C0)
	return joint.C0
end

local function eggInfo(egg: BasePart): EggParts
	local info = eggParts[egg]
	if info then
		return info
	end
	-- The egg's own size is simply Config.Eggs.Size (it never changes on the server).
	if typeof(egg:GetAttribute(BASE_SIZE)) ~= "Vector3" then
		egg:SetAttribute(BASE_SIZE, Config.Eggs.Size)
	end
	local newInfo: EggParts = { Parts = {}, Joints = {}, LabelOffset = nil, Scale = -1 }
	for _, item in egg:GetDescendants() do
		if item:IsA("BasePart") then
			table.insert(newInfo.Parts, { Part = item, Size = originalSize(item) })
		elseif item:IsA("JointInstance") then
			table.insert(newInfo.Joints, { Joint = item, C0 = originalC0(item) })
		end
	end
	local label = egg:FindFirstChild("Label")
	if label and label:IsA("BillboardGui") then
		local saved = label:GetAttribute(BASE_SIZE)
		if typeof(saved) ~= "Vector3" then
			saved = label.StudsOffsetWorldSpace
			label:SetAttribute(BASE_SIZE, saved)
		end
		newInfo.LabelOffset = saved :: Vector3
	end
	eggParts[egg] = newInfo
	-- Forget it when the egg is gone (hatched or removed). If more parts
	-- arrive over the network, build the list again (the ORIGINAL sizes are
	-- stored on the parts, so rebuilding never grows anything twice).
	local connections: { RBXScriptConnection } = {}
	local function forget()
		if eggParts[egg] == newInfo then
			eggParts[egg] = nil
		end
		for _, connection in connections do
			connection:Disconnect()
		end
	end
	table.insert(connections, egg.Destroying:Connect(forget))
	table.insert(connections, egg.DescendantAdded:Connect(function(item)
		if item:IsA("BasePart") or item:IsA("JointInstance") then
			forget()
		end
	end))
	return newInfo
end

local function setEggScale(egg: BasePart, info: EggParts, scale: number)
	info.Scale = scale
	egg.Size = Config.Eggs.Size * scale
	for _, entry in info.Parts do
		entry.Part.Size = entry.Size * scale
	end
	for _, entry in info.Joints do
		entry.Joint.C0 = entry.C0.Rotation + entry.C0.Position * scale
	end
	local label = egg:FindFirstChild("Label")
	if info.LabelOffset and label and label:IsA("BillboardGui") then
		-- Keep the name label just above the (bigger) egg.
		label.StudsOffsetWorldSpace = info.LabelOffset + Vector3.new(0, Config.Eggs.Size.Y * (scale - 1), 0)
	end
end

-- How big an egg should be right now (1 = normal).
local function eggGrowth(egg: BasePart, remaining: number, ready: boolean): number
	local rarity = egg:GetAttribute("Rarity")
	local maxSize = if typeof(rarity) == "string" then Config.Eggs.GrowByRarity[rarity] or 1 else 1
	local duration = egg:GetAttribute("HatchDuration")
	local progress = if ready then 1 elseif typeof(duration) == "number" and duration > 0 then 1 - math.clamp(remaining / duration, 0, 1) else 0
	-- Never bigger than the rarity's maximum.
	return math.clamp(1 + (maxSize - 1) * progress, 1, math.max(maxSize, 1))
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

	-- Grow (only resize when it changed noticeably, to keep things fast).
	local info = eggInfo(egg)
	local scale = eggGrowth(egg, remaining, ready)
	if math.abs(scale - info.Scale) > 0.004 then
		setEggScale(egg, info, scale)
	end
	-- Grow upward: the bottom stays where it was, the middle rises.
	local base = basePivot(egg) * CFrame.new(0, Config.Eggs.Size.Y * (info.Scale - 1) / 2, 0)
	if ready then
		-- Bouncing happily, waiting for its owner.
		local hop = math.abs(math.sin(time * 5)) * 0.8 * info.Scale
		local angle = math.sin(time * 10) * 0.12
		egg.CFrame = base * CFrame.new(0, hop, 0) * CFrame.Angles(0, 0, angle)
	elseif remaining < WIGGLE_SECONDS then
		-- Wiggle harder as the moment gets closer.
		local strength = 1 - math.max(remaining, 0) / WIGGLE_SECONDS
		local angle = math.sin(time * 30) * 0.25 * strength
		egg.CFrame = base * CFrame.Angles(0, 0, angle)
	else
		egg.CFrame = base
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
	-- Sparkles where a new pad or the second floor appears.
	Net.event(Net.Names.PlotUpgraded).OnClientEvent:Connect(function(position: unknown)
		if typeof(position) == "Vector3" then
			Effects.burst(position + Vector3.new(0, 1, 0), Color3.fromRGB(120, 255, 140), 30)
			Effects.confetti(position + Vector3.new(0, 1, 0), 30)
		end
	end)
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
			-- Growing eggs can be huge, so they're updated from farther away.
			if egg:IsA("BasePart") and (basePivot(egg).Position - cameraPosition).Magnitude < ANIMATE_DISTANCE * 2.5 then
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
