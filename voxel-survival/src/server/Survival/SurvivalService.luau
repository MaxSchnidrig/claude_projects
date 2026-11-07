--!strict
-- Health, hunger, air, fall damage, lava, eating, death and respawn, all server-side.
--
-- Health is the Humanoid's Health (MaxHealth 20), changed only by this service. The server has no
-- terrain physics, so ground contact, water and lava are read from the voxel data at the
-- character's position (client-reported, like all character physics on Roblox).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local SurvivalRules = require(Shared.Gameplay.SurvivalRules)
local WorldService = require(script.Parent.Parent.World.WorldService)
local InventoryService = require(script.Parent.Parent.Player.InventoryService)
local SpawnService = require(script.Parent.Parent.Player.SpawnService)
local BlockActionService = require(script.Parent.Parent.Interaction.BlockActionService)
local DayNightService = require(script.Parent.DayNightService)

local BS = Config.BLOCK_SIZE
local FEET_BELOW_ROOT = 3 -- R6: HumanoidRootPart centre is 3 studs above the feet
local EAT_SECONDS = 1.6
local LAVA = BlockRegistry.id("lava")
local isSolid = BlockRegistry.isSolid
local isLiquid = BlockRegistry.isLiquid
local MIN_STARVE_HEALTH = ({ easy = 10, normal = 1, hard = 0 } :: { [string]: number })[Config.DIFFICULTY] or 1

type State = {
	hunger: SurvivalRules.Hunger,
	air: number,
	drownTimer: number,
	lavaTimer: number,
	peakFeetY: number?,
	wasGrounded: boolean,
	lastPos: Vector3?,
	sprinting: boolean,
	eatingSince: number?,
	eatingSlot: number,
	dead: boolean,
	lastSent: string,
	diedAt: number,
	lastCause: string?,
	heights: { { t: number, y: number } },
}

local SurvivalService = {}
local states: { [Player]: State } = {}

local function newState(): State
	return {
		hunger = SurvivalRules.newHunger(),
		air = SurvivalRules.MAX_AIR,
		drownTimer = 0,
		lavaTimer = 0,
		peakFeetY = nil,
		wasGrounded = true,
		lastPos = nil,
		sprinting = false,
		eatingSince = nil,
		eatingSlot = 0,
		dead = false,
		lastSent = "",
		diedAt = 0,
		lastCause = nil,
		heights = {},
	}
end

local function state(p: Player): State
	local s = states[p]
	if not s then
		s = newState()
		states[p] = s
	end
	return s
end

local function humanoidOf(p: Player): (Humanoid?, BasePart?)
	local c = p.Character
	if not c then
		return nil, nil
	end
	return c:FindFirstChildOfClass("Humanoid"), c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function sync(p: Player, event: string?, cause: string?)
	local s = state(p)
	local h = s.hunger
	local payload = {
		food = h.food,
		saturation = math.floor(h.saturation * 10) / 10,
		air = math.ceil(s.air * 2) / 2,
		maxAir = SurvivalRules.MAX_AIR,
		canSprint = SurvivalRules.canSprint(h),
		event = event,
		cause = cause,
	}
	local key = `{payload.food}|{payload.saturation}|{payload.air}|{payload.canSprint}`
	if event or key ~= s.lastSent then
		s.lastSent = key
		Remotes.get("SurvivalSync"):FireClient(p, payload)
	end
end

-- Apply damage (HP). `cause` is shown on the death screen.
function SurvivalService.damage(p: Player, amount: number, cause: string)
	local humanoid = humanoidOf(p)
	local s = state(p)
	if not humanoid or s.dead or humanoid.Health <= 0 or amount <= 0 then
		return
	end
	SurvivalRules.addExhaustion(s.hunger, SurvivalRules.EXHAUSTION.damage)
	s.lastCause = cause
	humanoid.Health = math.max(0, humanoid.Health - amount)
	sync(p, "hurt", cause)
end

function SurvivalService.addExhaustion(p: Player, amount: number)
	SurvivalRules.addExhaustion(state(p).hunger, amount)
end

-- Block at world block coords (0 for out of range).
local function block(x: number, y: number, z: number): number
	return WorldService.getBlock(x, y, z)
end

local function stepPlayer(p: Player, s: State, dt: number)
	local humanoid, root = humanoidOf(p)
	if not humanoid or not root or humanoid.Health <= 0 or s.dead then
		return
	end
	local pos = root.Position
	local feetY = pos.Y - FEET_BELOW_ROOT
	local bx, bz = math.floor(pos.X / BS), math.floor(pos.Z / BS)
	local feetBlock = block(bx, math.floor((feetY + 0.1) / BS), bz)
	local bodyBlock = block(bx, math.floor((pos.Y) / BS), bz)
	local eyeBlock = block(bx, math.floor((pos.Y + Config.EYE_HEIGHT) / BS), bz)
	local belowY = math.floor((feetY - 0.1) / BS)
	local grounded = isSolid[block(bx, belowY, bz) + 1] and feetY - (belowY + 1) * BS <= 0.4

	-- Recent heights, to sanity-check falls the client reports (see "fall" action).
	table.insert(s.heights, { t = os.clock(), y = feetY })
	while #s.heights > 0 and os.clock() - s.heights[1].t > 8 do
		table.remove(s.heights, 1)
	end

	-- Exhaustion from jumping and sprinting.
	local vy = root.AssemblyLinearVelocity.Y
	if s.wasGrounded and not grounded and vy > 12 then
		SurvivalRules.addExhaustion(s.hunger, if s.sprinting then SurvivalRules.EXHAUSTION.sprintJump else SurvivalRules.EXHAUSTION.jump)
	end
	s.wasGrounded = grounded
	if s.lastPos and s.sprinting then
		local d = Vector3.new(pos.X - s.lastPos.X, 0, pos.Z - s.lastPos.Z).Magnitude / BS
		if d < 2 then -- ignore teleports
			SurvivalRules.addExhaustion(s.hunger, d * SurvivalRules.EXHAUSTION.sprintPerBlock)
		end
	end
	s.lastPos = pos
	if s.sprinting and not SurvivalRules.canSprint(s.hunger) then
		s.sprinting = false -- client is told via canSprint in the next sync
	end

	-- Air / drowning
	if isLiquid[eyeBlock + 1] then
		s.air = math.max(0, s.air - dt)
		if s.air <= 0 then
			s.drownTimer += dt
			while s.drownTimer >= 1 do
				s.drownTimer -= 1
				SurvivalService.damage(p, SurvivalRules.DROWN_DAMAGE, "drowned")
			end
		end
	else
		s.air = math.min(SurvivalRules.MAX_AIR, s.air + dt * 5)
		s.drownTimer = 0
	end

	-- Lava
	if feetBlock == LAVA or bodyBlock == LAVA then
		s.lavaTimer += dt
		while s.lavaTimer >= 0.5 do
			s.lavaTimer -= 0.5
			SurvivalService.damage(p, SurvivalRules.LAVA_DAMAGE, "tried to swim in lava")
		end
	else
		s.lavaTimer = 0.5 -- first touch hurts immediately
	end

	-- Out of the world
	if pos.Y < -64 then
		SurvivalService.damage(p, 1000, "fell out of the world")
	end

	-- Regeneration / starvation
	local heal, starve = SurvivalRules.tick(s.hunger, dt, humanoid.Health, humanoid.MaxHealth, MIN_STARVE_HEALTH)
	if heal > 0 then
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + heal)
	end
	if starve > 0 then
		SurvivalService.damage(p, starve, "starved")
	end
	sync(p)
end

local function onAction(p: Player, a: any)
	if typeof(a) ~= "table" or typeof(a.type) ~= "string" then
		return
	end
	local s = state(p)
	local t = a.type
	if t == "fall" then
		-- The client measures falls from its real ground contact. The server only checks the
		-- claim against the descent it actually saw (recent highest point minus current height).
		if typeof(a.blocks) ~= "number" or a.blocks ~= a.blocks or s.dead then
			return
		end
		local humanoid, root = humanoidOf(p)
		if not humanoid or not root then
			return
		end
		local feetY = root.Position.Y - FEET_BELOW_ROOT
		local highest = feetY
		for _, h in s.heights do
			highest = math.max(highest, h.y)
		end
		local seen = (highest - feetY) / BS + 1 -- +1 block of slack for timing
		local bx, bz = math.floor(root.Position.X / BS), math.floor(root.Position.Z / BS)
		local here = block(bx, math.floor((feetY + 0.1) / BS), bz)
		local dmg = SurvivalRules.fallDamage(math.clamp(a.blocks, 0, seen), isLiquid[here + 1])
		if dmg > 0 then
			SurvivalService.damage(p, dmg, "fell from a high place")
		end
		table.clear(s.heights) -- a fall is only counted once
	elseif t == "sprint" then
		s.sprinting = a.on == true and SurvivalRules.canSprint(s.hunger)
	elseif t == "eatStart" then
		s.eatingSince = os.clock()
		s.eatingSlot = InventoryService.selectedSlot(p)
	elseif t == "eatCancel" then
		s.eatingSince = nil
	elseif t == "eatFinish" then
		local since = s.eatingSince
		s.eatingSince = nil
		if not since or os.clock() - since < EAT_SECONDS - 0.15 or s.dead then
			return
		end
		if InventoryService.selectedSlot(p) ~= s.eatingSlot then
			return
		end
		local stack = InventoryService.selectedStack(p)
		local def = stack and ItemRegistry.get(stack.item)
		local food = def and def.food
		if not food or s.hunger.food >= SurvivalRules.MAX_FOOD then
			return
		end
		if InventoryService.consumeSelected(p, 1) then
			SurvivalRules.eat(s.hunger, food.hunger, food.saturation)
			sync(p)
		end
	elseif t == "respawn" then
		if s.dead then
			SpawnService.respawn(p)
		end
	end
end

local function onCharacter(p: Player, character: Model)
	local s = state(p)
	-- A fresh life: full health and hunger (classic respawn).
	local fresh = newState()
	states[p] = fresh
	s = fresh
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	-- Roblox's default "Health" script regenerates 1% per second; our rules replace it.
	local regen = character:FindFirstChild("Health")
	if regen and regen:IsA("BaseScript") then
		regen:Destroy()
	end
	humanoid.MaxHealth = SurvivalRules.MAX_HEALTH
	humanoid.Health = SurvivalRules.MAX_HEALTH
	humanoid.Died:Connect(function()
		if s.dead then
			return
		end
		s.dead = true
		s.diedAt = os.clock()
		-- Freeze the body where it died: the server has no terrain collision, so unanchored
		-- body parts would fall through the world (and the camera with them).
		for _, d in character:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
			end
		end
		local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			InventoryService.dropAll(p, root.Position)
		end
		sync(p, "died", s.lastCause or "died")
	end)
	sync(p, "spawned")
end

function SurvivalService.init()
	BlockActionService.setBlockBrokenCallback(function(p: Player)
		SurvivalService.addExhaustion(p, SurvivalRules.EXHAUSTION.breakBlock)
	end)
	Remotes.get("SurvivalAction").OnServerEvent:Connect(onAction)

	-- Studio-only debug keys (skip time, hurt yourself) for testing.
	Remotes.get("DebugAction").OnServerEvent:Connect(function(p: Player, a: any)
		if not RunService:IsStudio() or typeof(a) ~= "table" then
			return
		end
		if a.type == "skipTime" then
			DayNightService.addTicks(6000)
		elseif a.type == "hurtSelf" then
			SurvivalService.damage(p, 3, "hurt themselves (debug)")
		end
	end)

	local function onPlayer(p: Player)
		p.CharacterAdded:Connect(function(c)
			onCharacter(p, c)
		end)
		if p.Character then
			onCharacter(p, p.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(p)
		states[p] = nil
	end)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc < 0.05 then
			return
		end
		local step = math.min(acc, 0.5)
		acc = 0
		for p, s in states do
			if p.Parent then
				stepPlayer(p, s, step)
				-- safety net: respawn if the death screen never answered
				if s.dead and os.clock() - s.diedAt > Config.AUTO_RESPAWN_SECONDS then
					s.diedAt = math.huge
					SpawnService.respawn(p)
				end
			end
		end
	end)
end

return SurvivalService
