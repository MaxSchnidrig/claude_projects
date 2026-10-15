--!strict
--[[
	EggService
	==========
	Spawns eggs in the danger zones, handles picking them up, carrying,
	dropping (when caught or killed), and delivering them to the hatch pad.

	Built in: Milestone 2. For now this is an empty shell, so the start-up wiring can
	be tested.

	Planned public interface (other services will call these):
	EggService.IsCarrying(player) -> boolean
	EggService.DropEgg(player)   -- called by BotService when a player is caught
]]

local EggService = {}
EggService.Name = "EggService"

-- Called once at server start, before any service's Start().
-- Create state here. Don't call other services yet.
function EggService.Init()
end

-- Called once after every service has finished Init().
-- Connect events, start loops, and use other services here.
function EggService.Start()
end

return EggService
