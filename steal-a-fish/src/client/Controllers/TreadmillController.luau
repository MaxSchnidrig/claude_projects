--!strict
--[[
	TreadmillController
	===================
	Makes every treadmill belt look like it's moving, by sliding the chevron
	(arrow) markings along the belt over and over. This only happens on your
	own screen; the server doesn't move anything.

	To save work, belts far away from the camera are not animated.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)

local TreadmillController = {}
TreadmillController.Name = "TreadmillController"

local ANIMATE_DISTANCE = 150 -- only animate belts closer than this to the camera
local END_MARGIN = 1.2 -- hide chevrons this close to the belt ends

local function animateBelt(belt: BasePart, time: number)
	local count = belt:GetAttribute("ChevronCount")
	if typeof(count) ~= "number" or count <= 0 then
		return
	end
	local halfLength = belt.Size.Z / 2
	local spacing = belt.Size.Z / count
	-- How far the belt has moved, wrapped so it repeats every `spacing` studs.
	local shift = (time * Config.Visuals.TreadmillBeltSpeed) % spacing

	for _, bar in belt:GetChildren() do
		if bar:IsA("BasePart") then
			local offset = bar:GetAttribute("ChevronOffset")
			local index = bar:GetAttribute("ChevronIndex")
			if typeof(offset) == "CFrame" and typeof(index) == "number" then
				-- The markings slide from the console end (+Z) toward the back (-Z).
				local z = halfLength - (index - 0.5) * spacing - shift
				if z < -halfLength then
					z += belt.Size.Z
				end
				bar.CFrame = belt.CFrame * CFrame.new(0, belt.Size.Y / 2 + 0.03, z) * offset
				bar.LocalTransparencyModifier = if math.abs(z) > halfLength - END_MARGIN then 1 else 0
			end
		end
	end
end

function TreadmillController.Init()
end

function TreadmillController.Start()
	RunService.RenderStepped:Connect(function()
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local time = os.clock()
		for _, belt in CollectionService:GetTagged(Constants.Tags.TreadmillBelt) do
			if belt:IsA("BasePart") and (belt.Position - camera.CFrame.Position).Magnitude < ANIMATE_DISTANCE then
				animateBelt(belt, time)
			end
		end
	end)
end

return TreadmillController
