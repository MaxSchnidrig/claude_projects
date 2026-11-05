--!strict
-- Fallback render backend: greedy-merged Parts. One Part per merged box of *exposed* blocks of
-- the same type (blocks with at least one non-opaque neighbour). Boxes may also grow through
-- buried blocks (wildcards), which are never visible. Works on every device and needs no
-- EditableMesh, at the cost of many more instances than meshes (see ARCHITECTURE.md).
-- Each box shows its block's top colour on all sides.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local BoxMerger = require(Shared.Meshing.BoxMerger)
local RenderStyle = require(script.Parent.RenderStyle)

local BS = Config.BLOCK_SIZE
local isOpaque = BlockRegistry.isOpaque
local isLiquid = BlockRegistry.isLiquid
local OFFS = BoxMerger.NEIGHBOR_OFFSETS

export type Handle = { parts: { BasePart } }

local Backend = {}
Backend.stats = { parts = 0 }

-- Merge key for one cell: its block id if any face is visible, WILDCARD if it's an opaque block
-- buried on all 6 sides (never seen, so any box may cover it), else 0 (skip).
function Backend.partKey(padded: buffer, id: number, p: number): number
	for i = 1, 6 do
		local n = buffer.readu8(padded, p + OFFS[i])
		if n == 0 or (not isOpaque[n + 1] and n ~= id and not (isLiquid[id + 1] and isLiquid[n + 1])) then
			return id
		end
	end
	return if isOpaque[id + 1] then BoxMerger.WILDCARD else 0
end

function Backend.build(padded: buffer, originStuds: Vector3, folder: Instance): Handle
	local boxes, count = BoxMerger.merge(padded, function(id: number, p: number): number
		return Backend.partKey(padded, id, p)
	end)
	local handle: Handle = { parts = table.create(count) }
	for b = 0, count - 1 do
		local o = b * 7
		local x, y, z, sx, sy, sz, id = boxes[o + 1], boxes[o + 2], boxes[o + 3], boxes[o + 4], boxes[o + 5], boxes[o + 6], boxes[o + 7]
		local style = RenderStyle.forBlock(id)
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Material = style.material
		part.Color = style.color
		part.Transparency = style.transparency
		part.Size = Vector3.new(sx, sy, sz) * BS
		part.CFrame = CFrame.new(originStuds + Vector3.new(x + sx / 2, y + sy / 2, z + sz / 2) * BS)
		part.Parent = folder
		table.insert(handle.parts, part)
	end
	Backend.stats.parts += count
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
