--!strict
-- Builds ROCRAFT's textures on the client from the generated 16x16 art (Blocks/TextureGen,
-- Items/ItemIconGen):
--
--   block atlas  every block texture + 10 crack stages, each 16x16 texture scaled up 7x into a
--                128 px cell with an 8 px border copied from its edges. Roblox filters 3D textures
--                (no nearest-neighbour option), so the big scale keeps every pixel sharp and the
--                border stops neighbouring cells bleeding in (also in smaller mip levels).
--   icon sheet   one 16x16 icon per non-block item, for UI (ImageLabels use Pixelated resampling)
--
-- Both are EditableImages baked to static content with CreateDataModelContentAsync (frees the
-- editable-memory budget); if baking isn't available they stay live.

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local TexturePalette = require(Shared.Blocks.TexturePalette)
local TextureGen = require(Shared.Blocks.TextureGen)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local ItemIconGen = require(Shared.Items.ItemIconGen)
local Config = require(Shared.Config)

local TextureAtlas = {}
TextureAtlas.ready = false
TextureAtlas.content = nil :: Content?
TextureAtlas.iconContent = nil :: Content?
TextureAtlas.size = 1024
TextureAtlas.stats = { baked = false, error = "" }

local SIZE = Config.ATLAS_SIZE
local SCALE = Config.ATLAS_SCALE
local GUTTER = Config.ATLAS_GUTTER
local CELL = 16 * SCALE + 2 * GUTTER
local COLS = SIZE // CELL
TextureAtlas.capacity = COLS * COLS

local cells: { [number]: number } = {} -- texture index -> cell number (0-based)
local crackCell: { [number]: number } = {} -- stage -> cell
local pixels: { [number]: buffer } = {} -- texture index -> 16x16 RGBA (particles, held blocks)
local iconCells: { [string]: number } = {}
local ICON_COLS = 16

local function bake(image: any): Content
	local ok, res, content = pcall(function()
		return AssetService:CreateDataModelContentAsync(Content.fromObject(image))
	end)
	if ok and res == Enum.CreateContentResult.Success and content then
		image:Destroy()
		TextureAtlas.stats.baked = true
		return content
	end
	TextureAtlas.stats.error = if ok then tostring(res) else tostring(res)
	return Content.fromObject(image) -- keep it live
end

local function blit(dst: buffer, cell: number, src: buffer)
	local cx, cy = (cell % COLS) * CELL, (cell // COLS) * CELL
	for y = 0, CELL - 1 do
		local sy = math.clamp((y - GUTTER) // SCALE, 0, 15)
		for x = 0, CELL - 1 do
			local sx = math.clamp((x - GUTTER) // SCALE, 0, 15)
			local so = (sy * 16 + sx) * 4
			local d = ((cy + y) * SIZE + cx + x) * 4
			buffer.writeu32(dst, d, buffer.readu32(src, so))
		end
	end
end

function TextureAtlas.init()
	local data = buffer.create(SIZE * SIZE * 4)
	local n = 0
	local overflow = 0
	-- the next free cell; if the atlas is full, extra textures share the last cell (wrong
	-- picture, but the rest of the world stays textured) and we warn once
	local function nextCell(img: buffer): number
		if n >= COLS * COLS then
			overflow += 1
			return COLS * COLS - 1
		end
		blit(data, n, img)
		n += 1
		return n - 1
	end
	local byBase: { [string]: number } = {}
	for index, key in BlockRegistry.textureKeys do
		local img = TextureGen.generate(key, TexturePalette[key])
		pixels[index] = img
		local base = TextureGen.baseKey(key)
		local shared = byBase[base]
		if shared then
			cells[index] = shared -- fluid levels share their fluid's cell
		else
			local c = nextCell(img)
			cells[index] = c
			byBase[base] = c
		end
	end
	for stage = 0, TextureGen.CRACK_STAGES - 1 do
		crackCell[stage] = nextCell(TextureGen.crack(stage))
	end
	if overflow > 0 then
		warn(`[TextureAtlas] {overflow} textures don't fit in the atlas ({COLS * COLS} slots); raise Config.ATLAS capacity`)
	end
	local image = AssetService:CreateEditableImage({ Size = Vector2.new(SIZE, SIZE) })
	if not image then
		warn("[TextureAtlas] CreateEditableImage returned nil; blocks stay untextured")
		return
	end
	image:WritePixelsBuffer(Vector2.zero, Vector2.new(SIZE, SIZE), data)
	TextureAtlas.content = bake(image)

	-- item icons
	local items = {}
	for _, def in ItemRegistry.list() do
		if not def.block or def.icon then
			table.insert(items, def)
		end
	end
	local rows = math.max(1, math.ceil(#items / ICON_COLS))
	local w, h = ICON_COLS * 16, rows * 16
	local sheet = buffer.create(w * h * 4)
	for i, def in items do
		local cell = i - 1
		iconCells[def.key] = cell
		local icon = ItemIconGen.generate(def)
		local ox, oy = (cell % ICON_COLS) * 16, (cell // ICON_COLS) * 16
		for y = 0, 15 do
			buffer.copy(sheet, ((oy + y) * w + ox) * 4, icon, y * 64, 64)
		end
	end
	local iconImage = AssetService:CreateEditableImage({ Size = Vector2.new(w, h) })
	if iconImage then
		iconImage:WritePixelsBuffer(Vector2.zero, Vector2.new(w, h), sheet)
		TextureAtlas.iconContent = bake(iconImage)
	end
	TextureAtlas.ready = true
end

-- UV rectangle (0..1, v down) of a texture's 16x16 pixels inside the atlas.
function TextureAtlas.uvRect(texIndex: number): (number, number, number, number)
	local cell = cells[texIndex] or 0
	local x0 = (cell % COLS) * CELL + GUTTER
	local y0 = (cell // COLS) * CELL + GUTTER
	local span = 16 * SCALE
	return (x0 + 0.5) / SIZE, (y0 + 0.5) / SIZE, (x0 + span - 0.5) / SIZE, (y0 + span - 0.5) / SIZE
end

-- Pixel rectangle (offset, size) for ImageLabel.ImageRectOffset/Size.
function TextureAtlas.pixelRect(texIndex: number): (Vector2, Vector2)
	local cell = cells[texIndex] or 0
	return Vector2.new((cell % COLS) * CELL + GUTTER, (cell // COLS) * CELL + GUTTER), Vector2.new(16 * SCALE, 16 * SCALE)
end

function TextureAtlas.crackRect(stage: number): (Vector2, Vector2)
	local cell = crackCell[math.clamp(stage, 0, TextureGen.CRACK_STAGES - 1)] or 0
	return Vector2.new((cell % COLS) * CELL + GUTTER, (cell // COLS) * CELL + GUTTER), Vector2.new(16 * SCALE, 16 * SCALE)
end

-- Icon rectangle in the icon sheet, or nil for blocks / unknown items.
function TextureAtlas.iconRect(itemKey: string): (Vector2?, Vector2?)
	local cell = iconCells[itemKey]
	if not cell then
		return nil, nil
	end
	return Vector2.new((cell % ICON_COLS) * 16, (cell // ICON_COLS) * 16), Vector2.new(16, 16)
end

-- The 16x16 RGBA pixels of a texture (break particles, held block colours).
function TextureAtlas.pixels(texIndex: number): buffer?
	return pixels[texIndex]
end

-- Random opaque pixel colour of a texture (break particles).
function TextureAtlas.randomColor(texIndex: number): Color3
	local img = pixels[texIndex]
	if not img then
		return Color3.new(0.5, 0.5, 0.5)
	end
	for _ = 1, 8 do
		local o = math.random(0, 255) * 4
		if buffer.readu8(img, o + 3) > 128 then
			return Color3.fromRGB(buffer.readu8(img, o), buffer.readu8(img, o + 1), buffer.readu8(img, o + 2))
		end
	end
	local avg = TextureGen.average(img)
	return Color3.fromRGB(avg[1], avg[2], avg[3])
end

return TextureAtlas
