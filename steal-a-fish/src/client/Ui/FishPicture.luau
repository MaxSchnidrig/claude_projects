--!strict
--[[
	FishPicture
	===========
	A little 3D picture of a fish for the UI (Index and Fish panel), using a
	ViewportFrame and the same model builder the server uses for real fish.
	Not-found fish can be shown as a black silhouette.

	Usage:
		local picture = FishPicture.create(parent, fishConfig, UDim2.fromOffset(80, 80), UDim2.new(), silhouette)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local FishModel = require(ReplicatedStorage.Shared.Models.FishModel)

local FishPicture = {}

local FIELD_OF_VIEW = 35

function FishPicture.create(parent: Instance, fish: Config.FishConfig, size: UDim2, position: UDim2?, silhouette: boolean?): ViewportFrame
	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "Picture"
	viewport.Size = size
	viewport.Position = position or UDim2.new()
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(190, 190, 200)
	viewport.LightColor = Color3.new(1, 1, 1)
	viewport.LightDirection = Vector3.new(-0.4, -1, 0.6)
	if silhouette then
		-- Tint everything black: you only see the outline.
		viewport.ImageColor3 = Color3.new(0, 0, 0)
		viewport.ImageTransparency = 0.15
	end

	-- Built at the origin, turned a little so you see its face and side.
	local model = FishModel.create(fish, CFrame.new(), true)
	model:PivotTo(CFrame.Angles(0, math.rad(-35), 0))
	model.Parent = viewport

	local camera = Instance.new("Camera")
	camera.FieldOfView = FIELD_OF_VIEW
	local center, boxSize = model:GetBoundingBox()
	local radius = boxSize.Magnitude / 2
	local distance = radius / math.tan(math.rad(FIELD_OF_VIEW / 2)) * 1.05
	-- The fish looks toward -Z, so the camera sits in front of it (at -Z).
	local eye = center.Position + Vector3.new(0, radius * 0.25, -distance)
	camera.CFrame = CFrame.lookAt(eye, center.Position)
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	viewport.Parent = parent
	return viewport
end

return FishPicture
