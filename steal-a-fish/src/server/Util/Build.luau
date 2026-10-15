--!strict
--[[
	Build
	=====
	Small helpers for making placeholder parts and text labels from code.
	Everything they create is Anchored (it doesn't fall or move).

	Usage:
		Build.part({ Name = "Floor", Size = ..., CFrame = ..., Parent = model })
		Build.cylinder({ ... })               -- upright cylinder; CFrame = center
		Build.surfaceText(part, Enum.NormalId.Front, "Hello")
		Build.billboard(part, "Hatch Pad", 4)
]]

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
}

local Build = {}

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
	part.Parent = props.Parent
	return part
end

-- An upright cylinder. Size = Vector3.new(diameter, height, diameter).
-- (Roblox cylinders lie on their side by default, so we rotate them upright.)
function Build.cylinder(props: PartProps): Part
	local part = Instance.new("Part")
	applyProps(part, props)
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(props.Size.Y, props.Size.X, props.Size.Z)
	part.CFrame = props.CFrame * CFrame.Angles(0, 0, math.rad(90))
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
