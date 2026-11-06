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
	-- Phase 6 replaces the default seed with the owning player's world seed (reserved servers).
	{ name = "WorldService", run = function()
		require(server.World.WorldService).init(Config.DEFAULT_SEED)
	end },
	{ name = "ChunkStreamer", run = function()
		require(server.World.ChunkStreamer).init()
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
})
