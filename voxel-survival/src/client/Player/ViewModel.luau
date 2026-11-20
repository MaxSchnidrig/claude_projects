--!strict
-- First-person hand, held item and view bobbing (first-person camera only).
--
--   hand       a blocky arm in the avatar's right-arm colour, lower right of the view
--   held item  its 3D mesh (Render/ItemMeshes): blocks as a small textured block, everything
--              else as the 16x16 icon extruded one pixel deep (Java's item models)
--   action     original tool strokes and hand-to-mouth motions shared with the R6 avatar
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
local Glint = require(script.Parent.Parent.UI.Glint)
local CameraController = require(script.Parent.CameraController)
local InventoryClient = require(script.Parent.InventoryClient)

local Motion = require(Shared.Gameplay.HandMotion)
local ActionAnimator = require(script.Parent.ActionAnimator)
local BS = Config.BLOCK_SIZE

local ViewModel = {}

local model: Model
local arm: Part
local held: Model? = nil
local heldKey: string? = nil
local heldFinal = true
local offFinal = true
local offHeld: Model? = nil -- the off-hand item, lower left
local offKey: string? = nil
local offEquipT = 1
local leftArm: Part
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
local Grip = require(script.Parent.ItemGrip)
local VIEW_SCALE = 0.48
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
	local main, final = Grip.make(key, VIEW_SCALE)
	main.Name = "Main"
	main.CastShadow = false
	main.Parent = m
	return m, final
end

local function armColor(): Color3
	local c = Players.LocalPlayer.Character
	local a = c and c:FindFirstChild("Right Arm")
	if a and a:IsA("BasePart") then
		return a.Color
	end
	return Color3.fromRGB(230, 190, 150)
end

function ViewModel.swing(action: string?, left: boolean?)
	local def = ItemRegistry.get(InventoryClient.heldItem())
	ActionAnimator.start(action or Motion.stroke(if def and def.tool then def.tool.kind else nil), left)
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
	leftArm = arm:Clone()
	leftArm.Name = "OffArm"
	leftArm.Parent = model
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
			and not MovementController.sleeping and not MovementController.spectating
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
		-- enchanted items shimmer in your hands too
		local hs = InventoryClient.heldStack()
		Glint.sync(held, hs ~= nil and hs.ench ~= nil)
		local os2 = InventoryClient.offhand()
		Glint.sync(offHeld, os2 ~= nil and os2.ench ~= nil)

		local base = cam.CFrame * CFrame.new(1.05, -1.02 - (1 - equipT) * 0.9, -1.62)
			* ActionAnimator.view(false) * CFrame.Angles(0, math.rad(8), 0)
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
				local at = cam.CFrame * CFrame.new(if raised then -0.55 else -1.05, (if raised then -0.55 else -0.75) - (1 - offEquipT) * 0.9, -1.9) * ActionAnimator.view(true)
				leftArm.CFrame = at * CFrame.new(-0.1, -0.28, 0.69)
				local avatarArm = character and character:FindFirstChild("Left Arm")
				leftArm.Color = if avatarArm and avatarArm:IsA("BasePart") then avatarArm.Color else arm.Color
				main.CFrame = at * CFrame.new(-0.1,-0.20,0.03) * Grip.offset(okKey :: string, VIEW_SCALE, true)
			end
		end
		local h = held
		if h then
			local main = h:FindFirstChild("Main") :: BasePart?
			if main then
				main.CFrame = base * CFrame.new(0,0.08,-0.25) * Grip.offset(key :: string, VIEW_SCALE, false)
			end
		end
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.LocalTransparencyModifier = if d == leftArm and not oh then 1 else 0
			end
		end
	end)
end

return ViewModel
