--!strict
-- Server bootstrap: the ONLY server Script. Starts each system in dependency order; each step is
-- isolated (Util/Startup), so a failure is reported in Output and the rest still start.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameInfo = require(Shared.GameInfo)
local Config = require(Shared.Config)
local Startup = require(Shared.Util.Startup)
require(Shared.Net.Remotes) -- creates the RemoteEvents before anything listens

print(`[{GameInfo.TITLE}] server {GameInfo.VERSION}`)

-- Characters are spawned by SpawnService once the player's save and terrain are ready.
game:GetService("Players").CharacterAutoLoads = false

local server = script.Parent
local Persistence = require(server.Persistence.Persistence)

-- Lobby or world? (A reserved server looks up its owner; Studio waits for the first player.)
local mode = Persistence.resolve()
ReplicatedStorage:SetAttribute("ServerMode", mode)
if mode == "lobby" then
	Startup.run("server", {
		{ name = "LobbyService", run = function()
			require(server.Lobby.LobbyService).init()
		end },
	})
	return
end

local meta = Persistence.loadWorld()
Startup.run("server", {
	{ name = "AssetDiagnostics", run = function()
		require(Shared.Util.AssetDiagnostics).init()
	end },
	{ name = "Physics", run = function()
		workspace.Gravity = Config.GRAVITY -- Java: 32 blocks/s^2
		-- sneaking moves the visual body parts into a group that doesn't collide (SneakPose)
		local PhysicsService = game:GetService("PhysicsService")
		local SneakPose = require(Shared.Gameplay.SneakPose)
		PhysicsService:RegisterCollisionGroup(SneakPose.GHOST_GROUP)
		PhysicsService:CollisionGroupSetCollidable(SneakPose.GHOST_GROUP, "Default", false)
		PhysicsService:CollisionGroupSetCollidable(SneakPose.GHOST_GROUP, SneakPose.GHOST_GROUP, false)
	end },
	{ name = "WorldService", run = function()
		local WorldService = require(server.World.WorldService)
		Persistence.attachWorld(WorldService, require(server.World.BlockEntityService))
		WorldService.init(meta.seed)
	end },
	{ name = "ChunkStreamer", run = function()
		require(server.World.ChunkStreamer).init()
	end },
	{ name = "ItemEntityService", run = function()
		require(server.World.ItemEntityService).init()
	end },
	{ name = "BlockEntityService", run = function()
		require(server.World.BlockEntityService).init()
	end },
	{ name = "InventoryService", run = function()
		require(server.Player.InventoryService).init()
	end },
	{ name = "BlockActionService", run = function()
		require(server.Interaction.BlockActionService).init()
	end },
	{ name = "SpawnService", run = function()
		require(server.Player.SpawnService).init()
	end },
	{ name = "DayNightService", run = function()
		require(server.Survival.DayNightService).init(meta.ticks)
	end },
	{ name = "SurvivalService", run = function()
		require(server.Survival.SurvivalService).init()
	end },
	{ name = "MobService", run = function()
		require(server.Mobs.MobService).init()
	end },
	{ name = "Persistence", run = function()
		Persistence.startWorld({
			InventoryService = require(server.Player.InventoryService),
			SurvivalService = require(server.Survival.SurvivalService),
			SpawnService = require(server.Player.SpawnService),
			DayNightService = require(server.Survival.DayNightService),
		})
	end },
})
