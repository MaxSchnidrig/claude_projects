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

-- The server decides whether this is a lobby or a world (ReplicatedStorage "ServerMode").
local mode = ReplicatedStorage:GetAttribute("ServerMode")
while mode == nil do
	ReplicatedStorage:GetAttributeChangedSignal("ServerMode"):Wait()
	mode = ReplicatedStorage:GetAttribute("ServerMode")
end
if mode == "lobby" then
	Startup.run("client", {
		system("CoreGuiSetup", function()
			return client.UI.CoreGuiSetup
		end),
		system("LobbyUI", function()
			return client.Lobby.LobbyUI
		end),
	})
	return
end

Startup.run("client", {
	system("AssetDiagnostics", function()
		return Shared.Util.AssetDiagnostics
	end),
	-- textures first: terrain meshes, icons and the hand all use the atlas
	system("TextureAtlas", function()
		return client.Render.TextureAtlas
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
	system("MobClient", function()
		return client.Mobs.MobClient
	end),
	{
		name = "Effects",
		run = function()
			local BlockInteraction = require(client.Interaction.BlockInteraction) :: any
			local ClientWorld = require(client.World.ClientWorld) :: any
			local Particles = require(client.Render.Particles) :: any
			Particles.init(ClientWorld.getBlock)
			BlockInteraction.broken.Event:Connect(function(x, y, z, id)
				Particles.breakBlock(x, y, z, id)
			end)
			BlockInteraction.digging.Event:Connect(function(x, y, z, id)
				local hit = BlockInteraction.target
				local n = if hit then Vector3.new(hit.nx, hit.ny, hit.nz) else Vector3.yAxis
				Particles.dig(x, y, z, id, n)
			end)
			require(client.Player.ViewModel).init(BlockInteraction.swing)
			require(client.World.Clouds).init()
			local BlockRegistry = require(Shared.Blocks.BlockRegistry) :: any
			require(client.Survival.DayNightClient).setBlockSource(ClientWorld.getBlock, BlockRegistry.isOpaque)
		end,
	},
	{
		name = "AudioClient",
		run = function()
			require(client.Audio.AudioClient).init({
				BlockInteraction = require(client.Interaction.BlockInteraction),
				ClientWorld = require(client.World.ClientWorld),
				MovementController = require(client.Player.MovementController),
				InventoryClient = require(client.Player.InventoryClient),
				MobClient = require(client.Mobs.MobClient),
			})
		end,
	},
	system("DebugOverlay", function()
		return client.Debug.DebugOverlay
	end),
})
