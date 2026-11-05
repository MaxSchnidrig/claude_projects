--!strict
-- Primary render backend: greedy quads -> EditableMesh -> MeshPart, one MeshPart per texture
-- per section.
--
-- Building the EditableMesh is synchronous Luau work (runs inside a scheduler job, with
-- checkpoints). Turning it into a MeshPart (AssetService:CreateMeshPartAsync) yields, so it runs
-- on separate threads with a cap on concurrent uploads.
--
-- Failure modes we handle:
--   * EditableMesh API unavailable or the device memory budget is exhausted -> the build reports
--     an error and ChunkRenderer falls back to the Parts backend for that section.

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

export type Handle = { parts: { BasePart }, meshes: { any }, triangles: number, counted: boolean }

local Backend = {}
Backend.stats = { meshParts = 0, triangles = 0, uploadsInFlight = 0, uploadsQueued = 0, failures = 0, lastError = "" }

local MESH_OPTIONS = {
	CollisionFidelity = Enum.CollisionFidelity.Box, -- cheapest; render parts never collide
	RenderFidelity = Enum.RenderFidelity.Precise, -- no automatic LOD (it would punch holes)
}

type Upload = { em: any, done: (MeshPart?, string?) -> () }
local queue: { Upload } = {}

-- Fill one EditableMesh with all quads of a texture group. Returns triangle count and the
-- centre (block units) that the vertices were made relative to.
local function fillMesh(em: any, tex: number, quads: { number }): (number, Vector3)
	-- Bounding box first so vertices can be centred on the part's origin.
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	local n = #quads
	for q = 1, n, 6 do
		local c = GreedyMesher.quadCorners(quads[q], quads[q + 1], quads[q + 2], quads[q + 3], quads[q + 4], quads[q + 5])
		for v = 1, 12, 3 do
			minX, maxX = math.min(minX, c[v]), math.max(maxX, c[v])
			minY, maxY = math.min(minY, c[v + 1]), math.max(maxY, c[v + 1])
			minZ, maxZ = math.min(minZ, c[v + 2]), math.max(maxZ, c[v + 2])
		end
	end
	-- Flat groups (e.g. only top faces) have zero thickness; pad so the MeshPart size is valid.
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
	local cx, cy, cz = (minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2

	local style = RenderStyle.forTexture(tex)
	local normalIds = {}
	local colorIds = {}
	local uvIds: { [number]: number } = {}
	local function uv(u: number, v: number): number
		local key = (u + 512) * 2048 + (v + 512)
		local id = uvIds[key]
		if not id then
			id = em:AddUV(Vector2.new(u, v))
			uvIds[key] = id
		end
		return id
	end

	local flip = Config.FLIP_WINDING
	local tris = 0
	for q = 1, n, 6 do
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
		tris += 2
	end
	return tris, Vector3.new(cx, cy, cz)
end

-- Build all texture groups of a section. Calls `onDone(handle, nil)` once every MeshPart exists
-- (parented to `folder`), or `onDone(nil, errorMessage)` if anything failed (partial work is
-- cleaned up).
function Backend.build(
	result: GreedyMesher.MeshResult,
	originStuds: Vector3,
	folder: Instance,
	checkpoint: () -> (),
	onDone: (Handle?, string?) -> ()
)
	local built: { { em: any, tex: number, center: Vector3, tris: number } } = {}
	local ok, err = pcall(function()
		for tex, quads in result.groups do
			local em = AssetService:CreateEditableMesh()
			if not em then
				error("CreateEditableMesh returned nil (memory budget?)")
			end
			local tris, center = fillMesh(em, tex, quads)
			table.insert(built, { em = em, tex = tex, center = center, tris = tris })
			checkpoint()
		end
	end)
	if not ok then
		for _, b in built do
			b.em:Destroy()
		end
		Backend.stats.failures += 1
		Backend.stats.lastError = tostring(err)
		onDone(nil, tostring(err))
		return
	end
	if #built == 0 then
		onDone({ parts = {}, meshes = {}, triangles = 0, counted = false }, nil)
		return
	end

	local handle: Handle = { parts = {}, meshes = {}, triangles = 0, counted = false }
	local remaining = #built
	local failed: string? = nil
	for _, b in built do
		table.insert(queue, {
			em = b.em,
			done = function(part: MeshPart?, uploadErr: string?)
				if part then
					local style = RenderStyle.forTexture(b.tex)
					part.Anchored = true
					part.CanCollide = false
					part.CanQuery = false
					part.CanTouch = false
					part.CastShadow = true
					part.Material = style.material
					part.Color = if Config.USE_VERTEX_COLORS then Color3.new(1, 1, 1) else style.color
					part.Transparency = style.transparency
					part.CFrame = CFrame.new(originStuds + b.center * BS)
					table.insert(handle.parts, part)
					handle.triangles += b.tris
				else
					failed = uploadErr or "CreateMeshPartAsync failed"
				end
				table.insert(handle.meshes, b.em)
				remaining -= 1
				if remaining == 0 then
					if failed then
						Backend.destroy(handle)
						Backend.stats.failures += 1
						Backend.stats.lastError = failed :: string
						onDone(nil, failed)
					else
						for _, p in handle.parts do
							p.Parent = folder
						end
						Backend.stats.meshParts += #handle.parts
						Backend.stats.triangles += handle.triangles
						handle.counted = true
						onDone(handle, nil)
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
	for _, em in handle.meshes do
		em:Destroy()
	end
	table.clear(handle.parts)
	table.clear(handle.meshes)
	handle.triangles = 0
end

-- Call every frame: starts queued uploads up to the concurrency cap.
function Backend.pump()
	while Backend.stats.uploadsInFlight < Config.MAX_MESH_UPLOADS_IN_FLIGHT and #queue > 0 do
		local job = table.remove(queue, 1) :: Upload
		Backend.stats.uploadsInFlight += 1
		task.spawn(function()
			local ok, res = pcall(function()
				return AssetService:CreateMeshPartAsync(Content.fromObject(job.em), MESH_OPTIONS)
			end)
			Backend.stats.uploadsInFlight -= 1
			if ok and res then
				job.done(res :: MeshPart, nil)
			else
				job.done(nil, tostring(res))
			end
		end)
	end
	Backend.stats.uploadsQueued = #queue
end

return Backend
