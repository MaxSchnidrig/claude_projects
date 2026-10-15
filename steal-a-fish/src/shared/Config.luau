--!strict
--[[
	Config
	======
	EVERY balancing number in the game lives here. Change values in this file to
	tweak the game; you should never need to touch the logic to rebalance.

	Lives in: ReplicatedStorage.Shared.Config
	Used by:  both the server (to run the game) and the client (to show prices,
	          odds, etc. in the UI). Never put secrets here - players can read it.

	Units:
	  - distances are in studs (1 stud ~ 28 cm; a default character is ~5 studs tall)
	  - times are in seconds
	  - speeds are in studs per second (default Roblox WalkSpeed is 16)
	  - money values are plain numbers

	Sections are filled in milestone by milestone. A section can already exist
	before the code that uses it is written.
]]

-- Type shapes for the tables below. They let the editor catch typos and wrong
-- values. `{ [string]: number }` means "rarity name -> weight".
export type Weights = { [string]: number }

export type ZoneConfig = {
	Name: string,
	Length: number,
	Color: Color3,
	MaxEggs: number,
	EggWeights: Weights,
	BotCount: number,
	BotSpeed: number,
}

export type PetConfig = {
	Name: string,
	Rarity: string,
	Income: number,
}

local Config = {}

---------------------------------------------------------------------------
-- GENERAL
---------------------------------------------------------------------------
Config.GameName = "Steal A Fish"

-- Print extra debug messages to the Output window.
Config.Debug = true

---------------------------------------------------------------------------
-- RARITIES
-- Ordered from most common to rarest. The order matters: "deeper" zones and
-- "upgrade one tier" logic use this list's order.
---------------------------------------------------------------------------
Config.Rarities = {
	{ Name = "Common", Color = Color3.fromRGB(200, 200, 200) },
	{ Name = "Uncommon", Color = Color3.fromRGB(85, 220, 110) },
	{ Name = "Rare", Color = Color3.fromRGB(60, 140, 255) },
	{ Name = "Epic", Color = Color3.fromRGB(170, 80, 255) },
	{ Name = "Legendary", Color = Color3.fromRGB(255, 180, 40) },
	{ Name = "Mythic", Color = Color3.fromRGB(255, 60, 120) },
}

---------------------------------------------------------------------------
-- PLAYER
---------------------------------------------------------------------------
Config.Player = {
	BaseWalkSpeed = 16, -- Roblox default
	MaxWalkSpeed = 50, -- hard cap, no matter how high the Speed stat gets
	WalkSpeedPerSpeedPoint = 0.05, -- WalkSpeed = Base + SpeedStat * this (then capped)
}

---------------------------------------------------------------------------
-- PLOTS (Milestone 1)
---------------------------------------------------------------------------
Config.Plots = {
	Count = 8, -- maximum players per server should be <= this
	Size = Vector3.new(60, 1, 80), -- width (X), thickness (Y), depth (Z) of one plot
	Gap = 8, -- empty space between two plots
	StartingPetSlots = 4, -- pedestals unlocked on a brand new plot
	MaxPetSlots = 12, -- most pedestals a plot can ever have
	SafeMargin = 3, -- the safe area reaches this many studs past the plot's edges
	-- One floor color per plot (Plot 1 gets the first color, and so on).
	Colors = {
		Color3.fromRGB(110, 190, 255),
		Color3.fromRGB(255, 150, 110),
		Color3.fromRGB(140, 230, 140),
		Color3.fromRGB(230, 140, 230),
		Color3.fromRGB(255, 220, 110),
		Color3.fromRGB(120, 230, 220),
		Color3.fromRGB(200, 170, 255),
		Color3.fromRGB(255, 130, 160),
	},
}

---------------------------------------------------------------------------
-- WORLD LAYOUT (Milestone 1)
-- Seen from above:
--
--        [ danger zones: Shallows -> Coral Reef -> ... ]   (toward -Z)
--                    [ entrance arch ]
--   ~~~~~~~~~~~~~~~~~~~~ beach (safe) ~~~~~~~~~~~~~~~~~~~~~
--   [P1][P2][P3][P4]                      [P5][P6][P7][P8]   (plots, toward +Z)
---------------------------------------------------------------------------
Config.World = {
	GroundTop = 1, -- height (Y) of the walkable ground surface
	BeachDepth = 30, -- depth of the safe strip between the plots and the danger zone
	DangerZoneWidth = 160, -- width of the danger zone (and its entrance)
	WallHeight = 16, -- glass walls around the danger zone (players jump ~7 studs)
	GroundColor = Color3.fromRGB(235, 215, 160), -- sand
}

---------------------------------------------------------------------------
-- EGGS (Milestone 2)
-- Per rarity: how long it takes to hatch and how much it slows the carrier.
-- CarrySpeedMultiplier 0.9 = player walks at 90% speed while holding it.
---------------------------------------------------------------------------
Config.Eggs = {
	PickupHoldDuration = 0.4, -- seconds to hold the ProximityPrompt key
	PickupMaxDistance = 10, -- studs; the server re-checks this
	RespawnInterval = 4, -- seconds between egg spawn attempts in each zone

	-- What happens to a carried egg when the carrier is caught or dies:
	--   "Drop" = the egg falls on the ground where they were and can be picked up again
	--   "Lose" = the egg disappears
	OnCaught = "Drop",
	DroppedEggLifetime = 20, -- seconds a dropped egg stays before vanishing

	ByRarity = {
		Common = { HatchTime = 10, CarrySpeedMultiplier = 1.0 },
		Uncommon = { HatchTime = 20, CarrySpeedMultiplier = 0.95 },
		Rare = { HatchTime = 40, CarrySpeedMultiplier = 0.9 },
		Epic = { HatchTime = 75, CarrySpeedMultiplier = 0.85 },
		Legendary = { HatchTime = 120, CarrySpeedMultiplier = 0.8 },
		Mythic = { HatchTime = 180, CarrySpeedMultiplier = 0.75 },
	},
}

---------------------------------------------------------------------------
-- DANGER ZONES (Milestones 2 + 3)
-- Listed from the entrance (shallowest) to the deepest. Each zone is a strip
-- of the danger area. Deeper zones: rarer eggs, more and faster bots.
-- EggWeights are relative weights, not percents: {Common = 3, Rare = 1}
-- means Common is 3x as likely as Rare (75% vs 25%).
---------------------------------------------------------------------------
local zones: { ZoneConfig } = {
	{
		Name = "Shallows",
		Length = 120, -- how deep (Z direction) this zone strip is
		Color = Color3.fromRGB(90, 200, 230),
		MaxEggs = 8,
		EggWeights = { Common = 70, Uncommon = 25, Rare = 5 },
		BotCount = 2,
		BotSpeed = 14,
	},
	{
		Name = "Coral Reef",
		Length = 120,
		Color = Color3.fromRGB(240, 120, 150),
		MaxEggs = 6,
		EggWeights = { Common = 25, Uncommon = 40, Rare = 25, Epic = 10 },
		BotCount = 3,
		BotSpeed = 17,
	},
	{
		Name = "Twilight Deep",
		Length = 120,
		Color = Color3.fromRGB(70, 60, 160),
		MaxEggs = 5,
		EggWeights = { Uncommon = 20, Rare = 40, Epic = 30, Legendary = 10 },
		BotCount = 3,
		BotSpeed = 20,
	},
	{
		Name = "The Abyss",
		Length = 120,
		Color = Color3.fromRGB(25, 20, 50),
		MaxEggs = 4,
		EggWeights = { Rare = 20, Epic = 40, Legendary = 30, Mythic = 10 },
		BotCount = 4,
		BotSpeed = 23,
	},
}
Config.Zones = zones

---------------------------------------------------------------------------
-- CHASER BOTS (Milestone 3)
---------------------------------------------------------------------------
Config.Bots = {
	ModelName = "Shark", -- looked up in ReplicatedStorage.Assets; placeholder if missing
	AggroRadius = 50, -- starts chasing an egg carrier within this distance
	GiveUpDistance = 90, -- stops chasing once the target is farther than this
	CatchDistance = 4.5, -- touching distance that counts as "caught"
	PathRecomputeInterval = 0.5, -- seconds between path recalculations per bot
	DirectChaseDistance = 20, -- closer than this: skip pathfinding, run straight at them
	PatrolPauseTime = 2, -- seconds a bot waits at each patrol point
	CatchCooldown = 3, -- seconds a player is immune after being caught
	KnockbackForce = 80, -- how hard a caught player is pushed back
	KillOnCatch = false, -- true = catching kills the player instead of knocking back
}

---------------------------------------------------------------------------
-- PETS (Milestone 4)
-- Income is money per second at pet level 1.
---------------------------------------------------------------------------
local pets: { PetConfig } = {
	{ Name = "Clownfish", Rarity = "Common", Income = 1 },
	{ Name = "Sardine", Rarity = "Common", Income = 1.5 },
	{ Name = "Pufferfish", Rarity = "Uncommon", Income = 4 },
	{ Name = "Seahorse", Rarity = "Uncommon", Income = 5 },
	{ Name = "Octopus", Rarity = "Rare", Income = 12 },
	{ Name = "Sea Turtle", Rarity = "Rare", Income = 15 },
	{ Name = "Manta Ray", Rarity = "Epic", Income = 40 },
	{ Name = "Swordfish", Rarity = "Epic", Income = 50 },
	{ Name = "Hammerhead", Rarity = "Legendary", Income = 140 },
	{ Name = "Giant Squid", Rarity = "Legendary", Income = 175 },
	{ Name = "Kraken", Rarity = "Mythic", Income = 500 },
	{ Name = "Golden Megalodon", Rarity = "Mythic", Income = 650 },
}
Config.Pets = pets

-- Which pet rarity comes out of which egg rarity (relative weights).
-- Mostly the same rarity, with a small chance of one tier better.
-- Inside the chosen rarity, every pet of that rarity is equally likely.
local hatchOdds: { [string]: Weights } = {
	Common = { Common = 90, Uncommon = 10 },
	Uncommon = { Uncommon = 90, Rare = 10 },
	Rare = { Rare = 92, Epic = 8 },
	Epic = { Epic = 94, Legendary = 6 },
	Legendary = { Legendary = 96, Mythic = 4 },
	Mythic = { Mythic = 100 },
}
Config.HatchOdds = hatchOdds

---------------------------------------------------------------------------
-- ECONOMY (Milestones 4 + 5)
---------------------------------------------------------------------------
Config.Economy = {
	StartingMoney = 0,
	IncomeTickInterval = 1, -- pets pay out every this many seconds
	-- "Pad"  = money piles up on the plot; step on the collect pad to take it
	-- "Auto" = money goes straight to the player
	CollectMode = "Pad",
	SellValueSeconds = 60, -- selling a pet gives this many seconds of its income
}

---------------------------------------------------------------------------
-- UPGRADES (Milestone 5)
-- Price of buying the NEXT level = Base * Growth ^ currentLevel  (rounded)
-- See Config.UpgradePrice below.
---------------------------------------------------------------------------
Config.Upgrades = {
	PetSlots = { Base = 150, Growth = 1.9 }, -- +1 pet slot per level (up to Plots.MaxPetSlots)
	Treadmill = {
		Base = 60,
		Growth = 1.6,
		MaxLevel = 20,
		BaseSpeedGain = 1, -- Speed points per second while running on it at level 0
		GainPerLevel = 0.5, -- each level adds this much to the gain rate
	},
	PetLevel = {
		MaxLevel = 10,
		PriceIncomeSeconds = 30, -- level 1->2 costs 30 seconds of the pet's income
		Growth = 1.5, -- each further level costs 1.5x more
		IncomeBonusPerLevel = 0.25, -- +25% of base income per level above 1
	},
}

-- The price formula used by every upgrade. Kept here so it's easy to tweak.
function Config.UpgradePrice(base: number, growth: number, currentLevel: number): number
	return math.floor(base * growth ^ currentLevel + 0.5)
end

return Config
