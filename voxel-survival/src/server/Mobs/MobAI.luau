--!strict
-- Mob behaviours, following the Java Edition goals. Each tick `think` sets the mob's wanted ground
-- velocity (wantX/wantZ, blocks/s), jump request and facing; MobService moves it with Java
-- physics.
--
-- Targeting (all hostiles, Java NearestAttackableTargetGoal + TargetGoal):
--   * a new target is looked for about every 0.5 s: the nearest player within followRange
--     (and within 4 blocks vertically) that the mob can SEE: no block with collision (glass and
--     leaves included) between the mob's eyes and the player's eyes
--   * a target is kept while it stays within followRange and was seen in the last 3 s
--   * being hit by a player makes the mob target that player (HurtByTargetGoal)
--
--   wander      passive animals: stroll (about every 6 s, within 10 blocks); panic for 5 s when
--               hurt or burning, running to random spots within 5 blocks at the panic speed
--   melee       zombies, spiders: path to the target and hit when the attack box (own box grown
--               by 0.83 blocks horizontally) touches it, with line of sight, once per second.
--               Spiders only pick targets in darkness (brightness < 0.5) and, in light, drop
--               their target with a 1 % chance per tick; they leap from 2-4 blocks away
--   ranged      skeletons (bow goal): approach until within 15 blocks and seen for 1 s, then
--               strafe (back off under 3.75 blocks); draw 1 s, shoot, wait 2 s
--   exploder    sneaker (creeper): starts its 1.5 s fuse within 3 blocks; the fuse runs while
--               the target is within 7 blocks AND visible, otherwise it cools down
--   teleporter  voidling (enderman): neutral. Provoked by a player looking it in the eyes for
--               5 ticks (client-reported, checked by MobService) or by being hit. While angry it
--               chases at speed 0.45, freezes while stared at (teleports away if the player gets
--               within 4 blocks) and teleports toward a target more than 16 blocks away.
--               Water hurts it; hits from non-living sources make it teleport (90 %); it dodges
--               projectiles; in daylight under open sky it teleports away at random.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Pathfinder = require(Shared.Mobs.Pathfinder)
local MobDefs = require(Shared.Mobs.MobDefs)
local Combat = require(Shared.Gameplay.Combat)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local ExplosionService = require(script.Parent.Parent.World.ExplosionService)

local isLiquid = BlockRegistry.isLiquid
local isSolid = BlockRegistry.isSolid

local MobAI = {}
local S: any = nil -- MobService

local PLAYER_HEIGHT = 1.8
local PLAYER_HALF_WIDTH = 0.3
local UNSEEN_MEMORY = 3 -- seconds (60 ticks)

function MobAI.init(service: any)
	S = service
end

local function face(m: any, dx: number, dz: number)
	if dx ~= 0 or dz ~= 0 then
		m.yaw = math.atan2(-dx, -dz) -- CFrame.Angles(0, yaw, 0) looks along (-sin, -cos)
	end
end

local function speedOf(m: any, modifier: number, attr: number?): number
	return MobDefs.blocksPerSecond((attr or m.def.speedAttr) * modifier)
end

local function eyeOf(m: any): Vector3
	return Vector3.new(m.x, m.y + (m.def.eyeHeight or m.def.height * 0.85), m.z)
end

local function gaussian(): number
	return math.sqrt(-2 * math.log(1 - math.random())) * math.cos(2 * math.pi * math.random())
end

-- Steer straight toward (tx, tz). Returns true when there.
local function steerTo(m: any, tx: number, tz: number, speed: number): boolean
	local dx, dz = tx - m.x, tz - m.z
	local d = math.sqrt(dx * dx + dz * dz)
	if d < 0.2 then
		m.wantX, m.wantZ = 0, 0
		return true
	end
	m.wantX, m.wantZ = dx / d * speed, dz / d * speed
	face(m, dx, dz)
	if m.hitWall and m.onGround then
		m.wantJump = true
	end
	return false
end

-- Follow an A* path to the goal cell, repathing every second (or when the goal moves).
local function goTo(m: any, gx: number, gy: number, gz: number, speed: number, now: number): boolean
	local a = m.ai
	local goalMoved = not a.goal or math.abs(a.goal[1] - gx) + math.abs(a.goal[3] - gz) > 2
	if goalMoved or now >= (a.repathAt or 0) then
		local height = math.ceil(m.def.height - 0.05)
		local path = Pathfinder.find(S.solid, math.floor(m.x), math.floor(m.y + 0.01), math.floor(m.z), gx, gy, gz, {
			height = height,
			maxNodes = 250,
			maxDrop = 3,
		})
		a.path = path
		a.pi = 1
		a.goal = { gx, gy, gz }
		a.repathAt = now + 1 + math.random() * 0.3
	end
	local path = a.path
	if path and a.pi <= #path then
		local node = path[a.pi]
		local cx, cz = node[1] + 0.5, node[3] + 0.5
		if node[2] > math.floor(m.y + 0.01) and m.onGround then
			local dx, dz = cx - m.x, cz - m.z
			if dx * dx + dz * dz < 1.6 or m.hitWall then
				m.wantJump = true
			end
		end
		if steerTo(m, cx, cz, speed) or (math.abs(cx - m.x) < 0.35 and math.abs(cz - m.z) < 0.35) then
			a.pi += 1
		end
		return false
	end
	-- no path (or finished): head straight for it
	return steerTo(m, gx + 0.5, gz + 0.5, speed)
end

local function chase(m: any, t: any, speed: number, now: number)
	goTo(m, math.floor(t.feet.X), math.floor(t.feet.Y + 0.01), math.floor(t.feet.Z), speed, now)
end

local function horizontalDist(m: any, p: Vector3): number
	local dx, dz = p.X - m.x, p.Z - m.z
	return math.sqrt(dx * dx + dz * dz)
end

local function canSee(m: any, t: any): boolean
	return S.lineOfSight(eyeOf(m), t.eye)
end

local function angry(m: any, now: number): boolean
	return (m.ai.angryUntil or 0) > now
end

-- Brightness check for spiders (Java: hostile only below 0.5).
local function inLight(m: any): boolean
	return S.brightness(m.x, m.y + m.def.height, m.z) >= 0.5
end

local function targetFor(targets: { any }, player: Player?): any?
	if not player then
		return nil
	end
	for _, t in targets do
		if t.player == player then
			return t
		end
	end
	return nil
end

-- Current target of a hostile mob (Java targeting rules, see the header), or nil.
local function acquire(m: any, targets: { any }, now: number): any?
	local a = m.ai
	local def = m.def
	-- keep the current target?
	local t = targetFor(targets, a.target)
	if t then
		local d = (t.feet - Vector3.new(m.x, m.y, m.z)).Magnitude
		local seen = canSee(m, t)
		if seen then
			a.seenAt = now
		end
		local keep = d <= def.followRange and now - (a.seenAt or now) <= UNSEEN_MEMORY
		if def.key == "spider" and keep and inLight(m) and not angry(m, now) and math.random() < 0.01 then
			keep = false -- spiders in light give up now and then
		end
		if def.behavior == "teleporter" and not angry(m, now) then
			keep = false
		end
		if keep then
			return t
		end
		a.target = nil
	end
	if def.behavior == "teleporter" then
		return nil -- only provoked (stare / hit)
	end
	if def.key == "spider" and inLight(m) then
		return nil
	end
	-- look for a new one about every 10 ticks
	if math.random() >= 0.1 then
		return nil
	end
	local best, bestD = nil, def.followRange
	local pos = Vector3.new(m.x, m.y, m.z)
	for _, c in targets do
		local d = (c.feet - pos).Magnitude
		-- Java: sneaking players are noticed at 80 % of the range
		local range = if c.sneaking then def.followRange * 0.8 else def.followRange
		if d <= math.min(bestD, range) and math.abs(c.feet.Y - m.y) <= 4 + def.height and canSee(m, c) then
			best, bestD = c, d
		end
	end
	if best then
		a.target = best.player
		a.seenAt = now
		a.path = nil
	end
	return best
end

-- Random reachable cell within `h` blocks horizontally and `v` vertically (Java DefaultRandomPos).
local function randomSpot(m: any, h: number, v: number, awayFrom: Vector3?): { number }?
	local height = math.ceil(m.def.height - 0.05)
	for _ = 1, 10 do
		local ox, oz = math.random(-h, h), math.random(-h, h)
		if awayFrom then
			local ax, az = m.x - awayFrom.X, m.z - awayFrom.Z
			if ox * ax + oz * az < 0 then
				ox, oz = -ox, -oz
			end
		end
		local gx, gz = math.floor(m.x) + ox, math.floor(m.z) + oz
		for dy = v, -v, -1 do
			local gy = math.floor(m.y) + dy
			if Pathfinder.walkable(S.solid, gx, gy, gz, height) then
				local below = S.blockAt(gx, gy - 1, gz)
				local feet = S.blockAt(gx, gy, gz)
				if below and feet and not isLiquid[below + 1] and not isLiquid[feet + 1] then
					return { gx, gy, gz }
				end
			end
		end
	end
	return nil
end

-- Java RandomStrollGoal: a 1-in-120 chance per tick to pick a spot within 10/7 blocks.
local function wander(m: any, now: number, dt: number)
	local a = m.ai
	if not a.wanderGoal and math.random() < dt * 20 / 120 then
		a.wanderGoal = randomSpot(m, 10, 7, nil)
		a.wanderGiveUp = now + 10
	end
	local g = a.wanderGoal
	if g then
		if goTo(m, g[1], g[2], g[3], speedOf(m, m.def.wander), now) or now > (a.wanderGiveUp or 0) then
			a.wanderGoal = nil
		end
	end
end

-- Teleport (Java EnderMan.teleport): random spot +-32 blocks; drops to the first floor below;
-- the spot must be free and dry. `towards` aims 16 blocks toward a position instead.
local function teleport(m: any, attempts: number, towards: Vector3?): boolean
	local from = Vector3.new(m.x, m.y, m.z)
	local h = math.ceil(m.def.height - 0.05)
	for _ = 1, attempts do
		local tx, ty, tz
		if towards then
			local dir = (Vector3.new(m.x, m.y + m.def.height / 2, m.z) - towards)
			dir = if dir.Magnitude > 0.01 then dir.Unit else Vector3.xAxis
			tx = m.x + (math.random() - 0.5) * 8 - dir.X * 16
			ty = m.y + math.random(0, 15) - 8 - dir.Y * 16
			tz = m.z + (math.random() - 0.5) * 8 - dir.Z * 16
		else
			tx = m.x + (math.random() - 0.5) * 64
			ty = m.y + math.random(0, 63) - 32
			tz = m.z + (math.random() - 0.5) * 64
		end
		local gx, gz = math.floor(tx), math.floor(tz)
		local gy = math.clamp(math.floor(ty), 1, Config.WORLD_HEIGHT - 2)
		while gy > 1 do
			local below = S.blockAt(gx, gy - 1, gz)
			if below == nil then
				break
			end
			if isSolid[below + 1] then
				break
			end
			gy -= 1
		end
		local below = S.blockAt(gx, gy - 1, gz)
		local feet = S.blockAt(gx, gy, gz)
		if below and feet and isSolid[below + 1] and not isLiquid[feet + 1] and Pathfinder.walkable(S.solid, gx, gy, gz, h) then
			m.x, m.y, m.z = gx + 0.5, gy, gz + 0.5
			m.vx, m.vy, m.vz = 0, 0, 0
			m.peakY = m.y
			m.ai.path = nil
			S.broadcastEvent({ type = "teleport", id = m.id, from = from * 3, to = Vector3.new(m.x, m.y, m.z) * 3 }, from)
			return true
		end
	end
	return false
end

-- Behaviours ---------------------------------------------------------------------------------

local function passive(m: any, now: number, dt: number)
	local a = m.ai
	if (a.panicUntil or 0) > now or m.burning > 0 then
		m.flags = S.FLAG.PANIC
		local g = a.panicGoal
		if not g then
			g = randomSpot(m, 5, 4, a.panicFrom)
			a.panicGoal = g
		end
		if g then
			if goTo(m, g[1], g[2], g[3], speedOf(m, m.def.panic), now) then
				a.panicGoal = nil
			end
		end
		return
	end
	a.panicGoal = nil
	m.flags = 0
	wander(m, now, dt)
end

-- Java mob attack box: own box grown by MOB_ATTACK_REACH horizontally touches the player's box.
local function inAttackReach(m: any, t: any): boolean
	local r = m.def.width / 2 + Combat.MOB_ATTACK_REACH + PLAYER_HALF_WIDTH
	return math.abs(t.feet.X - m.x) <= r and math.abs(t.feet.Z - m.z) <= r
		and t.feet.Y < m.y + m.def.height and t.feet.Y + PLAYER_HEIGHT > m.y
end

local function melee(m: any, now: number, dt: number, targets: { any }, speed: number?)
	local a = m.ai
	local t = acquire(m, targets, now)
	if m.def.behavior ~= "teleporter" then
		m.flags = 0
	end
	if not t then
		wander(m, now, dt)
		return
	end
	local def = m.def
	if inAttackReach(m, t) then
		m.wantX, m.wantZ = 0, 0
		face(m, t.feet.X - m.x, t.feet.Z - m.z)
		if now >= (a.nextAttack or 0) and canSee(m, t) then
			a.nextAttack = now + def.attackCooldown
			S.hurtPlayer(t, def.attack, `was slain by {def.name}`, Vector3.new(m.x, m.y, m.z))
		end
		return
	end
	-- spiders leap from 2..4 blocks (Java LeapAtTargetGoal 0.4)
	local d = horizontalDist(m, t.feet)
	if def.key == "spider" and d >= 2 and d <= 4 and m.onGround and math.random() < 0.1 then
		local vx = (t.feet.X - m.x) / d * 0.4 + m.vx / 20 * 0.2
		local vz = (t.feet.Z - m.z) / d * 0.4 + m.vz / 20 * 0.2
		m.vx, m.vy, m.vz = vx * 20, 8, vz * 20
		face(m, t.feet.X - m.x, t.feet.Z - m.z)
		return
	end
	chase(m, t, speed or speedOf(m, def.chase), now)
end

-- Skeleton bow goal (Java RangedBowAttackGoal, Normal: 40-tick interval, 20-tick draw, range 15).
local function ranged(m: any, now: number, dt: number, targets: { any })
	local a = m.ai
	local def = m.def
	local t = acquire(m, targets, now)
	m.flags = 0
	if not t then
		a.using = false
		a.seeTime = 0
		wander(m, now, dt)
		return
	end
	local range = def.shootRange or 15
	local eye = eyeOf(m)
	local d = (t.feet - Vector3.new(m.x, m.y, m.z)).Magnitude
	local see = canSee(m, t)
	if see ~= (a.sawLast == true) then
		a.seeTime = 0
	end
	a.sawLast = see
	a.seeTime = (a.seeTime or 0) + (if see then dt else -dt)
	a.strafeTime = a.strafeTime or -1

	if d <= range and a.seeTime >= 1 then
		m.wantX, m.wantZ = 0, 0
		a.strafeTime += dt
	else
		chase(m, t, speedOf(m, def.chase), now)
		a.strafeTime = -1
	end
	if a.strafeTime >= 1 then
		if math.random() < 0.3 then
			a.clockwise = not a.clockwise
		end
		if math.random() < 0.3 then
			a.backwards = not a.backwards
		end
		a.strafeTime = 0
	end
	local dx, dz = t.feet.X - m.x, t.feet.Z - m.z
	local l = math.max(0.01, math.sqrt(dx * dx + dz * dz))
	if a.strafeTime > -1 then
		if d > range * 0.75 then
			a.backwards = false
		elseif d < range * 0.25 then
			a.backwards = true
		end
		local fwd = if a.backwards then -0.5 else 0.5
		local side = if a.clockwise then 0.5 else -0.5
		local wx = dx / l * fwd - dz / l * side
		local wz = dz / l * fwd + dx / l * side
		local wl = math.sqrt(wx * wx + wz * wz)
		local speed = speedOf(m, def.chase)
		m.wantX, m.wantZ = wx / wl * speed, wz / wl * speed
		if m.hitWall and m.onGround then
			m.wantJump = true
		end
	end
	face(m, dx, dz)

	if a.using then
		if not see and a.seeTime < -3 then
			a.using = false
		elseif see and now - a.drawStart >= 1 then
			a.using = false
			a.attackTime = def.attackCooldown
			-- Java: aim at 1/3 of the target's height, + 0.2 per block of distance for the arc;
			-- 1.6 blocks/tick with Normal inaccuracy 6
			local from = Vector3.new(m.x, eye.Y - 0.1, m.z)
			local ex = t.feet.X - from.X
			local ey = t.feet.Y + PLAYER_HEIGHT / 3 - from.Y
			local ez = t.feet.Z - from.Z
			local g = math.sqrt(ex * ex + ez * ez)
			local dir = Vector3.new(ex, ey + g * 0.2, ez).Unit
			dir += Vector3.new(gaussian(), gaussian(), gaussian()) * 0.0075 * 6
			local base = 2 + 2 * 0.11 + (math.random() - math.random()) * 0.57425
			S.shootArrow(from + dir * 0.4, dir * 1.6 * 20, base, def.name, m.id)
		end
	else
		a.attackTime = (a.attackTime or 0) - dt
		if a.attackTime <= 0 and a.seeTime >= -3 then
			a.using = true
			a.drawStart = now
		end
	end
end

-- Creeper-role swell goal.
local function exploder(m: any, now: number, dt: number, targets: { any })
	local a = m.ai
	local def = m.def
	local t = acquire(m, targets, now)
	a.fuse = a.fuse or 0
	a.swellDir = a.swellDir or -1
	local d = if t then (t.feet - Vector3.new(m.x, m.y, m.z)).Magnitude else math.huge
	if t and (a.swellDir > 0 or d < 3) then
		m.wantX, m.wantZ = 0, 0
		face(m, t.feet.X - m.x, t.feet.Z - m.z)
		a.swellDir = if d > 7 or not canSee(m, t) then -1 else 1
	else
		a.swellDir = -1
		if t then
			chase(m, t, speedOf(m, def.chase), now)
		else
			wander(m, now, dt)
		end
	end
	a.fuse = math.max(0, a.fuse + a.swellDir * dt)
	m.flags = if a.fuse > 0 then S.FLAG.FUSING else 0
	if a.fuse >= (def.fuseSeconds or 1.5) then
		local center = Vector3.new(m.x, m.y, m.z)
		S.broadcastEvent({ type = "explode", id = m.id, pos = (center + Vector3.new(0, def.height / 2, 0)) * 3 }, center)
		S.remove(m)
		ExplosionService.explode(center, def.explosionPower or 3, `was blown up by {def.name}`)
	end
end

local function teleporter(m: any, now: number, dt: number, targets: { any })
	local a = m.ai
	local def = m.def
	a.targetChangedAt = a.targetChangedAt or now
	-- daylight: random teleports away (and forget the target) after 30 s with a target/without
	if S.isDay() and now >= a.targetChangedAt + 30 then
		local eye = eyeOf(m)
		local b = S.brightness(eye.X, eye.Y, eye.Z)
		if b > 0.5 and S.skyExposed(math.floor(eye.X), math.floor(eye.Y), math.floor(eye.Z))
			and math.random() * 30 < (b - 0.4) * 2 * (dt * 20)
		then
			a.angryUntil = 0
			a.target = nil
			a.targetChangedAt = now
			teleport(m, 1)
			return
		end
	end
	if angry(m, now) then
		m.flags = S.FLAG.ANGRY
		local t = targetFor(targets, a.target)
		if t then
			local d = (t.feet - Vector3.new(m.x, m.y, m.z)).Magnitude
			local stared = now - (a.staredAt or -math.huge) < 0.3
			if stared and d < 4 then
				teleport(m, 1)
				return
			elseif stared and d <= 16 then
				m.wantX, m.wantZ = 0, 0 -- frozen while looked at
				face(m, t.feet.X - m.x, t.feet.Z - m.z)
				return
			elseif d > 16 then
				a.farTime = (a.farTime or 0) + dt
				if a.farTime >= 1.5 then
					a.farTime = 0
					teleport(m, 1, t.eye)
					return
				end
			end
		end
		melee(m, now, dt, targets, speedOf(m, def.chase, def.angrySpeedAttr))
		m.flags = S.FLAG.ANGRY
		return
	end
	m.flags = 0
	wander(m, now, dt)
end

-- Called by MobService every tick (dt seconds).
function MobAI.think(m: any, dt: number, targets: { any })
	local now = os.clock()
	m.wantX, m.wantZ = 0, 0
	local b = m.def.behavior
	if b == "wander" then
		passive(m, now, dt)
	elseif b == "melee" then
		melee(m, now, dt, targets)
	elseif b == "ranged" then
		ranged(m, now, dt, targets)
	elseif b == "exploder" then
		exploder(m, now, dt, targets)
	elseif b == "teleporter" then
		teleporter(m, now, dt, targets)
	end
end

local function anger(m: any, player: Player, now: number)
	local a = m.ai
	if a.target ~= player then
		a.targetChangedAt = now
	end
	a.target = player
	a.seenAt = now
	a.path = nil
	if m.def.behavior == "teleporter" then
		if not angry(m, now) then
			S.broadcastEvent({ type = "angry", id = m.id }, Vector3.new(m.x, m.y, m.z))
		end
		a.angryUntil = now + math.random(20, 39) -- Java: anger lasts 20-39 s
	end
end

-- Reactions to being hurt. `living`: the damage came from a living entity (player, creeper...).
function MobAI.onHurt(m: any, attacker: Player?, kind: string, living: boolean)
	local now = os.clock()
	local a = m.ai
	if m.def.category == "passive" then
		a.panicUntil = now + 5
		a.panicFrom = if attacker then Vector3.new(m.x - m.vx * 0.1, m.y, m.z - m.vz * 0.1) else nil
		a.panicGoal = nil
	elseif attacker then
		anger(m, attacker, now)
	end
	if m.def.behavior == "teleporter" and m.alive and not living and math.random(10) ~= 1 then
		teleport(m, 1)
	end
end

-- A player stared a voidling in the eyes (validated by MobService).
function MobAI.provoke(m: any, player: Player)
	local now = os.clock()
	m.ai.staredAt = now
	if not angry(m, now) or m.ai.target ~= player then
		anger(m, player, now)
	end
end

-- Projectile about to hit a voidling: it teleports away instead (up to 64 tries).
function MobAI.dodge(m: any)
	teleport(m, 64)
end

-- Voidling standing in water: each tick a teleport attempt (Java: hurt by water, 90 %).
function MobAI.waterTeleport(m: any)
	if math.random(10) ~= 1 then
		teleport(m, 1)
	end
end

return MobAI
