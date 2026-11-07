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

local server = script.Parent
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
	-- Phase 6 replaces the default seed with the owning player's world seed (reserved servers).
	{ name = "WorldService", run = function()
		require(server.World.WorldService).init(Config.DEFAULT_SEED)
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
		require(server.Survival.DayNightService).init()
	end },
	{ name = "SurvivalService", run = function()
		require(server.Survival.SurvivalService).init()
	end },
	{ name = "MobService", run = function()
		require(server.Mobs.MobService).init()
	end },
})
