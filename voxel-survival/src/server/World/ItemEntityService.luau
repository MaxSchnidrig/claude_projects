--!strict
-- Dropped items lying in the world (mined blocks, thrown items, container contents).
--
-- The server advances dropped stacks against the voxel shapes. Clients smooth the snapshots.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Shapes = require(Shared.Blocks.Shapes)
local Physics = require(Shared.Mobs.MobPhysics)
local ItemMotion = require(Shared.Gameplay.ItemMotion)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local WorldService = require(script.Parent.WorldService)

local BS = Config.BLOCK_SIZE
local H = Config.WORLD_HEIGHT
local solid = Shapes.physicsFn(WorldService.getBlock)
local function baseOf(s: ItemMotion.State): Vector3
	return Vector3.new(s.x * BS, s.y * BS + 0.45, s.z * BS)
end

export type Stack = { item: string, count: number, durability: number?, ench: { [string]: number }? }
type Entity = { part: Part, stack: Stack, pickupAt: number, despawnAt: number, motion: ItemMotion.State }

local ItemEntityService = {}
local entities: { Entity } = {}
local folder: Folder
local addToInventory: ((Player, Stack) -> number)? = nil -- set by InventoryService (avoids a require cycle)

function ItemEntityService.setInventoryAdder(fn: (Player, Stack) -> number)
	addToInventory = fn
end

-- Drop `stack` near world position `pos` (studs).
function ItemEntityService.spawn(stack: Stack, pos: Vector3, pickupDelay: number?, velocity: Vector3?)
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
	local v = velocity or Vector3.new(math.random() - 0.5, 1.6, math.random() - 0.5)
	local m: ItemMotion.State = { x = pos.X / BS, y = (pos.Y - 0.45) / BS, z = pos.Z / BS,
		vx = v.X, vy = v.Y, vz = v.Z, resting = false }
	-- Loot can originate inside a solid block (e.g. container overflow).
	while m.y < H and Physics.collides(solid, m.x, m.y, m.z, ItemMotion.SIZE, ItemMotion.SIZE) do
		m.y = math.floor(m.y) + 1
	end
	local base = baseOf(m)
	part:SetAttribute("Airborne", true)
	part.CFrame = CFrame.new(base)
	part:SetAttribute("Base", base) -- clients animate around this point
	part:SetAttribute("Count", stack.count)
	if stack.ench then
		part:SetAttribute("Glint", true) -- enchanted: drawn with the shimmer
	end
	part.Parent = folder
	local now = os.clock()
	table.insert(entities, {
		part = part,
		stack = { item = stack.item, count = stack.count, durability = stack.durability, ench = stack.ench },
		pickupAt = now + (pickupDelay or Config.ITEM_PICKUP_DELAY),
		despawnAt = now + Config.ITEM_DESPAWN_SECONDS,
		motion = m,
	})
end

-- Lightning burns up dropped items in its box (block units).
function ItemEntityService.removeIn(lo: Vector3, hi: Vector3): number
	local n = 0
	for i = #entities, 1, -1 do
		local e = entities[i]
		local p = baseOf(e.motion) / BS
		if p.X >= lo.X and p.X <= hi.X and p.Y >= lo.Y and p.Y <= hi.Y and p.Z >= lo.Z and p.Z <= hi.Z then
			e.part:Destroy()
			table.remove(entities, i)
			n += 1
		end
	end
	return n
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
		if root and humanoid and humanoid.Health > 0 and p:GetAttribute("Spectator") ~= true then
			table.insert(roots, { player = p, pos = root.Position })
		end
	end

	local radius = Config.ITEM_PICKUP_RADIUS * BS
	local i = 1
	while i <= #entities do
		local e = entities[i]
		local remove = now >= e.despawnAt or e.part.Parent == nil
		local m = e.motion
		if not remove and (not m.resting or resettle) then
			local before = baseOf(m)
			ItemMotion.step(m, solid)
			local base = baseOf(m)
			if base ~= before then
				e.part.CFrame = CFrame.new(base)
				e.part:SetAttribute("Base", base)
			end
			e.part:SetAttribute("Airborne", not m.resting)
			remove = m.y < -4
		end
		if not remove and now >= e.pickupAt and addToInventory then
			local itemPos = baseOf(m)
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
		acc = math.min(acc + dt, 0.25)
		while acc >= ItemMotion.TICK do
			update(ItemMotion.TICK)
			acc -= ItemMotion.TICK
		end
	end)
end

return ItemEntityService
