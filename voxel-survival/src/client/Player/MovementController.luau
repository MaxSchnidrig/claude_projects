--!strict
-- Movement feel: classic walk/sprint speeds and a 1.2-block jump (3.6 studs), applied to the
-- local character (the client simulates its own character's physics). The server applies the
-- same base values on spawn.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local MovementController = {}
MovementController.sprinting = false

local sprintHeld = false
local BASE_FOV = 70

local function configure(humanoid: Humanoid)
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = Config.JUMP_HEIGHT
	humanoid.WalkSpeed = Config.WALK_SPEED
	humanoid.AutoRotate = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
end

function MovementController.init()
	local keySprint = (Enum.KeyCode :: any)[Config.KEY_SPRINT]
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and (input.KeyCode == keySprint or input.KeyCode == Enum.KeyCode.ButtonL3) then
			sprintHeld = true
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == keySprint or input.KeyCode == Enum.KeyCode.ButtonL3 then
			sprintHeld = false
		end
	end)

	Players.LocalPlayer.CharacterAdded:Connect(function(character)
		configure(character:WaitForChild("Humanoid") :: Humanoid)
	end)
	if Players.LocalPlayer.Character then
		local h = Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
		if h then
			configure(h)
		end
	end

	RunService.Heartbeat:Connect(function()
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not humanoid or not root then
			return
		end
		-- Sprint only while moving forward (relative to where the body faces).
		local forward = humanoid.MoveDirection:Dot(root.CFrame.LookVector) > 0.5
		MovementController.sprinting = sprintHeld and forward
		humanoid.WalkSpeed = if MovementController.sprinting then Config.SPRINT_SPEED else Config.WALK_SPEED
		local camera = workspace.CurrentCamera
		local targetFov = if MovementController.sprinting then BASE_FOV * 1.1 else BASE_FOV
		camera.FieldOfView += (targetFov - camera.FieldOfView) * 0.2
	end)
end

return MovementController
