--!strict
--[[
	ShiftLockController
	===================
	Our own shift lock, so it works for everyone without changing any Roblox
	settings:
	  - Computer: press Shift to lock. The mouse is locked to the middle of the
	    screen, the camera sits over your right shoulder, and your character
	    turns with the camera. Press Shift again to unlock.
	  - Phone/tablet: a small lock button appears at the right side of the screen.

	Roblox's built-in shift lock is turned off in default.project.json
	(StarterPlayer.EnableMouseLockOption = false), so the two don't fight.
	Turn ours off with Config.Controls.ShiftLock = false.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

local ShiftLockController = {}
ShiftLockController.Name = "ShiftLockController"

local player = Players.LocalPlayer
local locked = false
local mobileButton: TextButton? = nil

local function getHumanoidAndRoot(): (Humanoid?, BasePart?)
	local character = player.Character
	if not character then
		return nil, nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	return humanoid, if root and root:IsA("BasePart") then root else nil
end

local function applyToCharacter()
	local humanoid = getHumanoidAndRoot()
	if humanoid then
		-- While locked, WE turn the character (to face the camera direction).
		humanoid.AutoRotate = not locked
		humanoid.CameraOffset = if locked then Config.Controls.ShiftLockCameraOffset else Vector3.zero
	end
end

local function setLocked(value: boolean)
	locked = value
	applyToCharacter()
	if not locked then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
	if mobileButton then
		mobileButton.BackgroundColor3 = if locked then Color3.fromRGB(60, 170, 255) else Color3.fromRGB(30, 40, 60)
	end
end

-- Runs every frame, just after the camera updates.
local function onRenderStep()
	if not locked then
		return
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
	local humanoid, root = getHumanoidAndRoot()
	local camera = Workspace.CurrentCamera
	if not (humanoid and root and camera) or humanoid.Sit then
		return
	end
	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude > 0.01 then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + flat)
	end
end

local function buildMobileButton()
	local gui = Instance.new("ScreenGui")
	gui.Name = "ShiftLock"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local button = Instance.new("TextButton")
	button.Name = "LockButton"
	button.AnchorPoint = Vector2.new(1, 1)
	button.Position = UDim2.new(1, -20, 1, -170) -- above the jump button
	button.Size = UDim2.fromOffset(56, 56)
	button.BackgroundColor3 = Color3.fromRGB(30, 40, 60)
	button.BackgroundTransparency = 0.2
	button.Text = "🔒"
	button.TextScaled = true
	button.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = button

	button.Activated:Connect(function()
		setLocked(not locked)
	end)
	mobileButton = button
end

function ShiftLockController.Init()
end

function ShiftLockController.Start()
	if not Config.Controls.ShiftLock then
		return
	end

	ContextActionService:BindAction("ToggleShiftLock", function(_name, state, _input)
		if state == Enum.UserInputState.Begin then
			setLocked(not locked)
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift)

	-- Run right after Roblox's camera code, so our mouse lock wins.
	RunService:BindToRenderStep("ShiftLock", Enum.RenderPriority.Camera.Value + 1, onRenderStep)

	-- A new character needs the settings again.
	player.CharacterAdded:Connect(function(character)
		character:WaitForChild("Humanoid", 10)
		applyToCharacter()
	end)

	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		buildMobileButton()
	end
end

return ShiftLockController
