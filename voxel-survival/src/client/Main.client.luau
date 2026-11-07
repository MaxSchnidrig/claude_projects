--!strict
-- Client bootstrap: the ONLY client LocalScript. Starts each system in order; each step is
-- isolated (Util/Startup), so one failing system is reported (Output + red on-screen list) and
-- the rest still start.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameInfo = require(Shared.GameInfo)
local Startup = require(Shared.Util.Startup)

print(`[{GameInfo.TITLE}] client {GameInfo.VERSION}`)

local client = script.Parent
local function system(name: string, path: () -> Instance)
	return {
		name = name,
		run = function()
			(require(path() :: ModuleScript) :: any).init()
		end,
	}
end

Startup.run("client", {
	system("AssetDiagnostics", function()
		return Shared.Util.AssetDiagnostics
	end),
	system("CoreGuiSetup", function()
		return client.UI.CoreGuiSetup
	end),
	system("SurvivalClient", function()
		return client.Survival.SurvivalClient
	end),
	system("DayNightClient", function()
		return client.Survival.DayNightClient
	end),
	system("SurvivalHUD", function()
		return client.Survival.SurvivalHUD
	end),
	-- UI and input first: they don't need the world, and must appear even if the world is slow.
	system("InventoryClient", function()
		return client.Player.InventoryClient
	end),
	system("Hotbar", function()
		return client.UI.Hotbar
	end),
	system("Crosshair", function()
		return client.UI.Crosshair
	end),
	system("InventoryUI", function()
		return client.UI.InventoryUI
	end),
	system("MovementController", function()
		return client.Player.MovementController
	end),
	system("CameraController", function()
		return client.Player.CameraController
	end),
	-- ClientWorld.init waits for the server's world seed.
	system("ClientWorld", function()
		return client.World.ClientWorld
	end),
	system("BlockInteraction", function()
		return client.Interaction.BlockInteraction
	end),
	system("ItemEntityVisuals", function()
		return client.World.ItemEntityVisuals
	end),
	system("DebugOverlay", function()
		return client.Debug.DebugOverlay
	end),
})
