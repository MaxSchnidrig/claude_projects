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
local Animals = require(Shared.Mobs.Animals)
local WorldService = require(script.Parent.Parent.World.WorldService)
local ItemEntityService = require(script.Parent.Parent.World.ItemEntityService)
local WeatherService = require(script.Parent.Parent.World.WeatherService)
local ExplosionService = require(script.Parent.Parent.World.ExplosionService)
local InventoryService = require(script.Parent.Parent.Player.InventoryService)
local SurvivalService = require(script.Parent.Parent.Survival.SurvivalService)
local DayNightService = require(script.Parent.Parent.Survival.DayNightService)
local ExperienceService = require(script.Parent.Parent.Player.ExperienceService)
local Experience = require(Shared.Gameplay.Experience)
local Enchantments = require(Shared.Items.Enchantments)

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
	ownerPlayer: Player?, -- arrows a player shot (never hit them; pickup allowed)
	crit: boolean?,
	pickup: boolean?,
	punch: number?, -- Phase 10c bow enchantments on the arrow
	flame: boolean?,
	pierce: number?, -- Piercing: mobs it can still pass through
	pierced: { [any]: boolean }?,
	damage: number?,
	stuck: number?,
	eggTime: number?, -- chickens: ticks until the next egg (Java 6000..11999)
	charged: boolean?, -- a Sneaker struck by lightning: its blast is twice as strong
	-- animals (Phase 9e, Mobs/Animals): age < 0 baby (counts up to 0), > 0 can't breed yet
	-- (counts down); love > 0 ticks of love mode; sheep wool colour and sheared state
	age: number,
	love: number,
	color: string?,
	sheared: boolean?,
	-- Phase 10c: the Looting level of the last player hit (drops), Slowness IV until (Bane)
	looting: number?,
	slowUntil: number?,
}

local FLAG = { BURNING = 1, FUSING = 2, ANGRY = 4, PANIC = 8, CHARGED = 16, STUCK = 32, BABY = 64, SHEARED = 128 }

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
		-- spectators are invisible to mobs and don't make them spawn (Java: NO_SPECTATORS)
		if h and root and h.Health > 0 and p:GetAttribute("Spectator") ~= true then
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

-- Size factor (babies are half size, Java AgeableMob).
function MobService.scaleOf(m: Mob): number
	return if m.age < 0 then 0.5 else 1
end

-- `opts.age` / `opts.color` set an animal's state (breeding, chunks coming back); `opts.natural`:
-- a natural spawn (5 % babies unless it's the first of its group, sheep get Java's colours).
export type SpawnOpts = { age: number?, color: string?, sheared: boolean?, natural: boolean?, first: boolean? }
function MobService.spawn(key: string, x: number, y: number, z: number, yaw: number?, opts: SpawnOpts?): Mob?
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
		age = 0,
		love = 0,
	}
	local o: SpawnOpts = opts or {}
	if Animals.isAnimal(key) then
		m.age = o.age or (if o.natural and not o.first and math.random() < Animals.BABY_CHANCE then Animals.BABY_AGE else 0)
		if key == "sheep" then
			m.color = o.color or Animals.naturalSheepColor(math.random(0, 99), math.random(0, 499))
			m.sheared = o.sheared == true
		end
	end
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
	-- drops (meat comes out cooked if the mob was burning); babies drop nothing (Java)
	local byPlayer = playerKill(m)
	local looting = if byPlayer then m.looting or 0 else 0
	local stacks = {}
	for _, d in (if m.age < 0 then {} else m.def.drops) do
		-- Looting: rare drops +1 % a level (the zombie's 2.5 % is shared by its three rare drops)
		local chance = d.chance
		if chance and d.playerKill and looting > 0 then
			chance += 0.01 * looting / 3
		end
		if (d.playerKill and not byPlayer) or (chance and math.random() >= chance) then
			continue
		end
		local n = math.random(d.min, d.max)
		if not chance and d.item ~= "white_wool" then
			n += Enchantments.lootingExtra(looting, math.random) -- (wool: no Looting, Java)
		end
		if d.item == "white_wool" and m.def.key == "sheep" then
			n = if m.sheared then 0 else n -- a sheared sheep drops no wool; else its colour's
		end
		if n > 0 then
			local item = if d.item == "white_wool" and m.color then `{m.color}_wool` else d.item
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
	-- experience (Java LivingEntity.dropExperience): only if a player hit it in the last
	-- 100 ticks, never from babies
	if byPlayer and m.age >= 0 then
		ExperienceService.award(Vector3.new(m.x, m.y, m.z), Experience.mobReward(m.def.key, math.random))
	end
end

-- Damage kinds that armor reduces (Java: everything except fall, fire, drowning, starving...).
local ARMORED = { attack = true, projectile = true, explosion = true, lava = true, lightning = true }

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
-- The world's difficulty id (0 Peaceful .. 3 Hard) for Java formulas (MobAI: skeleton arrows).
function MobService.difficultyId(): number
	return require(script.Parent.Parent.World.WorldSettingsService).difficultyId()
end

-- `byPlayer`: an arrow a player shot (not changed by the difficulty, unlike a mob's damage).
-- `attacker`: the mob behind the hit (its bite, its arrow): worn Thorns hit it back (Phase 10d).
-- `projectile`: an arrow (Projectile Protection).
function MobService.hurtPlayer(t: Target, amount: number, cause: string, from: Vector3, byPlayer: boolean?, attacker: Mob?, projectile: boolean?)
	local dealt, fresh = SurvivalService.damage(t.player, amount, cause, nil, { armor = true, source = from, scales = not byPlayer, projectile = projectile })
	if dealt > 0 and fresh then
		local d = Vector3.new(t.feet.X - from.X, 0, t.feet.Z - from.Z)
		Remotes.get("Knockback"):FireClient(t.player, { dir = d, strength = Combat.KNOCKBACK })
	end
	if dealt > 0 and attacker and attacker.alive then
		-- Thorns (Java): every worn piece rolls on its own, 2 extra durability when it triggers;
		-- the invulnerability time keeps only the biggest hit
		local armorSlots = { Config.ARMOR_SLOT.head, Config.ARMOR_SLOT.chest, Config.ARMOR_SLOT.legs, Config.ARMOR_SLOT.feet }
		for k, s in InventoryService.armor(t.player) do
			local dmg = Enchantments.thorns(Enchantments.level(s, "thorns"), math.random)
			if dmg then
				MobService.damage(attacker, dmg, { kind = "thorns", from = t.feet, living = true })
				InventoryService.damageSlot(t.player, armorSlots[k], 2)
			end
		end
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
		MobPhysics.move(shapeSolid, m.x, m.y, m.z, vx * 20, vy * 20, vz * 20, def.width * MobService.scaleOf(m), def.height * MobService.scaleOf(m), TICK, 0.6)
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
	-- wet: in water or in the rain (Java isInWaterRainOrBubble)
	local wet = m.inLiquid or WeatherService.rainOn(m.x, m.y, m.z, h)
	-- undead catch fire in daylight (Java: brightness > 0.5, chance (b - 0.4) * 2 / 30 per tick,
	-- open sky above the eyes, not wet) and burn for 8 s
	if def.undead and not wet and MobService.isDay() then
		local ey = m.y + (def.eyeHeight or h * 0.85)
		if MobService.skyExposed(math.floor(m.x), math.floor(ey), math.floor(m.z)) then
			local b = MobService.brightness(m.x, ey, m.z)
			local ticks = math.max(1, math.floor(dt / TICK + 0.5))
			if b > 0.5 and math.random() < 1 - (1 - (b - 0.4) * 2 / 30) ^ ticks then
				m.burning = math.max(m.burning, 8)
			end
		end
	end
	if wet then
		m.burning = 0
		-- voidlings are hurt by water and rain and try to teleport out of it
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
	-- animals (Java AgeableMob.aiStep / Animal.aiStep): babies grow up by 1 a tick, parents'
	-- cooldown counts down; love mode runs out, and only adults ready to breed stay in love
	if Animals.isAnimal(def.key) and m.alive then
		local ticks = math.max(1, math.floor(dt / TICK + 0.5))
		if m.age < 0 then
			m.age = math.min(0, m.age + ticks)
		elseif m.age > 0 then
			m.age = math.max(0, m.age - ticks)
		end
		if m.age ~= 0 then
			m.love = 0
		elseif m.love > 0 then
			m.love = math.max(0, m.love - ticks)
		end
	end
	-- Java Chicken.aiStep: an egg every 6000..11999 ticks (5..10 minutes); not chicks
	if def.key == "chicken" and m.alive and m.age >= 0 then
		local t = (m.eggTime or (math.random(0, 5999) + 6000)) - math.max(1, math.floor(dt / TICK + 0.5))
		if t <= 0 then
			ItemEntityService.spawn({ item = "egg", count = 1 }, Vector3.new(m.x, m.y + 0.2, m.z) * BS)
			broadcastEvent({ type = "egg", id = m.id }, Vector3.new(m.x, m.y, m.z))
			t = math.random(0, 5999) + 6000
		end
		m.eggTime = t
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
			return
		end
		-- Java: an arrow a player shot is picked up by walking over it
		local pick = arrowPickup
		if m.pickup and pick then
			for _, t in MobService.targets() do
				local f = t.feet
				if math.abs(m.x - f.X) < 1 and math.abs(m.z - f.Z) < 1 and m.y >= f.Y - 0.5 and m.y <= f.Y + 2.3 then
					if pick(t.player) then
						MobService.remove(m)
						return
					end
				end
			end
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
				if m.flame then
					-- Java: a burning arrow lights the TNT or the unlit campfire it hits
					local bx, by, bz = math.floor(nx), math.floor(ny), math.floor(nz)
					local hitId = MobService.blockAt(bx, by, bz)
					if hitId == BlockRegistry.id("tnt") then
						require(script.Parent.Parent.Simulation.EntityService).igniteBlock(bx, by, bz)
						MobService.remove(m)
						return
					elseif hitId == BlockRegistry.id("campfire_unlit") then
						MobService.setBlock(bx, by, bz, BlockRegistry.id("campfire"))
					end
				end
				m.stuck = 60 -- Java: arrows in the ground despawn after a minute
				m.flags = FLAG.STUCK
				m.vx, m.vy, m.vz = 0, 0, 0
				return
			end
			m.x, m.y, m.z = nx, ny, nz
			local dmg = math.ceil(math.clamp(speed * (m.damage or 2), 0, 2147483647))
			if m.crit then
				dmg += math.random(0, dmg // 2 + 1)
			end
			-- Piercing: each target is hit once; the arrow stops at the first one it can't pass
			local pierced = m.pierced or {}
			m.pierced = pierced
			local function done(): boolean
				if (m.pierce or 0) > 0 then
					m.pierce = (m.pierce :: number) - 1
					return false
				end
				MobService.remove(m)
				return true
			end
			for _, t in targets do
				local f = t.feet
				if t.player ~= m.ownerPlayer and not pierced[t.player] and math.abs(m.x - f.X) < 0.55 and math.abs(m.z - f.Z) < 0.55 and m.y >= f.Y - 0.25 and m.y <= f.Y + 2.05 then
					pierced[t.player] = true
					MobService.hurtPlayer(t, dmg, `was shot by {m.owner or "an arrow"}`, Vector3.new(m.x - vx * 4, m.y, m.z - vz * 4), m.ownerPlayer ~= nil,
						if m.ownerId then mobs[m.ownerId] else nil, true)
					if m.flame then
						SurvivalService.ignite(t.player, 5)
					end
					if done() then
						return
					end
				end
			end
			for _, o in mobs do
				if o ~= m and o.alive and o.id ~= m.ownerId and o.def.category ~= "projectile" and not pierced[o] then
					local hw = o.def.width / 2 + 0.25
					if math.abs(m.x - o.x) < hw and math.abs(m.z - o.z) < hw and m.y >= o.y - 0.25 and m.y <= o.y + o.def.height + 0.25 then
						if o.def.behavior == "teleporter" then
							-- voidlings dodge projectiles by teleporting; the arrow flies on
							if ai then
								ai.dodge(o)
							end
						else
							pierced[o] = true
							-- Flame (Java AbstractArrow.onHitEntity): set on fire for 5 s BEFORE the
							-- damage, so a kill already counts as burning (cooked drops)
							local burnBefore = o.burning
							if m.flame then
								o.burning = math.max(o.burning, 5)
							end
							local dealt = MobService.damage(o, dmg, { kind = "projectile", from = Vector3.new(m.x - vx * 4, m.y, m.z - vz * 4), living = true, attacker = m.ownerPlayer })
							if dealt <= 0 and m.flame and o.alive then
								o.burning = burnBefore -- (Java: a hit that didn't land puts the fire out again)
							end
							if dealt > 0 and o.alive then
								local punch = m.punch or 0
								if punch > 0 then
									-- Punch (Java): pushed along the arrow's flight, 0.6 a level, 0.1 up
									local h = math.sqrt(vx * vx + vz * vz)
									if h > 1e-6 then
										o.vx += vx / h * punch * 0.6 * 20
										o.vz += vz / h * punch * 0.6 * 20
										o.vy += 0.1 * 20
									end
								end
							end
							if done() then
								return
							end
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

-- Fire an arrow (block units) from `from` with velocity `vel` (blocks/s). `opts.player`: shot
-- by a player (it never hits them, and with `pickup` it can be collected from the ground);
-- `opts.crit`: a critical arrow (Java: + random 0 .. damage / 2 + 1).
-- Phase 10c: `punch` (knockback level), `flame` (sets what it hits on fire for 5 s), `pierce`
-- (Piercing level: passes through that many mobs).
export type ArrowOpts = { player: Player?, crit: boolean?, pickup: boolean?, punch: number?, flame: boolean?, pierce: number? }
function MobService.shootArrow(from: Vector3, vel: Vector3, baseDamage: number, owner: string, ownerId: number?, opts: ArrowOpts?)
	local a = MobService.spawn("arrow", from.X, from.Y, from.Z)
	if a then
		a.vx, a.vy, a.vz = vel.X, vel.Y, vel.Z
		a.damage = baseDamage
		a.owner = owner
		a.ownerId = ownerId
		a.persistent = false
		if opts then
			a.ownerPlayer = opts.player
			a.crit = opts.crit
			a.pickup = opts.pickup
			a.punch = opts.punch
			a.flame = opts.flame
			a.pierce = opts.pierce
			if opts.flame then
				a.burning = 1e6 -- (drawn burning)
			end
		end
	end
	return a
end

local arrowPickup: ((Player) -> boolean)? = nil
function MobService.setArrowPickup(fn: (Player) -> boolean)
	arrowPickup = fn
end

---------------------------------------------------------------------------------------------
-- Player attacks
---------------------------------------------------------------------------------------------

local function onAttack(p: Player, id: any, critClaim: any)
	if typeof(id) ~= "number" or p:GetAttribute("Spectator") == true then
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
	local strength = SurvivalService.effects(p).strength
	if strength then
		base += 3 * (strength.amp + 1)
	end
	-- Java Player.attack: f = base x (0.2 + charge^2 x 0.8), enchantment bonus x charge
	local amount = Combat.scaledDamage(base, charge)
	local function bonusFor(t: Mob): number
		return Enchantments.meleeBonus(stack, t.def.undead, t.def.key == "spider") * charge
	end

	local sprinting, grounded, inLiquid = SurvivalService.movement(p)
	local full = charge > Combat.CRIT_MIN_CHARGE
	local sprintHit = sprinting and full
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
	-- Java's sweep: a fully charged sword hit on the ground, not a crit, not a sprint hit
	local sweep = full and not crit and not sprintHit and grounded and item ~= nil
		and string.sub(item, -6) == "_sword"
	local look = root.CFrame.LookVector
	local looting = Enchantments.level(stack, "looting")
	local fireAspect = Enchantments.level(stack, "fire_aspect")
	local bane = Enchantments.level(stack, "bane_of_arthropods")
	-- after-hit effects (Java doPostAttackEffects): Fire Aspect, Bane of Arthropods' slowness
	local function postHit(t: Mob)
		if not t.alive then
			return
		end
		if fireAspect > 0 then
			t.burning = math.max(t.burning, 4 * fireAspect)
		end
		if bane > 0 and t.def.key == "spider" then
			-- Slowness IV for 1.5 s up to 1.5 + 0.5 x (level - 1) s
			t.slowUntil = now + 1.5 + math.random() * 0.5 * (bane - 1)
		end
	end
	m.looting = looting
	-- Fire Aspect (Java Player.attack): the target is set on fire before the hit, so a kill drops
	-- cooked meat; if the hit doesn't land, the fire goes out again
	local function preIgnite(t: Mob): number
		local before = t.burning
		if fireAspect > 0 then
			t.burning = math.max(t.burning, 1)
		end
		return before
	end
	local burnBefore = preIgnite(m)
	local dealt, fresh = MobService.damage(m, amount + bonusFor(m), { attacker = p, from = eye, kind = "attack" })
	if dealt <= 0 then
		if m.alive then
			m.burning = burnBefore
		end
		return
	end
	postHit(m)
	if crit then
		broadcastEvent({ type = "crit", id = m.id }, Vector3.new(m.x, m.y, m.z))
	end
	Remotes.get("MobEvent"):FireClient(p, { type = "hit", id = m.id, damage = dealt, crit = crit, charge = charge })
	-- Extra knockback (Java): the Knockback level, + 1 for a fully charged sprint hit; 0.5 each,
	-- along the attacker's facing. A sprint hit ends the sprint.
	local kb = Enchantments.level(stack, "knockback") + (if sprintHit then 1 else 0)
	if fresh and kb > 0 and m.alive then
		local vx, vy, vz = Combat.knockback(m.vx / 20, m.vy / 20, m.vz / 20, look.X, look.Z, kb * Combat.SPRINT_KNOCKBACK, m.onGround)
		m.vx, m.vy, m.vz = vx * 20, vy * 20, vz * 20
	end
	if sprintHit then
		SurvivalService.stopSprint(p)
	end
	if sweep then
		-- every other mob within the target's box grown by (1, 0.25, 1) and 3 blocks of the
		-- player: knocked back 0.4 and hurt 1 + Sweeping Edge ratio x the hit's damage
		local sweepDamage = 1 + Enchantments.sweepRatio(Enchantments.level(stack, "sweeping_edge")) * amount
		local feet = root.Position / BS - Vector3.new(0, 1, 0)
		local hw = m.def.width / 2
		for _, o in mobs do
			if o ~= m and o.alive and o.def.category ~= "projectile" then
				local ow = o.def.width / 2
				local touches = o.x + ow > m.x - hw - 1 and o.x - ow < m.x + hw + 1
					and o.z + ow > m.z - hw - 1 and o.z - ow < m.z + hw + 1
					and o.y + o.def.height > m.y - 0.25 and o.y < m.y + m.def.height + 0.25
				if touches and (Vector3.new(o.x, o.y, o.z) - feet).Magnitude < 3 then
					local vx, vy, vz = Combat.knockback(o.vx / 20, o.vy / 20, o.vz / 20, look.X, look.Z, 0.4, o.onGround)
					o.vx, o.vy, o.vz = vx * 20, vy * 20, vz * 20
					o.looting = looting
					local ob = preIgnite(o)
					local d = MobService.damage(o, sweepDamage + bonusFor(o), { attacker = p, from = eye, kind = "attack" })
					if d > 0 then
						postHit(o)
					elseif o.alive then
						o.burning = ob
					end
				end
			end
		end
		broadcastEvent({ type = "sweep", id = m.id, pos = Vector3.new(m.x, m.y + m.def.height / 2, m.z) * BS }, Vector3.new(m.x, m.y, m.z))
	end
	SurvivalService.addExhaustion(p, 0.1)
	local wear = Combat.hitDurabilityCost(item)
	if wear > 0 then
		InventoryService.damageSelectedTool(p, wear)
	end
end

-- Lightning (Java LightningBolt / Entity.thunderHit): every mob in the box takes 5 damage and
-- burns for 8 s (a tick longer if already burning); a Sneaker becomes charged.
function MobService.lightningIn(lo: Vector3, hi: Vector3)
	for _, m in mobs do
		if m.alive and m.def.category ~= "projectile" and m.x >= lo.X and m.x <= hi.X and m.y >= lo.Y and m.y <= hi.Y
			and m.z >= lo.Z and m.z <= hi.Z
		then
			if m.def.behavior == "exploder" then
				m.charged = true
			end
			m.burning = if m.burning > 0 then m.burning + 0.05 else 8
			MobService.damage(m, 5, { kind = "lightning" })
		end
	end
end

-- Living mobs whose feet are within 3 blocks (sideways) of a column, at or above y0 - 3, under
-- the open sky (lightning picks one of them; WeatherService).
function MobService.lightningTargets(x: number, z: number, y0: number, topAt: (number, number) -> number?): { Vector3 }
	local out = {}
	for _, m in mobs do
		if m.alive and m.def.category ~= "projectile" and math.abs(m.x - (x + 0.5)) <= 3.5 and math.abs(m.z - (z + 0.5)) <= 3.5
			and m.y >= y0 - 3
		then
			local top = topAt(math.floor(m.x), math.floor(m.z))
			if top and top < m.y + 0.01 then
				table.insert(out, Vector3.new(m.x, m.y, m.z))
			end
		end
	end
	return out
end

-- Two animals in love made a baby (Java Animal.spawnChildFromBreeding): it appears at the first
-- parent, both parents rest 6000 ticks; a lamb mixes its parents' dye colours.
local function mixDyes(a: string, b: string): string?
	local r = Crafting.match({ { item = `{a}_dye`, count = 1 }, { item = `{b}_dye`, count = 1 }, nil, nil }, 2)
	local c = r and string.match(r.item, "^(.+)_dye$")
	return if c and r and r.count == 2 then c else nil
end
MobService.mixDyes = mixDyes
function MobService.breed(a: Mob, b: Mob): Mob?
	a.age, b.age = Animals.PARENT_COOLDOWN, Animals.PARENT_COOLDOWN
	a.love, b.love = 0, 0
	local color = nil
	if a.def.key == "sheep" and a.color and b.color then
		color = Animals.offspringColor(a.color, b.color, mixDyes, math.random(0, 1))
	end
	local baby = MobService.spawn(a.def.key, a.x, a.y, a.z, math.random() * math.pi * 2, { age = Animals.BABY_AGE, color = color })
	-- Java Animal.finalizeSpawnChildFromBreeding: one orb of 1-7 at the parent
	ExperienceService.orb(Vector3.new(a.x, a.y, a.z), math.random(Experience.BREED[1], Experience.BREED[2]))
	broadcastEvent({ type = "bred", id = a.id, other = b.id, pos = Vector3.new(a.x, a.y + 0.5, a.z) * BS }, Vector3.new(a.x, a.y, a.z))
	return baby
end

-- A mob changes a block (a sheep eating grass): through BlockUpdates, so every client sees it.
function MobService.setBlock(x: number, y: number, z: number, id: number)
	require(script.Parent.Parent.World.BlockUpdates).set(x, y, z, id)
end

-- A sheep finished eating grass (Java Sheep.ate): wool grows back; a lamb grows a minute.
function MobService.ateGrass(m: Mob)
	m.sheared = false
	if m.age < 0 then
		m.age = math.min(0, m.age + Animals.GRAZE_GROW_SECONDS * 20)
	end
	broadcastEvent({ type = "graze", id = m.id }, Vector3.new(m.x, m.y, m.z))
end

-- Right-click on a mob (Java Mob.mobInteract). A bucket on a cow fills with milk: a lone bucket
-- turns into the milk bucket, one from a stack goes to the inventory (dropped if it's full).
-- Animals (Phase 9e): their food puts an adult in love (or speeds a baby's growth by 10 % of the
-- time left), shears shear a sheep (1-3 wool of its colour), a dye colours a sheep.
local function onUseMob(p: Player, id: any)
	if typeof(id) ~= "number" or p:GetAttribute("Spectator") == true then
		return
	end
	local m = mobs[id]
	local c = p.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not m or not m.alive or not c or not h or not root or h.Health <= 0 then
		return
	end
	local eye = (root.Position + Vector3.new(0, SneakPose.eyeHeight(c), 0)) / BS
	local hw = m.def.width / 2 * MobService.scaleOf(m)
	local closest = Vector3.new(
		math.clamp(eye.X, m.x - hw, m.x + hw),
		math.clamp(eye.Y, m.y, m.y + m.def.height * MobService.scaleOf(m)),
		math.clamp(eye.Z, m.z - hw, m.z + hw)
	)
	if (closest - eye).Magnitude > Combat.MELEE_REACH + 1 then
		return
	end
	local slot = InventoryService.selectedSlot(p)
	local stack = InventoryService.getSlot(p, slot)
	local item = stack and stack.item
	local center = Vector3.new(m.x, m.y + m.def.height * MobService.scaleOf(m) / 2, m.z)
	if item and Animals.isFood(m.def.key, item) then
		if m.age == 0 and m.love <= 0 then
			InventoryService.consumeSelected(p, 1)
			m.love = Animals.LOVE_TICKS
			broadcastEvent({ type = "love", id = m.id, pos = center * BS }, center)
		elseif m.age < 0 then
			InventoryService.consumeSelected(p, 1)
			m.age = math.min(0, m.age + Animals.feedSpeedUpTicks(m.age))
			broadcastEvent({ type = "fed", id = m.id, pos = center * BS }, center)
		end
		return
	end
	if m.def.key == "sheep" and item == "shears" then
		if m.age >= 0 and not m.sheared then
			-- Java Sheep.shear: 1 + random(3) wool, each popping out with a little random velocity
			m.sheared = true
			local n = math.random(1, 3)
			for _ = 1, n do
				ItemEntityService.spawn({ item = `{m.color or "white"}_wool`, count = 1 }, (center + Vector3.new(0, 0.5, 0)) * BS)
			end
			InventoryService.damageSelectedTool(p, 1)
			broadcastEvent({ type = "shear", id = m.id, pos = center * BS }, center)
		end
		return
	end
	local dye = item and string.match(item, "^(.+)_dye$")
	if m.def.key == "sheep" and dye and Animals.colorIndex[dye] then
		-- Java DyeItem: a sheep with wool that isn't already that colour
		if not m.sheared and m.color ~= dye then
			m.color = dye
			InventoryService.consumeSelected(p, 1)
		end
		return
	end
	if m.def.key == "cow" and stack and stack.item == "bucket" and m.age >= 0 then
		if stack.count <= 1 then
			InventoryService.setSlot(p, slot, { item = "milk_bucket", count = 1 })
		else
			InventoryService.setSlot(p, slot, { item = "bucket", count = stack.count - 1 })
			if InventoryService.add(p, "milk_bucket", 1) > 0 then
				ItemEntityService.spawn({ item = "milk_bucket", count = 1 }, root.Position)
			end
		end
		broadcastEvent({ type = "milk", id = m.id }, Vector3.new(m.x, m.y, m.z))
	end
end

-- A player reports staring a voidling in the eyes (5 ticks). The server checks range (64) and
-- that no block with collision is in the way.
local function onStare(p: Player, id: any)
	if typeof(id) ~= "number" or p:GetAttribute("Spectator") == true then
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
					flags = bit32.bor(m.flags, if m.burning > 0 then FLAG.BURNING else 0, if m.charged then FLAG.CHARGED else 0,
						if m.age < 0 then FLAG.BABY else 0, if m.sheared then FLAG.SHEARED else 0),
					variant = if m.color then Animals.colorIndex[m.color] else 0,
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

-- Any living mob of `category` whose feet are inside the box (block units)?
function MobService.anyIn(category: string, lo: Vector3, hi: Vector3): boolean
	for _, m in mobs do
		if m.alive and m.def.category == category and m.x >= lo.X and m.x <= hi.X and m.y >= lo.Y and m.y <= hi.Y
			and m.z >= lo.Z and m.z <= hi.Z
		then
			return true
		end
	end
	return false
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

	ExplosionService.setHooks(function(p: Player, amount: number, cause: string, center: Vector3?, byMob: boolean?)
		SurvivalService.damage(p, amount, cause, nil, { armor = true, source = center, scales = byMob, explosion = true })
	end, explosionDamage)
	if ExplosionService.setKnockbackScale then
		ExplosionService.setKnockbackScale(function(p: Player): number
			return Enchantments.blastKnockbackFactor(InventoryService.armor(p))
		end)
	end

	Remotes.get("AttackMob").OnServerEvent:Connect(onAttack)
	Remotes.get("StareMob").OnServerEvent:Connect(onStare)
	Remotes.get("UseMob").OnServerEvent:Connect(onUseMob)
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
