--!strict
-- The local player's movement: Java Edition physics, run by us (the client simulates its own
-- character; the server checks positions, falls and reach).
--
-- Since 0.8.8 the Roblox Humanoid no longer moves the player. It stays in its "Physics" state
-- (no walking, jumping, landing or ledge snapping of its own) and only carries the body and its
-- animations. Every 20 Hz tick this module runs Java's player physics on a 0.6 x 1.8 block box
-- (1.5 while sneaking) against the real block shapes (Blocks/Shapes, MobPhysics), and the body is
-- placed where the box is, interpolated between ticks. That gives Java's behaviour exactly:
--
--   walk 4.317 b/s, sprint 5.612 b/s, held sprint-jump ~7.1 b/s, jump 1.2522 blocks
--   gravity 0.08 / tick, air drag 0.98, ground friction 0.546, air friction 0.91
--   step up 0.6 blocks (slabs, stairs) while on the ground; never higher, no ledge climbing
--   fences, walls and gates are 1.5 blocks: you can't jump over them
--   a ceiling only stops upward motion (forward motion in a low tunnel continues)
--   holding jump re-jumps on the landing tick, then every 10 ticks at most (noJumpDelay)
--   sprint: double-tap W (7 ticks) or the gamepad stick click; ends on W release, a head-on
--           wall, hunger, sneaking or using an item
--   sneak:  input x 0.3, eyes 1.27 blocks, body 1.5 blocks; on the ground you can't walk off an
--           edge with a drop of more than 0.6 (Java maybeBackOffFromEdge)
--   item use (eating, bow, crossbow, shield): input x 0.2
--   ladders and vines: falling capped at 0.15 / tick, climbing at 0.2 when pushing into
--           something or holding jump, sneaking holds you in place
--   water: acceleration 0.02, drag 0.8, sinking 0.005 / tick, jump swims up 0.04 / tick, a
--           current pushes 0.014 / tick, and swimming into a ledge lifts you out (0.3)
--   lava: the same with drag 0.5 and sinking 0.02
--   falls: reported on landing (the server checks them); beds bounce you at 66 %

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Shapes = require(Shared.Blocks.Shapes)
local SurvivalClient = require(script.Parent.Parent.Survival.SurvivalClient)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local InventoryClient = require(script.Parent.Parent.Player.InventoryClient)
local SneakPose = require(Shared.Gameplay.SneakPose)
local PlayerPhysics = require(Shared.Gameplay.PlayerPhysics)
local PlayerMotor = require(Shared.Gameplay.PlayerMotor)

local BS = Config.BLOCK_SIZE
local TICK = 0.05
local FEET_BELOW_ROOT = 3 -- studs from the HumanoidRootPart centre down to the feet
local BASE_FOV = 70

local MovementController = {}
MovementController.sprinting = false
MovementController.inLiquid = false
MovementController.onLadder = false
MovementController.onGround = true -- Java onGround (use this, not Humanoid.FloorMaterial)
MovementController.sleeping = false -- lying in a bed (BedClient): the view drops to the pillow
MovementController.bowPull = 0 -- 0..1 while drawing a bow (BlockInteraction): FOV zoom
MovementController.stepOffset = 0 -- studs; the camera glides after a step up instead of jumping
MovementController.sneaking = false -- crouched (Shift held, or no room to stand)
MovementController.usingItem = false -- eating / bow / crossbow / shield (BlockInteraction)
MovementController.eyeHeight = Config.EYE_HEIGHT -- studs above the root, eases when sneaking
MovementController.spectating = false -- Studio test tool (Java spectator mode comes in phase 21)
MovementController.velocity = Vector3.zero -- blocks/tick (crits, sounds)

-- Java state (PlayerMotor), block units. `pos` is the feet centre.
type Motor = PlayerMotor.State & {
	prev: Vector3, -- position at the previous tick (for interpolation)
	acc: number,
	lastSet: Vector3?, -- where we put the root last frame (studs): detects server teleports
}
local motor: Motor? = nil

local sprintLatch = false
local sprintTriggerUntil = -math.huge
local touchSneak = false
local inputDir = Vector3.zero -- world-space movement input, length <= 1

-- Animations: the default R6 animations, played by us (the Animate script follows Humanoid
-- states, which no longer change).
local tracks: { [string]: AnimationTrack } = {}
local playing: string? = nil

local world = PlayerMotor.world(function(x: number, y: number, z: number): number?
	return ClientWorld.getBlock(x, y, z)
end)

-- Java: a full-strength sprint hit ends the sprint.
function MovementController.stopSprint()
	sprintLatch = false
end

-- Touch button: toggle sneaking.
function MovementController.toggleSneak()
	touchSneak = not touchSneak
end

local function canStartSprint(): boolean
	if MovementController.spectating then
		return true -- spectators sprint-fly regardless of hunger
	end
	return SurvivalClient.canSprint and not SurvivalClient.dead and not MovementController.sneaking
		and not MovementController.usingItem
end

-- One Java tick of the local player, with its side effects.
local function tick(m: Motor, root: BasePart, jumpHeld: boolean)
	m.prev = m.pos
	local look = root.CFrame.LookVector
	local from = m.pos
	local r = PlayerMotor.tick(m, {
		moveX = inputDir.X, moveZ = inputDir.Z, jump = jumpHeld, sneak = MovementController.sneaking,
		sprint = MovementController.sprinting, usingItem = MovementController.usingItem,
		lookX = look.X, lookZ = look.Z,
	}, world)
	MovementController.inLiquid = r.fluid ~= nil
	MovementController.onLadder = r.onLadder
	MovementController.onGround = m.onGround
	MovementController.velocity = m.vel
	if r.stepUp > 0 then
		MovementController.stepOffset -= r.stepUp * BS -- the camera glides up the step
	end
	if r.fall and r.fall > 3 then
		SurvivalClient.reportFall(r.fall) -- the server checks it (and halves it on a bed)
	end
	-- sprint ends on a head-on wall (Java: a horizontal collision that isn't minor)
	if MovementController.sprinting and r.hitWall then
		local moved = Vector3.new(m.pos.X - from.X, 0, m.pos.Z - from.Z)
		if moved:Dot(Vector3.new(look.X, 0, look.Z)) < 0.02 then
			sprintLatch = false
		end
	end
end

-- Knockback from hits / explosions replaces the stored velocity (Combat.knockback).
local function addVelocity(v: Vector3)
	local m = motor
	if m then
		m.vel = v
		m.onGround = false
	end
end

local function loadAnimations(character: Model, humanoid: Humanoid)
	table.clear(tracks)
	playing = nil
	local animate = character:FindFirstChild("Animate")
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
	if animate and animate:IsA("LocalScript") then
		animate.Enabled = false
		for _, name in { "idle", "walk", "run", "jump", "fall", "climb" } do
			local v = animate:FindFirstChild(name)
			local a = v and v:FindFirstChildOfClass("Animation")
			if a then
				local ok, track = pcall(function()
					return animator:LoadAnimation(a)
				end)
				if ok and track then
					tracks[name] = track
				end
			end
		end
	end
	for _, t in animator:GetPlayingAnimationTracks() do
		t:Stop(0)
	end
end

local function playAnim(name: string, speed: number)
	local t = tracks[name] or (if name == "walk" then tracks.run else nil)
	if not t then
		return
	end
	if playing ~= name then
		local old = playing and (tracks[playing] or (if playing == "walk" then tracks.run else nil))
		if old then
			old:Stop(0.15)
		end
		t:Play(0.15)
		playing = name
	end
	t:AdjustSpeed(speed)
end

local function configure(humanoid: Humanoid)
	local character = humanoid.Parent :: Model
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = Config.JUMP_HEIGHT -- keeps the touch jump button
	humanoid.AutoRotate = false
	humanoid.WalkSpeed = 0
	for _, st in {
		Enum.HumanoidStateType.Running, Enum.HumanoidStateType.RunningNoPhysics, Enum.HumanoidStateType.Freefall,
		Enum.HumanoidStateType.Landed, Enum.HumanoidStateType.Climbing, Enum.HumanoidStateType.GettingUp,
		Enum.HumanoidStateType.FallingDown, Enum.HumanoidStateType.Ragdoll, Enum.HumanoidStateType.Swimming,
		Enum.HumanoidStateType.Seated, Enum.HumanoidStateType.StrafingNoPhysics, Enum.HumanoidStateType.Flying,
	} do
		humanoid:SetStateEnabled(st, false)
	end
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	SneakPose.remember(character)
	-- the body doesn't collide: our box does the colliding
	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
		end
	end
	character.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			d.CanCollide = false
		end
	end)
	loadAnimations(character, humanoid)
	MovementController.sneaking = false
	MovementController.eyeHeight = Config.EYE_HEIGHT
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if root then
		local feet = (root.Position - Vector3.new(0, FEET_BELOW_ROOT, 0)) / BS
		motor = { pos = feet, prev = feet, vel = Vector3.zero, onGround = false, noJumpDelay = 0, acc = 0, peak = nil, lastSet = nil }
	end
end

function MovementController.init()
	workspace.Gravity = Config.GRAVITY -- Java gravity (the server sets it too; items still use it)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.W then
			-- Java double-tap: the first press (on the ground) arms a 7-tick trigger, a second
			-- press while it is armed starts the sprint.
			local now = os.clock()
			if canStartSprint() then
				if now <= sprintTriggerUntil then
					sprintLatch = true
					sprintTriggerUntil = -math.huge
				elseif MovementController.onGround or MovementController.spectating then
					sprintTriggerUntil = now + Config.SPRINT_DOUBLE_TAP
				end
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonL3 then
			if canStartSprint() then
				sprintLatch = true -- gamepad: left stick click; needs forward movement below
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.W then
			sprintLatch = false
		end
	end)

	-- Spectator mode (Studio only, key N): fly through blocks, no collision, no interaction.
	local function setSpectating(on: boolean)
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			return
		end
		MovementController.spectating = on
		Players.LocalPlayer:SetAttribute("Spectating", on)
		sprintLatch = false
		local m = motor
		if m then
			local feet = (root.Position - Vector3.new(0, FEET_BELOW_ROOT, 0)) / BS
			m.pos, m.prev, m.vel, m.peak = feet, feet, Vector3.zero, nil
		end
		print(`[Spectator] {if on then "on (N to leave)" else "off"}`)
	end
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not RunService:IsStudio() then
			return
		end
		if input.KeyCode == (Enum.KeyCode :: any)[Config.DEBUG_KEY_SPECTATOR] then
			setSpectating(not MovementController.spectating)
		end
	end)

	-- Knockback (Java Combat.knockback on our own velocity, or an explosion push).
	local Remotes = require(Shared.Net.Remotes)
	local Combat = require(Shared.Gameplay.Combat)
	Remotes.get("Knockback").OnClientEvent:Connect(function(kb: any)
		local m = motor
		if typeof(kb) ~= "table" or not m or MovementController.spectating then
			return
		end
		local v = m.vel
		if typeof(kb.dir) == "Vector3" and typeof(kb.strength) == "number" then
			local x, y, z = Combat.knockback(v.X, v.Y, v.Z, kb.dir.X, kb.dir.Z, kb.strength, m.onGround)
			addVelocity(Vector3.new(x, y, z))
		elseif typeof(kb.add) == "Vector3" then
			addVelocity(v + kb.add)
		end
	end)

	Players.LocalPlayer.CharacterAdded:Connect(function(character)
		configure(character:WaitForChild("Humanoid") :: Humanoid)
	end)
	if Players.LocalPlayer.Character then
		local h = Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
		if h then
			task.spawn(configure, h)
		end
	end

	-- Before the camera (Input + 1): read input, run the ticks, place the body.
	RunService:BindToRenderStep("RocraftMotor", Enum.RenderPriority.Input.Value + 1, function(dt)
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local m = motor
		if not humanoid or not root or not m then
			return
		end
		-- movement input, relative to where the player faces: keys, else the gamepad stick, else
		-- the Humanoid's move direction (set by Roblox's touch controls on phones). Nothing here
		-- may wait: this runs every frame.
		local look = root.CFrame.LookVector
		local fwd = Vector3.new(look.X, 0, look.Z)
		fwd = if fwd.Magnitude > 1e-3 then fwd.Unit else Vector3.new(0, 0, -1)
		local right = Vector3.new(-fwd.Z, 0, fwd.X)
		local kf = (if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up) then 1 else 0)
			- (if UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down) then 1 else 0)
		local kr = (if UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then 1 else 0)
			- (if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then 1 else 0)
		local dir = fwd * kf + right * kr
		if dir.Magnitude < 0.01 then
			for _, st in UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1) do
				if st.KeyCode == Enum.KeyCode.Thumbstick1 and st.Position.Magnitude > 0.2 then
					dir = fwd * st.Position.Y + right * st.Position.X
				end
			end
		end
		if dir.Magnitude < 0.01 then
			local md = humanoid.MoveDirection -- touch thumbstick (world space)
			dir = Vector3.new(md.X, 0, md.Z)
		end
		if dir.Magnitude > 1 then
			dir = dir.Unit
		end
		inputDir = if InventoryClient.uiOpen or SurvivalClient.dead then Vector3.zero else dir
		local jumpHeld = (UserInputService:IsKeyDown(Enum.KeyCode.Space) or humanoid.Jump)
			and not InventoryClient.uiOpen and not SurvivalClient.dead

		-- spectating: fly freely (no collision)
		if MovementController.spectating then
			local up = (if UserInputService:IsKeyDown(Enum.KeyCode.Space) then 1 else 0)
				- (if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then 1 else 0)
			local speed = Config.SPECTATOR_SPEED * BS * (if MovementController.sprinting then 2 else 1)
			local v = inputDir * speed + Vector3.new(0, up * speed, 0)
			root.CFrame = CFrame.new(root.Position + v * dt) * root.CFrame.Rotation
			root.AssemblyLinearVelocity = Vector3.zero
			m.pos = (root.Position - Vector3.new(0, FEET_BELOW_ROOT, 0)) / BS
			m.prev = m.pos
			m.lastSet = root.Position
			return
		end
		-- the server moved us (respawn, bed, teleport) or holds us (sleeping, anchored): follow it.
		-- Between our frames the body moves on by its velocity; more than 2 studs off that is
		-- someone else's doing.
		local last = m.lastSet
		if root.Anchored or humanoid.Health <= 0 then
			local feet = (root.Position - Vector3.new(0, FEET_BELOW_ROOT, 0)) / BS
			m.pos, m.prev, m.vel, m.peak = feet, feet, Vector3.zero, nil
			m.lastSet = nil
			return
		end
		local expected = if last then last + m.vel * 20 * BS * dt else nil -- physics carried it on by its velocity
		if not expected or (root.Position - expected).Magnitude > 2 then
			local feet = (root.Position - Vector3.new(0, FEET_BELOW_ROOT, 0)) / BS
			m.pos, m.prev, m.vel, m.peak = feet, feet, Vector3.zero, nil
		end
		if humanoid:GetState() ~= Enum.HumanoidStateType.Physics then
			humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		end

		-- sneaking: Shift held (not in a window), or forced while there's no room to stand
		local keySneak = (Enum.KeyCode :: any)[Config.KEY_SNEAK]
		local wantSneak = (UserInputService:IsKeyDown(keySneak) or touchSneak) and not InventoryClient.uiOpen
		local crouch = wantSneak or (MovementController.sneaking and not PlayerMotor.roomToStand(world, m.pos))
		if crouch ~= MovementController.sneaking then
			MovementController.sneaking = crouch
			SneakPose.apply(character :: Model, crouch)
			SurvivalClient.setSneaking(crouch)
		end

		-- sprint latch: needs forward movement, food > 6, not sneaking or using an item
		local forward = inputDir:Dot(fwd) > 0.5
		if not forward or not canStartSprint() then
			sprintLatch = false
		end
		if sprintLatch ~= MovementController.sprinting then
			MovementController.sprinting = sprintLatch
			SurvivalClient.setSprinting(sprintLatch) -- the server charges sprint exhaustion
		end

		-- fixed 20 Hz ticks
		m.acc = math.min(m.acc + dt, 0.25)
		while m.acc >= TICK do
			m.acc -= TICK
			tick(m, root, jumpHeld)
		end
		-- place the body between the last two ticks
		local alpha = m.acc / TICK
		local feet = m.prev:Lerp(m.pos, alpha)
		local at = feet * BS + Vector3.new(0, FEET_BELOW_ROOT, 0)
		root.CFrame = CFrame.new(at) * root.CFrame.Rotation
		-- its real velocity: the server reads it (jump hunger, crits) and other players' views use it
		root.AssemblyLinearVelocity = m.vel * 20 * BS
		m.lastSet = at

		-- eye height eases toward its target (half the difference per tick)
		local targetEye = if MovementController.sleeping then 0.3 * BS
			elseif crouch then Config.EYE_HEIGHT_SNEAK else Config.EYE_HEIGHT
		MovementController.eyeHeight += (targetEye - MovementController.eyeHeight) * (1 - 0.5 ^ (dt * 20))
		MovementController.stepOffset *= 0.5 ^ (dt * 30)
		if math.abs(MovementController.stepOffset) < 0.01 then
			MovementController.stepOffset = 0
		end

		-- animations
		local hs = Vector3.new(m.vel.X, 0, m.vel.Z).Magnitude * 20 * BS -- studs/s
		if MovementController.onLadder and math.abs(m.vel.Y) > 0.01 then
			playAnim("climb", 1)
		elseif not m.onGround and not MovementController.inLiquid then
			playAnim(if m.vel.Y > 0 then "jump" else "fall", 1)
		elseif hs > 0.5 then
			playAnim("walk", math.clamp(hs / 14, 0.3, 1.6))
		else
			playAnim("idle", 1)
		end

		-- FOV: Java AbstractClientPlayer.getFieldOfViewModifier: x (speed / walking speed + 1) / 2,
		-- so sprinting is x1.15 (70 -> 80.5); a drawn bow zooms in by up to 15 %. GameRenderer
		-- eases half the remaining gap per tick.
		local camera = workspace.CurrentCamera
		local targetFov = if MovementController.sprinting then BASE_FOV * 1.15 else BASE_FOV
		targetFov *= 1 - MovementController.bowPull * 0.15
		camera.FieldOfView += (targetFov - camera.FieldOfView) * (1 - 0.5 ^ (dt * 20))
	end)
end

return MovementController
