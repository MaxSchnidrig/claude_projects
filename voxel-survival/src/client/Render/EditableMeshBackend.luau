--!strict
-- Primary render backend: greedy quads -> EditableMesh -> (baked static content) -> MeshPart.
--
-- WHY BAKING: on live clients the editable-object memory budget is small (forum reports put it
-- around 8 meshes), and CreateEditableMesh returns nil once it is used up. Phase 1 kept every
-- EditableMesh alive for as long as its section existed, so the budget ran out after 8 MeshParts.
-- Now each mesh is:
--   1. built in an EditableMesh (synchronous, inside a scheduler job),
--   2. baked with AssetService:CreateDataModelContentAsync into static content,
--   3. turned into a MeshPart with CreateMeshPartAsync(staticContent),
--   4. destroyed immediately, which frees its share of the budget.
-- So only meshes that are *in flight* count against the budget (capped by MAX_LIVE_EDITABLE).
--
-- If baking isn't available (API missing or failing), we fall back to "live" mode: the MeshPart
-- references the EditableMesh directly, so the mesh must stay alive. The budget then limits how
-- many sections can be meshes, and ChunkRenderer keeps those for the sections nearest the player.
--
-- Grouping: with vertex colours on, all opaque textures of a section share ONE mesh (colours are
-- per vertex); only different transparency/material needs a separate MeshPart. That's typically
-- 1-2 MeshParts per section instead of one per texture.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local GreedyMesher = require(Shared.Meshing.GreedyMesher)
local RenderStyle = require(script.Parent.RenderStyle)

local BS = Config.BLOCK_SIZE
local SHADE = Config.FACE_SHADE
local DIR_SHADE = { SHADE.east, SHADE.west, SHADE.top, SHADE.bottom, SHADE.south, SHADE.north }
local DIR_NORMALS = {
	Vector3.new(1, 0, 0),
	Vector3.new(-1, 0, 0),
	Vector3.new(0, 1, 0),
	Vector3.new(0, -1, 0),
	Vector3.new(0, 0, 1),
	Vector3.new(0, 0, -1),
}
-- Rough per-element cost for the overlay's memory estimate of live meshes (not an official figure).
local EST_BYTES_PER_VERTEX = 48
local EST_BYTES_PER_TRIANGLE = 48

export type Handle = {
	parts: { BasePart },
	meshes: { any }, -- EditableMeshes kept alive (live mode only)
	triangles: number,
	liveBytes: number,
	counted: boolean,
}

local Backend = {}
Backend.stats = {
	meshParts = 0,
	triangles = 0,
	liveEditable = 0, -- EditableMeshes currently alive (building, queued, uploading, or live mode)
	peakLiveEditable = 0,
	liveBytesEst = 0,
	uploadsInFlight = 0,
	uploadsQueued = 0,
	failures = 0,
	budgetHits = 0,
	lastError = "",
	-- "unknown" until the first upload, then "static" (baking works) or "live" (it doesn't)
	bakeMode = "unknown",
	bakeError = "",
	uploadRetries = 0,
	-- live mode: how many live meshes fit before CreateEditableMesh returned nil
	learnedCap = nil :: number?,
}

local MESH_OPTIONS = {
	CollisionFidelity = Enum.CollisionFidelity.Box, -- cheapest; render parts never collide
	RenderFidelity = Enum.RenderFidelity.Precise, -- no automatic LOD (it would punch holes)
}

type Upload = { em: any, liveBytes: number, done: (MeshPart?, string?, boolean) -> () }
local queue: { Upload } = {}

local function trackCreate()
	local s = Backend.stats
	s.liveEditable += 1
	if s.liveEditable > s.peakLiveEditable then
		s.peakLiveEditable = s.liveEditable
	end
end

local function destroyEditable(em: any, liveBytes: number)
	em:Destroy()
	Backend.stats.liveEditable -= 1
	Backend.stats.liveBytesEst -= liveBytes
end

-- Can a new section start building right now without risking the budget?
function Backend.canStart(): boolean
	local s = Backend.stats
	if s.bakeMode == "live" then
		return s.learnedCap == nil or s.liveEditable < (s.learnedCap :: number)
	end
	return s.liveEditable < Config.MAX_LIVE_EDITABLE
end

-- True when meshes can't be baked and the live budget is exhausted: most sections end up as Parts.
function Backend.isBudgetLimited(): boolean
	local s = Backend.stats
	return s.bakeMode == "live" and s.learnedCap ~= nil
end

-- Group key for a texture: textures with equal render properties can share one mesh.
local function groupKey(tex: number): string
	if not Config.USE_VERTEX_COLORS then
		return "t" .. tex -- part colour carries the texture colour, so one texture per mesh
	end
	local style = RenderStyle.forTexture(tex)
	return `{style.transparency}:{style.material.Name}`
end

-- Append all quads of one texture to an EditableMesh. Returns vertices/triangles added.
local function appendQuads(
	em: any,
	tex: number,
	quads: { number },
	center: Vector3,
	normalIds: { [number]: number },
	uvIds: { [number]: number }
): (number, number)
	local style = RenderStyle.forTexture(tex)
	local colorIds: { [number]: number } = {}
	local function uv(u: number, v: number): number
		local key = (u + 512) * 2048 + (v + 512)
		local id = uvIds[key]
		if not id then
			id = em:AddUV(Vector2.new(u, v))
			uvIds[key] = id
		end
		return id
	end

	local cx, cy, cz = center.X, center.Y, center.Z
	local flip = Config.FLIP_WINDING
	local verts, tris = 0, 0
	for q = 1, #quads, 6 do
		local d = quads[q]
		local c = GreedyMesher.quadCorners(d, quads[q + 1], quads[q + 2], quads[q + 3], quads[q + 4], quads[q + 5])
		local vIds = table.create(4, 0)
		local uvs = table.create(4, 0)
		for k = 0, 3 do
			local x, y, z = c[k * 3 + 1], c[k * 3 + 2], c[k * 3 + 3]
			vIds[k + 1] = em:AddVertex(Vector3.new((x - cx) * BS, (y - cy) * BS, (z - cz) * BS))
			-- World-aligned UVs: one texture tile per block, "up" is +Y on side faces.
			if d <= 2 then
				uvs[k + 1] = uv(z, -y)
			elseif d >= 5 then
				uvs[k + 1] = uv(x, -y)
			else
				uvs[k + 1] = uv(x, z)
			end
		end
		local nId = normalIds[d]
		if not nId then
			nId = em:AddNormal(DIR_NORMALS[d])
			normalIds[d] = nId
		end
		local colId = colorIds[d]
		if not colId then
			local s = DIR_SHADE[d]
			local col = if Config.USE_VERTEX_COLORS
				then Color3.new(style.color.R * s, style.color.G * s, style.color.B * s)
				else Color3.new(s, s, s)
			colId = em:AddColor(col, 1)
			colorIds[d] = colId
		end
		local a, b, c2, e = vIds[1], vIds[2], vIds[3], vIds[4]
		local ua, ub, uc, ue = uvs[1], uvs[2], uvs[3], uvs[4]
		local f1, f2
		if flip then
			f1 = em:AddTriangle(a, c2, b)
			f2 = em:AddTriangle(a, e, c2)
			em:SetFaceUVs(f1, { ua, uc, ub })
			em:SetFaceUVs(f2, { ua, ue, uc })
		else
			f1 = em:AddTriangle(a, b, c2)
			f2 = em:AddTriangle(a, c2, e)
			em:SetFaceUVs(f1, { ua, ub, uc })
			em:SetFaceUVs(f2, { ua, uc, ue })
		end
		em:SetFaceNormals(f1, { nId, nId, nId })
		em:SetFaceNormals(f2, { nId, nId, nId })
		em:SetFaceColors(f1, { colId, colId, colId })
		em:SetFaceColors(f2, { colId, colId, colId })
		verts += 4
		tris += 2
	end
	return verts, tris
end

-- Bounding-box centre (block units) of a set of texture groups, padded so flat groups still get
-- a valid MeshPart size.
local function groupCenter(texList: { number }, groups: { [number]: { number } }): Vector3
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, tex in texList do
		local quads = groups[tex]
		for q = 1, #quads, 6 do
			local c = GreedyMesher.quadCorners(quads[q], quads[q + 1], quads[q + 2], quads[q + 3], quads[q + 4], quads[q + 5])
			for v = 1, 12, 3 do
				minX, maxX = math.min(minX, c[v]), math.max(maxX, c[v])
				minY, maxY = math.min(minY, c[v + 1]), math.max(maxY, c[v + 1])
				minZ, maxZ = math.min(minZ, c[v + 2]), math.max(maxZ, c[v + 2])
			end
		end
	end
	local PAD = 0.05
	if maxX - minX < PAD then
		minX -= PAD; maxX += PAD
	end
	if maxY - minY < PAD then
		minY -= PAD; maxY += PAD
	end
	if maxZ - minZ < PAD then
		minZ -= PAD; maxZ += PAD
	end
	return Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
end

-- Build all meshes of a section. Calls `onDone(handle, nil, false)` once every MeshPart exists
-- (parented to `folder`), or `onDone(nil, errorMessage, isBudgetError)` on failure (all partial
-- work is cleaned up).
function Backend.build(
	result: GreedyMesher.MeshResult,
	originStuds: Vector3,
	folder: Instance,
	checkpoint: () -> (),
	onDone: (Handle?, string?, boolean) -> ()
)
	-- Group textures that can share a mesh.
	local byKey: { [string]: { number } } = {}
	local keys: { string } = {}
	for tex in result.groups do
		local k = groupKey(tex)
		if not byKey[k] then
			byKey[k] = {}
			table.insert(keys, k)
		end
		table.insert(byKey[k], tex)
	end

	type Built = { em: any, center: Vector3, tris: number, liveBytes: number, style: RenderStyle.Style }
	local built: { Built } = {}
	local budgetHit = false
	local ok, err = pcall(function()
		for _, k in keys do
			local texList = byKey[k]
			local em = AssetService:CreateEditableMesh()
			if not em then
				budgetHit = true
				error("CreateEditableMesh returned nil: editable memory budget exhausted")
			end
			trackCreate()
			local center = groupCenter(texList, result.groups)
			local normalIds, uvIds = {}, {}
			local verts, tris = 0, 0
			-- Register immediately so cleanup destroys it even if filling errors.
			local entry: Built = { em = em, center = center, tris = 0, liveBytes = 0, style = RenderStyle.forTexture(texList[1]) }
			table.insert(built, entry)
			for _, tex in texList do
				local v, t = appendQuads(em, tex, result.groups[tex], center, normalIds, uvIds)
				verts += v
				tris += t
			end
			entry.tris = tris
			entry.liveBytes = verts * EST_BYTES_PER_VERTEX + tris * EST_BYTES_PER_TRIANGLE
			Backend.stats.liveBytesEst += entry.liveBytes
			checkpoint()
		end
	end)
	if not ok then
		for _, b in built do
			destroyEditable(b.em, b.liveBytes)
		end
		Backend.stats.failures += 1
		if budgetHit then
			Backend.stats.budgetHits += 1
			if Backend.stats.bakeMode == "live" then
				-- learn how many live meshes fit on this device
				Backend.stats.learnedCap = math.max(1, Backend.stats.liveEditable)
			end
		end
		Backend.stats.lastError = tostring(err)
		onDone(nil, tostring(err), budgetHit)
		return
	end
	if #built == 0 then
		onDone({ parts = {}, meshes = {}, triangles = 0, liveBytes = 0, counted = false }, nil, false)
		return
	end

	local handle: Handle = { parts = {}, meshes = {}, triangles = 0, liveBytes = 0, counted = false }
	local remaining = #built
	local failed: string? = nil
	for _, b in built do
		table.insert(queue, {
			em = b.em,
			liveBytes = b.liveBytes,
			done = function(part: MeshPart?, uploadErr: string?, baked: boolean)
				if part then
					part.Anchored = true
					part.CanCollide = false
					part.CanQuery = false
					part.CanTouch = false
					part.CastShadow = true
					part.Material = b.style.material
					part.Color = if Config.USE_VERTEX_COLORS then Color3.new(1, 1, 1) else b.style.color
					part.Transparency = b.style.transparency
					part.CFrame = CFrame.new(originStuds + b.center * BS)
					table.insert(handle.parts, part)
					handle.triangles += b.tris
				else
					failed = uploadErr or "mesh upload failed"
				end
				if baked then
					destroyEditable(b.em, b.liveBytes) -- static content now; free the budget
				else
					table.insert(handle.meshes, b.em) -- live mode: the MeshPart still needs it
					handle.liveBytes += b.liveBytes
				end
				remaining -= 1
				if remaining == 0 then
					if failed then
						Backend.destroy(handle)
						Backend.stats.failures += 1
						Backend.stats.lastError = failed :: string
						onDone(nil, failed, false)
					else
						for _, p in handle.parts do
							p.Parent = folder
						end
						Backend.stats.meshParts += #handle.parts
						Backend.stats.triangles += handle.triangles
						handle.counted = true
						onDone(handle, nil, false)
					end
				end
			end,
		})
	end
end

function Backend.destroy(handle: Handle)
	if handle.counted then
		Backend.stats.meshParts -= #handle.parts
		Backend.stats.triangles -= handle.triangles
		handle.counted = false
	end
	for _, p in handle.parts do
		p:Destroy()
	end
	-- Live-mode meshes: per-mesh byte estimates aren't tracked per handle entry, so release the
	-- handle's total once.
	for _, em in handle.meshes do
		em:Destroy()
		Backend.stats.liveEditable -= 1
	end
	Backend.stats.liveBytesEst -= handle.liveBytes
	table.clear(handle.parts)
	table.clear(handle.meshes)
	handle.triangles = 0
	handle.liveBytes = 0
end

-- Failure bookkeeping: every distinct reason is counted and printed to Output once, so silent
-- fallbacks can't hide (Phase 1.1 test showed many Parts sections with no visible error).
Backend.stats.failReasons = {} :: { [string]: number }
local function noteFailure(reason: string)
	local key = string.sub(reason, 1, 120)
	local reasons = Backend.stats.failReasons
	if not reasons[key] then
		warn(`[EditableMeshBackend] mesh upload failed: {reason}`)
	end
	reasons[key] = (reasons[key] or 0) + 1
end

-- One attempt to turn an EditableMesh into a MeshPart. Returns (part, error, apiMissing).
local function attempt(em: any): (MeshPart?, string?, boolean)
	local s = Backend.stats
	if s.bakeMode ~= "live" then
		local ok, res, content = pcall(function()
			return AssetService:CreateDataModelContentAsync(Content.fromObject(em))
		end)
		if not ok then
			-- The baking API itself is missing or not allowed here.
			return nil, `CreateDataModelContentAsync error: {res}`, true
		end
		if res ~= Enum.CreateContentResult.Success then
			-- The API works but refused this one (e.g. StorageLimitExceeded).
			s.bakeError = `CreateDataModelContentAsync returned {res}`
			return nil, s.bakeError, false
		end
		local ok2, part = pcall(function()
			return AssetService:CreateMeshPartAsync(content, MESH_OPTIONS)
		end)
		if ok2 and part then
			s.bakeMode = "static"
			return part :: MeshPart, nil, false
		end
		return nil, `CreateMeshPartAsync(baked) error: {part}`, false
	end
	local ok, part = pcall(function()
		return AssetService:CreateMeshPartAsync(Content.fromObject(em), MESH_OPTIONS)
	end)
	if ok and part then
		return part :: MeshPart, nil, false
	end
	return nil, `CreateMeshPartAsync(live) error: {part}`, false
end

local UPLOAD_ATTEMPTS = 3
local RETRY_DELAYS = { 0.5, 1.5 }

-- Turn an EditableMesh into a MeshPart, retrying transient failures (e.g. throttling).
-- Returns (part, error, baked). `baked` = the MeshPart no longer needs the EditableMesh.
local function upload(em: any): (MeshPart?, string?, boolean)
	local s = Backend.stats
	local lastErr = ""
	for i = 1, UPLOAD_ATTEMPTS do
		local part, err, apiMissing = attempt(em)
		if part then
			return part, nil, s.bakeMode == "static"
		end
		lastErr = err or "unknown"
		noteFailure(lastErr)
		if apiMissing and s.bakeMode ~= "live" then
			s.bakeError = lastErr
			warn(`[EditableMeshBackend] baking unavailable; using live EditableMeshes ({lastErr})`)
			s.bakeMode = "live"
			-- retry immediately in live mode (doesn't consume an attempt's delay)
		elseif i < UPLOAD_ATTEMPTS then
			s.uploadRetries += 1
			task.wait(RETRY_DELAYS[i])
		end
	end
	return nil, lastErr, s.bakeMode == "static"
end

-- Call every frame: starts queued uploads up to the concurrency cap.
function Backend.pump()
	while Backend.stats.uploadsInFlight < Config.MAX_MESH_UPLOADS_IN_FLIGHT and #queue > 0 do
		local job = table.remove(queue, 1) :: Upload
		Backend.stats.uploadsInFlight += 1
		task.spawn(function()
			local part, err, baked = upload(job.em)
			Backend.stats.uploadsInFlight -= 1
			job.done(part, err, baked)
		end)
	end
	Backend.stats.uploadsQueued = #queue
end

return Backend
