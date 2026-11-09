--!strict
-- Movement, Java Edition rules, applied to the local character (the client simulates its own
-- character's physics; the server applies the same base values on spawn).
--
--   walk 4.317 b/s, sprint 5.612 b/s, jump 1.2522 blocks, gravity 32 b/s^2
--   sprint     starts on a second W press within 7 ticks (0.35 s) of the first (the trigger is
--              armed by a W press while on the ground), or the gamepad stick click; ends when W
--              is released, forward movement stops, you hit a wall, get hungry (food <= 6), sneak
--              or use an item. Holding W again after a sprint ends does NOT resume it.
--   sneak      hold Left Shift: speed x 0.3, no sprinting, eyes 1.27 blocks, body 1.5 blocks
--              tall (fits under 1.5-block gaps), and on the ground you can't move off an edge
--              where nothing is within 0.6 blocks below your feet box. You stay crouched while
--              there's no room to stand. (Not while a window is open.)
--   item use   eating: speed x 0.2 (x 0.06 when also sneaking), no sprinting
--   jumping    holding jump re-jumps only 10 ticks after the previous jump (Java noJumpDelay);
--              from a jump, a fall or a knockback until the landing settles, horizontal movement
--              follows Java per tick (PlayerPhysics): sprint-jump +0.2 blocks/tick forward, air
--              acceleration 0.02 (0.026 sprinting), air drag 0.91, ground friction 0.546

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
local Fluids = require(Shared.World.Fluids)

local BS = Config.BLOCK_SIZE
local isLiquid = BlockRegistry.isLiquid
local isSolid = BlockRegistry.isSolid
local SWIM_UP_SPEED = 9 -- studs/s while holding jump in water
local SINK_SPEED = 5 -- max sinking speed in water (studs/s)
local SWIM_SPEED_FACTOR = 0.6 -- walking speed multiplier in liquid

local MovementController = {}
MovementController.sprinting = false
MovementController.inLiquid = false
MovementController.onLadder = false
MovementController.stepOffset = 0 -- studs; the camera lags behind a step-up and glides after it
MovementController.sneaking = false -- crouched (Shift held, or no room to stand)
MovementController.usingItem = false -- set by BlockInteraction while eating
MovementController.eyeHeight = Config.EYE_HEIGHT -- studs above the root, eases when sneaking
MovementController.spectating = false -- Studio test tool (Java spectator mode comes in phase 21)

local sprintLatch = false
local sprintTriggerUntil = -math.huge
local blockedTime = 0
local touchSneak = false
-- Fall tracking uses the character's real ground contact (Humanoid.FloorMaterial, from the
-- client's collision boxes): resets on every touch of the ground, step or edge.
local peakFeetY: number? = nil
local ladderHoldY: number? = nil -- sneaking on a ladder: the height to hold
local noLandWhileRising = false
-- Height guard: the highest the feet may legally get (blocks). Java can't jump higher than
-- 1.2522 blocks or step more than 0.6; a Roblox body could slide up block edges and climb onto
-- fences, walls or two-block ledges. See the end of the Heartbeat.
local guard = { top = nil :: number?, lastPos = nil :: Vector3?, lastLegal = nil :: CFrame? }
local function raiseLimit(feet: number, vyStuds: number)
	local g = Config.GRAVITY / BS
	local vy = math.max(vyStuds / BS, 0)
	guard.top = math.max(guard.top or feet, feet + vy * vy / (2 * g) + 0.1)
end
local FEET_BELOW_ROOT = 3
local BASE_FOV = 70
-- Java horizontal movement (PlayerPhysics) takes over from the Humanoid from a jump, a fall or a
-- knockback until a landing has settled back to normal ground speed. Velocities in blocks/tick.
local sim = { active = false, sx = 0, sz = 0, acc = 0, jumpTick = false, lastCmd = Vector3.zero }
-- Held-jump delay (Java noJumpDelay): 10 ticks after a jump while jump stays held.
local lastJumpAt = -math.huge
local jumpEnabled = true
local heldSinceJump = false -- jump held without a break since the last jump
-- The player's own movement input this frame (the movement simulation overrides MoveDirection).
local inputDir = Vector3.zero
-- Sneak edge guard: last position standing on support while sneaking, whether we're in the air
-- because of a jump (then the guard is off), and a small invisible ledge under the body centre:
-- Java lets you lean out until the 0.6-wide box loses support, Roblox would drop you as soon as
-- the centre passes the edge.
local lastSupported: Vector3? = nil
local airborneByJump = false
local ledge: Part? = nil

local function setLedge(pos: Vector3?)
	if not pos then
		if ledge then
			ledge.Parent = nil
		end
		return
	end
	local l = ledge
	if not l then
		local p = Instance.new("Part")
		p.Name = "SneakLedge"
		p.Anchored = true
		p.Transparency = 1
		p.CanTouch = false
		p.CastShadow = false
		p.Size = Vector3.new(0.6, 0.2, 0.6)
		ledge = p
		l = p
	end
	local part = l :: Part
	part.CFrame = CFrame.new(pos)
	part.Parent = workspace
end

local function startSim(vx: number, vz: number)
	sim.active = true
	sim.sx, sim.sz = vx, vz
	sim.acc = 0
end

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
		-- Java has no friction against walls and ceilings: a head bump must not slow you down
		for _, d in character:GetDescendants() do
			if d:IsA("BasePart") then
				d.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0, 0, 100, 1)
			end
		end
	end
	MovementController.sneaking = false
	MovementController.eyeHeight = Config.EYE_HEIGHT
	sim.active = false
	jumpEnabled = true
	humanoid.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Jumping then
			lastJumpAt = os.clock()
			local r0 = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart") :: BasePart?
			if r0 then
				guard.top = (r0.Position.Y - FEET_BELOW_ROOT) / BS + Config.JUMP_HEIGHT / BS + 0.05
			end
			heldSinceJump = true
			airborneByJump = true -- jumping off an edge while sneaking is allowed
			local root = humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not sim.active and root then
				-- leaving the ground at full speed: Java's stored velocity is disp x 0.546
				local v = root.AssemblyLinearVelocity / BS / 20
				startSim(v.X * PlayerPhysics.GROUND_FRICTION, v.Z * PlayerPhysics.GROUND_FRICTION)
			end
			sim.active = true
			sim.jumpTick = true
		end
	end)
end

local function onGround(humanoid: Humanoid): boolean
	return humanoid.FloorMaterial ~= Enum.Material.Air
end

local function canStartSprint(humanoid: Humanoid): boolean
	if MovementController.spectating then
		return true -- spectators sprint-fly regardless of hunger
	end
	return SurvivalClient.canSprint and not SurvivalClient.dead and not MovementController.sneaking
		and not MovementController.usingItem
end

-- Any block collision box inside this box (block units)? Unloaded counts as solid. Uses real
-- block shapes (slabs, stairs, fences), including fences reaching up from the cell below.
local physicsAt = Shapes.physicsFn(function(x: number, y: number, z: number): number?
	return ClientWorld.getBlock(x, y, z)
end)
local function solidIn(x0: number, y0: number, z0: number, x1: number, y1: number, z1: number): boolean
	for x = math.floor(x0), math.ceil(x1) - 1 do
		for y = math.floor(y0) - 1, math.ceil(y1) - 1 do
			for z = math.floor(z0), math.ceil(z1) - 1 do
				local s = physicsAt(x, y, z)
				if s == true then
					if y >= math.floor(y0) then
						return true
					end
				elseif s then
					for _, b in s do
						if x + b[4] > x0 and x + b[1] < x1 and y + b[5] > y0 and y + b[2] < y1 and z + b[6] > z0 and z + b[3] < z1 then
							return true
						end
					end
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

-- Would the body box (Java 0.6 wide) collide after moving by (dx, dz)?
local function bodyBlocked(x: number, feetY: number, z: number, dx: number, dz: number, height: number): boolean
	local cx, cz = x + dx, z + dz
	return solidIn(cx - HALF, feetY + 0.05, cz - HALF, cx + HALF, feetY + height - 0.05, cz + HALF)
end

-- In the air: the Java box's height with the Roblox body's depth (0.15 blocks each side). The
-- Humanoid's own collision lets it come closer to walls than Java's 0.3, so the full-width box
-- would already overlap and couldn't tell "moving into" from "touching".
local function airBlocked(x: number, feetY: number, z: number, dx: number, dz: number, height: number): boolean
	local cx, cz = x + dx, z + dz
	return solidIn(cx - 0.15, feetY + 0.05, cz - 0.15, cx + 0.15, feetY + height - 0.05, cz + 0.15)
end

local function roomToStand(x: number, feetY: number, z: number): boolean
	return not solidIn(x - HALF + 1e-3, feetY + 0.01, z - HALF + 1e-3, x + HALF - 1e-3, feetY + 1.8, z + HALF - 1e-3)
end

function MovementController.init()
	workspace.Gravity = Config.GRAVITY -- Java gravity (the server sets it too)
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
				elseif onGround(humanoid) or MovementController.spectating then
					sprintTriggerUntil = now + Config.SPRINT_DOUBLE_TAP
				end
			end
		elseif input.KeyCode == Enum.KeyCode.ButtonL3 then
			if canStartSprint(humanoid) then
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
	-- The body is anchored and moved directly; leaving puts it back into normal physics.
	local function setSpectating(on: boolean)
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			return
		end
		MovementController.spectating = on
		Players.LocalPlayer:SetAttribute("Spectating", on)
		sim.active = false
		sprintLatch = false
		if on then
			root.Anchored = true
		else
			root.AssemblyLinearVelocity = Vector3.zero
			root.Anchored = false
			peakFeetY = nil
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
	RunService:BindToRenderStep("RocraftSpectator", Enum.RenderPriority.Input.Value + 3, function(dt)
		if not MovementController.spectating then
			return
		end
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local cam = workspace.CurrentCamera
		if not humanoid or not root or not cam then
			return
		end
		root.Anchored = true
		local move = inputDir
		local up = 0
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
			up += 1
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
			up -= 1
		end
		-- sprint-flying like Java: double-tap W, ends when W is released
		local speed = Config.SPECTATOR_SPEED * BS * (if MovementController.sprinting then 2 else 1)
		local v = Vector3.new(move.X, 0, move.Z) * speed + Vector3.new(0, up * speed, 0)
		local look = cam.CFrame.LookVector
		local yaw = math.atan2(-look.X, -look.Z)
		root.CFrame = CFrame.new(root.Position + v * dt) * CFrame.Angles(0, yaw, 0)
		humanoid:Move(Vector3.zero, false)
	end)

	-- Sneaking at the edge of a drop: after the control script has set this frame's move
	-- direction, drop the parts of it that would take the feet box off its support.
	RunService:BindToRenderStep("RocraftSneakEdge", Enum.RenderPriority.Input.Value + 1, function(dt)
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if humanoid then
			inputDir = humanoid.MoveDirection -- just set by the control script from the player's input
		end
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

	-- Held-jump delay and Java air movement (after the control script and the sneak edge check).
	RunService:BindToRenderStep("RocraftJavaMove", Enum.RenderPriority.Input.Value + 2, function(dt)
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not humanoid or not root then
			return
		end
		-- Java: while jump is held, the next jump waits 10 ticks after the last one; letting go of
		-- jump clears the wait, so pressing it again jumps at once.
		local held = humanoid.Jump
		if not held then
			heldSinceJump = false -- any release clears the delay (Java noJumpDelay = 0)
		end
		local allow = not heldSinceJump or os.clock() - lastJumpAt >= PlayerPhysics.JUMP_DELAY_TICKS / 20
		if allow ~= jumpEnabled then
			jumpEnabled = allow
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, allow)
		end
		-- Java jumps again on the very tick you land while jump is held; a Roblox Humanoid waits
		-- in its Landed state first, and those extra ground frames bleed off sprint-jump speed.
		local state = humanoid:GetState()
		if held and allow and not root.Anchored and humanoid.Health > 0 and not MovementController.inLiquid
			and not MovementController.onLadder and humanoid.FloorMaterial ~= Enum.Material.Air
			and state ~= Enum.HumanoidStateType.Jumping and state ~= Enum.HumanoidStateType.Freefall
		then
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end
		-- Java keeps rising to the top of the jump even when the feet pass a ledge; a Humanoid
		-- would "land" on the ledge as soon as it is under it and end the jump early. No landing
		-- while still going up.
		local rising = root.AssemblyLinearVelocity.Y > 2 and not MovementController.onLadder
		if rising ~= noLandWhileRising then
			noLandWhileRising = rising
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Landed, not rising)
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, not rising)
		end

		if root.Anchored or humanoid.Health <= 0 or MovementController.inLiquid then
			sim.active = false
			return
		end
		local grounded = onGround(humanoid)
		if not sim.active then
			if grounded then
				return
			end
			-- walked off a ledge: continue with the air velocity
			local v = root.AssemblyLinearVelocity / BS / 20
			startSim(v.X * PlayerPhysics.AIR_FRICTION, v.Z * PlayerPhysics.AIR_FRICTION)
		end
		if grounded and MovementController.sneaking then
			sim.active = false -- the sneak edge check needs the Humanoid's own walking
			return
		end
		-- a blocked axis loses its velocity (Java collision). Tested against the blocks themselves:
		-- a slowdown from touching a ceiling is not a collision.
		local pb = root.Position / BS
		local feetB = (root.Position.Y - FEET_BELOW_ROOT) / BS
		local h = if MovementController.sneaking then 1.5 else 1.8
		if sim.sx ~= 0 and bodyBlocked(pb.X, feetB, pb.Z, math.sign(sim.sx) * 0.03, 0, h) then
			sim.sx = 0
		end
		if sim.sz ~= 0 and bodyBlocked(pb.X, feetB, pb.Z, 0, math.sign(sim.sz) * 0.03, h) then
			sim.sz = 0
		end

		local md = inputDir
		local scale = PlayerPhysics.INPUT_DAMPING
		if MovementController.sneaking then
			scale *= Config.SNEAK_SPEED_FACTOR
		end
		if MovementController.usingItem then
			scale *= Config.ITEM_USE_SPEED_FACTOR
		end
		local ix, iz = md.X * scale, md.Z * scale
		local sprinting = MovementController.sprinting
		sim.acc += dt
		local dx, dz = sim.sx, sim.sz
		local ticked = false
		while sim.acc >= 0.05 do
			sim.acc -= 0.05
			local g = grounded or sim.jumpTick
			if sim.jumpTick and sprinting then
				local look = root.CFrame.LookVector
				local bx, bz = PlayerPhysics.jumpBoost(look.X, look.Z)
				sim.sx += bx
				sim.sz += bz
			end
			sim.jumpTick = false
			dx, dz, sim.sx, sim.sz = PlayerPhysics.tick(sim.sx, sim.sz, ix, iz, g, sprinting)
			ticked = true
		end
		if ticked then
			-- Java's body is a 0.6 x 1.8 box down to the feet; a Roblox character's legs don't
			-- collide, so in the air it could slide over things only the legs would hit (a 1.5
			-- block fence, a slab on a block). Stop any horizontal step the full body can't take.
			local stuck = airBlocked(pb.X, feetB, pb.Z, 0, 0, h) -- already inside something: never freeze
			if not stuck and dx ~= 0 and airBlocked(pb.X, feetB, pb.Z, dx + math.sign(dx) * 0.02, 0, h) then
				dx, sim.sx = 0, 0
			end
			if not stuck and dz ~= 0 and airBlocked(pb.X, feetB, pb.Z, dx, dz + math.sign(dz) * 0.02, h) then
				dz, sim.sz = 0, 0
			end
			if not grounded then
				local rv = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(if dx == 0 then 0 else rv.X, rv.Y, if dz == 0 then 0 else rv.Z)
			end
			local v = Vector3.new(dx, 0, dz) * 20 * BS
			sim.lastCmd = v
			if v.Magnitude > 0.05 then
				humanoid.WalkSpeed = v.Magnitude
				humanoid:Move(v.Unit, false)
			else
				humanoid:Move(Vector3.zero, false)
			end
			-- landed and back to normal ground speed: hand control back to the Humanoid
			if grounded then
				local gx, gz = PlayerPhysics.steadyGround(ix, iz, sprinting)
				if math.abs(dx - gx) < 0.004 and math.abs(dz - gz) < 0.004 then
					sim.active = false
				end
			end
		else
			local v = sim.lastCmd
			if v.Magnitude > 0.05 then
				humanoid.WalkSpeed = v.Magnitude
				humanoid:Move(v.Unit, false)
			end
		end
	end)

	Players.LocalPlayer.CharacterAdded:Connect(function(character)
		configure(character:WaitForChild("Humanoid") :: Humanoid)
	end)

	-- Knockback from hits/explosions (the client simulates its own character's physics).
	-- Hits use Java's formula on our own velocity and ground state (Combat.knockback); the
	-- horizontal part then runs through the Java movement simulation (friction, air drag).
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
		-- Java: knockback changes the stored velocity; the movement simulation carries it on
		startSim(nv.X, nv.Z)
		sim.lastCmd = Vector3.zero
		root.AssemblyLinearVelocity = nv * 20 * BS
		raiseLimit((root.Position.Y - FEET_BELOW_ROOT) / BS, nv.Y * 20 * BS)
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
			and not root.Anchored and humanoid.Health > 0 and not MovementController.spectating
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
		-- Forward input comes from the player's keys/stick, not from the Humanoid's move direction,
		-- which the Java movement simulation sets while airborne or landing.
		local look = root.CFrame.LookVector
		local forward = inputDir:Dot(look) > 0.5
		if not forward or not canStartSprint(humanoid) then
			sprintLatch = false
		end
		-- Java: sprint stops on a real horizontal collision in the facing direction (more than a
		-- glancing touch): the body box is blocked just ahead AND we actually stopped moving
		-- forward. Jumps, landings and ceiling bumps don't count.
		local v = root.AssemblyLinearVelocity
		local headOn = false
		if sprintLatch and not MovementController.spectating then
			local lb = Vector3.new(look.X, 0, look.Z)
			lb = if lb.Magnitude > 1e-3 then lb.Unit else Vector3.zero
			local pb = root.Position / BS
			local feetB = (root.Position.Y - FEET_BELOW_ROOT) / BS
			headOn = bodyBlocked(pb.X, feetB, pb.Z, lb.X * 0.05, lb.Z * 0.05, 1.8)
				and Vector3.new(v.X, 0, v.Z):Dot(lb) < Config.WALK_SPEED * 0.4
		end
		if headOn then
			blockedTime += dt
			if blockedTime > 0.1 then
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
			-- Java: flowing water pushes you along its current (0.014 blocks/tick per tick with
			-- water drag 0.8 -> about 1.4 blocks/s when you don't swim against it)
			local fx, fz = Fluids.flow(ClientWorld.getBlock, bx, math.floor((p.Y - 2.5) / BS), bz)
			if fx ~= 0 or fz ~= 0 then
				local cv = root.AssemblyLinearVelocity
				local push = 0.07 * 20 * BS
				root.AssemblyLinearVelocity = cv + Vector3.new(fx, 0, fz) * push * math.min(1, dt * 10)
			end
			speed *= SWIM_SPEED_FACTOR
			local v = root.AssemblyLinearVelocity
			local up = humanoid.Jump or UserInputService:IsKeyDown(Enum.KeyCode.Space)
			local vy = if up then SWIM_UP_SPEED else math.max(v.Y, -SINK_SPEED)
			root.AssemblyLinearVelocity = Vector3.new(v.X, vy, v.Z)
		end
		humanoid.WalkSpeed = speed

		-- Ladders (Java LivingEntity.handleOnClimbable): falling is capped at 0.15 blocks/tick;
		-- pushing into the ladder or holding jump climbs (0.2/tick, about 2.35 blocks/s after
		-- gravity and drag); sneaking holds you in place.
		local onLadder = Shapes.climbable(bodyId, ClientWorld.getBlock(bx, math.floor(p.Y / BS) - 1, bz))
			or Shapes.climbable(feetId, ClientWorld.getBlock(bx, math.floor((p.Y - 2.5) / BS) - 1, bz))
		MovementController.onLadder = onLadder
		if onLadder and not root.Anchored and not inLiquid and humanoid.Health > 0 and not MovementController.spectating then
			local v = root.AssemblyLinearVelocity
			local pbl = root.Position / BS
			local feetL = (root.Position.Y - FEET_BELOW_ROOT) / BS
			-- Java climbs on any horizontal collision; walking toward the ladder's wall counts too
			local towardWall = false
			for _, id in { bodyId, feetId } do
				local d = id and BlockRegistry.byId[id]
				if d and d.shape == "ladder" then
					local f = Shapes.DIR[d.state.facing :: string]
					towardWall = towardWall or (inputDir.X * -f[1] + inputDir.Z * -f[2]) > 0.3
				end
			end
			local pushing = inputDir.Magnitude > 0.1 and (towardWall
				or bodyBlocked(pbl.X, feetL, pbl.Z, inputDir.X * 0.08, inputDir.Z * 0.08, 1.7))
			local up = humanoid.Jump or UserInputService:IsKeyDown(Enum.KeyCode.Space)
			local maxH = 0.15 * 20 * BS
			local hx, hz = math.clamp(v.X, -maxH, maxH), math.clamp(v.Z, -maxH, maxH)
			if crouch and not (pushing or up) then
				-- Java: sneaking stops the slide; hold the height exactly (gravity would creep)
				ladderHoldY = ladderHoldY or root.Position.Y
				local hy = ladderHoldY :: number
				root.CFrame = CFrame.new(root.Position.X, hy, root.Position.Z) * root.CFrame.Rotation
				root.AssemblyLinearVelocity = Vector3.new(hx, 0, hz)
			else
				ladderHoldY = nil
				local vy
				if pushing or up then
					vy = 0.1176 * 20 * BS
					-- off the floor: a grounded Humanoid pins itself down and would fight the climb
					local st = humanoid:GetState()
					if st == Enum.HumanoidStateType.Running or st == Enum.HumanoidStateType.Landed
						or st == Enum.HumanoidStateType.RunningNoPhysics
					then
						humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
					end
				else
					vy = math.max(v.Y, -0.15 * 20 * BS)
				end
				root.AssemblyLinearVelocity = Vector3.new(hx, vy, hz)
			end
			peakFeetY = nil -- Java: climbing resets the fall distance
		else
			ladderHoldY = nil
		end

		-- Step up (Java step height 0.6): walking into a slab, a stair step or anything up to 0.6
		-- blocks high lifts you onto it. Only real ledges count (more than 0.1 block above the
		-- feet), so standing on flat ground never triggers it; the camera glides up instead of
		-- jumping (MovementController.stepOffset).
		if not root.Anchored and humanoid.Health > 0 and not inLiquid and humanoid.FloorMaterial ~= Enum.Material.Air
			and not MovementController.spectating and not MovementController.onLadder
		then
			local dirv = Vector3.new(inputDir.X, 0, inputDir.Z)
			if dirv.Magnitude > 0.1 then
				dirv = dirv.Unit
				local px0, pz0 = root.Position.X / BS + dirv.X * 0.1, root.Position.Z / BS + dirv.Z * 0.1
				local feet0 = (root.Position.Y - FEET_BELOW_ROOT) / BS
				local function clearAt(h: number): boolean
					return not solidIn(px0 - HALF, feet0 + h, pz0 - HALF, px0 + HALF, feet0 + h + 1.75, pz0 + HALF)
				end
				if not clearAt(0.1) then
					for i = 2, 10 do
						local h = i * 0.0625
						if clearAt(h) then
							if roomToStand(root.Position.X / BS, feet0 + h, root.Position.Z / BS) then
								local lift = h * BS + 0.05
								root.CFrame += Vector3.new(0, lift, 0)
								local v = root.AssemblyLinearVelocity
								root.AssemblyLinearVelocity = Vector3.new(v.X, math.max(v.Y, 0), v.Z)
								MovementController.stepOffset -= lift
								guard.top = math.max(guard.top or 0, feet0 + h + 0.1)
							end
							break
						end
					end
				end
			end
		end
		-- camera glide after a step: back to 0 in about 0.15 s
		MovementController.stepOffset *= 0.5 ^ (dt * 30)
		if math.abs(MovementController.stepOffset) < 0.01 then
			MovementController.stepOffset = 0
		end

		-- Sneak edge guard (after physics, whatever moved us: walking, the movement simulation,
		-- knockback): while sneaking on the ground you can't leave the support of the block you
		-- stand on if the drop is more than 0.6 blocks. Jumping off stays possible.
		local here = root.Position
		local feetNow = (here.Y - FEET_BELOW_ROOT) / BS
		local onSupport = supported(here.X / BS, feetNow, here.Z / BS)
		local vyNow = root.AssemblyLinearVelocity.Y
		local groundedNow = humanoid.FloorMaterial ~= Enum.Material.Air
		if airborneByJump and groundedNow and vyNow <= 1 and os.clock() - lastJumpAt > 0.1 then
			airborneByJump = false
		end
		if crouch and not root.Anchored and not inLiquid and humanoid.Health > 0 and not airborneByJump then
			if onSupport and vyNow <= 1 then
				if groundedNow then
					lastSupported = here
				end
				local base = lastSupported
				if base then
					-- ledge top exactly at foot level, under the body centre
					setLedge(Vector3.new(here.X, base.Y - FEET_BELOW_ROOT - 0.1, here.Z))
				end
			elseif not onSupport and lastSupported
				and (Vector3.new(here.X, 0, here.Z) - Vector3.new((lastSupported :: Vector3).X, 0, (lastSupported :: Vector3).Z)).Magnitude < BS
			then
				local back = lastSupported :: Vector3
				root.CFrame = CFrame.new(back) * (root.CFrame - root.CFrame.Position)
				root.AssemblyLinearVelocity = Vector3.zero
				sim.active = false
			end
		else
			setLedge(nil)
			lastSupported = if crouch and onSupport and groundedNow then here else nil
		end

		-- Height guard (see `guard`)
		do
			local feetG = (root.Position.Y - FEET_BELOW_ROOT) / BS
			local posB = root.Position / BS
			local lp = guard.lastPos
			local teleported = lp ~= nil and ((Vector3.new(posB.X, 0, posB.Z) - Vector3.new(lp.X, 0, lp.Z)).Magnitude > 2
				or math.abs(posB.Y - lp.Y) > 3)
			local exempt = root.Anchored or humanoid.Health <= 0 or inLiquid or MovementController.onLadder
				or MovementController.spectating
			local groundedG = humanoid.FloorMaterial ~= Enum.Material.Air
			if exempt or teleported or guard.top == nil then
				-- swimming up or climbing out keeps its momentum (jumping out of water onto a ledge)
				guard.top = feetG + 0.65
				raiseLimit(feetG, root.AssemblyLinearVelocity.Y)
				guard.lastLegal = root.CFrame
			elseif feetG > (guard.top :: number) + 0.02 then
				local vel = root.AssemblyLinearVelocity
				if groundedG and guard.lastLegal then
					-- standing somewhere it couldn't have got to: back to the last legal spot
					root.CFrame = guard.lastLegal :: CFrame
					root.AssemblyLinearVelocity = Vector3.new(0, math.min(vel.Y, 0), 0)
					sim.active = false
				else
					-- rising past the jump's peak (sliding up an edge): hold it at the peak
					root.CFrame -= Vector3.new(0, (feetG - (guard.top :: number)) * BS, 0)
					root.AssemblyLinearVelocity = Vector3.new(vel.X, math.min(vel.Y, 0), vel.Z)
				end
			else
				guard.lastLegal = root.CFrame
				-- standing for real (a block right under the feet, not a wall the body brushes in
				-- mid-air): a step up to 0.6 is the most it can rise from here
				local pbG = root.Position / BS
				local standing = solidIn(pbG.X - 0.15, feetG - 0.15, pbG.Z - 0.15, pbG.X + 0.15, feetG + 0.02, pbG.Z + 0.15)
				if groundedG and standing and root.AssemblyLinearVelocity.Y <= 1 then
					guard.top = feetG + 0.65
				end
			end
			guard.lastPos = root.Position / BS
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
		-- Java AbstractClientPlayer.getFieldOfViewModifier: fov x (speed / walking speed + 1) / 2;
		-- sprinting is +30 % speed, so x1.15 (70 -> 80.5). GameRenderer.tickFov eases half the
		-- remaining gap per tick.
		local targetFov = if MovementController.sprinting then BASE_FOV * 1.15 else BASE_FOV
		camera.FieldOfView += (targetFov - camera.FieldOfView) * (1 - 0.5 ^ (dt * 20))
	end)
end

return MovementController
