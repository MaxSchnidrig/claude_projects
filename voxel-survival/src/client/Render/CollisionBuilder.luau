--!strict
-- Client-side terrain collision: invisible anchored Parts covering merged boxes of solid blocks.
-- Only built for sections near the player (Config.COLLISION_RADIUS), because the character is the
-- only thing that physically collides with terrain on this client. Mobs (phase 5) move on the
-- voxel grid on the server and never need these.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local BoxMerger = require(Shared.Meshing.BoxMerger)

local BS = Config.BLOCK_SIZE
local isSolid = BlockRegistry.isSolid

local CollisionBuilder = {}
CollisionBuilder.stats = { parts = 0 }

local function solidKey(id: number): number
	return if isSolid[id + 1] then 1 else 0
end

function CollisionBuilder.build(padded: buffer, originStuds: Vector3, folder: Instance): { BasePart }
	local boxes, count = BoxMerger.merge(padded, solidKey)
	local parts = table.create(count)
	for b = 0, count - 1 do
		local o = b * 7
		local x, y, z, sx, sy, sz = boxes[o + 1], boxes[o + 2], boxes[o + 3], boxes[o + 4], boxes[o + 5], boxes[o + 6]
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = true
		-- CanQuery stays on: Humanoid floor detection and the camera's occlusion check use queries.
		part.CanQuery = true
		part.CanTouch = false
		part.Transparency = 1
		part.CastShadow = false
		part.Size = Vector3.new(sx, sy, sz) * BS
		part.CFrame = CFrame.new(originStuds + Vector3.new(x + sx / 2, y + sy / 2, z + sz / 2) * BS)
		part.Parent = folder
		table.insert(parts, part)
	end
	CollisionBuilder.stats.parts += count
	return parts
end

function CollisionBuilder.destroy(parts: { BasePart })
	CollisionBuilder.stats.parts -= #parts
	for _, p in parts do
		p:Destroy()
	end
	table.clear(parts)
end

return CollisionBuilder
