--!strict
--[[
	TutorialController
	==================
	A short guide for new players (the server turns it on with the player
	attribute "ShowTutorial", and remembers when it's done):

	  1. Steal an egg in the Danger Zone       -> arrow to the entrance
	  2. Run back to the safe zone            -> arrow to your plot
	     (caught? back to step 1)
	  3. Equip the egg, press E on a free pad -> arrow to your plot
	  4. Hold E on the egg when it's READY    -> arrow to your plot
	  5. Train on your treadmill              -> arrow to your treadmill
	  6. "Faster = deeper zones = rarer eggs!" -> done after a few seconds

	A trail of bold red arrows (chevrons) lies flat on the ground from you to
	the target. They flow toward the target and get smaller farther away. A
	tall glowing beacon marks the target. Both exist only on your own screen.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Layout = require(ReplicatedStorage.Shared.Layout)
local Net = require(ReplicatedStorage.Shared.Net)
local Kit = require(script.Parent.Parent.Ui.Kit)
local Sounds = require(script.Parent.Parent.Ui.Sounds)

local TutorialController = {}
TutorialController.Name = "TutorialController"

local player = Players.LocalPlayer

local STEPS = {
	"🥚 Go to the Danger Zone and steal an egg!",
	"🏃 Run back to the safe zone before the shark gets you!",
	"🎒 Equip the egg from your hotbar and press E on a free pad!",
	"✨ When the egg says READY, hold E on it to hatch!",
	"⚡ Step on your treadmill to train your Speed!",
	"🎉 Faster = deeper zones = rarer eggs. Have fun!",
}
local FINAL_STEP = #STEPS
local FINAL_STEP_SECONDS = 6

local step = 0 -- 0 = tutorial not running
local banner: TextLabel
local bannerFrame: Frame
local CHEVRONS = 14 -- how many arrows the trail has (at most)
local CHEVRON_SPACING = 4.5 -- studs between two arrows
local CHEVRON_COLOR = Color3.fromRGB(235, 35, 35)
local FLOW_SPEED = 6 -- studs per second the arrows flow toward the target
local chevrons: { { Left: BasePart, Right: BasePart } } = {}
local chevronFolder: Folder? = nil
local beacon: BasePart? = nil
-- Counts when the current step started, to notice progress.
local eggsAtStepStart = 0
local padEggsAtStepStart = 0
local petsAtStepStart = 0
local finalStepEndsAt = 0
local lostEggSince: number? = nil -- when we first noticed "not carrying" in step 2

---------------------------------------------------------------------------
-- Finding things in the world
---------------------------------------------------------------------------

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

-- How many things with this tag are on my plot (eggs or pets).
local function countOnMyPlot(tag: string): number
	local plot = myPlot()
	if not plot then
		return 0
	end
	local count = 0
	for _, child in plot:GetChildren() do
		if CollectionService:HasTag(child, tag) then
			count += 1
		end
	end
	return count
end

local function eggCount(): number
	local value = player:GetAttribute(Constants.Attributes.EggCount)
	return if typeof(value) == "number" then value else 0
end

-- Where the current step wants you to go (nil = nowhere).
local function targetPosition(): Vector3?
	if step == 1 then
		-- A little way into the first danger zone.
		return Vector3.new(0, Layout.GroundTop, Layout.DangerZoneFront - 15)
	end
	local plot = myPlot()
	if not plot then
		return nil
	end
	if step == 2 or step == 3 or step == 4 then
		local floor = plot.PrimaryPart
		return if floor then floor.Position else nil
	elseif step == 5 then
		local model = plot:FindFirstChild("TreadmillModel")
		local belt = model and model:FindFirstChild("Treadmill")
		return if belt and belt:IsA("BasePart") then belt.Position else nil
	end
	return nil
end

---------------------------------------------------------------------------
-- Arrow and beacon (local parts)
---------------------------------------------------------------------------

local function neonPart(name: string, size: Vector3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Material = Enum.Material.Neon
	part.Color = Config.Tutorial.ArrowColor
	part.Parent = parent
	return part
end

-- One flat chevron: two bars meeting at a point (">"), lying on the ground.
local function buildChevrons()
	local folder = Instance.new("Folder")
	folder.Name = "TutorialArrows"
	folder.Parent = Workspace
	chevronFolder = folder
	for _ = 1, CHEVRONS do
		local left: BasePart = neonPart("ArrowLeft", Vector3.new(0.7, 0.15, 2.6), folder)
		local right: BasePart = neonPart("ArrowRight", Vector3.new(0.7, 0.15, 2.6), folder)
		left.Color = CHEVRON_COLOR
		right.Color = CHEVRON_COLOR
		table.insert(chevrons, { Left = left, Right = right })
	end
end

local function hideChevrons()
	for _, chevron in chevrons do
		chevron.Left.Transparency = 1
		chevron.Right.Transparency = 1
	end
end

-- The floor height under a spot (plot floors, second floors, sand).
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local function floorY(position: Vector3): number
	local exclude: { Instance } = {}
	if player.Character then
		table.insert(exclude, player.Character)
	end
	if chevronFolder then
		table.insert(exclude, chevronFolder)
	end
	if beacon then
		table.insert(exclude, beacon)
	end
	rayParams.FilterDescendantsInstances = exclude
	local origin = Vector3.new(position.X, position.Y + 4, position.Z)
	local result = Workspace:Raycast(origin, Vector3.new(0, -30, 0), rayParams)
	return if result then result.Position.Y else Layout.GroundTop
end

local function buildBeacon(): BasePart
	local height = Config.Tutorial.BeaconHeight
	local part = neonPart("TutorialBeacon", Vector3.new(height, 4, 4), Workspace)
	part.Shape = Enum.PartType.Cylinder
	part.Transparency = 0.5
	return part
end

local function clearMarkers()
	hideChevrons()
	if beacon then
		beacon:Destroy()
		beacon = nil
	end
end

local function updateMarkers()
	local target = targetPosition()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (target and root and root:IsA("BasePart")) then
		clearMarkers()
		return
	end
	if #chevrons == 0 then
		buildChevrons()
	end
	if not beacon then
		beacon = buildBeacon()
	end

	-- Beacon: an upright glowing column standing on the target.
	local height = Config.Tutorial.BeaconHeight
	;(beacon :: BasePart).CFrame = CFrame.new(target + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.rad(90))

	-- Arrow trail: from just in front of you toward the target, flowing
	-- forward, smaller (and fainter) farther away.
	local flat = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z)
	local total = flat.Magnitude
	if total < 0.1 then
		hideChevrons()
		return
	end
	local direction = flat.Unit
	local time = os.clock()
	local offset = (time * FLOW_SPEED) % CHEVRON_SPACING
	local trailLength = CHEVRONS * CHEVRON_SPACING
	for index, chevron in chevrons do
		local distance = 3 + (index - 1) * CHEVRON_SPACING + offset
		if distance > total - 2 or distance > trailLength then
			chevron.Left.Transparency = 1
			chevron.Right.Transparency = 1
			continue
		end
		local along = distance / trailLength -- 0 near you, 1 at the end of the trail
		local scale = 1.25 - along * 0.65
		local spot = Vector3.new(root.Position.X, 0, root.Position.Z) + direction * distance
		local y = floorY(Vector3.new(spot.X, root.Position.Y, spot.Z)) + 0.1
		local base = CFrame.lookAt(Vector3.new(spot.X, y, spot.Z), Vector3.new(spot.X, y, spot.Z) + direction)
		-- A gentle pulse running along the trail.
		local pulse = 0.5 + 0.5 * math.sin(time * 6 - index * 0.8)
		local transparency = math.clamp(0.05 + along * 0.45 + pulse * 0.15, 0, 0.9)
		local armLength = 2.6 * scale
		for side, part in { [-1] = chevron.Left, [1] = chevron.Right } do
			part.Size = Vector3.new(0.7 * scale, 0.15, armLength)
			-- Each bar goes back from the tip at 40 degrees to one side.
			local angle = math.rad(40) * side
			local center = CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, armLength / 2)
			part.CFrame = base * center
			part.Transparency = transparency
		end
	end
end

---------------------------------------------------------------------------
-- Steps
---------------------------------------------------------------------------

local function setStep(newStep: number)
	step = newStep
	if step == 0 then
		bannerFrame.Visible = false
		clearMarkers()
		return
	end
	bannerFrame.Visible = true
	banner.Text = STEPS[step]
	eggsAtStepStart = eggCount()
	padEggsAtStepStart = countOnMyPlot(Constants.Tags.HatchingEgg)
	petsAtStepStart = countOnMyPlot(Constants.Tags.PetModel)
	if step == FINAL_STEP then
		finalStepEndsAt = os.clock() + FINAL_STEP_SECONDS
		clearMarkers()
	end
	Sounds.play("Click")
	-- Small pop so the new instruction gets noticed.
	local scale = bannerFrame:FindFirstChildOfClass("UIScale")
	if scale then
		local target = scale.Scale
		scale.Scale = target * 1.15
		TweenService:Create(scale, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = target }):Play()
	end
end

local function finish()
	setStep(0)
	Net.event(Net.Names.TutorialFinished):FireServer()
end

-- Runs every frame while the tutorial is on.
local function update()
	if step == 0 then
		return
	end
	local carrying = player:GetAttribute(Constants.Attributes.CarryingEgg) ~= nil
	local training = player:GetAttribute(Constants.Attributes.Training) == true

	if step == 1 and carrying then
		setStep(2)
	elseif step == 2 then
		if eggCount() > eggsAtStepStart then
			lostEggSince = nil
			setStep(3) -- the egg is safe in the hotbar!
		elseif not carrying then
			-- The egg may simply not have shown up on the pad yet; wait a moment
			-- before deciding it was lost.
			lostEggSince = lostEggSince or os.clock()
			if os.clock() - (lostEggSince :: number) > 1 then
				lostEggSince = nil
				setStep(1) -- caught (or lost the egg): try again
			end
		else
			lostEggSince = nil
		end
	elseif step == 3 and countOnMyPlot(Constants.Tags.HatchingEgg) > padEggsAtStepStart then
		setStep(4) -- placed on a pad
	elseif step == 4 and countOnMyPlot(Constants.Tags.PetModel) > petsAtStepStart then
		setStep(5) -- hatched!
	elseif step == 5 and training then
		setStep(6)
	elseif step == FINAL_STEP and os.clock() >= finalStepEndsAt then
		finish()
		return
	end
	updateMarkers()
end

local function onShowTutorialChanged()
	if player:GetAttribute(Constants.Attributes.ShowTutorial) == true then
		if step == 0 then
			setStep(1)
		end
	elseif step ~= 0 then
		setStep(0)
	end
end

function TutorialController.Init()
	local gui = Kit.screenGui("Tutorial", 8)
	bannerFrame = Instance.new("Frame")
	bannerFrame.AnchorPoint = Vector2.new(0.5, 0)
	bannerFrame.Position = UDim2.new(0.5, 0, 0, 8)
	bannerFrame.Size = UDim2.fromOffset(560, 54)
	bannerFrame.BackgroundColor3 = Kit.Colors.Panel
	bannerFrame.Visible = false
	bannerFrame.Parent = gui
	Kit.corner(bannerFrame, 14)
	Kit.stroke(bannerFrame, Config.Tutorial.ArrowColor, 3)
	Kit.autoScale(bannerFrame, Vector2.new(560, 54))

	banner = Kit.label(bannerFrame, "", UDim2.new(1, -24, 1, -14), UDim2.fromOffset(12, 7), Config.Tutorial.ArrowColor)
	banner.TextXAlignment = Enum.TextXAlignment.Center

	-- A small "skip" button for players who don't need help.
	local skip = Kit.button(bannerFrame, "Skip", Kit.Colors.Grey, UDim2.fromOffset(64, 34), UDim2.new(1, -72, 0.5, -17))
	skip.Activated:Connect(finish)
	banner.Size = UDim2.new(1, -92, 1, -14)
end

function TutorialController.Start()
	player:GetAttributeChangedSignal(Constants.Attributes.ShowTutorial):Connect(onShowTutorialChanged)
	onShowTutorialChanged()
	RunService.RenderStepped:Connect(update)
end

return TutorialController
