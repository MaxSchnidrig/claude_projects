--!strict
--[[
	UpgradeService
	==============
	Handles buying upgrades (pet slots, treadmill, pet levels): checks
	the price, takes the money, applies the upgrade. Also trains the Speed
	stat on the treadmill.

	Built in: Milestone 5. For now this is an empty shell, so the start-up wiring can
	be tested.

	Planned public interface (other services will call these):
	UpgradeService.GetLevel(player, upgradeName) -> number
]]

local UpgradeService = {}
UpgradeService.Name = "UpgradeService"

-- Called once at server start, before any service's Start().
-- Create state here. Don't call other services yet.
function UpgradeService.Init()
end

-- Called once after every service has finished Init().
-- Connect events, start loops, and use other services here.
function UpgradeService.Start()
end

return UpgradeService
