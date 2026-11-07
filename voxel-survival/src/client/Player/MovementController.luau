--!strict
-- Movement, Java Edition rules, applied to the local character (the client simulates its own
-- character's physics; the server applies the same base values on spawn).
--
--   walk 4.317 b/s, sprint 5.612 b/s, jump 1.2522 blocks, gravity 32 b/s^2
--   sprint     starts on a second W press within 7 ticks (0.35 s) of the first (the trigger is
--              armed by a W press while on the ground), or Ctrl while moving forward; ends when W
--              is released, forward movement stops, you hit a wall, get hungry (food <= 6), sneak
--              or use an item. Holding W again after a sprint ends does NOT resume it.
--   sneak      hold Left Shift: speed x 0.3, no sprinting, eyes 1.27 blocks, body 1.5 blocks
--              tall (fits under 1.5-block gaps), and on the ground you can't move off an edge
--              where nothing is within 0.6 blocks below your feet box. You stay crouched while
--              there's no room to stand. (Not while a window is open.)
--   item use   eating: speed x 0.2 (x 0.06 when also sneaking), no sprinting

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local SurvivalClient = require(script.Parent.Parent.Survival.SurvivalClient)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local InventoryClient = require(script.Parent.Parent.Player.InventoryClient)
local SneakPose = require(Shared.Gameplay.SneakPose)

local BS = Config.BLOCK_SIZE
local isLiquid = BlockRegistry.isLiquid
local isSolid = BlockRegistry.isSolid
local SWIM_UP_SPEED = 9 -- studs/s while holding jump in water
local SINK_SPEED = 5 -- max sinking speed in water (studs/s)
local SWIM_SPEED_FACTOR = 0.6 -- walking speed multiplier in liquid

local MovementController = {}
MovementController.sprinting = false
MovementController.inLiquid = false
MovementController.sneaking = false -- crouched (Shift held, or no room to stand)
MovementController.usingItem = false -- set by BlockInteraction while eating
MovementController.eyeHeight = Config.EYE_HEIGHT -- studs above the root, eases when sneaking

local sprintLatch = false
local sprintTriggerUntil = -math.huge
local blockedTime = 0
local touchSneak = false
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

-- Touch button: toggle sneaking.
function MovementController.toggleSneak()
	touchSneak = not touchSneak
end

local function configure(humanoid: Humanoid)
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = Config.JUMP_HEIGHT
	humanoid.WalkSpeed = Config.WALK_SPEED
	humanoid.AutoRotate = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Climbing, false)
	local character = humanoid.Parent
	if character and character:IsA("Model") then
		SneakPose.remember(character)
	end
	MovementController.sneaking = false
	MovementController.eyeHeight = Config.EYE_HEIGHT
end

local function onGround(humanoid: Humanoid): boolean
	return humanoid.FloorMaterial ~= Enum.Material.Air
end

local function canStartSprint(humanoid: Humanoid): boolean
	return SurvivalClient.canSprint and not SurvivalClient.dead and not MovementController.sneaking
		and not MovementController.usingItem
end

-- Any block with collision inside this box (block units)? Unloaded counts as solid.
local function solidIn(x0: number, y0: number, z0: number, x1: number, y1: number, z1: number): boolean
	for x = math.floor(x0), math.ceil(x1) - 1 do
		for y = math.floor(y0), math.ceil(y1) - 1 do
			for z = math.floor(z0), math.ceil(z1) - 1 do
				local id = ClientWorld.getBlock(x, y, z)
				if id == nil or isSolid[id + 1] then
					return true
				end
			end
		end
	end
	return false
end

local HALF = 0.3 -- Java player half width (blocks)
local STEP = 0.6 -- Java max step height (blocks)

-- Something to stand on within STEP below the feet box at (x, z)?
local function supported(x: number, feetY: number, z: number): boolean
	return solidIn(x - HALF + 1e-3, feetY - STEP, z - HALF + 1e-3, x + HALF - 1e-3, feetY - 1e-3, z + HALF - 1e-3)
end

local function roomToStand(x: number, feetY: number, z: number): boolean
	return not solidIn(x - HALF + 1e-3, feetY + 0.01, z - HALF + 1e-3, x + HALF - 1e-3, feetY + 1.8, z + HALF - 1e-3)
end

function MovementController.init()
	workspace.Gravity = Config.GRAVITY -- Java gravity (the server sets it too)
	local keySprint = (Enum.KeyCode :: any)[Config.KEY_SPRINT]
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return
		end
		if input.KeyCode == Enum.KeyCode.W then
			-- Java double-tap: the first press (on the ground) arms a 7-tick trigger, a second
			-- press while it is armed starts the sprint.
			local now = os.clock()
			if canStartSprint(humanoid) then
				if now <= sprintTriggerUntil then
					sprintLatch = true
					sprintTriggerUntil = -math.huge
				elseif onGround(humanoid) then
					sprintTriggerUntil = now + Config.SPRINT_DOUBLE_TAP
				end
			end
		elseif input.KeyCode == keySprint or input.KeyCode == Enum.KeyCode.ButtonL3 then
			if canStartSprint(humanoid) then
				sprintLatch = true -- Ctrl (+W) / left stick click; needs forward movement below
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.W then
			sprintLatch = false
		end
	end)

	-- Sneaking at the edge of a drop: after the control script has set this frame's move
	-- direction, drop the parts of it that would take the feet box off its support.
	RunService:BindToRenderStep("RocraftSneakEdge", Enum.RenderPriority.Input.Value + 1, function(dt)
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not MovementController.sneaking or not humanoid or not root or root.Anchored then
			return
		end
		local v = root.AssemblyLinearVelocity
		if not onGround(humanoid) or v.Y > 1 or MovementController.inLiquid then
			return -- Java: only while standing on the ground (jumping off is allowed)
		end
		local dir = humanoid.MoveDirection
		local p = root.Position / BS
		local feetY = (root.Position.Y - FEET_BELOW_ROOT) / BS
		local look = math.max(humanoid.WalkSpeed * dt * 2 / BS, 0.04) -- blocks ahead to test
		local dx = if math.abs(dir.X) > 1e-3 then math.sign(dir.X) * look else 0
		local dz = if math.abs(dir.Z) > 1e-3 then math.sign(dir.Z) * look else 0
		local okX = dx == 0 or supported(p.X + dx, feetY, p.Z)
		local okZ = dz == 0 or supported(p.X, feetY, p.Z + dz)
		if okX and okZ and dx ~= 0 and dz ~= 0 and not supported(p.X + dx, feetY, p.Z + dz) then
			okX, okZ = false, false
		end
		if not okX or not okZ then
			local mx = if okX then dir.X else 0
			local mz = if okZ then dir.Z else 0
			humanoid:Move(Vector3.new(mx, 0, mz), false)
			root.AssemblyLinearVelocity = Vector3.new(if okX then v.X else 0, v.Y, if okZ then v.Z else 0)
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
		-- Sneaking: Shift held (not in a window), or forced while there's no room to stand.
		local keySneak = (Enum.KeyCode :: any)[Config.KEY_SNEAK]
		local wantSneak = (UserInputService:IsKeyDown(keySneak) or touchSneak) and not InventoryClient.uiOpen
			and not root.Anchored and humanoid.Health > 0
		local pb = root.Position / BS
		local feetB = (root.Position.Y - FEET_BELOW_ROOT) / BS
		local crouch = wantSneak or (MovementController.sneaking and not roomToStand(pb.X, feetB, pb.Z))
		if crouch ~= MovementController.sneaking then
			MovementController.sneaking = crouch
			SneakPose.apply(character :: Model, crouch)
			SneakPose.setCollision(character :: Model, crouch)
			SurvivalClient.setSneaking(crouch)
		end
		-- Java eye height eases toward the target (half the difference per tick)
		local targetEye = if crouch then Config.EYE_HEIGHT_SNEAK else Config.EYE_HEIGHT
		MovementController.eyeHeight += (targetEye - MovementController.eyeHeight) * (1 - 0.5 ^ (dt * 20))

		-- Sprint latch: needs forward movement, food > 6, not sneaking or using an item, and not
		-- pushing against a wall.
		local forward = humanoid.MoveDirection:Dot(root.CFrame.LookVector) > 0.5
		if UserInputService:IsKeyDown(keySprint) and forward and canStartSprint(humanoid) then
			sprintLatch = true -- Ctrl held while walking forward
		end
		if not forward or not canStartSprint(humanoid) then
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
		if crouch then
			speed *= Config.SNEAK_SPEED_FACTOR
		end
		if MovementController.usingItem then
			speed *= Config.ITEM_USE_SPEED_FACTOR
		end
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

		-- Java terminal velocity
		local vel = root.AssemblyLinearVelocity
		if vel.Y < -Config.TERMINAL_FALL_SPEED and not root.Anchored then
			root.AssemblyLinearVelocity = Vector3.new(vel.X, -Config.TERMINAL_FALL_SPEED, vel.Z)
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
