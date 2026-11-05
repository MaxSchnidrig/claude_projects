--!strict
-- Crosshair: a small, thin plus sign drawn from Frames (no image assets).
--   * light grey arms, 2 px thick, 18 px across
--   * a 1 px dark outline (darker frames behind) so it reads on bright sky and dark caves —
--     Roblox UI can't invert the colours behind it
--   * positioned on whole pixels at the exact viewport centre, so it stays crisp
-- Shown in first person and third-person-behind; hidden in the front view (nothing to aim at).

local Players = game:GetService("Players")

local CameraController = require(script.Parent.Parent.Player.CameraController)

local ARM = 18 -- total length (px), even so the centre lands between pixels symmetrically
local THICK = 2
local OUTLINE = 1
local LIGHT = Color3.fromRGB(232, 232, 236)
local DARK = Color3.fromRGB(16, 16, 20)

local Crosshair = {}

local function bar(parent: Instance, w: number, h: number, color: Color3, z: number): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color
	f.Size = UDim2.fromOffset(w, h)
	f.ZIndex = z
	f.Parent = parent
	return f
end

function Crosshair.init()
	local gui = Instance.new("ScreenGui")
	gui.Name = "Crosshair"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- centre of the whole screen = centre of the camera view
	gui.DisplayOrder = 10

	local root = Instance.new("Frame")
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromOffset(ARM + OUTLINE * 2, ARM + OUTLINE * 2)
	root.Parent = gui

	local full = ARM + OUTLINE * 2
	local thick = THICK + OUTLINE * 2
	local mid = (full - thick) // 2
	-- outline (behind)
	local oh = bar(root, full, thick, DARK, 1)
	oh.Position = UDim2.fromOffset(0, mid)
	local ov = bar(root, thick, full, DARK, 1)
	ov.Position = UDim2.fromOffset(mid, 0)
	-- light arms (front)
	local lh = bar(root, ARM, THICK, LIGHT, 2)
	lh.Position = UDim2.fromOffset(OUTLINE, mid + OUTLINE)
	local lv = bar(root, THICK, ARM, LIGHT, 2)
	lv.Position = UDim2.fromOffset(mid + OUTLINE, OUTLINE)

	-- Whole-pixel centring (scale-based centring can land on half pixels and blur).
	local function place()
		local vp = workspace.CurrentCamera.ViewportSize
		root.Position = UDim2.fromOffset(math.floor(vp.X / 2) - full // 2, math.floor(vp.Y / 2) - full // 2)
	end
	place()
	workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(place)

	local function onMode(mode: string)
		root.Visible = mode ~= "front"
	end
	onMode(CameraController.mode)
	CameraController.ModeChanged:Connect(onMode)

	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

return Crosshair
