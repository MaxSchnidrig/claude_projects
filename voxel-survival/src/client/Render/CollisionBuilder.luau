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
local SectionSampler = require(Shared.Meshing.SectionSampler)
local Shapes = require(Shared.Blocks.Shapes)

local BS = Config.BLOCK_SIZE
local isSolid = BlockRegistry.isSolid
local isCube = BlockRegistry.isCube
local isBoxShape = BlockRegistry.isBoxShape
local SS = Config.SECTION_SIZE
local P = SectionSampler.SIZE
local P2 = P * P

local CollisionBuilder = {}
CollisionBuilder.stats = { parts = 0 }

local function solidKey(id: number): number
	return if isSolid[id + 1] and isCube[id + 1] then 1 else 0
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
	-- slabs, stairs, fences, doors, ladders: one part per collision box (Blocks/Shapes)
	local function addBox(x: number, y: number, z: number, b: { number })
		local size = Vector3.new(b[4] - b[1], b[5] - b[2], b[6] - b[3])
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = true
		part.CanQuery = true
		part.CanTouch = false
		part.Transparency = 1
		part.CastShadow = false
		part.Size = size * BS
		part.CFrame = CFrame.new(originStuds + (Vector3.new(x + b[1], y + b[2], z + b[3]) + size / 2) * BS)
		part.Parent = folder
		table.insert(parts, part)
		count += 1
	end
	for y = 0, SS - 1 do
		for z = 0, SS - 1 do
			for x = 0, SS - 1 do
				local p = (x + 1) + (z + 1) * P + (y + 1) * P2
				local id = buffer.readu16(padded, p * 2)
				if id ~= 0 and isBoxShape[id + 1] and isSolid[id + 1] then
					local function get(dx: number, dy: number, dz: number): number?
						return buffer.readu16(padded, (p + dx + dz * P + dy * P2) * 2)
					end
					local tall = BlockRegistry.byId[id].shape
					tall = (tall == "fence" or tall == "wall" or tall == "fence_gate") and tall or nil
					for _, b in Shapes.boxes(id, get, true) do
						if tall and b[5] > 1 then
							-- a Roblox body's legs don't collide: its torso starts 2/3 of a block up and
							-- would clear a 1.5 fence at the top of a jump. Up to 2 blocks for the body;
							-- the Java 1.5 stays for feet and mobs (Shapes, MovementController).
							b = { b[1], b[2], b[3], b[4], 2, b[6] }
						end
						addBox(x, y, z, b)
					end
				end
			end
		end
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
