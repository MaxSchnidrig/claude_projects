--!strict
-- First-person hand, held item and view bobbing (first-person camera only).
--
--   hand       a blocky arm in the avatar's right-arm colour, lower right of the view
--   held item  its 3D mesh (Render/ItemMeshes): blocks as a small textured block, everything
--              else as the 16x16 icon extruded one pixel deep (Java's item models)
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
local ItemMeshes = require(script.Parent.Parent.Render.ItemMeshes)
local CameraController = require(script.Parent.CameraController)
local InventoryClient = require(script.Parent.InventoryClient)

local BS = Config.BLOCK_SIZE

local ViewModel = {}

local model: Model
local arm: Part
local held: Model? = nil
local heldKey: string? = nil
local heldFinal = true
local offFinal = true
local offHeld: Model? = nil -- the off-hand item, lower left (Java shows it without an arm)
local offKey: string? = nil
local offEquipT = 1
local swingStart = -math.huge
local SWING = 6 / 20
local equipT = 1
local walkDist = 0
local bobAmount = 0
local bobbing = true -- Settings: "bobbing"

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

-- The held item as a model with a "Main" part: its 3D mesh (Render/ItemMeshes: extruded icon or
-- a small block) or, until that's built, a plain stand-in. Second result: is it the final mesh?
local VIEW_PIXEL = 0.8 / 16 -- flat items are 0.8 studs wide in the hand
local VIEW_BLOCK = 0.62
local function buildHeld(key: string?): (Model?, boolean)
	if not key then
		return nil, true
	end
	local def = ItemRegistry.get(key)
	if not def then
		return nil, true
	end
	local m = Instance.new("Model")
	m.Name = "Held"
	local mesh = ItemMeshes.make(key, VIEW_PIXEL, VIEW_BLOCK)
	local main: BasePart = mesh or ItemMeshes.standIn(key, VIEW_PIXEL, VIEW_BLOCK)
	main.Name = "Main"
	main.CastShadow = false
	main.Parent = m
	return m, mesh ~= nil
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
	require(script.Parent.Settings).onChange(function(key: string, value: any)
		if key == "bobbing" then
			bobbing = value
		end
	end)
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
		local MovementController = require(script.Parent.MovementController) :: any
		-- (Java hides the hand while you sleep)
		local first = CameraController.mode == "first" and humanoid ~= nil and humanoid.Health > 0
			and not MovementController.sleeping
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
		local v = MovementController.velocity -- blocks/tick (the motor moves the body)
		local horiz = Vector3.new(v.X, 0, v.Z).Magnitude
		local grounded = MovementController.onGround
		local target = if grounded and bobbing then math.min(0.1, horiz) else 0
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
		if key ~= heldKey or not heldFinal then
			if key ~= heldKey then
				equipT = 0
			end
			if key ~= heldKey or ItemMeshes.get(key :: string) then
				heldKey = key
				if held then
					(held :: Model):Destroy()
				end
				held, heldFinal = buildHeld(key)
				if held then
					(held :: Model).Parent = model
				end
			end
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
		-- off hand: the item mirrored at the lower left; a raised shield comes up toward the middle
		local ok = InventoryClient.offhand()
		local okKey = ok and ok.item
		if okKey ~= offKey or not offFinal then
			if okKey ~= offKey then
				offEquipT = 0
			end
			if okKey ~= offKey or ItemMeshes.get(okKey :: string) then
				offKey = okKey
				if offHeld then
					(offHeld :: Model):Destroy()
				end
				offHeld, offFinal = buildHeld(okKey)
				if offHeld then
					(offHeld :: Model).Parent = model
				end
			end
		end
		offEquipT = math.min(1, offEquipT + dt * 4)
		local oh = offHeld
		if oh then
			local main = oh:FindFirstChild("Main") :: BasePart?
			if main then
				local raised = okKey == "shield" and MovementController.usingItem and heldKey ~= "shield"
				local isCard = main.Size.Z < 0.1
				local at = cam.CFrame * CFrame.new(if raised then -0.55 else -1.05, (if raised then -0.55 else -0.75) - (1 - offEquipT) * 0.9, -1.9)
				main.CFrame = at * (if isCard then CFrame.Angles(0, math.rad(-80), math.rad(20)) else CFrame.Angles(0, math.rad(-45), 0))
				local tip = oh:FindFirstChild("Tip") :: BasePart?
				if tip then
					tip.CFrame = main.CFrame * CFrame.new(0, 0.38, 0)
				end
			end
		end
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
