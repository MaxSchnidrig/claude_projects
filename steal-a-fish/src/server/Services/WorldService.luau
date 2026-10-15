--!strict
--[[
	WorldService
	============
	Builds the static map from code when the server starts: the sand ground,
	the beach, the danger zone floors (one colored strip per zone), the glass
	walls around the danger zone, the entrance arch, and an invisible barrier
	that only bots bump into.

	Everything goes into Workspace.World. Plots are built separately, by
	PlotService.

	Bots are kept out of the safe areas in two ways:
	  1. BotService (Milestone 3) only lets them move inside the danger zone.
	  2. An invisible "BotBarrier" wall across the entrance. Thanks to
	     collision groups, players walk straight through it, but bots can't.

	Public interface:
		WorldService.GetFolder() -> Folder          -- Workspace.World
		WorldService.CollisionGroups.Bots           -- put bot parts in this group
]]

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Layout = require(ReplicatedStorage.Shared.Layout)
local Build = require(script.Parent.Parent.Util.Build)

local WorldService = {}
WorldService.Name = "WorldService"

WorldService.CollisionGroups = {
	Bots = "Bots",
	BotBarrier = "BotBarrier",
}

local worldFolder: Folder

function WorldService.GetFolder(): Folder
	return worldFolder
end

-- Bots collide with the barrier; players (the "Default" group) pass through.
local function setupCollisionGroups()
	local groups = WorldService.CollisionGroups
	for _, name in { groups.Bots, groups.BotBarrier } do
		if not PhysicsService:IsCollisionGroupRegistered(name) then
			PhysicsService:RegisterCollisionGroup(name)
		end
	end
	PhysicsService:CollisionGroupSetCollidable(groups.BotBarrier, "Default", false)
	PhysicsService:CollisionGroupSetCollidable(groups.BotBarrier, groups.Bots, true)
end

-- The "Baseplate" template comes with a SpawnLocation in the middle of the
-- map. Players spawn on their own plot instead, so remove any spawn that
-- isn't ours. (This only happens while the game runs; your saved place
-- file is not changed.)
local function removeTemplateSpawns()
	for _, item in Workspace:GetDescendants() do
		if item:IsA("SpawnLocation") and not item:IsDescendantOf(worldFolder) then
			item:Destroy()
		end
	end
end

local function buildGround()
	local world = Config.World
	local sideMargin = 20
	local backMargin = 20
	local nearZ = Config.Plots.Size.Z + backMargin -- behind the plots
	local farZ = Layout.DangerZoneFront -- the danger zone entrance
	local depth = nearZ - farZ
	Build.part({
		Name = "Ground",
		Size = Vector3.new(Layout.RowWidth + sideMargin * 2, 2, depth),
		CFrame = CFrame.new(0, Layout.GroundTop - 1, (nearZ + farZ) / 2),
		Color = world.GroundColor,
		Material = Enum.Material.Sand,
		Parent = worldFolder,
	})
end

local function buildDangerZones()
	local folder = Instance.new("Folder")
	folder.Name = "DangerZone"
	folder.Parent = worldFolder

	local width = Config.World.DangerZoneWidth

	for index, zone in Config.Zones do
		local cf, size = Layout.zoneCFrameAndSize(index)
		local floor = Build.part({
			Name = `Zone{index}_{zone.Name}`,
			Size = Vector3.new(size.X, 2, size.Z),
			CFrame = cf * CFrame.new(0, -1, 0),
			Color = zone.Color,
			Material = Enum.Material.Slate,
			Parent = folder,
		})
		floor:SetAttribute("ZoneIndex", index)

		-- A glowing line where this zone starts, plus a floating name label.
		local near = Layout.zoneZRange(index)
		local line = Build.part({
			Name = `Zone{index}_StartLine`,
			Size = Vector3.new(width, 0.2, 1),
			CFrame = CFrame.new(0, Layout.GroundTop + 0.1, near - 0.5),
			Color = zone.Color:Lerp(Color3.new(1, 1, 1), 0.5),
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanTouch = false,
			CanQuery = false,
			Parent = folder,
		})
		Build.billboard(line, `Zone {index}: {zone.Name}`, 14, 250)
	end

	-- Glass walls on the left, right and far end of the danger zone.
	local length = Layout.DangerZoneLength
	local wallH = Config.World.WallHeight
	local thickness = 4
	local front = Layout.DangerZoneFront
	local centerZ = front - length / 2
	local wallY = Layout.GroundTop + wallH / 2
	local glass = {
		Color = Color3.fromRGB(150, 220, 255),
		Material = Enum.Material.Glass,
		Transparency = 0.6,
	}
	for _, side in { -1, 1 } do
		Build.part({
			Name = if side < 0 then "WallLeft" else "WallRight",
			Size = Vector3.new(thickness, wallH, length),
			CFrame = CFrame.new(side * (width / 2 + thickness / 2), wallY, centerZ),
			Color = glass.Color,
			Material = glass.Material,
			Transparency = glass.Transparency,
			Parent = folder,
		})
	end
	Build.part({
		Name = "WallBack",
		Size = Vector3.new(width + thickness * 2, wallH, thickness),
		CFrame = CFrame.new(0, wallY, front - length - thickness / 2),
		Color = glass.Color,
		Material = glass.Material,
		Transparency = glass.Transparency,
		Parent = folder,
	})

	-- Entrance arch: two red neon posts and a sign across the top.
	local archHeight = 20
	for _, side in { -1, 1 } do
		Build.part({
			Name = "ArchPost",
			Size = Vector3.new(3, archHeight, 3),
			CFrame = CFrame.new(side * (width / 2 + 1.5), Layout.GroundTop + archHeight / 2, front),
			Color = Color3.fromRGB(255, 60, 60),
			Material = Enum.Material.Neon,
			Parent = folder,
		})
	end
	local beam = Build.part({
		Name = "ArchSign",
		Size = Vector3.new(width + 6, 5, 2),
		CFrame = CFrame.new(0, Layout.GroundTop + archHeight + 2.5, front),
		Color = Color3.fromRGB(40, 40, 60),
		Parent = folder,
	})
	-- "Back" is the side facing +Z: the beach and the plots.
	Build.surfaceText(beam, Enum.NormalId.Back, "⚠ DANGER ZONE ⚠  Steal eggs, dodge the sharks!", Color3.fromRGB(255, 90, 90))
	Build.surfaceText(beam, Enum.NormalId.Front, "EXIT → Run back to your plot!", Color3.fromRGB(120, 255, 140))

	-- Invisible wall across the entrance that only bots collide with. It sits
	-- just outside the zone, on the beach side.
	local barrier = Build.part({
		Name = "BotBarrier",
		Size = Vector3.new(width, 40, 2),
		CFrame = CFrame.new(0, Layout.GroundTop + 20, front + 1),
		Transparency = 1,
		CanTouch = false,
		CanQuery = false,
		Parent = folder,
	})
	barrier.CollisionGroup = WorldService.CollisionGroups.BotBarrier
end

function WorldService.Init()
	setupCollisionGroups()

	worldFolder = Instance.new("Folder")
	worldFolder.Name = "World"
	worldFolder.Parent = Workspace

	removeTemplateSpawns()
	buildGround()
	buildDangerZones()
end

function WorldService.Start()
end

return WorldService
