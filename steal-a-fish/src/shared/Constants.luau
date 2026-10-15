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
	},
	Attributes = {
		-- Set on the Player while they carry an egg. Value = the egg's rarity.
		CarryingEgg = "CarryingEgg",
	},
}
