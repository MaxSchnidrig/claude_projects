--!strict
--[[
	FishModel
	=========
	Builds the 3D fish for one Config.Fish entry: a cute blocky creature with
	a clear face, made with the Voxel builder.

	A fish = SHAPE (the body) + FACE + PATTERN + FEATURE (see Config.Fish for
	the names). Rarer fish are bigger (Config.PetDisplay.SizePerRarity) and
	get effects (Config.RarityEffects). Tails, fins and tentacles wiggle on
	the client (CreatureController); the whole fish bobs and slowly turns
	(PetController).

	Custom model: a Model in ReplicatedStorage.Assets named exactly like the
	fish (for example "Pinchy Crab") replaces the built-in one.

	Usage:
		local model = FishModel.create(fishConfig, cframe)
		local picture = FishModel.create(fishConfig, CFrame.new(), true)  -- for UI pictures (no effects, no tags)
		-- model.PrimaryPart = invisible anchored "PetRoot" (LookVector = facing)
		-- attributes: Rarity, Zone, Top (height of its top above the root),
		--             Bottom (depth of its lowest point below the root)
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)
local Rarity = require(ReplicatedStorage.Shared.Rarity)
local Assets = require(script.Parent.Parent.Assets)
local Voxel = require(script.Parent.Voxel)

type Builder = Voxel.Builder
type Fish = Config.FishConfig

-- A body box: patterns (stripes, spots, belly) are drawn on these.
type Box = { Size: Vector3, Center: Vector3, Attach: BasePart? }
type Point = { Position: Vector3, Attach: BasePart? }

-- Where things go on a shape (all at size 1, relative to the root; the
-- fish looks toward -Z).
type Anatomy = {
	Boxes: { Box },
	Face: {
		Z: number, -- the front surface the eyes sit on
		EyeX: number,
		EyeY: number,
		EyeSize: number,
		EyeDepth: number?, -- thick eyes (crab eye stalks)
		MouthY: number,
		MouthZ: number,
		MouthWidth: number,
		MouthShape: string?, -- "Smile" (default), "O" or "None"
		Attach: BasePart?,
	},
	HeadTop: Vector3, -- top middle of the head (hats, crowns, halos)
	HeadHalfWidth: number,
	Back: { Point }, -- along the top of the back (spikes, fins, leaves)
	Spots: { Point }?, -- custom spot places (otherwise random on the boxes)
	EffectPart: BasePart, -- lights and particles go here
	Radius: number, -- rough size at scale 1
}

local FishModel = {}

local V = Vector3.new
local CF = CFrame.new
local rad = math.rad
local WHITE = Color3.new(1, 1, 1)
local DARK = Color3.fromRGB(35, 25, 30)

-- Fin-colored parts of the fish being built (they shift colors on the
-- rarest fish).
local fins: { BasePart } = {}

local function fin(b: Builder, name: string, size: Vector3, offset: CFrame, fish: Fish, options: Voxel.BlockOptions?): BasePart
	local part = Voxel.block(b, name, size, offset, fish.Fin, options)
	table.insert(fins, part)
	return part
end

---------------------------------------------------------------------------
-- Shapes
---------------------------------------------------------------------------

type FishLike = { W: number, H: number, L: number, Tail: number, Dorsal: boolean, TallFins: boolean?, Flukes: boolean? }

local FISH_LIKE: { [string]: FishLike } = {
	Fish = { W = 2.0, H = 1.8, L = 2.4, Tail = 1.0, Dorsal = true },
	FishSmall = { W = 1.5, H = 1.4, L = 1.8, Tail = 0.8, Dorsal = true },
	FishLong = { W = 1.3, H = 1.3, L = 3.4, Tail = 0.9, Dorsal = true },
	FishFlat = { W = 0.9, H = 2.4, L = 2.0, Tail = 1.0, Dorsal = true, TallFins = true },
	FishRound = { W = 2.3, H = 2.3, L = 2.1, Tail = 0.8, Dorsal = true },
	FishBig = { W = 2.4, H = 2.1, L = 3.0, Tail = 1.2, Dorsal = true },
	Whale = { W = 2.4, H = 2.0, L = 3.4, Tail = 1.2, Dorsal = false, Flukes = true },
}

local function buildFishLike(b: Builder, fish: Fish, d: FishLike): Anatomy
	local W, H, L = d.W, d.H, d.L
	local body = Voxel.block(b, "Body", V(W, H, L), CF(), fish.Body, { Studs = true })
	local front = -L / 2
	local snoutH = H * 0.45
	-- A smaller snout block in front and a narrower back end: chunky and tapered.
	Voxel.block(b, "Snout", V(W * 0.62, snoutH, 0.35), CF(0, -H * 0.18, front - 0.175), fish.Body)
	Voxel.block(b, "Rear", V(W * 0.72, H * 0.68, 0.45), CF(0, 0, L / 2 + 0.225), fish.Body)

	-- Tail (swishes side to side; whale flukes go up and down).
	local t = d.Tail
	local tail = Voxel.pivot(b, "TailPivot", CF(0, 0, L / 2 + 0.45), if d.Flukes then "X" else "Y", 0.35, 4.5)
	fin(b, "TailStub", V(W * 0.35, H * 0.4, 0.45), CF(0, 0, L / 2 + 0.7), fish, { Attach = tail })
	if d.Flukes then
		for _, side in { -1, 1 } do
			fin(b, "Fluke", V(1.1 * t, 0.2, 0.55 * t), CF(side * 0.5 * t, 0, L / 2 + 1.05) * CFrame.Angles(0, side * rad(-25), 0), fish, { Attach = tail })
		end
	else
		fin(b, "TailFin", V(0.2, 1.1 * t, 0.5 * t), CF(0, 0.42 * t, L / 2 + 0.95 + 0.2 * t) * CFrame.Angles(rad(35), 0, 0), fish, { Attach = tail })
		fin(b, "TailFin", V(0.2, 1.1 * t, 0.5 * t), CF(0, -0.42 * t, L / 2 + 0.95 + 0.2 * t) * CFrame.Angles(rad(-35), 0, 0), fish, { Attach = tail })
	end

	-- Fins on top (and below, for tall flat fish).
	if d.Dorsal then
		local h = if d.TallFins then H * 0.55 else H * 0.38
		fin(b, "DorsalFin", V(0.22, h, L * 0.5), CF(0, H / 2 + h / 2, L * 0.05), fish, { Shape = "Wedge" })
		if d.TallFins then
			fin(b, "BellyFin", V(0.22, h * 0.8, L * 0.4), CF(0, -H / 2 - h * 0.4, L * 0.1) * CFrame.Angles(0, 0, math.pi), fish, { Shape = "Wedge" })
		end
	end
	-- Side fins (flap).
	for _, side in { -1, 1 } do
		local pivot = Voxel.pivot(b, "SideFinPivot", CF(side * W / 2, -H * 0.2, -L * 0.05), "Z", 0.3, 3, if side > 0 then 0 else math.pi)
		fin(b, "SideFin", V(0.55, 0.12, 0.5), CF(side * (W / 2 + 0.25), -H * 0.22, -L * 0.05) * CFrame.Angles(0, 0, side * rad(-20)), fish, { Attach = pivot })
	end

	local eye = math.clamp(math.min(W, H) * 0.27, 0.3, 0.55)
	local backPoints: { Point } = {}
	for i = 0, 3 do
		table.insert(backPoints, { Position = V(0, H / 2, -L * 0.3 + i * L * 0.22) })
	end
	return {
		Boxes = { { Size = V(W, H, L), Center = V(0, 0, 0) } },
		Face = {
			Z = front,
			EyeX = math.min(W * 0.25, W / 2 - eye * 0.55),
			EyeY = H / 2 - eye * 0.7 - 0.08,
			EyeSize = eye,
			MouthY = -H * 0.18 - snoutH * 0.12,
			MouthZ = front - 0.35,
			MouthWidth = W * 0.32,
		},
		HeadTop = V(0, H / 2, -L * 0.25),
		HeadHalfWidth = W / 2,
		Back = backPoints,
		EffectPart = body,
		Radius = math.max(W, H, L) / 2,
	}
end

local function buildEel(b: Builder, fish: Fish): Anatomy
	local head = Voxel.block(b, "Body", V(1.2, 1.1, 1.2), CF(0, 0, -1.5), fish.Body, { Studs = true })
	Voxel.block(b, "Jaw", V(0.9, 0.4, 0.3), CF(0, -0.28, -2.25), fish.Body)
	local boxes: { Box } = { { Size = V(1.2, 1.1, 1.2), Center = V(0, 0, -1.5) } }
	local back: { Point } = { { Position = V(0, 0.55, -1.5) } }

	-- A chain of body segments; each one swings a bit after the one before,
	-- so the eel wiggles like a wave.
	local segments = { V(1.05, 1.0, 0.9), V(0.95, 0.9, 0.85), V(0.85, 0.8, 0.8), V(0.7, 0.65, 0.75) }
	local z = -0.9
	local previous: BasePart? = nil
	for index, size in segments do
		local pivot = Voxel.pivot(b, `Segment{index}`, CF(0, 0, z), "Y", 0.16 + index * 0.03, 3.5, -index * 0.9, previous)
		local center = V(0, 0, z + size.Z / 2)
		Voxel.block(b, "Segment", size, CF(center), fish.Body, { Attach = pivot })
		fin(b, "Ridge", V(0.1, 0.22, size.Z * 0.8), CF(0, size.Y / 2 + 0.11, center.Z), fish, { Attach = pivot })
		table.insert(boxes, { Size = size, Center = center, Attach = pivot })
		table.insert(back, { Position = V(0, size.Y / 2 + 0.2, center.Z), Attach = pivot })
		previous = pivot
		z += size.Z
	end
	fin(b, "TailFin", V(0.12, 0.85, 0.65), CF(0, 0, z + 0.3), fish, { Attach = previous })

	return {
		Boxes = boxes,
		Face = { Z = -2.1, EyeX = 0.3, EyeY = 0.2, EyeSize = 0.32, MouthY = -0.3, MouthZ = -2.4, MouthWidth = 0.5 },
		HeadTop = V(0, 0.55, -1.6),
		HeadHalfWidth = 0.6,
		Back = back,
		EffectPart = head,
		Radius = 2.2,
	}
end

local function buildCrab(b: Builder, fish: Fish): Anatomy
	local body = Voxel.block(b, "Body", V(2.4, 1.1, 1.7), CF(), fish.Body, { Studs = true })
	Voxel.block(b, "Top", V(1.8, 0.35, 1.3), CF(0, 0.72, 0.05), fish.Body)
	for _, side in { -1, 1 } do
		-- Eye stalks (the eyes sit on top, see Face).
		fin(b, "Stalk", V(0.16, 0.5, 0.16), CF(side * 0.45, 0.95, -0.55), fish)
		-- Claws on a joint: they snap open and closed a little.
		local claw = Voxel.pivot(b, "ClawPivot", CF(side * 1.2, 0, -0.5), "Y", 0.25, 2.5, if side > 0 then 0 else math.pi)
		fin(b, "Arm", V(0.6, 0.3, 0.3), CF(side * 1.45, 0, -0.65) * CFrame.Angles(0, side * rad(30), 0), fish, { Attach = claw })
		Voxel.block(b, "Pincer", V(0.6, 0.5, 0.6), CF(side * 1.75, 0.05, -1.0), fish.Body, { Attach = claw })
		Voxel.block(b, "PincerTip", V(0.2, 0.22, 0.45), CF(side * 1.6, 0.12, -1.48), fish.Body, { Attach = claw })
		Voxel.block(b, "PincerTip", V(0.2, 0.22, 0.4), CF(side * 1.92, 0.12, -1.45), fish.Body, { Attach = claw })
		-- Three little legs per side.
		for _, z in { -0.35, 0.15, 0.6 } do
			fin(b, "Leg", V(0.7, 0.14, 0.16), CF(side * 1.4, -0.45, z) * CFrame.Angles(0, 0, side * rad(-35)), fish)
		end
	end
	return {
		Boxes = { { Size = V(2.4, 1.1, 1.7), Center = V(0, 0, 0) } },
		-- Eyes are cubes on top of the stalks.
		Face = { Z = -0.66, EyeX = 0.45, EyeY = 1.4, EyeSize = 0.42, EyeDepth = 0.42, MouthY = 0, MouthZ = -0.85, MouthWidth = 0.6 },
		HeadTop = V(0, 0.9, -0.2),
		HeadHalfWidth = 1.1,
		Back = { { Position = V(-0.5, 0.9, 0.1) }, { Position = V(0, 0.9, 0.3) }, { Position = V(0.5, 0.9, 0.1) } },
		EffectPart = body,
		Radius = 1.6,
	}
end

local function buildStar(b: Builder, fish: Fish): Anatomy
	local body = Voxel.block(b, "Body", V(1.1, 1.1, 0.6), CF(), fish.Body, { Studs = true })
	local spots: { Point } = {}
	for k = 0, 4 do
		local angle = rad(90 + 72 * k)
		local direction = V(math.cos(angle), math.sin(angle), 0)
		local turn = CFrame.Angles(0, 0, angle - math.pi / 2)
		-- The top arm waves hello.
		local attach = if k == 0 then Voxel.pivot(b, "WavePivot", CF(direction * 0.5) * turn, "Z", 0.2, 2) else nil
		Voxel.block(b, "Arm", V(0.6, 1.0, 0.5), CF(direction * 1.0) * turn, fish.Body, { Attach = attach })
		fin(b, "ArmTip", V(0.36, 0.4, 0.42), CF(direction * 1.6) * turn, fish, { Attach = attach })
		table.insert(spots, { Position = direction * 1.05 + V(0, 0, -0.25), Attach = attach })
	end
	return {
		Boxes = { { Size = V(1.1, 1.1, 0.6), Center = V(0, 0, 0) } },
		Face = { Z = -0.3, EyeX = 0.22, EyeY = 0.14, EyeSize = 0.3, MouthY = -0.22, MouthZ = -0.3, MouthWidth = 0.3 },
		HeadTop = V(0, 1.85, 0),
		HeadHalfWidth = 0.4,
		Back = { { Position = V(0, 0.55, 0.1) } },
		Spots = spots,
		EffectPart = body,
		Radius = 1.8,
	}
end

local function buildPuffer(b: Builder, fish: Fish): Anatomy
	local body = Voxel.block(b, "Body", V(2.1, 2.0, 2.1), CF(), fish.Body, { Studs = true })
	-- Diamond-shaped spikes all around.
	local spikes = {
		V(-0.6, 1.05, 0.1), V(0.6, 1.05, 0.1), V(0, 1.05, 0.7),
		V(1.08, 0.45, 0.4), V(1.08, -0.45, -0.3), V(-1.08, 0.45, 0.4), V(-1.08, -0.45, -0.3),
		V(0.5, -1.02, 0.3), V(-0.5, -1.02, 0.3), V(0, 0.4, 1.08),
	}
	for _, position in spikes do
		fin(b, "Spike", V(0.28, 0.28, 0.28), CF(position) * CFrame.Angles(rad(45), rad(45), 0), fish)
	end
	local tail = Voxel.pivot(b, "TailPivot", CF(0, 0, 1.05), "Y", 0.4, 5)
	fin(b, "TailFin", V(0.15, 0.75, 0.55), CF(0, 0, 1.35), fish, { Attach = tail })
	for _, side in { -1, 1 } do
		local pivot = Voxel.pivot(b, "SideFinPivot", CF(side * 1.05, -0.2, -0.2), "Z", 0.45, 6, if side > 0 then 0 else math.pi)
		fin(b, "SideFin", V(0.45, 0.12, 0.4), CF(side * 1.27, -0.2, -0.2), fish, { Attach = pivot })
	end
	return {
		Boxes = { { Size = V(2.1, 2.0, 2.1), Center = V(0, 0, 0) } },
		Face = { Z = -1.05, EyeX = 0.45, EyeY = 0.35, EyeSize = 0.5, MouthY = -0.4, MouthZ = -1.05, MouthWidth = 0.3, MouthShape = "O" },
		HeadTop = V(0, 1.0, -0.4),
		HeadHalfWidth = 1.05,
		Back = { { Position = V(0, 1.0, -0.3) }, { Position = V(0, 1.0, 0.3) } },
		EffectPart = body,
		Radius = 1.3,
	}
end

local function buildTurtle(b: Builder, fish: Fish): Anatomy
	-- The shell uses the Accent color, the skin the Body color.
	local shell = Voxel.block(b, "Shell", V(2.2, 0.8, 2.4), CF(0, 0.15, 0), fish.Accent, { Studs = true })
	Voxel.block(b, "ShellTop", V(1.6, 0.45, 1.8), CF(0, 0.75, 0), fish.Accent, { Studs = true })
	Voxel.block(b, "Belly", V(2.0, 0.4, 2.2), CF(0, -0.42, 0), fish.Body)
	Voxel.block(b, "TurtleHead", V(0.95, 0.85, 0.9), CF(0, 0.05, -1.55), fish.Body)
	for _, side in { -1, 1 } do
		local flipper = Voxel.pivot(b, "FlipperPivot", CF(side * 1.05, -0.2, -0.7), "Z", 0.35, 2.5, if side > 0 then 0 else math.pi)
		fin(b, "Flipper", V(1.0, 0.15, 0.55), CF(side * 1.55, -0.25, -0.75) * CFrame.Angles(0, side * rad(20), 0), fish, { Attach = flipper })
		fin(b, "BackFlipper", V(0.6, 0.15, 0.45), CF(side * 1.2, -0.3, 0.95), fish)
	end
	fin(b, "Tail", V(0.25, 0.2, 0.4), CF(0, -0.25, 1.35), fish)
	return {
		Boxes = { { Size = V(1.6, 0.45, 1.8), Center = V(0, 0.75, 0) } },
		Face = { Z = -2.0, EyeX = 0.22, EyeY = 0.18, EyeSize = 0.28, MouthY = -0.17, MouthZ = -2.0, MouthWidth = 0.35 },
		HeadTop = V(0, 0.48, -1.55),
		HeadHalfWidth = 0.48,
		Back = { { Position = V(0, 0.98, -0.5) }, { Position = V(0, 0.98, 0) }, { Position = V(0, 0.98, 0.5) } },
		EffectPart = shell,
		Radius = 1.4,
	}
end

local function buildSeahorse(b: Builder, fish: Fish): Anatomy
	local body = Voxel.block(b, "Body", V(1.0, 1.6, 1.0), CF(), fish.Body, { Studs = true })
	Voxel.block(b, "Chest", V(0.75, 1.2, 0.25), CF(0, 0.05, -0.6), fish.Accent)
	Voxel.block(b, "SeahorseHead", V(1.0, 0.95, 1.05), CF(0, 1.2, -0.15), fish.Body)
	Voxel.block(b, "Snout", V(0.35, 0.35, 0.6), CF(0, 1.05, -0.95), fish.Body)
	Voxel.block(b, "SnoutTip", V(0.3, 0.3, 0.06), CF(0, 1.05, -1.27), DARK)
	fin(b, "Crest", V(0.15, 0.3, 0.3), CF(0, 1.8, 0.0), fish)
	fin(b, "Crest", V(0.15, 0.22, 0.25), CF(0, 1.75, 0.3), fish)
	-- Curly tail (gently sways).
	local tail = Voxel.pivot(b, "TailPivot", CF(0, -0.8, 0), "X", 0.15, 2)
	Voxel.block(b, "Tail", V(0.75, 0.6, 0.75), CF(0, -1.1, 0.05), fish.Body, { Attach = tail })
	Voxel.block(b, "Tail", V(0.55, 0.5, 0.55), CF(0, -1.55, 0.25), fish.Body, { Attach = tail })
	Voxel.block(b, "Tail", V(0.42, 0.42, 0.42), CF(0, -1.88, 0.05), fish.Body, { Attach = tail })
	fin(b, "TailCurl", V(0.32, 0.32, 0.32), CF(0, -1.82, -0.28), fish, { Attach = tail })
	-- Little fin on the back that flutters fast.
	local dorsal = Voxel.pivot(b, "DorsalPivot", CF(0, 0.1, 0.5), "Y", 0.45, 7)
	fin(b, "DorsalFin", V(0.1, 0.7, 0.45), CF(0, 0.1, 0.72), fish, { Attach = dorsal })
	return {
		Boxes = { { Size = V(1.0, 1.6, 1.0), Center = V(0, 0, 0) } },
		Face = { Z = -0.675, EyeX = 0.28, EyeY = 1.42, EyeSize = 0.28, MouthY = 0, MouthZ = 0, MouthWidth = 0, MouthShape = "None" },
		HeadTop = V(0, 1.68, -0.15),
		HeadHalfWidth = 0.5,
		Back = { { Position = V(0, 1.68, 0.2) }, { Position = V(0.3, 0.8, 0.5) }, { Position = V(-0.3, 0.3, 0.5) } },
		EffectPart = body,
		Radius = 1.6,
	}
end

local function buildJelly(b: Builder, fish: Fish): Anatomy
	local dome = Voxel.block(b, "Body", V(2.1, 0.9, 2.1), CF(0, 0.2, 0), fish.Body, { Transparency = 0.12, Studs = true })
	Voxel.block(b, "DomeTop", V(1.5, 0.5, 1.5), CF(0, 0.85, 0), fish.Body, { Transparency = 0.12 })
	fin(b, "Rim", V(2.3, 0.15, 2.3), CF(0, -0.25, 0), fish, { Transparency = 0.2 })
	for k = 1, 6 do
		local angle = rad(k * 60)
		local base = V(math.cos(angle) * 0.65, -0.3, math.sin(angle) * 0.65)
		local tentacle = Voxel.pivot(b, "TentaclePivot", CF(base), if k % 2 == 0 then "X" else "Z", 0.25, 2.2, k * 1.1)
		fin(b, "Tentacle", V(0.18, 1.0, 0.18), CF(base + V(0, -0.5, 0)), fish, { Attach = tentacle, Transparency = 0.25 })
		fin(b, "TentacleTip", V(0.14, 0.5, 0.14), CF(base * 1.15 + V(0, -1.15, 0)), fish, { Attach = tentacle, Transparency = 0.3 })
	end
	return {
		Boxes = { { Size = V(2.1, 0.9, 2.1), Center = V(0, 0.2, 0) } },
		Face = { Z = -1.05, EyeX = 0.38, EyeY = 0.35, EyeSize = 0.32, MouthY = 0.02, MouthZ = -1.05, MouthWidth = 0.32 },
		HeadTop = V(0, 1.1, 0),
		HeadHalfWidth = 0.75,
		Back = { { Position = V(-0.5, 1.1, 0.2) }, { Position = V(0.5, 1.1, 0.2) } },
		EffectPart = dome,
		Radius = 1.3,
	}
end

local function buildSquid(b: Builder, fish: Fish): Anatomy
	local head = Voxel.block(b, "Body", V(1.7, 1.7, 1.7), CF(0, 0.55, 0), fish.Body, { Studs = true })
	Voxel.block(b, "SquidTop", V(1.2, 0.45, 1.2), CF(0, 1.6, 0.05), fish.Body)
	Voxel.block(b, "Skirt", V(1.5, 0.35, 1.5), CF(0, -0.45, 0), fish.Body)
	for k = 1, 6 do
		local angle = rad(k * 60 + 30)
		local direction = V(math.cos(angle), 0, math.sin(angle))
		local base = direction * 0.55 + V(0, -0.6, 0)
		local tentacle = Voxel.pivot(b, "TentaclePivot", CF(base), if k % 2 == 0 then "X" else "Z", 0.3, 2, k * 1.3)
		Voxel.block(b, "Tentacle", V(0.32, 0.9, 0.32), CF(base + V(0, -0.45, 0)), fish.Body, { Attach = tentacle })
		fin(b, "TentacleTip", V(0.3, 0.3, 0.3), CF(base + direction * 0.2 + V(0, -1.0, 0)), fish, { Attach = tentacle })
	end
	return {
		Boxes = { { Size = V(1.7, 1.7, 1.7), Center = V(0, 0.55, 0) } },
		Face = { Z = -0.85, EyeX = 0.4, EyeY = 0.75, EyeSize = 0.45, MouthY = 0.25, MouthZ = -0.85, MouthWidth = 0.4 },
		HeadTop = V(0, 1.82, 0),
		HeadHalfWidth = 0.85,
		Back = { { Position = V(0, 1.82, 0.2) }, { Position = V(0, 1.4, 0.85) } },
		EffectPart = head,
		Radius = 1.3,
	}
end

local function buildRay(b: Builder, fish: Fish): Anatomy
	local body = Voxel.block(b, "Body", V(1.6, 0.6, 1.8), CF(), fish.Body, { Studs = true })
	local spots: { Point } = { { Position = V(0.4, 0.3, 0.3) }, { Position = V(-0.4, 0.3, 0.3) }, { Position = V(0, 0.3, -0.2) } }
	for _, side in { -1, 1 } do
		-- Wings flap slowly, like a ray gliding.
		local wing = Voxel.pivot(b, "WingPivot", CF(side * 0.8, 0, 0), "Z", 0.3, 2.2, if side > 0 then 0 else math.pi)
		Voxel.block(b, "Wing", V(1.0, 0.35, 1.4), CF(side * 1.3, 0, 0.05), fish.Body, { Attach = wing })
		fin(b, "WingTip", V(0.7, 0.25, 0.8), CF(side * 2.1, 0, 0.15), fish, { Attach = wing })
		table.insert(spots, { Position = V(side * 1.35, 0.17, 0.1), Attach = wing })
	end
	local tail = Voxel.pivot(b, "TailPivot", CF(0, 0, 0.9), "Y", 0.3, 3)
	fin(b, "Tail", V(0.14, 0.14, 1.8), CF(0, 0.05, 1.8), fish, { Attach = tail })
	fin(b, "TailTip", V(0.1, 0.35, 0.3), CF(0, 0.15, 2.6), fish, { Attach = tail })
	return {
		Boxes = { { Size = V(1.6, 0.6, 1.8), Center = V(0, 0, 0) } },
		Face = { Z = -0.9, EyeX = 0.4, EyeY = 0.12, EyeSize = 0.3, MouthY = -0.17, MouthZ = -0.9, MouthWidth = 0.4 },
		HeadTop = V(0, 0.3, -0.45),
		HeadHalfWidth = 0.8,
		Back = { { Position = V(0, 0.3, -0.2) }, { Position = V(0, 0.3, 0.3) } },
		Spots = spots,
		EffectPart = body,
		Radius = 1.6,
	}
end

local function buildShape(b: Builder, fish: Fish): Anatomy
	local fishLike = FISH_LIKE[fish.Shape]
	if fishLike then
		return buildFishLike(b, fish, fishLike)
	end
	local shape = fish.Shape
	if shape == "Eel" then
		return buildEel(b, fish)
	elseif shape == "Crab" then
		return buildCrab(b, fish)
	elseif shape == "Star" then
		return buildStar(b, fish)
	elseif shape == "Puffer" then
		return buildPuffer(b, fish)
	elseif shape == "Turtle" then
		return buildTurtle(b, fish)
	elseif shape == "Seahorse" then
		return buildSeahorse(b, fish)
	elseif shape == "Jelly" then
		return buildJelly(b, fish)
	elseif shape == "Squid" then
		return buildSquid(b, fish)
	elseif shape == "Ray" then
		return buildRay(b, fish)
	end
	warn(`[{Config.GameName}] Unknown fish Shape "{shape}" for {fish.Name}; using "Fish".`)
	return buildFishLike(b, fish, FISH_LIKE.Fish)
end

---------------------------------------------------------------------------
-- Face
---------------------------------------------------------------------------

local function buildFace(b: Builder, anatomy: Anatomy)
	local face = anatomy.Face
	local attach = face.Attach
	local e = face.EyeSize
	local depth = face.EyeDepth or 0.1
	local front = face.Z - 0.1 -- front of the eye whites
	for _, side in { -1, 1 } do
		local x = side * face.EyeX
		Voxel.block(b, "EyeWhite", V(e, e * 1.15, depth), CF(x, face.EyeY, front + depth / 2), WHITE, { Attach = attach, Outline = false })
		-- Pupils look a little inward: cute!
		local pupilX = x - side * e * 0.08
		Voxel.block(b, "Pupil", V(e * 0.55, e * 0.68, 0.06), CF(pupilX, face.EyeY - e * 0.08, front - 0.03), DARK, { Attach = attach })
		Voxel.block(b, "Shine", V(e * 0.2, e * 0.2, 0.04), CF(pupilX - e * 0.1, face.EyeY + e * 0.1, front - 0.07), WHITE, { Attach = attach })
	end

	local shape = face.MouthShape or "Smile"
	if shape == "Smile" then
		local w = face.MouthWidth
		Voxel.block(b, "Mouth", V(w, 0.1, 0.06), CF(0, face.MouthY, face.MouthZ - 0.03), DARK, { Attach = attach })
		for _, side in { -1, 1 } do
			Voxel.block(b, "Mouth", V(0.1, 0.1, 0.06), CF(side * (w / 2 + 0.04), face.MouthY + 0.07, face.MouthZ - 0.03), DARK, { Attach = attach })
		end
	elseif shape == "O" then
		Voxel.block(b, "Mouth", V(face.MouthWidth, face.MouthWidth * 0.8, 0.06), CF(0, face.MouthY, face.MouthZ - 0.03), DARK, { Attach = attach })
	end
end

---------------------------------------------------------------------------
-- Patterns
---------------------------------------------------------------------------

-- Random spots on the sides and top of the body boxes (the same for every
-- copy of a fish, because the random numbers start from the fish's name).
local function surfacePoints(anatomy: Anatomy, count: number, random: Random): { Point }
	if anatomy.Spots then
		local result: { Point } = {}
		for i = 1, count do
			table.insert(result, anatomy.Spots[(i - 1) % #anatomy.Spots + 1])
		end
		return result
	end
	local result: { Point } = {}
	for i = 1, count do
		local box = anatomy.Boxes[(i - 1) % #anatomy.Boxes + 1]
		local size, center = box.Size, box.Center
		local u = random:NextNumber(-0.32, 0.32)
		local v = random:NextNumber(-0.3, 0.3)
		local side = i % 3
		local offset
		if side == 0 then
			offset = V(u * size.X, size.Y / 2, v * size.Z)
		elseif side == 1 then
			offset = V(size.X / 2, v * size.Y, u * size.Z)
		else
			offset = V(-size.X / 2, v * size.Y, u * size.Z)
		end
		table.insert(result, { Position = center + offset, Attach = box.Attach })
	end
	return result
end

local function bands(b: Builder, anatomy: Anatomy, color: Color3, thickness: number, count: number, rainbow: boolean)
	if #anatomy.Boxes > 1 then
		-- Segmented bodies: a band on every other segment.
		for index, box in anatomy.Boxes do
			if index % 2 == 0 then
				local size = box.Size
				Voxel.block(b, "Stripe", V(size.X + 0.08, size.Y + 0.08, math.min(0.3, size.Z * 0.5)), CF(box.Center), color, { Attach = box.Attach, Rainbow = rainbow })
			end
		end
		return
	end
	local box = anatomy.Boxes[1]
	local size = box.Size
	for i = 1, count do
		local z = box.Center.Z + size.Z * ((i - 0.5) / count - 0.5) * 0.9
		Voxel.block(b, "Stripe", V(size.X + 0.08, size.Y + 0.08, math.max(thickness, size.Z * 0.1)), CF(box.Center.X, box.Center.Y, z), color, { Attach = box.Attach, Rainbow = rainbow })
	end
end

local function cubes(b: Builder, points: { Point }, size: number, color: Color3, options: Voxel.BlockOptions?, rotate: boolean?)
	for _, point in points do
		local o: Voxel.BlockOptions = table.clone(options or {})
		o.Attach = point.Attach
		local rotation = if rotate then CFrame.Angles(rad(45), rad(45), 0) else CFrame.identity
		Voxel.block(b, "Spot", V(size, size, size), CF(point.Position) * rotation, color, o)
	end
end

local function buildPattern(b: Builder, anatomy: Anatomy, fish: Fish, random: Random)
	local pattern = fish.Pattern
	local mainBox = anatomy.Boxes[1]
	local spotSize = math.clamp(math.min(mainBox.Size.X, mainBox.Size.Y, mainBox.Size.Z) * 0.22, 0.22, 0.4)
	if pattern == "Stripes" then
		bands(b, anatomy, fish.Accent, 0.25, 2, false)
	elseif pattern == "Rainbow" then
		bands(b, anatomy, fish.Accent, 0.25, 3, true)
	elseif pattern == "Ribs" then
		bands(b, anatomy, fish.Accent, 0.12, 3, false)
	elseif pattern == "Spots" then
		cubes(b, surfacePoints(anatomy, 6, random), spotSize, fish.Accent, { Outline = false })
	elseif pattern == "GlowSpots" then
		cubes(b, surfacePoints(anatomy, 6, random), spotSize, fish.Accent, { Material = Enum.Material.Neon })
	elseif pattern == "Stars" then
		cubes(b, surfacePoints(anatomy, 7, random), spotSize * 0.8, fish.Accent, { Material = Enum.Material.Neon }, true)
	elseif pattern == "Glitch" then
		local colors = { fish.Accent, fish.Fin, Color3.fromRGB(255, 0, 200), Color3.fromRGB(0, 255, 255) }
		for index, point in surfacePoints(anatomy, 8, random) do
			local size = random:NextNumber(0.15, 0.45)
			local nudge = V(random:NextNumber(-0.15, 0.15), random:NextNumber(-0.15, 0.15), random:NextNumber(-0.15, 0.15))
			Voxel.block(b, "Glitch", V(size, size, size), CF(point.Position + nudge), colors[(index - 1) % #colors + 1], {
				Attach = point.Attach,
				Material = Enum.Material.Neon,
				Rainbow = index == 1,
			})
		end
	elseif pattern == "Belly" then
		local size = mainBox.Size
		Voxel.block(b, "Belly", V(size.X + 0.04, size.Y * 0.3, size.Z * 0.85), CF(mainBox.Center + V(0, -size.Y / 2 + size.Y * 0.15 - 0.02, 0)), fish.Accent, { Attach = mainBox.Attach })
	end
end

---------------------------------------------------------------------------
-- Features
---------------------------------------------------------------------------

local GOLD = Color3.fromRGB(255, 200, 40)

local function buildFeature(b: Builder, anatomy: Anatomy, fish: Fish, model: Model)
	local feature = fish.Feature
	local face = anatomy.Face
	local top = anatomy.HeadTop
	local hw = anatomy.HeadHalfWidth
	local e = face.EyeSize
	local fa = face.Attach
	-- Hats scale with the head.
	local hat = math.clamp(hw * 0.9, 0.55, 1.1)

	if feature == "Sunglasses" then
		local z = face.Z - 0.17
		Voxel.block(b, "Glasses", V(face.EyeX * 2 + e * 1.3, 0.1, 0.06), CF(0, face.EyeY + e * 0.4, z), DARK, { Attach = fa })
		for _, side in { -1, 1 } do
			Voxel.block(b, "Lens", V(e * 1.15, e * 0.8, 0.06), CF(side * face.EyeX, face.EyeY, z), Color3.fromRGB(15, 15, 20), { Attach = fa, Reflectance = 0.3 })
		end
	elseif feature == "Crown" then
		Voxel.block(b, "Crown", V(0.9, 0.22, 0.9) * hat, CF(top + V(0, 0.11 * hat, 0)), GOLD, { Reflectance = 0.2 })
		for _, x in { -1, 1 } do
			for _, z in { -1, 1 } do
				Voxel.block(b, "CrownPoint", V(0.18, 0.28, 0.18) * hat, CF(top + V(x * 0.36, 0.36, z * 0.36) * hat), GOLD, { Reflectance = 0.2 })
			end
		end
		Voxel.block(b, "Gem", V(0.18, 0.18, 0.06) * hat, CF(top + V(0, 0.11, -0.46) * hat), Color3.fromRGB(255, 40, 80), { Material = Enum.Material.Neon })
	elseif feature == "Spikes" then
		for _, point in anatomy.Back do
			fin(b, "Spike", V(0.15, 0.42, 0.35), CF(point.Position + V(0, 0.2, 0)), fish, { Shape = "Wedge", Attach = point.Attach })
		end
	elseif feature == "Headphones" then
		local grey = Color3.fromRGB(40, 40, 50)
		Voxel.block(b, "Headband", V(hw * 2 + 0.3, 0.14, 0.25), CF(top + V(0, 0.08, 0)), grey)
		for _, side in { -1, 1 } do
			Voxel.block(b, "Headband", V(0.14, 0.5, 0.25), CF(top + V(side * (hw + 0.08), -0.18, 0)), grey)
			Voxel.block(b, "EarCup", V(0.3, 0.6, 0.6), CF(top + V(side * (hw + 0.15), -0.6, 0)), fish.Accent)
		end
	elseif feature == "PirateHat" then
		local black = Color3.fromRGB(25, 25, 30)
		Voxel.block(b, "HatBrim", V(1.4, 0.18, 0.9) * hat, CF(top + V(0, 0.09 * hat, 0)), black)
		Voxel.block(b, "Hat", V(0.9, 0.4, 0.65) * hat, CF(top + V(0, 0.38, 0.05) * hat), black)
		Voxel.block(b, "Skull", V(0.22, 0.22, 0.05) * hat, CF(top + V(0, 0.4, -0.29) * hat), WHITE)
	elseif feature == "Eyepatch" then
		local black = Color3.fromRGB(20, 20, 25)
		Voxel.block(b, "Eyepatch", V(e * 1.25, e * 1.3, 0.06), CF(-face.EyeX, face.EyeY, face.Z - 0.2), black, { Attach = fa })
		Voxel.block(b, "Strap", V(hw * 2 + 0.1, 0.08, 0.05), CF(0, face.EyeY + e * 0.45, face.Z - 0.17) * CFrame.Angles(0, 0, rad(-18)), black, { Attach = fa })
	elseif feature == "Ghost" then
		-- See-through body (the face stays solid so it's still cute).
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") and part.Transparency < 0.5 and part.Name ~= "EyeWhite" and part.Name ~= "Pupil" and part.Name ~= "Shine" then
				part.Transparency = 0.4
				part.Material = Enum.Material.Neon
			end
		end
	elseif feature == "Nightcap" then
		local blue = Color3.fromRGB(70, 90, 200)
		Voxel.block(b, "CapTrim", V(0.95, 0.14, 0.95) * hat, CF(top + V(0, 0.07, 0) * hat), WHITE)
		Voxel.block(b, "Cap", V(0.8, 0.3, 0.8) * hat, CF(top + V(0.05, 0.28, 0) * hat), blue)
		Voxel.block(b, "Cap", V(0.58, 0.3, 0.58) * hat, CF(top + V(0.17, 0.55, 0) * hat), blue)
		Voxel.block(b, "Cap", V(0.38, 0.3, 0.38) * hat, CF(top + V(0.32, 0.8, 0) * hat), blue)
		Voxel.block(b, "Pompom", V(0.26, 0.26, 0.26) * hat, CF(top + V(0.5, 0.98, 0) * hat), WHITE)
	elseif feature == "Fangs" then
		for _, side in { -1, 1 } do
			Voxel.block(b, "Fang", V(0.1, 0.22, 0.07), CF(side * math.max(face.MouthWidth * 0.3, 0.1), face.MouthY - 0.14, face.MouthZ - 0.05), WHITE, { Attach = fa })
		end
	elseif feature == "Horn" then
		local ivory = Color3.fromRGB(250, 245, 220)
		local y = face.EyeY - e * 0.6
		Voxel.block(b, "Horn", V(0.22, 0.22, 1.6), CF(0, y, face.Z - 0.8), ivory, { Attach = fa })
		Voxel.block(b, "HornRing", V(0.28, 0.28, 0.1), CF(0, y, face.Z - 0.45), ivory:Lerp(DARK, 0.2), { Attach = fa })
		Voxel.block(b, "HornRing", V(0.25, 0.25, 0.1), CF(0, y, face.Z - 0.95), ivory:Lerp(DARK, 0.2), { Attach = fa })
		Voxel.block(b, "HornTip", V(0.12, 0.12, 0.3), CF(0, y, face.Z - 1.75), ivory, { Attach = fa })
	elseif feature == "Halo" then
		local y = top.Y + 0.75
		local options: Voxel.BlockOptions = { Material = Enum.Material.Neon }
		for _, z in { -0.43, 0.43 } do
			Voxel.block(b, "Halo", V(1.0, 0.1, 0.14) * hat, CF(V(top.X, y, top.Z) + V(0, 0, z) * hat), GOLD, options)
		end
		for _, x in { -0.43, 0.43 } do
			Voxel.block(b, "Halo", V(0.14, 0.1, 0.86) * hat, CF(V(top.X, y, top.Z) + V(x, 0, 0) * hat), GOLD, options)
		end
	elseif feature == "Lure" then
		-- The anglerfish light: a stalk with a glowing bulb that bobs.
		Voxel.block(b, "LureStalk", V(0.1, 0.7, 0.1), CF(top + V(0, 0.35, 0)), fish.Fin)
		local lure = Voxel.pivot(b, "LurePivot", CF(top + V(0, 0.7, 0)), "X", 0.25, 2.5)
		Voxel.block(b, "LureStalk", V(0.1, 0.1, 0.65), CF(top + V(0, 0.7, -0.3)), fish.Fin, { Attach = lure })
		local bulb = Voxel.block(b, "LureBulb", V(0.38, 0.38, 0.38), CF(top + V(0, 0.52, -0.62)), fish.Accent, { Attach = lure, Material = Enum.Material.Neon })
		local light = Instance.new("PointLight")
		light.Color = fish.Accent
		light.Range = 10
		light.Brightness = 2
		light.Parent = bulb
		CollectionService:AddTag(light, Constants.Tags.LodEffect)
	elseif feature == "SharkFin" then
		local middle = anatomy.Back[math.max(1, math.floor(#anatomy.Back / 2))]
		fin(b, "SharkFin", V(0.25, 1.1, 1.2), CF(middle.Position + V(0, 0.55, 0)), fish, { Shape = "Wedge", Attach = middle.Attach })
	elseif feature == "Leaves" then
		local leaf = fish.Accent
		for index, point in anatomy.Back do
			local side = if index % 2 == 0 then 1 else -1
			Voxel.block(b, "Leaf", V(0.55, 0.12, 0.32), CF(point.Position + V(side * 0.3, 0.12, 0)) * CFrame.Angles(0, 0, side * rad(40)), leaf, { Attach = point.Attach })
			Voxel.block(b, "Leaf", V(0.4, 0.12, 0.28), CF(point.Position + V(-side * 0.25, 0.2, 0.15)) * CFrame.Angles(0, 0, -side * rad(50)), leaf:Lerp(WHITE, 0.2), { Attach = point.Attach })
		end
	elseif feature == "Shell" then
		local middle = anatomy.Back[math.max(1, math.floor(#anatomy.Back / 2))]
		local base = middle.Position
		local light = fish.Accent:Lerp(WHITE, 0.3)
		Voxel.block(b, "Shell", V(1.2, 1.0, 1.1), CF(base + V(0, 0.45, 0.2)), fish.Accent, { Attach = middle.Attach })
		Voxel.block(b, "Shell", V(0.8, 0.7, 0.8), CF(base + V(0, 1.1, 0.35)), light, { Attach = middle.Attach })
		Voxel.block(b, "Shell", V(0.45, 0.45, 0.45), CF(base + V(0, 1.6, 0.45)), fish.Accent, { Attach = middle.Attach })
	end
end

---------------------------------------------------------------------------
-- Public
---------------------------------------------------------------------------

local function nameSeed(name: string): number
	local seed = 0
	for i = 1, #name do
		seed = (seed * 31 + string.byte(name, i)) % 2147483647
	end
	return seed
end

-- How big a fish of this rarity is (1 = Common).
function FishModel.scale(rarity: string): number
	return 1 + (math.max(Rarity.rank(rarity), 1) - 1) * Config.PetDisplay.SizePerRarity
end

function FishModel.create(fish: Fish, cframe: CFrame, preview: boolean?): Model
	local model = Instance.new("Model")
	model.Name = fish.Name

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

	if not (Assets.decorate(root, fish.Name) or Assets.decorate(root, fish.Id)) then
		local scale = FishModel.scale(fish.Rarity)
		local b = Voxel.new(model, root, scale)
		table.clear(fins)
		local anatomy = buildShape(b, fish)
		buildFace(b, anatomy)
		buildPattern(b, anatomy, fish, Random.new(nameSeed(fish.Id)))
		buildFeature(b, anatomy, fish, model)
		if not preview then
			Voxel.rarityEffects(anatomy.EffectPart, fish.Rarity, anatomy.Radius * scale)
		end
		if Voxel.isCosmic(fish.Rarity) and not preview then
			for _, part in fins do
				CollectionService:AddTag(part, Constants.Tags.RainbowPart)
			end
		end
		table.clear(fins)
		if b.Pivots > 0 and not preview then
			CollectionService:AddTag(model, Constants.Tags.Animated)
		end
	end

	-- How far the fish reaches above and below its root (for placing it on a
	-- pad and putting its name label on top).
	local boxCFrame, boxSize = model:GetBoundingBox()
	local relative = cframe:PointToObjectSpace(boxCFrame.Position)
	model:SetAttribute("Top", relative.Y + boxSize.Y / 2)
	model:SetAttribute("Bottom", -(relative.Y - boxSize.Y / 2))
	model:SetAttribute("Rarity", fish.Rarity)
	model:SetAttribute(Constants.Attributes.Zone, fish.Zone)
	if not preview then
		CollectionService:AddTag(model, Constants.Tags.PetModel)
	end
	return model
end

return FishModel
