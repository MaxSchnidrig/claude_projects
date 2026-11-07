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
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local SurvivalClient = require(script.Parent.Parent.Survival.SurvivalClient)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)

local BS = Config.BLOCK_SIZE
local isLiquid = BlockRegistry.isLiquid
local SWIM_UP_SPEED = 9 -- studs/s while holding jump in water
local SINK_SPEED = 5 -- max sinking speed in water (studs/s)
local SWIM_SPEED_FACTOR = 0.6 -- walking speed multiplier in liquid

local MovementController = {}
MovementController.sprinting = false
MovementController.inLiquid = false

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
		-- Sprint only while moving forward (relative to where the body faces) and not too hungry.
		local forward = humanoid.MoveDirection:Dot(root.CFrame.LookVector) > 0.5
		local sprinting = sprintHeld and forward and SurvivalClient.canSprint and not SurvivalClient.dead
		if sprinting ~= MovementController.sprinting then
			MovementController.sprinting = sprinting
			SurvivalClient.setSprinting(sprinting) -- the server charges sprint exhaustion
		end

		-- Swimming (water/lava): Humanoids only swim in Roblox Terrain water, so we do it by hand:
		-- hold jump to rise, otherwise sink slowly; move slower.
		local p = root.Position
		local bx, bz = math.floor(p.X / BS), math.floor(p.Z / BS)
		local bodyId = ClientWorld.getBlock(bx, math.floor(p.Y / BS), bz)
		local feetId = ClientWorld.getBlock(bx, math.floor((p.Y - 2.5) / BS), bz)
		local inLiquid = (bodyId ~= nil and isLiquid[bodyId + 1]) or (feetId ~= nil and isLiquid[feetId + 1])
		MovementController.inLiquid = inLiquid
		local speed = if sprinting then Config.SPRINT_SPEED else Config.WALK_SPEED
		if inLiquid and not root.Anchored then
			speed *= SWIM_SPEED_FACTOR
			local v = root.AssemblyLinearVelocity
			local up = humanoid.Jump or UserInputService:IsKeyDown(Enum.KeyCode.Space)
			local vy = if up then SWIM_UP_SPEED else math.max(v.Y, -SINK_SPEED)
			root.AssemblyLinearVelocity = Vector3.new(v.X, vy, v.Z)
		end
		humanoid.WalkSpeed = speed
		local camera = workspace.CurrentCamera
		local targetFov = if MovementController.sprinting then BASE_FOV * 1.1 else BASE_FOV
		camera.FieldOfView += (targetFov - camera.FieldOfView) * 0.2
	end)
end

return MovementController
