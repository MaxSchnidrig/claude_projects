--!strict
-- First-person hand, held item and view bobbing (first-person camera only).
--
--   hand       a blocky arm in the avatar's right-arm colour, lower right of the view
--   held item  blocks: a small textured cube (atlas tiles on each side); torches: stick + tip;
--              other items: their 16x16 icon on a thin card
--   swing      Java's 6-tick arm swing on attacks, placements and while mining
--   equip      the hand dips and comes back up when the held item changes
--   bobbing    Java view bobbing: walking moves the view in a figure-eight (sin/cos of the
--              distance walked), scaled by how fast you move; off in the air
-- The viewmodel never collides, casts no shadow and is hidden in the third-person views.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local ItemRegistry = require(Shared.Items.ItemRegistry)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local TorchRules = require(Shared.Blocks.TorchRules)
local TextureAtlas = require(script.Parent.Parent.Render.TextureAtlas)
local CameraController = require(script.Parent.CameraController)
local InventoryClient = require(script.Parent.InventoryClient)

local BS = Config.BLOCK_SIZE

local ViewModel = {}

local model: Model
local arm: Part
local held: Model? = nil
local heldKey: string? = nil
local swingStart = -math.huge
local SWING = 6 / 20
local equipT = 1
local walkDist = 0
local bobAmount = 0

local function part(size: Vector3, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	return p
end

local function textured(p: Part, content: Content?, rectFn: ((Enum.NormalId) -> (Vector2?, Vector2?))?)
	for _, face in Enum.NormalId:GetEnumItems() do
		local offset, size = nil, nil
		if rectFn then
			offset, size = rectFn(face)
		end
		if offset and size and content then
			local gui = Instance.new("SurfaceGui")
			gui.Face = face
			gui.CanvasSize = Vector2.new(64, 64)
			gui.LightInfluence = 1
			local img = Instance.new("ImageLabel")
			img.Size = UDim2.fromScale(1, 1)
			img.BackgroundTransparency = 1
			img.ResampleMode = Enum.ResamplerMode.Pixelated
			img.ImageRectOffset = offset
			img.ImageRectSize = size
			pcall(function()
				(img :: any).ImageContent = content
			end)
			img.Parent = gui
			gui.Parent = p
		end
	end
end

local function buildHeld(key: string?): Model?
	if not key then
		return nil
	end
	local def = ItemRegistry.get(key)
	if not def then
		return nil
	end
	local m = Instance.new("Model")
	m.Name = "Held"
	if def.block and TorchRules.isTorch(def.block) then
		local stick = part(Vector3.new(0.12, 0.62, 0.12), Color3.fromRGB(116, 82, 44))
		stick.Name = "Main"
		stick.Parent = m
		local tip = part(Vector3.new(0.14, 0.16, 0.14), Color3.fromRGB(255, 200, 90), Enum.Material.Neon)
		tip.Name = "Tip"
		tip.Parent = m
	elseif def.block then
		local b = BlockRegistry.byId[def.block]
		local cube = part(Vector3.one * 0.62, Color3.new(1, 1, 1))
		cube.Name = "Main"
		cube.Transparency = if b and b.transparent then 0.4 else 0
		textured(cube, TextureAtlas.content, function(face)
			if not b then
				return nil, nil
			end
			local dir = if face == Enum.NormalId.Top then BlockRegistry.Dir.TOP
				elseif face == Enum.NormalId.Bottom then BlockRegistry.Dir.BOTTOM
				else BlockRegistry.Dir.EAST
			return TextureAtlas.pixelRect(b.faceTexture[dir])
		end)
		cube.Parent = m
	else
		local card = part(Vector3.new(0.75, 0.75, 0.04), Color3.new(1, 1, 1))
		card.Name = "Main"
		card.Transparency = 1
		textured(card, TextureAtlas.iconContent, function(face)
			if face == Enum.NormalId.Front or face == Enum.NormalId.Back then
				return TextureAtlas.iconRect(def.key)
			end
			return nil, nil
		end)
		card.Parent = m
	end
	return m
end

local function armColor(): Color3
	local c = Players.LocalPlayer.Character
	local a = c and c:FindFirstChild("Right Arm")
	if a and a:IsA("BasePart") then
		return a.Color
	end
	return Color3.fromRGB(230, 190, 150)
end

function ViewModel.swing()
	swingStart = os.clock()
end

function ViewModel.init(swingEvent: BindableEvent)
	model = Instance.new("Model")
	model.Name = "ViewModel"
	arm = part(Vector3.new(0.42, 0.42, 1.25), armColor())
	arm.Name = "Arm"
	arm.Parent = model
	model.Parent = workspace.CurrentCamera
	swingEvent.Event:Connect(ViewModel.swing)

	-- after the camera controller (Camera + 1): bob the view, then place the hand on it
	RunService:BindToRenderStep("RocraftViewModel", Enum.RenderPriority.Camera.Value + 2, function(dt)
		local cam = workspace.CurrentCamera
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local first = CameraController.mode == "first" and humanoid ~= nil and humanoid.Health > 0
		if model.Parent ~= cam then
			model.Parent = cam
		end
		if not first or not root or not humanoid then
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") then
					d.LocalTransparencyModifier = 1
				end
			end
			return
		end

		-- view bobbing (Java): distance walked drives the phase, speed the amount
		local v = root.AssemblyLinearVelocity
		local horiz = Vector3.new(v.X, 0, v.Z).Magnitude / BS / 20 -- blocks/tick
		local grounded = humanoid.FloorMaterial ~= Enum.Material.Air
		local target = if grounded then math.min(0.1, horiz) else 0
		bobAmount += (target - bobAmount) * (1 - 0.6 ^ (dt * 20))
		walkDist += horiz * 0.6 * dt * 20
		local f = walkDist * math.pi
		local bx = math.sin(f) * bobAmount * 0.5 * BS
		local by = -math.abs(math.cos(f) * bobAmount) * BS
		local rz = math.rad(math.sin(f) * bobAmount * 3)
		local rx = math.rad(math.abs(math.cos(f - 0.2) * bobAmount) * 5)
		cam.CFrame = cam.CFrame * CFrame.new(bx, by, 0) * CFrame.Angles(rx, 0, rz)

		-- held item changes: dip and raise
		local key = InventoryClient.heldItem()
		if key ~= heldKey then
			heldKey = key
			if held then
				(held :: Model):Destroy()
			end
			held = buildHeld(key)
			if held then
				(held :: Model).Parent = model
			end
			equipT = 0
		end
		equipT = math.min(1, equipT + dt * 4)
		arm.Color = armColor()

		-- swing: Java's 6-tick arc
		local s = math.clamp((os.clock() - swingStart) / SWING, 0, 1)
		local swingP = if s < 1 then s else 0
		local sq = math.sin(math.sqrt(swingP) * math.pi)
		local sw = math.sin(swingP * math.pi)
		local base = cam.CFrame
			* CFrame.new(1.1 - sq * 0.25, -1.05 - (1 - equipT) * 0.9 + sw * 0.15, -1.6 - sw * 0.35)
			* CFrame.Angles(math.rad(-sw * 70), math.rad(-sq * 20 + 8), math.rad(-sq * 15))
		arm.CFrame = base * CFrame.new(0, 0, 0.35)
		local h = held
		if h then
			local main = h:FindFirstChild("Main") :: BasePart?
			if main then
				local isCard = main.Size.Z < 0.1
				main.CFrame = base * CFrame.new(-0.05, 0.35, -0.45)
					* (if isCard then CFrame.Angles(0, math.rad(80), math.rad(-20)) else CFrame.Angles(0, math.rad(45), 0))
				local tip = h:FindFirstChild("Tip") :: BasePart?
				if tip then
					tip.CFrame = main.CFrame * CFrame.new(0, 0.38, 0)
				end
			end
		end
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = 0
			end
		end
	end)
end

return ViewModel
