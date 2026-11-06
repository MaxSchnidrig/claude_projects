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

local BS = Config.BLOCK_SIZE
local SHADE = Config.FACE_SHADE
local DIR_SHADE = { SHADE.east, SHADE.west, SHADE.top, SHADE.bottom, SHADE.south, SHADE.north }
local THICKNESS = 0.02 -- studs; the slab sits just behind the face plane (inside its block)

export type Handle = { parts: { BasePart } }

local Backend = {}
Backend.stats = { parts = 0, sections = 0 }

-- Is this texture rendered by this backend (instead of the opaque mesh)?
function Backend.isSpecial(tex: number): boolean
	local style = RenderStyle.forTexture(tex)
	return style.transparency > 0 or style.material ~= Enum.Material.SmoothPlastic
end

-- `groups`: texture -> quad list (GreedyMesher format), special textures only.
function Backend.build(groups: { [number]: { number } }, originStuds: Vector3, folder: Instance): Handle?
	local handle: Handle = { parts = {} }
	for tex, quads in groups do
		local style = RenderStyle.forTexture(tex)
		for q = 1, #quads, 6 do
			local d, k, i, j, w, h = quads[q], quads[q + 1], quads[q + 2], quads[q + 3], quads[q + 4], quads[q + 5]
			local dir = GreedyMesher.DIRS[d]
			local size = { 0, 0, 0 }
			local center = { 0, 0, 0 }
			size[dir.u + 1] = w * BS
			size[dir.v + 1] = h * BS
			center[dir.u + 1] = (i + w / 2) * BS
			center[dir.v + 1] = (j + h / 2) * BS
			local plane = (if dir.sign > 0 then k + 1 else k) * BS
			size[dir.axis + 1] = THICKNESS
			center[dir.axis + 1] = plane - dir.sign * THICKNESS / 2

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
