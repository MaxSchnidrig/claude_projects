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
local TorchRules = require(Shared.Blocks.TorchRules)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)

local CS = Config.CHUNK_SIZE
local BS = Config.BLOCK_SIZE

local WorldService = {}

local gen: TerrainGen.Generator
local seed: number
local chunks: { [number]: ChunkData.Chunk } = {}
local diffs: { [number]: { [number]: number } } = {} -- chunkKey -> (blockIndex -> id)
local wanted: { [number]: boolean } = {}
local wantedOrder: { number } = {} -- wanted keys, nearest to a player first
local populated: { [number]: boolean } = {} -- chunks that already had their first load (animals)
local loadedListeners: { (key: number, firstTime: boolean) -> () } = {}
local blockSetListeners: { (chunkKey: number) -> () } = {}
-- Light sources placed by players (torches), per chunk: block index -> light level. The server has
-- no light engine; hostile spawning checks an estimate from these (see blockLightAt).
local sources: { [number]: { [number]: number } } = {}

local function noteSource(key: number, idx: number, id: number)
	local level = BlockRegistry.lightEmission[id + 1]
	local list = sources[key]
	if level > 0 and TorchRules.isTorch(id) then
		if not list then
			list = {}
			sources[key] = list
		end
		(list :: { [number]: number })[idx] = level
	elseif list then
		list[idx] = nil
	end
end
-- Saved-data gate (Persistence): a chunk may only be generated once its saved edits are loaded.
local gate: { ready: (number) -> boolean, request: (number) -> (), ensure: (number) -> () }? = nil
local unloadedListeners: { (key: number) -> () } = {}
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
local function stored(key: number, chunk: ChunkData.Chunk)
	chunks[key] = chunk
	local first = not populated[key]
	populated[key] = true
	for _, fn in loadedListeners do
		task.spawn(fn, key, first)
	end
end

local function pickJob(): (() -> ())?
	for _, key in wantedOrder do
		if not chunks[key] and not generating[key] then
			local g = gate
			if g and not g.ready(key) then
				g.request(key) -- loads in the background; picked up on a later frame
				continue
			end
			generating[key] = true
			return function()
				local chunk = generateNow(key)
				generating[key] = nil
				if wanted[key] and not chunks[key] then
					stored(key, chunk)
				end
			end
		end
	end
	return nil
end

local function refreshWanted()
	table.clear(wanted)
	local r = Config.SERVER_CHUNK_RADIUS
	local dist: { [number]: number } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local own = player:GetAttribute("SpawnBlock")
		local pos = if root then root.Position elseif typeof(own) == "Vector3" then own * BS else spawnBlock * BS
		local pcx, pcz = math.floor(pos.X / BS) // CS, math.floor(pos.Z / BS) // CS
		for dz = -r, r do
			for dx = -r, r do
				local key = ChunkData.key(pcx + dx, pcz + dz)
				wanted[key] = true
				local d = dx * dx + dz * dz
				if not dist[key] or d < dist[key] then
					dist[key] = d
				end
			end
		end
	end
	table.clear(wantedOrder)
	for key in wanted do
		table.insert(wantedOrder, key)
	end
	table.sort(wantedOrder, function(a, b)
		return dist[a] < dist[b]
	end)
	-- Unload chunks nobody needs (their diffs stay in `diffs`).
	local loaded = 0
	for key in chunks do
		if not wanted[key] then
			chunks[key] = nil
			for _, fn in unloadedListeners do
				fn(key)
			end
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
	if gate then
		gate.ensure(key) -- yields until the chunk's saved edits are loaded
	end
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
		if gate then
			gate.ensure(key)
			chunk = chunks[key]
			if chunk then
				return chunk
			end
		end
		chunk = generateNow(key)
		stored(key, chunk)
	end
	return chunk
end

-- Persistence hooks ---------------------------------------------------------------------------

function WorldService.setGate(g: { ready: (number) -> boolean, request: (number) -> (), ensure: (number) -> () })
	gate = g
end

-- Saved edits for a chunk, installed before the chunk is generated.
function WorldService.installDiffs(key: number, d: { [number]: number })
	local mine = diffs[key]
	if not mine then
		mine = {}
		diffs[key] = mine
	end
	for idx, id in d do
		if mine[idx] == nil then -- edits made this session win
			mine[idx] = id
			noteSource(key, idx, id)
		end
	end
	local chunk = chunks[key]
	if chunk then
		for idx, id in mine do
			buffer.writeu8(chunk.blocks, idx, id)
		end
		chunk.diffs = mine
	end
end

function WorldService.getDiffs(key: number): { [number]: number }?
	return diffs[key]
end

-- Estimated block light at a block from nearby torches: level - Manhattan distance (walls are
-- ignored, so this errs on the lit side, which only makes spawning rarer next to torches).
function WorldService.blockLightAt(x: number, y: number, z: number): number
	local best = 0
	local cx, cz = x // CS, z // CS
	for dz = -1, 1 do
		for dx = -1, 1 do
			local list = sources[ChunkData.key(cx + dx, cz + dz)]
			if list then
				for idx, level in list do
					local lx, ly, lz = ChunkData.unindex(idx)
					local d = math.abs((cx + dx) * CS + lx - x) + math.abs(ly - y) + math.abs((cz + dz) * CS + lz - z)
					best = math.max(best, level - d)
				end
			end
		end
	end
	return best
end

function WorldService.onBlockSet(fn: (chunkKey: number) -> ())
	table.insert(blockSetListeners, fn)
end

-- Chunk lifecycle hooks (mobs: animals spawn with new chunks and are parked with unloaded ones).
-- `firstTime` is true the first time this server loads the chunk.
function WorldService.onChunkLoaded(fn: (key: number, firstTime: boolean) -> ())
	table.insert(loadedListeners, fn)
end

function WorldService.onChunkUnloaded(fn: (key: number) -> ())
	table.insert(unloadedListeners, fn)
end

function WorldService.isLoaded(key: number): boolean
	return chunks[key] ~= nil
end

-- Block at world block coordinates (generates the chunk if needed). 0 outside the world.
function WorldService.getBlock(wx: number, wy: number, wz: number): number
	if wy < 0 or wy >= Config.WORLD_HEIGHT then
		return 0
	end
	local cx, cz, lx, lz = ChunkData.worldToChunk(wx, wz)
	return ChunkData.get(WorldService.getChunkSync(cx, cz), lx, wy, lz)
end

-- Block if its chunk is already loaded on the server, else nil (never generates). Mobs use this
-- so they never trigger chunk generation by wandering.
function WorldService.getBlockIfLoaded(wx: number, wy: number, wz: number): number?
	if wy < 0 or wy >= Config.WORLD_HEIGHT then
		return 0
	end
	local cx, cz, lx, lz = ChunkData.worldToChunk(wx, wz)
	local chunk = chunks[ChunkData.key(cx, cz)]
	if not chunk then
		return nil
	end
	return ChunkData.get(chunk, lx, wy, lz)
end

-- Authoritative block write. Records the edit as a diff so it survives chunk unloads (and, in
-- phase 6, saving). Returns the chunk key so callers can notify subscribers.
function WorldService.setBlock(wx: number, wy: number, wz: number, id: number): number
	local cx, cz, lx, lz = ChunkData.worldToChunk(wx, wz)
	local chunk = WorldService.getChunkSync(cx, cz)
	local key = ChunkData.key(cx, cz)
	ChunkData.set(chunk, lx, wy, lz, id)
	local d = diffs[key]
	if not d then
		d = {}
		diffs[key] = d
		chunk.diffs = d
	end
	d[ChunkData.index(lx, wy, lz)] = id
	noteSource(key, ChunkData.index(lx, wy, lz), id)
	for _, fn in blockSetListeners do
		fn(key)
	end
	return key
end

return WorldService
