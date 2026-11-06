--!strict
-- Instant edits through live EditableMeshes.
--
-- A small pool of live EditableMeshes, each already attached to a MeshPart (created once at
-- startup). When the player breaks or places a block, the edited section's new geometry is
-- written straight into a pooled mesh on the same frame. It's the same mesh type, vertex colours
-- and material as the baked terrain, so it looks identical. The section's old baked MeshParts
-- for the groups the pool covers are hidden in that same frame.
-- Meanwhile the normal background job bakes a static mesh for the section; once that is parented
-- (plus the usual overlap) the pooled mesh is cleared and returned to the pool.
--
-- Each pool slot has one live mesh per render group it covers (opaque terrain, water). Groups a
-- slot doesn't cover (lava, ice, glass) keep showing the section's old baked parts until the bake.
--
-- Fixed bounds: two tiny anchor triangles sit at opposite corners of the 16^3 section, so the
-- mesh's bounding box never changes when geometry is rewritten (a MeshPart sizes itself to the
-- mesh bounds; changing them could rescale what's drawn).
--
-- Budget: pool meshes count against the client's editable-memory budget. If creating them fails,
-- the pool simply ends up smaller (or empty) and edits fall back to the delayed swap.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local GreedyMesher = require(Shared.Meshing.GreedyMesher)
local EditableMeshBackend = require(script.Parent.EditableMeshBackend)
local RenderStyle = require(script.Parent.RenderStyle)

local BS = Config.BLOCK_SIZE
local SS = Config.SECTION_SIZE
local CENTER = Vector3.new(SS / 2, SS / 2, SS / 2) -- block units, section-local
local HALF = SS / 2 * BS -- studs
local ANCHOR = 0.01 -- studs

type Sub = { em: any, part: MeshPart, faces: { number } }
export type Slot = {
	subs: { [string]: Sub },
	section: any?, -- ChunkRenderer.Section currently shown by this slot
	lastUsed: number,
	releaseToken: number,
}

local LiveEditPool = {}
LiveEditPool.stats = {
	slots = 0,
	meshes = 0, -- live EditableMeshes held by the pool
	inUse = 0,
	writes = 0,
	writeTime = 0,
	noSlot = 0, -- edits that found no free slot (used the delayed swap)
	createError = "",
}

local slots: { Slot } = {}
local folder: Instance

-- Render groups the pool covers, as EditableMeshBackend group keys.
local function coveredGroups(): { { key: string, tex: number } }
	local list = {}
	for _, texKey in { "stone", "water" } do
		local tex = BlockRegistry.textureIndex[texKey]
		table.insert(list, { key = EditableMeshBackend.groupKey(tex), tex = tex })
	end
	return list
end

local function addAnchor(em: any, corner: Vector3, dir: number)
	local a = em:AddVertex(corner)
	local b = em:AddVertex(corner + Vector3.new(ANCHOR * dir, 0, 0))
	local c = em:AddVertex(corner + Vector3.new(0, ANCHOR * dir, 0))
	em:AddTriangle(a, b, c)
end

local function createSlot(): Slot?
	local slot: Slot = { subs = {}, section = nil, lastUsed = 0, releaseToken = 0 }
	for _, g in coveredGroups() do
		local ok, em = pcall(function()
			return AssetService:CreateEditableMesh()
		end)
		if not ok or not em then
			LiveEditPool.stats.createError = if ok then "CreateEditableMesh returned nil (budget)" else tostring(em)
			for _, sub in slot.subs do
				sub.part:Destroy()
				sub.em:Destroy()
				LiveEditPool.stats.meshes -= 1
			end
			return nil
		end
		LiveEditPool.stats.meshes += 1
		addAnchor(em, Vector3.new(-HALF, -HALF, -HALF), 1)
		addAnchor(em, Vector3.new(HALF, HALF, HALF), -1)
		local ok2, part = pcall(function()
			return AssetService:CreateMeshPartAsync(Content.fromObject(em), EditableMeshBackend.MESH_OPTIONS)
		end)
		if not ok2 or not part then
			LiveEditPool.stats.createError = `CreateMeshPartAsync: {part}`
			em:Destroy()
			LiveEditPool.stats.meshes -= 1
			for _, sub in slot.subs do
				sub.part:Destroy()
				sub.em:Destroy()
				LiveEditPool.stats.meshes -= 1
			end
			return nil
		end
		local style = RenderStyle.forTexture(g.tex)
		local mp = part :: MeshPart
		mp.Name = "LiveEdit"
		mp.Anchored = true
		mp.CanCollide = false
		mp.CanQuery = false
		mp.CanTouch = false
		mp.CastShadow = true
		mp.Material = style.material
		mp.Color = if Config.USE_VERTEX_COLORS then Color3.new(1, 1, 1) else style.color
		mp.Transparency = style.transparency
		slot.subs[g.key] = { em = em, part = mp, faces = {} }
	end
	return slot
end

function LiveEditPool.init(renderFolder: Instance)
	folder = renderFolder
	task.spawn(function()
		for _ = 1, Config.LIVE_EDIT_SLOTS do
			local slot = createSlot()
			if not slot then
				warn(`[LiveEditPool] pool stopped at {#slots} slot(s): {LiveEditPool.stats.createError}`)
				break
			end
			table.insert(slots, slot)
			LiveEditPool.stats.slots = #slots
		end
	end)
end

local function clear(slot: Slot)
	for _, sub in slot.subs do
		for _, f in sub.faces do
			sub.em:RemoveFace(f)
		end
		table.clear(sub.faces)
		sub.em:RemoveUnused() -- drop now-unused vertices/normals/UVs/colours (anchors stay)
	end
end

-- The slot already showing this section, else a free one, else nil (pool exhausted).
function LiveEditPool.acquire(section: any): Slot?
	if section.liveSlot then
		return section.liveSlot
	end
	for _, slot in slots do
		if slot.section == nil then
			slot.section = section
			section.liveSlot = slot
			LiveEditPool.stats.inUse += 1
			return slot
		end
	end
	LiveEditPool.stats.noSlot += 1
	return nil
end

-- Rewrite the slot's live meshes with `result` (section geometry). Same frame, synchronous.
-- Returns the set of group keys the slot could NOT show (caller keeps old parts for those).
function LiveEditPool.write(slot: Slot, section: any, result: GreedyMesher.MeshResult): { [string]: boolean }
	local t = os.clock()
	slot.releaseToken += 1 -- cancels any pending release from an earlier hand-over
	slot.lastUsed = t
	clear(slot)
	local uncovered: { [string]: boolean } = {}
	local caches: { [string]: { normals: { [number]: number }, uvs: { [number]: number } } } = {}
	for tex, quads in result.groups do
		local key = EditableMeshBackend.groupKey(tex)
		local sub = slot.subs[key]
		if sub then
			local c = caches[key]
			if not c then
				c = { normals = {}, uvs = {} }
				caches[key] = c
			end
			EditableMeshBackend.appendQuads(sub.em, tex, quads, CENTER, c.normals, c.uvs, sub.faces)
		else
			uncovered[key] = true
		end
	end
	local cf = CFrame.new(section.origin + CENTER * BS)
	for _, sub in slot.subs do
		sub.part.CFrame = cf
		sub.part.Parent = if #sub.faces > 0 then folder else nil
	end
	LiveEditPool.stats.writes += 1
	LiveEditPool.stats.writeTime += os.clock() - t
	return uncovered
end

-- Return a slot to the pool now.
function LiveEditPool.release(slot: Slot)
	slot.releaseToken += 1
	clear(slot)
	for _, sub in slot.subs do
		sub.part.Parent = nil
	end
	if slot.section then
		slot.section.liveSlot = nil
		slot.section = nil
		LiveEditPool.stats.inUse -= 1
	end
end

-- Return the slot after `delay` seconds, unless it's written again in the meantime.
function LiveEditPool.releaseAfter(slot: Slot, delay: number)
	slot.releaseToken += 1
	local token = slot.releaseToken
	task.delay(delay, function()
		if slot.releaseToken == token then
			LiveEditPool.release(slot)
		end
	end)
end

-- Sections currently shown by pool meshes (for the F6 toggle).
function LiveEditPool.activeSections(): { any }
	local list = {}
	for _, slot in slots do
		if slot.section then
			table.insert(list, slot.section)
		end
	end
	return list
end

return LiveEditPool
