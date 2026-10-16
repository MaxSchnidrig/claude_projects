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
	  - Carrying pose: for every player carrying an egg, the arms stay raised
	    above the head. (The server raises the shoulders; here we stop the walk
	    animation from swinging the arms, so the legs walk but the arms don't.)
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Constants = require(ReplicatedStorage.Shared.Constants)

local EggController = {}
EggController.Name = "EggController"

local player = Players.LocalPlayer

-- Arm joints that should stay still (no walk swing) while carrying.
local ARM_JOINTS = {
	{ "RightUpperArm", "RightShoulder" },
	{ "LeftUpperArm", "LeftShoulder" },
	{ "RightLowerArm", "RightElbow" },
	{ "LeftLowerArm", "LeftElbow" },
	{ "RightHand", "RightWrist" },
	{ "LeftHand", "LeftWrist" },
	{ "Torso", "Right Shoulder" },
	{ "Torso", "Left Shoulder" },
}

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

local function holdArmsStill()
	for _, other in Players:GetPlayers() do
		if other:GetAttribute(Constants.Attributes.CarryingEgg) ~= nil and other.Character then
			local character = other.Character
			for _, names in ARM_JOINTS do
				local part = character:FindFirstChild(names[1])
				local joint = part and part:FindFirstChild(names[2])
				if joint and joint:IsA("Motor6D") then
					joint.Transform = CFrame.identity
				end
			end
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

	-- Runs after animations each frame, so it overrides the arm swing.
	RunService.Stepped:Connect(holdArmsStill)
end

return EggController
