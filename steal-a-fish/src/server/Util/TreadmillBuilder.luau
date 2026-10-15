--!strict
--[[
	TreadmillBuilder
	================
	Builds a treadmill of any tier from Config.Treadmill.Tiers out of parts:
	  - a frame (deck + raised side edges) in the tier's color and material
	  - a running belt with chevron (arrow) markings
	  - two uprights, handrails and a tilted console with a glowing screen
	  - on better tiers: glowing side stripes, light, sparkles/fire/stars, or
	    rainbow colors

	The runner stands on the belt facing the console. The belt is the part
	named "Treadmill"; it is the one that matters for gameplay (SpeedService
	checks who stands on it). Everything else is decoration.

	The belt markings move (and rainbow parts change color) on each player's
	own computer, done by the client's TreadmillController.

	Custom model: if ReplicatedStorage.Assets has a model named
	"Treadmill<TierName>" (for example "TreadmillGold") or "Treadmill", only the
	belt is built (invisible) and your model is placed on it.

	Usage:
		local model, belt = TreadmillBuilder.build(originCFrame, parent, tierIndex)
		-- originCFrame: the middle of the treadmill at floor height. Its
		-- LookVector (-Z) points toward the entry end; the console is at +Z.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Assets = require(script.Parent.Assets)
local Build = require(script.Parent.Build)

local TreadmillBuilder = {}

local LENGTH = 18 -- along Z
local WIDTH = 9.6 -- along X
local DECK_HEIGHT = 0.8
local BELT_WIDTH = 7
local BELT_LENGTH = LENGTH - 1
local CHEVRON_COUNT = 4

-- Two thin bars that form a "^" pointing toward the console (+Z).
local function buildChevron(belt: BasePart, index: number, tier: Config.TreadmillTier)
	local barAngle = math.rad(50)
	for _, side in { -1, 1 } do
		-- Where this bar sits relative to the chevron's center.
		local offset = CFrame.new(side * 0.75, 0, 0) * CFrame.Angles(0, -side * barAngle, 0)
		local bar = Build.part({
			Name = "Chevron",
			Size = Vector3.new(0.35, 0.06, 2.2),
			CFrame = belt.CFrame,
			Color = tier.ChevronColor,
			Material = if tier.ChevronNeon then Enum.Material.Neon else Enum.Material.SmoothPlastic,
			Studs = false,
			CanCollide = false,
			CanTouch = false,
			CanQuery = false,
			Parent = belt,
		})
		bar:SetAttribute("ChevronOffset", offset)
		bar:SetAttribute("ChevronIndex", index)
		-- Starting position; the client animates it from here.
		local spacing = BELT_LENGTH / CHEVRON_COUNT
		local z = BELT_LENGTH / 2 - (index - 0.5) * spacing
		bar.CFrame = belt.CFrame * CFrame.new(0, belt.Size.Y / 2 + 0.03, z) * offset
		if tier.Rainbow then
			CollectionService:AddTag(bar, Constants.Tags.RainbowPart)
		end
	end
end

local function addEffect(tier: Config.TreadmillTier, parts: { BasePart })
	for _, part in parts do
		if tier.Effect == "Sparkles" then
			local sparkles = Instance.new("Sparkles")
			sparkles.SparkleColor = tier.AccentColor or tier.ChevronColor
			sparkles.Parent = part
		elseif tier.Effect == "Fire" then
			local fire = Instance.new("Fire")
			fire.Color = tier.AccentColor or Color3.fromRGB(255, 100, 0)
			fire.SecondaryColor = Color3.fromRGB(255, 220, 80)
			fire.Size = 3
			fire.Heat = 4
			fire.Parent = part
		elseif tier.Effect == "Stars" then
			local stars = Instance.new("ParticleEmitter")
			stars.Color = ColorSequence.new(tier.AccentColor or tier.ChevronColor)
			stars.LightEmission = 1
			stars.Rate = 6
			stars.Lifetime = NumberRange.new(1.2, 2)
			stars.Speed = NumberRange.new(1, 3)
			stars.SpreadAngle = Vector2.new(180, 180)
			stars.Size = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.4),
				NumberSequenceKeypoint.new(1, 0),
			})
			stars.Parent = part
		end
	end
end

function TreadmillBuilder.build(origin: CFrame, parent: Instance, tierIndex: number): (Model, BasePart)
	local tiers = Config.Treadmill.Tiers
	local index = math.clamp(math.floor(tierIndex), 1, #tiers)
	local tier = tiers[index]

	local model = Instance.new("Model")
	model.Name = "TreadmillModel"
	model:SetAttribute("Tier", index)
	model.Parent = parent

	-- The running belt (the gameplay part).
	local belt = Build.part({
		Name = "Treadmill",
		Size = Vector3.new(BELT_WIDTH, 0.2, BELT_LENGTH),
		CFrame = origin * CFrame.new(0, DECK_HEIGHT + 0.1, -0.3),
		Color = tier.BeltColor,
		Studs = false,
		Parent = model,
	})
	belt:SetAttribute("ChevronCount", CHEVRON_COUNT)
	belt:SetAttribute(Constants.Attributes.BeltActive, false)
	CollectionService:AddTag(belt, Constants.Tags.TreadmillBelt)

	if Assets.decorate(belt, `Treadmill{tier.Name}`) or Assets.decorate(belt, "Treadmill") then
		return model, belt
	end

	for chevron = 1, CHEVRON_COUNT do
		buildChevron(belt, chevron, tier)
	end

	-- Frame parts share the tier's look. Rainbow frames skip studs (their
	-- color changes on the client, and the studs wouldn't follow).
	local frameParts: { BasePart } = {}
	local function framePart(name: string, size: Vector3, cf: CFrame): BasePart
		local part = Build.part({
			Name = name,
			Size = size,
			CFrame = cf,
			Color = tier.FrameColor,
			Material = tier.FrameMaterial,
			Studs = if tier.Rainbow then false else nil,
			Parent = model,
		})
		if tier.Rainbow then
			CollectionService:AddTag(part, Constants.Tags.RainbowPart)
		end
		table.insert(frameParts, part)
		return part
	end

	-- Deck under the belt, and raised edges on both sides.
	framePart("Deck", Vector3.new(WIDTH, DECK_HEIGHT, LENGTH), origin * CFrame.new(0, DECK_HEIGHT / 2, 0))
	local edgeWidth = (WIDTH - BELT_WIDTH) / 2
	local edges: { BasePart } = {}
	for _, side in { -1, 1 } do
		local x = side * (BELT_WIDTH / 2 + edgeWidth / 2)
		table.insert(edges, framePart("SideEdge", Vector3.new(edgeWidth, 0.5, LENGTH), origin * CFrame.new(x, DECK_HEIGHT + 0.25, 0)))
	end

	-- Uprights and handrails at the console end (+Z).
	local consoleZ = LENGTH / 2 - 0.8
	local uprightHeight = 4.5
	for _, side in { -1, 1 } do
		local x = side * (WIDTH / 2 - 0.4)
		framePart("Upright", Vector3.new(0.8, uprightHeight, 0.8), origin * CFrame.new(x, DECK_HEIGHT + uprightHeight / 2, consoleZ))
		framePart("Handrail", Vector3.new(0.6, 0.6, 7), origin * CFrame.new(x, DECK_HEIGHT + 3.4, consoleZ - 3.5))
	end

	-- Console across the top, tilted up toward the runner, with a screen.
	local console = framePart(
		"Console",
		Vector3.new(WIDTH, 1.2, 2.6),
		origin * CFrame.new(0, DECK_HEIGHT + uprightHeight + 0.4, consoleZ) * CFrame.Angles(math.rad(25), 0, 0)
	)
	local screen = Build.part({
		Name = "Screen",
		Size = Vector3.new(5, 0.7, 0.1),
		CFrame = console.CFrame * CFrame.new(0, 0, -1.35),
		Color = tier.ScreenColor,
		Material = Enum.Material.Neon,
		CanCollide = false,
		CanQuery = false,
		Parent = model,
	})
	-- The tier's name on the screen.
	Build.surfaceText(screen, Enum.NormalId.Front, tier.Name:upper(), Color3.fromRGB(20, 20, 30))

	-- Glowing stripes along both sides of the belt.
	if tier.AccentColor then
		for _, edge in edges do
			local stripe = Build.part({
				Name = "AccentStripe",
				Size = Vector3.new(0.3, 0.15, LENGTH),
				CFrame = edge.CFrame * CFrame.new(0, 0.3, 0),
				Color = tier.AccentColor,
				Material = Enum.Material.Neon,
				CanCollide = false,
				CanQuery = false,
				CanTouch = false,
				Parent = model,
			})
			if tier.Rainbow then
				CollectionService:AddTag(stripe, Constants.Tags.RainbowPart)
			end
		end
	end

	if tier.Light > 0 then
		local light = Instance.new("PointLight")
		light.Color = tier.AccentColor or tier.ScreenColor
		light.Brightness = tier.Light
		light.Range = 10 + tier.Light * 3
		light.Parent = console
	end

	addEffect(tier, edges)

	return model, belt
end

return TreadmillBuilder
