--!strict
-- Java random ticks: every game tick, in every 16 x 16 x 16 section of the chunks near players,
-- Config.RANDOM_TICK_SPEED (3) random blocks get a "random tick" if their block type wants one
-- (crops grow, farmland dries, grass spreads). Chunks further than Config.RANDOM_TICK_RADIUS
-- from every player don't tick (Java: outside the simulation distance).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local ChunkData = require(Shared.World.ChunkData)
local Remotes = require(Shared.Net.Remotes)
local WorldService = require(script.Parent.WorldService)
local BlockUpdates = require(script.Parent.BlockUpdates)

local CS = Config.CHUNK_SIZE
local SECTIONS = Config.WORLD_HEIGHT // 16
local BS = Config.BLOCK_SIZE

local RandomTicks = {}
RandomTicks.stats = { chunks = 0, picks = 0, ticked = 0 }

local handlers: { [number]: (x: number, y: number, z: number, id: number) -> () } = {}
local rng = Random.new()

-- fn(x, y, z, id) runs when a block with one of `ids` gets a random tick.
function RandomTicks.register(ids: { number }, fn: (x: number, y: number, z: number, id: number) -> ())
	for _, id in ids do
		handlers[id] = fn
	end
end

-- Chunk keys within the radius of any player (each once).
local function nearChunks(): { number }
	local seen: { [number]: boolean } = {}
	local list = {}
	local r = Config.RANDOM_TICK_RADIUS
	for _, p in Players:GetPlayers() do
		local c = p.Character
		local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local cx, cz = math.floor(root.Position.X / BS) // CS, math.floor(root.Position.Z / BS) // CS
			for dz = -r, r do
				for dx = -r, r do
					local key = ChunkData.key(cx + dx, cz + dz)
					if not seen[key] then
						seen[key] = true
						table.insert(list, key)
					end
				end
			end
		end
	end
	return list
end

function RandomTicks.step()
	local picks = RandomTicks.speed
	if picks <= 0 then
		return
	end
	local chunks = nearChunks()
	local ticked = 0
	for _, key in chunks do
		local chunk = WorldService.getChunk(key)
		if chunk then
			local cx, cz = ChunkData.unkey(key)
			for sy = 0, SECTIONS - 1 do
				for _ = 1, picks do
					local lx, ly, lz = rng:NextInteger(0, 15), sy * 16 + rng:NextInteger(0, 15), rng:NextInteger(0, 15)
					local id = ChunkData.get(chunk, lx, ly, lz)
					local h = handlers[id]
					if h then
						ticked += 1
						h(cx * CS + lx, ly, cz * CS + lz, id)
					end
				end
			end
		end
	end
	RandomTicks.stats.chunks = #chunks
	RandomTicks.stats.picks += #chunks * SECTIONS * picks
	RandomTicks.stats.ticked += ticked
end

-- Studio test aid (key H): random ticks x10, like Java's /gamerule randomTickSpeed 30.
RandomTicks.speed = Config.RANDOM_TICK_SPEED

function RandomTicks.init()
	BlockUpdates.onTick(RandomTicks.step)
	Remotes.get("DebugAction").OnServerEvent:Connect(function(_p: Player, a: any)
		if RunService:IsStudio() and typeof(a) == "table" and a.type == "fastTicks" then
			RandomTicks.speed = if RandomTicks.speed == Config.RANDOM_TICK_SPEED then Config.RANDOM_TICK_SPEED * 10 else Config.RANDOM_TICK_SPEED
			ReplicatedStorage:SetAttribute("RandomTickSpeed", RandomTicks.speed)
			print(`[RandomTicks] random tick speed {RandomTicks.speed}`)
		end
	end)
end

return RandomTicks
