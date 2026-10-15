--!strict
--[[
	PetService
	==========
	Hatches eggs on the hatch pad, rolls a random pet, places pets on
	the plot's pet slots, and handles selling pets.

	Built in: Milestone 4. For now this is an empty shell, so the start-up wiring can
	be tested.

	Planned public interface (other services will call these):
	PetService.StartHatch(player, rarity)
	PetService.GetIncomePerSecond(player) -> number
]]

local PetService = {}
PetService.Name = "PetService"

-- Called once at server start, before any service's Start().
-- Create state here. Don't call other services yet.
function PetService.Init()
end

-- Called once after every service has finished Init().
-- Connect events, start loops, and use other services here.
function PetService.Start()
end

return PetService
