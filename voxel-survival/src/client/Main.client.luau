--!strict
-- Client bootstrap: the ONLY client LocalScript. Requires and starts each system in order.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameInfo = require(Shared.GameInfo)

local ClientWorld = require(script.Parent.World.ClientWorld)
local InventoryClient = require(script.Parent.Player.InventoryClient)
local MovementController = require(script.Parent.Player.MovementController)
local CameraController = require(script.Parent.Player.CameraController)
local BlockInteraction = require(script.Parent.Interaction.BlockInteraction)
local Hotbar = require(script.Parent.UI.Hotbar)
local Crosshair = require(script.Parent.UI.Crosshair)
local DebugOverlay = require(script.Parent.Debug.DebugOverlay)

print(`[{GameInfo.TITLE}] client {GameInfo.VERSION}`)

ClientWorld.init()
InventoryClient.init()
MovementController.init()
CameraController.init()
BlockInteraction.init()
Hotbar.init()
Crosshair.init()
DebugOverlay.init()
