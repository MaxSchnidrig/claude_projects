--!strict
-- Natural spawning and despawning, Java Edition rules (minecraft.wiki: Mob spawning).
--
-- Hostiles (every tick, under the cap of 70 per player area):
--   * a pack starts at a random block in a loaded chunk around a player, at a random height
--     between the bottom and the surface; the block must have no collision
--   * up to 3 packs of up to 4 tries: each try moves x and z by random(0..5) - random(0..5);
--     a mob spawns if the spot is 24..128 blocks from the nearest player, has a solid floor,
--     room for its height (no liquid) and is dark enough:
--       fail if sky light > random(0..31), then pass if (sky light - sky darkening) <= random(0..7)
--     and no torch light (block light 0; estimated from nearby torches); sky light is 15 under
--     open sky, 0 elsewhere
--   * the kind (weighted: zombie 95, skeleton/spider/sneaker 100, voidling 10) is chosen
--     per pack; a pack stops at the kind's group size
-- Animals:
--   * when a chunk loads for the first time: 10 % chance (repeated while it succeeds) of a group
--     of 4 of one kind (sheep 12, pig 10, chicken 10, cow 8) on grass under open sky
--   * every 20 s (400 ticks) attempts on grass with light > 8, under the cap of 10 per player
--   * they never despawn; when their chunk unloads they are parked and come back with it
-- Despawning (hostiles): instantly beyond 128 blocks from every player; beyond 32 blocks, after
-- 30 s without a player nearby, a 1/800 chance per tick.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local MobDefs = require(Shared.Mobs.MobDefs)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Pathfinder = require(Shared.Mobs.Pathfinder)
local ChunkData = require(Shared.World.ChunkData)
local SkyLight = require(Shared.World.SkyLight)
local WorldService = require(script.Parent.Parent.World.WorldService)

local H = Config.WORLD_HEIGHT
local CS = Config.CHUNK_SIZE
local isSolid = BlockRegistry.isSolid
local Shapes = require(Shared.Blocks.Shapes)
local ICE = BlockRegistry.id("ice")
local isLiquid = BlockRegistry.isLiquid
local GRASS = { [BlockRegistry.id("grass_block")] = true, [BlockRegistry.id("snowy_grass_block")] = true }
local HOSTILE_ATTEMPTS_PER_TICK = 2 -- per player (Java tries once per loaded chunk; caps limit both)
local PASSIVE_ATTEMPTS = 24 -- per player every 20 s

local MobSpawner = {}
local S: any = nil

local byCategory: { [string]: { MobDefs.MobDef } } = { hostile = {}, passive = {} }
for _, d in MobDefs.list do
	if byCategory[d.category] and d.spawnWeight > 0 then
		table.insert(byCategory[d.category], d)
	end
end

local function pickWeighted(list: { MobDefs.MobDef }): MobDefs.MobDef
	local total = 0
	for _, d in list do
		total += d.spawnWeight
	end
	local r = math.random() * total
	for _, d in list do
		r -= d.spawnWeight
		if r <= 0 then
			return d
		end
	end
	return list[#list]
end

-- Feet height on top of the highest solid block of a column, or nil if not loaded.
local function surfaceY(x: number, z: number): number?
	for y = H - 1, 1, -1 do
		local id = S.blockAt(x, y, z)
		if id == nil then
			return nil
		end
		if isSolid[id + 1] then
			return y + 1
		end
	end
	return nil
end

-- Placement: solid floor, room for the mob, no liquid.
local function placementOk(def: MobDefs.MobDef, x: number, y: number, z: number): boolean
	local floor = S.blockAt(x, y - 1, z)
	if not floor or not isSolid[floor + 1] then
		return false
	end
	-- Java: only on a full top face (not on bottom slabs, stairs' steps, fences, doors...)
	if not Shapes.coversFace(floor, 3) and floor ~= ICE then
		return false
	end
	local h = math.ceil(def.height - 0.05)
	if not Pathfinder.walkable(S.solid, x, y, z, h) then
		return false
	end
	for dy = 0, h - 1 do
		local id = S.blockAt(x, y + dy, z)
		if not id or isLiquid[id + 1] then
			return false
		end
	end
	return true
end

local function hostileRulesOk(x: number, y: number, z: number): boolean
	if WorldService.blockLightAt(x, y, z) > 0 then
		return false -- Java: monsters only spawn at block light 0 (torches keep areas safe)
	end
	local sky = S.skyExposed(x, y, z)
	return SkyLight.monsterCanSpawn(sky, S.timeOfDay(), math.random(0, 31), math.random(0, 7))
end

local function animalRulesOk(x: number, y: number, z: number): boolean
	local floor = S.blockAt(x, y - 1, z)
	-- Java: grass below and raw light > 8 (sky light is not darkened at night for this check)
	return floor ~= nil and GRASS[floor] == true and S.skyExposed(x, y, z)
end

local function nearestPlayer(targets: { any }, pos: Vector3): number
	local best = math.huge
	for _, t in targets do
		best = math.min(best, (t.feet - pos).Magnitude)
	end
	return best
end

-- Java NaturalSpawner.spawnCategoryForPosition.
local function spawnPacks(category: string, x0: number, y: number, z0: number, targets: { any })
	local start = S.blockAt(x0, y, z0)
	if start == nil or isSolid[start + 1] then
		return
	end
	for _ = 1, 3 do
		local x, z = x0, z0
		local def: MobDefs.MobDef? = nil
		local count = 0
		for _ = 1, 4 do
			x += math.random(0, 5) - math.random(0, 5)
			z += math.random(0, 5) - math.random(0, 5)
			local pos = Vector3.new(x + 0.5, y, z + 0.5)
			local d = nearestPlayer(targets, pos)
			if d < Config.MOB_SPAWN_MIN_DISTANCE or d > Config.MOB_SPAWN_MAX_DISTANCE then
				continue
			end
			def = def or pickWeighted(byCategory[category])
			local kind = def :: MobDefs.MobDef
			if not placementOk(kind, x, y, z) then
				continue
			end
			local rulesOk = if category == "hostile" then hostileRulesOk(x, y, z) else animalRulesOk(x, y, z)
			if not rulesOk then
				continue
			end
			S.spawn(kind.key, x + 0.5, y, z + 0.5)
			count += 1
			if count >= kind.groupMax then
				break
			end
		end
	end
end

local function randomColumnNear(t: any): (number, number)
	local r = Config.SERVER_CHUNK_RADIUS
	local pcx, pcz = math.floor(t.feet.X) // CS, math.floor(t.feet.Z) // CS
	local cx, cz = pcx + math.random(-r, r), pcz + math.random(-r, r)
	return cx * CS + math.random(0, CS - 1), cz * CS + math.random(0, CS - 1)
end

local function tryHostile(t: any, targets: { any })
	if S.count("hostile", t.feet, Config.MOB_SPAWN_MAX_DISTANCE) >= Config.MOB_CAP_HOSTILE_PER_PLAYER then
		return
	end
	local x, z = randomColumnNear(t)
	local top = surfaceY(x, z)
	if not top then
		return
	end
	spawnPacks("hostile", x, math.random(1, top), z, targets)
end

local function tryPassive(t: any, targets: { any })
	if S.count("passive", t.feet, Config.MOB_SPAWN_MAX_DISTANCE) >= Config.MOB_CAP_PASSIVE_PER_PLAYER then
		return
	end
	local x, z = randomColumnNear(t)
	local top = surfaceY(x, z)
	if top then
		spawnPacks("passive", x, top, z, targets)
	end
end

-- Java spawnMobsForChunkGeneration: animals come with new terrain.
local function populateChunk(key: number)
	local cx, cz = ChunkData.unkey(key)
	while math.random() < 0.1 do
		local def = pickWeighted(byCategory.passive)
		local x = cx * CS + math.random(0, CS - 1)
		local z = cz * CS + math.random(0, CS - 1)
		local count = 0
		for _ = 1, def.groupMax do
			for _ = 1, 4 do
				local top = surfaceY(x, z)
				if top and placementOk(def, x, top, z) and animalRulesOk(x, top, z) then
					S.spawn(def.key, x + 0.5, top, z + 0.5)
					count += 1
					break
				end
				x = math.clamp(x + math.random(0, 4) - math.random(0, 4), cx * CS, cx * CS + CS - 1)
				z = math.clamp(z + math.random(0, 4) - math.random(0, 4), cz * CS, cz * CS + CS - 1)
			end
		end
	end
end

-- Animals in unloaded chunks are parked here and restored when the chunk loads again.
type Parked = { key: string, x: number, y: number, z: number, yaw: number, health: number }
local parked: { [number]: { Parked } } = {}

local function chunkKeyOf(m: any): number
	return ChunkData.key(math.floor(m.x) // CS, math.floor(m.z) // CS)
end

local function onUnloaded(key: number)
	for _, m in S.mobs do
		if chunkKeyOf(m) == key then
			if m.persistent then
				local list = parked[key] or {}
				parked[key] = list
				table.insert(list, { key = m.def.key, x = m.x, y = m.y, z = m.z, yaw = m.yaw, health = m.health })
			else
				S.stats.despawned += 1
			end
			S.remove(m)
		end
	end
end

local function onLoaded(key: number, firstTime: boolean)
	local list = parked[key]
	if list then
		parked[key] = nil
		for _, p in list do
			local m = S.spawn(p.key, p.x, p.y, p.z, p.yaw)
			if m then
				m.health = p.health
			end
		end
	end
	if firstTime then
		populateChunk(key)
	end
end

local passiveAcc = 0

function MobSpawner.step(dt: number, targets: { any })
	passiveAcc += dt
	if #targets == 0 then
		return
	end
	local ticks = math.max(1, math.floor(dt * 20 + 0.5))
	for _, t in targets do
		for _ = 1, HOSTILE_ATTEMPTS_PER_TICK * ticks do
			tryHostile(t, targets)
		end
	end
	if passiveAcc >= 20 then
		passiveAcc = 0
		for _, t in targets do
			for _ = 1, PASSIVE_ATTEMPTS do
				tryPassive(t, targets)
			end
		end
	end
	-- despawning (hostiles only; animals are persistent)
	local now = os.clock()
	local chance = 1 - (1 - 1 / 800) ^ ticks
	for _, m in S.mobs do
		if m.persistent or m.def.category ~= "hostile" then
			continue
		end
		local d = nearestPlayer(targets, Vector3.new(m.x, m.y, m.z))
		if d > Config.MOB_DESPAWN_DISTANCE then
			S.remove(m)
			S.stats.despawned += 1
		elseif d > Config.MOB_DESPAWN_RANDOM_DISTANCE then
			m.farSince = m.farSince or now
			if now - (m.farSince :: number) > 30 and math.random() < chance then
				S.remove(m)
				S.stats.despawned += 1
			end
		else
			m.farSince = nil
		end
	end
end

function MobSpawner.init(service: any)
	S = service
	WorldService.onChunkLoaded(onLoaded)
	WorldService.onChunkUnloaded(onUnloaded)
end

-- Debug: spawn a mob in front of a target (Studio key L).
local debugOrder = { "zombie", "skeleton", "spider", "sneaker", "voidling", "cow", "pig", "sheep", "chicken" }
local debugIndex = 0
function MobSpawner.debugSpawn(t: any)
	debugIndex = debugIndex % #debugOrder + 1
	local key = debugOrder[debugIndex]
	local look = t.root.CFrame.LookVector
	local x = math.floor(t.feet.X + look.X * 4)
	local z = math.floor(t.feet.Z + look.Z * 4)
	for y = math.floor(t.feet.Y) + 4, math.floor(t.feet.Y) - 6, -1 do
		local def = MobDefs.byKey[key]
		if Pathfinder.walkable(S.solid, x, y, z, math.ceil(def.height - 0.05)) then
			local m = S.spawn(key, x + 0.5, y, z + 0.5)
			if m then
				m.persistent = true -- debug mobs stay around for testing
			end
			return key
		end
	end
	return nil
end

return MobSpawner
