--!strict
-- Client-side world: generates chunks locally from the server's seed, applies the server's diffs,
-- and drives rendering + collision around the player.
--
-- Work selection (scheduler picker), in priority order:
--   1. collision for sections within COLLISION_RADIUS (the player must never fall through)
--   2. nearest-first: generate missing chunk data (radius R + 1), mesh dirty sections (radius R)
-- Meshing a chunk waits until its 4 neighbours have data, so border faces are culled correctly.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local ChunkData = require(Shared.World.ChunkData)
local TerrainGen = require(Shared.World.TerrainGen)
local Scheduler = require(Shared.Util.Scheduler)
local Remotes = require(Shared.Net.Remotes)
local ChunkRenderer = require(script.Parent.Parent.Render.ChunkRenderer)

local CS = Config.CHUNK_SIZE
local SS = Config.SECTION_SIZE
local BS = Config.BLOCK_SIZE
local H = Config.WORLD_HEIGHT
local NSEC = Config.SECTIONS_PER_CHUNK

type Rec = {
	key: number,
	cx: number,
	cz: number,
	data: ChunkData.Chunk?,
	generating: boolean,
	diffsReady: boolean,
	minSurface: number, -- lowest generated surface height in the chunk (for cave culling)
	sections: { ChunkRenderer.Section },
}

local ClientWorld = {}
ClientWorld.stats = { generated = 0, genTime = 0, loaded = 0, pendingGen = 0, pendingMesh = 0 }
-- Average milliseconds per frame spent in our Heartbeat work (for the overlay).
ClientWorld.profile = { refresh = 0, scheduler = 0, other = 0, total = 0 }

local isMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local renderDistance = if isMobile then Config.RENDER_DISTANCE_MOBILE else Config.RENDER_DISTANCE_DESKTOP

local gen: TerrainGen.Generator
local chunks: { [number]: Rec } = {}
local centerX, centerZ = 0, 0
local spawnBlock = Vector3.zero
local scheduler: Scheduler.Scheduler
local pendingLoad: { number } = {}
local pendingUnload: { number } = {}
local worldReadySent = false
local lastFogDistance = -1

-- Fog hides chunk pop-in at the render-distance edge. (Ignored by Roblox if an Atmosphere
-- object exists; phase 4's day/night system takes this over.)
local function applyFog(rd: number)
	lastFogDistance = rd
	local edge = (rd - 0.5) * CS * BS
	Lighting.FogEnd = edge
	Lighting.FogStart = edge * 0.55
	Lighting.FogColor = Color3.fromRGB(170, 200, 235)
end
local anchoredByUs = false

-- Chunk offsets sorted by distance, covering the largest radius we ever need.
local offsets: { { dx: number, dz: number, d2: number } } = {}
do
	local r = Config.RENDER_DISTANCE_MAX + Config.UNLOAD_MARGIN + 1
	for dz = -r, r do
		for dx = -r, r do
			table.insert(offsets, { dx = dx, dz = dz, d2 = dx * dx + dz * dz })
		end
	end
	table.sort(offsets, function(a, b)
		return a.d2 < b.d2
	end)
end

local function getRec(cx: number, cz: number): Rec
	local key = ChunkData.key(cx, cz)
	local rec = chunks[key]
	if not rec then
		rec = {
			key = key,
			cx = cx,
			cz = cz,
			data = nil,
			generating = false,
			diffsReady = false,
			minSurface = 0,
			sections = ChunkRenderer.newSections(cx, cz),
		}
		chunks[key] = rec
	end
	return rec
end

local function dataAt(cx: number, cz: number): ChunkData.Chunk?
	local rec = chunks[ChunkData.key(cx, cz)]
	return rec and rec.data
end

local function neighbors(rec: Rec)
	return {
		east = dataAt(rec.cx + 1, rec.cz),
		west = dataAt(rec.cx - 1, rec.cz),
		south = dataAt(rec.cx, rec.cz + 1),
		north = dataAt(rec.cx, rec.cz - 1),
	}
end

local function neighborsReady(rec: Rec): boolean
	return dataAt(rec.cx + 1, rec.cz) ~= nil
		and dataAt(rec.cx - 1, rec.cz) ~= nil
		and dataAt(rec.cx, rec.cz + 1) ~= nil
		and dataAt(rec.cx, rec.cz - 1) ~= nil
end

-- Jobs ---------------------------------------------------------------------------------------

local function generateJob(rec: Rec): () -> ()
	rec.generating = true
	return function()
		local chunk = ChunkData.new(rec.cx, rec.cz)
		local t = os.clock()
		TerrainGen.generate(gen, chunk, Scheduler.checkpoint)
		ClientWorld.stats.genTime += os.clock() - t
		ClientWorld.stats.generated += 1
		rec.generating = false
		if chunks[rec.key] == rec then
			local minH = math.huge
			for i = 0, CS * CS - 1 do
				minH = math.min(minH, buffer.readu8(chunk.heights, i))
			end
			rec.minSurface = minH
			rec.data = chunk
			table.insert(pendingLoad, rec.key)
		end
	end
end

local function renderJob(rec: Rec, section: ChunkRenderer.Section, mode: string): () -> ()
	section.renderDirty = false -- claim it so the picker doesn't hand it out twice
	return function()
		if section.alive and rec.data then
			ChunkRenderer.renderSection(section, rec.data, neighbors(rec), mode)
		end
	end
end

-- Parts-mode cave culling: a section entirely under the surface, farther than
-- PARTS_CAVE_RADIUS chunks, is skipped (it can only be seen from inside the caves).
local function hiddenCaveSection(rec: Rec, s: ChunkRenderer.Section, d2: number): boolean
	return (s.sy + 1) * SS <= rec.minSurface - 2 and d2 > Config.PARTS_CAVE_RADIUS ^ 2
end

-- Render distance actually used for meshing: smaller while the world is mostly Parts, because
-- Parts cost ~15x more instances than meshes. Chunk data still loads to the full distance.
local function effectiveRenderDistance(): number
	if ChunkRenderer.isDegraded() then
		return math.min(renderDistance, Config.PARTS_RENDER_DISTANCE)
	end
	return renderDistance
end
ClientWorld.effectiveRenderDistance = effectiveRenderDistance

local function collisionJob(rec: Rec, section: ChunkRenderer.Section): () -> ()
	section.collisionDirty = false
	return function()
		if section.alive and rec.data then
			ChunkRenderer.collideSection(section, rec.data)
		end
	end
end

local function pickJob(): (() -> ())?
	-- 1. collision near the player
	local cr = Config.COLLISION_RADIUS
	for _, o in offsets do
		if o.d2 > 2 * cr * cr then
			break
		end
		local rec = chunks[ChunkData.key(centerX + o.dx, centerZ + o.dz)]
		if rec and rec.data and rec.diffsReady then
			for _, s in rec.sections do
				if s.collisionDirty then
					return collisionJob(rec, s)
				end
			end
		end
	end
	-- 2. nearest-first generation and meshing
	local rd = effectiveRenderDistance()
	local genLimit = (rd + 1.5) ^ 2
	local meshLimit = (rd + 0.5) ^ 2
	for _, o in offsets do
		if o.d2 > genLimit then
			break
		end
		local rec = getRec(centerX + o.dx, centerZ + o.dz)
		if not rec.data then
			if not rec.generating then
				return generateJob(rec)
			end
		elseif o.d2 <= meshLimit and rec.diffsReady and neighborsReady(rec) then
			for _, s in rec.sections do
				if s.renderDirty then
					-- Nearest sections are asked first, so they get EditableMesh slots first.
					local mode = ChunkRenderer.chooseBackend(s)
					if mode == "parts" and hiddenCaveSection(rec, s, o.d2) then
						-- skip: invisible from the surface, not worth ~150 Parts. Parked until
						-- refresh() sees the player come close (so it isn't rescanned every frame).
						s.renderDirty = false
						s.culled = true
					elseif mode ~= "wait" then
						return renderJob(rec, s, mode)
					end
				end
			end
		end
	end
	return nil
end

-- Streaming bookkeeping ----------------------------------------------------------------------

local function playerPosition(): Vector3
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		return root.Position
	end
	return spawnBlock * BS
end

local function refresh()
	local pos = playerPosition()
	centerX = math.floor(pos.X / BS) // CS
	centerZ = math.floor(pos.Z / BS) // CS
	ChunkRenderer.setCenter(centerX, centerZ)
	local rd = effectiveRenderDistance()
	if rd ~= lastFogDistance then
		applyFog(rd)
	end
	local renderKeep = (rd + 0.5) ^ 2

	local unloadLimit = (renderDistance + Config.UNLOAD_MARGIN + 0.5) ^ 2
	local collisionKeep = Config.COLLISION_RADIUS + 1
	local loaded, pendingGen, pendingMesh = 0, 0, 0
	for key, rec in chunks do
		local dx, dz = rec.cx - centerX, rec.cz - centerZ
		if dx * dx + dz * dz > unloadLimit then
			for _, s in rec.sections do
				ChunkRenderer.destroySection(s)
			end
			chunks[key] = nil
			if rec.data then
				table.insert(pendingUnload, key)
			end
		else
			if rec.data then
				loaded += 1
			else
				pendingGen += 1
			end
			local farForCollision = math.abs(dx) > collisionKeep or math.abs(dz) > collisionKeep
			local farForRender = dx * dx + dz * dz > renderKeep
			if not farForRender then
				ChunkRenderer.refreshRetries(rec.sections)
			end
			for _, s in rec.sections do
				if s.culled and not hiddenCaveSection(rec, s, dx * dx + dz * dz) then
					s.culled = false
					s.renderDirty = true
				end
				if s.render and (farForRender
					or (s.render.kind == "parts" and hiddenCaveSection(rec, s, dx * dx + dz * dz)))
				then
					ChunkRenderer.clearRender(s) -- out of (degraded) range, or culled cave section
				end
				if farForCollision and s.collision then
					ChunkRenderer.clearCollision(s)
				end
				if s.renderDirty then
					pendingMesh += 1
				end
			end
		end
	end
	ClientWorld.stats.loaded = loaded
	ClientWorld.stats.pendingGen = pendingGen
	ClientWorld.stats.pendingMesh = pendingMesh

	-- Ask the server for diffs of newly generated chunks; release unloaded ones.
	if #pendingLoad > 0 or #pendingUnload > 0 then
		local request = Remotes.get("ChunkRequest")
		while #pendingLoad > 0 or #pendingUnload > 0 do
			local load = table.move(pendingLoad, 1, math.min(#pendingLoad, 128), 1, {})
			local unload = table.move(pendingUnload, 1, math.min(#pendingUnload, 128), 1, {})
			for _ = 1, #load do
				table.remove(pendingLoad, 1)
			end
			for _ = 1, #unload do
				table.remove(pendingUnload, 1)
			end
			request:FireServer({ load = load, unload = unload })
		end
	end
end

-- Mark the sections touching a block dirty (including neighbours across borders).
-- Returns the affected (rec, section) pairs.
local function markDirty(wx: number, wy: number, wz: number): { { rec: Rec, section: ChunkRenderer.Section } }
	local cx, cz, lx, lz = ChunkData.worldToChunk(wx, wz)
	local sy = wy // SS
	local touched = {}
	local function mark(ccx: number, ccz: number, s: number)
		local rec = chunks[ChunkData.key(ccx, ccz)]
		if rec and s >= 0 and s < NSEC then
			local sec = rec.sections[s + 1]
			sec.renderDirty = true
			sec.collisionDirty = true
			table.insert(touched, { rec = rec, section = sec })
		end
	end
	mark(cx, cz, sy)
	local ly = wy % SS
	if ly == 0 then
		mark(cx, cz, sy - 1)
	elseif ly == SS - 1 then
		mark(cx, cz, sy + 1)
	end
	if lx == 0 then
		mark(cx - 1, cz, sy)
	elseif lx == CS - 1 then
		mark(cx + 1, cz, sy)
	end
	if lz == 0 then
		mark(cx, cz - 1, sy)
	elseif lz == CS - 1 then
		mark(cx, cz + 1, sy)
	end
	return touched
end

-- Same-frame rebuilds for edits (see ChunkRenderer.renderUrgent). Capped per frame so a burst of
-- remote edits (e.g. future explosions) can't stall a frame; extra sections use the normal path.
local URGENT_SECTIONS_PER_FRAME = 8
local urgentLeft = URGENT_SECTIONS_PER_FRAME

local function rebuildNow(touched: { { rec: Rec, section: ChunkRenderer.Section } })
	local meshLimit = (effectiveRenderDistance() + 0.5) ^ 2
	for _, t in touched do
		local rec, s = t.rec, t.section
		local data = rec.data
		local dx, dz = rec.cx - centerX, rec.cz - centerZ
		if urgentLeft > 0 and data and rec.diffsReady and s.alive then
			-- render (only where we'd render anyway, and once neighbours exist for border culling)
			if dx * dx + dz * dz <= meshLimit and neighborsReady(rec) and (s.render ~= nil or not s.culled) then
				urgentLeft -= 1
				ChunkRenderer.renderUrgent(s, data, neighbors(rec))
			end
			-- collision: rebuild now if this section has collision, so you can walk into the hole
			-- (or stand on the new block) immediately
			if s.collision ~= nil then
				ChunkRenderer.collideSection(s, data)
			end
		end
	end
end

local function onDiffs(list: any)
	if typeof(list) ~= "table" then
		return
	end
	for _, entry in list do
		local key, packed = entry[1], entry[2]
		local rec = chunks[key]
		if rec and rec.data and typeof(packed) == "string" then
			if #packed > 0 then
				local diffs = ChunkData.unpackDiffs(packed)
				ChunkData.applyDiffs(rec.data, diffs)
				for idx in diffs do
					local x, y, z = ChunkData.unindex(idx)
					markDirty(rec.cx * CS + x, y, rec.cz * CS + z)
				end
			end
			rec.diffsReady = true
		end
	end
end

-- Keep the character frozen while there is no collision under it (e.g. right after a respawn
-- far away), so it can't fall through not-yet-built terrain.
local function safetyAnchor()
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local p = root.Position / BS
	local bx, by, bz = math.floor(p.X), math.floor(p.Y), math.floor(p.Z)
	local cx, cz = bx // CS, bz // CS
	local rec = chunks[ChunkData.key(cx, cz)]
	local ready = rec ~= nil and rec.data ~= nil
	if ready and rec then
		local sy = math.clamp(by // SS, 0, NSEC - 1)
		for s = math.max(0, sy - 1), sy do
			local sec = rec.sections[s + 1]
			if sec.collisionDirty or sec.collision == nil then
				ready = false
			end
		end
	end
	if not ready and not root.Anchored then
		root.Anchored = true
		anchoredByUs = true
	elseif ready and anchoredByUs then
		root.Anchored = false
		anchoredByUs = false
	end
end

local function checkWorldReady()
	if worldReadySent then
		return
	end
	local scx, scz = math.floor(spawnBlock.X) // CS, math.floor(spawnBlock.Z) // CS
	local cr = Config.COLLISION_RADIUS
	for dz = -cr, cr do
		for dx = -cr, cr do
			local rec = chunks[ChunkData.key(scx + dx, scz + dz)]
			if not rec or not rec.data then
				return
			end
			for _, s in rec.sections do
				if s.collisionDirty then
					return
				end
			end
		end
	end
	worldReadySent = true
	Remotes.get("WorldReady"):FireServer()
end

-- Public API ---------------------------------------------------------------------------------

function ClientWorld.init()
	local seed = ReplicatedStorage:GetAttribute("WorldSeed")
	while seed == nil do
		ReplicatedStorage:GetAttributeChangedSignal("WorldSeed"):Wait()
		seed = ReplicatedStorage:GetAttribute("WorldSeed")
	end
	spawnBlock = ReplicatedStorage:GetAttribute("SpawnBlock") or Vector3.new(0, 80, 0)
	gen = TerrainGen.new(seed :: number)

	local player = Players.LocalPlayer
	local function applyRenderDistance()
		local rd = player:GetAttribute("RenderDistance")
		if typeof(rd) == "number" then
			renderDistance = math.clamp(math.floor(rd), Config.RENDER_DISTANCE_MIN, Config.RENDER_DISTANCE_MAX)
		end
	end
	applyRenderDistance()
	applyFog(effectiveRenderDistance())
	player:GetAttributeChangedSignal("RenderDistance"):Connect(applyRenderDistance)

	ChunkRenderer.init()
	Remotes.get("ChunkDiffs").OnClientEvent:Connect(onDiffs)
	-- Authoritative block changes (other players' edits, and confirmations/corrections of ours).
	Remotes.get("BlockChanged").OnClientEvent:Connect(function(x: any, y: any, z: any, id: any)
		if typeof(x) == "number" and typeof(y) == "number" and typeof(z) == "number" and typeof(id) == "number" then
			if ClientWorld.getBlock(x, y, z) ~= id then
				ClientWorld.setBlock(x, y, z, id, true) -- others' edits and our rollbacks show instantly
			end
		end
	end)

	local budget = if isMobile then Config.FRAME_BUDGET_MS_MOBILE else Config.FRAME_BUDGET_MS_DESKTOP
	scheduler = Scheduler.new(budget, pickJob)
	ClientWorld.scheduler = scheduler

	local acc = math.huge
	local prof = ClientWorld.profile
	RunService.Heartbeat:Connect(function(dt)
		local t0 = os.clock()
		urgentLeft = URGENT_SECTIONS_PER_FRAME
		acc += dt
		if acc >= 0.25 then
			acc = 0
			refresh()
		end
		local t1 = os.clock()
		scheduler:step()
		local t2 = os.clock()
		ChunkRenderer.pump()
		safetyAnchor()
		checkWorldReady()
		local t3 = os.clock()
		-- exponential moving averages (ms) for the F3 overlay
		prof.refresh = prof.refresh * 0.9 + (t1 - t0) * 100
		prof.scheduler = prof.scheduler * 0.9 + (t2 - t1) * 100
		prof.other = prof.other * 0.9 + (t3 - t2) * 100
		prof.total = prof.total * 0.9 + (t3 - t0) * 100
	end)
end

function ClientWorld.getRenderDistance(): number
	return renderDistance
end

function ClientWorld.isMobile(): boolean
	return isMobile
end

-- Block id at world block coords, or nil if that chunk isn't loaded on this client.
function ClientWorld.getBlock(wx: number, wy: number, wz: number): number?
	if wy < 0 or wy >= H then
		return 0
	end
	local cx, cz, lx, lz = ChunkData.worldToChunk(wx, wz)
	local data = dataAt(cx, cz)
	if not data then
		return nil
	end
	return ChunkData.get(data, lx, wy, lz)
end

-- Local block write (used when the server confirms a change; phase 2).
-- Block write. `instant` = show the change on this very frame (player edits, server-confirmed
-- edits); otherwise the scheduler rebuilds the section in the background.
function ClientWorld.setBlock(wx: number, wy: number, wz: number, id: number, instant: boolean?)
	if wy < 0 or wy >= H then
		return
	end
	local cx, cz, lx, lz = ChunkData.worldToChunk(wx, wz)
	local data = dataAt(cx, cz)
	if not data then
		return
	end
	ChunkData.set(data, lx, wy, lz, id)
	local touched = markDirty(wx, wy, wz)
	if instant then
		rebuildNow(touched)
	end
end

function ClientWorld.biomeAt(wx: number, wz: number): number?
	local cx, cz, lx, lz = ChunkData.worldToChunk(wx, wz)
	local data = dataAt(cx, cz)
	if not data then
		return nil
	end
	return buffer.readu8(data.biomes, lx + lz * CS)
end

-- Rebuild every section's geometry (used when switching render backends).
function ClientWorld.remeshAll()
	for _, rec in chunks do
		for _, s in rec.sections do
			s.renderDirty = true
			s.culled = false
			ChunkRenderer.resetForceParts(s)
		end
	end
end

return ClientWorld
