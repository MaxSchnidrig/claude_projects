--!strict
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Motion = require(Shared.Gameplay.HandMotion)
local remote = require(Shared.Net.Remotes).get("HandAction")

type Action = { kind: string, left: boolean, start: number, joint: Motor6D?, base: CFrame? }
local actions: { [Model]: Action } = {}
local Animator = {}
local function clear(character: Model)
	local old = actions[character]
	if old and old.joint and old.base then old.joint.C0 = old.base end
	actions[character] = nil
end
local function play(character: Model, kind: string, left: boolean)
	clear(character)
	if kind ~= "stop" then
		actions[character] = { kind = kind, left = left, start = os.clock() }
	end
end
function Animator.start(kind: string, left: boolean?)
	local c = Players.LocalPlayer.Character
	if c then
		play(c, kind, left == true)
		remote:FireServer(kind, left == true)
	end
end
function Animator.view(left: boolean): CFrame
	local c = Players.LocalPlayer.Character
	local a = c and actions[c]
	if a and a.left == left then
		local view = Motion.pose(a.kind, os.clock() - a.start, left)
		return view
	end
	return CFrame.identity
end
function Animator.init()
	remote.OnClientEvent:Connect(function(c: Model, kind: string, left: boolean)
		if c and c ~= Players.LocalPlayer.Character then play(c, kind, left) end
	end)
	RunService.RenderStepped:Connect(function()
		for c, a in actions do
			local elapsed = os.clock() - a.start
			local hum = c:FindFirstChildOfClass("Humanoid")
			if elapsed >= (Motion.duration :: {[string]: number})[a.kind] or not c.Parent or not hum or hum.Health <= 0 then
				clear(c)
				continue
			end
			local torso = c:FindFirstChild("Torso")
			local joint = torso and torso:FindFirstChild(if a.left then "Left Shoulder" else "Right Shoulder")
			if joint and joint:IsA("Motor6D") then
				if a.joint ~= joint then
					a.joint, a.base = joint, joint.C0
				end
				local base = a.base :: CFrame
				local _, rotation = Motion.pose(a.kind, elapsed, a.left)
				joint.C0 = CFrame.new(base.Position) * rotation * base.Rotation
			end
		end
	end)
end
return Animator
