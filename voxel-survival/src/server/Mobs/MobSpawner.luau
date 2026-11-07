--!strict
-- Natural spawning and despawning (classic rules, adapted):
--   * hostiles: one attempt per player per second, 24..48 blocks away, in a group of the chosen
--     kind's size. A spot needs an opaque floor, free space for the mob's height (no liquid) and
--     darkness: under open sky only at night; anywhere without sky above (caves) at any time.
--     There is no block-light (torch) engine yet, so lit caves don't exist; that comes with torches.
--   * passive animals: an attempt every 6 s per player, on grass under open sky during the day.
--   * caps per player area and in total (Config.MOB_CAP_*).
--   * despawn: hostiles and animals with no player within Config.MOB_DESPAWN_DISTANCE vanish;
--     hostiles more than 32 blocks from every player also have a 1-in-40-per-second chance.
--     (Classic animals persist forever; here they're removed when far away so the server stays
--     light; phase 6 can persist them with their chunk.)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local MobDefs = require(Shared.Mobs.MobDefs)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Pathfinder = require(Shared.Mobs.Pathfinder)

local H = Config.WORLD_HEIGHT
local isOpaque = BlockRegistry.isOpaque
local isLiquid = BlockRegistry.isLiquid
local GRASS = { [BlockRegistry.id("grass_block")] = true, [BlockRegistry.id("snowy_grass_block")] = true }

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

-- Highest feet position on the column (first non-opaque cell above an opaque block), or nil if
-- the column isn't loaded.
local function surfaceY(x: number, z: number): number?
	for y = H - 1, 1, -1 do
		local id = S.blockAt(x, y, z)
		if id == nil then
			return nil
		end
		if isOpaque[id + 1] then
			return y + 1
		end
	end
	return nil
end

local function spotOk(def: MobDefs.MobDef, x: number, y: number, z: number): boolean
	local h = math.ceil(def.height - 0.05)
	local floor = S.blockAt(x, y - 1, z)
	if not floor or not isOpaque[floor + 1] then
		return false
	end
	if not Pathfinder.walkable(S.solid, x, y, z, h) then
		return false
	end
	for dy = 0, h - 1 do
		local id = S.blockAt(x, y + dy, z)
		if not id or isLiquid[id + 1] then
			return false
		end
	end
	local sky = S.skyExposed(x, y, z)
	if def.category == "passive" then
		return sky and GRASS[floor] == true and S.isDay()
	end
	return (not sky) or not S.isDay()
end

local function farFromPlayers(targets: { any }, pos: Vector3): boolean
	for _, t in targets do
		if (t.feet - pos).Magnitude < Config.MOB_SPAWN_MIN_DISTANCE then
			return false
		end
	end
	return true
end

local function trySpawn(category: string, t: any, targets: { any })
	local cap = if category == "hostile" then Config.MOB_CAP_HOSTILE_PER_PLAYER else Config.MOB_CAP_PASSIVE_PER_PLAYER
	if S.count(category, t.feet, Config.MOB_DESPAWN_DISTANCE) >= cap then
		return
	end
	if S.count("hostile") + S.count("passive") >= Config.MOB_CAP_TOTAL then
		return
	end
	local def = pickWeighted(byCategory[category])
	local angle = math.random() * math.pi * 2
	local dist = Config.MOB_SPAWN_MIN_DISTANCE + math.random() * (Config.MOB_SPAWN_MAX_DISTANCE - Config.MOB_SPAWN_MIN_DISTANCE)
	local bx = math.floor(t.feet.X + math.cos(angle) * dist)
	local bz = math.floor(t.feet.Z + math.sin(angle) * dist)
	local top = surfaceY(bx, bz)
	if not top then
		return
	end
	-- candidate feet heights: the surface, and (hostiles) a random cave spot below it
	local y: number? = nil
	if category == "hostile" and math.random() < 0.6 and top > 8 then
		local start = math.random(5, math.max(6, top - 3))
		for yy = start, math.max(2, start - 16), -1 do
			if spotOk(def, bx, yy, bz) then
				y = yy
				break
			end
		end
	end
	if not y and spotOk(def, bx, top, bz) then
		y = top
	end
	if not y or not farFromPlayers(targets, Vector3.new(bx, y, bz)) then
		return
	end
	local n = math.random(def.groupMin, def.groupMax)
	local spawned = 0
	for i = 1, n * 3 do
		if spawned >= n then
			break
		end
		local ox, oz = if i == 1 then 0 else math.random(-2, 2), if i == 1 then 0 else math.random(-2, 2)
		for dy = 1, -1, -1 do
			local yy = (y :: number) + dy
			if spotOk(def, bx + ox, yy, bz + oz) then
				S.spawn(def.key, bx + ox + 0.5, yy, bz + oz + 0.5)
				spawned += 1
				break
			end
		end
	end
end

local hostileAcc, passiveAcc, despawnAcc = 0, 0, 0

function MobSpawner.step(dt: number, targets: { any })
	hostileAcc += dt
	passiveAcc += dt
	despawnAcc += dt
	if #targets == 0 then
		return
	end
	if hostileAcc >= 1 then
		hostileAcc = 0
		for _, t in targets do
			trySpawn("hostile", t, targets)
		end
	end
	if passiveAcc >= 6 then
		passiveAcc = 0
		for _, t in targets do
			trySpawn("passive", t, targets)
		end
	end
	if despawnAcc >= 1 then
		despawnAcc = 0
		for _, m in S.mobs do
			if m.def.category ~= "projectile" then
				local nearest = math.huge
				for _, t in targets do
					nearest = math.min(nearest, (t.feet - Vector3.new(m.x, m.y, m.z)).Magnitude)
				end
				if nearest > Config.MOB_DESPAWN_DISTANCE
					or (m.def.category == "hostile" and nearest > 32 and math.random() < 1 / 40)
				then
					S.remove(m)
					S.stats.despawned += 1
				end
			end
		end
	end
end

function MobSpawner.init(service: any)
	S = service
end

-- Debug: spawn a mob in front of a target (Studio key L).
local debugOrder = { "zombie", "skeleton", "spider", "cinderhusk", "shiftling", "cow", "pig", "sheep", "chicken" }
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
			S.spawn(key, x + 0.5, y, z + 0.5)
			return key
		end
	end
	return nil
end

return MobSpawner
