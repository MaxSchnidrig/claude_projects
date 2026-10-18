--!strict
--[[
	Layout
	======
	Works out WHERE everything in the world is, using the numbers in Config.
	Both the server (to build and check positions) and the client (for things
	like a tutorial arrow) can use it, so they always agree.

	Coordinate system (seen from above):
	  - The plots sit in one row along the X axis. Their front edges are at Z = 0
	    and they extend toward +Z.
	  - The big open front area (safe) runs from Z = 0 to Z = -FrontAreaDepth.
	  - The danger zones start at Z = -FrontAreaDepth and go further toward -Z,
	    centered on X = 0. Zone 1 is the shallowest; the last zone is the deepest.
	  - One tall wall runs around all of it (see Layout.mapOutline).
	  - "Front" of a plot = the side facing the danger zone (-Z).

	This module only does math; it never creates parts.
]]

local Config = require(script.Parent.Config)

local Plots = Config.Plots
local World = Config.World

local Layout = {}

Layout.GroundTop = World.GroundTop
-- Plot floors are raised a tiny bit above the sand so they don't flicker.
Layout.PlotFloorTop = World.GroundTop + 0.2
Layout.RowWidth = Plots.Count * Plots.Size.X + (Plots.Count - 1) * Plots.Gap

-- Z position of the danger zone entrance line.
Layout.DangerZoneFront = -World.FrontAreaDepth

-- Total depth of all danger zones together.
local totalLength = 0
for _, zone in Config.Zones do
	totalLength += zone.Length
end
Layout.DangerZoneLength = totalLength
-- Z position of the far end of the deepest zone.
Layout.DangerZoneBack = Layout.DangerZoneFront - totalLength

-- Edges of the wide part of the map (plots + front area).
Layout.MapHalfWidth = Layout.RowWidth / 2 + World.MapSideMargin
Layout.MapBackZ = Plots.Size.Z + World.MapBackMargin

-- The inside edge of the map wall, as corner points (X, Z) going around the
-- map. The wall is built just outside this line. Seen from above, the shape
-- is a wide rectangle (plots + front area) with the narrower danger zone
-- sticking out of its front.
function Layout.mapOutline(): { Vector2 }
	local wide = Layout.MapHalfWidth
	local zone = World.DangerZoneWidth / 2
	local front = Layout.DangerZoneFront
	local back = Layout.DangerZoneBack
	return {
		Vector2.new(-wide, Layout.MapBackZ),
		Vector2.new(wide, Layout.MapBackZ),
		Vector2.new(wide, front),
		Vector2.new(zone, front),
		Vector2.new(zone, back),
		Vector2.new(-zone, back),
		Vector2.new(-zone, front),
		Vector2.new(-wide, front),
	}
end

-- The center of plot `index`'s floor top surface. Its LookVector points to
-- the front of the plot (toward the danger zone).
function Layout.plotCFrame(index: number): CFrame
	local x = -Layout.RowWidth / 2 + Plots.Size.X / 2 + (index - 1) * (Plots.Size.X + Plots.Gap)
	return CFrame.new(x, Layout.PlotFloorTop, Plots.Size.Z / 2)
end

-- Is `position` inside the given plot's safe area?
function Layout.isInsidePlot(index: number, position: Vector3): boolean
	local localPos = Layout.plotCFrame(index):PointToObjectSpace(position)
	local m = Plots.SafeMargin
	return math.abs(localPos.X) <= Plots.Size.X / 2 + m
		and math.abs(localPos.Z) <= Plots.Size.Z / 2 + m
		and localPos.Y > -10
		and localPos.Y < 100
end

-- Near and far Z edges of danger zone `index` (near > far, since zones go toward -Z).
function Layout.zoneZRange(index: number): (number, number)
	local near = Layout.DangerZoneFront
	for i = 1, index - 1 do
		near -= Config.Zones[i].Length
	end
	return near, near - Config.Zones[index].Length
end

-- Z of the line a zone's shark patrols along (near the zone's deep edge).
function Layout.patrolLineZ(index: number): number
	local _, far = Layout.zoneZRange(index)
	return far + Config.Bots.PatrolLineInset
end

-- Where a zone's eggs may spawn along Z: from the zone's halfway mark
-- (Config.Eggs.SpawnFromFraction) back to just before the shark's patrol line.
-- Returns (nearZ, farZ), nearZ > farZ.
function Layout.eggSpawnZRange(index: number): (number, number)
	local near, far = Layout.zoneZRange(index)
	local startZ = near - (near - far) * Config.Eggs.SpawnFromFraction
	local endZ = Layout.patrolLineZ(index) + Config.Eggs.SpawnLineGap
	return startZ, math.min(endZ, startZ)
end

-- Center (at ground-top height) and size of danger zone `index`.
function Layout.zoneCFrameAndSize(index: number): (CFrame, Vector3)
	local near, far = Layout.zoneZRange(index)
	local cf = CFrame.new(0, Layout.GroundTop, (near + far) / 2)
	return cf, Vector3.new(World.DangerZoneWidth, 0, near - far)
end

-- Which danger zone is `position` in? Returns 1, 2, 3, ... or nil if outside.
function Layout.zoneIndexAt(position: Vector3): number?
	if math.abs(position.X) > World.DangerZoneWidth / 2 then
		return nil
	end
	for index = 1, #Config.Zones do
		local near, far = Layout.zoneZRange(index)
		if position.Z <= near and position.Z >= far then
			return index
		end
	end
	return nil
end

function Layout.isInDangerZone(position: Vector3): boolean
	return Layout.zoneIndexAt(position) ~= nil
end

return Layout
