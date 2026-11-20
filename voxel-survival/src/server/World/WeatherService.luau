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
local Players = game:GetService("Players")

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
	-- the timers (ticks) for F3 / "/weather query": how long until each flag flips
	ReplicatedStorage:SetAttribute("WeatherRainTime", state.rainTime)
	ReplicatedStorage:SetAttribute("WeatherThunderTime", state.thunderTime)
	ReplicatedStorage:SetAttribute("WeatherClearTime", state.clearTime)
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

-- Weather commands (Studio keys, "/weather"): "clear" | "rain" | "thunder".
function WeatherService.set(kind: string, ticks: number?)
	local d = ticks
	if not d then
		local range = if kind == "clear" then Weather.RAIN_DELAY elseif kind == "rain" then Weather.RAIN_DURATION else Weather.THUNDER_DURATION
		d = rand(range[1], range[2])
	end
	Weather.set(state, kind, d :: number)
	publish()
end

-- What the weather is now: "clear" | "rain" | "thunder".
function WeatherService.current(): string
	return if state.raining and state.thundering then "thunder" elseif state.raining then "rain" else "clear"
end

local function timeText(ticks: number): string
	local s = math.floor(ticks / 20)
	return if s >= 3600 then string.format("%d:%02d:%02d", s // 3600, (s // 60) % 60, s % 60) else string.format("%d:%02d", s // 60, s % 60)
end

-- Lightning at a random spot 4-6 blocks from a player (testing; like /summon lightning_bolt, it
-- strikes whatever the weather). Returns false if there's no ground there.
function WeatherService.strikeNear(p: Player): boolean
	local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return false
	end
	local a = rng:NextNumber(0, math.pi * 2)
	local d = rng:NextNumber(4, 6)
	local x = math.floor(root.Position.X / Config.BLOCK_SIZE + math.cos(a) * d)
	local z = math.floor(root.Position.Z / Config.BLOCK_SIZE + math.sin(a) * d)
	local top = WeatherService.topAt(x, z)
	if not top then
		return false
	end
	WeatherService.strike(x, top + 1, z)
	return true
end

-- Who may change the weather: anyone in Studio, else the world's owner.
local function allowed(p: Player): boolean
	return RunService:IsStudio() or ReplicatedStorage:GetAttribute("WorldOwner") == p.UserId
end

local function reply(p: Player, text: string)
	print(`[Weather] {p.Name}: {text}`)
	Remotes.get("Weather"):FireClient(p, { type = "message", text = text })
end

-- "/weather clear|rain|thunder [seconds]" (Java's /weather; without seconds Java's random
-- length), "/weather query", "/weather snow on|off", "/weather strike", and "cycle" (key Y).
function WeatherService.command(p: Player, args: { string })
	if not allowed(p) then
		reply(p, "Only the world's owner can change the weather")
		return
	end
	local verb = args[1] or "query"
	if verb == "cycle" then
		local nowKind = WeatherService.current()
		verb = if nowKind == "clear" then "rain" elseif nowKind == "rain" then "thunder" else "clear"
	end
	if verb == "clear" or verb == "rain" or verb == "thunder" then
		local secs = tonumber(args[2] or "")
		local ticks = if secs and secs > 0 then math.floor(math.min(secs, 1000000) * 20) else nil
		WeatherService.set(verb, ticks)
		local d = if verb == "clear" then state.clearTime else state.rainTime
		reply(p, `Weather set to {if verb == "thunder" then "thunderstorm" else verb} for {timeText(d)}`)
	elseif verb == "query" then
		reply(p, `Weather: {WeatherService.current()}`)
	elseif verb == "strike" then
		reply(p, if WeatherService.strikeNear(p) then "Lightning strike near you" else "No ground there for lightning")
	else
		reply(p, "Usage: /weather clear|rain|thunder [seconds], /weather query, /weather strike")
	end
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

local timerTicks = 0

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
	timerTicks += 1
	if timerTicks >= 20 then
		timerTicks = 0
		publish() -- (the timers on F3 count down once a second)
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

	-- Commands: Studio keys (DebugAction) and "/weather ..." from the world owner (or anyone in
	-- Studio) via the WeatherCommand remote or the old chat. Every command answers with a message.
	Remotes.get("DebugAction").OnServerEvent:Connect(function(p: Player, a: any)
		if not RunService:IsStudio() or typeof(a) ~= "table" then
			return
		end
		if a.type == "weather" then
			WeatherService.command(p, { "cycle" })
		elseif a.type == "lightning" then
			WeatherService.command(p, { "strike" })
		end
	end)
	Remotes.get("WeatherCommand").OnServerEvent:Connect(function(p: Player, args: any)
		if typeof(args) ~= "table" or #args > 4 then
			return
		end
		local clean = {}
		for _, a in args do
			if typeof(a) ~= "string" or #a > 16 then
				return
			end
			table.insert(clean, string.lower(a))
		end
		WeatherService.command(p, clean)
	end)
	local function chatted(p: Player)
		p.Chatted:Connect(function(msg: string)
			local words = string.split(string.lower(msg), " ")
			if words[1] == "/weather" then
				table.remove(words, 1)
				WeatherService.command(p, words)
			end
		end)
	end
	for _, p in Players:GetPlayers() do
		chatted(p)
	end
	Players.PlayerAdded:Connect(chatted)

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
