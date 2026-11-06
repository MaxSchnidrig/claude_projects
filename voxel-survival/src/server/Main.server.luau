--!strict
-- Server bootstrap: the ONLY server Script. Requires and starts each system in dependency order.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameInfo = require(Shared.GameInfo)
local Config = require(Shared.Config)
require(Shared.Net.Remotes) -- creates the RemoteEvents before anything listens
require(Shared.Util.AssetDiagnostics).init() -- reports where failing asset IDs come from

local WorldService = require(script.Parent.World.WorldService)
local ChunkStreamer = require(script.Parent.World.ChunkStreamer)
local SpawnService = require(script.Parent.Player.SpawnService)
local InventoryService = require(script.Parent.Player.InventoryService)
local BlockActionService = require(script.Parent.Interaction.BlockActionService)

print(`[{GameInfo.TITLE}] server {GameInfo.VERSION}`)

-- Phase 6 replaces this with the owning player's world seed (reserved-server worlds).
WorldService.init(Config.DEFAULT_SEED)
ChunkStreamer.init()
InventoryService.init()
BlockActionService.init()
SpawnService.init()
