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
local Combat = require(Shared.Gameplay.Combat)
local SneakPose = require(Shared.Gameplay.SneakPose)
local WorldService = require(script.Parent.Parent.World.WorldService)
local InventoryService = require(script.Parent.Parent.Player.InventoryService)
local ExperienceService = require(script.Parent.Parent.Player.ExperienceService)
local SpawnService = require(script.Parent.Parent.Player.SpawnService)
local BlockActionService = require(script.Parent.Parent.Interaction.BlockActionService)
local DayNightService = require(script.Parent.DayNightService)
local WorldSettingsService = require(script.Parent.Parent.World.WorldSettingsService)
local Difficulty = require(Shared.Gameplay.Difficulty)
local Farming = require(Shared.Gameplay.Farming)
local Effects = require(Shared.Gameplay.Effects)
local Enchantments = require(Shared.Items.Enchantments)
local WeatherService = require(script.Parent.Parent.World.WeatherService)

local BS = Config.BLOCK_SIZE
local FEET_BELOW_ROOT = 3 -- R6: HumanoidRootPart centre is 3 studs above the feet
local EAT_SECONDS = 1.6
local FIRE = BlockRegistry.id("fire")
local CAMPFIRE = BlockRegistry.id("campfire")
local function isLava(id: number): boolean
	local def = BlockRegistry.byId[id]
	return def ~= nil and def.fluid == "lava"
end
local isSolid = BlockRegistry.isSolid
local isLiquid = BlockRegistry.isLiquid

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
	hurt: Combat.HurtState, -- 0.5 s invulnerability after a hit
	grounded: boolean,
	inLiquid: boolean,
	sneaking: boolean,
	lastHealth: number, -- for saving after the character is gone
	burning: number, -- seconds of fire left (after lava)
	fireTimer: number,
	peaceHeal: number, -- Peaceful: time towards the next +1 health / +1 food
	peaceFood: number,
	effects: Effects.List, -- status effects (Phase 9c)
	absorption: number, -- extra health from the absorption effect (taken before health)
	effectAcc: number, -- seconds towards the next effect tick (20 per second)
	ticks: number, -- game ticks this life (Java tickCount: Peaceful healing)
	lastDebug: number, -- when exhaustion / timer were last sent (F3)
	exhaustAt: number, -- when the client last reported movement exhaustion
	score: number?, -- experience score at death (death screen)
}

local SurvivalService = {}
local states: { [Player]: State } = {}
-- Hardcore: players who died in this world. They come back only as spectators (Java).
local spectators: { [Player]: boolean } = {}
-- Saved values to apply on the player's first spawn this session (Persistence).
type Restore = {
	health: number, food: number, saturation: number, exhaustion: number, air: number,
	effects: { [string]: any }?, absorption: number?,
}
local pendingRestore: { [Player]: Restore } = {}

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
		hurt = { invulnUntil = 0, lastHurt = 0 },
		grounded = true,
		inLiquid = false,
		sneaking = false,
		lastHealth = 20,
		burning = 0,
		fireTimer = 0,
		peaceHeal = 0,
		peaceFood = 0,
		ticks = 0,
		lastDebug = 0,
		exhaustAt = os.clock(),
		effects = {},
		absorption = 0,
		effectAcc = 0,
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
		score = if event == "died" then s.score else nil,
		absorption = math.ceil(s.absorption),
		-- { id, level (0 = I), seconds left } in display order
		effects = {} :: { { any } },
	}
	local fxKey = ""
	for _, id in Effects.ORDER do
		local e = s.effects[id]
		if e then
			local secs = math.ceil(e.ticks / 20)
			table.insert(payload.effects, { id, e.amp, secs })
			fxKey ..= `{id}{e.amp}:{secs},`
		end
	end
	local key = `{payload.food}|{payload.saturation}|{payload.air}|{payload.canSprint}|{payload.absorption}|{fxKey}`
	-- F3 values (exhaustion, the food tick timer) ride along at most 4 times a second
	local payloadAny = payload :: any
	payloadAny.exhaustion = math.floor(h.exhaustion * 1000 + 0.5) / 1000
	payloadAny.foodTimer = h.tickTimer
	payloadAny.saturation = math.floor(h.saturation * 1000 + 0.5) / 1000
	local now = os.clock()
	local debugDue = now - s.lastDebug >= 0.25
	if event or key ~= s.lastSent or debugDue then
		s.lastDebug = now
		s.lastSent = key
		Remotes.get("SurvivalSync"):FireClient(p, payload)
	end
end

-- Apply damage (HP). `cause` is shown on the death screen. Java invulnerability applies: for
-- 0.5 s after a hit only a stronger hit gets through, and only its difference. Returns the damage
-- dealt and whether it was a fresh hit (callers apply knockback only then). `bypass` skips the
-- invulnerability check (falling out of the world).
-- Damage options (Phase 8c): `armor` = worn armour reduces it (attacks, arrows, explosions,
-- fire, lava; not falls, drowning, starving, the void); `source` = where it came from (block
-- units) so a raised shield in front can block it.
-- `scales` = caused by a living mob (bites, its arrows, a Sneaker's blast): changed by the
-- difficulty first (Gameplay/Difficulty: Peaceful 0, Easy halved + 1, Hard x 1.5).
-- `fire` = fire, lava, burning, campfires (fire resistance blocks it); `magic` = poison (no
-- exhaustion, Java's magic damage type).
-- `explosion`, `projectile`, `fall`: the kind of hit for the specific protection enchantments
-- (Phase 10d); `attacker`: the mob behind it (Thorns hits back).
export type DamageOpts = { armor: boolean?, source: Vector3?, scales: boolean?, fire: boolean?, magic: boolean?, starve: boolean?,
	explosion: boolean?, projectile: boolean?, fall: boolean? }
-- Set by CombatGearService (avoids a require cycle): shield and armour.
local gear: { block: (Player, number, DamageOpts) -> boolean, armor: (Player, number) -> number }? = nil
function SurvivalService.setGear(g: { block: (Player, number, DamageOpts) -> boolean, armor: (Player, number) -> number })
	gear = g
end

function SurvivalService.damage(p: Player, amount: number, cause: string, bypass: boolean?, opts: DamageOpts?): (number, boolean)
	local humanoid = humanoidOf(p)
	local s = state(p)
	if not humanoid or s.dead or humanoid.Health <= 0 or amount <= 0 or spectators[p] then
		return 0, false
	end
	if opts and opts.fire and s.effects.fire_resistance then
		return 0, false -- Java: fire resistance ignores fire damage completely
	end
	if opts and opts.scales then
		amount = Difficulty.scaleMobDamage(WorldSettingsService.difficulty(), amount)
		if amount <= 0 then
			return 0, false -- Java: a hit scaled to nothing doesn't hurt at all
		end
	end
	-- Java order: a shield blocks first (nothing gets through, no knockback), then the hurt
	-- cooldown, then armour.
	if gear and opts and opts.source and gear.block(p, amount, opts) then
		sync(p, "blocked")
		return 0, false
	end
	local dealt, fresh = amount, true
	if not bypass then
		dealt, fresh = Combat.applyInvulnerability(s.hurt, amount, os.clock())
		if dealt <= 0 then
			return 0, false
		end
	end
	if gear and opts and opts.armor then
		dealt = gear.armor(p, dealt)
	end
	-- Java LivingEntity.actuallyHurt: armour, then resistance (not the void), then absorption
	if not bypass and not (opts and opts.starve) then
		dealt = Effects.resist(s.effects, dealt) -- (starvation ignores Resistance)
		-- protection enchantments (Java getDamageAfterMagicAbsorb): not for starving or the void
		local o = opts or {}
		local epf = Enchantments.protection(InventoryService.armor(p), {
			fire = o.fire, explosion = o.explosion, projectile = o.projectile, fall = o.fall,
		})
		dealt = Enchantments.afterProtection(dealt, epf)
	end
	local absorbed = math.min(s.absorption, dealt)
	s.absorption -= absorbed
	local toHealth = dealt - absorbed
	-- Java: getting hurt wakes a sleeping player
	require(script.Parent.Parent.Player.BedService).onHurt(p)
	-- Java: 0.1 exhaustion for damage types armour protects against (attacks, arrows,
	-- explosions, fire, lava, cactus); falls, drowning, starving, the void and magic add none
	if opts and opts.armor then
		SurvivalRules.addExhaustion(s.hunger, SurvivalRules.EXHAUSTION.damage)
	end
	s.lastCause = cause
	humanoid.Health = math.max(0, humanoid.Health - toHealth)
	sync(p, "hurt", cause)
	return dealt, fresh
end

-- Movement state the server tracks (for critical hits and sprint knockback).
function SurvivalService.movement(p: Player): (boolean, boolean, boolean)
	local s = state(p)
	return s.sprinting, s.grounded, s.inLiquid
end

function SurvivalService.setRestore(p: Player, r: Restore)
	pendingRestore[p] = r
end

-- Save snapshot. A dead player is saved as respawned (their items were already dropped).
function SurvivalService.snapshot(p: Player): (Restore, boolean)
	local s = states[p]
	local r = pendingRestore[p]
	if r then
		return r, false -- not spawned yet: keep what was loaded
	end
	if not s or s.dead then
		return { health = 20, food = 20, saturation = SurvivalRules.START_SATURATION, exhaustion = 0, air = SurvivalRules.MAX_AIR }, s ~= nil and s.dead
	end
	local humanoid = humanoidOf(p)
	return {
		health = if humanoid and humanoid.Health > 0 then humanoid.Health else s.lastHealth,
		food = s.hunger.food,
		saturation = s.hunger.saturation,
		exhaustion = s.hunger.exhaustion,
		air = s.air,
		effects = Effects.encode(s.effects),
		absorption = s.absorption,
	}, false
end

-- Struck by lightning (Java Entity.thunderHit): 5 damage (armour counts) and on fire for 8 s
-- (just a tick longer if already burning).
function SurvivalService.lightning(p: Player)
	local s = state(p)
	if s.dead or spectators[p] then
		return
	end
	s.burning = if s.burning > 0 then s.burning + 0.05 else 8 * Enchantments.burnFactor(InventoryService.armor(p))
	SurvivalService.damage(p, 5, "was struck by lightning", nil, { armor = true })
end

-- Set on fire for at least `seconds` (a Flame arrow: 5 s).
function SurvivalService.ignite(p: Player, seconds: number)
	local s = state(p)
	s.burning = math.max(s.burning, seconds * Enchantments.burnFactor(InventoryService.armor(p)))
end

function SurvivalService.isSneaking(p: Player): boolean
	return state(p).sneaking
end

-- The client stopped sprinting because of an attack (Java: sprint hits end the sprint).
function SurvivalService.stopSprint(p: Player)
	state(p).sprinting = false
end

function SurvivalService.addExhaustion(p: Player, amount: number)
	SurvivalRules.addExhaustion(state(p).hunger, amount)
end

-- Block at world block coords (0 for out of range).
local function block(x: number, y: number, z: number): number
	return WorldService.getBlock(x, y, z)
end

-- One tick of status effects (Gameplay/Effects).
local function stepEffects(p: Player, s: State, humanoid: Humanoid)
	local ended = Effects.tick(s.effects, {
		health = function()
			return humanoid.Health
		end,
		maxHealth = function()
			return humanoid.MaxHealth
		end,
		hurt = function(n: number)
			SurvivalService.damage(p, n, "was killed by magic", nil, { magic = true })
		end,
		heal = function(n: number)
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + n)
		end,
		exhaust = function(n: number)
			SurvivalRules.addExhaustion(s.hunger, n)
		end,
		absorption = function()
			return s.absorption
		end,
	})
	-- the absorption hearts never exceed what the current level gives (0 once it's gone)
	s.absorption = math.min(s.absorption, Effects.absorptionMax(s.effects))
	if #ended > 0 then
		sync(p)
	end
end

-- Give a player an effect (Java addEffect). Absorption fills its hearts when given or raised.
function SurvivalService.addEffect(p: Player, id: string, amp: number, ticks: number): boolean
	local s = state(p)
	if s.dead or spectators[p] then
		return false
	end
	local changed = Effects.add(s.effects, id, amp, ticks)
	if changed and id == "absorption" then
		s.absorption = math.max(s.absorption, 4 * (amp + 1))
	end
	s.absorption = math.min(s.absorption, Effects.absorptionMax(s.effects))
	sync(p)
	return changed
end

-- Milk (Java removeAllEffects).
function SurvivalService.clearEffects(p: Player)
	local s = state(p)
	Effects.clear(s.effects)
	s.absorption = 0
	sync(p)
end

function SurvivalService.effects(p: Player): Effects.List
	return state(p).effects
end

local function stepPlayer(p: Player, s: State, dt: number)
	local humanoid, root = humanoidOf(p)
	if not humanoid or not root or humanoid.Health <= 0 or s.dead or spectators[p] then
		return
	end
	local pos = root.Position
	local feetY = pos.Y - FEET_BELOW_ROOT
	local bx, bz = math.floor(pos.X / BS), math.floor(pos.Z / BS)
	local feetBlock = block(bx, math.floor((feetY + 0.1) / BS), bz)
	local bodyBlock = block(bx, math.floor((pos.Y) / BS), bz)
	local eyeBlock = block(bx, math.floor((pos.Y + SneakPose.eyeHeight(p.Character)) / BS), bz)
	local belowY = math.floor((feetY - 0.1) / BS)
	local grounded = isSolid[block(bx, belowY, bz) + 1] and feetY - (belowY + 1) * BS <= 0.4

	s.lastHealth = humanoid.Health

	-- Recent heights, to sanity-check falls the client reports (see "fall" action).
	table.insert(s.heights, { t = os.clock(), y = feetY })
	while #s.heights > 0 and os.clock() - s.heights[1].t > 8 do
		table.remove(s.heights, 1)
	end

	-- (Movement exhaustion - sprinting, swimming, jumps - is measured by the client's Java
	-- physics tick by tick and reported with the "exhaust" action.)
	s.wasGrounded = grounded
	s.grounded = grounded
	s.inLiquid = isLiquid[feetBlock + 1] or isLiquid[bodyBlock + 1]
	s.lastPos = pos
	if s.sprinting and not SurvivalRules.canSprint(s.hunger) then
		s.sprinting = false -- client is told via canSprint in the next sync
	end

	-- Air / drowning
	if isLiquid[eyeBlock + 1] then
		-- Respiration (Java oxygen_bonus): each tick only 1 in (level + 1) costs air, so air
		-- (and the drowning count after it) lasts level + 1 times longer
		local helmet = InventoryService.armor(p)[1]
		local slow = 1 + Enchantments.level(helmet, "respiration")
		s.air = math.max(0, s.air - dt / slow)
		if s.air <= 0 then
			s.drownTimer += dt / slow
			while s.drownTimer >= 1 do
				s.drownTimer -= 1
				SurvivalService.damage(p, SurvivalRules.DROWN_DAMAGE, "drowned")
			end
		end
	else
		s.air = math.min(SurvivalRules.MAX_AIR, s.air + dt * 5)
		s.drownTimer = 0
	end

	-- Lava: 4 damage (every tick, so every 0.5 s through invulnerability) and 15 s of fire;
	-- fire burns 1 per second until it runs out or you step into water (Java).
	if isLava(feetBlock) or isLava(bodyBlock) then
		s.burning = 15 * Enchantments.burnFactor(InventoryService.armor(p)) -- (Fire Protection: shorter)
		SurvivalService.damage(p, SurvivalRules.LAVA_DAMAGE, "tried to swim in lava", nil, { armor = true, fire = true })
	elseif s.inLiquid or WeatherService.rainOn(pos.X / BS, feetY / BS, pos.Z / BS, 1.8) then
		s.burning = 0 -- water and rain put you out (Java isInWaterRainOrBubble)
	elseif feetBlock == FIRE or bodyBlock == FIRE then
		-- Java: standing in fire hurts 1 per hit and sets you on fire for 8 s
		s.burning = math.max(s.burning, 8 * Enchantments.burnFactor(InventoryService.armor(p)))
		SurvivalService.damage(p, 1, "went up in flames", nil, { armor = true, fire = true })
	end
	-- Java: walking on a lit campfire hurts (1), unless sneaking or wearing Frost Walker boots
	if grounded and not s.sneaking and block(bx, belowY, bz) == CAMPFIRE
		and Enchantments.level(InventoryService.armor(p)[4], "frost_walker") == 0
	then
		SurvivalService.damage(p, 1, "was burned on a campfire", nil, { armor = true, fire = true })
	end
	if s.burning > 0 then
		s.burning -= dt
		s.fireTimer += dt
		if s.fireTimer >= 1 then
			s.fireTimer -= 1
			SurvivalService.damage(p, 1, "burned to death", nil, { armor = true, fire = true })
		end
	else
		s.fireTimer = 0
	end

	-- Cactus (Java: touching it, 1 damage; its 1/16 inset lets you walk into its cell)
	do
		local fx, fy, fz = pos.X / BS, feetY / BS, pos.Z / BS
		local pricked = false
		for cx = math.floor(fx - 0.299), math.floor(fx + 0.299) do
			for cz = math.floor(fz - 0.299), math.floor(fz + 0.299) do
				for cy = math.floor(fy + 0.001), math.floor(fy + 1.799) do
					if Farming.isCactus(block(cx, cy, cz)) then
						pricked = true
					end
				end
			end
		end
		if pricked then
			SurvivalService.damage(p, 1, "was pricked to death", nil, { armor = true })
		end
	end

	-- Out of the world
	if pos.Y < -64 then
		SurvivalService.damage(p, 1000, "fell out of the world", true)
	end

	-- Status effects, one Java tick (1/20 s) at a time
	s.effectAcc += dt
	local fxTicks = 0
	while s.effectAcc >= 0.05 and fxTicks < 10 do
		s.effectAcc -= 0.05
		fxTicks += 1
		if next(s.effects) then
			stepEffects(p, s, humanoid)
		end
	end
	if fxTicks >= 10 then
		s.effectAcc = 0
	end
	if humanoid.Health <= 0 or s.dead then
		return
	end

	-- Hunger, regeneration, starvation: Java's FoodData, one call per game tick (stepPlayer
	-- runs exactly once per tick, see init)
	s.ticks += 1
	local difficulty = WorldSettingsService.difficulty()
	local peaceful = difficulty == "peaceful"
	s.hunger.peaceful = peaceful
	if peaceful then
		-- Java Player.aiStep on Peaceful: +1 health on every 20th tick, +1 hunger on every 10th
		if humanoid.Health < humanoid.MaxHealth and s.ticks % 20 == 0 then
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + 1)
		end
		if s.hunger.food < SurvivalRules.MAX_FOOD and s.ticks % 10 == 0 then
			s.hunger.food += 1
		end
	end
	local heal, starve = SurvivalRules.tickFood(s.hunger, humanoid.Health, humanoid.MaxHealth, difficulty)
	if heal > 0 then
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + heal)
	end
	if starve > 0 then
		SurvivalService.damage(p, starve, "starved", nil, { starve = true })
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
		local blocks = math.clamp(a.blocks, 0, seen)
		local hereDef = BlockRegistry.byId[here]
		if hereDef and hereDef.shape == "bed" then
			blocks *= 0.5 -- Java: beds halve fall damage
		end
		local dmg = SurvivalRules.fallDamage(blocks, isLiquid[here + 1])
		if dmg > 0 then
			SurvivalService.damage(p, dmg, "fell from a high place", nil, { fall = true })
		end
		table.clear(s.heights) -- a fall is only counted once
	elseif t == "exhaust" then
		-- Movement exhaustion the client's Java physics measured (sprinting on the ground,
		-- swimming, jumps). Capped by the time since the last report (sprint-jumping is under
		-- 1 a second), so a bad client can't starve itself in an instant.
		local amount = a.amount
		if typeof(amount) ~= "number" or amount ~= amount or amount <= 0 or s.dead or spectators[p] then
			return
		end
		local now = os.clock()
		local since = math.clamp(now - s.exhaustAt, 0, 2)
		s.exhaustAt = now
		SurvivalRules.addExhaustion(s.hunger, math.min(amount, since * 1.5 + 0.3))
	elseif t == "sprint" then
		s.sprinting = a.on == true and SurvivalRules.canSprint(s.hunger) and not s.sneaking
	elseif t == "sneak" then
		-- pose for everyone else (the owner already shows it); eye height for reach checks
		s.sneaking = a.on == true
		if s.sneaking then
			s.sprinting = false
		end
		local character = p.Character
		if character then
			character:SetAttribute("Sneaking", s.sneaking)
			SneakPose.apply(character, s.sneaking)
		end
	elseif t == "eatStart" then
		s.eatingSince = os.clock()
		-- the off hand eats when the main hand has no food (Java: main hand first)
		s.eatingSlot = if a.hand == "off" then Config.OFFHAND_SLOT else InventoryService.selectedSlot(p)
	elseif t == "eatCancel" then
		s.eatingSince = nil
	elseif t == "eatFinish" then
		local since = s.eatingSince
		s.eatingSince = nil
		if not since or os.clock() - since < EAT_SECONDS - 0.15 or s.dead then
			return
		end
		local slot = s.eatingSlot
		if slot ~= Config.OFFHAND_SLOT and InventoryService.selectedSlot(p) ~= slot then
			return
		end
		local stack = InventoryService.getSlot(p, slot)
		local def = stack and ItemRegistry.get(stack.item)
		local food = def and def.food
		if not stack or not food or (s.hunger.food >= SurvivalRules.MAX_FOOD and not food.alwaysEat) then
			return
		end
		local st = stack :: InventoryService.Stack
		st.count -= 1
		InventoryService.setSlot(p, slot, if st.count > 0 then st else nil)
		if food.remainder then
			-- stews leave their bowl (in the same slot when it's empty, else in the inventory)
			if st.count <= 0 then
				InventoryService.setSlot(p, slot, { item = food.remainder, count = 1 })
			elseif InventoryService.add(p, food.remainder, 1) > 0 then
				local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if root then
					require(script.Parent.Parent.World.ItemEntityService).spawn({ item = food.remainder, count = 1 }, root.Position)
				end
			end
		end
		do
			if food.hunger > 0 or food.saturation > 0 then
				SurvivalRules.eat(s.hunger, food.hunger, food.saturation)
			end
			if food.clearsEffects then
				SurvivalService.clearEffects(p) -- milk
			end
			-- Java: the food's effects after its nutrition, each with its chance
			for _, fx in Effects.FOOD[st.item] or {} do
				if fx.chance >= 1 or math.random() < fx.chance then
					SurvivalService.addEffect(p, fx.id, fx.amp, fx.ticks)
				end
			end
			sync(p)
		end
	elseif t == "respawn" then
		if s.dead then
			SpawnService.respawn(p) -- (Hardcore: comes back as a spectator, see onCharacter)
		end
	end
end

-- Spectator (Hardcore after death): no damage, hunger or pickups, can't touch the world, mobs
-- ignore you, and others can't see you. The attribute is what the rest of the server checks.
local function applySpectator(p: Player, character: Model?)
	p:SetAttribute("Spectator", true)
	if character then
		for _, d in character:GetDescendants() do
			if d:IsA("BasePart") then
				d.Transparency = 1
				d.CanQuery = false
				d.CanTouch = false
			elseif d:IsA("Decal") then
				d.Transparency = 1
			end
		end
		character.DescendantAdded:Connect(function(d)
			if d:IsA("BasePart") then
				d.Transparency = 1
			elseif d:IsA("Decal") then
				d.Transparency = 1
			end
		end)
	end
end

function SurvivalService.isSpectator(p: Player): boolean
	return spectators[p] == true
end

-- From the save (Persistence): this player already died in this Hardcore world.
function SurvivalService.setSpectator(p: Player, on: boolean)
	spectators[p] = if on then true else nil
	if on then
		applySpectator(p, p.Character)
	end
end

local function onCharacter(p: Player, character: Model)
	SneakPose.remember(character)
	local s = state(p)
	-- A fresh life: full health and hunger (classic respawn).
	local fresh = newState()
	states[p] = fresh
	s = fresh
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	-- Roblox's default "Health" script regenerates 1% per second; our rules replace it.
	-- (src/character/Health replaces it; any "Health" script that still shows up is switched off.)
	for _, c in character:GetChildren() do
		if c.Name == "Health" and c:IsA("BaseScript") then
			(c :: BaseScript).Enabled = false
		end
	end
	character.ChildAdded:Connect(function(c)
		if c.Name == "Health" and c:IsA("BaseScript") then
			(c :: BaseScript).Enabled = false
		end
	end)

	humanoid.MaxHealth = SurvivalRules.MAX_HEALTH
	humanoid.Health = SurvivalRules.MAX_HEALTH
	local r = pendingRestore[p]
	if r then
		-- first spawn after joining: continue where the save left off
		pendingRestore[p] = nil
		humanoid.Health = math.max(1, r.health)
		s.hunger.food = r.food
		s.hunger.saturation = r.saturation
		s.hunger.exhaustion = r.exhaustion
		s.air = r.air
		if r.effects then
			s.effects = Effects.decode(r.effects)
			s.absorption = math.min(r.absorption or 0, Effects.absorptionMax(s.effects))
		end
	end
	if spectators[p] then
		applySpectator(p, character)
	end
	humanoid.Died:Connect(function()
		if s.dead then
			return
		end
		if WorldSettingsService.isHardcore() then
			spectators[p] = true -- one life: from now on this player only watches (saved)
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
		-- experience: 7 x level (max 100) drops as orbs, the rest is lost; the score shows on the
		-- death screen
		s.score = ExperienceService.onDeath(p, if root then root.Position / Config.BLOCK_SIZE - Vector3.new(0, 1, 0) else nil)
		sync(p, "died", s.lastCause or "died")
	end)
	sync(p, "spawned")
end

function SurvivalService.init()
	BlockActionService.onBlockBroken(function(p: Player)
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
		elseif a.type == "giveItem" then
			-- Studio test menu (C): any item, up to one full stack
			local def = typeof(a.item) == "string" and ItemRegistry.get(a.item)
			local n = if typeof(a.count) == "number" then math.clamp(math.floor(a.count), 1, 64) else 1
			if def then
				InventoryService.add(p, def.key, math.min(n, def.stack))
			end
		elseif a.type == "dropPile" then
			-- 200 random stacks in a 9 x 9 block square around the player (dropped-item
			-- performance check; they're ordinary dropped items and despawn as usual)
			local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				local items = ItemRegistry.list()
				local Drops = require(script.Parent.Parent.World.ItemEntityService)
				for _ = 1, 200 do
					local def = items[math.random(1, #items)]
					local pos = root.Position + Vector3.new(math.random(-12, 12), 3, math.random(-12, 12))
					Drops.spawn({ item = def.key, count = math.random(1, math.min(64, def.stack)) }, pos, 3)
				end
			end
		elseif a.type == "giveKit" then
			InventoryService.add(p, "torch", 64)
			InventoryService.add(p, "coal", 16)
			-- phase 8a test kit
			InventoryService.add(p, "bucket", 2)
			InventoryService.add(p, "water_bucket", 1)
			InventoryService.add(p, "lava_bucket", 1)
			InventoryService.add(p, "flint_and_steel", 1)
			InventoryService.add(p, "tnt", 8)
			InventoryService.add(p, "sand", 32)
			InventoryService.add(p, "gravel", 32)
			InventoryService.add(p, "campfire", 2)
			InventoryService.add(p, "raw_beef", 4)
			InventoryService.add(p, "oak_planks", 32)
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
		task.delay(30, function() -- kept a moment longer so Persistence can save it
			states[p] = nil
			pendingRestore[p] = nil
			spectators[p] = nil
		end)
	end)

	local acc = 0
	-- Exactly 20 game ticks a second (Java's rate), each a step of 1/20 s; after a long hitch
	-- at most 10 ticks catch up at once.
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		local n = 0
		while acc >= SurvivalRules.TICK and n < 10 do
			acc -= SurvivalRules.TICK
			n += 1
			for p, s in states do
				if p.Parent then
					stepPlayer(p, s, SurvivalRules.TICK)
					-- safety net: respawn if the death screen never answered
					if s.dead and os.clock() - s.diedAt > Config.AUTO_RESPAWN_SECONDS then
						s.diedAt = math.huge
						SpawnService.respawn(p)
					end
				end
			end
		end
		if n >= 10 then
			acc = 0
		end
	end)
end

return SurvivalService
