--!strict
-- Owns the render + collision state of every 16^3 section and talks to the backends.
--
-- Sections are rebuilt by scheduler jobs (ClientWorld decides which one is most urgent).
-- A rebuilt section replaces the old geometry only once the new geometry is ready, so edits
-- never flash holes. If EditableMesh fails (API unavailable / memory budget), the section is
-- rebuilt with the Parts backend; after repeated failures the whole renderer switches over.

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
local MAX_CONSECUTIVE_FAILURES = 3

export type Render = { kind: string, handle: any }
export type Section = {
	sy: number,
	origin: Vector3, -- world position (studs) of the section's min corner
	renderDirty: boolean,
	collisionDirty: boolean,
	version: number,
	render: Render?,
	collision: { BasePart }?,
	forceParts: boolean,
	alive: boolean,
}

local ChunkRenderer = {}
ChunkRenderer.backend = Config.RENDER_BACKEND
ChunkRenderer.editableDisabled = false
ChunkRenderer.stats = {
	sectionsMeshed = 0,
	meshTime = 0,
	quads = 0,
	fallbacks = 0,
}

local paddedRender = buffer.create(SectionSampler.VOLUME)
local paddedCollision = buffer.create(SectionSampler.VOLUME)
local consecutiveFailures = 0

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

function ChunkRenderer.newSections(cx: number, cz: number): { Section }
	local list = table.create(Config.SECTIONS_PER_CHUNK)
	for sy = 0, Config.SECTIONS_PER_CHUNK - 1 do
		table.insert(list, {
			sy = sy,
			origin = Vector3.new(cx * CS, sy * SS, cz * CS) * BS,
			renderDirty = true,
			collisionDirty = true,
			version = 0,
			render = nil,
			collision = nil,
			forceParts = false,
			alive = true,
		})
	end
	return list
end

local function destroyRender(r: Render?)
	if not r then
		return
	end
	if r.kind == "editable" then
		EditableMeshBackend.destroy(r.handle)
	else
		PartsBackend.destroy(r.handle)
	end
end

local function replaceRender(section: Section, r: Render?)
	local old = section.render
	section.render = r
	destroyRender(old)
end

-- Rebuild a section's visible geometry. Runs inside a scheduler job.
function ChunkRenderer.renderSection(section: Section, chunk: any, neighbors: SectionSampler.Neighbors)
	section.renderDirty = false
	section.version += 1
	local version = section.version

	SectionSampler.fill(paddedRender, chunk, neighbors, section.sy)
	local class = GreedyMesher.classify(paddedRender)
	if class ~= "mesh" then
		replaceRender(section, nil)
		return
	end

	local useEditable = ChunkRenderer.backend == "editable" and not ChunkRenderer.editableDisabled and not section.forceParts
	if useEditable then
		local t = os.clock()
		local result = GreedyMesher.mesh(paddedRender, Scheduler.checkpoint)
		ChunkRenderer.stats.meshTime += os.clock() - t
		ChunkRenderer.stats.sectionsMeshed += 1
		ChunkRenderer.stats.quads += result.quadCount
		EditableMeshBackend.build(result, section.origin, renderFolder, Scheduler.checkpoint, function(handle, err)
			if not section.alive or section.version ~= version then
				if handle then
					EditableMeshBackend.destroy(handle)
				end
				return
			end
			if err or not handle then
				consecutiveFailures += 1
				ChunkRenderer.stats.fallbacks += 1
				if consecutiveFailures >= MAX_CONSECUTIVE_FAILURES and not ChunkRenderer.editableDisabled then
					ChunkRenderer.editableDisabled = true
					warn(`[ChunkRenderer] EditableMesh failed {consecutiveFailures}x, switching to Parts backend. Last error: {err}`)
				end
				section.forceParts = true
				section.renderDirty = true
				return
			end
			consecutiveFailures = 0
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
	ChunkRenderer.editableDisabled = false
	consecutiveFailures = 0
end

function ChunkRenderer.resetForceParts(section: Section)
	section.forceParts = false
end

function ChunkRenderer.pump()
	EditableMeshBackend.pump()
end

return ChunkRenderer
