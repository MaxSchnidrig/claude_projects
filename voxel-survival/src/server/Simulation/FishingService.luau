--!strict
-- The client supplies aim and a use press. The server owns the float, bite clock and catch.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local Fishing = require(Shared.Items.Fishing)
local Enchantments = require(Shared.Items.Enchantments)
local Items = require(Shared.Items.ItemRegistry)
local Blocks = require(Shared.Blocks.BlockRegistry)
local Shapes = require(Shared.Blocks.Shapes)
local Fluids = require(Shared.World.Fluids)
local Ray = require(Shared.World.VoxelRaycast)
local World = require(script.Parent.Parent.World.WorldService)
local Inventory = require(script.Parent.Parent.Player.InventoryService)
local Drops = require(script.Parent.Parent.World.ItemEntityService)
local ExperienceService = require(script.Parent.Parent.Player.ExperienceService)
local Experience = require(Shared.Gameplay.Experience)
local remote = Remotes.get("Fishing")
local BS = Config.BLOCK_SIZE
local rng = Random.new()
local GRAVITY = Vector3.new(0, -22, 0)
local MAX_LINE = 32
local TICK = 1 / 30
type Cast = {
	root: BasePart, rod: Inventory.Stack, slot: number, float: Part, hand: Attachment,
	pos: Vector3, velocity: Vector3, age: number, water: Vector3?, landed: number, waitTime: number, phase: string,
}
local casts: { [Player]: Cast } = {}
local lastUse: { [Player]: number } = {}
local function finish(p: Player, message: string?)
	local c = casts[p]
	if c then
		casts[p] = nil
		c.float:Destroy()
		c.hand:Destroy()
	end
	if message and p.Parent then remote:FireClient(p, message, false) end
end

local function rootWithRod(p: Player): (BasePart?, Inventory.Stack?)
	local char = p.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local rod = Inventory.selectedStack(p)
	if not hum or hum.Health <= 0 or p:GetAttribute("Spectator") == true or not rod or rod.item ~= "fishing_rod" then
		return nil, nil
	end
	return char:FindFirstChild("HumanoidRootPart") :: BasePart?, rod
end

local function cast(p: Player, root: BasePart, rod: Inventory.Stack, look: Vector3)
	local hand = Instance.new("Attachment")
	hand.CFrame = CFrame.new(0.25 * BS, 0.1 * BS, -0.25 * BS)
	hand.Parent = root
	local height = if p.Character and p.Character:GetAttribute("Sneaking") then Config.EYE_HEIGHT_SNEAK else Config.EYE_HEIGHT
	local pos = (root.Position + Vector3.new(0, height, 0)) / BS
	local float = Instance.new("Part")
	float.Name = "FishingFloat"
	float.Shape = Enum.PartType.Ball
	float.Size = Vector3.new(0.23, 0.3, 0.23) * BS
	float.Color = Color3.fromRGB(242, 78, 55)
	float.Anchored = true
	float.CanCollide, float.CanTouch, float.CanQuery = false, false, false
	float.Position = pos * BS
	local hook = Instance.new("Attachment")
	hook.Parent = float
	local line = Instance.new("Beam")
	line.Attachment0, line.Attachment1 = hand, hook
	line.Width0, line.Width1 = 0.035 * BS, 0.018 * BS
	line.FaceCamera = true
	line.Color = ColorSequence.new(Color3.fromRGB(196, 205, 190))
	line.Parent = float
	float.Parent = workspace
	casts[p] = { root = root, rod = rod, slot = Inventory.selectedSlot(p), float = float, hand = hand,
		pos = pos, velocity = look * 16 + Vector3.new(0, 4, 0), age = 0, water = nil,
		landed = 0, waitTime = 0, phase = "flight" }
	remote:FireClient(p, "Casting…", true)
end

local function wet(cell: Vector3): (boolean, number)
	local kind, level = Fluids.info(World.getBlockIfLoaded(cell.X, cell.Y, cell.Z))
	return kind == "water", Fluids.height(level)
end

local function valid(c: Cast, p: Player): boolean
	local root, rod = rootWithRod(p)
	return root == c.root and rod == c.rod and Inventory.selectedSlot(p) == c.slot
		and (c.root.Position / BS - c.pos).Magnitude <= MAX_LINE
end

-- Wait for a bite: 5 to 14 s (this game's range), Lure takes 5 s off a level (Java), never
-- below 1 s.
local function waitFor(c: Cast): number
	return math.max(1, rng:NextNumber(5, 14) - 5 * Enchantments.level(c.rod, "lure"))
end

local function onUse(p: Player, aim: any)
	local now = os.clock()
	if now - (lastUse[p] or -1) < 0.18 then return end
	lastUse[p] = now
	local c = casts[p]
	if c then
		if not valid(c, p) then finish(p, "Line withdrawn") return end
		if c.water and wet(c.water) and Fishing.phase(now - c.landed, c.waitTime) == "bite" then
			-- Luck of the Sea shifts the catch toward treasure (Java quality weights)
			local luck = Enchantments.level(c.rod, "luck_of_the_sea")
			local item = Fishing.catch(rng:NextInteger(1, Fishing.categoryTotal(luck)), rng:NextInteger(1, 100), rng:NextInteger(1, 4), luck)
			local def = Items.get(item)
			assert(def, "Unknown fishing catch")
			local pos = c.root.Position
			local caughtAt = c.float.Position
			finish(p, nil)
			Inventory.damageSelectedTool(p, 1)
			local overflow = Inventory.add(p, item, 1)
			if overflow > 0 then
				Drops.spawn({ item = item, count = 1, durability = if def.tool then def.tool.durability else nil }, pos)
			end
			-- Java FishingHook.retrieve: one orb of 1-6 at the player (y + 0.5, z + 0.5)
			local feet = pos / BS - Vector3.new(0, 1, 0)
			ExperienceService.orb(feet + Vector3.new(0, 0.5, 0.5), rng:NextInteger(Experience.FISH[1], Experience.FISH[2]))
			remote:FireClient(p, if overflow > 0 then `Caught {def.name} · inventory full, dropped at your feet` else `Caught {def.name}`, false, item, caughtAt)
		else
			finish(p, "Reeled in empty")
		end
		return
	end
	local root, rod = rootWithRod(p)
	if root and rod and typeof(aim) == "Vector3" and aim.Magnitude > 0.99 and aim.Magnitude < 1.01 then
		cast(p, root, rod, aim.Unit)
	end
end

local function blocksHook(id: number): boolean
	return Blocks.isSolid[id + 1] or Blocks.isLiquid[id + 1]
end
local function shapeOf(id: number, x: number, y: number, z: number)
	if Blocks.isBoxShape[id + 1] then return Shapes.at(World.getBlockIfLoaded, x, y, z, true) end
	return nil
end
local function step(p: Player, c: Cast, now: number)
	c.age += TICK
	if not valid(c, p) or c.age > 90 then finish(p, "Line withdrawn") return end
	local cell = c.water
	if cell then
		local inWater, height = wet(cell)
		if not inWater then finish(p, "The float is out of water") return end
		local phase = Fishing.phase(now - c.landed, c.waitTime)
		if phase == "missed" then
			c.landed, c.waitTime = now, waitFor(c)
			phase = "waiting"
			remote:FireClient(p, "Missed the bite · waiting for another", true)
		elseif phase ~= c.phase then
			remote:FireClient(p, "Bite! Reel in!", true)
		end
		c.phase = phase
		local dip = if phase == "bite" then -0.18 else 0.04
		c.float.Position = Vector3.new(c.pos.X, cell.Y + height + dip + math.sin(c.age * 4) * 0.025, c.pos.Z) * BS
		return
	end
	local delta = (c.velocity + GRAVITY * (TICK / 2)) * TICK
	local hit = Ray.cast(World.getBlockIfLoaded, c.pos.X, c.pos.Y, c.pos.Z, delta.X, delta.Y, delta.Z, delta.Magnitude, blocksHook, shapeOf)
	if hit then
		local water = Vector3.new(hit.x, hit.y, hit.z)
		if not wet(water) or Fluids.info(World.getBlockIfLoaded(hit.x, hit.y + 1, hit.z)) == "water" then
			finish(p, "Cast into open water") return
		end
		c.water, c.pos = water, Vector3.new(hit.px, hit.py, hit.pz)
		c.landed, c.waitTime, c.phase = now, waitFor(c), "waiting"
		remote:FireClient(p, "Watch the float…", true)
	else
		c.velocity += GRAVITY * TICK
		c.pos += delta
		if c.age > 3 or World.getBlockIfLoaded(math.floor(c.pos.X), math.floor(c.pos.Y), math.floor(c.pos.Z)) == nil then
			finish(p, "Cast closer to shore") return
		end
	end
	c.float.Position = c.pos * BS
end
local FishingService = {}
function FishingService.init()
	remote.OnServerEvent:Connect(onUse)
	Players.PlayerRemoving:Connect(function(p)
		finish(p, nil)
		lastUse[p] = nil
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc = math.min(0.25, acc + dt)
		while acc >= TICK do
			acc -= TICK
			local now = os.clock()
			for p, c in casts do step(p, c, now) end
		end
	end)
end
return FishingService
