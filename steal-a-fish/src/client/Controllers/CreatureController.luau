--!strict
--[[
	CreatureController
	==================
	Brings fish, eggs and sharks to life on your screen (looks only; the
	server decides where everything is):

	  - Every model tagged "Animated" has "Wiggle" joints (made by the
	    server's Voxel builder): tails, fins, tentacles, wings. Each frame we
	    swing them with a sine wave, using the joint's attributes
	    (Axis, Amount, Speed, Phase).
	  - Sharks (attribute "Swims") swish harder and faster the faster they
	    move, so a chasing shark really thrashes its tail.
	  - Lights and particles tagged "LodEffect" are switched off when they
	    are far from the camera (Config.RarityEffects.EffectsDistance), and
	    animations stop beyond AnimateDistance, to keep the game smooth.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)

local CreatureController = {}
CreatureController.Name = "CreatureController"

local LOD_INTERVAL = 0.5

type Wiggle = {
	Joint: Motor6D,
	Axis: Vector3,
	Amount: number,
	Speed: number,
	Phase: number,
}

type Creature = {
	Instance: Instance,
	Joints: { Wiggle },
	Root: BasePart?,
	Swims: boolean,
	Clock: number, -- its own animation clock (runs faster while swimming fast)
	Phase: number, -- so identical creatures don't move in sync
	Dirty: boolean, -- joints need to be looked up (again)
	Connection: RBXScriptConnection?,
}

local AXES: { [string]: Vector3 } = { X = Vector3.xAxis, Y = Vector3.yAxis, Z = Vector3.zAxis }

local creatures: { [Instance]: Creature } = {}
local rng = Random.new()

local function numberAttribute(instance: Instance, name: string, default: number): number
	local value = instance:GetAttribute(name)
	return if typeof(value) == "number" then value else default
end

local function rootOf(instance: Instance): BasePart?
	if instance:IsA("BasePart") then
		return instance
	elseif instance:IsA("Model") then
		return instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart")
	end
	return nil
end

local function scan(creature: Creature)
	table.clear(creature.Joints)
	for _, item in creature.Instance:GetDescendants() do
		if item:IsA("Motor6D") and item.Name == "Wiggle" then
			local axisName = item:GetAttribute("Axis")
			table.insert(creature.Joints, {
				Joint = item,
				Axis = AXES[if typeof(axisName) == "string" then axisName else "Y"] or Vector3.yAxis,
				Amount = numberAttribute(item, "Amount", 0.2),
				Speed = numberAttribute(item, "Speed", 3),
				Phase = numberAttribute(item, "Phase", 0),
			})
		end
	end
	creature.Root = rootOf(creature.Instance)
	creature.Swims = creature.Instance:GetAttribute("Swims") == true
	creature.Dirty = false
end

local function add(instance: Instance)
	if creatures[instance] then
		return
	end
	local creature: Creature = {
		Instance = instance,
		Joints = {},
		Root = nil,
		Swims = false,
		Clock = 0,
		Phase = rng:NextNumber(0, math.pi * 2),
		Dirty = true,
		Connection = nil,
	}
	-- Parts can arrive a little later over the network: look again then.
	creature.Connection = instance.DescendantAdded:Connect(function(item)
		if item:IsA("Motor6D") or item:IsA("BasePart") then
			creature.Dirty = true
		end
	end)
	creatures[instance] = creature
end

local function remove(instance: Instance)
	local creature = creatures[instance]
	if creature then
		if creature.Connection then
			creature.Connection:Disconnect()
		end
		creatures[instance] = nil
	end
end

local function animate(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local cameraPosition = camera.CFrame.Position
	local maxDistance = Config.RarityEffects.AnimateDistance
	for _, creature in creatures do
		if creature.Dirty then
			scan(creature)
		end
		local root = creature.Root
		if not root or root.Parent == nil or (root.Position - cameraPosition).Magnitude > maxDistance then
			continue
		end
		local strength, pace = 1, 1
		if creature.Swims then
			local speed = root.AssemblyLinearVelocity.Magnitude
			strength = 0.6 + math.min(speed / 15, 1.2)
			pace = 0.7 + math.min(speed / 20, 1.3)
		end
		creature.Clock += dt * pace
		for _, wiggle in creature.Joints do
			local angle = math.sin(creature.Clock * wiggle.Speed + wiggle.Phase + creature.Phase) * wiggle.Amount * strength
			wiggle.Joint.Transform = CFrame.fromAxisAngle(wiggle.Axis, angle)
		end
	end
end

-- Switch far-away lights and particles off (and near ones back on).
local function updateEffects()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local cameraPosition = camera.CFrame.Position
	local maxDistance = Config.RarityEffects.EffectsDistance
	for _, effect in CollectionService:GetTagged(Constants.Tags.LodEffect) do
		local part = effect.Parent
		if part and part:IsA("BasePart") then
			local near = (part.Position - cameraPosition).Magnitude <= maxDistance
			if effect:IsA("ParticleEmitter") or effect:IsA("PointLight") then
				if effect.Enabled ~= near then
					effect.Enabled = near
				end
			end
		end
	end
end

function CreatureController.Init()
end

function CreatureController.Start()
	CollectionService:GetInstanceAddedSignal(Constants.Tags.Animated):Connect(add)
	CollectionService:GetInstanceRemovedSignal(Constants.Tags.Animated):Connect(remove)
	for _, instance in CollectionService:GetTagged(Constants.Tags.Animated) do
		add(instance)
	end
	RunService.RenderStepped:Connect(animate)

	task.spawn(function()
		while true do
			updateEffects()
			task.wait(LOD_INTERVAL)
		end
	end)
end

return CreatureController
