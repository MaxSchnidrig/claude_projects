--!strict
--[[
	PlotService
	===========
	Builds the 8 plots, gives each joining player a free plot, frees it
	when they leave, and spawns players on their own plot.

	Built in: Milestone 1. For now this is an empty shell, so the start-up wiring can
	be tested.

	Planned public interface (other services will call these):
	PlotService.GetPlot(player) -> Model?          -- the player's plot
	PlotService.IsInsideAnyPlot(position) -> boolean -- used to keep bots out
]]

local PlotService = {}
PlotService.Name = "PlotService"

-- Called once at server start, before any service's Start().
-- Create state here. Don't call other services yet.
function PlotService.Init()
end

-- Called once after every service has finished Init().
-- Connect events, start loops, and use other services here.
function PlotService.Start()
end

return PlotService
