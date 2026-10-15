--!strict
--[[
	BotService
	==========
	Spawns the shark bots in the danger zone. They patrol, chase egg
	carriers with PathfindingService, and catch players they touch.

	Built in: Milestone 3. For now this is an empty shell, so the start-up wiring can
	be tested.

	Planned public interface (other services will call these):
	(none yet - BotService mostly calls other services)
]]

local BotService = {}
BotService.Name = "BotService"

-- Called once at server start, before any service's Start().
-- Create state here. Don't call other services yet.
function BotService.Init()
end

-- Called once after every service has finished Init().
-- Connect events, start loops, and use other services here.
function BotService.Start()
end

return BotService
