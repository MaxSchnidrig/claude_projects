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

local BS = Config.BLOCK_SIZE
local AIR = 0
local isLiquid = BlockRegistry.isLiquid

local BlockInteraction = {}
BlockInteraction.target = nil :: VoxelRaycast.Hit?

type MiningState = { x: number, y: number, z: number, item: string?, progress: number, started: boolean }

local breakHeld = false
local placeHeld = false
local mining: MiningState? = nil
local cooldownUntil = 0
local nextPlaceAt = 0

local highlightPart: Part
local selection: SelectionBox
local crackPart: Part

local function stopsRay(id: number): boolean
	return id ~= AIR and not isLiquid[id + 1]
end

local function blockAt(x: number, y: number, z: number): number?
	return ClientWorld.getBlock(x, y, z)
end

local function send(action: string, x: number, y: number, z: number)
	Remotes.get("BlockAction"):FireServer(action, x, y, z)
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
	crackPart.Transparency = 1
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

local function update(dt: number)
	local now = os.clock()
	local eye, look = CameraController.getEyeAndLook()
	local hit: VoxelRaycast.Hit? = nil
	if eye then
		local o = eye / BS
		hit = VoxelRaycast.cast(blockAt, o.X, o.Y, o.Z, look.X, look.Y, look.Z, Config.REACH, stopsRay)
	end
	BlockInteraction.target = hit

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
				ClientWorld.setBlock(cur.x, cur.y, cur.z, AIR) -- prediction; server corrects if wrong
				cooldownUntil = now + (if total <= 0 then 0.05 else Config.BREAK_COOLDOWN)
				mining = nil
				crackPart.Transparency = 1
			else
				local stage = math.floor(cur.progress * 10) -- 0..9
				crackPart.CFrame = blockCFrame(cur.x, cur.y, cur.z)
				crackPart.Transparency = 0.92 - stage * 0.06
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
				send("place", x, y, z)
				ClientWorld.setBlock(x, y, z, item.block) -- prediction
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
		breakHeld = true
	end, function()
		breakHeld = false
	end)
	button("Place", UDim2.new(1, -120, 1, -130), function()
		placeHeld = true
		nextPlaceAt = 0
	end, function()
		placeHeld = false
	end)
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
end

function BlockInteraction.init()
	makeVisuals()

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2 then
			breakHeld = true
		elseif t == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.ButtonL2 then
			placeHeld = true
			nextPlaceAt = 0 -- first placement is immediate
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or input.KeyCode == Enum.KeyCode.ButtonR2 then
			breakHeld = false
		elseif t == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.ButtonL2 then
			placeHeld = false
		end
	end)
	if UserInputService.TouchEnabled then
		makeTouchButtons()
	end

	RunService:BindToRenderStep("RocraftBlockInteraction", Enum.RenderPriority.Camera.Value + 2, update)
end

return BlockInteraction
