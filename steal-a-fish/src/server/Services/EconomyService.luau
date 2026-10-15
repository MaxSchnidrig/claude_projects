--!strict
--[[
	EconomyService
	==============
	Owns money. Adds pet income every tick, handles collecting money
	from the plot, and is the ONLY place money is added or removed.

	Built in: Milestones 4-5. For now this is an empty shell, so the start-up wiring can
	be tested.

	Planned public interface (other services will call these):
	EconomyService.GetMoney(player) -> number
	EconomyService.AddMoney(player, amount)
	EconomyService.TrySpend(player, amount) -> boolean   -- false if they can't afford it
]]

local EconomyService = {}
EconomyService.Name = "EconomyService"

-- Called once at server start, before any service's Start().
-- Create state here. Don't call other services yet.
function EconomyService.Init()
end

-- Called once after every service has finished Init().
-- Connect events, start loops, and use other services here.
function EconomyService.Start()
end

return EconomyService
