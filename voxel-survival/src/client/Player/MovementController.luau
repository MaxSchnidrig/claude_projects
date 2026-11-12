--!strict
-- The local player's movement: Java Edition physics, run by us (the client simulates its own
-- character; the server checks positions, falls and reach).
--
-- The Roblox Humanoid does not move the player. It stays in its "Physics" state (no walking,
-- jumping, landing or ledge snapping of its own) and only carries the body and its animations.
-- Every 20 Hz tick Gameplay/PlayerMotor runs Java's player physics on a 0.6 x 1.8 block box
-- (1.5 while sneaking) against the real block shapes; every frame the body is put where the box
-- is, between the last two ticks.
--
-- Rules this file keeps (each one was a bug once):
--   * The motor's own numbers are the truth. The body's position is never read back, except
--     when a character spawns and when the server lets go of it after holding it (a bed).
--     Reading it back loses precision (a Vector3 is 32-bit: the box ends up a hair inside the
--     wall it touched and walks through it) and picks up whatever Roblox physics did to the
--     body in between (a long frame drops it through the floor).
--   * The body collides with nothing (ghost collision group) and has no weight (a force
--     cancels gravity), so Roblox physics leaves it where we put it.
--   * Nothing in the per-frame code may wait (WaitForChild and friends).
--   * The server moves the player by telling us (MovementController.teleport), not by moving
--     the body under us.
--
--   walk 4.317 b/s, sprint 5.612 b/s, held sprint-jump about 7.1 b/s, jump 1.2522 blocks
--   step up 0.6 blocks (slabs, stairs); fences, walls and gates are 1.5: no jumping over them
--   sprint: double-tap W (7 ticks) or the gamepad stick click; ends on W release, a real
--           collision with a wall (Java: more than 8 degrees off your input), wading in water,
--           hunger, sneaking or using an item
--   sneak:  Left Shift; slower, 1.5 blocks tall, no walking off edges; you stay crouched while
--           there is no room to stand
--   ladders, vines, water, lava, ice, beds, falls: see PlayerMotor

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Shapes = require(Shared.Blocks.Shapes)
local SurvivalClient = require(script.Parent.Parent.Survival.SurvivalClient)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local InventoryClient = require(script.Parent.Parent.Player.InventoryClient)
local SneakPose = require(Shared.Gameplay.SneakPose)
local PlayerMotor = require(Shared.Gameplay.PlayerMotor)
local Combat = require(Shared.Gameplay.Combat)
local Remotes = require(Shared.Net.Remotes)

local BS = Config.BLOCK_SIZE
local TICK = PlayerMotor.TICK
local FEET_BELOW_ROOT = 3 -- studs from the HumanoidRootPart centre down to the feet
local BASE_FOV = 70

local MovementController = {}
MovementController.sprinting = false
MovementController.inLiquid = false
MovementController.onLadder = false
MovementController.onGround = true -- Java onGround (use this, not Humanoid.FloorMaterial)
MovementController.sleeping = false -- lying in a bed (BedClient): the view drops to the pillow
MovementController.bowPull = 0 -- 0..1 while drawing a bow (BlockInteraction): FOV zoom
MovementController.stepOffset = 0 -- studs added to the camera height (kept 0: see tick)
MovementController.sneaking = false -- crouched (Shift held, or no room to stand)
MovementController.usingItem = false -- eating / bow / crossbow / shield (BlockInteraction)
MovementController.eyeHeight = Config.EYE_HEIGHT -- studs above the root, eases when sneaking
MovementController.spectating = false -- Studio test tool (Java spectator mode comes in phase 21)
MovementController.velocity = Vector3.zero -- blocks/tick (crits, sounds, view bobbing)
MovementController.lookYaw = 0 -- where the player looks (radians); CameraController sets it
-- Diagnostics for the F3 overlay and the headless tests.
MovementController.stats = { ticks = 0, held = false, waitingForChunk = false }

-- The local player's box: Java state (PlayerMotor, block units, doubles) and what the frame
-- loop needs around it.
type Body = {
	character: Model,
	st: PlayerMotor.State,
	px: number, -- position at the previous tick (the body is drawn between the two)
	py: number,
	pz: number,
	acc: number, -- time not yet turned into ticks
	held: boolean, -- the server holds the body (anchored: asleep in a bed, frozen after death)
	force: VectorForce?, -- cancels gravity on the body
}
local body: Body? = nil
local pendingTeleport: Vector3? = nil

-- Lying in a bed (BedClient): the client itself puts the body on the pillow and holds it
-- there, so the view is right even before the server's anchored pose replicates.
local sleepPose: { mid: Vector3, dir: Vector3, eye: Vector3 }? = nil

local sprintLatch = false
local sprintTriggerUntil = -math.huge
local touchSneak = false

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

-- Sleeping (BedClient). `head` is the bed's head cell (blocks) and `facing` the bed's facing;
-- nil wakes up. While asleep the body lies on the bed with the head on the pillow, exactly as
-- the server posed it, whether or not that pose has replicated.
function MovementController.sleep(head: Vector3?, facing: string?)
	local v = facing and (Shapes.DIR :: any)[facing]
	if head and v then
		local dir = Vector3.new(v[1], 0, v[2])
		local mid = (head + Vector3.new(0.5, 0.6, 0.5) - dir * 0.5) * BS
		-- Java: the sleeper is at the head cell (+0.5, +0.6875, +0.5) with eye height 0.2, and the
		-- camera looks level toward the foot of the bed, pulled back 0.3 toward the headboard
		local eye = (head + Vector3.new(0.5, 0.6875 + 0.2, 0.5) + dir * 0.3) * BS
		sleepPose = { mid = mid, dir = dir, eye = eye }
	else
		sleepPose = nil
	end
	MovementController.sleeping = sleepPose ~= nil
end

-- The sleeping view: eye position (studs) and look direction, or nil when awake.
function MovementController.sleepView(): (Vector3?, Vector3?)
	local sp = sleepPose
	if not sp or not MovementController.sleeping then
		return nil, nil
	end
	return sp.eye, -sp.dir
end

-- Touch button: toggle sneaking.
function MovementController.toggleSneak()
	touchSneak = not touchSneak
end

-- The server moved the player (waking up next to a bed, later: commands, portals). `feet` is
-- the new feet position in blocks.
function MovementController.teleport(feet: Vector3)
	pendingTeleport = feet
end

-- Feet position in blocks (the motor's own, exact), or nil without a character.
function MovementController.feet(): Vector3?
	local b = body
	return if b then Vector3.new(b.st.x, b.st.y, b.st.z) else nil
end

local function canStartSprint(): boolean
	if MovementController.spectating then
		return true -- spectators sprint-fly regardless of hunger
	end
	return SurvivalClient.canSprint and not SurvivalClient.dead and not MovementController.sneaking
		and not MovementController.usingItem
end

-- Put the box at a position that came from outside (a spawn, the server): no speed, and
-- nudged out of anything it overlaps by a rounding error.
local function resync(b: Body, feet: Vector3)
	local st = b.st
	st.x, st.y, st.z = feet.X, feet.Y, feet.Z
	st.vx, st.vy, st.vz = 0, 0, 0
	st.onGround = false
	st.fallDistance = 0
	st.noJumpDelay = 0
	if PlayerMotor.loaded(world, st) then
		PlayerMotor.settle(st, world, MovementController.sneaking)
		PlayerMotor.unstick(st, world, MovementController.sneaking)
	end
	b.px, b.py, b.pz = st.x, st.y, st.z
	b.acc = 0
end

local function feetOf(root: BasePart): Vector3
	return (root.Position - Vector3.new(0, FEET_BELOW_ROOT, 0)) / BS
end

-- Put the body at a feet position (blocks), facing `yaw`, with the speed it is moving at
-- (studs/s; the server and other players' views read it).
local function place(b: Body, root: BasePart, x: number, y: number, z: number, yaw: number, velocity: Vector3)
	root.CFrame = CFrame.new(x * BS, y * BS + FEET_BELOW_ROOT, z * BS) * CFrame.Angles(0, yaw, 0)
	root.AssemblyLinearVelocity = velocity
	root.AssemblyAngularVelocity = Vector3.zero
	local force = b.force
	if force then
		force.Force = Vector3.new(0, root.AssemblyMass * workspace.Gravity, 0)
	end
end

-- Movement keys, the gamepad stick or the touch thumbstick: forward and strafe (-1..1, relative
-- to where the player looks) and whether jump is held. (fx, fz) is the horizontal look direction.
local function readInput(humanoid: Humanoid, fx: number, fz: number): (number, number, boolean)
	if InventoryClient.uiOpen or SurvivalClient.dead or GuiService.MenuIsOpen then
		return 0, 0, false
	end
	local forward, strafe, jump = 0, 0, false
	if UserInputService:GetFocusedTextBox() == nil then -- (typing must not move you)
		forward = (if UserInputService:IsKeyDown(Enum.KeyCode.W) then 1 else 0) - (if UserInputService:IsKeyDown(Enum.KeyCode.S) then 1 else 0)
		strafe = (if UserInputService:IsKeyDown(Enum.KeyCode.D) then 1 else 0) - (if UserInputService:IsKeyDown(Enum.KeyCode.A) then 1 else 0)
		jump = UserInputService:IsKeyDown(Enum.KeyCode.Space)
	end
	if forward == 0 and strafe == 0 and UserInputService.GamepadEnabled then
		for _, state in UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1) do
			if state.KeyCode == Enum.KeyCode.Thumbstick1 and state.Position.Magnitude > 0.2 then
				forward, strafe = state.Position.Y, state.Position.X
			elseif state.KeyCode == Enum.KeyCode.ButtonA and state.UserInputState == Enum.UserInputState.Begin then
				jump = true
			end
		end
	end
	if UserInputService.TouchEnabled then
		-- Roblox's touch controls: the thumbstick's direction (world space) arrives in the
		-- Humanoid's move direction, the jump button in its Jump flag
		if forward == 0 and strafe == 0 then
			local md = humanoid.MoveDirection
			if md.Magnitude > 0.05 then
				forward = md.X * fx + md.Z * fz
				strafe = md.X * -fz + md.Z * fx
			end
		end
		jump = jump or humanoid.Jump
	end
	return math.clamp(forward, -1, 1), math.clamp(strafe, -1, 1), jump
end

-- One Java tick of the local player, and what follows from it.
local function tick(b: Body, forward: number, strafe: number, jumpHeld: boolean, fx: number, fz: number)
	local st = b.st
	b.px, b.py, b.pz = st.x, st.y, st.z
	local r = PlayerMotor.tick(st, {
		forward = forward, strafe = strafe, lookX = fx, lookZ = fz, jump = jumpHeld,
		sneak = MovementController.sneaking, sprint = MovementController.sprinting,
		usingItem = MovementController.usingItem,
	}, world)
	MovementController.stats.ticks += 1
	MovementController.inLiquid = r.fluid ~= nil
	MovementController.onLadder = r.onLadder
	MovementController.onGround = st.onGround
	MovementController.velocity = Vector3.new(st.vx, st.vy, st.vz)
	-- (a step up needs no camera smoothing of its own: the body already moves smoothly between
	-- the two ticks, like Java; an extra glide on top made the camera dip on every slab / stair)
	if r.fall and r.fall > 3 then
		SurvivalClient.reportFall(r.fall) -- the server checks it (and halves it on a bed)
	end
	if MovementController.sprinting then
		-- Java: a real collision ends the sprint (a glancing one doesn't), and so does wading
		if r.hitWall and not r.minorWall then
			sprintLatch = false
		elseif r.fluid == "water" then
			local eyes = st.y + (if MovementController.sneaking then 1.27 else 1.62)
			local id = ClientWorld.getBlock(math.floor(st.x), math.floor(eyes), math.floor(st.z))
			if not (id and BlockRegistry.isLiquid[id + 1]) then
				sprintLatch = false -- head above the water
			end
		end
	end
end

local function loadAnimations(character: Model, humanoid: Humanoid)
	table.clear(tracks)
	playing = nil
	-- in its own thread: these wait for the server's copies, and the frame loop must not
	task.spawn(function()
		local animator = humanoid:WaitForChild("Animator", 5)
		local animate = character:WaitForChild("Animate", 5)
		if Players.LocalPlayer.Character ~= character then
			return
		end
		if not animator or not animator:IsA("Animator") then
			-- the server's Animator never arrived: make our own (it works the same locally)
			local a = Instance.new("Animator")
			a.Parent = humanoid
			animator = a
		end
		local mine: { [AnimationTrack]: boolean } = {}
		if animate and animate:IsA("LocalScript") then
			animate.Enabled = false
			for _, name in { "idle", "walk", "run", "jump", "fall", "climb" } do
				local holder = animate:FindFirstChild(name)
				local animation = holder and holder:FindFirstChildOfClass("Animation")
				if animation then
					local ok, track = pcall(function()
						return animator:LoadAnimation(animation)
					end)
					if ok and track then
						tracks[name] = track
						mine[track] = true
					end
				end
			end
		end
		for _, t in animator:GetPlayingAnimationTracks() do
			if not mine[t] then
				t:Stop(0) -- whatever the Animate script had started
			end
		end
	end)
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

-- A new character: hand its movement over to the motor.
local function configure(humanoid: Humanoid)
	local character = humanoid.Parent :: Model
	local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
	if not root or Players.LocalPlayer.Character ~= character then
		return
	end
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = Config.JUMP_HEIGHT -- (keeps Roblox's touch jump button visible)
	humanoid.AutoRotate = false
	humanoid.WalkSpeed = 0
	for _, state in {
		Enum.HumanoidStateType.Climbing, Enum.HumanoidStateType.GettingUp, Enum.HumanoidStateType.FallingDown,
		Enum.HumanoidStateType.Ragdoll, Enum.HumanoidStateType.Swimming, Enum.HumanoidStateType.Seated,
	} do
		humanoid:SetStateEnabled(state, false)
	end
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	SneakPose.remember(character)
	-- The body never collides: our box does the colliding. The ghost collision group collides
	-- with nothing, and unlike CanCollide the Humanoid doesn't switch it back on for the torso
	-- and head (which made Roblox push the body out of walls).
	local function ghost(d: Instance)
		if d:IsA("BasePart") then
			d.CanCollide = false
			pcall(function()
				d.CollisionGroup = SneakPose.GHOST_GROUP
			end)
		end
	end
	for _, d in character:GetDescendants() do
		ghost(d)
	end
	character.DescendantAdded:Connect(ghost)
	-- ... and it has no weight: without this it would fall between our frames (it has nothing
	-- to stand on), far in a long frame
	local attachment = Instance.new("Attachment")
	attachment.Name = "MotorAttachment"
	attachment.Parent = root
	local force = Instance.new("VectorForce")
	force.Name = "MotorAntiGravity"
	force.Attachment0 = attachment
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true
	force.Force = Vector3.new(0, root.AssemblyMass * workspace.Gravity, 0)
	force.Parent = root

	loadAnimations(character, humanoid)
	sleepPose = nil -- a new body is never in bed (died while sleeping)
	MovementController.sleeping = false
	MovementController.sneaking = false
	MovementController.eyeHeight = Config.EYE_HEIGHT
	MovementController.stepOffset = 0
	MovementController.velocity = Vector3.zero
	-- where the server spawned us (exact; the body itself may have dropped a little while the
	-- server still simulated it), else the body's position
	local named = character:GetAttribute("SpawnFeet")
	local feet = if typeof(named) == "Vector3" then named else feetOf(root)
	local b: Body = {
		character = character,
		st = PlayerMotor.new(feet.X, feet.Y, feet.Z),
		px = feet.X, py = feet.Y, pz = feet.Z,
		acc = 0,
		held = false,
		force = force,
	}
	resync(b, feet)
	pendingTeleport = nil
	body = b
end

local function setSpectating(on: boolean)
	local b = body
	if not b then
		return
	end
	MovementController.spectating = on
	Players.LocalPlayer:SetAttribute("Spectating", on)
	sprintLatch = false
	local st = b.st
	st.vx, st.vy, st.vz = 0, 0, 0
	st.onGround = false
	st.fallDistance = 0
	b.px, b.py, b.pz = st.x, st.y, st.z
	b.acc = 0
	print(`[Spectator] {if on then "on (N to leave)" else "off"}`)
end

-- Every frame, before the camera: read the input, run the ticks, place the body.
local function step(dt: number)
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local b = body
	if not character or not humanoid or not root or not b or b.character ~= character then
		return
	end
	local st = b.st
	local yaw = MovementController.lookYaw
	local fx, fz = -math.sin(yaw), -math.cos(yaw)
	local forward, strafe, jumpHeld = readInput(humanoid, fx, fz)

	-- sprint latch: needs forward movement, food > 6, not sneaking or using an item
	if forward <= 1e-5 or not canStartSprint() then
		sprintLatch = false
	end
	if sprintLatch ~= MovementController.sprinting then
		MovementController.sprinting = sprintLatch
		if not MovementController.spectating then
			SurvivalClient.setSprinting(sprintLatch) -- the server charges sprint exhaustion
		end
	end

	-- eye height eases toward its target (half the difference per tick); a step up glides
	local targetEye = if MovementController.sleeping then 0.3 * BS
		elseif MovementController.sneaking then Config.EYE_HEIGHT_SNEAK else Config.EYE_HEIGHT
	MovementController.eyeHeight += (targetEye - MovementController.eyeHeight) * (1 - 0.5 ^ (dt * 20))
	MovementController.stepOffset *= 0.5 ^ (dt * 30)
	if math.abs(MovementController.stepOffset) < 0.01 then
		MovementController.stepOffset = 0
	end
	-- FOV: Java x (speed / walking speed + 1) / 2, so sprinting is x1.15 (70 -> 80.5); a drawn
	-- bow zooms in by up to 15 %; eased by half the remaining gap per tick
	local camera = workspace.CurrentCamera
	if camera then
		local targetFov = (if MovementController.sprinting then BASE_FOV * 1.15 else BASE_FOV) * (1 - MovementController.bowPull * 0.15)
		camera.FieldOfView += (targetFov - camera.FieldOfView) * (1 - 0.5 ^ (dt * 20))
	end

	-- Asleep in a bed: the client holds the body in the lying pose itself (the server's
	-- anchored pose may not have replicated into a body the client owns), and the camera
	-- sinks to the pillow through eyeHeight above.
	local sp = sleepPose
	if MovementController.sleeping and sp and humanoid.Health > 0 and not SurvivalClient.dead then
		st.x, st.z = sp.mid.X / BS, sp.mid.Z / BS
		st.y = sp.mid.Y / BS - 1 -- the root sits one block over the feet
		st.vx, st.vy, st.vz = 0, 0, 0
		st.onGround = true
		st.fallDistance = 0
		b.px, b.py, b.pz = st.x, st.y, st.z
		b.acc = 0
		MovementController.velocity = Vector3.zero
		MovementController.stats.held = root.Anchored
		b.held = false
		-- body along the bed, head on the pillow (the server's exact pose)
		root.CFrame = CFrame.lookAt(sp.mid, sp.mid + Vector3.yAxis, sp.dir)
		if not root.Anchored then
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			local force = b.force
			if force then
				force.Force = Vector3.new(0, root.AssemblyMass * workspace.Gravity, 0)
			end
		end
		playAnim("idle", 1)
		return
	end

	-- The server holds the body (asleep in a bed, frozen after death): hands off.
	if root.Anchored then
		b.held = true
		MovementController.stats.held = true
		MovementController.velocity = Vector3.zero
		return
	end
	if b.held then
		-- let go: start from where it left the body, unless it named the spot
		b.held = false
		MovementController.stats.held = false
		resync(b, feetOf(root))
	end
	local target = pendingTeleport
	if target then
		pendingTeleport = nil
		resync(b, target)
	end
	if humanoid:GetState() ~= Enum.HumanoidStateType.Physics and humanoid.Health > 0 then
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end

	if humanoid.Health <= 0 or SurvivalClient.dead then
		-- dead: stay where we died until the server freezes the body
		MovementController.velocity = Vector3.zero
		place(b, root, st.x, st.y, st.z, yaw, Vector3.zero)
		return
	end

	if MovementController.spectating then
		-- fly freely, through blocks; Space up, Shift down, sprint doubles the speed
		local up = (if UserInputService:IsKeyDown(Enum.KeyCode.Space) then 1 else 0)
			- (if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then 1 else 0)
		if InventoryClient.uiOpen or UserInputService:GetFocusedTextBox() ~= nil then
			up = 0
		end
		local speed = Config.SPECTATOR_SPEED * (if MovementController.sprinting then 2 else 1) -- blocks/s
		local wx, wz = fx * forward - fz * strafe, fz * forward + fx * strafe
		local len = math.sqrt(wx * wx + wz * wz)
		if len > 1 then
			wx, wz = wx / len, wz / len
		end
		st.x += wx * speed * dt
		st.y += up * speed * dt
		st.z += wz * speed * dt
		st.vx, st.vy, st.vz = 0, 0, 0
		st.onGround = false
		st.fallDistance = 0
		b.px, b.py, b.pz = st.x, st.y, st.z
		b.acc = 0
		MovementController.onGround = false
		MovementController.inLiquid = false
		MovementController.onLadder = false
		MovementController.velocity = Vector3.new(wx, up, wz) * (speed / 20)
		place(b, root, st.x, st.y, st.z, yaw, Vector3.new(wx, up, wz) * (speed * BS))
		playAnim("idle", 1)
		return
	end

	-- The chunk we stand in isn't here yet (just respawned far away): wait, don't simulate
	-- inside unknown blocks.
	if not PlayerMotor.loaded(world, st) then
		MovementController.stats.waitingForChunk = true
		MovementController.velocity = Vector3.zero
		b.acc = 0
		place(b, root, st.x, st.y, st.z, yaw, Vector3.zero)
		return
	end
	if MovementController.stats.waitingForChunk then
		-- the chunk just arrived: make sure we don't start inside one of its blocks
		MovementController.stats.waitingForChunk = false
		PlayerMotor.settle(st, world, MovementController.sneaking)
		PlayerMotor.unstick(st, world, MovementController.sneaking)
		b.px, b.py, b.pz = st.x, st.y, st.z
	end

	-- sneaking: Shift held (not in a window), or forced while there's no room to stand
	local keySneak = (Enum.KeyCode :: any)[Config.KEY_SNEAK]
	local wantSneak = ((UserInputService:IsKeyDown(keySneak) and UserInputService:GetFocusedTextBox() == nil) or touchSneak)
		and not InventoryClient.uiOpen
	local crouch = wantSneak or (MovementController.sneaking and not PlayerMotor.roomToStand(world, st))
	if crouch ~= MovementController.sneaking then
		MovementController.sneaking = crouch
		SneakPose.apply(character, crouch)
		SurvivalClient.setSneaking(crouch)
	end

	-- fixed 20 Hz ticks (at most 5 per frame: a long frame slows the game down instead of
	-- running away)
	b.acc = math.min(b.acc + dt, 0.25)
	while b.acc >= TICK do
		b.acc -= TICK
		tick(b, forward, strafe, jumpHeld, fx, fz)
	end
	-- the body goes between the last two ticks, moving at the speed that takes it there
	local alpha = b.acc / TICK
	local x = b.px + (st.x - b.px) * alpha
	local y = b.py + (st.y - b.py) * alpha
	local z = b.pz + (st.z - b.pz) * alpha
	local rate = BS / TICK
	place(b, root, x, y, z, yaw, Vector3.new((st.x - b.px) * rate, (st.y - b.py) * rate, (st.z - b.pz) * rate))

	-- animations
	local hs = math.sqrt(st.vx * st.vx + st.vz * st.vz) * 20 * BS -- studs/s
	if MovementController.onLadder and math.abs(st.y - b.py) > 0.01 then
		playAnim("climb", 1)
	elseif not st.onGround and not MovementController.inLiquid then
		playAnim(if st.vy > 0 then "jump" else "fall", 1)
	elseif hs > 0.5 then
		playAnim("walk", math.clamp(hs / 14, 0.3, 1.6))
	else
		playAnim("idle", 1)
	end
end

function MovementController.init()
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
				sprintLatch = true -- gamepad: left stick click; needs forward movement
			end
		elseif input.KeyCode == (Enum.KeyCode :: any)[Config.DEBUG_KEY_SPECTATOR] and RunService:IsStudio() then
			-- Spectator mode (Studio only): fly through blocks, no collision, no interaction
			setSpectating(not MovementController.spectating)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.KeyCode == Enum.KeyCode.W then
			sprintLatch = false
		end
	end)

	-- Knockback: Java's formula on our own velocity (hits), or a push added to it (explosions).
	Remotes.get("Knockback").OnClientEvent:Connect(function(kb: any)
		local b = body
		if typeof(kb) ~= "table" or not b or b.held or MovementController.spectating then
			return
		end
		local st = b.st
		if typeof(kb.dir) == "Vector3" and typeof(kb.strength) == "number" then
			st.vx, st.vy, st.vz = Combat.knockback(st.vx, st.vy, st.vz, kb.dir.X, kb.dir.Z, kb.strength, st.onGround)
		elseif typeof(kb.add) == "Vector3" then
			st.vx += kb.add.X
			st.vy += kb.add.Y
			st.vz += kb.add.Z
		end
	end)

	Players.LocalPlayer.CharacterAdded:Connect(function(character)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			configure(humanoid)
		end
	end)
	local existing = Players.LocalPlayer.Character
	if existing then
		local h = existing:FindFirstChildOfClass("Humanoid")
		if h then
			task.spawn(configure, h)
		end
	end

	RunService:BindToRenderStep("RocraftMotor", Enum.RenderPriority.Input.Value + 1, step)
end

return MovementController
