--!strict
--[[
	EggVisual
	=========
	Creates the 3D egg you see on the ground, above a player's head, and on
	the hatch pad.

	Placeholder: an egg-shaped part (a stretched sphere) in the rarity's color.
	Rarer eggs glow more (Config.Rarities[...].Glow).

	Custom models: put a model named "Egg<Rarity>" (for example "EggLegendary")
	or just "Egg" into ReplicatedStorage > Assets. The rarity-specific name is
	tried first.

	Usage:
		local part = EggVisual.create("Rare", true)   -- anchored (lying still)
		local part = EggVisual.create("Rare", false)  -- unanchored (to weld to a player)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local Assets = require(script.Parent.Assets)

local EggVisual = {}

function EggVisual.create(rarity: string, anchored: boolean): Part
	local color = Rarity.color(rarity)

	local egg = Instance.new("Part")
	egg.Name = `{rarity}Egg`
	egg.Size = Config.Eggs.Size
	egg.Color = color
	egg.Material = Enum.Material.SmoothPlastic
	egg.Anchored = anchored
	egg.CanCollide = false
	egg.CanTouch = false
	egg.Massless = true
	egg.TopSurface = Enum.SurfaceType.Smooth
	egg.BottomSurface = Enum.SurfaceType.Smooth
	egg:SetAttribute("Rarity", rarity)

	-- A sphere mesh stretched to the part's size looks like an egg.
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = egg

	local glow = Rarity.glow(rarity)
	if glow > 0 then
		egg.Material = Enum.Material.Neon
		local light = Instance.new("PointLight")
		-- Very dark eggs (like Secret) still cast a visible, bright light.
		light.Color = if color.R + color.G + color.B < 0.5 then Color3.new(1, 1, 1) else color
		light.Range = 4 + glow * Config.Eggs.GlowRangePerLevel
		light.Brightness = glow * Config.Eggs.GlowBrightnessPerLevel
		light.Parent = egg
	end

	if not Assets.decorate(egg, `Egg{rarity}`, not anchored) then
		Assets.decorate(egg, "Egg", not anchored)
	end

	return egg
end

return EggVisual
