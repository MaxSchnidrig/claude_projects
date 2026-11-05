--!strict
-- Spawning. Characters must not exist before the client has built collision under the spawn
-- point (terrain collision is client-side), so auto-loading is off and the client tells us when
-- it's ready. A timeout spawns the player anyway so nobody gets stuck.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Remotes = require(Shared.Net.Remotes)
local WorldService = require(script.Parent.Parent.World.WorldService)
local AvatarService = require(script.Parent.AvatarService)

local BS = Config.BLOCK_SIZE
local READY_TIMEOUT = 20 -- seconds
local RESPAWN_DELAY = 3 -- phase 4 replaces this with a death screen

local SpawnService = {}

local function spawnCFrame(): CFrame
	local b = WorldService.getSpawnBlock()
	-- stand on top of the block below spawnBlock; HumanoidRootPart sits ~3 studs above the feet
	return CFrame.new((b.X + 0.5) * BS, b.Y * BS + 3.5, (b.Z + 0.5) * BS)
end

local function spawn(player: Player)
	if not player.Parent then
		return
	end
	AvatarService.spawn(player, spawnCFrame())
end

function SpawnService.init()
	Players.CharacterAutoLoads = false

	local function onPlayer(player: Player)
		player.DevEnableMouseLock = false -- our camera locks the mouse itself; no shift-lock toggle
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid") :: Humanoid
			AvatarService.configureHumanoid(humanoid)
			humanoid.Died:Connect(function()
				task.delay(RESPAWN_DELAY, spawn, player)
			end)
		end)
		task.delay(READY_TIMEOUT, function()
			if player.Parent and not player.Character then
				warn(`[SpawnService] {player.Name} never reported WorldReady; spawning anyway`)
				spawn(player)
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end

	Remotes.get("WorldReady").OnServerEvent:Connect(function(player)
		if not player.Character then
			spawn(player)
		end
	end)
end

return SpawnService
