--!strict
-- Frost Walker (Phase 10d, Java FrostWalkerEnchantment / FrostedIceBlock).
--
--   freezing  when a player wearing Frost Walker boots stands on the ground and moves to a new
--             block, every water source at the height of the block under the feet, with air
--             above it and within min(2 + level, 16) blocks, turns into frosted ice (age 0)
--   melting   frosted ice is checked every 3 to 6 s (then every 1 to 2 s); it ages (0..3) when
--             a 1 in 3 roll hits or it has fewer than 4 frosted ice neighbours, AND the light
--             there is above 11 - age - 1 (day light melts it, the night keeps it); at age 3 it
--             turns back into water and makes its frosted neighbours age too
-- Random ticks run the same check, so ice left over after a server restart still melts.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Fluids = require(Shared.World.Fluids)
local Enchantments = require(Shared.Items.Enchantments)
local SkyLight = require(Shared.World.SkyLight)
local WorldService = require(script.Parent.Parent.World.WorldService)
local BlockUpdates = require(script.Parent.Parent.World.BlockUpdates)
local RandomTicks = require(script.Parent.Parent.World.RandomTicks)
local InventoryService = require(script.Parent.Parent.Player.InventoryService)
local SurvivalService = require(script.Parent.Parent.Survival.SurvivalService)
local DayNightService = require(script.Parent.Parent.Survival.DayNightService)

local BS = Config.BLOCK_SIZE
local FrostWalkerService = {}
FrostWalkerService.stats = { frozen = 0, melted = 0 }

local FROSTED: { number } = {}
local AGE: { [number]: number } = {}
for age = 0, 3 do
	local id = BlockRegistry.id(if age == 0 then "frosted_ice" else `frosted_ice_{age}`)
	FROSTED[age] = id
	AGE[id] = age
end
local WATER = Fluids.id("water", 0)
local lastBlock: { [Player]: Vector3 } = {}

function FrostWalkerService.isFrosted(id: number?): boolean
	return id ~= nil and AGE[id] ~= nil
end

-- Freeze the water around feet position `feet` (block units) for Frost Walker `level`.
function FrostWalkerService.freeze(feet: Vector3, level: number): number
	local r = math.min(2 + level, 16)
	local y = math.floor(feet.Y + 1e-3) - 1
	local fx, fz = math.floor(feet.X), math.floor(feet.Z)
	local n = 0
	for dx = -r, r do
		for dz = -r, r do
			local x, z = fx + dx, fz + dz
			-- Java closerToCenterThan: the block's centre within r of the feet
			local cx, cy, cz = x + 0.5 - feet.X, y + 0.5 - feet.Y, z + 0.5 - feet.Z
			if cx * cx + cy * cy + cz * cz <= r * r then
				if WorldService.getBlockIfLoaded(x, y, z) == WATER and WorldService.getBlockIfLoaded(x, y + 1, z) == 0 then
					BlockUpdates.set(x, y, z, FROSTED[0])
					BlockUpdates.schedule(x, y, z, math.random(60, 119), "frosted_ice")
					n += 1
				end
			end
		end
	end
	FrostWalkerService.stats.frozen += n
	return n
end

local function skyExposed(x: number, y: number, z: number): boolean
	for yy = y + 1, Config.WORLD_HEIGHT - 1 do
		local id = WorldService.getBlockIfLoaded(x, yy, z)
		if id == nil then
			return false
		end
		if BlockRegistry.isOpaque[id + 1] then
			return false
		end
	end
	return true
end

local DIRS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

local function frostedNeighbours(x: number, y: number, z: number, limit: number): number
	local n = 0
	for _, d in DIRS do
		if AGE[WorldService.getBlockIfLoaded(x + d[1], y + d[2], z + d[3]) or 0] then
			n += 1
			if n >= limit then
				break
			end
		end
	end
	return n
end

-- One step of melting (FrostedIceBlock.slightlyMelt): age up, or turn into water at age 3.
local function slightlyMelt(x: number, y: number, z: number): boolean
	local age = AGE[WorldService.getBlockIfLoaded(x, y, z) or 0]
	if not age then
		return false
	end
	if age < 3 then
		BlockUpdates.set(x, y, z, FROSTED[age + 1])
		return false
	end
	BlockUpdates.set(x, y, z, WATER)
	FrostWalkerService.stats.melted += 1
	return true
end

-- FrostedIceBlock.tick
function FrostWalkerService.tick(x: number, y: number, z: number)
	local id = WorldService.getBlockIfLoaded(x, y, z)
	local age = id and AGE[id]
	if not age then
		return
	end
	local sky = if skyExposed(x, y, z) then 15 - SkyLight.skyDarken(DayNightService.timeOfDay()) else 0
	local light = math.max(sky, WorldService.blockLightAt(x, y, z))
	local roll = math.random(0, 2) == 0 or frostedNeighbours(x, y, z, 4) < 4
	if roll and light > 11 - age - 1 then
		if slightlyMelt(x, y, z) then
			for _, d in DIRS do
				local nx, ny, nz = x + d[1], y + d[2], z + d[3]
				if AGE[WorldService.getBlockIfLoaded(nx, ny, nz) or 0] then
					slightlyMelt(nx, ny, nz)
				end
			end
			return
		end
	end
	BlockUpdates.schedule(x, y, z, math.random(20, 40), "frosted_ice")
end

local function step()
	for _, p in Players:GetPlayers() do
		local c = p.Character
		local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		local h = c and c:FindFirstChildOfClass("Humanoid")
		if not root or not h or h.Health <= 0 or SurvivalService.isSpectator(p) then
			lastBlock[p] = nil
			continue
		end
		local boots = InventoryService.armor(p)[4]
		local level = Enchantments.level(boots, "frost_walker")
		local feet = root.Position / BS - Vector3.new(0, 1, 0)
		local cell = Vector3.new(math.floor(feet.X), math.floor(feet.Y + 1e-3), math.floor(feet.Z))
		local _, grounded = SurvivalService.movement(p)
		if level > 0 and grounded and lastBlock[p] ~= cell then
			FrostWalkerService.freeze(feet, level)
		end
		lastBlock[p] = if grounded then cell else nil
	end
end
FrostWalkerService.step = step

-- Does this player's boots carry Frost Walker? (campfires don't burn them, Java)
function FrostWalkerService.protects(p: Player): boolean
	return Enchantments.level(InventoryService.armor(p)[4], "frost_walker") > 0
end

function FrostWalkerService.init()
	BlockUpdates.register("frosted_ice", FrostWalkerService.tick)
	RandomTicks.register({ FROSTED[0], FROSTED[1], FROSTED[2], FROSTED[3] }, function(x, y, z)
		FrostWalkerService.tick(x, y, z)
	end)
	BlockUpdates.onTick(step)
	Players.PlayerRemoving:Connect(function(p)
		lastBlock[p] = nil
	end)
end

return FrostWalkerService
