--!strict
-- Client bootstrap: the ONLY client LocalScript. Requires and starts each system in order.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameInfo = require(Shared.GameInfo)
require(Shared.Util.AssetDiagnostics).init() -- reports where failing asset IDs come from

local ClientWorld = require(script.Parent.World.ClientWorld)
local InventoryClient = require(script.Parent.Player.InventoryClient)
local MovementController = require(script.Parent.Player.MovementController)
local CameraController = require(script.Parent.Player.CameraController)
local BlockInteraction = require(script.Parent.Interaction.BlockInteraction)
local Hotbar = require(script.Parent.UI.Hotbar)
local Crosshair = require(script.Parent.UI.Crosshair)
local DebugOverlay = require(script.Parent.Debug.DebugOverlay)
local CoreGuiSetup = require(script.Parent.UI.CoreGuiSetup)

print(`[{GameInfo.TITLE}] client {GameInfo.VERSION}`)

CoreGuiSetup.init()
ClientWorld.init()
InventoryClient.init()
MovementController.init()
CameraController.init()
BlockInteraction.init()
Hotbar.init()
Crosshair.init()
DebugOverlay.init()
