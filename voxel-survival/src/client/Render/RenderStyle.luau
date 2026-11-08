--!strict
-- Maps texture indices to Roblox render properties (colour, transparency, material).
-- Phase 7 swaps the flat colours for generated 16x16 pixel textures.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)

local RenderStyle = {}
-- Material of ordinary (opaque) terrain. Plastic is rougher than SmoothPlastic, so blocks look
-- matte like the classic games instead of shiny.
RenderStyle.baseMaterial = (Enum.Material :: any)[Config.TERRAIN_MATERIAL] or Enum.Material.Plastic

export type Style = { color: Color3, transparency: number, material: Enum.Material }

local cache: { [number]: Style } = {}

function RenderStyle.forTexture(tex: number): Style
	local s = cache[tex]
	if s then
		return s
	end
	local rgb = BlockRegistry.textureColor(tex)
	local key = BlockRegistry.textureKeys[tex]
	local o = (Config.TEXTURE_STYLE :: any)[key] or {}
	s = {
		color = Color3.fromRGB(rgb[1], rgb[2], rgb[3]),
		transparency = o.transparency or 0,
		material = if o.neon then Enum.Material.Neon else RenderStyle.baseMaterial,
	}
	cache[tex] = s
	return s
end

-- Style for a whole block (Parts backend uses the top texture).
function RenderStyle.forBlock(id: number): Style
	local def = BlockRegistry.byId[id]
	return RenderStyle.forTexture(def.faceTexture[BlockRegistry.Dir.TOP])
end

return RenderStyle
