--!strict
--[[
	EggController
	=============
	Client-side egg helpers. While you carry an egg, the "Steal" prompts on
	other eggs are hidden, since you can only carry one at a time.

	This only changes what YOU see. The server still refuses a second egg even
	if someone gets around this.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Constants = require(ReplicatedStorage.Shared.Constants)

local EggController = {}
EggController.Name = "EggController"

local player = Players.LocalPlayer

local function isCarrying(): boolean
	return player:GetAttribute(Constants.Attributes.CarryingEgg) ~= nil
end

local function refreshPrompt(prompt: Instance)
	if prompt:IsA("ProximityPrompt") then
		prompt.Enabled = not isCarrying()
	end
end

local function refreshAll()
	for _, prompt in CollectionService:GetTagged(Constants.Tags.EggPrompt) do
		refreshPrompt(prompt)
	end
end

function EggController.Init()
end

function EggController.Start()
	CollectionService:GetInstanceAddedSignal(Constants.Tags.EggPrompt):Connect(refreshPrompt)
	player:GetAttributeChangedSignal(Constants.Attributes.CarryingEgg):Connect(refreshAll)
	refreshAll()
end

return EggController
