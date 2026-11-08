--!strict
-- Saving and loading (phase 6). See Shared/Persistence/SaveFormat for the data layout.
--
-- Server kinds (decided at startup by `resolve`):
--   lobby   a public server: only the lobby menu runs (LobbyService); no world
--   world   a reserved server created for one owner (looked up via srv:<PrivateServerId>), a
--           VIP server (owner = its owner), or Studio (owner = first player / STUDIO_OWNER_ID)
--
-- In a world server:
--   * world meta (seed, time, friends setting, index of saved regions) is loaded before the world
--     starts; time and the region index are written back
--   * a chunk is only generated after its region's saved edits are loaded (WorldService gate).
--     Regions never saved are ready at once. A region whose load fails after all retries is
--     played but never saved, so the stored copy can't be overwritten with a blank one
--   * any block edit or chest/furnace change marks its region dirty
--   * players: loaded on join before they spawn (inventory, health, hunger, air, position);
--     saved on leave, every Config.AUTOSAVE_SECONDS and on shutdown. If a player's save can't
--     be read they are kicked rather than given (and later saving) an empty inventory
--   * access: the owner always; others only if the owner allows friends and is their friend
--   * every write goes through DataStoreQueue (budget, 6 s per key, retries, merging)
--
-- Not saved: dropped items, mobs (animals re-populate fresh chunks each session).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local ChunkData = require(Shared.World.ChunkData)
local SaveFormat = require(Shared.Persistence.SaveFormat)
local DataStoreQueue = require(script.Parent.DataStoreQueue)

local CS = Config.CHUNK_SIZE
local BS = Config.BLOCK_SIZE
local RC = SaveFormat.REGION_CHUNKS

local Persistence = {}
Persistence.mode = "world"
Persistence.ownerId = 0
Persistence.stats = { regionsLoaded = 0, regionsSaved = 0, regionsFailed = 0 }

export type Meta = {
	seed: number,
	ticks: number?,
	friends: boolean,
	code: string?,
	psid: string?,
	regions: { string },
	created: number?,
}

local queue: DataStoreQueue.Queue
local meta: Meta
local savedRegions: { [string]: boolean } = {} -- regions with data in the store
local regionState: { [string]: string } = {} -- "loading" | "ready" | "failed"
local loadedPlayers: { [Player]: boolean } = {}
local lastPos: { [Player]: { pos: Vector3, yaw: number } } = {}

function Persistence.storeName(): string
	return if RunService:IsStudio() then Config.DATASTORE_NAME .. "_Studio" else Config.DATASTORE_NAME
end

function Persistence.queue(): DataStoreQueue.Queue
	return queue
end

-- Which kind of server is this, and who owns the world? Yields (DataStore read, or waiting for
-- the first player in Studio).
function Persistence.resolve(): (string, number)
	queue = DataStoreQueue.new(Persistence.storeName())
	if RunService:IsStudio() then
		local owner = Config.STUDIO_OWNER_ID
		if owner == 0 then
			local first = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()
			owner = first.UserId
		end
		Persistence.mode, Persistence.ownerId = "world", owner
	elseif game.PrivateServerId ~= "" and game.PrivateServerOwnerId ~= 0 then
		Persistence.mode, Persistence.ownerId = "world", game.PrivateServerOwnerId -- VIP server
	elseif game.PrivateServerId ~= "" then
		local ok, owner = queue:get(SaveFormat.serverKey(game.PrivateServerId))
		if ok and typeof(owner) == "number" then
			Persistence.mode, Persistence.ownerId = "world", owner
		else
			warn("[Persistence] reserved server without a known owner")
			Persistence.mode = "world"
			local first = Players:GetPlayers()[1] or Players.PlayerAdded:Wait()
			Persistence.ownerId = first.UserId
		end
	else
		Persistence.mode = "lobby"
	end
	return Persistence.mode, Persistence.ownerId
end

local function decodeMeta(v: any): Meta?
	if typeof(v) ~= "table" or typeof(v.seed) ~= "number" then
		return nil
	end
	local regions = {}
	if typeof(v.regions) == "table" then
		for _, r in v.regions do
			if typeof(r) == "string" then
				table.insert(regions, r)
			end
		end
	end
	return {
		seed = v.seed,
		ticks = if typeof(v.ticks) == "number" then v.ticks else nil,
		friends = v.friends ~= false,
		code = if typeof(v.code) == "string" then v.code else nil,
		psid = if typeof(v.psid) == "string" then v.psid else nil,
		regions = regions,
		created = if typeof(v.created) == "number" then v.created else nil,
	}
end
Persistence.decodeMeta = decodeMeta

-- A new world's seed (Studio keeps the default seed so test worlds stay familiar).
function Persistence.newSeed(): number
	if RunService:IsStudio() then
		return Config.DEFAULT_SEED
	end
	return Random.new():NextInteger(1, 2 ^ 31 - 2)
end

-- Load (or create) the world meta. Yields.
function Persistence.loadWorld(): Meta
	local ok, v = queue:get(SaveFormat.metaKey(Persistence.ownerId))
	if not ok then
		-- can't read the world: refuse to run it rather than overwrite it
		for _, p in Players:GetPlayers() do
			p:Kick("Couldn't load this world (saving service unavailable). Please try again in a minute.")
		end
		error("[Persistence] world meta could not be read")
	end
	meta = decodeMeta(v) or {
		seed = Persistence.newSeed(),
		ticks = nil,
		friends = true,
		regions = {},
		created = os.time(),
	}
	for _, r in meta.regions do
		savedRegions[r] = true
	end
	print(`[Persistence] world of {Persistence.ownerId}: seed {meta.seed}, {#meta.regions} saved regions, saving {if queue:isPersistent() then "on" else "OFF"}`)
	return meta
end

---------------------------------------------------------------------------------------------
-- Regions
---------------------------------------------------------------------------------------------

local function regionOfChunk(key: number): (number, number, string)
	local cx, cz = ChunkData.unkey(key)
	local rx, rz = SaveFormat.regionOf(cx, cz)
	return rx, rz, SaveFormat.regionId(rx, rz)
end

local WorldService: any
local BlockEntityService: any
local installing = false

local function loadRegion(rx: number, rz: number, rid: string)
	regionState[rid] = "loading"
	local ok, v = queue:get(SaveFormat.regionKey(Persistence.ownerId, rx, rz))
	if not ok then
		warn(`[Persistence] region {rid} could not be loaded; it will not be saved this session`)
		regionState[rid] = "failed"
		Persistence.stats.regionsFailed += 1
		return
	end
	local region = SaveFormat.decodeRegion(v)
	installing = true -- restoring isn't a change: don't mark the region dirty
	for key, diffs in region.chunks do
		WorldService.installDiffs(key, diffs)
	end
	for _, e in region.entities do
		BlockEntityService.restore(e.kind, e.x, e.y, e.z, e.slots, e.burn, e.burnMax, e.progress, e.data)
	end
	installing = false
	regionState[rid] = "ready"
	Persistence.stats.regionsLoaded += 1
end

local function ready(key: number): boolean
	local _, _, rid = regionOfChunk(key)
	local st = regionState[rid]
	if st == "ready" or st == "failed" then
		return true
	end
	if st == nil and not savedRegions[rid] then
		regionState[rid] = "ready" -- nothing saved there
		return true
	end
	return false
end

local function request(key: number)
	local rx, rz, rid = regionOfChunk(key)
	if regionState[rid] == nil then
		if savedRegions[rid] then
			task.spawn(loadRegion, rx, rz, rid)
		else
			regionState[rid] = "ready"
		end
	end
end

local function ensure(key: number)
	if ready(key) then
		return
	end
	request(key)
	local _, _, rid = regionOfChunk(key)
	local t0 = os.clock()
	while regionState[rid] == "loading" and os.clock() - t0 < 60 do
		task.wait(0.05)
	end
end

-- Value for a region record, built from live data at write time.
local function regionProducer(rx: number, rz: number): (any) -> any
	return function(_old: any): any
		local chunks = {}
		for dz = 0, RC - 1 do
			for dx = 0, RC - 1 do
				local key = ChunkData.key(rx * RC + dx, rz * RC + dz)
				local d = WorldService.getDiffs(key)
				if d then
					chunks[key] = d
				end
			end
		end
		local entities = {}
		local x0, z0 = rx * RC * CS, rz * RC * CS
		for _, e in BlockEntityService.inArea(x0, z0, x0 + RC * CS, z0 + RC * CS) do
			local f = e.furnace
			table.insert(entities, {
				kind = e.kind,
				x = e.x,
				y = e.y,
				z = e.z,
				slots = e.slots,
				burn = if f then f.burn else 0,
				burnMax = if f then f.burnMax else 0,
				progress = if f then f.progress else 0,
				data = e.data,
			})
		end
		Persistence.stats.regionsSaved += 1
		return SaveFormat.encodeRegion({ chunks = chunks, entities = entities })
	end
end

local metaDirty = false
local function markRegion(rx: number, rz: number)
	local rid = SaveFormat.regionId(rx, rz)
	if installing or regionState[rid] == "failed" then
		return
	end
	if not savedRegions[rid] then
		savedRegions[rid] = true
		metaDirty = true
	end
	queue:markDirty(SaveFormat.regionKey(Persistence.ownerId, rx, rz), regionProducer(rx, rz))
end

---------------------------------------------------------------------------------------------
-- Meta
---------------------------------------------------------------------------------------------

local DayNightService: any

local function markMeta()
	queue:markDirty(SaveFormat.metaKey(Persistence.ownerId), function(old: any): any
		-- merge: the lobby owns code/psid/friends; this server owns time and the region index
		local prev = decodeMeta(old)
		local regions = {}
		local seen = {}
		for rid in savedRegions do
			seen[rid] = true
			table.insert(regions, rid)
		end
		if prev then
			for _, rid in prev.regions do
				if not seen[rid] then
					table.insert(regions, rid)
				end
			end
		end
		table.sort(regions)
		return {
			v = SaveFormat.VERSION,
			seed = meta.seed,
			ticks = DayNightService.ticks(),
			friends = if prev then prev.friends else meta.friends,
			code = if prev and prev.code then prev.code else meta.code,
			psid = if prev and prev.psid then prev.psid else meta.psid,
			regions = regions,
			created = (prev and prev.created) or meta.created or os.time(),
		}
	end)
	metaDirty = false
end

---------------------------------------------------------------------------------------------
-- Players
---------------------------------------------------------------------------------------------

local InventoryService: any
local SurvivalService: any
local SpawnService: any

local function playerProducer(p: Player): (any) -> any
	-- the snapshot is taken now (the player may be gone at write time)
	local slots, selected = InventoryService.snapshot(p)
	local surv, dead = SurvivalService.snapshot(p)
	local lp = lastPos[p]
	local state: SaveFormat.PlayerState = {
		slots = slots,
		selected = selected,
		health = surv.health,
		food = surv.food,
		saturation = surv.saturation,
		exhaustion = surv.exhaustion,
		air = surv.air,
		pos = if lp and not dead then lp.pos else nil,
		yaw = if lp then lp.yaw else 0,
	}
	local encoded = SaveFormat.encodePlayer(state)
	return function(_old: any): any
		return encoded
	end
end

local function savePlayer(p: Player)
	if loadedPlayers[p] then
		queue:markDirty(SaveFormat.playerKey(Persistence.ownerId, p.UserId), playerProducer(p))
	end
end

local function canJoin(p: Player): (boolean, string?)
	if p.UserId == Persistence.ownerId or RunService:IsStudio() then
		return true, nil
	end
	local ok, v = queue:get(SaveFormat.metaKey(Persistence.ownerId))
	local m = if ok then decodeMeta(v) else nil
	local friends = if m then m.friends else meta.friends
	if not friends then
		return false, "The owner of this world doesn't allow visitors right now."
	end
	local isFriend = false
	pcall(function()
		isFriend = p:IsFriendsWith(Persistence.ownerId)
	end)
	if not isFriend then
		return false, "Only the owner's friends can join this world."
	end
	return true, nil
end

local function onPlayer(p: Player)
	local allowed, why = canJoin(p)
	if not allowed then
		p:Kick(why)
		return
	end
	local ok, v = queue:get(SaveFormat.playerKey(Persistence.ownerId, p.UserId))
	if not p.Parent then
		return
	end
	if not ok then
		p:Kick("Couldn't load your save (saving service unavailable). Please rejoin in a minute.")
		return
	end
	local state = SaveFormat.decodePlayer(v, Config.INVENTORY_SLOTS)
	if state then
		InventoryService.restore(p, state.slots, state.selected)
		SurvivalService.setRestore(p, {
			health = state.health,
			food = state.food,
			saturation = state.saturation,
			exhaustion = state.exhaustion,
			air = state.air,
		})
		if state.pos then
			SpawnService.setFirstSpawn(p, state.pos, state.yaw)
			-- make sure the saved spot's region is loaded before the client asks for it
			local cx, cz = math.floor(state.pos.X) // CS, math.floor(state.pos.Z) // CS
			ensure(ChunkData.key(cx, cz))
		end
	elseif RunService:IsStudio() then
		InventoryService.giveStarterKit(p)
	end
	loadedPlayers[p] = true
	p:SetAttribute("DataLoaded", true)
end

---------------------------------------------------------------------------------------------
-- Active worlds (MemoryStore): lets friends in the lobby see this world is running
---------------------------------------------------------------------------------------------

local function publishActive(remove: boolean?)
	if RunService:IsStudio() or game.PrivateServerId == "" then
		return
	end
	pcall(function()
		local map = game:GetService("MemoryStoreService"):GetSortedMap(Config.ACTIVE_WORLDS_MAP)
		if remove then
			map:RemoveAsync(tostring(Persistence.ownerId))
		else
			map:SetAsync(tostring(Persistence.ownerId), { players = #Players:GetPlayers() }, 150)
		end
	end)
end

---------------------------------------------------------------------------------------------

-- Gate chunk generation on saved data and track edits. Call BEFORE WorldService.init so no chunk
-- is ever generated without its saved edits.
function Persistence.attachWorld(worldService: any, blockEntityService: any)
	WorldService = worldService
	BlockEntityService = blockEntityService
	WorldService.setGate({ ready = ready, request = request, ensure = ensure })
	WorldService.onBlockSet(function(chunkKey: number)
		local rx, rz = regionOfChunk(chunkKey)
		markRegion(rx, rz)
	end)
	BlockEntityService.onDirty(function(x: number, z: number)
		local rx, rz = SaveFormat.regionOf(x // CS, z // CS)
		markRegion(rx, rz)
	end)
end

-- Start player saving, autosave and shutdown saving (after all services are initialised).
function Persistence.startWorld(services: { [string]: any })
	ReplicatedStorage:SetAttribute("WorldOwner", Persistence.ownerId) -- e.g. the owner's debug button
	InventoryService = services.InventoryService
	SurvivalService = services.SurvivalService
	SpawnService = services.SpawnService
	DayNightService = services.DayNightService

	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayer, p)
	end
	Players.PlayerRemoving:Connect(function(p)
		if loadedPlayers[p] then
			savePlayer(p)
			loadedPlayers[p] = nil
			task.spawn(function()
				queue:flush()
			end)
		end
		lastPos[p] = nil
	end)

	-- remember positions (the character is gone by the time PlayerRemoving fires)
	task.spawn(function()
		while true do
			for _, p in Players:GetPlayers() do
				local c = p.Character
				local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
				local h = c and c:FindFirstChildOfClass("Humanoid")
				if root and h and h.Health > 0 and not root.Anchored then
					local look = root.CFrame.LookVector
					lastPos[p] = {
						pos = Vector3.new(root.Position.X, root.Position.Y - 3, root.Position.Z) / BS,
						yaw = math.atan2(-look.X, -look.Z),
					}
				end
			end
			task.wait(1)
		end
	end)

	-- autosave
	task.spawn(function()
		local since = 0
		while true do
			task.wait(5)
			since += 5
			if metaDirty then
				markMeta()
			end
			if since >= Config.AUTOSAVE_SECONDS then
				since = 0
				markMeta()
				for p in loadedPlayers do
					savePlayer(p)
				end
				queue:flush()
				publishActive()
				local st = queue.stats
				ReplicatedStorage:SetAttribute("SaveStatus", string.format("saving %s, last autosave %s, pending %d, reads %d, writes %d, failures %d%s",
					if queue:isPersistent() then "ON" else "OFF (no DataStore access)", os.date("%H:%M:%S"),
					st.pending, st.reads, st.writes, st.failures,
					if st.lastError ~= "" then ` ({st.lastError})` else ""))
			end
		end
	end)
	publishActive()
	ReplicatedStorage:SetAttribute("SaveStatus", `saving {if queue:isPersistent() then "ON" else "OFF (no DataStore access)"}, owner {Persistence.ownerId}`)

	game:BindToClose(function()
		markMeta()
		for p in loadedPlayers do
			savePlayer(p)
		end
		queue:flush(os.clock() + 25)
		publishActive(true)
	end)
end

function Persistence.worldMeta(): Meta
	return meta
end

return Persistence
