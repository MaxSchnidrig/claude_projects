--!strict
-- Server-side mobs: registry, physics tick, damage/death/drops, player attacks and snapshots.
--
-- Mobs are pure data on the server (no Instances). Each tick (20 Hz) the AI (MobAI) sets a
-- desired velocity, MobPhysics moves the mob's box through the voxel world, and the environment
-- (falls, lava, daylight burning) applies. Movement follows Java's per-tick integration:
--   horizontal  v += accel (ground: 0.98*s^2, air/water: 0.0196*s), move, v *= friction
--               (ground 0.546, air 0.91, water 0.8)
--   vertical    move, then vy = (vy - 0.08) * 0.98; jump 0.42; water: vy*0.8 - 0.005, float +0.04
-- so knockback (Combat.knockback) and AI steering combine exactly like in Java. Every 0.1 s each player receives a compact snapshot of
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
local Shapes = require(Shared.Blocks.Shapes)
local MobDefs = require(Shared.Mobs.MobDefs)
local MobPhysics = require(Shared.Mobs.MobPhysics)
local Combat = require(Shared.Gameplay.Combat)
local Crafting = require(Shared.Items.Crafting)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local VoxelRaycast = require(Shared.World.VoxelRaycast)
local SurvivalRules = require(Shared.Gameplay.SurvivalRules)
local SkyLight = require(Shared.World.SkyLight)
local MobSnapshotCodec = require(Shared.Mobs.MobSnapshotCodec)
local SneakPose = require(Shared.Gameplay.SneakPose)
local WorldService = require(script.Parent.Parent.World.WorldService)
local ItemEntityService = require(script.Parent.Parent.World.ItemEntityService)
local ExplosionService = require(script.Parent.Parent.World.ExplosionService)
local InventoryService = require(script.Parent.Parent.Player.InventoryService)
local SurvivalService = require(script.Parent.Parent.Survival.SurvivalService)
local DayNightService = require(script.Parent.Parent.Survival.DayNightService)

local BS = Config.BLOCK_SIZE
local H = Config.WORLD_HEIGHT
local TICK = 0.05
local FIRE = BlockRegistry.id("fire")
local function isLava(id: number?): boolean
	local def = id and BlockRegistry.byId[id]
	return def ~= nil and def.fluid == "lava"
end
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
	hurt: Combat.HurtState,
	burning: number, -- seconds left
	burnTimer: number,
	peakY: number,
	flags: number,
	alive: boolean,
	lastAttacker: Player?,
	lastAttackedAt: number,
	persistent: boolean, -- animals: never despawn; parked with their chunk
	farSince: number?, -- despawn bookkeeping (MobSpawner)
	-- projectiles
	owner: string?,
	ownerId: number?,
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
local heldItem: { [Player]: string } = {}
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
-- Movement collision with real block shapes (slabs, stairs, fences, doors).
local shapeSolid = Shapes.physicsFn(WorldService.getBlockIfLoaded)

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

function MobService.timeOfDay(): number
	return DayNightService.timeOfDay()
end

function MobService.isDay(): boolean
	return SkyLight.isDay(DayNightService.timeOfDay())
end

-- Java "light level dependent magic value" (0..1) at a block-unit position.
function MobService.brightness(x: number, y: number, z: number): number
	local sky = MobService.skyExposed(math.floor(x), math.floor(y), math.floor(z))
	return SkyLight.magicBrightness(SkyLight.rawBrightness(sky, DayNightService.timeOfDay()))
end

-- Voxel line of sight between two block-unit points. Like Java (collider shapes), every block
-- with collision blocks the view, including glass and leaves; liquids don't.
function MobService.lineOfSight(a: Vector3, b: Vector3): boolean
	local d = b - a
	local dist = d.Magnitude
	if dist < 0.01 then
		return true
	end
	local hit = VoxelRaycast.cast(function(x, y, z)
		return WorldService.getBlockIfLoaded(x, y, z) or 1
	end, a.X, a.Y, a.Z, d.X, d.Y, d.Z, dist, function(id)
		return isSolid[id + 1]
	end)
	return hit == nil
end

-- Living players with their positions (block units: feet centre, eye).
export type Target = { player: Player, feet: Vector3, eye: Vector3, root: BasePart, look: Vector3, sneaking: boolean }
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
				eye = (pos + Vector3.new(0, SneakPose.eyeHeight(c), 0)) / BS,
					sneaking = c:GetAttribute("Sneaking") == true,
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
		hurt = { invulnUntil = 0, lastHurt = 0 },
		burning = 0,
		burnTimer = 0,
		peakY = y,
		flags = 0,
		alive = true,
		lastAttacker = nil,
		lastAttackedAt = -math.huge,
		persistent = def.category == "passive",
		farSince = nil,
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

local function playerKill(m: Mob): boolean
	-- Java remembers the last player hit for 100 ticks
	return m.lastAttacker ~= nil and os.clock() - m.lastAttackedAt <= 5
end

local function die(m: Mob)
	if not m.alive then
		return
	end
	MobService.remove(m)
	MobService.stats.killed += 1
	local center = Vector3.new(m.x, m.y + m.def.height / 2, m.z)
	broadcastEvent({ type = "died", id = m.id }, center)
	-- drops (meat comes out cooked if the mob was burning)
	local byPlayer = playerKill(m)
	local stacks = {}
	for _, d in m.def.drops do
		if (d.playerKill and not byPlayer) or (d.chance and math.random() >= d.chance) then
			continue
		end
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

-- Damage kinds that armor reduces (Java: everything except fall, fire, drowning, starving...).
local ARMORED = { attack = true, projectile = true, explosion = true, lava = true }

export type DamageOpts = {
	attacker: Player?, -- a player hit (anger, player-kill drops)
	from: Vector3?, -- attacker position (block units): standard 0.4 knockback away from it
	kind: string?, -- "attack" | "projectile" | "explosion" | "lava" | "fire" | "fall" | "drown"
	living: boolean?, -- caused by a living entity (voidlings don't teleport away from those)
}

-- Damage a mob with Java invulnerability (0.5 s; a stronger hit deals the difference without
-- knockback). Returns the damage dealt and whether it was a fresh hit.
function MobService.damage(m: Mob, amount: number, opts: DamageOpts?): (number, boolean)
	local o: DamageOpts = opts or {}
	if not m.alive or m.def.category == "projectile" then
		return 0, false
	end
	local kind = o.kind or "attack"
	if ARMORED[kind] then
		amount = Combat.armorReduce(amount, m.def.armor)
	end
	local now = os.clock()
	local dealt, fresh = Combat.applyInvulnerability(m.hurt, amount, now)
	if dealt <= 0 then
		return 0, false
	end
	m.health -= dealt
	if o.attacker then
		m.lastAttacker = o.attacker
		m.lastAttackedAt = now
	end
	if fresh then
		local from = o.from
		if from then
			local vx, vy, vz = Combat.knockback(m.vx / 20, m.vy / 20, m.vz / 20, m.x - from.X, m.z - from.Z, Combat.KNOCKBACK, m.onGround)
			m.vx, m.vy, m.vz = vx * 20, vy * 20, vz * 20
		end
		broadcastEvent({ type = "hurt", id = m.id }, Vector3.new(m.x, m.y, m.z))
	end
	if ai then
		ai.onHurt(m, o.attacker, kind, o.living == true or o.attacker ~= nil)
	end
	if m.health <= 0 then
		die(m)
	end
	return dealt, fresh
end

-- Explosion damage to every mob in range (hook for ExplosionService): damage plus a push of
-- direction * impact (blocks/tick), like Java.
local function explosionDamage(center: Vector3, power: number)
	for _, m in mobs do
		if m.def.category == "projectile" then
			continue
		end
		local c = Vector3.new(m.x, m.y + m.def.height / 2, m.z)
		local d = (c - center).Magnitude
		local dmg = Combat.explosionDamage(power, d)
		if dmg > 0 then
			MobService.damage(m, dmg, { kind = "explosion", living = true })
			local dir = if d > 0.01 then (c - center) / d else Vector3.yAxis
			local impact = 1 - d / (2 * power)
			m.vx += dir.X * impact * 20
			m.vy += dir.Y * impact * 20
			m.vz += dir.Z * impact * 20
		end
	end
end

-- Damage a player from a mob (melee / arrow). A fresh hit pushes the player away from `from`
-- with Java's 0.4 knockback (the client applies it to its own character).
function MobService.hurtPlayer(t: Target, amount: number, cause: string, from: Vector3)
	local dealt, fresh = SurvivalService.damage(t.player, amount, cause)
	if dealt > 0 and fresh then
		local d = Vector3.new(t.feet.X - from.X, 0, t.feet.Z - from.Z)
		Remotes.get("Knockback"):FireClient(t.player, { dir = d, strength = Combat.KNOCKBACK })
	end
end

---------------------------------------------------------------------------------------------
-- Physics + environment
---------------------------------------------------------------------------------------------

local function feetBlock(m: Mob): number?
	return MobService.blockAt(math.floor(m.x), math.floor(m.y + 0.1), math.floor(m.z))
end

-- One 20 Hz tick of Java-style movement. Velocities are stored in blocks/s.
local function physicsTick(m: Mob)
	local def = m.def
	local id = feetBlock(m)
	m.inLiquid = id ~= nil and isLiquid[id + 1]
	local vx, vy, vz = m.vx / 20, m.vy / 20, m.vz / 20 -- blocks/tick

	-- steering: the AI's wanted ground speed -> Java speed value -> acceleration
	local want = math.sqrt(m.wantX * m.wantX + m.wantZ * m.wantZ)
	if want > 1e-4 then
		local sv = math.sqrt(want / 20 * (1 - 0.546) / 0.98)
		local accel = if m.onGround and not m.inLiquid then 0.98 * sv * sv else 0.02 * 0.98 * sv
		vx += m.wantX / want * accel
		vz += m.wantZ / want * accel
	end
	if m.inLiquid then
		if def.behavior ~= "teleporter" then
			vy += 0.04 -- swim up (Java FloatGoal)
		end
	elseif m.wantJump and m.onGround then
		vy = 0.42
	end
	if def.canClimb and m.hitWall and want > 1e-4 then
		vy = 0.2 -- spiders climb walls
	end
	m.wantJump = false

	local wasGround = m.onGround
	local nx, ny, nz, rvx, rvy, rvz, onGround, hitWall =
		MobPhysics.move(shapeSolid, m.x, m.y, m.z, vx * 20, vy * 20, vz * 20, def.width, def.height, TICK, 0.6)
	m.x, m.y, m.z, m.onGround, m.hitWall = nx, ny, nz, onGround, hitWall
	vx, vy, vz = rvx / 20, rvy / 20, rvz / 20

	if m.inLiquid then
		vx *= 0.8
		vz *= 0.8
		vy = vy * 0.8 - 0.005
	else
		local f = if wasGround then 0.546 else 0.91
		vx *= f
		vz *= f
		vy = (vy - 0.08) * 0.98
		if def.key == "chicken" and not m.onGround and vy < 0 then
			vy *= 0.6 -- flaps its wings
		end
	end
	m.vx, m.vy, m.vz = vx * 20, vy * 20, vz * 20

	-- fall damage (not chickens / not into liquid)
	if m.onGround or m.inLiquid then
		if not wasGround and def.key ~= "chicken" and not m.inLiquid then
			local dmg = SurvivalRules.fallDamage(m.peakY - m.y, false)
			if dmg > 0 then
				MobService.damage(m, dmg, { kind = "fall" })
			end
		end
		m.peakY = m.y
	else
		m.peakY = math.max(m.peakY, m.y)
	end
end

local function stepPhysics(m: Mob, dt: number)
	local def = m.def
	local h = def.height
	for _ = 1, math.max(1, math.floor(dt / TICK + 0.5)) do
		physicsTick(m)
		if not m.alive then
			return
		end
	end

	-- lava: 4 damage (every 0.5 s through invulnerability) and 15 s of fire
	local bodyId = MobService.blockAt(math.floor(m.x), math.floor(m.y + h / 2), math.floor(m.z))
	local feet = feetBlock(m)
	if isLava(feet) or isLava(bodyId) then
		m.burning = 15
		MobService.damage(m, 4, { kind = "lava" })
	elseif feet == FIRE or bodyId == FIRE then
		m.burning = math.max(m.burning, 8)
		MobService.damage(m, 1, { kind = "fire" })
	end
	-- undead catch fire in daylight (Java: brightness > 0.5, chance (b - 0.4) * 2 / 30 per tick,
	-- open sky above the eyes, not wet) and burn for 8 s
	if def.undead and not m.inLiquid and MobService.isDay() then
		local ey = m.y + (def.eyeHeight or h * 0.85)
		if MobService.skyExposed(math.floor(m.x), math.floor(ey), math.floor(m.z)) then
			local b = MobService.brightness(m.x, ey, m.z)
			local ticks = math.max(1, math.floor(dt / TICK + 0.5))
			if b > 0.5 and math.random() < 1 - (1 - (b - 0.4) * 2 / 30) ^ ticks then
				m.burning = math.max(m.burning, 8)
			end
		end
	end
	if m.inLiquid then
		m.burning = 0
		-- voidlings are hurt by water and try to teleport out of it
		if def.behavior == "teleporter" then
			MobService.damage(m, 1, { kind = "drown" })
			if m.alive and ai then
				ai.waterTeleport(m)
			end
		end
	end
	if m.burning > 0 then
		m.burning -= dt
		m.burnTimer += dt
		if m.burnTimer >= 1 then
			m.burnTimer -= 1
			MobService.damage(m, 1, { kind = "fire" })
		end
	else
		m.burnTimer = 0
	end
	if m.y < -64 then
		MobService.remove(m)
	end
end

-- Arrows (Java): per tick move, then v *= 0.99 (0.6 in water), vy -= 0.05. Damage on hit =
-- ceil(speed (blocks/tick) * baseDamage). Hitbox 0.5 x 0.5.
local function stepProjectile(m: Mob, dt: number)
	if m.stuck then
		m.stuck -= dt
		if (m.stuck :: number) <= 0 then
			MobService.remove(m)
		end
		return
	end
	local targets = MobService.targets()
	for _ = 1, math.max(1, math.floor(dt / TICK + 0.5)) do
		local vx, vy, vz = m.vx / 20, m.vy / 20, m.vz / 20
		local speed = math.sqrt(vx * vx + vy * vy + vz * vz)
		local steps = math.max(1, math.ceil(speed / 0.2))
		for _ = 1, steps do
			local nx, ny, nz = m.x + vx / steps, m.y + vy / steps, m.z + vz / steps
			if solid(math.floor(nx), math.floor(ny), math.floor(nz)) then
				m.stuck = 60 -- Java: arrows in the ground despawn after a minute
				m.flags = FLAG.STUCK
				m.vx, m.vy, m.vz = 0, 0, 0
				return
			end
			m.x, m.y, m.z = nx, ny, nz
			local dmg = math.ceil(math.clamp(speed * (m.damage or 2), 0, 2147483647))
			for _, t in targets do
				local f = t.feet
				if math.abs(m.x - f.X) < 0.55 and math.abs(m.z - f.Z) < 0.55 and m.y >= f.Y - 0.25 and m.y <= f.Y + 2.05 then
					MobService.hurtPlayer(t, dmg, `was shot by {m.owner or "an arrow"}`, Vector3.new(m.x - vx * 4, m.y, m.z - vz * 4))
					MobService.remove(m)
					return
				end
			end
			for _, o in mobs do
				if o ~= m and o.alive and o.id ~= m.ownerId and o.def.category ~= "projectile" then
					local hw = o.def.width / 2 + 0.25
					if math.abs(m.x - o.x) < hw and math.abs(m.z - o.z) < hw and m.y >= o.y - 0.25 and m.y <= o.y + o.def.height + 0.25 then
						if o.def.behavior == "teleporter" then
							-- voidlings dodge projectiles by teleporting; the arrow flies on
							if ai then
								ai.dodge(o)
							end
						else
							MobService.damage(o, dmg, { kind = "projectile", from = Vector3.new(m.x - vx * 4, m.y, m.z - vz * 4), living = true })
							MobService.remove(m)
							return
						end
					end
				end
			end
		end
		local drag = if solid(math.floor(m.x), math.floor(m.y), math.floor(m.z)) then 1 else 0.99
		local id = MobService.blockAt(math.floor(m.x), math.floor(m.y), math.floor(m.z))
		if id and isLiquid[id + 1] then
			drag = 0.6
		end
		m.vx, m.vy, m.vz = vx * drag * 20, (vy * drag - 0.05) * 20, vz * drag * 20
	end
	local horizontal = math.sqrt(m.vx * m.vx + m.vz * m.vz)
	m.yaw = math.atan2(-m.vx, -m.vz)
	m.pitch = math.atan2(m.vy, horizontal)
	if m.y < -64 then
		MobService.remove(m)
	end
end

-- Fire an arrow (block units) from `from` with velocity `vel` (blocks/s).
function MobService.shootArrow(from: Vector3, vel: Vector3, baseDamage: number, owner: string, ownerId: number?)
	local a = MobService.spawn("arrow", from.X, from.Y, from.Z)
	if a then
		a.vx, a.vy, a.vz = vel.X, vel.Y, vel.Z
		a.damage = baseDamage
		a.owner = owner
		a.ownerId = ownerId
		a.persistent = false
	end
end

---------------------------------------------------------------------------------------------
-- Player attacks
---------------------------------------------------------------------------------------------

local function onAttack(p: Player, id: any, critClaim: any)
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
	local eye = (root.Position + Vector3.new(0, SneakPose.eyeHeight(c), 0)) / BS
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
	local base, attackSpeed = Combat.attackStats(item)
	local now = os.clock()
	local charge = Combat.charge(now - (lastSwing[p] or 0), attackSpeed)
	lastSwing[p] = now
	local amount = Combat.scaledDamage(base, charge)

	local sprinting, _grounded, inLiquid = SurvivalService.movement(p)
	-- Critical hit: the client saw itself falling and airborne; the server re-checks what it can
	-- (charge, sprint, liquid, not rising).
	local crit = critClaim == true and Combat.isCrit({
		charge = charge,
		falling = root.AssemblyLinearVelocity.Y <= 0.5,
		onGround = false,
		sprinting = sprinting,
		inLiquid = inLiquid,
	})
	if crit then
		amount *= Combat.CRIT_MULTIPLIER
	end
	local dealt, fresh = MobService.damage(m, amount, { attacker = p, from = eye, kind = "attack" })
	if dealt <= 0 then
		return
	end
	if crit then
		broadcastEvent({ type = "crit", id = m.id }, Vector3.new(m.x, m.y, m.z))
	end
	Remotes.get("MobEvent"):FireClient(p, { type = "hit", id = m.id, damage = dealt, crit = crit, charge = charge })
	-- Sprint hit at full strength: extra 0.5 knockback along the attacker's facing; sprint ends.
	if fresh and sprinting and charge > Combat.CRIT_MIN_CHARGE and m.alive then
		local look = root.CFrame.LookVector
		local vx, vy, vz = Combat.knockback(m.vx / 20, m.vy / 20, m.vz / 20, look.X, look.Z, Combat.SPRINT_KNOCKBACK, m.onGround)
		m.vx, m.vy, m.vz = vx * 20, vy * 20, vz * 20
		SurvivalService.stopSprint(p)
	end
	SurvivalService.addExhaustion(p, 0.1)
	local wear = Combat.hitDurabilityCost(item)
	if wear > 0 then
		InventoryService.damageSelectedTool(p, wear)
	end
end

-- A player reports staring a voidling in the eyes (5 ticks). The server checks range (64) and
-- that no block with collision is in the way.
local function onStare(p: Player, id: any)
	if typeof(id) ~= "number" then
		return
	end
	local m = mobs[id]
	if not m or not m.alive or m.def.behavior ~= "teleporter" then
		return
	end
	for _, t in MobService.targets() do
		if t.player == p then
			local mobEye = Vector3.new(m.x, m.y + (m.def.eyeHeight or m.def.height), m.z)
			if (mobEye - t.eye).Magnitude <= 64 and MobService.lineOfSight(t.eye, mobEye) and ai then
				ai.provoke(m, p)
			end
		end
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

	-- Studio key L spawns mobs for testing
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
	Remotes.get("StareMob").OnServerEvent:Connect(onStare)
	Players.PlayerRemoving:Connect(function(p)
		lastSwing[p] = nil
		heldItem[p] = nil
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
