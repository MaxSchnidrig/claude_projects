--!strict
--[[
	Constants
	=========
	Names that the server and client must agree on (tags and attributes).
	Not balancing numbers: those go in Config.
]]

return {
	Tags = {
		-- Every egg pickup ProximityPrompt has this CollectionService tag.
		EggPrompt = "EggPrompt",
		-- Every treadmill belt part has this tag (the client animates them).
		TreadmillBelt = "TreadmillBelt",
		-- Treadmill parts whose color cycles through the rainbow (client side).
		RainbowPart = "RainbowPart",
	},
	Attributes = {
		-- Set on the Player while they carry an egg. Value = the egg's rarity.
		CarryingEgg = "CarryingEgg",
		-- On the Player: their Speed stat (number).
		SpeedStat = "SpeedStat",
		-- On the Player: their current WalkSpeed (number), for the HUD.
		WalkSpeed = "WalkSpeed",
		-- On the Player: true while they train on their treadmill.
		Training = "Training",
		-- On a treadmill belt: true while someone trains on it (it animates).
		BeltActive = "BeltActive",
	},
}
