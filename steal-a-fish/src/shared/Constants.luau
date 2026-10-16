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
		-- Eggs on a pad that are counting down to hatch (client shows the timer).
		HatchingEgg = "HatchingEgg",
		-- Pet models on pads (the client makes them bob gently).
		PetModel = "PetModel",
		-- Upgrade/Sell prompts on pets (the client hides other players' prompts).
		PetPrompt = "PetPrompt",
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
		-- On a hatching egg: the server time (workspace:GetServerTimeNow()) it hatches at.
		HatchEndsAt = "HatchEndsAt",
		-- On the Player: money they hold (number).
		Money = "Money",
		-- On the Player: total pet income per second (number).
		Income = "Income",
		-- On the Player: how many pads are unlocked on their plot.
		PadsUnlocked = "PadsUnlocked",
		-- On the Player: their treadmill tier (index into Config.Treadmill.Tiers).
		TreadmillTier = "TreadmillTier",
		-- On a pet prompt: the UserId of the pet's owner.
		OwnerUserId = "OwnerUserId",
	},
}
