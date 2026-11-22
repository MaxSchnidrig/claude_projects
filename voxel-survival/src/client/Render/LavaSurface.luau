--!strict
-- World-space, block-sized lava art on the outward face of a fluid slab or fallback box.
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local TextureGen = require(Shared.Blocks.TextureGen)
local BS = require(Shared.Config).BLOCK_SIZE

local LavaSurface = {}
LavaSurface.faces = { Enum.NormalId.Right, Enum.NormalId.Left, Enum.NormalId.Top, Enum.NormalId.Bottom, Enum.NormalId.Back, Enum.NormalId.Front }

local tile: Content? = nil
local attempted = false
local function getTile(): Content?
	if not attempted then
		attempted = true
		local ok, content = pcall(function()
			local size = Vector2.new(16, 16)
			local image = game:GetService("AssetService"):CreateEditableImage({ Size = size })
			assert(image)
			image:WritePixelsBuffer(Vector2.zero, size, TextureGen.generate("lava"))
			return Content.fromObject(image)
		end)
		if ok then tile = content end
	end
	return tile
end

function LavaSurface.draw(part: BasePart, face: Enum.NormalId)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 16 / BS
	gui.LightInfluence = 0.25
	gui.Brightness = 0.85
	gui.Active = false
	gui.ClipsDescendants = true
	local content = getTile()
	if content then
		local image = Instance.new("ImageLabel")
		image.Size = UDim2.fromScale(1, 1)
		image.BackgroundTransparency = 1
		image.ImageContent = content
		image.ScaleType = Enum.ScaleType.Tile
		image.TileSize = UDim2.fromOffset(16, 16)
		image.ResampleMode = Enum.ResamplerMode.Pixelated
		image.Parent = gui
	else
		-- Editable images may be unavailable. Sparse, joined pixel seams still break up the crust.
		local size = part.Size / BS
		local width = if face == Enum.NormalId.Left or face == Enum.NormalId.Right then size.Z else size.X
		local height = if face == Enum.NormalId.Top or face == Enum.NormalId.Bottom then size.Z else size.Y
		local function seam(x: number, y: number, w: number, h: number, color: Color3)
			local strip = Instance.new("Frame")
			strip.BorderSizePixel = 0
			strip.Position = UDim2.fromOffset(x, y)
			strip.Size = UDim2.fromOffset(w, h)
			strip.BackgroundColor3 = color
			strip.Parent = gui
		end
		for y = 0, math.ceil(height * 16) - 1, 24 do
			for x = -12, math.ceil(width * 16) - 1, 24 do
				local u = x + (if y % 48 == 0 then 8 else 0)
				seam(u, y + 3, 13, 1, Color3.fromRGB(191, 78, 30))
				seam(u + 12, y + 3, 1, 6, Color3.fromRGB(219, 115, 42))
				seam(u + 12, y + 8, 12, 1, Color3.fromRGB(165, 61, 29))
			end
		end
	end
	gui.Parent = part
end

return LavaSurface
