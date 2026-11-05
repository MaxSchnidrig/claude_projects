--!strict
-- Client bootstrap: the ONLY client LocalScript. Requires and starts each system in order.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameInfo = require(Shared.GameInfo)

local ClientWorld = require(script.Parent.World.ClientWorld)
local DebugOverlay = require(script.Parent.Debug.DebugOverlay)

print(`[{GameInfo.TITLE}] client {GameInfo.VERSION}`)

ClientWorld.init()
DebugOverlay.init()
