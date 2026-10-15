--!strict
--[[
	TreadmillBuilder
	================
	Builds a treadmill out of placeholder parts:
	  - a light-grey frame (deck + raised side edges)
	  - a dark running belt with light chevron (arrow) markings
	  - two uprights, handrails and a tilted console with a glowing screen

	The runner stands on the belt facing the console. The belt is the part
	named "Treadmill"; it is the one that matters for gameplay (Milestone 5
	checks who stands on it). Everything else is decoration.

	The chevrons are animated on each player's computer by the client's
	TreadmillController, so the belt looks like it's moving. The server never
	moves them.

	Custom model: if ReplicatedStorage.Assets has a "Treadmill" model, only the
	belt is built (invisible) and your model is placed on it.

	Usage:
		local belt = TreadmillBuilder.build(originCFrame, parent)
		-- originCFrame: the middle of the treadmill at floor height. Its
		-- LookVector (-Z) points toward the entry end; the console is at +Z.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

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

local FRAME_COLOR = Color3.fromRGB(205, 205, 212)
local BELT_COLOR = Color3.fromRGB(45, 45, 52)
local CHEVRON_COLOR = Color3.fromRGB(235, 235, 240)
local SCREEN_COLOR = Color3.fromRGB(80, 220, 255)

-- Two thin bars that form a "^" pointing toward the console (+Z).
local function buildChevron(belt: BasePart, index: number)
	local barAngle = math.rad(50)
	for _, side in { -1, 1 } do
		-- Where this bar sits relative to the chevron's center.
		local offset = CFrame.new(side * 0.75, 0, 0) * CFrame.Angles(0, -side * barAngle, 0)
		local bar = Build.part({
			Name = "Chevron",
			Size = Vector3.new(0.35, 0.06, 2.2),
			CFrame = belt.CFrame,
			Color = CHEVRON_COLOR,
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
	end
end

function TreadmillBuilder.build(origin: CFrame, parent: Instance): BasePart
	local model = Instance.new("Model")
	model.Name = "TreadmillModel"
	model.Parent = parent

	-- The running belt (the gameplay part).
	local belt = Build.part({
		Name = "Treadmill",
		Size = Vector3.new(BELT_WIDTH, 0.2, BELT_LENGTH),
		CFrame = origin * CFrame.new(0, DECK_HEIGHT + 0.1, -0.3),
		Color = BELT_COLOR,
		Studs = false,
		Parent = model,
	})
	belt:SetAttribute("ChevronCount", CHEVRON_COUNT)
	CollectionService:AddTag(belt, Constants.Tags.TreadmillBelt)

	if Assets.decorate(belt, "Treadmill") then
		return belt
	end

	for index = 1, CHEVRON_COUNT do
		buildChevron(belt, index)
	end

	-- Frame: the deck under the belt, and raised edges on both sides.
	Build.part({
		Name = "Deck",
		Size = Vector3.new(WIDTH, DECK_HEIGHT, LENGTH),
		CFrame = origin * CFrame.new(0, DECK_HEIGHT / 2, 0),
		Color = FRAME_COLOR,
		Parent = model,
	})
	for _, side in { -1, 1 } do
		Build.part({
			Name = "SideEdge",
			Size = Vector3.new((WIDTH - BELT_WIDTH) / 2, 0.5, LENGTH),
			CFrame = origin * CFrame.new(side * (BELT_WIDTH / 2 + (WIDTH - BELT_WIDTH) / 4), DECK_HEIGHT + 0.25, 0),
			Color = FRAME_COLOR,
			Parent = model,
		})
	end

	-- Uprights and handrails at the console end (+Z).
	local consoleZ = LENGTH / 2 - 0.8
	local uprightHeight = 4.5
	for _, side in { -1, 1 } do
		local x = side * (WIDTH / 2 - 0.4)
		Build.part({
			Name = "Upright",
			Size = Vector3.new(0.8, uprightHeight, 0.8),
			CFrame = origin * CFrame.new(x, DECK_HEIGHT + uprightHeight / 2, consoleZ),
			Color = FRAME_COLOR,
			Parent = model,
		})
		Build.part({
			Name = "Handrail",
			Size = Vector3.new(0.6, 0.6, 7),
			CFrame = origin * CFrame.new(x, DECK_HEIGHT + 3.4, consoleZ - 3.5),
			Color = FRAME_COLOR,
			Parent = model,
		})
	end

	-- Console across the top, tilted up toward the runner, with a screen.
	local console = Build.part({
		Name = "Console",
		Size = Vector3.new(WIDTH, 1.2, 2.6),
		CFrame = origin * CFrame.new(0, DECK_HEIGHT + uprightHeight + 0.4, consoleZ) * CFrame.Angles(math.rad(25), 0, 0),
		Color = FRAME_COLOR,
		Parent = model,
	})
	Build.part({
		Name = "Screen",
		Size = Vector3.new(5, 0.7, 0.1),
		CFrame = console.CFrame * CFrame.new(0, 0, -1.35),
		Color = SCREEN_COLOR,
		Material = Enum.Material.Neon,
		CanCollide = false,
		CanQuery = false,
		Parent = model,
	})

	return belt
end

return TreadmillBuilder
