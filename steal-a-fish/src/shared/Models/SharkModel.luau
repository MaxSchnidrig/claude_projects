--!strict
--[[
	SharkModel
	==========
	Builds a real-looking (but still blocky) shark: pointed snout, strong
	body, dorsal fin, side fins, a crescent tail fin, gills, angry eyes and
	teeth. Each zone's shark looks different (Config.Sharks: colors, size,
	scars, glowing eyes, spikes) and deeper sharks are bigger and scarier.

	It swims on the client (CreatureController): the tail swishes and the
	body sways, faster while it moves fast. While chasing (attribute
	"Chasing", set by SharkModel.setChasing) the client smoothly turns it red
	and makes it glow.

	Custom model: "Shark<zone>" (for example "Shark7") or "Shark"
	(Config.Bots.ModelName) in ReplicatedStorage.Assets.

	Usage:
		SharkModel.build(model, rootPart, zoneIndex)   -- adds the shark's parts to `model`
		SharkModel.setChasing(model, true)
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Assets = require(script.Parent.Parent.Assets)
local Voxel = require(script.Parent.Voxel)

local SharkModel = {}

local V = Vector3.new
local CF = CFrame.new
local rad = math.rad
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local CHASE_COLOR = Color3.fromRGB(255, 40, 40)

-- Battle scars: { side, height, position along the body, tilt }
local SCARS = { { 1, 0.3, -1.2, 35 }, { -1, 0.5, -0.4, -30 }, { 1, -0.2, 0.6, -25 } }

local function buildParts(model: Model, root: BasePart, zoneIndex: number)
	local look = Config.Sharks[zoneIndex] or Config.Sharks[1]
	local b = Voxel.new(model, root, look.Scale)
	local color = look.Color
	local dark = color:Lerp(BLACK, 0.55)

	-- The whole body sways gently; the tail swings much more.
	local body = Voxel.pivot(b, "BodyPivot", CF(), "Y", 0.06, 2.5, 0)
	local on = { Attach = body }

	Voxel.block(b, "Body", V(3.0, 2.6, 4.2), CF(0, 0, -0.4), color, { Attach = body, Studs = true })
	local head = Voxel.block(b, "SharkHead", V(2.6, 2.2, 1.8), CF(0, 0.05, -3.4), color, on)
	Voxel.block(b, "Snout", V(1.9, 1.5, 1.0), CF(0, 0.2, -4.8), color, on)
	Voxel.block(b, "SnoutTip", V(1.1, 0.9, 0.6), CF(0, 0.35, -5.6), color, on)
	Voxel.block(b, "Belly", V(2.6, 0.6, 5.6), CF(0, -1.05, -1.9), look.Belly, on)
	Voxel.block(b, "Jaw", V(1.6, 0.4, 1.1), CF(0, -0.8, -4.65), look.Belly, on)
	Voxel.block(b, "Mouth", V(1.5, 0.22, 0.1), CF(0, -0.56, -5.22), Color3.fromRGB(110, 15, 25), on)
	-- Teeth: little white diamonds along the mouth.
	for i = -2, 2 do
		Voxel.block(b, "Tooth", V(0.17, 0.17, 0.08), CF(i * 0.3, -0.52, -5.3) * CFrame.Angles(0, 0, rad(45)), WHITE, { Attach = body, Outline = false })
	end

	for _, side in { -1, 1 } do
		-- Angry eyes: an eyeball, a pupil and a slanted brow.
		local eyeOptions: Voxel.BlockOptions = { Attach = body, Outline = false }
		if look.GlowEyes then
			eyeOptions.Material = Enum.Material.Neon
			Voxel.block(b, "Eye", V(0.08, 0.5, 0.6), CF(side * 1.31, 0.45, -3.8), look.EyeColor, eyeOptions)
			Voxel.block(b, "Pupil", V(0.06, 0.3, 0.18), CF(side * 1.36, 0.42, -3.9), WHITE, eyeOptions)
		else
			Voxel.block(b, "Eye", V(0.08, 0.5, 0.6), CF(side * 1.31, 0.45, -3.8), WHITE, eyeOptions)
			Voxel.block(b, "Pupil", V(0.06, 0.32, 0.3), CF(side * 1.36, 0.42, -3.92), look.EyeColor, eyeOptions)
		end
		Voxel.block(b, "Brow", V(0.12, 0.16, 0.85), CF(side * 1.33, 0.82, -3.8) * CFrame.Angles(rad(-25), 0, 0), dark, on)
		-- Gills.
		for k = 0, 2 do
			Voxel.block(b, "Gill", V(0.06, 0.9, 0.12), CF(side * 1.51, 0.1, -2.1 + k * 0.35), dark, on)
		end
		-- Side (pectoral) fins.
		local finPivot = Voxel.pivot(b, "FinPivot", CF(side * 1.5, -0.7, -1.4), "Z", 0.12, 2.5, if side > 0 then 0 else math.pi, body)
		Voxel.block(b, "SideFin", V(2.0, 0.22, 1.1), CF(side * 2.4, -0.95, -1.3) * CFrame.Angles(0, side * rad(15), side * rad(-22)), color, { Attach = finPivot })
	end

	-- Dorsal fin (the classic shark fin).
	Voxel.block(b, "DorsalFin", V(0.4, 2.1, 2.2), CF(0, 2.35, -0.2), color, { Attach = body, Shape = "Wedge" })

	-- Scars.
	for i = 1, math.min(look.Scars, #SCARS) do
		local scar = SCARS[i]
		Voxel.block(b, "Scar", V(0.06, 0.14, 1.0), CF(scar[1] * 1.52, scar[2], scar[3]) * CFrame.Angles(rad(scar[4]), 0, 0), Color3.fromRGB(230, 170, 170), on)
	end

	-- Tail section on its own joint: it swishes side to side.
	local tail = Voxel.pivot(b, "TailPivot", CF(0, 0, 1.7), "Y", 0.32, 4.5, -0.8, body)
	local onTail = { Attach = tail }
	Voxel.block(b, "Tail", V(2.2, 1.9, 1.6), CF(0, 0.05, 2.5), color, { Attach = tail, Studs = true })
	Voxel.block(b, "TailBelly", V(1.8, 0.4, 1.5), CF(0, -0.85, 2.5), look.Belly, onTail)
	Voxel.block(b, "Tail", V(1.4, 1.2, 1.4), CF(0, 0.15, 3.9), color, onTail)
	Voxel.block(b, "Tail", V(0.8, 0.7, 1.0), CF(0, 0.2, 5.0), color, onTail)
	Voxel.block(b, "TailFin", V(0.3, 2.6, 0.9), CF(0, 1.35, 5.85) * CFrame.Angles(rad(35), 0, 0), color, onTail)
	Voxel.block(b, "TailFin", V(0.3, 1.5, 0.8), CF(0, -0.55, 5.6) * CFrame.Angles(rad(-35), 0, 0), color, onTail)
	Voxel.block(b, "SecondFin", V(0.25, 0.6, 0.6), CF(0, 1.05, 3.9), color, { Attach = tail, Shape = "Wedge" })

	if look.Spikes then
		for _, z in { 1.0, 1.6 } do
			Voxel.block(b, "Spike", V(0.25, 0.5, 0.6), CF(0, 1.55, z), dark, { Attach = body, Shape = "Wedge" })
		end
		for _, z in { 2.7, 3.4 } do
			Voxel.block(b, "Spike", V(0.25, 0.45, 0.5), CF(0, 1.2, z), dark, { Attach = tail, Shape = "Wedge" })
		end
	end

	if look.GlowEyes then
		local light = Instance.new("PointLight")
		light.Name = "EyeGlow"
		light.Color = look.EyeColor
		light.Range = 10 * look.Scale
		light.Brightness = 1.5
		light.Parent = head
		CollectionService:AddTag(light, Constants.Tags.LodEffect)
	end

	-- Red chase glow (off until the shark starts chasing).
	local chaseLight = Instance.new("PointLight")
	chaseLight.Name = "ChaseLight"
	chaseLight.Color = CHASE_COLOR
	chaseLight.Range = 18 * look.Scale
	chaseLight.Brightness = 2.5
	chaseLight.Enabled = false
	chaseLight.Parent = head
end

function SharkModel.build(model: Model, root: BasePart, zoneIndex: number)
	if not (Assets.decorate(root, `Shark{zoneIndex}`, true) or Assets.decorate(root, Config.Bots.ModelName, true)) then
		buildParts(model, root, zoneIndex)
	end

	local glow = Instance.new("Highlight")
	glow.Name = "ChaseGlow"
	glow.FillColor = CHASE_COLOR
	glow.FillTransparency = 0.65
	glow.OutlineColor = Color3.fromRGB(255, 90, 90)
	glow.OutlineTransparency = 0
	glow.DepthMode = Enum.HighlightDepthMode.Occluded
	glow.Enabled = false
	glow.Adornee = model
	glow.Parent = model

	model:SetAttribute("Swims", true) -- the client swims faster when it moves faster
	CollectionService:AddTag(model, Constants.Tags.Animated)
end

-- Chasing on/off (the server calls this when a chase starts/ends). The
-- client (CreatureController) then smoothly turns the shark red and back,
-- with the ChaseGlow highlight and ChaseLight.
function SharkModel.setChasing(model: Model, chasing: boolean)
	model:SetAttribute("Chasing", chasing)
end

return SharkModel
