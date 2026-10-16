--!strict
--[[
	EggController
	=============
	Client-side egg helpers (they only change what YOU see; the server checks
	everything again):
	  - While you carry an egg, the "Steal" prompts on other eggs are hidden,
	    since you can only carry one at a time.
	  - "Place Egg" prompts on pads are shown only on YOUR free pads, and only
	    while you hold an egg from your hotbar.
	  - Carrying pose: for every player carrying an egg, the arms stay
	    straight up. The server turns the shoulders up (CarryRig.setRaised);
	    here, every frame AFTER the animations ran, we undo the walk/run
	    animation's arm swing (CarryRig.holdArmsStill), so the legs walk but
	    the arms stay up. Works with Motor6D and AnimationConstraint joints.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CarryRig = require(ReplicatedStorage.Shared.CarryRig)
local Constants = require(ReplicatedStorage.Shared.Constants)

local EggController = {}
EggController.Name = "EggController"

local player = Players.LocalPlayer

local function isCarrying(): boolean
	return player:GetAttribute(Constants.Attributes.CarryingEgg) ~= nil
end

local function holdingEgg(): boolean
	local character = player.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	return tool ~= nil and typeof(tool:GetAttribute(Constants.Attributes.EggRarity)) == "string"
end

---------------------------------------------------------------------------
-- Prompts
---------------------------------------------------------------------------

local function refreshEggPrompt(prompt: Instance)
	if prompt:IsA("ProximityPrompt") then
		prompt.Enabled = not isCarrying()
	end
end

local function refreshPadPrompt(prompt: Instance)
	if not prompt:IsA("ProximityPrompt") then
		return
	end
	local pad = prompt.Parent
	local mine = prompt:GetAttribute(Constants.Attributes.OwnerUserId) == player.UserId
	local free = pad ~= nil and pad:GetAttribute(Constants.Attributes.Occupied) ~= true
	prompt.Enabled = mine and free and holdingEgg()
end

local function refreshAll()
	for _, prompt in CollectionService:GetTagged(Constants.Tags.EggPrompt) do
		refreshEggPrompt(prompt)
	end
	for _, prompt in CollectionService:GetTagged(Constants.Tags.PadPrompt) do
		refreshPadPrompt(prompt)
	end
end

local function watchPadPrompt(prompt: Instance)
	refreshPadPrompt(prompt)
	prompt:GetAttributeChangedSignal(Constants.Attributes.OwnerUserId):Connect(function()
		refreshPadPrompt(prompt)
	end)
	local pad = prompt.Parent
	if pad then
		pad:GetAttributeChangedSignal(Constants.Attributes.Occupied):Connect(function()
			refreshPadPrompt(prompt)
		end)
	end
end

-- Equipping/unequipping a Tool changes what's inside the character.
local function watchCharacter(character: Model)
	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			refreshAll()
		end
	end)
	character.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") then
			refreshAll()
		end
	end)
	refreshAll()
end

---------------------------------------------------------------------------
-- Carrying pose (for every carrying player you can see)
---------------------------------------------------------------------------

-- Each character's arm joints, found once (weak keys: old characters drop out).
local jointCache: { [Model]: { CarryRig.ArmJoint } } = setmetatable({}, { __mode = "k" }) :: any

local function armJoints(character: Model): { CarryRig.ArmJoint }
	local joints = jointCache[character]
	-- Look again if we found nothing yet (the character may still be loading)
	-- or a joint was replaced.
	local stale = joints == nil or #joints == 0
	if joints and not stale then
		for _, arm in joints do
			if arm.Joint.Parent == nil then
				stale = true
				break
			end
		end
	end
	if stale then
		joints = CarryRig.armJoints(character)
		jointCache[character] = joints
	end
	return joints :: { CarryRig.ArmJoint }
end

local function holdArmsStill()
	for _, other in Players:GetPlayers() do
		local character = other.Character
		if character and other:GetAttribute(Constants.Attributes.CarryingEgg) ~= nil then
			CarryRig.holdArmsStill(armJoints(character))
		end
	end
end

function EggController.Init()
end

function EggController.Start()
	CollectionService:GetInstanceAddedSignal(Constants.Tags.EggPrompt):Connect(refreshEggPrompt)
	CollectionService:GetInstanceAddedSignal(Constants.Tags.PadPrompt):Connect(watchPadPrompt)
	for _, prompt in CollectionService:GetTagged(Constants.Tags.PadPrompt) do
		watchPadPrompt(prompt)
	end
	player:GetAttributeChangedSignal(Constants.Attributes.CarryingEgg):Connect(refreshAll)
	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		watchCharacter(player.Character)
	end
	refreshAll()

	-- PreSimulation runs every frame after the animations were applied and
	-- before physics, so what we set here is what you see.
	RunService.PreSimulation:Connect(holdArmsStill)
end

return EggController
