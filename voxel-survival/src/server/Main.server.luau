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
	-- Studio: the title screen opens the chosen world right here (no teleporting in Studio)
	local inPlace = game:GetService("RunService"):IsStudio()
	local chosen = Instance.new("BindableEvent")
	Startup.run("server", {
		{ name = "SettingsService", run = function()
			local SettingsService = require(server.Player.SettingsService) :: any
			SettingsService.started = true
			SettingsService.init()
		end },
		{ name = "LobbyService", run = function()
			require(server.Lobby.LobbyService).init(if inPlace
				then function(_p: Player, owner: number, world: string)
					Persistence.useWorld(owner, world)
					chosen:Fire()
				end
				else nil)
		end },
	})
	if not inPlace then
		return
	end
	chosen.Event:Wait()
	require(server.Lobby.LobbyService).close()
	ReplicatedStorage:SetAttribute("ServerMode", "world")
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
	{ name = "ExperienceService", run = function()
		require(server.Player.ExperienceService).init()
	end },
	{ name = "SettingsService", run = function()
		local SettingsService = require(server.Player.SettingsService) :: any
		if not SettingsService.started then
			SettingsService.started = true
			SettingsService.init()
		end
	end },
	{ name = "WorldSettingsService", run = function()
		require(server.World.WorldSettingsService).init()
	end },
	{ name = "InventoryService", run = function()
		require(server.Player.InventoryService).init()
	end },
	{ name = "HandActionService", run = function()
		require(server.Player.HandActionService).init()
	end },
	{ name = "FishingService", run = function()
		require(server.Simulation.FishingService).init()
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
	-- world simulation: block ticks, fluids, falling blocks / TNT, fire, campfires, item use
	{ name = "BlockUpdates", run = function()
		require(server.World.BlockUpdates).init()
	end },
	{ name = "RandomTicks", run = function()
		require(server.World.RandomTicks).init()
	end },
	{ name = "FarmingService", run = function()
		require(server.Simulation.FarmingService).init()
	end },
	{ name = "FluidService", run = function()
		require(server.Simulation.FluidService).init()
	end },
	{ name = "EntityService", run = function()
		require(server.Simulation.EntityService).init()
	end },
	{ name = "FireService", run = function()
		require(server.Simulation.FireService).init()
	end },
	{ name = "WeatherService", run = function()
		local WeatherService = require(server.World.WeatherService)
		local SurvivalService = require(server.Survival.SurvivalService)
		local MobService = require(server.Mobs.MobService)
		local FireService = require(server.Simulation.FireService)
		local ItemEntityService = require(server.World.ItemEntityService)
		local WorldSettingsService = require(server.World.WorldSettingsService)
		local BS = (require(game:GetService("ReplicatedStorage").Shared.Config) :: any).BLOCK_SIZE
		local function playerFeet(p: Player): Vector3?
			local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			return if root then (root.Position - Vector3.new(0, 3, 0)) / BS else nil
		end
		WeatherService.load(meta.weather)
		WeatherService.init({
			nearChunks = require(server.World.RandomTicks).nearChunks,
			ignite = FireService.ignite,
			difficulty = WorldSettingsService.difficulty,
			hurtPlayers = function(lo: Vector3, hi: Vector3)
				for _, p in game:GetService("Players"):GetPlayers() do
					local f = playerFeet(p)
					if f and f.X >= lo.X and f.X <= hi.X and f.Y >= lo.Y and f.Y <= hi.Y and f.Z >= lo.Z and f.Z <= hi.Z then
						SurvivalService.lightning(p)
					end
				end
			end,
			hurtMobs = function(lo: Vector3, hi: Vector3)
				MobService.lightningIn(lo, hi)
				ItemEntityService.removeIn(lo, hi)
			end,
			targets = function(x: number, z: number, y0: number): { Vector3 }
				local list = MobService.lightningTargets(x, z, y0, WeatherService.topAt)
				for _, p in game:GetService("Players"):GetPlayers() do
					local f = playerFeet(p)
					if f and p:GetAttribute("Spectator") ~= true and math.abs(f.X - (x + 0.5)) <= 3.5
						and math.abs(f.Z - (z + 0.5)) <= 3.5 and f.Y >= y0 - 3
					then
						local top = WeatherService.topAt(math.floor(f.X), math.floor(f.Z))
						if top and top < f.Y + 0.01 then
							table.insert(list, f)
						end
					end
				end
				return list
			end,
		})
	end },
	{ name = "CampfireService", run = function()
		require(server.Simulation.CampfireService).init()
	end },
	{ name = "ItemUseService", run = function()
		require(server.Simulation.ItemUseService).init()
	end },
	{ name = "DecorService", run = function()
		require(server.Simulation.DecorService).init()
	end },
	{ name = "CombatGearService", run = function()
		require(server.Player.CombatGearService).init()
	end },
	{ name = "BedService", run = function()
		require(server.Player.BedService).init()
	end },
	{ name = "MenuService", run = function()
		require(server.Player.MenuService).init()
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
