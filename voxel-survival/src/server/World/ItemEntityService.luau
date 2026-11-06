--!strict
-- Dropped items lying in the world (mined blocks, thrown items, container contents).
--
-- The server has no terrain physics (terrain collision exists only on clients), so an item
-- simply rests on top of the first solid block below where it was dropped, and re-settles when
-- that block is removed. Players pick items up by walking within Config.ITEM_PICKUP_RADIUS.
-- Clients add the spin/bob animation locally (see client ItemEntityVisuals).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local WorldService = require(script.Parent.WorldService)

local BS = Config.BLOCK_SIZE
local H = Config.WORLD_HEIGHT
local isSolid = BlockRegistry.isSolid

export type Stack = { item: string, count: number, durability: number? }
type Entity = { part: Part, stack: Stack, pickupAt: number, despawnAt: number, x: number, z: number, y: number }

local ItemEntityService = {}
local entities: { Entity } = {}
local folder: Folder
local addToInventory: ((Player, Stack) -> number)? = nil -- set by InventoryService (avoids a require cycle)

-- Height (studs) an item at world block column (bx, bz) rests at, starting from block row by.
local function restY(bx: number, by: number, bz: number): number
	by = math.clamp(by, 0, H - 1)
	while by < H - 1 and isSolid[WorldService.getBlock(bx, by, bz) + 1] do
		by += 1 -- inside a block: pop up
	end
	while by > 0 and not isSolid[WorldService.getBlock(bx, by - 1, bz) + 1] do
		by -= 1 -- fall onto the first solid block
	end
	return by * BS + 0.45
end

function ItemEntityService.setInventoryAdder(fn: (Player, Stack) -> number)
	addToInventory = fn
end

-- Drop `stack` near world position `pos` (studs).
function ItemEntityService.spawn(stack: Stack, pos: Vector3, pickupDelay: number?)
	if stack.count <= 0 or not ItemRegistry.get(stack.item) then
		return
	end
	if #entities >= Config.MAX_ITEM_ENTITIES then
		local oldest = table.remove(entities, 1) :: Entity
		oldest.part:Destroy()
	end
	local def = ItemRegistry.get(stack.item) :: ItemRegistry.ItemDef
	local part = Instance.new("Part")
	part.Name = stack.item
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = true
	part.Material = Enum.Material.SmoothPlastic
	part.Color = Color3.fromRGB(def.color[1], def.color[2], def.color[3])
	part.Size = if def.block then Vector3.one * 0.75 else Vector3.new(0.7, 0.7, 0.15)
	local bx, bz = math.floor(pos.X / BS), math.floor(pos.Z / BS)
	local y = restY(bx, math.floor(pos.Y / BS), bz)
	local base = Vector3.new(pos.X, y, pos.Z)
	part.CFrame = CFrame.new(base)
	part:SetAttribute("Base", base) -- clients animate around this point
	part:SetAttribute("Count", stack.count)
	part.Parent = folder
	local now = os.clock()
	table.insert(entities, {
		part = part,
		stack = { item = stack.item, count = stack.count, durability = stack.durability },
		pickupAt = now + (pickupDelay or Config.ITEM_PICKUP_DELAY),
		despawnAt = now + Config.ITEM_DESPAWN_SECONDS,
		x = pos.X,
		z = pos.Z,
		y = y,
	})
end

-- Drop several stacks around a block (e.g. a broken chest), scattered a little.
function ItemEntityService.spawnAround(stacks: { Stack }, center: Vector3)
	for _, s in stacks do
		local offset = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5) * BS * 0.6
		ItemEntityService.spawn(s, center + offset)
	end
end

local resettleAcc = 0
local function update(dt: number)
	local now = os.clock()
	resettleAcc += dt
	local resettle = resettleAcc >= 0.5
	if resettle then
		resettleAcc = 0
	end

	local roots: { { player: Player, pos: Vector3 } } = {}
	for _, p in Players:GetPlayers() do
		local character = p.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and humanoid and humanoid.Health > 0 then
			table.insert(roots, { player = p, pos = root.Position })
		end
	end

	local radius = Config.ITEM_PICKUP_RADIUS * BS
	local i = 1
	while i <= #entities do
		local e = entities[i]
		local remove = now >= e.despawnAt or e.part.Parent == nil
		if not remove and resettle then
			-- the block it lay on may have been mined away
			local y = restY(math.floor(e.x / BS), math.floor((e.y - 0.45) / BS), math.floor(e.z / BS))
			if y ~= e.y then
				e.y = y
				local base = Vector3.new(e.x, y, e.z)
				e.part.CFrame = CFrame.new(base)
				e.part:SetAttribute("Base", base)
			end
		end
		if not remove and now >= e.pickupAt and addToInventory then
			local itemPos = Vector3.new(e.x, e.y, e.z)
			for _, r in roots do
				-- measured to the body centre, a little generous vertically
				local d = r.pos - itemPos
				if Vector3.new(d.X, d.Y * 0.6, d.Z).Magnitude <= radius then
					local left = (addToInventory :: (Player, Stack) -> number)(r.player, e.stack)
					if left == 0 then
						remove = true
						break
					elseif left ~= e.stack.count then
						e.stack.count = left
						e.part:SetAttribute("Count", left)
					end
				end
			end
		end
		if remove then
			e.part:Destroy()
			table.remove(entities, i)
		else
			i += 1
		end
	end
end

function ItemEntityService.init()
	folder = Instance.new("Folder")
	folder.Name = "ItemEntities"
	folder.Parent = workspace
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.1 then
			update(acc)
			acc = 0
		end
	end)
end

return ItemEntityService
