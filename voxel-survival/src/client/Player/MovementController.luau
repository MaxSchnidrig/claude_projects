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

-- Sprint is a latch (classic behaviour): started by double-tapping W, by Ctrl while moving
-- forward, or by clicking the left stick; it ends when W is released, you stop moving forward,
-- run into a wall, or get too hungry.
local sprintLatch = false
local lastWRelease = -math.huge
local blockedTime = 0
-- Fall tracking uses the character's real ground contact (Humanoid.FloorMaterial, from the
-- client's collision boxes): resets on every touch of the ground, step or edge.
local peakFeetY: number? = nil
local FEET_BELOW_ROOT = 3
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
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.W then
			if os.clock() - lastWRelease <= Config.SPRINT_DOUBLE_TAP then
				sprintLatch = true -- double-tap W
			end
		elseif input.KeyCode == keySprint or input.KeyCode == Enum.KeyCode.ButtonL3 then
			sprintLatch = true -- Ctrl (+W) / left stick click; needs forward movement below
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.W then
			lastWRelease = os.clock()
			sprintLatch = false
		end
	end)

	Players.LocalPlayer.CharacterAdded:Connect(function(character)
		configure(character:WaitForChild("Humanoid") :: Humanoid)
	end)

	-- Knockback from hits/explosions (the client simulates its own character's physics).
	local Remotes = require(Shared.Net.Remotes)
	Remotes.get("Knockback").OnClientEvent:Connect(function(vel: any)
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if typeof(vel) == "Vector3" and root and not root.Anchored then
			root.AssemblyLinearVelocity = Vector3.new(vel.X, math.max(vel.Y, root.AssemblyLinearVelocity.Y), vel.Z)
		end
	end)
	if Players.LocalPlayer.Character then
		local h = Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
		if h then
			configure(h)
		end
	end

	RunService.Heartbeat:Connect(function(dt)
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not humanoid or not root then
			return
		end
		-- Sprint latch: needs forward movement, food > 6, and not pushing against a wall.
		local forward = humanoid.MoveDirection:Dot(root.CFrame.LookVector) > 0.5
		if UserInputService:IsKeyDown(keySprint) and forward then
			sprintLatch = true -- Ctrl held while walking forward
		end
		if not forward or not SurvivalClient.canSprint or SurvivalClient.dead then
			sprintLatch = false
		end
		local v = root.AssemblyLinearVelocity
		if sprintLatch and Vector3.new(v.X, 0, v.Z).Magnitude < Config.WALK_SPEED * 0.4 then
			blockedTime += dt
			if blockedTime > 0.15 then
				sprintLatch = false -- ran into a wall
			end
		else
			blockedTime = 0
		end
		local sprinting = sprintLatch
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

		-- Fall distance: highest point since last ground contact; reported on landing.
		local feetY = p.Y - FEET_BELOW_ROOT
		if root.Anchored or humanoid.Health <= 0 or inLiquid then
			peakFeetY = nil -- frozen, dead, or water/lava breaks the fall
		elseif humanoid.FloorMaterial ~= Enum.Material.Air then
			local peak = peakFeetY
			if peak and peak - feetY > 3 * BS then
				SurvivalClient.reportFall((peak - feetY) / BS)
			end
			peakFeetY = nil
		else
			peakFeetY = math.max(peakFeetY or feetY, feetY)
		end
		local camera = workspace.CurrentCamera
		local targetFov = if MovementController.sprinting then BASE_FOV * 1.1 else BASE_FOV
		camera.FieldOfView += (targetFov - camera.FieldOfView) * 0.2
	end)
end

return MovementController
