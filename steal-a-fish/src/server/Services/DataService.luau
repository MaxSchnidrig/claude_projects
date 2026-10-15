--!strict
--[[
	DataService
	===========
	Loads and saves each player's data (money, speed, upgrades, pets)
	using DataStoreService with session locking. Other services read and
	write player data through this service only.

	Built in: Milestone 6. For now this is an empty shell, so the start-up wiring can
	be tested.

	Planned public interface (other services will call these):
	DataService.GetData(player) -> PlayerData?   -- the live data table, or nil if not loaded
]]

local DataService = {}
DataService.Name = "DataService"

-- Called once at server start, before any service's Start().
-- Create state here. Don't call other services yet.
function DataService.Init()
end

-- Called once after every service has finished Init().
-- Connect events, start loops, and use other services here.
function DataService.Start()
end

return DataService
