--!strict
-- Java-style block updates for systems that change the world on their own (fluids, falling
-- blocks, fire, TNT):
--
--   * a game tick clock at 20 ticks per second, independent of the frame rate
--   * scheduled ticks: schedule(x, y, z, delay, kind) runs handlers[kind](x, y, z) `delay` ticks
--     later (one entry per block and kind, like Java's scheduled block ticks)
--   * neighbour updates: whenever any block changes, `neighbourHandlers` run for the block and
--     its 6 neighbours (they usually schedule a tick)
--   * set(x, y, z, id): change a block and send it to the players who have that chunk; changes
--     are batched per tick into one message per player
-- Work per tick is capped (Config.MAX_BLOCK_TICKS_PER_TICK); the rest waits for the next tick.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local WorldService = require(script.Parent.WorldService)
local ChunkStreamer = require(script.Parent.ChunkStreamer)

local CS = Config.CHUNK_SIZE

local BlockUpdates = {}
BlockUpdates.tick = 0
BlockUpdates.stats = { scheduled = 0, ran = 0, deferred = 0, sent = 0 }

type Entry = { x: number, y: number, z: number, kind: string }
local due: { [number]: { Entry } } = {} -- tick -> entries
local pendingKey: { [string]: number } = {} -- "kind:x,y,z" -> tick it is scheduled for
local handlers: { [string]: (x: number, y: number, z: number) -> () } = {}
local neighbourHandlers: { (x: number, y: number, z: number) -> () } = {}
local tickHandlers: { () -> () } = {}
local outgoing: { { number } } = {}

local DIRS = { { 0, 0, 0 }, { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

function BlockUpdates.register(kind: string, fn: (x: number, y: number, z: number) -> ())
	handlers[kind] = fn
end

-- Called for a changed block and each of its 6 neighbours.
function BlockUpdates.onNeighbourChanged(fn: (x: number, y: number, z: number) -> ())
	table.insert(neighbourHandlers, fn)
end

-- Runs once per game tick (entities like falling blocks and TNT).
function BlockUpdates.onTick(fn: () -> ())
	table.insert(tickHandlers, fn)
end

function BlockUpdates.schedule(x: number, y: number, z: number, delay: number, kind: string)
	local key = `{kind}:{x},{y},{z}`
	local at = BlockUpdates.tick + math.max(1, delay)
	local existing = pendingKey[key]
	if existing and existing <= at and existing > BlockUpdates.tick then
		return -- already scheduled sooner
	end
	pendingKey[key] = at
	local list = due[at]
	if not list then
		list = {}
		due[at] = list
	end
	table.insert(list, { x = x, y = y, z = z, kind = kind })
	BlockUpdates.stats.scheduled += 1
end

-- Change a block from a game system and tell the clients (batched).
function BlockUpdates.set(x: number, y: number, z: number, id: number)
	if y < 0 or y >= Config.WORLD_HEIGHT then
		return
	end
	if WorldService.getBlockIfLoaded(x, y, z) == nil then
		return -- never touch unloaded chunks
	end
	WorldService.setBlock(x, y, z, id)
	table.insert(outgoing, { x, y, z, id })
end

-- Also batch changes made elsewhere that should reach clients this way.
function BlockUpdates.send(x: number, y: number, z: number, id: number)
	table.insert(outgoing, { x, y, z, id })
end

local function flush()
	if #outgoing == 0 then
		return
	end
	local byPlayer: { [Player]: { number } } = {}
	local cache: { [number]: { Player } } = {}
	for _, c in outgoing do
		local cx, cz = c[1] // CS, c[3] // CS
		local key = (cx + 1048576) * 2097152 + (cz + 1048576)
		local list = cache[key]
		if not list then
			list = ChunkStreamer.playersWithChunk(key)
			cache[key] = list
		end
		for _, p in list do
			local flat = byPlayer[p]
			if not flat then
				flat = {}
				byPlayer[p] = flat
			end
			table.insert(flat, c[1])
			table.insert(flat, c[2])
			table.insert(flat, c[3])
			table.insert(flat, c[4])
		end
	end
	table.clear(outgoing)
	local remote = Remotes.get("BlockBatch")
	for p, flat in byPlayer do
		if p.Parent then
			remote:FireClient(p, flat)
			BlockUpdates.stats.sent += #flat // 4
		end
	end
end

local function runTick()
	BlockUpdates.tick += 1
	local t = BlockUpdates.tick
	local list = due[t]
	if list then
		due[t] = nil
		local budget = Config.MAX_BLOCK_TICKS_PER_TICK
		for i, e in list do
			if i > budget then
				-- over budget: move the rest to the next tick
				local nextList = due[t + 1] or {}
				due[t + 1] = nextList
				table.insert(nextList, e)
				pendingKey[`{e.kind}:{e.x},{e.y},{e.z}`] = t + 1
				BlockUpdates.stats.deferred += 1
			else
				pendingKey[`{e.kind}:{e.x},{e.y},{e.z}`] = nil
				local h = handlers[e.kind]
				if h then
					h(e.x, e.y, e.z)
					BlockUpdates.stats.ran += 1
				end
			end
		end
	end
	for _, fn in tickHandlers do
		fn()
	end
	flush()
end

function BlockUpdates.init()
	WorldService.onBlockChanged(function(x, y, z)
		for _, d in DIRS do
			for _, fn in neighbourHandlers do
				fn(x + d[1], y + d[2], z + d[3])
			end
		end
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		local n = 0
		while acc >= 0.05 and n < 4 do
			acc -= 0.05
			n += 1
			runTick()
		end
		if acc > 0.2 then
			acc = 0 -- don't spiral after a long hitch
		end
	end)
	Players.PlayerRemoving:Connect(function() end)
end

return BlockUpdates
