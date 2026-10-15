--!strict
--[[
	PetVisual
	=========
	Creates the 3D pet that floats above a pad.

	Placeholder: a simple fish made of parts in the pet's Config color, bigger
	for rarer pets, glowing for rarities with Glow > 0.
	Custom model: put a Model named exactly like the pet (for example
	"Kraken") in ReplicatedStorage > Assets.

	Every pet is a Model whose PrimaryPart ("PetRoot") is an invisible,
	anchored part at the pet's center. Its LookVector is where the pet faces.

	Usage:
		local model = PetVisual.create("Kraken", "Mythic", Color3.new(...), cframe)
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local Assets = require(script.Parent.Assets)

local PetVisual = {}

local function addPart(model: Model, root: BasePart, name: string, size: Vector3, offset: CFrame, color: Color3, shape: string?): BasePart
	local part: BasePart = if shape == "Wedge" then Instance.new("WedgePart") else Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CFrame = root.CFrame * offset
	if shape == "Sphere" then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = part
	end
	part.Parent = model
	return part
end

-- A cute placeholder fish. Its nose points along the root's LookVector (-Z).
local function buildPlaceholderFish(model: Model, root: BasePart, color: Color3, scale: number, glow: number)
	local function s(x: number, y: number, z: number): Vector3
		return Vector3.new(x, y, z) * scale
	end
	local function at(x: number, y: number, z: number): CFrame
		return CFrame.new(x * scale, y * scale, z * scale)
	end
	local finColor = color:Lerp(Color3.new(0, 0, 0), 0.25)

	local body = addPart(model, root, "Body", s(2, 2.2, 3.4), CFrame.new(), color, "Sphere")
	addPart(model, root, "Tail", s(0.3, 1.8, 1.4), at(0, 0, 2.1) * CFrame.Angles(0, math.pi, 0), finColor, "Wedge")
	addPart(model, root, "TopFin", s(0.25, 1, 1.2), at(0, 1.25, 0.3), finColor, "Wedge")
	for _, side in { -1, 1 } do
		addPart(model, root, "Eye", s(0.45, 0.45, 0.45), at(side * 0.75, 0.35, -1.25), Color3.new(1, 1, 1), "Sphere")
		addPart(model, root, "Pupil", s(0.25, 0.25, 0.25), at(side * 0.92, 0.35, -1.35), Color3.new(0, 0, 0), "Sphere")
		addPart(model, root, "SideFin", s(0.9, 0.15, 0.6), at(side * 1.05, -0.3, -0.1) * CFrame.Angles(0, 0, side * math.rad(-25)), finColor)
	end

	if glow > 0 then
		body.Material = Enum.Material.Neon
		local light = Instance.new("PointLight")
		light.Color = if color.R + color.G + color.B < 0.5 then Color3.new(1, 1, 1) else color
		light.Range = 4 + glow * 3
		light.Brightness = glow * 0.6
		light.Parent = body
	end
end

function PetVisual.create(petName: string, rarity: string, color: Color3, cframe: CFrame): Model
	local model = Instance.new("Model")
	model.Name = petName

	local root = Instance.new("Part")
	root.Name = "PetRoot"
	root.Size = Vector3.new(1, 1, 1)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.CFrame = cframe
	root.Parent = model
	model.PrimaryPart = root

	if not Assets.decorate(root, petName) then
		local scale = 1 + (Rarity.rank(rarity) - 1) * Config.PetDisplay.SizePerRarity
		buildPlaceholderFish(model, root, color, scale, Rarity.glow(rarity))
	end

	model:SetAttribute("Rarity", rarity)
	CollectionService:AddTag(model, Constants.Tags.PetModel)
	return model
end

return PetVisual
