--!strict
-- Cosmetic only. Damage, block breaks, and consumption use their own server checks.
local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Motion = require(Shared.Gameplay.HandMotion)
local remote = require(Shared.Net.Remotes).get("HandAction")
local HandActionService = {}
function HandActionService.init()
	local last: { [Player]: number } = {}
	remote.OnServerEvent:Connect(function(p: Player, kind: any, left: any)
		if typeof(kind) ~= "string" or typeof(left) ~= "boolean" or (kind ~= "stop" and not (Motion.duration :: {[string]: number})[kind]) then return end
		local c = p.Character
		local h = c and c:FindFirstChildOfClass("Humanoid")
		if not c or not h or h.Health <= 0 or p:GetAttribute("Spectator") == true then return end
		local now = os.clock()
		if now - (last[p] or -1) < 0.06 and kind ~= "stop" then return end
		if kind == "stop" and not last[p] then return end
		last[p] = if kind == "stop" then nil else now
		remote:FireAllClients(c, kind, left)
	end)
	Players.PlayerRemoving:Connect(function(p) last[p] = nil end)
end
return HandActionService
