--!strict
-- Custom camera: first person by default with the mouse locked to the screen centre, and a key
-- (Config.KEY_CAMERA, default V) that cycles: first person -> third person behind -> third
-- person in front (looking back at the player). The mouse stays locked in every mode.
--
-- The camera is Scriptable, so Roblox's default camera scripts stay out of the way. The body
-- always turns to face the look direction (yaw), like classic block games.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local MovementController = require(script.Parent.MovementController)

local MODES = { "first", "back", "front" }
local MAX_PITCH = math.rad(89)

local CameraController = {}
CameraController.mode = "first"
-- Set true while a menu needs the cursor (phase 3 inventory).
CameraController.mouseUnlocked = false

local modeChanged = Instance.new("BindableEvent")
CameraController.ModeChanged = modeChanged.Event

local yaw, pitch = 0, 0
local touchLook: { [InputObject]: boolean } = {}
local gamepadLook = Vector2.zero

local function rootPart(): BasePart?
	local character = Players.LocalPlayer.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Eye position (studs) and the player's look direction. The look direction is the same in every
-- camera mode, so block targeting doesn't change when you switch views.
function CameraController.getEyeAndLook(): (Vector3?, Vector3)
	local look = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0).LookVector
	local root = rootPart()
	if not root then
		return nil, look
	end
	return root.Position + Vector3.new(0, MovementController.eyeHeight, 0), look
end

local function setLocalTransparency(character: Model, value: number)
	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") or d:IsA("Decal") then
			(d :: any).LocalTransparencyModifier = value
		end
	end
end

local collisionParams = RaycastParams.new()
collisionParams.FilterType = Enum.RaycastFilterType.Include

-- Pull a third-person camera in front of terrain so it never ends up inside blocks.
local function clampToTerrain(from: Vector3, to: Vector3): Vector3
	local world = workspace:FindFirstChild("VoxelWorld")
	local collision = world and world:FindFirstChild("Collision")
	if not collision then
		return to
	end
	collisionParams.FilterDescendantsInstances = { collision }
	local dir = to - from
	local hit = workspace:Raycast(from, dir, collisionParams)
	if hit then
		return hit.Position - dir.Unit * 0.4
	end
	return to
end

local function update(dt: number)
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable

	if not CameraController.mouseUnlocked then
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
		local delta = UserInputService:GetMouseDelta()
		local settings = UserSettings():GetService("UserGameSettings")
		local sens = Config.MOUSE_SENSITIVITY * settings.MouseSensitivity
		yaw -= math.rad(delta.X * sens)
		pitch -= math.rad(delta.Y * sens)
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	end
	-- right thumbstick (gamepad)
	if gamepadLook.Magnitude > 0.15 then
		yaw -= gamepadLook.X * math.rad(240) * dt
		pitch += gamepadLook.Y * math.rad(180) * dt
	end
	pitch = math.clamp(pitch, -MAX_PITCH, MAX_PITCH)

	local character = Players.LocalPlayer.Character
	local root = rootPart()
	local rot = CFrame.fromEulerAnglesYXZ(pitch, yaw, 0)
	if not root or not character then
		return
	end
	-- Face the body where we look (yaw only).
	if not root.Anchored then
		root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, yaw, 0)
	end

	local eye = root.Position + Vector3.new(0, MovementController.eyeHeight + MovementController.stepOffset, 0)
	local look = rot.LookVector
	local mode = CameraController.mode
	if mode == "first" then
		camera.CFrame = CFrame.new(eye) * rot
		setLocalTransparency(character, 1)
	elseif mode == "back" then
		local pos = clampToTerrain(eye, eye - look * Config.THIRD_PERSON_DISTANCE)
		camera.CFrame = CFrame.new(pos) * rot
		setLocalTransparency(character, 0)
	else -- front
		local pos = clampToTerrain(eye, eye + look * Config.THIRD_PERSON_DISTANCE)
		camera.CFrame = CFrame.lookAt(pos, eye)
		setLocalTransparency(character, 0)
	end
	camera.Focus = CFrame.new(eye)
end

function CameraController.cycle()
	local i = table.find(MODES, CameraController.mode) or 1
	CameraController.mode = MODES[i % #MODES + 1]
	modeChanged:Fire(CameraController.mode)
end

function CameraController.init()
	local keyCamera = (Enum.KeyCode :: any)[Config.KEY_CAMERA]
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == keyCamera then
			CameraController.cycle()
		elseif input.UserInputType == Enum.UserInputType.Touch then
			touchLook[input] = true -- touches not claimed by UI/thumbstick turn the camera
		end
	end)
	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch and touchLook[input] then
			yaw -= math.rad(input.Delta.X * Config.TOUCH_SENSITIVITY)
			pitch -= math.rad(input.Delta.Y * Config.TOUCH_SENSITIVITY)
		elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
			gamepadLook = Vector2.new(input.Position.X, input.Position.Y)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		touchLook[input] = nil
	end)

	-- Start looking the way the character faces after each spawn.
	Players.LocalPlayer.CharacterAdded:Connect(function(character)
		local root = character:WaitForChild("HumanoidRootPart") :: BasePart
		local _, ry, _ = root.CFrame:ToEulerAnglesYXZ()
		yaw, pitch = ry, 0
	end)

	RunService:BindToRenderStep("RocraftCamera", Enum.RenderPriority.Camera.Value + 1, update)
end

return CameraController
