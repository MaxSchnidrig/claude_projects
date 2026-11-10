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
local Crafting = require(Shared.Items.Crafting)
local ClientWorld = require(script.Parent.Parent.World.ClientWorld)
local CameraController = require(script.Parent.Parent.Player.CameraController)
local InventoryClient = require(script.Parent.Parent.Player.InventoryClient)
local SurvivalClient = require(script.Parent.Parent.Survival.SurvivalClient)
local SurvivalHUD = require(script.Parent.Parent.Survival.SurvivalHUD)
local SurvivalRules = require(Shared.Gameplay.SurvivalRules)
local Combat = require(Shared.Gameplay.Combat)
local MobClient = require(script.Parent.Parent.Mobs.MobClient)
local MovementController = require(script.Parent.Parent.Player.MovementController)
local Shapes = require(Shared.Blocks.Shapes)
local Placement = require(Shared.Blocks.Placement)
local DecorClient = require(script.Parent.Parent.World.DecorClient)

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
local Fluids = require(Shared.World.Fluids)
local CAMPFIRE = BlockRegistry.id("campfire")
local CAMPFIRE_UNLIT = BlockRegistry.id("campfire_unlit")



local BlockInteraction = {}
-- Events for sounds, particles and the first-person hand:
--   placed(x, y, z, id)  broken(x, y, z, id)  digging(x, y, z, id) every 4 ticks while mining
--   swing()  each attack / placement and continuously while mining
BlockInteraction.placed = Instance.new("BindableEvent")
BlockInteraction.broken = Instance.new("BindableEvent")
BlockInteraction.digging = Instance.new("BindableEvent")
BlockInteraction.swing = Instance.new("BindableEvent")
BlockInteraction.used = Instance.new("BindableEvent") -- (held item key, target block id) on a right-click use
BlockInteraction.target = nil :: VoxelRaycast.Hit?
BlockInteraction.mobTarget = nil :: number? -- mob under the crosshair within melee reach
BlockInteraction.frameTarget = nil :: string? -- item frame under the crosshair

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
local rayShape = Shapes.rayShapeFn(blockAt)

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
			falling = MovementController.velocity.Y < 0,
			onGround = MovementController.onGround,
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

-- Items used with right-click on a block (server: Simulation/ItemUseService).
local USE_ITEMS = { bucket = true, water_bucket = true, lava_bucket = true, flint_and_steel = true }

-- Right-click "use": buckets, flint and steel, shovel / raw food on campfires. Returns true if the
-- click was used up here (no placing / eating).
local function send(action: string, x: number, y: number, z: number, nx: number?, ny: number?, nz: number?, extra: { number }?)
	Remotes.get("BlockAction"):FireServer(action, x, y, z, nx, ny, nz, extra)
end

-- Right-click on something that reacts: item frames, wooden doors, signs; placing an item frame.
-- Returns true if the click was used. Sneaking skips doors and signs (place against them).
local function tryInteract(shift: boolean): boolean
	local fk = BlockInteraction.frameTarget
	if fk then
		DecorClient.useFrame(fk)
		BlockInteraction.swing:Fire()
		return true
	end
	local hit = BlockInteraction.target
	if not hit then
		return false
	end
	local def = BlockRegistry.byId[hit.id]
	if not shift and def and def.shape == "door" and def.family ~= "iron_door" then
		local ly = if def.state.upper then hit.y - 1 else hit.y
		local lower = ClientWorld.getBlock(hit.x, ly, hit.z)
		local toggled = lower and Placement.toggledDoor(lower)
		if toggled then
			ClientWorld.setBlock(hit.x, ly, hit.z, toggled, true) -- prediction; the server confirms
			if ClientWorld.getBlock(hit.x, ly + 1, hit.z) then
				ClientWorld.setBlock(hit.x, ly + 1, hit.z, ClientWorld.getBlock(hit.x, ly + 1, hit.z) :: number, true) -- redraw the top half
			end
			local opened = BlockRegistry.byId[toggled].state.open
			BlockInteraction.used:Fire(if opened then "door_open" else "door_close", hit.id)
		end
		send("interact", hit.x, hit.y, hit.z)
		BlockInteraction.swing:Fire()
		return true
	end
	if not shift and def and (def.shape == "trapdoor" or def.shape == "fence_gate") then
		local _, look = CameraController.getEyeAndLook()
		local nextId = Placement.toggle(hit.id, look.X, look.Z)
		if nextId then
			ClientWorld.setBlock(hit.x, hit.y, hit.z, nextId, true) -- prediction; the server confirms
			local opened = BlockRegistry.byId[nextId].state.open
			BlockInteraction.used:Fire(if opened then "door_open" else "door_close", hit.id)
			send("interact", hit.x, hit.y, hit.z)
			BlockInteraction.swing:Fire()
			return true
		end
		-- iron trapdoors don't open by hand: fall through (place against it)
	end
	if not shift and def and (def.shape == "sign" or def.shape == "wall_sign" or def.shape == "hanging_sign"
		or def.shape == "wall_hanging_sign")
	then
		local eye = CameraController.getEyeAndLook()
		if eye then
			DecorClient.editSign(hit.x, hit.y, hit.z, hit.id, eye)
		end
		return true
	end
	if not shift and def and def.shape == "bed" then
		Remotes.get("Bed"):FireServer({ type = "use", x = hit.x, y = hit.y, z = hit.z })
		BlockInteraction.swing:Fire()
		return true
	end
	local heldKey = InventoryClient.heldItem()
	if heldKey == "item_frame" or heldKey == "glow_item_frame" then
		if hit.nx ~= 0 or hit.ny ~= 0 or hit.nz ~= 0 then
			DecorClient.placeFrame(hit.x, hit.y, hit.z, hit.nx, hit.ny, hit.nz)
			BlockInteraction.swing:Fire()
		end
		return true
	end
	return false
end

local function tryUse(): boolean
	local held = InventoryClient.heldItem()
	local def = ItemRegistry.get(held)
	local hit = BlockInteraction.target
	if held == "bucket" then
		-- an empty bucket looks for the first water or lava SOURCE along the view
		local eye, look = CameraController.getEyeAndLook()
		if not eye then
			return true
		end
		local o = eye / BS
		local fh = VoxelRaycast.cast(blockAt, o.X, o.Y, o.Z, look.X, look.Y, look.Z, Config.REACH, function(id)
			return id ~= AIR and (not isLiquid[id + 1] or Fluids.isSource(id))
		end)
		if fh and Fluids.isSource(fh.id) then
			Remotes.get("UseItem"):FireServer({ x = fh.x, y = fh.y, z = fh.z, nx = fh.nx, ny = fh.ny, nz = fh.nz })
			BlockInteraction.used:Fire("bucket_fill", fh.id)
			BlockInteraction.swing:Fire()
		end
		return true
	end
	if not hit then
		return held ~= nil and USE_ITEMS[held] == true
	end
	local cookable = def and def.food and Crafting.smeltResult(held) ~= nil
	local onCampfire = hit.id == CAMPFIRE or hit.id == CAMPFIRE_UNLIT
	if (held and USE_ITEMS[held]) or (onCampfire and (cookable or (def and def.tool and def.tool.kind == "shovel"))) then
		Remotes.get("UseItem"):FireServer({ x = hit.x, y = hit.y, z = hit.z, nx = hit.nx, ny = hit.ny, nz = hit.nz })
		BlockInteraction.used:Fire(held or "", hit.id)
		BlockInteraction.swing:Fire()
		return true
	end
	return false
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
		airborne = humanoid ~= nil and not MovementController.onGround,
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
-- The food to eat: the main hand's, else the off hand's (Java: main hand first). Slot or nil.
local function foodSlot(): number?
	local main = ItemRegistry.get(InventoryClient.heldItem())
	if main and main.food then
		return InventoryClient.selected
	end
	local off = InventoryClient.offhand()
	local od = off and ItemRegistry.get(off.item)
	if (not main or (not main.block and not main.tool)) and od and od.food then
		return Config.OFFHAND_SLOT
	end
	return nil
end

local function updateEating(dt: number)
	local slot = foodSlot()
	local canEat = useHeld and slot ~= nil and SurvivalClient.food < SurvivalRules.MAX_FOOD and not SurvivalClient.dead
	if not canEat or (eating and eating.slot ~= slot) then
		stopEating()
		return
	end
	if not eating then
		eating = { progress = 0, slot = slot :: number }
		SurvivalClient.eatStart(slot == Config.OFFHAND_SLOT)
	end
	local e = eating :: { progress: number, slot: number }
	e.progress += dt / EAT_SECONDS
	SurvivalHUD.setEatProgress(e.progress)
	if e.progress >= 1 then
		SurvivalClient.eatFinish()
		eating = nil -- next bite starts next frame if still held
	end
end

-- Bow, crossbow and shield (Phase 8c): held right button. Server: CombatGearService.
type GearUse = { kind: string, start: number, slot: number }
local gearUse: GearUse? = nil
local gearHeld = false

local function hasArrows(): boolean
	for idx, st in InventoryClient.slots do
		if st and st.item == "arrow" then
			return true
		end
	end
	return false
end

local function gearRemote(m: { [string]: any })
	Remotes.get("Gear"):FireServer(m)
end

local function lookVector(): Vector3?
	local _, look = CameraController.getEyeAndLook()
	return look
end

-- What a right-click starts with the held items (nil = nothing gear-related). `aimingAtBlock`
-- lets a held block be placed instead of raising an off-hand shield (Java: main hand first).
local function gearFor(aimingAtBlock: boolean): string?
	local held = InventoryClient.heldItem()
	if held == "bow" or held == "crossbow" then
		return if hasArrows() then held else nil
	elseif held == "crossbow_loaded" then
		return "fire"
	elseif held == "shield" then
		return "shield"
	end
	local def = ItemRegistry.get(held)
	if def and (def.food or (def.block and aimingAtBlock)) then
		return nil
	end
	local off = InventoryClient.offhand()
	if off and off.item == "shield" then
		return "shield"
	end
	return nil
end

local function stopGear(release: boolean)
	local g = gearUse
	gearUse = nil
	MovementController.bowPull = 0
	if not g then
		return
	end
	if g.kind == "shield" then
		gearRemote({ type = "shield", on = false })
	elseif release and g.kind == "bow" then
		local ticks = (os.clock() - g.start) * 20
		local f = ticks / 20
		if (f * f + f * 2) / 3 >= 0.1 then
			gearRemote({ type = "release", look = lookVector() })
			BlockInteraction.used:Fire("bow_shoot", 0)
			BlockInteraction.swing:Fire()
		else
			gearRemote({ type = "release", look = lookVector() }) -- too short: the server ignores it
		end
	elseif release and g.kind == "crossbow" then
		if (os.clock() - g.start) * 20 >= Combat.CROSSBOW_CHARGE_TICKS then
			BlockInteraction.used:Fire("crossbow_load", 0)
		end
		gearRemote({ type = "release", look = lookVector() })
	end
end

-- Start using gear on a right-click. Returns true if the click was used.
local function startGear(aimingAtBlock: boolean): boolean
	local kind = gearFor(aimingAtBlock)
	if not kind then
		return false
	end
	if kind == "fire" then
		gearRemote({ type = "fire", look = lookVector() })
		BlockInteraction.used:Fire("crossbow_shoot", 0)
		BlockInteraction.swing:Fire()
		return true
	end
	gearUse = { kind = kind, start = os.clock(), slot = InventoryClient.selected }
	gearHeld = true
	if kind == "shield" then
		gearRemote({ type = "shield", on = true })
	else
		gearRemote({ type = "draw" })
	end
	return true
end

local function updateGear()
	local g = gearUse
	if not g then
		return
	end
	if not gearHeld or InventoryClient.uiOpen or SurvivalClient.dead or g.slot ~= InventoryClient.selected then
		stopGear(gearHeld == false and not InventoryClient.uiOpen and not SurvivalClient.dead and g.slot == InventoryClient.selected)
		return
	end
	if g.kind == "bow" then
		-- Java FOV zoom while drawing: f = min(1, (ticks / 20)^2)
		local f = (os.clock() - g.start)
		MovementController.bowPull = math.min(1, f * f)
	end
end

-- Right-click with a piece of armour: wear it (Java).
local function tryEquip(): boolean
	local def = ItemRegistry.get(InventoryClient.heldItem())
	if def and def.armor then
		InventoryClient.equipHeld()
		BlockInteraction.used:Fire("armor_equip", 0)
		return true
	end
	return false
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
	updateGear()
	-- Java: eating, drawing a bow, charging a crossbow or blocking slows you to 20 %
	MovementController.usingItem = eating ~= nil or gearUse ~= nil
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
		hit = VoxelRaycast.cast(blockAt, o.X, o.Y, o.Z, look.X, look.Y, look.Z, Config.REACH, stopsRay, rayShape)
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
	-- an item frame in front of the block takes the clicks too
	BlockInteraction.frameTarget = nil
	if eye and not BlockInteraction.mobTarget then
		local fk, fd = DecorClient.raycast(eye, look, Config.REACH * BS)
		if fk and (not hit or fd < hit.distance * BS) then
			BlockInteraction.frameTarget = fk
			hit = nil
			BlockInteraction.target = nil
		end
	end

	-- Highlight
	if hit then
		-- outline the block's shape (a slab's half, a door's panel...)
		local lo, hi = Vector3.zero, Vector3.one
		if BlockRegistry.isBoxShape[hit.id + 1] then
			lo, hi = Shapes.bounds(Shapes.at(blockAt, hit.x, hit.y, hit.z, false))
		end
		highlightPart.Size = (hi - lo) * BS + Vector3.one * 0.02
		highlightPart.CFrame = CFrame.new((Vector3.new(hit.x, hit.y, hit.z) + (lo + hi) / 2) * BS)
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
				-- cracks cover only the block's shape (a slab's half, a fence post...)
				local lo, hi = Vector3.zero, Vector3.one
				if BlockRegistry.isBoxShape[hit.id + 1] then
					lo, hi = Shapes.bounds(Shapes.at(blockAt, cur.x, cur.y, cur.z, false))
				end
				crackPart.Size = (hi - lo) * BS + Vector3.one * 0.04
				crackPart.CFrame = CFrame.new((Vector3.new(cur.x, cur.y, cur.z) + (lo + hi) / 2) * BS)
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
		local fromOffhand = false
		if not (item and item.block) and not (item and item.food) then
			-- Java: a main hand that can't place lets the off hand place its block (torches)
			local off = InventoryClient.offhand()
			local od = off and ItemRegistry.get(off.item)
			if od and od.block then
				item, fromOffhand = od, true
			end
		end
		if item and item.block then
			local x, y, z = hit.x + hit.nx, hit.y + hit.ny, hit.z + hit.nz
			local _, look = CameraController.getEyeAndLook()
			local lx, lz = if look then look.X else 0, if look then look.Z else -1
			local changes = Placement.resolve(item.block, {
				hx = hit.x, hy = hit.y, hz = hit.z, nx = hit.nx, ny = hit.ny, nz = hit.nz,
				px = hit.px, py = hit.py, pz = hit.pz, lx = lx, lz = lz,
			}, ClientWorld.getBlock)
			local blocked = false
			if changes then
				for _, c in changes do
					if BlockRegistry.isSolid[c.id + 1] and overlapsSelf(c.x, c.y, c.z) then
						blocked = true
					end
				end
			end
			if changes and not blocked then
				send("place", x, y, z, hit.nx, hit.ny, hit.nz, { hit.px, hit.py, hit.pz, lx, lz, if fromOffhand then 1 else 0 })
				for _, c in changes do
					ClientWorld.setBlock(c.x, c.y, c.z, c.id, true) -- instant prediction
				end
				BlockInteraction.placed:Fire(changes[1].x, changes[1].y, changes[1].z, changes[1].id)
				BlockInteraction.swing:Fire()
			end
			nextPlaceAt = now + Config.PLACE_REPEAT
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
		if BlockInteraction.frameTarget then
			DecorClient.hitFrame(BlockInteraction.frameTarget :: string)
			return
		end
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
		if tryInteract(MovementController.sneaking) then
			return
		end
		if tryEquip() then
			return
		end
		if startGear(hit ~= nil) then
			return
		end
		if tryUse() then
			return
		end
		if foodSlot() then
			useHeld = true
			return
		end
		placeHeld = true
		nextPlaceAt = 0
	end, function()
		placeHeld = false
		useHeld = false
		gearHeld = false
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
		elseif (t == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2) and BlockInteraction.frameTarget then
			DecorClient.hitFrame(BlockInteraction.frameTarget :: string)
			BlockInteraction.swing:Fire()
		elseif t == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2 then
			breakHeld = true
		elseif t == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.ButtonL2 then
			local hit = BlockInteraction.target
			local shift = MovementController.sneaking or UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
				or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
			local held = ItemRegistry.get(InventoryClient.heldItem())
			if hit and INTERACTABLE[hit.id] and not shift then
				InventoryClient.openBlock(hit.x, hit.y, hit.z) -- server opens the window; the UI follows
			elseif tryInteract(shift) then
				-- door / sign / item frame / bed handled
			elseif tryUse() then
				-- bucket / flint and steel / campfire handled
			elseif tryEquip() then
				-- armour worn
			elseif startGear(hit ~= nil) then
				-- bow / crossbow / shield
			elseif foodSlot() then
				useHeld = true -- eat (main hand, else the off hand)
			else
				placeHeld = true
				nextPlaceAt = 0 -- first placement is immediate
			end
		elseif input.KeyCode == (Enum.KeyCode :: any)[Config.KEY_SWAP_HANDS] then
			InventoryClient.swapHands() -- F (Java): main hand <-> off hand
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
			gearHeld = false
		end
	end)
	if UserInputService.TouchEnabled then
		makeTouchButtons()
	end

	RunService:BindToRenderStep("RocraftBlockInteraction", Enum.RenderPriority.Camera.Value + 2, update)
end

return BlockInteraction
