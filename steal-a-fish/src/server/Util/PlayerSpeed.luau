--!strict
--[[
	PlayerSpeed
	===========
	The ONE place that sets a player's WalkSpeed, so different systems don't
	fight over it.

	WalkSpeed = Config.WalkSpeedFromStat(Speed stat) * (all multipliers multiplied together)

	  - The Speed stat comes from SpeedService (the treadmill).
	  - Multipliers are named, so each system controls its own:
	      "Carry" = slow-down from holding an egg (EggService; 1 = none)

	The final WalkSpeed is also copied to the player attribute "WalkSpeed",
	so the HUD can show it.

	Usage:
		PlayerSpeed.SetSpeedStat(player, 12500)
		PlayerSpeed.SetMultiplier(player, "Carry", 0.9)
		PlayerSpeed.SetMultiplier(player, "Carry", nil)  -- remove it

	WalkSpeed is reapplied automatically every time the character respawns.
	Note: a cheater can change their own WalkSpeed on their computer. The
	server's distance checks (for example, egg pickup range) limit what they
	can gain from it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Constants = require(ReplicatedStorage.Shared.Constants)

type State = {
	Stat: number,
	Multipliers: { [string]: number },
}

local PlayerSpeed = {}

local states: { [Player]: State } = {}

local function getState(player: Player): State
	local state = states[player]
	if not state then
		state = { Stat = Config.Speed.StartingStat, Multipliers = {} }
		states[player] = state
	end
	return state
end

-- The WalkSpeed this player should have right now.
function PlayerSpeed.Get(player: Player): number
	local state = getState(player)
	local speed = Config.WalkSpeedFromStat(state.Stat)
	for _, multiplier in state.Multipliers do
		speed *= multiplier
	end
	return speed
end

-- Push the current value onto the character's Humanoid.
function PlayerSpeed.Apply(player: Player)
	local speed = PlayerSpeed.Get(player)
	player:SetAttribute(Constants.Attributes.WalkSpeed, speed)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = speed
	end
end

function PlayerSpeed.SetSpeedStat(player: Player, stat: number)
	getState(player).Stat = math.max(stat, 0)
	PlayerSpeed.Apply(player)
end

function PlayerSpeed.SetMultiplier(player: Player, key: string, value: number?)
	local multipliers = getState(player).Multipliers
	if value then
		multipliers[key] = value
	else
		multipliers[key] = nil
	end
	PlayerSpeed.Apply(player)
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		character:WaitForChild("Humanoid", 10)
		PlayerSpeed.Apply(player)
	end)
	PlayerSpeed.Apply(player)
end

Players.PlayerAdded:Connect(watchPlayer)
for _, player in Players:GetPlayers() do
	watchPlayer(player)
end
Players.PlayerRemoving:Connect(function(player)
	states[player] = nil
end)

return PlayerSpeed
