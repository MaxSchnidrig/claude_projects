--!strict
-- Mob behaviours. Each tick `think` sets the mob's desired horizontal velocity (wantX/wantZ),
-- jump request and facing; MobService then moves it with MobPhysics.
--
--   wander      passive animals: idle / stroll to random nearby cells; panic (run away) when hurt
--   melee       chase the nearest player (A* path, repath 1 s) and hit within reach
--               spiders: neutral in daylight under open sky unless hurt; they leap and climb
--   ranged      skeletons: keep 5..14 blocks away with line of sight, shoot arrows every ~2 s
--   exploder    cinderhusk: walk up, then fuse for 1.5 s within 3 blocks (crackling glow) and
--               explode; the fuse cools down if the player gets more than 7 blocks away
--   teleporter  shiftling: neutral wanderer that blinks around; becomes hostile when hit OR when
--               a player breaks a block within 4 blocks of it (it guards its patch of ground);
--               teleports away from water and often when hurt

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Pathfinder = require(Shared.Mobs.Pathfinder)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local ExplosionService = require(script.Parent.Parent.World.ExplosionService)

local isLiquid = BlockRegistry.isLiquid

local MobAI = {}
local S: any = nil -- MobService

function MobAI.init(service: any)
	S = service
end

local function face(m: any, dx: number, dz: number)
	if dx ~= 0 or dz ~= 0 then
		m.yaw = math.atan2(-dx, -dz) -- CFrame.Angles(0, yaw, 0) looks along (-sin, -cos)
	end
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

local function horizontalDist(m: any, p: Vector3): number
	local dx, dz = p.X - m.x, p.Z - m.z
	return math.sqrt(dx * dx + dz * dz)
end

-- Is this mob standing in daylight under open sky?
local function lit(m: any): boolean
	return S.isDay() and S.skyExposed(math.floor(m.x), math.floor(m.y + m.def.height), math.floor(m.z))
end

local function angry(m: any, now: number): boolean
	return (m.ai.angryUntil or 0) > now
end

-- Nearest valid target for a hostile mob, or nil.
local function acquire(m: any, targets: { any }, now: number): any?
	local def = m.def
	if def.behavior == "teleporter" and not angry(m, now) then
		return nil
	end
	if def.neutralInLight and not angry(m, now) and lit(m) then
		return nil
	end
	local best, bestD = nil, def.followRange
	for _, t in targets do
		local d = (t.feet - Vector3.new(m.x, m.y, m.z)).Magnitude
		if d < bestD and math.abs(t.feet.Y - m.y) < 10 then
			if m.ai.angryAt == nil or not angry(m, now) or t.player == m.ai.angryAt then
				best, bestD = t, d
			end
		end
	end
	return best
end

local function wander(m: any, now: number, speedFactor: number)
	local a = m.ai
	if not a.wanderAt or now >= a.wanderAt then
		a.wanderAt = now + 4 + math.random() * 6
		a.wanderGoal = nil
		if math.random() < 0.6 then
			-- a random walkable cell within 6 blocks
			for _ = 1, 6 do
				local gx = math.floor(m.x) + math.random(-6, 6)
				local gz = math.floor(m.z) + math.random(-6, 6)
				local h = math.ceil(m.def.height - 0.05)
				for dy = 2, -3, -1 do
					local gy = math.floor(m.y) + dy
					if Pathfinder.walkable(S.solid, gx, gy, gz, h) then
						local below = S.blockAt(gx, gy - 1, gz)
						if below and not isLiquid[below + 1] then
							a.wanderGoal = { gx, gy, gz }
							break
						end
					end
				end
				if a.wanderGoal then
					break
				end
			end
		end
	end
	local g = a.wanderGoal
	if g then
		if goTo(m, g[1], g[2], g[3], m.def.speed * speedFactor, now) then
			a.wanderGoal = nil
		end
	end
end

local function teleport(m: any): boolean
	local from = Vector3.new(m.x, m.y, m.z)
	local h = math.ceil(m.def.height - 0.05)
	for _ = 1, 16 do
		local gx = math.floor(m.x) + math.random(-16, 16)
		local gz = math.floor(m.z) + math.random(-16, 16)
		for gy = math.floor(m.y) + 8, math.floor(m.y) - 8, -1 do
			if Pathfinder.walkable(S.solid, gx, gy, gz, h) then
				local feet = S.blockAt(gx, gy, gz)
				if feet and not isLiquid[feet + 1] then
					m.x, m.y, m.z = gx + 0.5, gy, gz + 0.5
					m.vx, m.vy, m.vz = 0, 0, 0
					m.peakY = m.y
					m.ai.path = nil
					S.broadcastEvent({ type = "teleport", id = m.id, from = from * 3, to = Vector3.new(m.x, m.y, m.z) * 3 }, from)
					return true
				end
			end
		end
	end
	return false
end

-- Behaviours ---------------------------------------------------------------------------------

local function passive(m: any, now: number)
	local a = m.ai
	if (a.panicUntil or 0) > now then
		m.flags = S.FLAG.PANIC
		local from = a.panicFrom or Vector3.new(m.x, m.y, m.z)
		local dx, dz = m.x - from.X, m.z - from.Z
		local d = math.sqrt(dx * dx + dz * dz)
		if d < 0.01 then
			dx, dz, d = math.random() - 0.5, math.random() - 0.5, 0.5
		end
		local tx, tz = m.x + dx / d * 8, m.z + dz / d * 8
		goTo(m, math.floor(tx), math.floor(m.y), math.floor(tz), m.def.speed * 1.25, now)
		return
	end
	m.flags = 0
	wander(m, now, 0.5)
end

local function melee(m: any, now: number, targets: { any })
	local a = m.ai
	local t = acquire(m, targets, now)
	m.flags = if angry(m, now) then S.FLAG.ANGRY else 0
	if not t then
		wander(m, now, 0.5)
		return
	end
	local def = m.def
	local d = horizontalDist(m, t.feet)
	local dy = t.feet.Y - m.y
	if d <= def.reach + def.width / 2 + 0.35 and math.abs(dy) < 1.6 then
		m.wantX, m.wantZ = 0, 0
		face(m, t.feet.X - m.x, t.feet.Z - m.z)
		if now >= (a.nextAttack or 0) then
			a.nextAttack = now + def.attackCooldown
			S.hurtPlayer(t, def.attack, `was slain by {def.name}`, Vector3.new(m.x, m.y, m.z))
		end
		return
	end
	-- spiders leap at close range
	if def.key == "spider" and d < 3.5 and m.onGround and now >= (a.leapAt or 0) then
		a.leapAt = now + 2
		m.vy = 6
		m.vx = (t.feet.X - m.x) / d * 6
		m.vz = (t.feet.Z - m.z) / d * 6
		m.knockbackUntil = now + 0.4 -- keep the leap velocity for a moment
		face(m, t.feet.X - m.x, t.feet.Z - m.z)
		return
	end
	goTo(m, math.floor(t.feet.X), math.floor(t.feet.Y + 0.01), math.floor(t.feet.Z), def.speed, now)
end

local function ranged(m: any, now: number, targets: { any })
	local a = m.ai
	local def = m.def
	local t = acquire(m, targets, now)
	m.flags = 0
	if not t then
		wander(m, now, 0.5)
		return
	end
	local eye = Vector3.new(m.x, m.y + 1.6, m.z)
	local d = (t.eye - eye).Magnitude
	local los = S.lineOfSight(eye, t.eye)
	local range = def.shootRange or 14
	if d > range or not los then
		goTo(m, math.floor(t.feet.X), math.floor(t.feet.Y + 0.01), math.floor(t.feet.Z), def.speed, now)
	elseif d < 5 then
		-- back off
		local dx, dz = m.x - t.feet.X, m.z - t.feet.Z
		local l = math.max(0.01, math.sqrt(dx * dx + dz * dz))
		m.wantX, m.wantZ = dx / l * def.speed * 0.8, dz / l * def.speed * 0.8
		if m.hitWall and m.onGround then
			m.wantJump = true
		end
	else
		-- strafe sideways, switching direction every couple of seconds
		if now >= (a.strafeAt or 0) then
			a.strafeAt = now + 1.5 + math.random()
			a.strafeDir = if math.random() < 0.5 then -1 else 1
		end
		local dx, dz = t.feet.X - m.x, t.feet.Z - m.z
		local l = math.max(0.01, math.sqrt(dx * dx + dz * dz))
		m.wantX, m.wantZ = -dz / l * (a.strafeDir or 1) * 0.8, dx / l * (a.strafeDir or 1) * 0.8
	end
	face(m, t.feet.X - m.x, t.feet.Z - m.z)
	if los and d <= range and now >= (a.nextAttack or 0) then
		a.nextAttack = now + def.attackCooldown + math.random() * 0.6
		local speed = 24
		local flight = d / speed
		local aim = (t.eye - Vector3.new(0, 0.3, 0)) - eye
		local vel = aim.Unit * speed + Vector3.new(0, 0.5 * 20 * flight, 0) -- lead for gravity
		S.shootArrow(eye + aim.Unit * 0.6, vel, math.random(2, 4), def.name)
	end
end

local function exploder(m: any, now: number, targets: { any })
	local a = m.ai
	local def = m.def
	local t = acquire(m, targets, now)
	a.fuse = a.fuse or 0
	if not t then
		a.fuse = math.max(0, a.fuse - 0.05)
		m.flags = if a.fuse > 0 then S.FLAG.FUSING else 0
		wander(m, now, 0.5)
		return
	end
	local center = Vector3.new(m.x, m.y + def.height / 2, m.z)
	local d = (t.feet + Vector3.new(0, 0.9, 0) - center).Magnitude
	local los = S.lineOfSight(center, t.eye)
	if (d <= (def.reach or 3) and los) or (a.fuse > 0 and d <= 7) then
		m.wantX, m.wantZ = 0, 0
		face(m, t.feet.X - m.x, t.feet.Z - m.z)
		a.fuse += 0.05
		m.flags = S.FLAG.FUSING
		if a.fuse >= (def.fuseSeconds or 1.5) then
			S.broadcastEvent({ type = "explode", id = m.id, pos = center * 3 }, center)
			S.remove(m)
			ExplosionService.explode(center, def.explosionPower or 3, `was blown up by {def.name}`)
		end
		return
	end
	a.fuse = math.max(0, a.fuse - 0.05)
	m.flags = if a.fuse > 0 then S.FLAG.FUSING else 0
	goTo(m, math.floor(t.feet.X), math.floor(t.feet.Y + 0.01), math.floor(t.feet.Z), def.speed, now)
end

local function teleporter(m: any, now: number, targets: { any })
	local a = m.ai
	if m.inLiquid then
		teleport(m)
		return
	end
	if angry(m, now) then
		melee(m, now, targets)
		m.flags = S.FLAG.ANGRY
		return
	end
	m.flags = 0
	if now >= (a.blinkAt or now + 1) and math.random() < 0.3 then
		teleport(m)
	end
	if not a.blinkAt or now >= a.blinkAt then
		a.blinkAt = now + 20 + math.random() * 30
	end
	wander(m, now, 0.5)
end

-- Called by MobService every tick (dt seconds).
function MobAI.think(m: any, _dt: number, targets: { any })
	local now = os.clock()
	m.wantX, m.wantZ = 0, 0
	local b = m.def.behavior
	if b == "wander" then
		passive(m, now)
	elseif b == "melee" then
		melee(m, now, targets)
	elseif b == "ranged" then
		ranged(m, now, targets)
	elseif b == "exploder" then
		exploder(m, now, targets)
	elseif b == "teleporter" then
		teleporter(m, now, targets)
	end
end

-- Reactions to being hurt.
function MobAI.onHurt(m: any, attacker: Player?)
	local now = os.clock()
	local a = m.ai
	if m.def.category == "passive" then
		a.panicUntil = now + 5
		a.panicFrom = Vector3.new(m.x - m.vx * 0.1, m.y, m.z - m.vz * 0.1)
		a.path = nil
	elseif attacker then
		a.angryUntil = now + 30
		a.angryAt = attacker
	end
	if m.def.behavior == "teleporter" and m.alive and math.random() < 0.5 then
		teleport(m)
	end
end

-- A player broke a block: shiftlings within 4 blocks guard their ground and turn hostile.
function MobAI.blockBroken(player: Player, x: number, y: number, z: number)
	local now = os.clock()
	for _, m in S.mobs do
		if m.def.behavior == "teleporter" then
			local dx, dy, dz = m.x - (x + 0.5), m.y - y, m.z - (z + 0.5)
			if dx * dx + dy * dy + dz * dz <= 16 then
				m.ai.angryUntil = now + 30
				m.ai.angryAt = player
			end
		end
	end
end

return MobAI
