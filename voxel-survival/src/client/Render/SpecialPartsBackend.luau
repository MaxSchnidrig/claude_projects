--!strict
-- Renders a section's "special" faces (see-through or glowing blocks: water, ice, glass, lava) as
-- plain Parts, one thin Part per greedy quad. Everything else (opaque terrain) stays a mesh.
--
-- Why: these faces must change on the exact frame of an edit without any hand-over. Meshes need
-- a live mesh -> baked mesh hand-over, and for see-through surfaces every hand-over strategy we
-- tried flashed (two overlapping water surfaces blend; hiding one leaves a gap). Plain Parts
-- appear on the frame they're parented, so the section's special faces are simply rebuilt in
-- that frame. Water etc. now ALWAYS use Parts (not only after edits), so the look is consistent.
--
-- Cost: special faces are few after greedy merging (an ocean section's surface is a handful of
-- big rectangles), so this is far fewer instances than the Parts backend, and it needs no
-- EditableMesh budget at all.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local GreedyMesher = require(Shared.Meshing.GreedyMesher)
local RenderStyle = require(script.Parent.RenderStyle)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Fluids = require(Shared.World.Fluids)

-- Fluid surfaces: texture -> (fluid, surface height 0..1). Java draws a source 8/9 of a block high
-- and each flowing level lower; the top layer's side faces are cut to the same height.
local fluidTex: { [number]: { fluid: string, height: number } } = {}
for _, def in BlockRegistry.byId do
	if def.fluid then
		fluidTex[def.faceTexture[BlockRegistry.Dir.TOP]] = { fluid = def.fluid, height = Fluids.height(def.fluidLevel or 0) }
	end
end
local function fluidOfId(id: number): string?
	local def = BlockRegistry.byId[id]
	return def and def.fluid
end

local BS = Config.BLOCK_SIZE
local SHADE = Config.FACE_SHADE
local DIR_SHADE = { SHADE.east, SHADE.west, SHADE.top, SHADE.bottom, SHADE.south, SHADE.north }
local THICKNESS = 0.02 -- studs; the slab sits just behind the face plane (inside its block)
-- Separate Parts sharing an edge aren't drawn watertight (thin seams showed on water). Each slab
-- extends this far into in-plane neighbours with a visible face, so neighbours overlap instead of
-- leaving a crack. The overlap strip is far thinner than a pixel at normal distances.
local SEAM_OVERLAP = 0.012

local faceVisible = GreedyMesher.faceVisible
local STRIDE = GreedyMesher.STRIDE

-- Is the face in direction d of padded cell (slice k, u, v) visible? (u, v may be -1 or 16.)
local function faceAt(padded: buffer, d: number, k: number, u: number, v: number): boolean
	if u < -1 or u > 16 or v < -1 or v > 16 then
		return false
	end
	local dir = GreedyMesher.DIRS[d]
	local p = (k + 1) * STRIDE[dir.axis] + (u + 1) * STRIDE[dir.u] + (v + 1) * STRIDE[dir.v]
	local b = buffer.readu16(padded, p * 2)
	return b ~= 0 and faceVisible(b, buffer.readu16(padded, (p + STRIDE[dir.axis] * dir.sign) * 2))
end

-- Does the plane continue into another visible face anywhere along this edge?
local function continues(padded: buffer, d: number, k: number, u0: number, u1: number, v0: number, v1: number): number
	for u = u0, u1 do
		for v = v0, v1 do
			if faceAt(padded, d, k, u, v) then
				return SEAM_OVERLAP
			end
		end
	end
	return 0
end

export type Handle = { parts: { BasePart } }

local Backend = {}
Backend.stats = { parts = 0, sections = 0 }

-- Is this texture rendered by this backend (instead of the opaque mesh)?
function Backend.isSpecial(tex: number): boolean
	local style = RenderStyle.forTexture(tex)
	return style.transparency > 0 or style.material ~= RenderStyle.baseMaterial
end

-- `groups`: texture -> quad list (GreedyMesher format), special textures only.
-- `padded` is the section's padded buffer (SectionSampler) the quads were meshed from.
function Backend.build(groups: { [number]: { number } }, padded: buffer, originStuds: Vector3, folder: Instance): Handle?
	local handle: Handle = { parts = {} }
	for tex, quads in groups do
		local style = RenderStyle.forTexture(tex)
		for q = 1, #quads, GreedyMesher.QUAD do
			local d, k, i, j, w, h = quads[q], quads[q + 1], quads[q + 2], quads[q + 3], quads[q + 4], quads[q + 5]
			local dir = GreedyMesher.DIRS[d]
			local size = { 0, 0, 0 }
			local center = { 0, 0, 0 }
			local eU0 = continues(padded, d, k, i - 1, i - 1, j, j + h - 1)
			local eU1 = continues(padded, d, k, i + w, i + w, j, j + h - 1)
			local eV0 = continues(padded, d, k, i, i + w - 1, j - 1, j - 1)
			local eV1 = continues(padded, d, k, i, i + w - 1, j + h, j + h)
			size[dir.u + 1] = w * BS + eU0 + eU1
			size[dir.v + 1] = h * BS + eV0 + eV1
			center[dir.u + 1] = (i + w / 2) * BS + (eU1 - eU0) / 2
			center[dir.v + 1] = (j + h / 2) * BS + (eV1 - eV0) / 2
			local plane = (if dir.sign > 0 then k + 1 else k) * BS
			size[dir.axis + 1] = THICKNESS
			center[dir.axis + 1] = plane - dir.sign * THICKNESS / 2
			local ft = fluidTex[tex]
			if ft and ft.height < 1 then
				local drop = (1 - ft.height) * BS
				if d == 3 then
					center[2] -= drop -- the surface sits lower than the block top
				elseif d ~= 4 then
					-- side face: cut its top to the surface height unless more fluid is above
					local topRow, yAxisIsU = 0, dir.u == 1
					topRow = if yAxisIsU then i + w - 1 else j + h - 1
					local pu = if yAxisIsU then topRow + 1 else i
					local pv = if yAxisIsU then j else topRow + 1
					local p = (k + 1) * STRIDE[dir.axis] + (pu + 1) * STRIDE[dir.u] + (pv + 1) * STRIDE[dir.v]
					local above = buffer.readu16(padded, p * 2)
					if fluidOfId(above) ~= ft.fluid then
						size[2] -= drop
						center[2] -= drop / 2
					end
				end
			end

			local s = DIR_SHADE[d]
			local part = Instance.new("Part")
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Reflectance = 0
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			part.CastShadow = style.transparency == 0 -- see-through surfaces don't cast shadows
			part.Material = style.material
			part.Color = Color3.new(style.color.R * s, style.color.G * s, style.color.B * s)
			part.Transparency = style.transparency
			part.Size = Vector3.new(size[1], size[2], size[3])
			part.CFrame = CFrame.new(originStuds + Vector3.new(center[1], center[2], center[3]))
			part.Parent = folder
			table.insert(handle.parts, part)
		end
	end
	if #handle.parts == 0 then
		return nil
	end
	Backend.stats.parts += #handle.parts
	Backend.stats.sections += 1
	return handle
end

function Backend.destroy(handle: Handle?)
	if not handle then
		return
	end
	Backend.stats.parts -= #handle.parts
	Backend.stats.sections -= 1
	for _, p in handle.parts do
		p:Destroy()
	end
	table.clear(handle.parts)
end

return Backend
