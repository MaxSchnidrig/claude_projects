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
-- Active knockback: horizontal velocity (studs/s) decaying with Java friction.
local knockback: { vel: Vector3, t: number }? = nil

-- Java: a full-strength sprint hit ends the sprint.
function MovementController.stopSprint()
	sprintLatch = false
end

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
	-- Hits use Java's formula on our own velocity and ground state (Combat.knockback); the
	-- horizontal push is held for a short moment so the Humanoid's walking doesn't cancel it.
	local Remotes = require(Shared.Net.Remotes)
	local Combat = require(Shared.Gameplay.Combat)
	Remotes.get("Knockback").OnClientEvent:Connect(function(kb: any)
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if typeof(kb) ~= "table" or not root or not humanoid or root.Anchored then
			return
		end
		local v = root.AssemblyLinearVelocity / BS / 20 -- blocks/tick
		local nv: Vector3
		if typeof(kb.dir) == "Vector3" and typeof(kb.strength) == "number" then
			local onGround = humanoid.FloorMaterial ~= Enum.Material.Air
			local x, y, z = Combat.knockback(v.X, v.Y, v.Z, kb.dir.X, kb.dir.Z, kb.strength, onGround)
			nv = Vector3.new(x, y, z)
		elseif typeof(kb.add) == "Vector3" then
			nv = v + kb.add
		else
			return
		end
		knockback = { vel = Vector3.new(nv.X, 0, nv.Z) * 20 * BS, t = 0 }
		root.AssemblyLinearVelocity = nv * 20 * BS
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

		-- Knockback: keep the pushed horizontal velocity, decaying like Java (ground 0.546 per
		-- tick, air 0.91), until it falls below walking speed; the Humanoid would cancel it.
		local kb = knockback
		if kb and not root.Anchored then
			local onGround = humanoid.FloorMaterial ~= Enum.Material.Air
			kb.vel *= (if onGround then 0.546 else 0.91) ^ (dt * 20)
			kb.t += dt
			if kb.vel.Magnitude < Config.WALK_SPEED * 0.5 or kb.t > 1.5 then
				knockback = nil
			else
				local cur = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(kb.vel.X, cur.Y, kb.vel.Z)
			end
		end

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
