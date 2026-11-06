--!strict
-- Instant renderer for just-edited sections: one thin Part per greedy quad, plus hidden filler
-- boxes.
--
-- Why: a baked MeshPart takes a moment to build, upload and start drawing, but a plain Part draws
-- on the frame it's parented. When the player breaks or places a block we show the section with
-- these Parts immediately (same frame as the click), remove the old mesh at the same moment, and
-- a priority background job bakes the real mesh, which replaces them shortly after.
--
-- Making the temporary geometry look identical to the mesh:
--   * Colour/shading: the same greedy quads, same texture colour x the same per-face shade the
--     mesh bakes into its vertex colours, same Material, Reflectance 0, CastShadow like the mesh.
--   * Depth: each quad is a thin slab sunk slightly INTO the surface, so while the real mesh and
--     the slabs overlap during the hand-over, the mesh is in front (no z-fighting).
--   * Seams: separate Parts sharing an edge aren't drawn watertight, which showed as thin white
--     lines. Each slab is extended by SEAM_OVERLAP on every edge where the same plane continues
--     into another visible face, and neighbouring slabs sit at slightly different depths so the
--     overlap strips don't flicker. Edges at convex corners are NOT extended (that would make a
--     visible lip stick out of the block).
--   * Lighting: Roblox derives ambient light / sky occlusion from the VOLUME parts occupy. Thin
--     slabs occupy almost none, so the area brightened until the mesh came back. Hidden filler
--     boxes (merged solid blocks, shrunk to sit just behind the slabs) give the edited section
--     the same occupied volume as real terrain, and also back any remaining crack with a dark
--     surface instead of the sky.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local GreedyMesher = require(Shared.Meshing.GreedyMesher)
local BoxMerger = require(Shared.Meshing.BoxMerger)
local RenderStyle = require(script.Parent.RenderStyle)

local BS = Config.BLOCK_SIZE
local SHADE = Config.FACE_SHADE
local DIR_SHADE = { SHADE.east, SHADE.west, SHADE.top, SHADE.bottom, SHADE.south, SHADE.north }
local THICKNESS = 0.04 -- studs
local INSET = 0.02 -- studs between the block surface and the slab's front face
local INSET_STAGGER = 0.004 -- every other slab sits this much deeper (no z-fight in overlaps)
local SEAM_OVERLAP = 0.015 -- studs each slab extends into in-plane neighbours
local FILLER_SHRINK = INSET + INSET_STAGGER + THICKNESS -- filler faces stay behind every slab
local FILLER_COLOR = Color3.fromRGB(20, 18, 16)

local isOpaque = BlockRegistry.isOpaque
local faceVisible = GreedyMesher.faceVisible
local STRIDE = GreedyMesher.STRIDE

export type Handle = { parts: { BasePart } }

local Backend = {}
Backend.stats = { parts = 0 }

local function newPart(folder: Instance): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Reflectance = 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

-- Is the face in direction `d` of padded cell (slice k, u, v) visible? Out-of-range = no.
local function faceAt(padded: buffer, d: number, k: number, u: number, v: number): boolean
	if u < -1 or u > 16 or v < -1 or v > 16 then
		return false
	end
	local dir = GreedyMesher.DIRS[d]
	local p = (k + 1) * STRIDE[dir.axis] + (u + 1) * STRIDE[dir.u] + (v + 1) * STRIDE[dir.v]
	local b = buffer.readu8(padded, p)
	if b == 0 then
		return false
	end
	return faceVisible(b, buffer.readu8(padded, p + STRIDE[dir.axis] * dir.sign))
end

-- Does the plane continue into a visible face anywhere along one edge of the quad?
local function edgeContinues(padded: buffer, d: number, k: number, u0: number, u1: number, v0: number, v1: number): boolean
	for u = u0, u1 do
		for v = v0, v1 do
			if faceAt(padded, d, k, u, v) then
				return true
			end
		end
	end
	return false
end

function Backend.build(result: GreedyMesher.MeshResult, padded: buffer, originStuds: Vector3, folder: Instance): Handle
	local handle: Handle = { parts = table.create(result.quadCount + 64) }
	local stagger = 0

	-- 1. Slabs, one per greedy quad.
	for tex, quads in result.groups do
		local style = RenderStyle.forTexture(tex)
		local shaded: { Color3 } = {}
		for d = 1, 6 do
			local s = DIR_SHADE[d]
			shaded[d] = Color3.new(style.color.R * s, style.color.G * s, style.color.B * s)
		end
		for q = 1, #quads, 6 do
			local d, k, i, j, w, h = quads[q], quads[q + 1], quads[q + 2], quads[q + 3], quads[q + 4], quads[q + 5]
			local dir = GreedyMesher.DIRS[d]
			-- Seam overlap on edges where the same plane continues (in studs).
			local eU0 = if edgeContinues(padded, d, k, i - 1, i - 1, j, j + h - 1) then SEAM_OVERLAP else 0
			local eU1 = if edgeContinues(padded, d, k, i + w, i + w, j, j + h - 1) then SEAM_OVERLAP else 0
			local eV0 = if edgeContinues(padded, d, k, i, i + w - 1, j - 1, j - 1) then SEAM_OVERLAP else 0
			local eV1 = if edgeContinues(padded, d, k, i, i + w - 1, j + h, j + h) then SEAM_OVERLAP else 0

			local inset = INSET + (stagger % 2) * INSET_STAGGER
			stagger += 1
			local size = { 0, 0, 0 }
			local center = { 0, 0, 0 }
			size[dir.u + 1] = w * BS + eU0 + eU1
			size[dir.v + 1] = h * BS + eV0 + eV1
			center[dir.u + 1] = (i + w / 2) * BS + (eU1 - eU0) / 2
			center[dir.v + 1] = (j + h / 2) * BS + (eV1 - eV0) / 2
			local plane = (if dir.sign > 0 then k + 1 else k) * BS
			size[dir.axis + 1] = THICKNESS
			center[dir.axis + 1] = plane - dir.sign * (inset + THICKNESS / 2)

			local part = newPart(folder)
			part.CastShadow = true -- like the mesh
			part.Material = style.material
			part.Color = shaded[d]
			part.Transparency = style.transparency
			part.Size = Vector3.new(size[1], size[2], size[3])
			part.CFrame = CFrame.new(originStuds + Vector3.new(center[1], center[2], center[3]))
			part.Parent = folder
			table.insert(handle.parts, part)
		end
	end

	-- 2. Hidden fillers: merged opaque blocks, shrunk so every face sits behind the slabs.
	local boxes, count = BoxMerger.merge(padded, function(id: number): number
		return if isOpaque[id + 1] then 1 else 0
	end)
	for b = 0, count - 1 do
		local o = b * 7
		local x, y, z, sx, sy, sz = boxes[o + 1], boxes[o + 2], boxes[o + 3], boxes[o + 4], boxes[o + 5], boxes[o + 6]
		local sizeStuds = Vector3.new(sx, sy, sz) * BS - Vector3.one * (FILLER_SHRINK * 2)
		if sizeStuds.X > 0 and sizeStuds.Y > 0 and sizeStuds.Z > 0 then
			local part = newPart(folder)
			part.CastShadow = false -- the slabs already cast the section's shadows
			part.Material = Enum.Material.SmoothPlastic
			part.Color = FILLER_COLOR
			part.Size = sizeStuds
			part.CFrame = CFrame.new(originStuds + Vector3.new(x + sx / 2, y + sy / 2, z + sz / 2) * BS)
			part.Parent = folder
			table.insert(handle.parts, part)
		end
	end

	Backend.stats.parts += #handle.parts
	return handle
end

function Backend.destroy(handle: Handle)
	Backend.stats.parts -= #handle.parts
	for _, p in handle.parts do
		p:Destroy()
	end
	table.clear(handle.parts)
end

return Backend
