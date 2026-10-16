--!strict
--[[
	EggModel
	========
	Builds an egg: a blocky egg shape (stacked layers, wide in the middle)
	in its rarity's color, with
	  - a PATTERN per rarity (Config.EggLooks): spots, stripes, swirls,
	    zigzags, glowing cracks, crystals, wings, stars, galaxy, glitch,
	  - a small DETAIL from the zone it came from (Config.Zones[...].EggDetail):
	    a shell, coral, seaweed, rust, glowworms, frost, lava, a tentacle,
	    a bone or void cubes,
	  - more glow and sparkles for rarer eggs (Config.RarityEffects).

	The egg is ONE invisible part (size Config.Eggs.Size) with all the blocks
	welded to it, so the game can treat it like a single part: put it on the
	ground, weld it to a player, use it as a Tool's Handle, wiggle it.

	Custom model: "Egg<Rarity>" (for example "EggLegendary") or "Egg" in
	ReplicatedStorage.Assets (the rarity-specific name is tried first).

	Usage:
		local part = EggModel.create("Rare", 3, true)   -- Rare egg from zone 3, anchored
		local part = EggModel.create("Rare", 3, false)  -- unanchored (to weld to a player / as a Handle)
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local Assets = require(script.Parent.Parent.Assets)
local Voxel = require(script.Parent.Voxel)

type Builder = Voxel.Builder

local EggModel = {}

local V = Vector3.new
local CF = CFrame.new
local rad = math.rad
local WHITE = Color3.new(1, 1, 1)

-- The egg's outline from bottom to top: { width (fraction), height (fraction) }.
local PROFILE = {
	{ 0.62, 0.14 },
	{ 0.88, 0.17 },
	{ 1.0, 0.19 },
	{ 0.94, 0.18 },
	{ 0.76, 0.17 },
	{ 0.46, 0.15 },
}

type Layer = { Width: number, Y: number, Height: number }

-- A point on the egg's surface: layer `index`, around the egg at `angle`
-- (degrees, 0 = +X), pushed out by `out` studs.
local function surface(layers: { Layer }, index: number, angle: number, out: number?, yOffset: number?): Vector3
	local layer = layers[index]
	local a = rad(angle)
	local direction = V(math.cos(a), 0, math.sin(a))
	-- Points on a square's edge (the layers are square).
	local edge = layer.Width / 2 / math.max(math.abs(direction.X), math.abs(direction.Z))
	return direction * (edge + (out or 0)) + V(0, layer.Y + (yOffset or 0), 0)
end

local function cube(b: Builder, name: string, size: number, position: Vector3, color: Color3, options: Voxel.BlockOptions?): BasePart
	return Voxel.block(b, name, V(size, size, size), CF(position), color, options)
end

---------------------------------------------------------------------------
-- Patterns (one per rarity)
---------------------------------------------------------------------------

local function buildPattern(b: Builder, layers: { Layer }, pattern: string, accent: Color3, rainbow: boolean)
	local neon: Voxel.BlockOptions = { Material = Enum.Material.Neon, Rainbow = rainbow }
	if pattern == "Spots" then
		local spots = { { 2, 20 }, { 3, 140 }, { 4, 250 }, { 3, 300 }, { 5, 80 }, { 4, 200 }, { 2, 170 } }
		for _, spot in spots do
			cube(b, "Spot", 0.38, surface(layers, spot[1], spot[2]), accent, { Outline = false })
		end
	elseif pattern == "Stripes" then
		for _, index in { 2, 4 } do
			local layer = layers[index]
			Voxel.block(b, "Stripe", V(layer.Width + 0.08, layer.Height * 0.45, layer.Width + 0.08), CF(0, layer.Y, 0), accent)
		end
	elseif pattern == "Swirl" then
		-- A spiral of blocks winding up the egg.
		for i = 1, 9 do
			local index = math.clamp(1 + math.floor((i - 1) * 5 / 8), 1, 6)
			cube(b, "Swirl", 0.32, surface(layers, index, i * 70), accent, { Outline = false, Rainbow = rainbow })
		end
	elseif pattern == "Zigzag" then
		for i = 0, 7 do
			local up = if i % 2 == 0 then 0.18 else -0.18
			cube(b, "Zigzag", 0.34, surface(layers, 3, i * 45, 0, up), accent, { Outline = false })
		end
	elseif pattern == "Cracks" then
		-- Glowing zigzag cracks on two sides.
		for _, angle in { 90, 270 } do
			for step = 0, 3 do
				local tilt = if step % 2 == 0 then 30 else -30
				local position = surface(layers, 2 + step, angle, 0.02)
				local turn = CFrame.Angles(0, -rad(angle) + math.pi / 2, 0)
				Voxel.block(b, "Crack", V(0.09, 0.55, 0.06), CF(position) * turn * CFrame.Angles(0, 0, rad(tilt)), accent, neon)
			end
		end
	elseif pattern == "Crystals" then
		local crystals = { { 6, 0, 0.25, 15 }, { 5, 60, 0.1, 35 }, { 4, 180, 0.1, -35 }, { 3, 300, 0.1, 30 }, { 5, 230, 0.1, -25 } }
		for _, c in crystals do
			local position = surface(layers, c[1], c[2], c[3])
			Voxel.block(b, "Crystal", V(0.3, 0.75, 0.3), CF(position + V(0, 0.2, 0)) * CFrame.Angles(rad(c[4]), rad(c[2]), rad(c[4] * 0.6)), accent, {
				Material = Enum.Material.Neon,
				Transparency = 0.15,
				Rainbow = rainbow,
			})
		end
	elseif pattern == "Wings" then
		-- Little angel wings that flap, and a golden halo.
		for _, side in { -1, 1 } do
			local layer = layers[4]
			local pivot = Voxel.pivot(b, "WingPivot", CF(side * layer.Width / 2, layer.Y, 0.15), "Z", 0.35, 4, if side > 0 then 0 else math.pi)
			Voxel.block(b, "Wing", V(0.14, 0.55, 0.85), CF(side * (layer.Width / 2 + 0.25), layer.Y + 0.2, 0.15) * CFrame.Angles(0, 0, side * rad(-35)), accent, { Attach = pivot })
			Voxel.block(b, "Wing", V(0.14, 0.4, 0.6), CF(side * (layer.Width / 2 + 0.5), layer.Y + 0.5, 0.2) * CFrame.Angles(0, 0, side * rad(-55)), accent, { Attach = pivot })
		end
		local top = layers[#layers]
		local y = top.Y + top.Height / 2 + 0.45
		local gold = Color3.fromRGB(255, 215, 80)
		for _, z in { -0.4, 0.4 } do
			Voxel.block(b, "Halo", V(0.95, 0.1, 0.14), CF(0, y, z), gold, neon)
		end
		for _, x in { -0.4, 0.4 } do
			Voxel.block(b, "Halo", V(0.14, 0.1, 0.8), CF(x, y, 0), gold, neon)
		end
	elseif pattern == "Stars" or pattern == "Galaxy" then
		local stars = { { 2, 30 }, { 3, 110 }, { 4, 200 }, { 5, 300 }, { 3, 250 }, { 4, 20 }, { 6, 160 } }
		for _, star in stars do
			Voxel.block(b, "Star", V(0.26, 0.26, 0.26), CF(surface(layers, star[1], star[2], 0.02)) * CFrame.Angles(rad(45), rad(45), 0), WHITE, {
				Material = Enum.Material.Neon,
			})
		end
		if pattern == "Galaxy" then
			-- A color-shifting swirl band around the middle.
			for i = 0, 5 do
				cube(b, "GalaxySwirl", 0.3, surface(layers, 3 + (i % 2), i * 60 + 15, 0), accent, neon)
			end
		end
	elseif pattern == "Glitch" then
		local colors = { accent, Color3.fromRGB(255, 0, 200), Color3.fromRGB(0, 255, 255) }
		local glitches = { { 2, 10, 0.3 }, { 3, 95, 0.45 }, { 3, 200, 0.25 }, { 4, 280, 0.4 }, { 5, 40, 0.3 }, { 5, 160, 0.2 }, { 6, 250, 0.35 } }
		for index, g in glitches do
			cube(b, "Glitch", g[3], surface(layers, g[1], g[2], g[3] * 0.3), colors[(index - 1) % #colors + 1], {
				Material = Enum.Material.Neon,
				Rainbow = index == 1,
			})
		end
	end
end

---------------------------------------------------------------------------
-- Zone details (always on the upper half, so they show on half-buried eggs)
---------------------------------------------------------------------------

local function buildDetail(b: Builder, layers: { Layer }, detail: string)
	if detail == "Shell" then
		local pink = Color3.fromRGB(255, 190, 190)
		local position = surface(layers, 5, 30, 0.05)
		Voxel.block(b, "Shell", V(0.5, 0.35, 0.2), CF(position) * CFrame.Angles(0, -rad(30) + math.pi / 2, 0), pink)
		Voxel.block(b, "Shell", V(0.3, 0.18, 0.22), CF(position + V(0, 0.22, 0)) * CFrame.Angles(0, -rad(30) + math.pi / 2, 0), pink:Lerp(WHITE, 0.4))
	elseif detail == "Coral" then
		local coral = Color3.fromRGB(255, 110, 90)
		local base = surface(layers, 5, 300, 0.05)
		Voxel.block(b, "Coral", V(0.18, 0.6, 0.18), CF(base + V(0, 0.2, 0)) * CFrame.Angles(0, 0, rad(-15)), coral)
		Voxel.block(b, "Coral", V(0.15, 0.4, 0.15), CF(base + V(0.15, 0.45, 0)) * CFrame.Angles(0, 0, rad(-50)), coral)
		Voxel.block(b, "Coral", V(0.15, 0.35, 0.15), CF(base + V(-0.12, 0.5, 0.05)) * CFrame.Angles(0, 0, rad(30)), coral)
	elseif detail == "Seaweed" then
		local green = Color3.fromRGB(60, 150, 70)
		Voxel.block(b, "Seaweed", V(0.14, 1.1, 0.22), CF(surface(layers, 4, 180, 0.05) + V(0, 0.2, 0)) * CFrame.Angles(0, 0, rad(10)), green)
		Voxel.block(b, "Seaweed", V(0.14, 0.8, 0.22), CF(surface(layers, 5, 150, 0.05)) * CFrame.Angles(rad(-10), 0, rad(-8)), green:Lerp(WHITE, 0.15))
	elseif detail == "Rust" then
		local rust = Color3.fromRGB(150, 80, 40)
		Voxel.block(b, "Rust", V(0.6, 0.45, 0.06), CF(surface(layers, 4, 270, 0.01)), rust, { Outline = false })
		for index, angle in { 20, 45, 70 } do
			cube(b, "Barnacle", 0.18 + index * 0.02, surface(layers, 4, angle, 0.05), Color3.fromRGB(200, 195, 180))
		end
	elseif detail == "Glowworms" then
		for _, spot in { { 4, 60 }, { 5, 190 }, { 4, 310 } } do
			cube(b, "Glowworm", 0.15, surface(layers, spot[1], spot[2], 0.05), Color3.fromRGB(120, 255, 220), { Material = Enum.Material.Neon })
		end
	elseif detail == "Frost" then
		local ice = Color3.fromRGB(190, 235, 255)
		local top = layers[#layers]
		local y = top.Y + top.Height / 2
		cube(b, "Frost", 0.32, V(0.12, y + 0.1, 0.05), ice, { Material = Enum.Material.Ice })
		cube(b, "Frost", 0.24, V(-0.15, y + 0.05, -0.12), ice, { Material = Enum.Material.Ice })
		cube(b, "Frost", 0.22, surface(layers, 5, 120, 0.02), ice, { Material = Enum.Material.Ice })
	elseif detail == "Lava" then
		local lava = Color3.fromRGB(255, 120, 20)
		for step = 0, 2 do
			Voxel.block(b, "LavaCrack", V(0.08, 0.4, 0.06), CF(surface(layers, 3 + step, 0, 0.02)) * CFrame.Angles(0, math.pi / 2, rad(if step % 2 == 0 then 25 else -25)), lava, {
				Material = Enum.Material.Neon,
			})
		end
	elseif detail == "Tentacle" then
		local purple = Color3.fromRGB(100, 45, 120)
		local base = surface(layers, 4, 0, 0.1)
		Voxel.block(b, "Tentacle", V(0.22, 0.22, 0.9), CF(base), purple)
		Voxel.block(b, "Tentacle", V(0.22, 0.6, 0.22), CF(base + V(0, 0.3, -0.35)), purple)
		Voxel.block(b, "Tentacle", V(0.18, 0.18, 0.35), CF(base + V(0, 0.55, -0.2)), purple:Lerp(WHITE, 0.2))
	elseif detail == "Bones" then
		local bone = Color3.fromRGB(240, 235, 220)
		local center = surface(layers, 4, 180, 0.1)
		Voxel.block(b, "Bone", V(0.14, 0.14, 0.9), CF(center) * CFrame.Angles(rad(30), 0, 0), bone)
		local offset = CFrame.Angles(rad(30), 0, 0) * CF(0, 0, 0.45)
		cube(b, "BoneEnd", 0.24, (CF(center) * offset).Position, bone)
		cube(b, "BoneEnd", 0.24, (CF(center) * CFrame.Angles(rad(30), 0, 0) * CF(0, 0, -0.45)).Position, bone)
	elseif detail == "Void" then
		cube(b, "VoidCube", 0.35, surface(layers, 5, 30, 0.45), Color3.fromRGB(15, 10, 25))
		cube(b, "VoidCube", 0.25, surface(layers, 4, 210, 0.5), Color3.fromRGB(160, 60, 255), { Material = Enum.Material.Neon })
	end
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

function EggModel.create(rarity: string, zoneIndex: number, anchored: boolean): Part
	local root = Instance.new("Part")
	root.Name = `{rarity}Egg`
	root.Size = Config.Eggs.Size
	root.Transparency = 1
	root.Anchored = anchored
	root.CanCollide = false
	root.CanTouch = false
	root.Massless = true
	root:SetAttribute("Rarity", rarity)
	root:SetAttribute(Constants.Attributes.Zone, zoneIndex)

	if Assets.decorate(root, `Egg{rarity}`, not anchored) or Assets.decorate(root, "Egg", not anchored) then
		return root
	end

	local b = Voxel.new(root, root, 1)
	local size = Config.Eggs.Size
	local color = Rarity.color(rarity)
	local look = Config.EggLooks[rarity] or { Pattern = "Spots", Accent = WHITE }
	local rainbow = Voxel.isCosmic(rarity)

	-- Stack the layers from the bottom up.
	local layers: { Layer } = {}
	local y = -size.Y / 2
	for index, entry in PROFILE do
		local width = size.X * entry[1]
		local height = size.Y * entry[2]
		table.insert(layers, { Width = width, Y = y + height / 2, Height = height })
		Voxel.block(b, `Layer{index}`, V(width, height, width), CF(0, y + height / 2, 0), color, { Studs = index == #PROFILE })
		y += height
	end

	buildPattern(b, layers, look.Pattern, look.Accent, rainbow)
	local zone = Config.Zones[zoneIndex]
	if zone then
		buildDetail(b, layers, zone.EggDetail)
	end
	Voxel.rarityEffects(root, rarity, 1.2)
	if b.Pivots > 0 then
		CollectionService:AddTag(root, Constants.Tags.Animated)
	end
	return root
end

return EggModel
