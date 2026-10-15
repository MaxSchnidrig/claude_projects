--!strict
--[[
	EffectsController
	=================
	Effects that happen to YOUR character, requested by the server.
	Sounds and particles join in Milestone 7.

	Knockback: when a shark catches you, the server sends a velocity. Your own
	computer controls your character's physics, so the push has to be applied
	here. The velocity is checked and capped before use.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net)

local EffectsController = {}
EffectsController.Name = "EffectsController"

local MAX_KNOCKBACK_SPEED = 200 -- safety cap

local function applyKnockback(velocity: unknown)
	if typeof(velocity) ~= "Vector3" or velocity.Magnitude > MAX_KNOCKBACK_SPEED then
		return
	end
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (root and root:IsA("BasePart") and humanoid) then
		return
	end
	-- Jump state first, so walking doesn't immediately cancel the push.
	humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	root.AssemblyLinearVelocity = velocity
end

function EffectsController.Init()
end

function EffectsController.Start()
	Net.event(Net.Names.Knockback).OnClientEvent:Connect(applyKnockback)
end

return EffectsController
