--!strict
-- Authoritative world state on the server.
--
--   * Generates chunks around every player (radius Config.SERVER_CHUNK_RADIUS) using the
--     time-sliced scheduler, so the server can validate interaction and run mobs later.
--   * Owns the per-chunk diff tables (edits relative to the seed). Diffs live in `diffs`,
--     separately from block data, so unloading a chunk never loses edits.
--   * Publishes the seed and spawn point as ReplicatedStorage attributes for clients.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local ChunkData = require(Shared.World.ChunkData)
local TerrainGen = require(Shared.World.TerrainGen)
local Scheduler = require(Shared.Util.Scheduler)

local CS = Config.CHUNK_SIZE
local BS = Config.BLOCK_SIZE

local WorldService = {}

local gen: TerrainGen.Generator
local seed: number
local chunks: { [number]: ChunkData.Chunk } = {}
local diffs: { [number]: { [number]: number } } = {} -- chunkKey -> (blockIndex -> id)
local wanted: { [number]: boolean } = {}
local spawnBlock = Vector3.zero
local scheduler: Scheduler.Scheduler

WorldService.stats = { generated = 0, genTime = 0, loaded = 0 }

local function generateNow(key: number): ChunkData.Chunk
	local cx, cz = ChunkData.unkey(key)
	local chunk = ChunkData.new(cx, cz)
	local t = os.clock()
	TerrainGen.generate(gen, chunk, Scheduler.checkpoint)
	local d = diffs[key]
	if d then
		for idx, id in d do
			buffer.writeu8(chunk.blocks, idx, id)
		end
		chunk.diffs = d
	end
	WorldService.stats.generated += 1
	WorldService.stats.genTime += os.clock() - t
	return chunk
end

-- Picker for the scheduler: generate the next wanted chunk that is missing.
local generating: { [number]: boolean } = {}
local function pickJob(): (() -> ())?
	for key in wanted do
		if not chunks[key] and not generating[key] then
			generating[key] = true
			return function()
				local chunk = generateNow(key)
				generating[key] = nil
				if wanted[key] then
					chunks[key] = chunk
				end
			end
		end
	end
	return nil
end

local function refreshWanted()
	table.clear(wanted)
	local r = Config.SERVER_CHUNK_RADIUS
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local pos = if root then root.Position else spawnBlock * BS
		local pcx, pcz = math.floor(pos.X / BS) // CS, math.floor(pos.Z / BS) // CS
		for dz = -r, r do
			for dx = -r, r do
				wanted[ChunkData.key(pcx + dx, pcz + dz)] = true
			end
		end
	end
	-- Unload chunks nobody needs (their diffs stay in `diffs`).
	local loaded = 0
	for key in chunks do
		if not wanted[key] then
			chunks[key] = nil
		else
			loaded += 1
		end
	end
	WorldService.stats.loaded = loaded
end

function WorldService.init(worldSeed: number)
	seed = worldSeed
	gen = TerrainGen.new(seed)
	local sx, sy, sz = TerrainGen.findSpawn(gen)
	spawnBlock = Vector3.new(sx, sy, sz)
	ReplicatedStorage:SetAttribute("WorldSeed", seed)
	ReplicatedStorage:SetAttribute("SpawnBlock", spawnBlock)

	scheduler = Scheduler.new(Config.FRAME_BUDGET_MS_SERVER, pickJob)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.5 then
			acc = 0
			refreshWanted()
		end
		scheduler:step()
	end)
	print(`[WorldService] seed {seed}, spawn block {spawnBlock}`)
end

function WorldService.getSeed(): number
	return seed
end

function WorldService.getSpawnBlock(): Vector3
	return spawnBlock
end

-- Packed diff string for a chunk (empty string if unmodified).
function WorldService.getPackedDiffs(key: number): string
	local d = diffs[key]
	if not d then
		return ""
	end
	return ChunkData.packDiffs(d)
end

-- Loaded chunk or nil. Phase 2 validation uses getChunkSync, which generates on demand.
function WorldService.getChunk(key: number): ChunkData.Chunk?
	return chunks[key]
end

function WorldService.getChunkSync(cx: number, cz: number): ChunkData.Chunk
	local key = ChunkData.key(cx, cz)
	local chunk = chunks[key]
	if not chunk then
		chunk = generateNow(key)
		chunks[key] = chunk
	end
	return chunk
end

return WorldService
