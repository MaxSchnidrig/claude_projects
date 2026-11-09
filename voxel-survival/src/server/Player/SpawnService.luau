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

local SpawnService = {}
-- Saved position for a player's first spawn this session (feet, block units), set by Persistence
-- before it marks the player's data as loaded (player attribute "DataLoaded").
local firstSpawn: { [Player]: { pos: Vector3, yaw: number } } = {}

local function spawnCFrame(): CFrame
	local b = WorldService.getSpawnBlock()
	-- stand on top of the block below spawnBlock; HumanoidRootPart sits ~3 studs above the feet
	return CFrame.new((b.X + 0.5) * BS, b.Y * BS + 3.5, (b.Z + 0.5) * BS)
end

function SpawnService.setFirstSpawn(player: Player, pos: Vector3, yaw: number)
	firstSpawn[player] = { pos = pos, yaw = yaw }
	player:SetAttribute("SpawnBlock", Vector3.new(math.floor(pos.X), math.floor(pos.Y), math.floor(pos.Z)))
end

local function spawn(player: Player)
	if not player.Parent then
		return
	end
	local saved = firstSpawn[player]
	if saved then
		firstSpawn[player] = nil
		local p = saved.pos * BS
		AvatarService.spawn(player, CFrame.new(p.X, p.Y + 3.05, p.Z) * CFrame.Angles(0, saved.yaw, 0))
		return
	end
	AvatarService.spawn(player, spawnCFrame())
end

local function dataLoaded(player: Player): boolean
	return player:GetAttribute("DataLoaded") == true
end

-- Where a player respawns instead of the world spawn (BedService: their bed), or nil.
local resolver: ((Player) -> CFrame?)? = nil
function SpawnService.setRespawnResolver(fn: (Player) -> CFrame?)
	resolver = fn
end

-- Respawn: at the player's bed if it still works, else the world spawn.
function SpawnService.respawn(player: Player)
	local r = resolver
	local at = r and r(player)
	if at and player.Parent then
		local b = at.Position / BS
		player:SetAttribute("SpawnBlock", Vector3.new(math.floor(b.X), math.floor(b.Y), math.floor(b.Z)))
		AvatarService.spawn(player, at)
		return
	end
	spawn(player)
end

function SpawnService.init()
	Players.CharacterAutoLoads = false

	local function onPlayer(player: Player)
		player.DevEnableMouseLock = false -- our camera locks the mouse itself; no shift-lock toggle
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid") :: Humanoid
			AvatarService.configureHumanoid(humanoid)
			-- Death and respawn are handled by SurvivalService (death screen -> "respawn").
		end)
		task.spawn(function()
			-- the save must be loaded first; then wait for the client's collision
			while player.Parent and not dataLoaded(player) do
				task.wait(0.2)
			end
			task.wait(READY_TIMEOUT)
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
		if not player.Character and dataLoaded(player) then
			spawn(player)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		firstSpawn[player] = nil
	end)
end

return SpawnService
