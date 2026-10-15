--!strict
--[[
	PlayerSpeed
	===========
	The ONE place that sets a player's WalkSpeed, so different systems don't
	fight over it.

	WalkSpeed = min(Config.Player.BaseWalkSpeed + bonus, Config.Player.MaxWalkSpeed)
	            * (all multipliers multiplied together)

	  - The bonus comes from the Speed stat (UpgradeService, Milestone 5). It
	    ADDS to the base speed and never replaces it.
	  - Multipliers are named, so each system controls its own:
	      "Carry" = slow-down from holding a heavy egg (EggService)

	Usage:
		PlayerSpeed.SetBonus(player, 6)                  -- +6 WalkSpeed from the Speed stat
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

type State = {
	Bonus: number,
	Multipliers: { [string]: number },
}

local PlayerSpeed = {}

local states: { [Player]: State } = {}

local function getState(player: Player): State
	local state = states[player]
	if not state then
		state = { Bonus = 0, Multipliers = {} }
		states[player] = state
	end
	return state
end

-- The WalkSpeed this player should have right now.
function PlayerSpeed.Get(player: Player): number
	local state = getState(player)
	local speed = math.min(Config.Player.BaseWalkSpeed + state.Bonus, Config.Player.MaxWalkSpeed)
	for _, multiplier in state.Multipliers do
		speed *= multiplier
	end
	return speed
end

-- Push the current value onto the character's Humanoid.
function PlayerSpeed.Apply(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = PlayerSpeed.Get(player)
	end
end

function PlayerSpeed.SetBonus(player: Player, bonus: number)
	getState(player).Bonus = math.max(bonus, 0)
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
	if player.Character then
		PlayerSpeed.Apply(player)
	end
end

Players.PlayerAdded:Connect(watchPlayer)
for _, player in Players:GetPlayers() do
	watchPlayer(player)
end
Players.PlayerRemoving:Connect(function(player)
	states[player] = nil
end)

return PlayerSpeed
