--!strict
--[[
	WorldService
	============
	Builds the static map from code when the server starts:
	  - the sand ground under the plots and the big open front area
	  - the danger zone floors (one colored strip per zone) with name labels
	  - ONE tall checkered wall around the whole map (plots, front area and
	    danger zones), so players can never leave or see the edge
	  - an ocean outside the wall
	  - the entrance arch, and an invisible barrier that only bots bump into

	Everything goes into Workspace.World. Positions all come from Layout, so
	changing Config (for example World.FrontAreaDepth) moves everything
	together. Plots are built separately, by PlotService.

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
	local thickness = world.MapWallThickness
	-- The ground reaches under the wall, so there are no gaps at the edges.
	local halfWidth = Layout.MapHalfWidth + thickness
	local nearZ = Layout.MapBackZ + thickness
	local farZ = Layout.DangerZoneFront
	Build.part({
		Name = "Ground",
		Size = Vector3.new(halfWidth * 2, 2, nearZ - farZ),
		CFrame = CFrame.new(0, Layout.GroundTop - 1, (nearZ + farZ) / 2),
		Color = world.GroundColor,
		Material = Enum.Material.Sand,
		StudFaces = { Enum.NormalId.Top },
		Parent = worldFolder,
	})

	-- Ocean outside the walls, so zooming out never shows an empty void.
	-- Its top sits just below the ground, so the two never flicker.
	Build.part({
		Name = "Ocean",
		Size = Vector3.new(4000, 1, 4000),
		CFrame = CFrame.new(0, Layout.GroundTop - 1, Layout.DangerZoneFront),
		Color = world.OceanColor,
		Material = Enum.Material.SmoothPlastic,
		Studs = false,
		CanTouch = false,
		Parent = worldFolder,
	})
end

local function buildDangerZones(): Folder
	local folder = Instance.new("Folder")
	folder.Name = "DangerZone"
	folder.Parent = worldFolder

	local width = Config.World.DangerZoneWidth
	local thickness = Config.World.MapWallThickness

	for index, zone in Config.Zones do
		local cf, size = Layout.zoneCFrameAndSize(index)
		local floor = Build.part({
			Name = `Zone{index}_{zone.Name}`,
			-- A bit wider than the zone so the floor reaches under the walls.
			Size = Vector3.new(size.X + thickness * 2, 2, size.Z),
			CFrame = cf * CFrame.new(0, -1, 0),
			Color = zone.Color,
			Material = Enum.Material.Slate,
			StudFaces = { Enum.NormalId.Top },
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

	-- Entrance arch: two red neon posts and a sign across the top, set into
	-- the map wall where the danger zone starts.
	local front = Layout.DangerZoneFront
	local archHeight = 24
	for _, side in { -1, 1 } do
		Build.part({
			Name = "ArchPost",
			Size = Vector3.new(3, archHeight, 3),
			CFrame = CFrame.new(side * (width / 2 - 1.5), Layout.GroundTop + archHeight / 2, front),
			Color = Color3.fromRGB(255, 60, 60),
			Material = Enum.Material.Neon,
			Parent = folder,
		})
	end
	local beam = Build.part({
		Name = "ArchSign",
		Size = Vector3.new(width, 5, 2),
		CFrame = CFrame.new(0, Layout.GroundTop + archHeight + 2.5, front),
		Color = Color3.fromRGB(40, 40, 60),
		Studs = false, -- keep the text easy to read
		Parent = folder,
	})
	-- "Back" is the side facing +Z: the front area and the plots.
	Build.surfaceText(beam, Enum.NormalId.Back, "⚠ DANGER ZONE ⚠  Steal eggs, dodge the sharks!", Color3.fromRGB(255, 90, 90))
	Build.surfaceText(beam, Enum.NormalId.Front, "EXIT → Run back to your plot!", Color3.fromRGB(120, 255, 140))

	-- Invisible wall across the entrance that only bots collide with. It sits
	-- just outside the zone, on the front-area side.
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

	return folder
end

---------------------------------------------------------------------------
-- Map wall
---------------------------------------------------------------------------

-- One straight piece of the map wall, from `startPoint` to `endPoint` (X, Z),
-- built on the `outward` side of that line. Its inside face gets a
-- checkerboard of two colors, and a trim runs along the top.
local function buildWallSegment(parent: Instance, name: string, startPoint: Vector2, endPoint: Vector2, outward: Vector2)
	local world = Config.World
	local height = world.MapWallHeight
	local thickness = world.MapWallThickness
	local tile = world.WallTileSize
	local sunk = 1 -- the wall starts 1 stud below the ground so there's no gap

	local length = (endPoint - startPoint).Magnitude
	local middle = (startPoint + endPoint) / 2
	local center = Vector3.new(
		middle.X + outward.X * thickness / 2,
		Layout.GroundTop - sunk + (height + sunk) / 2,
		middle.Y + outward.Y * thickness / 2
	)
	-- Point the part's Front face inward (toward the players).
	local inward = Vector3.new(-outward.X, 0, -outward.Y)
	local cf = CFrame.lookAt(center, center + inward)

	local wall = Build.part({
		Name = name,
		Size = Vector3.new(length, height + sunk, thickness),
		CFrame = cf,
		Color = world.WallColorA,
		StudFaces = { Enum.NormalId.Front },
		Parent = parent,
	})

	-- Checkerboard: thin colored squares on the inside face, every other cell.
	local columns = math.ceil(length / tile)
	local rows = math.ceil(height / tile)
	local bottomY = -wall.Size.Y / 2 + sunk -- local Y of the ground line
	for column = 0, columns - 1 do
		local left = -length / 2 + column * tile
		local w = math.min(tile, length / 2 - left)
		for row = 0, rows - 1 do
			if (column + row) % 2 == 1 then
				local bottom = bottomY + row * tile
				local h = math.min(tile, height - row * tile)
				Build.part({
					Name = "WallTile",
					Size = Vector3.new(w, h, 0.2),
					CFrame = cf * CFrame.new(left + w / 2, bottom + h / 2, -thickness / 2 - 0.1),
					Color = world.WallColorB,
					StudFaces = { Enum.NormalId.Front },
					CanQuery = false,
					Parent = wall,
				})
			end
		end
	end

	-- Trim along the top, sticking out a little on the inside.
	Build.part({
		Name = "WallTrim",
		Size = Vector3.new(length, 2, thickness + 1),
		CFrame = cf * CFrame.new(0, wall.Size.Y / 2 + 1, -0.5),
		Color = world.WallTrimColor,
		StudFaces = { Enum.NormalId.Top, Enum.NormalId.Front },
		Parent = wall,
	})
end

-- Walk around Layout.mapOutline() and build a wall piece for every side.
local function buildMapWall()
	local folder = Instance.new("Folder")
	folder.Name = "MapWall"
	folder.Parent = worldFolder

	local thickness = Config.World.MapWallThickness
	local points = Layout.mapOutline()
	local count = #points

	-- Turning direction at a corner: negative = outer corner, positive = inner corner.
	local function turn(a: Vector2, b: Vector2, c: Vector2): number
		local d1 = (b - a).Unit
		local d2 = (c - b).Unit
		return d1.X * d2.Y - d1.Y * d2.X
	end

	for i = 1, count do
		local previous = points[(i - 2) % count + 1]
		local a = points[i]
		local b = points[i % count + 1]
		local nextPoint = points[(i + 1) % count + 1]

		local direction = (b - a).Unit
		local outward = Vector2.new(-direction.Y, direction.X)

		local startPoint = a
		local endPoint = b
		-- Inner corner at the start: shorten, so this piece doesn't overlap the previous one.
		if turn(previous, a, b) > 0 then
			startPoint += direction * thickness
		end
		-- Outer corner at the end: lengthen, to fill the corner.
		if turn(a, b, nextPoint) < 0 then
			endPoint += direction * thickness
		end

		buildWallSegment(folder, `Wall{i}`, startPoint, endPoint, outward)
	end
end

function WorldService.Init()
	setupCollisionGroups()

	worldFolder = Instance.new("Folder")
	worldFolder.Name = "World"
	worldFolder.Parent = Workspace

	removeTemplateSpawns()
	buildGround()
	buildDangerZones()
	buildMapWall()
end

function WorldService.Start()
end

return WorldService
