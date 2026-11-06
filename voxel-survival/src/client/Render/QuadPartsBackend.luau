--!strict
-- Instant renderer for just-edited sections: one thin Part per greedy quad.
--
-- Why: a baked MeshPart takes a moment to build, upload and start drawing, but a plain Part draws
-- on the frame it's parented. When the player breaks or places a block we show the section with
-- these quad Parts immediately (same frame as the click), hide the old mesh at the same moment,
-- and let the background job bake a proper mesh that replaces them a bit later.
--
-- The quads come from the same greedy mesh as the final MeshPart and use the same colour and
-- per-face shading, so the hand-over is invisible. Each quad is a thin slab sunk slightly INTO the
-- block surface: while the real mesh and the quads overlap during the hand-over, the mesh is in
-- front and wins the depth test, so there's no z-fighting.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local GreedyMesher = require(Shared.Meshing.GreedyMesher)
local RenderStyle = require(script.Parent.RenderStyle)

local BS = Config.BLOCK_SIZE
local SHADE = Config.FACE_SHADE
local DIR_SHADE = { SHADE.east, SHADE.west, SHADE.top, SHADE.bottom, SHADE.south, SHADE.north }
local THICKNESS = 0.04 -- studs
local INSET = 0.02 -- studs between the block surface and the slab's front face

export type Handle = { parts: { BasePart } }

local Backend = {}
Backend.stats = { parts = 0 }

function Backend.build(result: GreedyMesher.MeshResult, originStuds: Vector3, folder: Instance): Handle
	local handle: Handle = { parts = table.create(result.quadCount) }
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
			-- size and centre in block units, per axis (index 1..3 = x, y, z)
			local size = { 0, 0, 0 }
			local center = { 0, 0, 0 }
			size[dir.u + 1] = w
			size[dir.v + 1] = h
			center[dir.u + 1] = i + w / 2
			center[dir.v + 1] = j + h / 2
			local plane = if dir.sign > 0 then k + 1 else k
			-- sink the slab into the block: its front face sits INSET studs behind the surface
			center[dir.axis + 1] = plane - dir.sign * (INSET + THICKNESS / 2) / BS
			local sizeStuds = Vector3.new(size[1] * BS, size[2] * BS, size[3] * BS)
			local axisSize = Vector3.new(
				if dir.axis == 0 then THICKNESS else sizeStuds.X,
				if dir.axis == 1 then THICKNESS else sizeStuds.Y,
				if dir.axis == 2 then THICKNESS else sizeStuds.Z
			)
			local part = Instance.new("Part")
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.CastShadow = true
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			part.Material = style.material
			part.Color = shaded[d]
			part.Transparency = style.transparency
			part.Size = axisSize
			part.CFrame = CFrame.new(originStuds + Vector3.new(center[1], center[2], center[3]) * BS)
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
