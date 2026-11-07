--!strict
-- Server-side mobs: registry, physics tick, damage/death/drops, player attacks and snapshots.
--
-- Mobs are pure data on the server (no Instances). Each tick (20 Hz) the AI (MobAI) sets a
-- desired velocity, MobPhysics moves the mob's box through the voxel world, and the environment
-- (falls, lava, daylight burning) applies. Every 0.1 s each player receives a compact snapshot of
-- nearby mobs (MobSnapshot, unreliable); clients build, interpolate and animate the models.
-- Natural spawning/despawning lives in MobSpawner.
--
-- Units: BLOCKS everywhere in here (positions are feet centres); converted to studs at the edges.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local MobDefs = require(Shared.Mobs.MobDefs)
local MobPhysics = require(Shared.Mobs.MobPhysics)
local Combat = require(Shared.Gameplay.Combat)
local Crafting = require(Shared.Items.Crafting)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local VoxelRaycast = require(Shared.World.VoxelRaycast)
local SurvivalRules = require(Shared.Gameplay.SurvivalRules)
local MobSnapshotCodec = require(Shared.Mobs.MobSnapshotCodec)
local WorldService = require(script.Parent.Parent.World.WorldService)
local ItemEntityService = require(script.Parent.Parent.World.ItemEntityService)
local ExplosionService = require(script.Parent.Parent.World.ExplosionService)
local InventoryService = require(script.Parent.Parent.Player.InventoryService)
local SurvivalService = require(script.Parent.Parent.Survival.SurvivalService)
local DayNightService = require(script.Parent.Parent.Survival.DayNightService)

local BS = Config.BLOCK_SIZE
local H = Config.WORLD_HEIGHT
local GRAVITY = 32 -- blocks/s^2 (classic)
local TERMINAL = 40
local LAVA = BlockRegistry.id("lava")
local isSolid = BlockRegistry.isSolid
local isOpaque = BlockRegistry.isOpaque
local isLiquid = BlockRegistry.isLiquid

export type Mob = {
	id: number,
	def: MobDefs.MobDef,
	x: number,
	y: number,
	z: number,
	vx: number,
	vy: number,
	vz: number,
	yaw: number,
	pitch: number,
	health: number,
	onGround: boolean,
	hitWall: boolean,
	inLiquid: boolean,
	-- AI scratch (owned by MobAI)
	ai: { [string]: any },
	-- desired horizontal velocity and jump request, set by the AI each tick
	wantX: number,
	wantZ: number,
	wantJump: boolean,
	knockbackUntil: number,
	invulnUntil: number,
	burning: number, -- seconds left
	burnTimer: number,
	lavaTimer: number,
	peakY: number,
	flags: number,
	alive: boolean,
	lastAttacker: Player?,
	-- projectiles
	owner: string?,
	damage: number?,
	stuck: number?,
}

local FLAG = { BURNING = 1, FUSING = 2, ANGRY = 4, PANIC = 8, STUCK = 32 }

local MobService = {}
MobService.FLAG = FLAG
MobService.stats = { spawned = 0, alive = 0, killed = 0, despawned = 0 }
MobService.mobs = {} :: { [number]: Mob }

local mobs = MobService.mobs
local nextId = 1
local lastSwing: { [Player]: number } = {}
local ai: any = nil -- MobAI module (set in init)

---------------------------------------------------------------------------------------------
-- World queries (block units)
---------------------------------------------------------------------------------------------

-- Unloaded blocks count as solid: mobs never walk (or fall) into chunks the server hasn't loaded.
local function solid(x: number, y: number, z: number): boolean
	local id = WorldService.getBlockIfLoaded(x, y, z)
	return id == nil or isSolid[id + 1]
end
MobService.solid = solid

function MobService.blockAt(x: number, y: number, z: number): number?
	return WorldService.getBlockIfLoaded(x, y, z)
end

-- Open sky above (no opaque block between y and the top of the world).
function MobService.skyExposed(x: number, y: number, z: number): boolean
	for yy = math.max(0, y), H - 1 do
		local id = WorldService.getBlockIfLoaded(x, yy, z)
		if id == nil then
			return false
		end
		if isOpaque[id + 1] then
			return false
		end
	end
	return true
end

function MobService.isDay(): boolean
	return DayNightService.timeOfDay() < 12500
end

-- Voxel line of sight between two block-unit points.
function MobService.lineOfSight(a: Vector3, b: Vector3): boolean
	local d = b - a
	local dist = d.Magnitude
	if dist < 0.01 then
		return true
	end
	local hit = VoxelRaycast.cast(function(x, y, z)
		return WorldService.getBlockIfLoaded(x, y, z) or 1
	end, a.X, a.Y, a.Z, d.X, d.Y, d.Z, dist, function(id)
		return isOpaque[id + 1]
	end)
	return hit == nil
end

-- Living players with their positions (block units: feet centre, eye).
export type Target = { player: Player, feet: Vector3, eye: Vector3, root: BasePart }
function MobService.targets(): { Target }
	local list = {}
	for _, p in Players:GetPlayers() do
		local c = p.Character
		local h = c and c:FindFirstChildOfClass("Humanoid")
		local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		if h and root and h.Health > 0 then
			local pos = root.Position
			table.insert(list, {
				player = p,
				feet = Vector3.new(pos.X, pos.Y - 3, pos.Z) / BS,
				eye = (pos + Vector3.new(0, Config.EYE_HEIGHT, 0)) / BS,
				root = root,
			})
		end
	end
	return list
end

---------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------

function MobService.spawn(key: string, x: number, y: number, z: number, yaw: number?): Mob?
	local def = MobDefs.byKey[key]
	if not def then
		return nil
	end
	local m: Mob = {
		id = nextId,
		def = def,
		x = x,
		y = y,
		z = z,
		vx = 0,
		vy = 0,
		vz = 0,
		yaw = yaw or math.random() * math.pi * 2,
		pitch = 0,
		health = def.health,
		onGround = false,
		hitWall = false,
		inLiquid = false,
		ai = {},
		wantX = 0,
		wantZ = 0,
		wantJump = false,
		knockbackUntil = 0,
		invulnUntil = 0,
		burning = 0,
		burnTimer = 0,
		lavaTimer = 0,
		peakY = y,
		flags = 0,
		alive = true,
		lastAttacker = nil,
	}
	nextId = (nextId % 60000) + 1
	mobs[m.id] = m
	MobService.stats.spawned += 1
	return m
end

function MobService.remove(m: Mob)
	m.alive = false
	mobs[m.id] = nil
end

local function broadcastEvent(e: { [string]: any }, near: Vector3)
	local remote = Remotes.get("MobEvent")
	for _, t in MobService.targets() do
		if (t.feet - near).Magnitude <= Config.MOB_SEND_DISTANCE then
			remote:FireClient(t.player, e)
		end
	end
end
MobService.broadcastEvent = broadcastEvent

local function die(m: Mob)
	if not m.alive then
		return
	end
	MobService.remove(m)
	MobService.stats.killed += 1
	local center = Vector3.new(m.x, m.y + m.def.height / 2, m.z)
	broadcastEvent({ type = "died", id = m.id }, center)
	-- drops (meat comes out cooked if the mob was burning)
	local stacks = {}
	for _, d in m.def.drops do
		local n = math.random(d.min, d.max)
		if n > 0 then
			local item = d.item
			if m.burning > 0 then
				item = Crafting.smeltResult(item) or item
				if not ItemRegistry.get(item) then
					item = d.item
				end
			end
			table.insert(stacks, { item = item, count = n })
		end
	end
	ItemEntityService.spawnAround(stacks, center * BS)
end

-- Damage a mob. `from` (block units) pushes it away; `attacker` makes neutrals angry.
function MobService.damage(m: Mob, amount: number, attacker: Player?, from: Vector3?)
	local now = os.clock()
	if not m.alive or now < m.invulnUntil or m.def.category == "projectile" then
		return
	end
	m.invulnUntil = now + 0.5
	m.health -= amount
	m.lastAttacker = attacker
	if from then
		local dx, dz = m.x - from.X, m.z - from.Z
		local len = math.sqrt(dx * dx + dz * dz)
		if len > 0.01 then
			m.vx = dx / len * Combat.KNOCKBACK_HORIZONTAL
			m.vz = dz / len * Combat.KNOCKBACK_HORIZONTAL
		end
		m.vy = Combat.KNOCKBACK_UP
		m.knockbackUntil = now + 0.35
	end
	broadcastEvent({ type = "hurt", id = m.id }, Vector3.new(m.x, m.y, m.z))
	if ai then
		ai.onHurt(m, attacker)
	end
	if m.health <= 0 then
		die(m)
	end
end

-- Explosion damage to every mob in range (hook for ExplosionService).
local function explosionDamage(center: Vector3, power: number)
	for _, m in mobs do
		local c = Vector3.new(m.x, m.y + m.def.height / 2, m.z)
		local d = (c - center).Magnitude
		local dmg = Combat.explosionDamage(power, d)
		if dmg > 0 then
			m.invulnUntil = 0
			MobService.damage(m, dmg, nil, center)
		end
	end
end

-- Damage a player from a mob (melee / arrow) with knockback away from `from`.
function MobService.hurtPlayer(t: Target, amount: number, cause: string, from: Vector3)
	SurvivalService.damage(t.player, amount, cause)
	local d = Vector3.new(t.feet.X - from.X, 0, t.feet.Z - from.Z)
	d = if d.Magnitude > 0.01 then d.Unit else Vector3.xAxis
	local v = (d * Combat.KNOCKBACK_HORIZONTAL + Vector3.new(0, Combat.KNOCKBACK_UP, 0)) * BS
	Remotes.get("Knockback"):FireClient(t.player, v)
end

---------------------------------------------------------------------------------------------
-- Physics + environment
---------------------------------------------------------------------------------------------

local function stepPhysics(m: Mob, dt: number)
	local now = os.clock()
	local def = m.def
	local w, h = def.width, def.height
	local feetId = MobService.blockAt(math.floor(m.x), math.floor(m.y + 0.1), math.floor(m.z))
	m.inLiquid = feetId ~= nil and isLiquid[feetId + 1]

	if now >= m.knockbackUntil then
		m.vx, m.vz = m.wantX, m.wantZ
	else
		m.vx *= 0.9
		m.vz *= 0.9
	end
	if m.inLiquid then
		m.vy = math.min(m.vy + 20 * dt, 2) -- buoyancy: float up slowly
		m.vx *= 0.6
		m.vz *= 0.6
	else
		m.vy = math.max(m.vy - GRAVITY * dt, -TERMINAL)
		if def.key == "chicken" then
			m.vy = math.max(m.vy, -3) -- flaps its wings
		end
	end
	if m.wantJump and (m.onGround or m.inLiquid) then
		m.vy = 8.4 -- ~1.1 blocks
	end
	if def.canClimb and m.hitWall and (m.wantX ~= 0 or m.wantZ ~= 0) then
		m.vy = 3 -- spiders climb walls
	end
	m.wantJump = false

	local wasGround = m.onGround
	m.x, m.y, m.z, m.vx, m.vy, m.vz, m.onGround, m.hitWall =
		MobPhysics.move(solid, m.x, m.y, m.z, m.vx, m.vy, m.vz, w, h, dt)

	-- fall damage (not chickens / not into liquid)
	if m.onGround or m.inLiquid then
		if not wasGround and def.key ~= "chicken" and not m.inLiquid then
			local dmg = SurvivalRules.fallDamage(m.peakY - m.y, false)
			if dmg > 0 then
				m.invulnUntil = 0
				MobService.damage(m, dmg, nil, nil)
			end
		end
		m.peakY = m.y
	else
		m.peakY = math.max(m.peakY, m.y)
	end

	-- lava and daylight burning
	local bodyId = MobService.blockAt(math.floor(m.x), math.floor(m.y + h / 2), math.floor(m.z))
	if feetId == LAVA or bodyId == LAVA then
		m.burning = 8
		m.lavaTimer += dt
		if m.lavaTimer >= 0.5 then
			m.lavaTimer = 0
			m.invulnUntil = 0
			MobService.damage(m, 4, nil, nil)
		end
	end
	if def.undead and MobService.isDay() and not m.inLiquid
		and MobService.skyExposed(math.floor(m.x), math.floor(m.y + h), math.floor(m.z))
	then
		m.burning = math.max(m.burning, 1)
	end
	if m.inLiquid then
		m.burning = 0
	end
	if m.burning > 0 then
		m.burning -= dt
		m.burnTimer += dt
		if m.burnTimer >= 1 then
			m.burnTimer = 0
			m.invulnUntil = 0
			MobService.damage(m, 1, nil, nil)
		end
	end
	if m.y < -10 then
		MobService.remove(m)
	end
end

-- Arrows: ballistic, hit players (and stick in blocks).
local function stepProjectile(m: Mob, dt: number)
	if m.stuck then
		m.stuck -= dt
		if (m.stuck :: number) <= 0 then
			MobService.remove(m)
		end
		return
	end
	m.vy = math.max(m.vy - 20 * dt, -TERMINAL)
	local steps = math.max(1, math.ceil(math.sqrt(m.vx * m.vx + m.vy * m.vy + m.vz * m.vz) * dt / 0.25))
	local sdt = dt / steps
	for _ = 1, steps do
		local nx, ny, nz = m.x + m.vx * sdt, m.y + m.vy * sdt, m.z + m.vz * sdt
		if solid(math.floor(nx), math.floor(ny), math.floor(nz)) then
			m.stuck = 10
			m.flags = FLAG.STUCK
			return
		end
		m.x, m.y, m.z = nx, ny, nz
		for _, t in MobService.targets() do
			local f = t.feet
			if math.abs(m.x - f.X) < 0.45 and math.abs(m.z - f.Z) < 0.45 and m.y >= f.Y and m.y <= f.Y + 1.8 then
				MobService.hurtPlayer(t, m.damage or 2, `was shot by {m.owner or "an arrow"}`, Vector3.new(m.x - m.vx, m.y, m.z - m.vz))
				MobService.remove(m)
				return
			end
		end
	end
	local horizontal = math.sqrt(m.vx * m.vx + m.vz * m.vz)
	m.yaw = math.atan2(-m.vx, -m.vz)
	m.pitch = math.atan2(m.vy, horizontal)
	if m.y < -10 then
		MobService.remove(m)
	end
end

-- Fire an arrow (block units) from `from` with velocity `vel`.
function MobService.shootArrow(from: Vector3, vel: Vector3, damage: number, owner: string)
	local a = MobService.spawn("arrow", from.X, from.Y, from.Z)
	if a then
		a.vx, a.vy, a.vz = vel.X, vel.Y, vel.Z
		a.damage = damage
		a.owner = owner
	end
end

---------------------------------------------------------------------------------------------
-- Player attacks
---------------------------------------------------------------------------------------------

local function onAttack(p: Player, id: any)
	if typeof(id) ~= "number" then
		return
	end
	local m = mobs[id]
	local c = p.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not m or not m.alive or m.def.category == "projectile" or not h or not root or h.Health <= 0 then
		return
	end
	local eye = (root.Position + Vector3.new(0, Config.EYE_HEIGHT, 0)) / BS
	-- distance from the eye to the mob's box
	local hw = m.def.width / 2
	local closest = Vector3.new(
		math.clamp(eye.X, m.x - hw, m.x + hw),
		math.clamp(eye.Y, m.y, m.y + m.def.height),
		math.clamp(eye.Z, m.z - hw, m.z + hw)
	)
	if (closest - eye).Magnitude > Combat.MELEE_REACH + 1 then
		return -- out of reach (with latency slack)
	end
	if not MobService.lineOfSight(eye, closest) then
		return
	end
	local stack = InventoryService.selectedStack(p)
	local item = stack and stack.item
	local base, cooldown = Combat.attackStats(item)
	local now = os.clock()
	local since = now - (lastSwing[p] or 0)
	lastSwing[p] = now
	MobService.damage(m, Combat.scaledDamage(base, since, cooldown), p, eye)
	SurvivalService.addExhaustion(p, 0.1)
	local def = ItemRegistry.get(item)
	if def and def.tool then
		InventoryService.damageSelectedTool(p, if def.tool.kind == "sword" then 1 else 2)
	end
end

---------------------------------------------------------------------------------------------
-- Snapshots
---------------------------------------------------------------------------------------------

local function sendSnapshots()
	local remote = Remotes.getUnreliable("MobSnapshot")
	local range2 = Config.MOB_SEND_DISTANCE ^ 2
	for _, t in MobService.targets() do
		local records = {}
		for _, m in mobs do
			local dx, dz = m.x - t.feet.X, m.z - t.feet.Z
			if dx * dx + dz * dz <= range2 then
				table.insert(records, {
					id = m.id,
					code = m.def.code,
					flags = bit32.bor(m.flags, if m.burning > 0 then FLAG.BURNING else 0),
					x = m.x * BS,
					y = m.y * BS,
					z = m.z * BS,
					yaw = m.yaw,
					pitch = m.pitch,
				})
			end
		end
		-- small binary packets: unreliable events over ~900 bytes are dropped by Roblox
		for _, packet in MobSnapshotCodec.encode(records) do
			remote:FireClient(t.player, packet)
		end
		MobService.stats.lastSent = #records
	end
end

---------------------------------------------------------------------------------------------

function MobService.count(category: string, near: Vector3?, radius: number?): number
	local n = 0
	for _, m in mobs do
		if m.def.category == category then
			if not near or (Vector3.new(m.x, m.y, m.z) - near).Magnitude <= (radius or math.huge) then
				n += 1
			end
		end
	end
	return n
end

function MobService.init()
	ai = require(script.Parent.MobAI)
	ai.init(MobService)
	local spawner = require(script.Parent.MobSpawner)
	spawner.init(MobService)

	-- shiftlings guard their ground; Studio key L spawns mobs for testing
	require(script.Parent.Parent.Interaction.BlockActionService).onBlockBroken(ai.blockBroken)
	Remotes.get("DebugAction").OnServerEvent:Connect(function(p: Player, a: any)
		if RunService:IsStudio() and typeof(a) == "table" and a.type == "spawnMob" then
			for _, t in MobService.targets() do
				if t.player == p then
					local key = spawner.debugSpawn(t)
					print(`[MobService] debug spawn: {key or "no room"}`)
				end
			end
		end
	end)

	ExplosionService.setHooks(function(p: Player, amount: number, cause: string)
		SurvivalService.damage(p, amount, cause)
	end, explosionDamage)

	Remotes.get("AttackMob").OnServerEvent:Connect(onAttack)
	Players.PlayerRemoving:Connect(function(p)
		lastSwing[p] = nil
	end)

	local acc, snapAcc = 0, 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		snapAcc += dt
		if acc >= 0.05 then
			local step = math.min(acc, 0.1)
			acc = 0
			local targets = MobService.targets()
			local alive = 0
			for _, m in mobs do
				if m.alive then
					if m.def.category == "projectile" then
						stepProjectile(m, step)
					else
						ai.think(m, step, targets)
						if m.alive then
							stepPhysics(m, step)
						end
					end
					alive += 1
				end
			end
			MobService.stats.alive = alive
			spawner.step(step, targets)
		end
		if snapAcc >= 1 / Config.MOB_SNAPSHOT_HZ then
			snapAcc = 0
			sendSnapshots()
		end
	end)
end

return MobService
