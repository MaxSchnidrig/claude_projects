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
local LiveEditPool = require(script.Parent.LiveEditPool)
local SpecialPartsBackend = require(script.Parent.SpecialPartsBackend)
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
	failCount: number, -- consecutive EditableMesh failures (retry delay doubles each time)
	culled: boolean, -- skipped by Parts-mode cave culling; ClientWorld re-dirties it when needed
	editPending: boolean, -- just edited: its mesh rebuild has priority
	liveSlot: any?, -- LiveEditPool slot currently showing this section (instant edit)
	special: any?, -- SpecialPartsBackend handle: water/ice/glass/lava faces as plain Parts
	editTime: number, -- os.clock() of that edit (to measure how long the hand-over takes)
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
	urgentBuilds = 0,
	urgentTime = 0,
	swaps = 0, -- edit (live mesh) -> baked mesh hand-overs
	swapTime = 0, -- total seconds from edit to the mesh being parented
}
-- Debug (F6): keep edited sections on their live pool mesh instead of baking, to compare.
ChunkRenderer.keepTemp = false

local paddedRender = buffer.create(SectionSampler.VOLUME)
local paddedCollision = buffer.create(SectionSampler.VOLUME)
local paddedUrgent = buffer.create(SectionSampler.VOLUME) -- urgent builds may interrupt a yielded job

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
	LiveEditPool.init(renderFolder)
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
			failCount = 0,
			culled = false,
			editPending = false,
			liveSlot = nil,
			special = nil,
			editTime = 0,
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
		EditableMeshBackend.destroy(r.handle)
	else
		ChunkRenderer.stats.sectionsParts -= 1
		PartsBackend.destroy(r.handle)
	end
end

-- Swap a section's geometry. When new geometry replaces old (a rebuild after an edit), the old
-- geometry stays visible for Config.RENDER_SWAP_OVERLAP seconds: a freshly parented MeshPart can
-- take a few frames before it actually draws, and destroying the old one in the same frame showed
-- a see-through "x-ray" flash. Removals with no replacement (unload, empty section) are immediate.
--
-- Transparent geometry (water, ice, glass) must never be doubled: two overlapping see-through
-- surfaces blend and flicker. So during the overlap the NEW transparent parts are drawn almost
-- invisibly (LocalTransparencyModifier 0.99: they still get drawn, so they're ready), and at the
-- end of the overlap one callback makes them fully visible, removes the old geometry and runs
-- `afterSwap` (e.g. clearing the live edit mesh), all in the same frame.
local NEAR_INVISIBLE = 0.99

local function replaceRender(section: Section, r: Render?, immediate: boolean?, afterSwap: (() -> ())?)
	local old = section.render
	section.render = r
	liveSections[section] = if r and r.kind == "editable" and #r.handle.meshes > 0 then true else nil
	if r then
		if r.kind == "editable" then
			ChunkRenderer.stats.sectionsEditable += 1
		else
			ChunkRenderer.stats.sectionsParts += 1
		end
	end
	if r and (old or afterSwap) and not immediate and Config.RENDER_SWAP_OVERLAP > 0 then
		local hiddenNew: { BasePart } = {}
		for _, p in r.handle.parts do
			if p.Transparency > 0 then
				p.LocalTransparencyModifier = NEAR_INVISIBLE
				table.insert(hiddenNew, p)
			end
		end
		task.delay(Config.RENDER_SWAP_OVERLAP, function()
			for _, p in hiddenNew do
				p.LocalTransparencyModifier = 0
			end
			destroyRender(section, old)
			if afterSwap then
				afterSwap()
			end
		end)
	else
		destroyRender(section, old)
		if afterSwap then
			afterSwap()
		end
	end
end

-- Replace a section's special faces (water, ice, glass, lava) right away. `groups` nil = none.
local function setSpecial(section: Section, groups: { [number]: { number } }?)
	local old = section.special
	section.special = if groups and section.alive then SpecialPartsBackend.build(groups, section.origin, renderFolder) else nil
	SpecialPartsBackend.destroy(old)
end

-- Split a mesh result into the opaque part (EditableMesh) and the special groups (Parts).
local function splitResult(result: GreedyMesher.MeshResult): (GreedyMesher.MeshResult, { [number]: { number } }?)
	local opaque: GreedyMesher.MeshResult = { groups = {}, quadCount = 0, faceCount = result.faceCount }
	local special: { [number]: { number } }? = nil
	for tex, quads in result.groups do
		if SpecialPartsBackend.isSpecial(tex) then
			special = special or {}
			(special :: any)[tex] = quads
		else
			opaque.groups[tex] = quads
			opaque.quadCount += #quads // 6
		end
	end
	return opaque, special
end

-- Give a section's live pool mesh back now.
local function releaseLive(section: Section)
	local slot = section.liveSlot
	if slot then
		LiveEditPool.release(slot)
	end
end

-- An afterSwap callback that releases the section's live slot, unless the slot was written again
-- in the meantime (a newer edit is showing on it).
local function releaseLiveAfterSwap(section: Section): (() -> ())?
	local slot = section.liveSlot
	if not slot then
		return nil
	end
	local writes = slot.writes
	return function()
		if section.liveSlot == slot and slot.writes == writes then
			LiveEditPool.release(slot)
		end
	end
end

-- Temporary bake failure (e.g. editable budget momentarily full): keep the current geometry and
-- retry with backoff instead of falling back to Parts.
local function retryLater(section: Section)
	section.failCount += 1
	section.retryAt = os.clock() + math.min(0.5 * 2 ^ (section.failCount - 1), 8)
	section.renderDirty = true
end

-- Hide the old baked parts of every group the live mesh now shows (same frame as the edit).
local function hideCovered(r: Render?, uncovered: { [string]: boolean })
	if not r then
		return
	end
	local parts = r.handle.parts
	local keys = r.handle.keys
	for i, p in parts do
		if not (keys and uncovered[keys[i]]) then
			p.Parent = nil
		end
	end
end

local function fallBackToParts(section: Section)
	section.forceParts = true
	section.failCount += 1
	section.retryAt = os.clock() + Config.EDITABLE_RETRY_SECONDS * 2 ^ math.min(section.failCount - 1, 5)
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
	local slot = section.liveSlot
	if slot and LiveEditPool.canBake(slot, section) then
		return "editable" -- bakes from the live mesh: needs no new EditableMesh
	end
	if section.retryAt > os.clock() then
		return "wait" -- backing off after a temporary failure
	end
	if EditableMeshBackend.canStart(section.editPending) then
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

	-- Just-edited section on a live pool mesh that shows exactly its current contents: bake that
	-- mesh directly (no re-meshing, no extra EditableMesh).
	local slot = section.liveSlot
	if mode == "editable" and slot and LiveEditPool.canBake(slot, section) then
		local version = section.version
		LiveEditPool.bake(slot, function(handle, err)
			if not section.alive or section.version ~= version or section.liveSlot ~= slot then
				if handle then
					EditableMeshBackend.destroy(handle)
				end
				return
			end
			if not handle then
				EditableMeshBackend.stats.lastError = tostring(err)
				retryLater(section)
				return
			end
			section.failCount = 0
			section.retryAt = 0
			if section.editPending then
				section.editPending = false
				ChunkRenderer.stats.swaps += 1
				ChunkRenderer.stats.swapTime += os.clock() - section.editTime
			end
			replaceRender(section, { kind = "editable", handle = handle }, false, releaseLiveAfterSwap(section))
		end)
		return
	end

	section.version += 1
	local version = section.version

	SectionSampler.fill(paddedRender, chunk, neighbors, section.sy)
	local class = GreedyMesher.classify(paddedRender)
	if class ~= "mesh" then
		replaceRender(section, nil)
		releaseLive(section)
		setSpecial(section, nil)
		return
	end

	if mode == "editable" then
		local t = os.clock()
		local full = GreedyMesher.mesh(paddedRender, Scheduler.checkpoint)
		ChunkRenderer.stats.meshTime += os.clock() - t
		ChunkRenderer.stats.sectionsMeshed += 1
		ChunkRenderer.stats.quads += full.quadCount
		if section.version ~= version then
			return -- edited while we were meshing; the newer rebuild handles it
		end
		local result, special = splitResult(full)
		setSpecial(section, special) -- special faces are Parts: show them now
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
				elseif budgetHit and not EditableMeshBackend.isBudgetLimited() then
					retryLater(section) -- static mode: the budget frees up as uploads finish
				else
					fallBackToParts(section)
				end
				return
			end
			section.failCount = 0
			section.retryAt = 0
			if section.editPending then
				section.editPending = false
				ChunkRenderer.stats.swaps += 1
				ChunkRenderer.stats.swapTime += os.clock() - section.editTime
			end
			-- the baked mesh is parented: the live mesh (if any) goes back in the same frame the
			-- baked one becomes fully visible
			replaceRender(section, { kind = "editable", handle = handle }, false, releaseLiveAfterSwap(section))
		end, section.editPending)
	else
		local t = os.clock()
		local handle = PartsBackend.build(paddedRender, section.origin, renderFolder)
		ChunkRenderer.stats.meshTime += os.clock() - t
		ChunkRenderer.stats.sectionsMeshed += 1
		replaceRender(section, { kind = "parts", handle = handle })
		releaseLive(section)
		setSpecial(section, nil) -- the Parts backend draws everything itself
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

-- Rebuild a just-edited section RIGHT NOW (same frame as the click), so a broken block vanishes
-- and a placed block appears instantly: the new geometry is written into a live pooled
-- EditableMesh (LiveEditPool) and the old baked parts it replaces are hidden in the same frame.
-- A priority background job bakes the real mesh; once it's parented (plus the swap overlap) the
-- live mesh goes back to the pool. With no free pool mesh, the old geometry simply stays until
-- the bake (the earlier delayed swap). In Parts mode, Parts are rebuilt directly.
function ChunkRenderer.renderUrgent(section: Section, chunk: any, neighbors: SectionSampler.Neighbors)
	local t = os.clock()
	section.version += 1 -- any in-flight mesh for the old contents is now stale
	SectionSampler.fill(paddedUrgent, chunk, neighbors, section.sy)
	local class = GreedyMesher.classify(paddedUrgent)
	if class ~= "mesh" then
		replaceRender(section, nil)
		releaseLive(section)
		setSpecial(section, nil)
		section.renderDirty = false
	elseif ChunkRenderer.chooseBackend(section) == "parts" then
		local handle = PartsBackend.build(paddedUrgent, section.origin, renderFolder)
		replaceRender(section, { kind = "parts", handle = handle }, true)
		releaseLive(section)
		setSpecial(section, nil)
		section.renderDirty = false
	else
		section.editPending = true
		section.editTime = os.clock()
		local result, special = splitResult(GreedyMesher.mesh(paddedUrgent))
		-- Water/ice/glass/lava are plain Parts: rebuilt on this frame, no hand-over ever.
		setSpecial(section, special)
		local slot = LiveEditPool.acquire(section)
		if slot then
			local uncovered = LiveEditPool.write(slot, section, result)
			hideCovered(section.render, uncovered)
			-- bake in the background (priority), unless the F6 debug toggle keeps the live mesh
			section.renderDirty = not ChunkRenderer.keepTemp
		else
			-- pool exhausted: keep the old geometry until the priority bake replaces it
			section.renderDirty = true
		end
	end
	ChunkRenderer.stats.urgentBuilds += 1
	ChunkRenderer.stats.urgentTime += os.clock() - t
end

-- F6 debug toggle. Turning it off queues bakes for every section still on a live pool mesh.
function ChunkRenderer.setKeepTemp(on: boolean)
	ChunkRenderer.keepTemp = on
	if not on then
		for _, s in LiveEditPool.activeSections() do
			if s.alive then
				s.renderDirty = true
			end
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
	releaseLive(section)
	setSpecial(section, nil)
	section.renderDirty = true
end

function ChunkRenderer.destroySection(section: Section)
	section.alive = false
	replaceRender(section, nil)
	releaseLive(section)
	setSpecial(section, nil)
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
