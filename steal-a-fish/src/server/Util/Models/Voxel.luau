--!strict
--[[
	Voxel
	=====
	The shared model builder for fish, eggs and sharks. Everything is made of
	chunky blocks (like Roblox "voxel" pets), with thin dark outlines and
	studs on the big blocks.

	How a model is put together:
	  - One ROOT part (invisible) is the model's position. Every block is
	    welded to the root, so moving the root moves the whole creature.
	  - Moving pieces (tails, fins, tentacles, wings) hang on a small
	    invisible PIVOT part, joined with a Motor6D named "Wiggle". The client
	    (CreatureController) swings these joints to animate the creature. The
	    joint's attributes say how: Axis ("X"/"Y"/"Z"), Amount (radians),
	    Speed and Phase.
	  - Offsets are given at size 1 and multiplied by the builder's Scale,
	    so the same recipe makes small and big creatures.

	Usage:
		local b = Voxel.new(model, rootPart, 1.3)
		local tail = Voxel.pivot(b, "TailPivot", CFrame.new(0, 0, 1.5), "Y", 0.35, 5)
		Voxel.block(b, "Body", Vector3.new(2, 2, 3), CFrame.new(), color, { Studs = true })
		Voxel.block(b, "Tail", Vector3.new(0.2, 1.5, 1), CFrame.new(0, 0, 2), color, { Attach = tail })
		Voxel.rarityEffects(bodyPart, "Mythic", 2)
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local Build = require(script.Parent.Parent.Build)

export type Builder = {
	Container: Instance, -- where new parts go (a Model, or the root part itself)
	Root: BasePart,
	Scale: number,
	Pivots: number, -- how many Wiggle joints were made (0 = nothing to animate)
}

export type BlockOptions = {
	Shape: string?, -- "Block" (default), "Wedge" or "CornerWedge"
	Material: Enum.Material?,
	Transparency: number?,
	Reflectance: number?,
	Outline: boolean?, -- default: yes for solid blocks at least 0.5 studs big
	Studs: boolean?, -- studs on the top face
	Attach: BasePart?, -- weld to this part (a pivot) instead of the root
	Rainbow: boolean?, -- the client cycles its color through the rainbow
}

local Voxel = {}

local BLACK = Color3.new(0, 0, 0)

function Voxel.new(container: Instance, root: BasePart, scale: number): Builder
	return { Container = container, Root = root, Scale = scale, Pivots = 0 }
end

-- Where an offset (given at size 1, relative to the root) ends up in the world.
function Voxel.place(b: Builder, offset: CFrame): CFrame
	return b.Root.CFrame * (offset.Rotation + offset.Position * b.Scale)
end

-- Join `part` rigidly to `anchor`, keeping its current position.
local function weld(anchor: BasePart, part: BasePart)
	local joint = Instance.new("Weld")
	joint.Part0 = anchor
	joint.Part1 = part
	joint.C0 = anchor.CFrame:ToObjectSpace(part.CFrame)
	joint.Parent = part
end

local function decorPart(part: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

-- One block. Size and offset are at size 1 (multiplied by the builder's Scale).
function Voxel.block(b: Builder, name: string, size: Vector3, offset: CFrame, color: Color3, options: BlockOptions?): BasePart
	local o: BlockOptions = options or {}
	local part: BasePart
	if o.Shape == "Wedge" then
		part = Instance.new("WedgePart")
	elseif o.Shape == "CornerWedge" then
		part = Instance.new("CornerWedgePart")
	else
		part = Instance.new("Part")
	end
	part.Name = name
	part.Size = size * b.Scale
	part.CFrame = Voxel.place(b, offset)
	part.Color = color
	part.Material = o.Material or Enum.Material.SmoothPlastic
	part.Transparency = o.Transparency or 0
	part.Reflectance = o.Reflectance or 0
	decorPart(part)
	weld(o.Attach or b.Root, part)

	local solid = part.Transparency < 0.1 and part.Material ~= Enum.Material.Neon
	local bigEnough = math.min(size.X, size.Y, size.Z) * b.Scale >= 0.5
	local outline = if o.Outline ~= nil then o.Outline else (solid and bigEnough and o.Shape == nil)
	if outline and Config.RarityEffects.Outlines then
		local box = Instance.new("SelectionBox")
		box.Adornee = part
		box.LineThickness = 0.03 * b.Scale
		box.Color3 = color:Lerp(BLACK, 0.6)
		box.Transparency = 0.25
		box.SurfaceTransparency = 1
		box.Parent = part
	end
	if o.Studs then
		Build.addStuds(part, { Enum.NormalId.Top })
	end
	if o.Rainbow then
		CollectionService:AddTag(part, Constants.Tags.RainbowPart)
	end
	part.Parent = b.Container
	return part
end

-- An invisible pivot with a "Wiggle" joint. Blocks attached to it swing
-- around it (axis "X", "Y" or "Z" of the pivot, by up to `amount` radians).
function Voxel.pivot(
	b: Builder,
	name: string,
	offset: CFrame,
	axis: string,
	amount: number,
	speed: number,
	phase: number?,
	attach: BasePart?
): BasePart
	local pivot = Instance.new("Part")
	pivot.Name = name
	pivot.Size = Vector3.new(0.2, 0.2, 0.2)
	pivot.Transparency = 1
	pivot.CFrame = Voxel.place(b, offset)
	decorPart(pivot)

	local parent = attach or b.Root
	local joint = Instance.new("Motor6D")
	joint.Name = "Wiggle"
	joint.Part0 = parent
	joint.Part1 = pivot
	joint.C0 = parent.CFrame:ToObjectSpace(pivot.CFrame)
	joint.C1 = CFrame.identity
	joint:SetAttribute("Axis", axis)
	joint:SetAttribute("Amount", amount)
	joint:SetAttribute("Speed", speed)
	joint:SetAttribute("Phase", phase or 0)
	joint.Parent = pivot
	pivot.Parent = b.Container
	b.Pivots += 1
	return pivot
end

local function isAtLeast(rarity: string, threshold: string): boolean
	return Rarity.rank(rarity) >= Rarity.rank(threshold)
end

local function lodTag(effect: Instance)
	CollectionService:AddTag(effect, Constants.Tags.LodEffect)
end

-- A color that still shows up as light/particles (Secret is almost black).
local function visibleColor(color: Color3): Color3
	if color.R + color.G + color.B < 0.6 then
		return Color3.fromRGB(200, 190, 255)
	end
	return color:Lerp(Color3.new(1, 1, 1), 0.25)
end

-- Glow, sparkles, aura and cosmic particles, depending on the rarity (see
-- Config.RarityEffects). `radius` = roughly how big the creature is (studs).
function Voxel.rarityEffects(part: BasePart, rarity: string, radius: number)
	local fx = Config.RarityEffects
	local color = visibleColor(Rarity.color(rarity))
	local glow = Rarity.glow(rarity)

	if isAtLeast(rarity, fx.GlowFrom) then
		local light = Instance.new("PointLight")
		light.Name = "RarityGlow"
		light.Color = color
		light.Range = 5 + glow * 2 + radius
		light.Brightness = 0.6 + glow * 0.35
		light.Shadows = false
		light.Parent = part
		lodTag(light)
	end

	if isAtLeast(rarity, fx.SparklesFrom) then
		local sparkles = Instance.new("ParticleEmitter")
		sparkles.Name = "Sparkles"
		sparkles.Texture = fx.SparkleTexture
		sparkles.Color = ColorSequence.new(color)
		sparkles.LightEmission = 1
		sparkles.Rate = 2 + Rarity.rank(rarity)
		sparkles.Lifetime = NumberRange.new(0.8, 1.4)
		sparkles.Speed = NumberRange.new(0.5, 1.5)
		sparkles.SpreadAngle = Vector2.new(180, 180)
		sparkles.Shape = Enum.ParticleEmitterShape.Box
		sparkles.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
		sparkles.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.3, 0.3 + radius * 0.06),
			NumberSequenceKeypoint.new(1, 0),
		})
		sparkles.Parent = part
		lodTag(sparkles)
	end

	if isAtLeast(rarity, fx.AuraFrom) then
		local aura = Instance.new("ParticleEmitter")
		aura.Name = "Aura"
		aura.Texture = fx.AuraTexture
		aura.Color = ColorSequence.new(color)
		aura.LightEmission = 1
		aura.LockedToPart = true
		aura.Rate = 3
		aura.Lifetime = NumberRange.new(1.4, 2)
		aura.Speed = NumberRange.new(0, 0)
		aura.RotSpeed = NumberRange.new(-30, 30)
		aura.Rotation = NumberRange.new(0, 360)
		aura.Size = NumberSequence.new(radius * 1.4, radius * 2.1)
		aura.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.3, 0.82),
			NumberSequenceKeypoint.new(1, 1),
		})
		aura.Parent = part
		lodTag(aura)
	end

	if isAtLeast(rarity, fx.CosmicFrom) then
		local cosmic = Instance.new("ParticleEmitter")
		cosmic.Name = "Cosmic"
		cosmic.Texture = fx.SparkleTexture
		cosmic.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 80, 200)),
			ColorSequenceKeypoint.new(0.33, Color3.fromRGB(120, 120, 255)),
			ColorSequenceKeypoint.new(0.66, Color3.fromRGB(80, 255, 230)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 240, 120)),
		})
		cosmic.LightEmission = 1
		cosmic.Rate = 8
		cosmic.Lifetime = NumberRange.new(1, 2)
		cosmic.Speed = NumberRange.new(1.5, 3.5)
		cosmic.SpreadAngle = Vector2.new(360, 360)
		cosmic.RotSpeed = NumberRange.new(-120, 120)
		cosmic.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(1, 0),
		})
		cosmic.Parent = part
		lodTag(cosmic)
	end
end

-- True if this rarity gets color-shifting details.
function Voxel.isCosmic(rarity: string): boolean
	return isAtLeast(rarity, Config.RarityEffects.CosmicFrom)
end

return Voxel
