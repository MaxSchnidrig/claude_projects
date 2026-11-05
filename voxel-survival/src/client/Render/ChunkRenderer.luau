--!strict
-- Owns the render + collision state of every 16^3 section and talks to the backends.
--
-- Sections are rebuilt by scheduler jobs (ClientWorld decides which one is most urgent, nearest
-- first). A rebuilt section replaces the old geometry only once the new geometry is ready, so
-- edits never flash holes.
--
-- Backend choice is PER SECTION:
--   * EditableMesh by default.
--   * If a section's mesh fails, only that section falls back to Parts, and it retries
--     EditableMesh after Config.EDITABLE_RETRY_SECONDS.
--   * If meshes can't be baked ("live" mode) the device budget limits how many sections can be
--     meshes. Then the nearest sections get them: a nearer section takes the slot of the farthest
--     mesh section, which is rebuilt as Parts.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Scheduler = require(Shared.Util.Scheduler)
local SectionSampler = require(Shared.Meshing.SectionSampler)
local GreedyMesher = require(Shared.Meshing.GreedyMesher)
local EditableMeshBackend = require(script.Parent.EditableMeshBackend)
local PartsBackend = require(script.Parent.PartsBackend)
local CollisionBuilder = require(script.Parent.CollisionBuilder)

local BS = Config.BLOCK_SIZE
local CS = Config.CHUNK_SIZE
local SS = Config.SECTION_SIZE

export type Render = { kind: string, handle: any }
export type Section = {
	cx: number,
	cz: number,
	sy: number,
	origin: Vector3, -- world position (studs) of the section's min corner
	renderDirty: boolean,
	collisionDirty: boolean,
	version: number,
	render: Render?,
	collision: { BasePart }?,
	forceParts: boolean, -- this section fell back to Parts
	retryAt: number, -- os.clock() after which it may try EditableMesh again
	alive: boolean,
}

local ChunkRenderer = {}
ChunkRenderer.backend = Config.RENDER_BACKEND -- "editable" | "parts" (F4 toggles)
ChunkRenderer.stats = {
	sectionsMeshed = 0,
	meshTime = 0,
	quads = 0,
	fallbacks = 0,
	demotions = 0,
	sectionsEditable = 0,
	sectionsParts = 0,
}

local paddedRender = buffer.create(SectionSampler.VOLUME)
local paddedCollision = buffer.create(SectionSampler.VOLUME)

local centerX, centerZ = 0, 0
-- Sections currently rendered with EditableMesh in live (unbaked) mode, for demotion.
local liveSections: { [Section]: boolean } = {}

local rootFolder: Folder
local renderFolder: Folder
local collisionFolder: Folder

function ChunkRenderer.init()
	rootFolder = Instance.new("Folder")
	rootFolder.Name = "VoxelWorld"
	renderFolder = Instance.new("Folder")
	renderFolder.Name = "Render"
	renderFolder.Parent = rootFolder
	collisionFolder = Instance.new("Folder")
	collisionFolder.Name = "Collision"
	collisionFolder.Parent = rootFolder
	rootFolder.Parent = workspace
end

function ChunkRenderer.setCenter(cx: number, cz: number)
	centerX, centerZ = cx, cz
end

local function dist2(s: Section): number
	local dx, dz = s.cx - centerX, s.cz - centerZ
	return dx * dx + dz * dz
end

function ChunkRenderer.newSections(cx: number, cz: number): { Section }
	local list = table.create(Config.SECTIONS_PER_CHUNK)
	for sy = 0, Config.SECTIONS_PER_CHUNK - 1 do
		table.insert(list, {
			cx = cx,
			cz = cz,
			sy = sy,
			origin = Vector3.new(cx * CS, sy * SS, cz * CS) * BS,
			renderDirty = true,
			collisionDirty = true,
			version = 0,
			render = nil,
			collision = nil,
			forceParts = false,
			retryAt = 0,
			alive = true,
		})
	end
	return list
end

local function destroyRender(section: Section, r: Render?)
	if not r then
		return
	end
	if r.kind == "editable" then
		ChunkRenderer.stats.sectionsEditable -= 1
		liveSections[section] = nil
		EditableMeshBackend.destroy(r.handle)
	else
		ChunkRenderer.stats.sectionsParts -= 1
		PartsBackend.destroy(r.handle)
	end
end

local function replaceRender(section: Section, r: Render?)
	local old = section.render
	section.render = r
	if r then
		if r.kind == "editable" then
			ChunkRenderer.stats.sectionsEditable += 1
			if #r.handle.meshes > 0 then
				liveSections[section] = true -- holds live EditableMeshes
			end
		else
			ChunkRenderer.stats.sectionsParts += 1
		end
	end
	destroyRender(section, old)
end

local function fallBackToParts(section: Section)
	section.forceParts = true
	section.retryAt = os.clock() + Config.EDITABLE_RETRY_SECONDS
	section.renderDirty = true
	ChunkRenderer.stats.fallbacks += 1
end

-- Live mode with a full budget: free the farthest live section's meshes if it's farther than
-- `section`. Returns true if a slot was freed.
local function demoteFarthestFor(section: Section): boolean
	local farthest: Section? = nil
	local farD = dist2(section)
	for s in liveSections do
		local d = dist2(s)
		if d > farD then
			farthest, farD = s, d
		end
	end
	if not farthest then
		return false
	end
	local victim = farthest :: Section
	replaceRender(victim, nil)
	victim.forceParts = true
	victim.retryAt = math.huge -- only comes back when a slot frees up (see refreshRetries)
	victim.renderDirty = true
	ChunkRenderer.stats.demotions += 1
	return true
end

-- Which backend should this section use right now?
--   "editable" | "parts" | "wait" (EditableMesh slots busy; try again next frame)
function ChunkRenderer.chooseBackend(section: Section): string
	if ChunkRenderer.backend ~= "editable" or section.forceParts then
		return "parts"
	end
	if EditableMeshBackend.canStart() then
		return "editable"
	end
	if EditableMeshBackend.isBudgetLimited() then
		-- live mode, budget full: nearest sections win
		if demoteFarthestFor(section) then
			return "editable"
		end
		return "parts"
	end
	return "wait" -- static mode: just wait for in-flight uploads to finish
end

-- True when most of the world renders as Parts, so ClientWorld should shrink render distance.
function ChunkRenderer.isDegraded(): boolean
	return ChunkRenderer.backend == "parts" or EditableMeshBackend.isBudgetLimited()
end

-- Rebuild a section's visible geometry. Runs inside a scheduler job.
function ChunkRenderer.renderSection(section: Section, chunk: any, neighbors: SectionSampler.Neighbors, mode: string)
	section.renderDirty = false
	section.version += 1
	local version = section.version

	SectionSampler.fill(paddedRender, chunk, neighbors, section.sy)
	local class = GreedyMesher.classify(paddedRender)
	if class ~= "mesh" then
		replaceRender(section, nil)
		return
	end

	if mode == "editable" then
		local t = os.clock()
		local result = GreedyMesher.mesh(paddedRender, Scheduler.checkpoint)
		ChunkRenderer.stats.meshTime += os.clock() - t
		ChunkRenderer.stats.sectionsMeshed += 1
		ChunkRenderer.stats.quads += result.quadCount
		EditableMeshBackend.build(result, section.origin, renderFolder, Scheduler.checkpoint, function(handle, err, budgetHit)
			if not section.alive or section.version ~= version then
				if handle then
					EditableMeshBackend.destroy(handle)
				end
				return
			end
			if err or not handle then
				if budgetHit and EditableMeshBackend.isBudgetLimited() and demoteFarthestFor(section) then
					section.renderDirty = true -- a farther section gave up its slot; retry now
				else
					fallBackToParts(section)
				end
				return
			end
			replaceRender(section, { kind = "editable", handle = handle })
		end)
	else
		local t = os.clock()
		local handle = PartsBackend.build(paddedRender, section.origin, renderFolder)
		ChunkRenderer.stats.meshTime += os.clock() - t
		ChunkRenderer.stats.sectionsMeshed += 1
		replaceRender(section, { kind = "parts", handle = handle })
	end
end

-- Called periodically: Parts sections whose retry time passed (or, in live mode, when a slot is
-- free) go back to EditableMesh, nearest first because the picker rebuilds nearest first.
function ChunkRenderer.refreshRetries(sections: { Section })
	if ChunkRenderer.backend ~= "editable" then
		return
	end
	local now = os.clock()
	local slotFree = EditableMeshBackend.canStart()
	-- Live mode: a Parts section nearer than the farthest mesh section should take its slot
	-- (happens when the player walks). chooseBackend performs the actual demotion.
	local farthestLive = -1
	for s in liveSections do
		farthestLive = math.max(farthestLive, dist2(s))
	end
	for _, s in sections do
		local reclaim = s.retryAt == math.huge and (slotFree or dist2(s) < farthestLive)
		if s.forceParts and (now >= s.retryAt or reclaim) then
			s.forceParts = false
			s.renderDirty = true
		end
	end
end

-- Rebuild a section's collision boxes. Runs inside a scheduler job.
function ChunkRenderer.collideSection(section: Section, chunk: any)
	section.collisionDirty = false
	SectionSampler.fill(paddedCollision, chunk, {}, section.sy)
	local old = section.collision
	section.collision = CollisionBuilder.build(paddedCollision, section.origin, collisionFolder)
	if old then
		CollisionBuilder.destroy(old)
	end
end

function ChunkRenderer.clearCollision(section: Section)
	if section.collision then
		CollisionBuilder.destroy(section.collision)
		section.collision = nil
	end
	section.collisionDirty = true
end

function ChunkRenderer.clearRender(section: Section)
	replaceRender(section, nil)
	section.renderDirty = true
end

function ChunkRenderer.destroySection(section: Section)
	section.alive = false
	replaceRender(section, nil)
	if section.collision then
		CollisionBuilder.destroy(section.collision)
		section.collision = nil
	end
end

-- Switch backends at runtime (debug key). Callers must mark all sections renderDirty.
function ChunkRenderer.setBackend(name: string)
	ChunkRenderer.backend = name
end

function ChunkRenderer.resetForceParts(section: Section)
	section.forceParts = false
	section.retryAt = 0
end

function ChunkRenderer.pump()
	EditableMeshBackend.pump()
end

return ChunkRenderer
