--!strict
-- One 3D mesh per item type, built on first use and cached (Meshing/ItemExtrude geometry):
--   flat items   the 16x16 icon extruded 1 pixel deep, coloured per vertex (no texture, so every
--                pixel stays perfectly sharp); size 16 x 16 x 1 "pixels"
--   block items  the block's boxes (cube, slab, stairs, wall, fence) textured from the block
--                atlas like the terrain; size 1 x 1 x 1
-- Each mesh is built in an EditableMesh, baked (EditableMeshBackend.upload, the terrain's path)
-- and kept as a template MeshPart; users get clones (`make`), which share the mesh data. Builds
-- run one at a time in the background; until a mesh exists `make` returns nil (callers show a
-- simple stand-in and ask again later).
--
-- Mesh sizes are pinned by two tiny triangles at opposite corners of the full box, so a small
-- icon (a seed) keeps its true size instead of being stretched to fill its MeshPart.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local AssetService = game:GetService("AssetService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local BlockIconGen = require(Shared.Items.BlockIconGen)
local ItemExtrude = require(Shared.Meshing.ItemExtrude)
local TextureAtlas = require(script.Parent.TextureAtlas)
local EditableMeshBackend = require(script.Parent.EditableMeshBackend)

local ItemMeshes = {}
ItemMeshes.stats = { templates = 0, building = 0, failed = 0, triangles = 0 }

local templates: { [string]: MeshPart } = {}
local state: { [string]: string } = {} -- "queued" | "building" | "failed"
local queue: { string } = {}
local working = false

local SHADE = Config.FACE_SHADE
local DIR_SHADE = { SHADE.east, SHADE.west, SHADE.top, SHADE.bottom, SHADE.south, SHADE.north }
local ANCHOR = 0.002

-- "block" (a 3D block shape) or "flat" (an extruded icon).
function ItemMeshes.kind(key: string): string
	local def = ItemRegistry.get(key)
	return if def and BlockIconGen.shapeForItem(def) then "block" else "flat"
end

local function addAnchor(em: any, corner: Vector3, dir: number, color: number)
	local a = em:AddVertex(corner)
	local b = em:AddVertex(corner + Vector3.new(ANCHOR * dir, 0, 0))
	local c = em:AddVertex(corner + Vector3.new(0, ANCHOR * dir, 0))
	local f = em:AddTriangle(a, b, c)
	em:SetFaceColors(f, { color, color, color })
end

-- Fill an EditableMesh with the item's geometry. Returns the triangle count.
local function fill(em: any, key: string): number
	local def = ItemRegistry.get(key)
	if not def then
		return 0
	end
	local normals = {}
	for d = 1, 6 do
		local n = ItemExtrude.NORMALS[d]
		normals[d] = em:AddNormal(Vector3.new(n[1], n[2], n[3]))
	end
	local colorIds: { [number]: number } = {}
	local function colorId(r: number, g: number, b: number): number
		local k = r * 65536 + g * 256 + b
		local id = colorIds[k]
		if not id then
			id = em:AddColor(Color3.fromRGB(r, g, b), 1)
			colorIds[k] = id
		end
		return id
	end
	local tris = 0
	local shape = BlockIconGen.shapeForItem(def)
	local quads: { ItemExtrude.Quad }
	local half: Vector3
	if shape then
		quads = ItemExtrude.boxes(BlockIconGen.SHAPES[shape])
		half = Vector3.new(0.5, 0.5, 0.5)
	else
		local px = TextureAtlas.iconPixels(key)
		quads = if px then ItemExtrude.flat(px) else {}
		half = Vector3.new(8, 8, 0.5)
	end
	local b = BlockRegistry.byId[def.block or 0]
	for _, q in quads do
		local v = q.v
		local ids = {}
		for k = 0, 3 do
			ids[k + 1] = em:AddVertex(Vector3.new(v[k * 3 + 1], v[k * 3 + 2], v[k * 3 + 3]))
		end
		local col: number
		local uvs: { number }? = nil
		if q.c then
			col = colorId(q.c[1], q.c[2], q.c[3])
		else
			local s = DIR_SHADE[q.dir]
			local textured = EditableMeshBackend.texturedMode()
			local base = if b and not textured then BlockRegistry.textureColor(b.faceTexture[q.dir]) else nil
			if base then
				col = colorId(math.floor(base[1] * s + 0.5), math.floor(base[2] * s + 0.5), math.floor(base[3] * s + 0.5))
			else
				local g = math.floor(255 * s + 0.5)
				col = colorId(g, g, g)
			end
			if b and q.st and textured then
				local u0, v0, u1, v1 = TextureAtlas.uvRect(b.faceTexture[q.dir])
				uvs = {}
				for k = 0, 3 do
					local ss, tt = q.st[k * 2 + 1], q.st[k * 2 + 2]
					uvs[k + 1] = em:AddUV(Vector2.new(u0 + (u1 - u0) * ss, v0 + (v1 - v0) * tt))
				end
			end
		end
		local n = normals[q.dir]
		local f1 = em:AddTriangle(ids[1], ids[2], ids[3])
		local f2 = em:AddTriangle(ids[1], ids[3], ids[4])
		em:SetFaceNormals(f1, { n, n, n })
		em:SetFaceNormals(f2, { n, n, n })
		em:SetFaceColors(f1, { col, col, col })
		em:SetFaceColors(f2, { col, col, col })
		if uvs then
			em:SetFaceUVs(f1, { uvs[1], uvs[2], uvs[3] })
			em:SetFaceUVs(f2, { uvs[1], uvs[3], uvs[4] })
		end
		tris += 2
	end
	local white = colorId(255, 255, 255)
	addAnchor(em, -half, 1, white)
	addAnchor(em, half, -1, white)
	return tris
end

local function build(key: string)
	state[key] = "building"
	ItemMeshes.stats.building += 1
	local ok, em = pcall(function()
		return AssetService:CreateEditableMesh()
	end)
	if not ok or not em then
		ItemMeshes.stats.building -= 1
		state[key] = nil -- the editable budget is busy: try again later
		task.wait(0.5)
		table.insert(queue, key)
		return
	end
	local tris = 0
	local fillOk, err = pcall(function()
		tris = fill(em, key)
	end)
	local part: MeshPart? = nil
	local baked = false
	if fillOk then
		local p, upErr, b = EditableMeshBackend.upload(em)
		part, baked = p, b
		if not p then
			err = upErr
		end
	end
	if baked or not part then
		em:Destroy()
	end
	ItemMeshes.stats.building -= 1
	if not part then
		state[key] = "failed"
		ItemMeshes.stats.failed += 1
		warn(`[ItemMeshes] {key}: {err}`)
		return
	end
	local mp = part :: MeshPart
	mp.Name = key
	mp.Anchored = true
	mp.CanCollide = false
	mp.CanQuery = false
	mp.CanTouch = false
	mp.Color = Color3.new(1, 1, 1)
	mp.Material = Enum.Material.SmoothPlastic
	if ItemMeshes.kind(key) == "block" and EditableMeshBackend.texturedMode() then
		pcall(function()
			(mp :: any).TextureContent = TextureAtlas.content
		end)
	end
	templates[key] = mp
	state[key] = nil
	ItemMeshes.stats.templates += 1
	ItemMeshes.stats.triangles += tris
end

local function work()
	if working then
		return
	end
	working = true
	task.spawn(function()
		while #queue > 0 do
			local key = table.remove(queue, 1) :: string
			if not templates[key] and state[key] ~= "failed" then
				build(key)
			end
		end
		working = false
	end)
end

-- The cached template for an item (nil while it's being built; starts the build).
function ItemMeshes.get(key: string): MeshPart?
	local t = templates[key]
	if t then
		return t
	end
	if not state[key] and TextureAtlas.ready and ItemRegistry.get(key) then
		state[key] = "queued"
		table.insert(queue, key)
		work()
	end
	return nil
end

-- A new MeshPart of the item, scaled so one texture pixel is `pixel` studs (flat items) or the
-- block is `blockSize` studs (block items). Nil until the mesh is ready.
function ItemMeshes.make(key: string, pixel: number, blockSize: number): MeshPart?
	local t = ItemMeshes.get(key)
	if not t then
		return nil
	end
	local p = t:Clone()
	p.Size = if ItemMeshes.kind(key) == "block" then Vector3.one * blockSize else Vector3.new(16, 16, 1) * pixel
	return p
end

-- A plain stand-in while the mesh is built (the item's colour).
function ItemMeshes.standIn(key: string, pixel: number, blockSize: number): Part
	local def = ItemRegistry.get(key)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Material = Enum.Material.SmoothPlastic
	local c = if def then def.color else { 200, 200, 200 }
	p.Color = Color3.fromRGB(c[1], c[2], c[3])
	p.Size = if ItemMeshes.kind(key) == "block" then Vector3.one * blockSize else Vector3.new(12 * pixel, 12 * pixel, pixel)
	return p
end

return ItemMeshes
