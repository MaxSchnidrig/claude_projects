--!strict
-- Original blocky mob designs, built from Parts in code (no imported models or textures).
--
-- Each design is a list of boxes in BLOCK units, relative to the mob's feet centre, facing -Z.
-- Boxes with `limb` swing around a hinge while walking; `glow` parts are Neon accents.
--
--   Zombie      pale grey-violet skin, rust-brown tattered tunic, mismatched amber eyes, arms out
--   Skeleton    chunky skull with a jaw and glowing pale-blue eye squares, slatted ribcage,
--               crude bow in one hand
--   Spider      dark-brown two-part body with orange stripes, cluster of amber eyes, 8 thin legs
--   Sneaker  squat ash-grey barrel on two stumpy legs, short arms, glowing ember crack lines
--               and a single horizontal ember slit for an eye (glows hotter while fusing)
--   Voidling   legless floating violet crystal figure: glassy core, diamond-shaped glowing head,
--               shard "arms" orbiting it, a tapering crystal trail below, a block hovering in front
--   Cow         tawny with a dark back stripe, cream belly patch, small curved horns
--   Pig         dusky pink-grey with a bristly darker ridge and little tusk nubs
--   Sheep       cream wool with a charcoal face and legs
--   Chicken     brown speckled hen, red comb, yellow beak and legs, flapping wings
--   Arrow       shaft, grey tip, pale fletching

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared").Config)
local BS = Config.BLOCK_SIZE

export type Box = {
	size: Vector3,
	pos: Vector3, -- centre, relative to the feet centre
	color: Color3,
	material: Enum.Material?,
	transparency: number?,
	rotation: Vector3?, -- degrees (static)
	-- animation
	limb: string?, -- "legL" | "legR" | "armL" | "armR" | "legSpider" | "wing" | "shard" | "fuse" | "core" | "carry"
	hinge: Vector3?, -- pivot for swinging limbs
	phase: number?, -- 0 or 1 (opposite swing)
	restPitch: number?, -- degrees: resting angle around X (zombie arms forward)
	side: number?, -- spider legs / wings: -1 left, 1 right
	glow: boolean?,
}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end
local function v(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local designs: { [string]: { Box } } = {}

-- Zombie ---------------------------------------------------------------------------------------
do
	local skin, cloth, trousers = rgb(150, 140, 162), rgb(122, 70, 48), rgb(70, 58, 60)
	designs.zombie = {
		{ size = v(0.26, 0.75, 0.26), pos = v(-0.14, 0.375, 0), color = trousers, limb = "legL", hinge = v(-0.14, 0.75, 0), phase = 0 },
		{ size = v(0.26, 0.75, 0.26), pos = v(0.14, 0.375, 0), color = trousers, limb = "legR", hinge = v(0.14, 0.75, 0), phase = 1 },
		{ size = v(0.56, 0.72, 0.3), pos = v(0, 1.11, 0), color = cloth },
		{ size = v(0.58, 0.12, 0.32), pos = v(0, 0.8, 0), color = rgb(96, 52, 36) }, -- ragged hem
		{ size = v(0.22, 0.7, 0.22), pos = v(-0.4, 1.12, 0), color = skin, limb = "armL", hinge = v(-0.4, 1.42, 0), phase = 1, restPitch = 80 },
		{ size = v(0.22, 0.7, 0.22), pos = v(0.4, 1.12, 0), color = skin, limb = "armR", hinge = v(0.4, 1.42, 0), phase = 0, restPitch = 80 },
		{ size = v(0.5, 0.5, 0.5), pos = v(0, 1.72, 0), color = skin },
		{ size = v(0.12, 0.1, 0.02), pos = v(-0.11, 1.76, -0.255), color = rgb(255, 176, 40), material = Enum.Material.Neon, glow = true },
		{ size = v(0.07, 0.07, 0.02), pos = v(0.12, 1.77, -0.255), color = rgb(255, 176, 40), material = Enum.Material.Neon, glow = true },
		{ size = v(0.22, 0.04, 0.02), pos = v(0, 1.6, -0.255), color = rgb(50, 30, 40) },
	}
end

-- Skeleton -------------------------------------------------------------------------------------
do
	local bone, dark = rgb(226, 220, 200), rgb(58, 52, 48)
	designs.skeleton = {
		{ size = v(0.14, 0.8, 0.14), pos = v(-0.12, 0.4, 0), color = bone, limb = "legL", hinge = v(-0.12, 0.8, 0), phase = 0 },
		{ size = v(0.14, 0.8, 0.14), pos = v(0.12, 0.4, 0), color = bone, limb = "legR", hinge = v(0.12, 0.8, 0), phase = 1 },
		{ size = v(0.14, 0.7, 0.14), pos = v(0, 1.15, 0.02), color = bone }, -- spine
		{ size = v(0.46, 0.06, 0.24), pos = v(0, 1.36, 0), color = bone }, -- ribs
		{ size = v(0.42, 0.06, 0.22), pos = v(0, 1.24, 0), color = bone },
		{ size = v(0.38, 0.06, 0.2), pos = v(0, 1.12, 0), color = bone },
		{ size = v(0.3, 0.3, 0.16), pos = v(0, 1.24, 0.01), color = dark }, -- shadowed chest
		{ size = v(0.12, 0.72, 0.12), pos = v(-0.32, 1.1, 0), color = bone, limb = "armL", hinge = v(-0.32, 1.44, 0), phase = 1, restPitch = 70 },
		{ size = v(0.12, 0.72, 0.12), pos = v(0.32, 1.1, 0), color = bone, limb = "armR", hinge = v(0.32, 1.44, 0), phase = 0, restPitch = 20 },
		-- bow held in the left hand (static relative to the arm swing for simplicity)
		{ size = v(0.04, 0.5, 0.04), pos = v(-0.32, 1.2, -0.62), color = rgb(110, 80, 50) },
		{ size = v(0.02, 0.5, 0.02), pos = v(-0.32, 1.2, -0.54), color = rgb(230, 230, 230) },
		{ size = v(0.54, 0.42, 0.48), pos = v(0, 1.76, 0), color = bone }, -- skull
		{ size = v(0.4, 0.1, 0.4), pos = v(0, 1.5, -0.02), color = bone }, -- jaw
		{ size = v(0.12, 0.1, 0.02), pos = v(-0.12, 1.78, -0.245), color = rgb(140, 200, 255), material = Enum.Material.Neon, glow = true },
		{ size = v(0.12, 0.1, 0.02), pos = v(0.12, 1.78, -0.245), color = rgb(140, 200, 255), material = Enum.Material.Neon, glow = true },
	}
end

-- Spider ---------------------------------------------------------------------------------------
do
	local body, stripe = rgb(72, 46, 30), rgb(232, 122, 40)
	local d: { Box } = {
		{ size = v(0.95, 0.55, 0.95), pos = v(0, 0.5, 0.35), color = body }, -- abdomen
		{ size = v(0.97, 0.06, 0.18), pos = v(0, 0.78, 0.2), color = stripe },
		{ size = v(0.97, 0.06, 0.18), pos = v(0, 0.78, 0.5), color = stripe },
		{ size = v(0.6, 0.42, 0.55), pos = v(0, 0.45, -0.35), color = rgb(60, 38, 26) }, -- head part
	}
	for _, e in { v(-0.14, 0.55, -0.63), v(0, 0.58, -0.63), v(0.14, 0.55, -0.63), v(-0.08, 0.45, -0.63), v(0.08, 0.45, -0.63), v(0, 0.36, -0.63) } do
		table.insert(d, { size = v(0.07, 0.07, 0.02), pos = e, color = rgb(255, 170, 60), material = Enum.Material.Neon, glow = true })
	end
	for i = 0, 3 do
		local z = -0.4 + i * 0.27
		for _, side in { -1, 1 } do
			table.insert(d, {
				size = v(0.85, 0.08, 0.08),
				pos = v(side * 0.68, 0.38, z),
				color = rgb(50, 32, 22),
				rotation = v(0, 0, side * -22),
				limb = "legSpider",
				hinge = v(side * 0.25, 0.45, z),
				phase = (i + (if side > 0 then 1 else 0)) % 2,
				side = side,
			})
		end
	end
	designs.spider = d
end

-- Sneaker -----------------------------------------------------------------------------------
do
	local ash, char, ember = rgb(96, 92, 88), rgb(46, 42, 40), rgb(255, 120, 30)
	designs.sneaker = {
		{ size = v(0.3, 0.45, 0.32), pos = v(-0.18, 0.225, 0), color = char, limb = "legL", hinge = v(-0.18, 0.45, 0), phase = 0 },
		{ size = v(0.3, 0.45, 0.32), pos = v(0.18, 0.225, 0), color = char, limb = "legR", hinge = v(0.18, 0.45, 0), phase = 1 },
		{ size = v(0.7, 0.75, 0.56), pos = v(0, 0.82, 0.04), color = ash, limb = "fuse" }, -- barrel body
		{ size = v(0.6, 0.1, 0.5), pos = v(0, 1.22, 0.06), color = char }, -- hunched shoulders
		-- glowing crack lines across the body
		{ size = v(0.04, 0.5, 0.02), pos = v(-0.15, 0.85, -0.245), color = ember, material = Enum.Material.Neon, rotation = v(0, 0, 18), glow = true, limb = "fuse" },
		{ size = v(0.04, 0.35, 0.02), pos = v(0.12, 0.75, -0.245), color = ember, material = Enum.Material.Neon, rotation = v(0, 0, -30), glow = true, limb = "fuse" },
		{ size = v(0.3, 0.04, 0.02), pos = v(0.02, 1.0, -0.245), color = ember, material = Enum.Material.Neon, glow = true, limb = "fuse" },
		{ size = v(0.02, 0.45, 0.04), pos = v(0.355, 0.8, 0.0), color = ember, material = Enum.Material.Neon, rotation = v(25, 0, 0), glow = true, limb = "fuse" },
		{ size = v(0.18, 0.45, 0.18), pos = v(-0.45, 0.85, -0.02), color = ash, limb = "armL", hinge = v(-0.45, 1.06, 0), phase = 1 },
		{ size = v(0.18, 0.45, 0.18), pos = v(0.45, 0.85, -0.02), color = ash, limb = "armR", hinge = v(0.45, 1.06, 0), phase = 0 },
		{ size = v(0.42, 0.34, 0.4), pos = v(0, 1.28, -0.2), color = char }, -- low head, pushed forward
		{ size = v(0.3, 0.05, 0.02), pos = v(0, 1.3, -0.405), color = ember, material = Enum.Material.Neon, glow = true, limb = "fuse" }, -- slit eye
	}
end

-- Voidling ------------------------------------------------------------------------------------
do
	local crystal, core = rgb(92, 64, 168), rgb(170, 140, 255)
	designs.voidling = {
		{ size = v(0.14, 0.14, 0.14), pos = v(0, 0.35, 0), color = crystal, material = Enum.Material.Glass, transparency = 0.2, rotation = v(45, 45, 0) },
		{ size = v(0.2, 0.2, 0.2), pos = v(0, 0.65, 0), color = crystal, material = Enum.Material.Glass, transparency = 0.2, rotation = v(45, 45, 0) },
		{ size = v(0.28, 0.4, 0.22), pos = v(0, 1.0, 0), color = crystal, material = Enum.Material.Glass, transparency = 0.15 },
		{ size = v(0.36, 0.95, 0.26), pos = v(0, 1.62, 0), color = crystal, material = Enum.Material.Glass, transparency = 0.15, limb = "core" },
		{ size = v(0.16, 0.5, 0.14), pos = v(0, 1.62, 0), color = core, material = Enum.Material.Neon, glow = true, limb = "core" },
		{ size = v(0.34, 0.34, 0.34), pos = v(0, 2.36, 0), color = core, material = Enum.Material.Neon, rotation = v(45, 0, 45), glow = true, limb = "core" },
		-- orbiting shard "arms"
		{ size = v(0.12, 0.42, 0.12), pos = v(-0.5, 1.7, 0), color = crystal, material = Enum.Material.Glass, transparency = 0.1, limb = "shard", phase = 0 },
		{ size = v(0.1, 0.3, 0.1), pos = v(-0.55, 1.25, 0), color = crystal, material = Enum.Material.Glass, transparency = 0.1, limb = "shard", phase = 0.33 },
		{ size = v(0.12, 0.42, 0.12), pos = v(0.5, 1.7, 0), color = crystal, material = Enum.Material.Glass, transparency = 0.1, limb = "shard", phase = 0.5 },
		{ size = v(0.1, 0.3, 0.1), pos = v(0.55, 1.25, 0), color = crystal, material = Enum.Material.Glass, transparency = 0.1, limb = "shard", phase = 0.83 },
		-- a carried block hovering in front
		{ size = v(0.4, 0.4, 0.4), pos = v(0, 1.45, -0.55), color = rgb(96, 160, 56), limb = "carry" },
	}
end

-- Cow ------------------------------------------------------------------------------------------
do
	local tawny, dark, cream, hoof = rgb(178, 122, 70), rgb(104, 66, 38), rgb(236, 220, 186), rgb(60, 44, 34)
	local d: { Box } = {
		{ size = v(0.72, 0.62, 1.15), pos = v(0, 0.95, 0.05), color = tawny },
		{ size = v(0.2, 0.04, 1.0), pos = v(0, 1.27, 0.05), color = dark },
		{ size = v(0.5, 0.06, 0.6), pos = v(0, 0.63, 0.1), color = cream },
		{ size = v(0.46, 0.44, 0.4), pos = v(0, 1.18, -0.7), color = tawny },
		{ size = v(0.34, 0.2, 0.08), pos = v(0, 1.05, -0.92), color = dark },
		{ size = v(0.06, 0.16, 0.06), pos = v(-0.2, 1.46, -0.72), color = cream, rotation = v(0, 0, 25) },
		{ size = v(0.06, 0.16, 0.06), pos = v(0.2, 1.46, -0.72), color = cream, rotation = v(0, 0, -25) },
	}
	for i, p in { v(-0.24, 0, -0.35), v(0.24, 0, -0.35), v(-0.24, 0, 0.45), v(0.24, 0, 0.45) } do
		table.insert(d, { size = v(0.2, 0.64, 0.2), pos = p + v(0, 0.32, 0), color = tawny, limb = "legL", hinge = p + v(0, 0.64, 0), phase = (i == 1 or i == 4) and 0 or 1 })
		table.insert(d, { size = v(0.21, 0.08, 0.21), pos = p + v(0, 0.04, 0), color = hoof, limb = "legL", hinge = p + v(0, 0.64, 0), phase = (i == 1 or i == 4) and 0 or 1 })
	end
	designs.cow = d
end

-- Pig ------------------------------------------------------------------------------------------
do
	local skin, ridge = rgb(196, 146, 146), rgb(146, 100, 100)
	local d: { Box } = {
		{ size = v(0.62, 0.5, 0.95), pos = v(0, 0.58, 0.05), color = skin },
		{ size = v(0.14, 0.06, 0.8), pos = v(0, 0.85, 0.05), color = ridge },
		{ size = v(0.48, 0.44, 0.42), pos = v(0, 0.68, -0.6), color = skin },
		{ size = v(0.26, 0.18, 0.08), pos = v(0, 0.6, -0.84), color = ridge },
		{ size = v(0.04, 0.04, 0.02), pos = v(-0.06, 0.61, -0.885), color = rgb(70, 40, 40) },
		{ size = v(0.04, 0.04, 0.02), pos = v(0.06, 0.61, -0.885), color = rgb(70, 40, 40) },
		{ size = v(0.04, 0.08, 0.04), pos = v(-0.15, 0.52, -0.84), color = rgb(236, 226, 200) }, -- tusk nubs
		{ size = v(0.04, 0.08, 0.04), pos = v(0.15, 0.52, -0.84), color = rgb(236, 226, 200) },
		{ size = v(0.12, 0.1, 0.06), pos = v(-0.18, 0.93, -0.6), color = ridge },
		{ size = v(0.12, 0.1, 0.06), pos = v(0.18, 0.93, -0.6), color = ridge },
	}
	for i, p in { v(-0.2, 0, -0.3), v(0.2, 0, -0.3), v(-0.2, 0, 0.38), v(0.2, 0, 0.38) } do
		table.insert(d, { size = v(0.18, 0.34, 0.18), pos = p + v(0, 0.17, 0), color = skin, limb = "legL", hinge = p + v(0, 0.34, 0), phase = (i == 1 or i == 4) and 0 or 1 })
	end
	designs.pig = d
end

-- Sheep ----------------------------------------------------------------------------------------
do
	local wool, face = rgb(236, 228, 210), rgb(60, 55, 56)
	local d: { Box } = {
		{ size = v(0.75, 0.62, 1.0), pos = v(0, 0.86, 0.05), color = wool },
		{ size = v(0.5, 0.2, 0.5), pos = v(0, 1.2, 0.1), color = wool }, -- wool puff
		{ size = v(0.36, 0.38, 0.36), pos = v(0, 1.1, -0.6), color = face },
		{ size = v(0.42, 0.16, 0.2), pos = v(0, 1.31, -0.5), color = wool }, -- woolly cap
	}
	for i, p in { v(-0.22, 0, -0.32), v(0.22, 0, -0.32), v(-0.22, 0, 0.42), v(0.22, 0, 0.42) } do
		table.insert(d, { size = v(0.16, 0.56, 0.16), pos = p + v(0, 0.28, 0), color = face, limb = "legL", hinge = p + v(0, 0.56, 0), phase = (i == 1 or i == 4) and 0 or 1 })
	end
	designs.sheep = d
end

-- Chicken --------------------------------------------------------------------------------------
do
	local feathers = rgb(150, 100, 62)
	designs.chicken = {
		{ size = v(0.38, 0.36, 0.48), pos = v(0, 0.42, 0.04), color = feathers },
		{ size = v(0.06, 0.06, 0.02), pos = v(-0.1, 0.5, -0.205), color = rgb(220, 190, 150) }, -- speckles
		{ size = v(0.06, 0.06, 0.02), pos = v(0.08, 0.38, -0.205), color = rgb(220, 190, 150) },
		{ size = v(0.24, 0.26, 0.22), pos = v(0, 0.72, -0.2), color = feathers },
		{ size = v(0.06, 0.1, 0.12), pos = v(0, 0.89, -0.2), color = rgb(210, 40, 40) }, -- comb
		{ size = v(0.1, 0.06, 0.1), pos = v(0, 0.7, -0.35), color = rgb(240, 190, 40) }, -- beak
		{ size = v(0.04, 0.24, 0.04), pos = v(-0.08, 0.12, 0.04), color = rgb(240, 190, 40), limb = "legL", hinge = v(-0.08, 0.24, 0.04), phase = 0 },
		{ size = v(0.04, 0.24, 0.04), pos = v(0.08, 0.12, 0.04), color = rgb(240, 190, 40), limb = "legR", hinge = v(0.08, 0.24, 0.04), phase = 1 },
		{ size = v(0.04, 0.26, 0.36), pos = v(-0.21, 0.46, 0.05), color = rgb(120, 78, 46), limb = "wing", hinge = v(-0.19, 0.58, 0.05), side = -1 },
		{ size = v(0.04, 0.26, 0.36), pos = v(0.21, 0.46, 0.05), color = rgb(120, 78, 46), limb = "wing", hinge = v(0.19, 0.58, 0.05), side = 1 },
	}
end

-- Arrow (feet centre = arrow centre) ------------------------------------------------------------
designs.arrow = {
	{ size = v(0.05, 0.05, 0.6), pos = v(0, 0, 0), color = rgb(150, 120, 80) },
	{ size = v(0.08, 0.08, 0.1), pos = v(0, 0, -0.32), color = rgb(150, 150, 156) },
	{ size = v(0.16, 0.02, 0.14), pos = v(0, 0, 0.26), color = rgb(236, 236, 230) },
	{ size = v(0.02, 0.16, 0.14), pos = v(0, 0, 0.26), color = rgb(236, 236, 230) },
}

local MobModels = {}

export type PartInfo = {
	part: BasePart,
	box: Box,
	baseColor: Color3,
	local0: CFrame, -- rest CFrame relative to the feet centre (studs)
}
export type Built = { model: Model, parts: { PartInfo }, torso: BasePart? }

function MobModels.build(key: string): Built?
	local design = designs[key]
	if not design then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = key
	local parts: { PartInfo } = {}
	local biggest: BasePart? = nil
	local biggestVol = 0
	for _, b in design do
		local p = Instance.new("Part")
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = not b.glow
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Material = b.material or Enum.Material.SmoothPlastic
		p.Color = b.color
		p.Transparency = b.transparency or 0
		p.Size = b.size * BS
		local rot = b.rotation or Vector3.zero
		local local0 = CFrame.new(b.pos * BS) * CFrame.Angles(math.rad(rot.X), math.rad(rot.Y), math.rad(rot.Z))
		p.Parent = model
		table.insert(parts, { part = p, box = b, baseColor = b.color, local0 = local0 })
		local vol = b.size.X * b.size.Y * b.size.Z
		if vol > biggestVol and not b.limb then
			biggest, biggestVol = p, vol
		end
	end
	return { model = model, parts = parts, torso = biggest }
end

return MobModels
