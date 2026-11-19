--!strict
-- Weather on the server (rules: World/Weather). 20 ticks a second:
--   * the Java rain / thunder cycle; the flags and levels go to every client as ReplicatedStorage
--     attributes (WeatherRain, WeatherThunder, WeatherRainLevel, WeatherThunderLevel)
--   * World/SkyLight learns the levels (rain and thunder darken the sky: undead don't burn in a
--     storm, monsters spawn in daylight during thunderstorms)
--   * lightning: during a thunderstorm each chunk near a player has a 1 in 100000 chance per tick;
--     the strike goes to the top of a random column (or a living thing under the sky within 3
--     blocks of it) where rain falls, deals 5 damage and sets on fire everything in Java's
--     6 x 12 x 6 box, lights fires (Normal and Hard) and charges Sneakers
--   * `rainingAt` (Java Level.isRainingAt) for rain effects elsewhere: farmland gets wet, fire goes
--     out, burning players and mobs are put out, voidlings get hurt
-- The weather is saved with the world (Persistence: meta.weather). Sleeping through a rainy
-- night clears it (BedService).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Weather = require(Shared.World.Weather)
local SkyLight = require(Shared.World.SkyLight)
local Biomes = require(Shared.World.Biomes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Remotes = require(Shared.Net.Remotes)
local WorldService = require(script.Parent.WorldService)

local CS = Config.CHUNK_SIZE
local H = Config.WORLD_HEIGHT

local WeatherService = {}
WeatherService.stats = { strikes = 0, attempts = 0 }

local state: Weather.State = Weather.new()
local rng = Random.new()
local function rand(lo: number, hi: number): number
	return rng:NextInteger(lo, hi)
end

-- Hooks the strike uses (set in init so this module doesn't require the gameplay services).
type Hooks = {
	nearChunks: () -> { number },
	hurtPlayers: (lo: Vector3, hi: Vector3) -> (),
	hurtMobs: (lo: Vector3, hi: Vector3) -> (),
	targets: (x: number, z: number, y0: number) -> { Vector3 }, -- living things near a column (block units, feet)
	ignite: (x: number, y: number, z: number) -> boolean,
	difficulty: () -> string,
}
local hooks: Hooks? = nil

function WeatherService.state(): Weather.State
	return state
end

-- Highest block that blocks motion (solid or liquid) per column, cached; a block change in the
-- column forgets it (Java's MOTION_BLOCKING heightmap).
local isSolid = BlockRegistry.isSolid
local isLiquid = BlockRegistry.isLiquid
local tops: { [number]: number } = {}
local function columnKey(x: number, z: number): number
	return (x + 1048576) * 2097152 + (z + 1048576)
end
function WeatherService.topAt(x: number, z: number): number?
	local k = columnKey(x, z)
	local t = tops[k]
	if t then
		return t
	end
	if WorldService.getBlockIfLoaded(x, H - 1, z) == nil then
		return nil
	end
	local y = H - 1
	while y > 0 do
		local id = WorldService.getBlock(x, y, z)
		if id ~= 0 and (isSolid[id + 1] or isLiquid[id + 1]) then
			break
		end
		y -= 1
	end
	tops[k] = y
	return y
end

-- "none" | "rain" | "snow" at a block (its biome and height).
function WeatherService.precipitationAt(x: number, y: number, z: number): string
	local b = WorldService.biomeAt(x, z)
	local biome = b and Biomes.byId[b]
	return Weather.precipitation(if biome then biome.key else "plains", y)
end

-- Java Level.isRainingAt: it's raining, the block is open to the sky (nothing that blocks
-- motion above it) and it rains (not snows) there.
function WeatherService.rainingAt(x: number, y: number, z: number): boolean
	if not Weather.isRaining(state) then
		return false
	end
	local top = WeatherService.topAt(x, z)
	if not top or top >= y then
		return false
	end
	return WeatherService.precipitationAt(x, y, z) == "rain"
end

-- Is anything wet by rain at a body (feet or head block, block units)?
function WeatherService.rainOn(x: number, feetY: number, z: number, height: number): boolean
	local bx, bz = math.floor(x), math.floor(z)
	return WeatherService.rainingAt(bx, math.floor(feetY), bz) or WeatherService.rainingAt(bx, math.floor(feetY + height), bz)
end

local function publish()
	ReplicatedStorage:SetAttribute("WeatherRain", state.raining)
	ReplicatedStorage:SetAttribute("WeatherThunder", state.thundering)
	ReplicatedStorage:SetAttribute("WeatherRainLevel", math.floor(state.rainLevel * 100 + 0.5) / 100)
	ReplicatedStorage:SetAttribute("WeatherThunderLevel", math.floor(state.thunderLevel * 100 + 0.5) / 100)
end

-- A lightning strike at block (x, y, z): the block the bolt hits (above the ground).
function WeatherService.strike(x: number, y: number, z: number)
	local h = hooks
	WeatherService.stats.strikes += 1
	Remotes.get("Weather"):FireAllClients({ type = "lightning", x = x, y = y, z = z })
	if not h then
		return
	end
	-- Java LightningBolt: fire at the strike (Normal / Hard), plus 4 more tries next to it
	local diff = h.difficulty()
	if diff == "normal" or diff == "hard" then
		h.ignite(x, y, z)
		for _ = 1, 4 do
			h.ignite(x + rng:NextInteger(-1, 1), y + rng:NextInteger(-1, 1), z + rng:NextInteger(-1, 1))
		end
	end
	-- everything in the 6 x 12 x 6 box around the north-west corner of the block, from 3 below
	local lo = Vector3.new(x - 3, y - 3, z - 3)
	local hi = Vector3.new(x + 3, y + 9, z + 3)
	h.hurtPlayers(lo, hi)
	h.hurtMobs(lo, hi)
end

-- One chunk's lightning roll (ServerLevel.tickChunk).
local function tryLightning(chunkKey: number)
	if rng:NextInteger(1, Weather.LIGHTNING_CHANCE) ~= 1 then
		return
	end
	WeatherService.stats.attempts += 1
	local cx = chunkKey // 2097152 - 1048576
	local cz = chunkKey % 2097152 - 1048576
	local x, z = cx * CS + rng:NextInteger(0, CS - 1), cz * CS + rng:NextInteger(0, CS - 1)
	local top = WeatherService.topAt(x, z)
	if not top then
		return
	end
	local y = top + 1
	-- Java findLightningTargetAround: a living thing under the sky within 3 blocks takes it
	local h = hooks
	if h then
		local near = h.targets(x, z, y)
		if #near > 0 then
			local t = near[rng:NextInteger(1, #near)]
			x, y, z = math.floor(t.X), math.floor(t.Y), math.floor(t.Z)
		end
	end
	if WeatherService.rainingAt(x, y, z) then
		WeatherService.strike(x, y, z)
	end
end

-- Weather commands (Studio key / future commands): "clear" | "rain" | "thunder".
function WeatherService.set(kind: string, ticks: number?)
	local d = ticks
	if not d then
		local range = if kind == "clear" then Weather.RAIN_DELAY elseif kind == "rain" then Weather.RAIN_DURATION else Weather.THUNDER_DURATION
		d = rand(range[1], range[2])
	end
	Weather.set(state, kind, d :: number)
	publish()
end

-- Sleeping through the night: rain stops (Java 1.18+: only when it is raining).
function WeatherService.onSlept()
	if Weather.isRaining(state) then
		Weather.resetCycle(state)
		publish()
	end
end

function WeatherService.encode(): { number }
	return Weather.encode(state)
end

function WeatherService.load(saved: any)
	state = Weather.decode(saved)
	SkyLight.rainLevel, SkyLight.thunderLevel = state.rainLevel, state.thunderLevel
	publish()
end

-- One game tick (exposed for tests).
function WeatherService.tick()
	local wasRain, wasThunder = state.raining, state.thundering
	local r0, t0 = state.rainLevel, state.thunderLevel
	Weather.tick(state, rand)
	SkyLight.rainLevel, SkyLight.thunderLevel = state.rainLevel, state.thunderLevel
	if state.raining ~= wasRain or state.thundering ~= wasThunder
		or math.floor(r0 * 10) ~= math.floor(state.rainLevel * 10) or math.floor(t0 * 10) ~= math.floor(state.thunderLevel * 10)
		or (state.rainLevel ~= r0 and (state.rainLevel == 0 or state.rainLevel == 1))
	then
		publish()
	end
	local h = hooks
	if h and Weather.isThundering(state) then
		for _, key in h.nearChunks() do
			tryLightning(key)
		end
	end
end

function WeatherService.init(h: Hooks)
	hooks = h
	WorldService.onBlockChanged(function(x, _y, z)
		tops[columnKey(x, z)] = nil
	end)
	WorldService.onChunkUnloaded(function(key)
		-- forget the cached tops of an unloaded chunk (they're rebuilt on demand)
		local cx = key // 2097152 - 1048576
		local cz = key % 2097152 - 1048576
		for lx = 0, CS - 1 do
			for lz = 0, CS - 1 do
				tops[columnKey(cx * CS + lx, cz * CS + lz)] = nil
			end
		end
	end)
	publish()

	-- Studio: the weather key cycles clear -> rain -> thunderstorm
	Remotes.get("DebugAction").OnServerEvent:Connect(function(_p: Player, a: any)
		if RunService:IsStudio() and typeof(a) == "table" and a.type == "weather" then
			local now = if Weather.isThundering(state) or state.thundering then "thunder" elseif state.raining then "rain" else "clear"
			local nextKind = if now == "clear" then "rain" elseif now == "rain" then "thunder" else "clear"
			WeatherService.set(nextKind)
			print(`[Weather] {nextKind}`)
		end
	end)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		local n = 0
		while acc >= 0.05 and n < 10 do
			acc -= 0.05
			n += 1
			WeatherService.tick()
		end
		if n >= 10 then
			acc = 0
		end
	end)
end

return WeatherService
