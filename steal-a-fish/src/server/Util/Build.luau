--!strict
--[[
	Build
	=====
	Small helpers for making placeholder parts and text labels from code.
	Everything they create is Anchored (it doesn't fall or move).

	STUDS: every part made with Build.part gets the classic Roblox stud look
	automatically (a tiling Texture, tinted with the part's color; see
	Config.Visuals). Studs are skipped automatically for Neon, Glass and see-
	through parts. To turn them off for one part, pass `Studs = false`. To
	choose which faces get studs, pass `StudFaces = { Enum.NormalId.Top }`.

	Usage:
		Build.part({ Name = "Floor", Size = ..., CFrame = ..., Parent = model })
		Build.cylinder({ ... })               -- upright cylinder; CFrame = center
		Build.addStuds(part)                  -- add studs to any part yourself
		Build.surfaceText(part, Enum.NormalId.Front, "Hello")
		Build.billboard(part, "Hatch Pad", 4)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)

export type PartProps = {
	Name: string,
	Size: Vector3,
	CFrame: CFrame,
	Parent: Instance,
	Color: Color3?,
	Material: Enum.Material?,
	Transparency: number?,
	CanCollide: boolean?, -- default true
	CanTouch: boolean?, -- default true
	CanQuery: boolean?, -- default true
	Studs: boolean?, -- default true for blocks, false for cylinders
	StudFaces: { Enum.NormalId }?, -- default: every face except the bottom
}

local Build = {}

local DEFAULT_STUD_FACES: { Enum.NormalId } = {
	Enum.NormalId.Top,
	Enum.NormalId.Front,
	Enum.NormalId.Back,
	Enum.NormalId.Left,
	Enum.NormalId.Right,
}
local STUD_TEXTURE_NAME = "Studs"

-- Add stud textures to `part`. The studs follow the part's color, even if the
-- color changes later (for example, a plot floor that brightens when owned).
function Build.addStuds(part: BasePart, faces: { Enum.NormalId }?)
	local visuals = Config.Visuals
	if not visuals.StudsEnabled then
		return
	end
	local faceList: { Enum.NormalId } = faces or DEFAULT_STUD_FACES
	for _, face in faceList do
		local texture = Instance.new("Texture")
		texture.Name = STUD_TEXTURE_NAME
		texture.Texture = visuals.StudTexture
		texture.Face = face
		texture.StudsPerTileU = visuals.StudsPerTile
		texture.StudsPerTileV = visuals.StudsPerTile
		texture.Transparency = visuals.StudTransparency
		texture.Color3 = part.Color
		texture.Parent = part
	end
	part:GetPropertyChangedSignal("Color"):Connect(function()
		for _, child in part:GetChildren() do
			if child:IsA("Texture") and child.Name == STUD_TEXTURE_NAME then
				child.Color3 = part.Color
			end
		end
	end)
end

local function wantsStuds(props: PartProps, default: boolean): boolean
	if props.Studs ~= nil then
		return props.Studs
	end
	local material = props.Material
	if material == Enum.Material.Neon or material == Enum.Material.Glass or material == Enum.Material.ForceField then
		return false
	end
	if (props.Transparency or 0) >= 0.5 then
		return false
	end
	return default
end

local function applyProps(part: Part, props: PartProps)
	part.Name = props.Name
	part.Anchored = true
	part.Color = props.Color or Color3.fromRGB(163, 162, 165)
	part.Material = props.Material or Enum.Material.SmoothPlastic
	part.Transparency = props.Transparency or 0
	part.CanCollide = if props.CanCollide == nil then true else props.CanCollide
	part.CanTouch = if props.CanTouch == nil then true else props.CanTouch
	part.CanQuery = if props.CanQuery == nil then true else props.CanQuery
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

-- A normal block.
function Build.part(props: PartProps): Part
	local part = Instance.new("Part")
	applyProps(part, props)
	part.Size = props.Size
	part.CFrame = props.CFrame
	if wantsStuds(props, true) then
		Build.addStuds(part, props.StudFaces)
	end
	part.Parent = props.Parent
	return part
end

-- An upright cylinder. Size = Vector3.new(diameter, height, diameter).
-- (Roblox cylinders lie on their side by default, so we rotate them upright.)
-- No studs unless you pass Studs = true (textures wrap oddly on round parts).
function Build.cylinder(props: PartProps): Part
	local part = Instance.new("Part")
	applyProps(part, props)
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(props.Size.Y, props.Size.X, props.Size.Z)
	part.CFrame = props.CFrame * CFrame.Angles(0, 0, math.rad(90))
	if wantsStuds(props, false) then
		Build.addStuds(part, props.StudFaces)
	end
	part.Parent = props.Parent
	return part
end

-- Text painted on one face of a part. Returns the TextLabel so you can change
-- the text later.
function Build.surfaceText(part: BasePart, face: Enum.NormalId, text: string, color: Color3?): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Name = `Text{face.Name}`
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = color or Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.3
	label.Text = text
	label.Parent = gui
	return label
end

-- Floating text above a part that always faces the camera.
function Build.billboard(part: BasePart, text: string, heightAbove: number, maxDistance: number?): TextLabel
	local gui = Instance.new("BillboardGui")
	gui.Name = "Label"
	gui.Size = UDim2.fromOffset(200, 50)
	gui.StudsOffsetWorldSpace = Vector3.new(0, heightAbove, 0)
	gui.MaxDistance = maxDistance or 80
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.Parent = part

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.2
	label.Text = text
	label.Parent = gui
	return label
end

return Build
