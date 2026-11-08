--!strict
-- Block targeting, hold-to-mine and placing.
--
-- Targeting: voxel raycast from the eye along the look direction (reach 4.5 blocks) against the
-- client's block data. The targeted block gets a thin dark outline.
-- Mining: hold left mouse (R2 / on-screen "Mine" button). Progress uses the classic formula
-- (Mining.breakSeconds), slowed 5x while airborne or under water. The client predicts the break;
-- the server validates and corrects (BlockChanged).
-- Placing: right mouse (L2 / "Place" button) puts the held block against the targeted face,
-- repeating every Config.PLACE_REPEAT seconds while held.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local Mining = require(Shared.Gameplay.Mining)
local VoxelRaycast = require(Shared.World.VoxelRaycast)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local CameraController = require(script.Parent.Parent.Player.CameraController)
local InventoryClient = require(script.Parent.Parent.Player.InventoryClient)
local SurvivalClient = require(script.Parent.Parent.Survival.SurvivalClient)
local SurvivalHUD = require(script.Parent.Parent.Survival.SurvivalHUD)
local SurvivalRules = require(Shared.Gameplay.SurvivalRules)
local Combat = require(Shared.Gameplay.Combat)
local MobClient = require(script.Parent.Parent.Mobs.MobClient)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local TorchRules = require(Shared.Blocks.TorchRules)

local EAT_SECONDS = 1.6

local BS = Config.BLOCK_SIZE
local AIR = 0
-- Right-clicking these opens their window instead of placing (hold Shift to place against them).
local INTERACTABLE = {
	[BlockRegistry.id("crafting_table")] = true,
	[BlockRegistry.id("furnace")] = true,
	[BlockRegistry.id("chest")] = true,
}
local isLiquid = BlockRegistry.isLiquid

local BlockInteraction = {}
-- Events for sounds, particles and the first-person hand:
--   placed(x, y, z, id)  broken(x, y, z, id)  digging(x, y, z, id) every 4 ticks while mining
--   swing()  each attack / placement and continuously while mining
BlockInteraction.placed = Instance.new("BindableEvent")
BlockInteraction.broken = Instance.new("BindableEvent")
BlockInteraction.digging = Instance.new("BindableEvent")
BlockInteraction.swing = Instance.new("BindableEvent")
BlockInteraction.target = nil :: VoxelRaycast.Hit?
BlockInteraction.mobTarget = nil :: number? -- mob under the crosshair within melee reach

type MiningState = { x: number, y: number, z: number, item: string?, progress: number, started: boolean }

local breakHeld = false
local placeHeld = false
local useHeld = false -- right button held with food: eating
local eating: { progress: number, slot: number }? = nil
local mining: MiningState? = nil
local cooldownUntil = 0
local nextPlaceAt = 0

local highlightPart: Part
local selection: SelectionBox
local crackPart: Part
local crackLabels: { ImageLabel } = {}
local lastDigSound = 0
local TextureAtlas = require(script.Parent.Parent.Render.TextureAtlas)

-- Show crack stage 0..9 on the mining overlay (nil hides it).
local function setCrack(stage: number?)
	if not stage or not TextureAtlas.content then
		crackPart.Transparency = 1
		for _, l in crackLabels do
			l.Visible = false
		end
		return
	end
	local offset, size = TextureAtlas.crackRect(stage)
	for _, l in crackLabels do
		l.Visible = true
		l.ImageRectOffset = offset
		l.ImageRectSize = size
	end
end
local function stopsRay(id: number): boolean
	return id ~= AIR and not isLiquid[id + 1]
end

local function blockAt(x: number, y: number, z: number): number?
	return ClientWorld.getBlock(x, y, z)
end

-- Attack a mob. The client knows its own physics, so it decides whether this is a critical hit
-- (Java: charge > 0.9, falling, airborne, not sprinting, not in liquid); the server re-checks.
local lastSwing = 0
local lastHeld: string? = nil
local function attackMob(id: number)
	local item = InventoryClient.heldItem()
	local _, attackSpeed = Combat.attackStats(item)
	local now = os.clock()
	local charge = Combat.charge(now - lastSwing, attackSpeed)
	lastSwing = now
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local crit = false
	if humanoid and root then
		crit = Combat.isCrit({
			charge = charge,
			falling = root.AssemblyLinearVelocity.Y < 0,
			onGround = humanoid.FloorMaterial ~= Enum.Material.Air,
			sprinting = MovementController.sprinting,
			inLiquid = MovementController.inLiquid,
		})
	end
	if MovementController.sprinting and charge > Combat.CRIT_MIN_CHARGE then
		MovementController.stopSprint() -- Java: a sprint hit ends the sprint
	end
	Remotes.get("AttackMob"):FireServer(id, crit)
	BlockInteraction.swing:Fire()
end

-- Java: switching to a different item restarts the attack cooldown.
RunService.Heartbeat:Connect(function()
	local held = InventoryClient.heldItem()
	if held ~= lastHeld then
		lastHeld = held
		lastSwing = os.clock()
	end
end)

local function send(action: string, x: number, y: number, z: number, nx: number?, ny: number?, nz: number?)
	Remotes.get("BlockAction"):FireServer(action, x, y, z, nx, ny, nz)
end

local function makeVisuals()
	highlightPart = Instance.new("Part")
	highlightPart.Name = "TargetHighlight"
	highlightPart.Anchored = true
	highlightPart.CanCollide = false
	highlightPart.CanQuery = false
	highlightPart.CanTouch = false
	highlightPart.Transparency = 1
	highlightPart.Size = Vector3.one * (BS + 0.02)
	selection = Instance.new("SelectionBox")
	selection.Adornee = highlightPart
	selection.Color3 = Color3.fromRGB(20, 20, 24)
	selection.LineThickness = 0.025
	selection.SurfaceTransparency = 1
	selection.Visible = false
	selection.Parent = highlightPart
	highlightPart.Parent = workspace

	-- Mining progress: a dark shell that gets more opaque in 10 steps.
	crackPart = Instance.new("Part")
	crackPart.Name = "MiningProgress"
	crackPart.Anchored = true
	crackPart.CanCollide = false
	crackPart.CanQuery = false
	crackPart.CanTouch = false
	crackPart.CastShadow = false
	crackPart.Material = Enum.Material.SmoothPlastic
	crackPart.Color = Color3.fromRGB(12, 10, 10)
	crackPart.Size = Vector3.one * (BS + 0.04)
	crackPart.Transparency = 1
	-- crack stages from the block atlas on all six sides
	for _, face in Enum.NormalId:GetEnumItems() do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.CanvasSize = Vector2.new(64, 64)
		gui.LightInfluence = 1
		gui.Adornee = crackPart
		local label = Instance.new("ImageLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.ResampleMode = Enum.ResamplerMode.Pixelated
		label.Visible = false
		pcall(function()
			if TextureAtlas.content then
				(label :: any).ImageContent = TextureAtlas.content
			end
		end)
		label.Parent = gui
		gui.Parent = crackPart
		table.insert(crackLabels, label)
	end
	crackPart.Parent = workspace
end

local function blockCFrame(x: number, y: number, z: number): CFrame
	return CFrame.new((x + 0.5) * BS, (y + 0.5) * BS, (z + 0.5) * BS)
end

local function cancelMining()
	if mining and mining.started then
		send("cancel", mining.x, mining.y, mining.z)
	end
	mining = nil
	setCrack(nil)
end

-- Rough local check so we don't request placements inside our own body.
local function overlapsSelf(x: number, y: number, z: number): boolean
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return false
	end
	local p = root.Position
	local minP = Vector3.new(x, y, z) * BS
	local maxP = minP + Vector3.one * BS
	return p.X - 0.9 < maxP.X and p.X + 0.9 > minP.X
		and p.Y - 2.95 < maxP.Y and p.Y + 2.0 > minP.Y
		and p.Z - 0.9 < maxP.Z and p.Z + 0.9 > minP.Z
end

local function modifiers(): Mining.Modifiers
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local eye = CameraController.getEyeAndLook()
	local inWater = false
	if eye then
		local id = ClientWorld.getBlock(math.floor(eye.X / BS), math.floor(eye.Y / BS), math.floor(eye.Z / BS))
		inWater = id ~= nil and isLiquid[id + 1]
	end
	return {
		airborne = humanoid ~= nil and humanoid.FloorMaterial == Enum.Material.Air,
		inWater = inWater,
	}
end

local function stopEating()
	if eating then
		SurvivalClient.eatCancel()
		eating = nil
	end
	SurvivalHUD.setEatProgress(nil)
end

-- Hold right mouse with food: eat over 1.6 s (only when not full), repeat while held.
local function updateEating(dt: number)
	local item = ItemRegistry.get(InventoryClient.heldItem())
	local canEat = useHeld and item ~= nil and item.food ~= nil
		and SurvivalClient.food < SurvivalRules.MAX_FOOD and not SurvivalClient.dead
	if not canEat or (eating and eating.slot ~= InventoryClient.selected) then
		stopEating()
		return
	end
	if not eating then
		eating = { progress = 0, slot = InventoryClient.selected }
		SurvivalClient.eatStart()
	end
	local e = eating :: { progress: number, slot: number }
	e.progress += dt / EAT_SECONDS
	SurvivalHUD.setEatProgress(e.progress)
	if e.progress >= 1 then
		SurvivalClient.eatFinish()
		eating = nil -- next bite starts next frame if still held
	end
end

local function update(dt: number)
	local now = os.clock()
	if Players.LocalPlayer:GetAttribute("Spectating") then
		-- spectators can't break, place, eat or attack
		breakHeld, placeHeld, useHeld = false, false, false
		if mining then
			cancelMining()
		end
		BlockInteraction.target = nil
		BlockInteraction.mobTarget = nil
		selection.Visible = false
		return
	end
	if InventoryClient.uiOpen or SurvivalClient.dead then
		useHeld = false
		stopEating()
	end
	updateEating(dt)
	MovementController.usingItem = eating ~= nil -- Java: slows you to 20 % and stops sprinting
	if InventoryClient.uiOpen or SurvivalClient.dead then
		-- a window is open: no mining/placing, no highlight
		breakHeld, placeHeld = false, false
		if mining then
			cancelMining()
		end
		selection.Visible = false
		return
	end
	local eye, look = CameraController.getEyeAndLook()
	local hit: VoxelRaycast.Hit? = nil
	if eye then
		local o = eye / BS
		hit = VoxelRaycast.cast(blockAt, o.X, o.Y, o.Z, look.X, look.Y, look.Z, Config.REACH, stopsRay)
	end
	BlockInteraction.target = hit

	-- A mob in front of the block (and within 3 blocks melee reach) takes the click instead.
	BlockInteraction.mobTarget = nil
	if eye then
		local mobId, mobDist = MobClient.raycast(eye, look, Combat.MELEE_REACH * BS)
		if mobId and (not hit or mobDist < hit.distance * BS) then
			BlockInteraction.mobTarget = mobId
			hit = nil -- no block highlight / mining through the mob
			BlockInteraction.target = nil
		end
	end

	-- Highlight
	if hit then
		highlightPart.CFrame = blockCFrame(hit.x, hit.y, hit.z)
		selection.Visible = true
	else
		selection.Visible = false
	end

	-- Mining
	if breakHeld and hit and now >= cooldownUntil then
		local item = InventoryClient.heldItem()
		local m = mining
		if not m or m.x ~= hit.x or m.y ~= hit.y or m.z ~= hit.z or m.item ~= item then
			cancelMining()
			if Mining.breakSeconds(hit.id, item) < math.huge then
				local started = Mining.breakSeconds(hit.id, item) > 0
				if started then
					send("start", hit.x, hit.y, hit.z)
				end
				mining = { x = hit.x, y = hit.y, z = hit.z, item = item, progress = 0, started = started }
			end
		end
		local cur = mining
		if cur then
			local total = Mining.breakSeconds(hit.id, item, modifiers())
			cur.progress = if total <= 0 then 1 else cur.progress + dt / total
			if cur.progress >= 1 then
				send("finish", cur.x, cur.y, cur.z)
				local brokenId = hit.id
				ClientWorld.setBlock(cur.x, cur.y, cur.z, AIR, true) -- instant prediction; server corrects if wrong
				cooldownUntil = now + (if total <= 0 then 0.05 else Config.BREAK_COOLDOWN)
				mining = nil
				setCrack(nil)
				BlockInteraction.broken:Fire(cur.x, cur.y, cur.z, brokenId)
			else
				local stage = math.floor(cur.progress * 10) -- 0..9
				crackPart.CFrame = blockCFrame(cur.x, cur.y, cur.z)
				setCrack(stage)
				if now - lastDigSound >= 0.2 then
					lastDigSound = now
					BlockInteraction.digging:Fire(cur.x, cur.y, cur.z, hit.id)
				end
				BlockInteraction.swing:Fire()
			end
		end
	elseif mining and (not breakHeld or not hit) then
		cancelMining()
	end

	-- Placing
	if placeHeld and hit and now >= nextPlaceAt and (hit.nx ~= 0 or hit.ny ~= 0 or hit.nz ~= 0) then
		local item = ItemRegistry.get(InventoryClient.heldItem())
		if item and item.block then
			local x, y, z = hit.x + hit.nx, hit.y + hit.ny, hit.z + hit.nz
			local current = ClientWorld.getBlock(x, y, z)
			local solid = BlockRegistry.isSolid[item.block + 1]
			if current ~= nil and (current == AIR or isLiquid[current + 1]) and not (solid and overlapsSelf(x, y, z)) then
				local placeId = TorchRules.placement(item.block, x, y, z, hit.nx, hit.ny, hit.nz, ClientWorld.getBlock)
				if placeId then
					send("place", x, y, z, hit.nx, hit.ny, hit.nz)
					ClientWorld.setBlock(x, y, z, placeId, true) -- instant prediction
					BlockInteraction.placed:Fire(x, y, z, placeId)
					BlockInteraction.swing:Fire()
				end
				nextPlaceAt = now + Config.PLACE_REPEAT
			end
		end
	end
end

local function makeTouchButtons()
	local gui = Instance.new("ScreenGui")
	gui.Name = "TouchActions"
	gui.ResetOnSpawn = false
	local function button(text: string, pos: UDim2, onDown: () -> (), onUp: () -> ())
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(84, 84)
		b.Position = pos
		b.AnchorPoint = Vector2.new(1, 1)
		b.BackgroundColor3 = Color3.fromRGB(20, 22, 28)
		b.BackgroundTransparency = 0.35
		b.TextColor3 = Color3.fromRGB(235, 235, 240)
		b.Font = Enum.Font.GothamBold
		b.TextSize = 18
		b.Text = text
		b.AutoButtonColor = true
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 10)
		corner.Parent = b
		b.MouseButton1Down:Connect(onDown)
		b.MouseButton1Up:Connect(onUp)
		b.MouseLeave:Connect(onUp)
		b.Parent = gui
	end
	button("Mine", UDim2.new(1, -24, 1, -200), function()
		if BlockInteraction.mobTarget then
			attackMob(BlockInteraction.mobTarget :: number)
			return
		end
		breakHeld = true
	end, function()
		breakHeld = false
	end)
	button("Place", UDim2.new(1, -120, 1, -130), function()
		local hit = BlockInteraction.target
		if hit and INTERACTABLE[hit.id] and not MovementController.sneaking then
			InventoryClient.openBlock(hit.x, hit.y, hit.z)
			return
		end
		local held = ItemRegistry.get(InventoryClient.heldItem())
		if held and held.food then
			useHeld = true
			return
		end
		placeHeld = true
		nextPlaceAt = 0
	end, function()
		placeHeld = false
		useHeld = false
	end)
	button("Sneak", UDim2.new(1, -216, 1, -130), function()
		MovementController.toggleSneak()
	end, function() end)
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

function BlockInteraction.init()
	makeVisuals()

	local keyDrop = (Enum.KeyCode :: any)[Config.KEY_DROP]
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or InventoryClient.uiOpen then
			return
		end
		local t = input.UserInputType
		if (t == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2) and BlockInteraction.mobTarget then
			-- attack: one hit per click (damage scales with how long since the last swing)
			attackMob(BlockInteraction.mobTarget :: number)
		elseif t == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2 then
			breakHeld = true
		elseif t == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.ButtonL2 then
			local hit = BlockInteraction.target
			local shift = MovementController.sneaking or UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
				or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			local held = ItemRegistry.get(InventoryClient.heldItem())
			if hit and INTERACTABLE[hit.id] and not shift then
				InventoryClient.openBlock(hit.x, hit.y, hit.z) -- server opens the window; the UI follows
			elseif held and held.food then
				useHeld = true -- eat
			else
				placeHeld = true
				nextPlaceAt = 0 -- first placement is immediate
			end
		elseif input.KeyCode == keyDrop or input.KeyCode == Enum.KeyCode.ButtonB then
			local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
			InventoryClient.drop(ctrl)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2 then
			breakHeld = false
		elseif t == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.ButtonL2 then
			placeHeld = false
			useHeld = false
		end
	end)
	if UserInputService.TouchEnabled then
		makeTouchButtons()
	end

	RunService:BindToRenderStep("RocraftBlockInteraction", Enum.RenderPriority.Camera.Value + 2, update)
end

return BlockInteraction
