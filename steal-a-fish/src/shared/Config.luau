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
}

export type RarityConfig = {
	Name: string,
	Color: Color3,
	Glow: number, -- 0 = no glow; higher = brighter and wider light
}

export type SharkConfig = {
	Speed: number, -- chase speed in studs per second
	Count: number, -- how many sharks patrol this zone
	-- Filled in automatically at the bottom of this file (don't type these):
	SpeedStatNeeded: number?, -- Speed stat at which you walk faster than this shark
	MinutesAtTier1: number?, -- treadmill minutes on the Basic treadmill to get there
}

export type TreadmillTier = {
	Name: string,
	Price: number, -- money to buy it (bought in the Upgrades milestone)
	Gain: number, -- Speed stat gained per second while training
	FrameColor: Color3,
	FrameMaterial: Enum.Material,
	BeltColor: Color3,
	ChevronColor: Color3, -- the arrow markings on the belt
	ChevronNeon: boolean, -- true = glowing arrows
	AccentColor: Color3?, -- glowing stripes along the sides (nil = none)
	ScreenColor: Color3,
	Light: number, -- light brightness around the treadmill (0 = none)
	Effect: string, -- "None", "Sparkles", "Fire" or "Stars"
	Rainbow: boolean, -- frame colors cycle through the rainbow
}

export type EggRarityConfig = {
	HatchTime: number,
	CarrySpeedMultiplier: number,
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
local rarities: { RarityConfig } = {
	{ Name = "Common", Color = Color3.fromRGB(200, 200, 200), Glow = 0 },
	{ Name = "Uncommon", Color = Color3.fromRGB(85, 220, 110), Glow = 0 },
	{ Name = "Rare", Color = Color3.fromRGB(60, 140, 255), Glow = 1 },
	{ Name = "Epic", Color = Color3.fromRGB(170, 80, 255), Glow = 1.5 },
	{ Name = "Legendary", Color = Color3.fromRGB(255, 180, 40), Glow = 2 },
	{ Name = "Mythic", Color = Color3.fromRGB(255, 60, 120), Glow = 2.5 },
	{ Name = "Divine", Color = Color3.fromRGB(255, 245, 190), Glow = 3 },
	{ Name = "Celestial", Color = Color3.fromRGB(120, 230, 255), Glow = 3.5 },
	{ Name = "Cosmic", Color = Color3.fromRGB(90, 50, 210), Glow = 4 },
	{ Name = "Secret", Color = Color3.fromRGB(20, 20, 25), Glow = 5 },
}
Config.Rarities = rarities

---------------------------------------------------------------------------
-- SPEED (the main progression)
-- Players have a Speed STAT that grows on the treadmill and can get huge
-- ("12.5K"). Their actual WalkSpeed grows much more slowly from it:
--
--   WalkSpeed = min(BaseWalkSpeed + Factor * SpeedStat ^ Exponent, MaxWalkSpeed)
--
-- With Factor 0.08 and Exponent 0.5:   Speed stat 0 -> 16,   2.5K -> 20,
--   40K -> 32,   250K -> 56,   400K -> 66.6,   1M -> 80 (the cap).
-- Egg carry slow-downs (Eggs.ByRarity) are multiplied on top.
---------------------------------------------------------------------------
Config.Speed = {
	StartingStat = 0,
	BaseWalkSpeed = 16, -- a brand-new player (Roblox's default)
	Factor = 0.08,
	Exponent = 0.5,
	MaxWalkSpeed = 80, -- hard cap, so the game stays controllable
	-- "Outrunning" a shark means walking at least this much faster than it.
	OutrunMargin = 0.5,
}

-- WalkSpeed for a given Speed stat (before carry slow-downs).
function Config.WalkSpeedFromStat(stat: number): number
	local speed = Config.Speed.BaseWalkSpeed + Config.Speed.Factor * math.max(stat, 0) ^ Config.Speed.Exponent
	return math.min(speed, Config.Speed.MaxWalkSpeed)
end

-- The reverse: the Speed stat needed to reach a WalkSpeed. math.huge if the
-- cap makes it impossible.
function Config.StatNeededForWalkSpeed(walkSpeed: number): number
	local extra = walkSpeed - Config.Speed.BaseWalkSpeed
	if extra <= 0 then
		return 0
	end
	if walkSpeed > Config.Speed.MaxWalkSpeed then
		return math.huge
	end
	return math.ceil((extra / Config.Speed.Factor) ^ (1 / Config.Speed.Exponent))
end

---------------------------------------------------------------------------
-- TREADMILL (Speed milestone)
-- Stand on your own treadmill to train. Every GainInterval seconds you get
-- the tier's Gain, multiplied by any boosts (Robux passes, later).
-- Tier 1 is free and everyone starts with it. Better tiers are bought with
-- money in the Upgrades milestone. Each tier looks cooler than the last, so
-- everyone can see who has the best treadmill.
---------------------------------------------------------------------------
local treadmillTiers: { TreadmillTier } = {
	{
		Name = "Basic", Price = 0, Gain = 10,
		FrameColor = Color3.fromRGB(205, 205, 212), FrameMaterial = Enum.Material.SmoothPlastic,
		BeltColor = Color3.fromRGB(45, 45, 52), ChevronColor = Color3.fromRGB(235, 235, 240), ChevronNeon = false,
		AccentColor = nil, ScreenColor = Color3.fromRGB(80, 220, 255), Light = 0, Effect = "None", Rainbow = false,
	},
	{
		Name = "Bronze", Price = 2_500, Gain = 25,
		FrameColor = Color3.fromRGB(205, 127, 50), FrameMaterial = Enum.Material.Metal,
		BeltColor = Color3.fromRGB(50, 35, 25), ChevronColor = Color3.fromRGB(255, 170, 90), ChevronNeon = false,
		AccentColor = nil, ScreenColor = Color3.fromRGB(255, 170, 90), Light = 0, Effect = "None", Rainbow = false,
	},
	{
		Name = "Silver", Price = 15_000, Gain = 60,
		FrameColor = Color3.fromRGB(200, 205, 215), FrameMaterial = Enum.Material.DiamondPlate,
		BeltColor = Color3.fromRGB(40, 45, 55), ChevronColor = Color3.fromRGB(230, 240, 255), ChevronNeon = true,
		AccentColor = nil, ScreenColor = Color3.fromRGB(200, 230, 255), Light = 0, Effect = "None", Rainbow = false,
	},
	{
		Name = "Gold", Price = 80_000, Gain = 150,
		FrameColor = Color3.fromRGB(255, 200, 60), FrameMaterial = Enum.Material.Foil,
		BeltColor = Color3.fromRGB(60, 45, 20), ChevronColor = Color3.fromRGB(255, 230, 120), ChevronNeon = true,
		AccentColor = Color3.fromRGB(255, 215, 80), ScreenColor = Color3.fromRGB(255, 230, 120), Light = 1, Effect = "None", Rainbow = false,
	},
	{
		Name = "Emerald", Price = 400_000, Gain = 350,
		FrameColor = Color3.fromRGB(40, 190, 110), FrameMaterial = Enum.Material.Glass,
		BeltColor = Color3.fromRGB(15, 50, 35), ChevronColor = Color3.fromRGB(120, 255, 170), ChevronNeon = true,
		AccentColor = Color3.fromRGB(80, 255, 150), ScreenColor = Color3.fromRGB(120, 255, 170), Light = 1.5, Effect = "Sparkles", Rainbow = false,
	},
	{
		Name = "Diamond", Price = 2_000_000, Gain = 800,
		FrameColor = Color3.fromRGB(170, 235, 255), FrameMaterial = Enum.Material.Glass,
		BeltColor = Color3.fromRGB(20, 40, 60), ChevronColor = Color3.fromRGB(150, 240, 255), ChevronNeon = true,
		AccentColor = Color3.fromRGB(120, 230, 255), ScreenColor = Color3.fromRGB(180, 245, 255), Light = 2, Effect = "Sparkles", Rainbow = false,
	},
	{
		Name = "Neon", Price = 10_000_000, Gain = 2_000,
		FrameColor = Color3.fromRGB(25, 25, 35), FrameMaterial = Enum.Material.SmoothPlastic,
		BeltColor = Color3.fromRGB(10, 10, 15), ChevronColor = Color3.fromRGB(255, 60, 220), ChevronNeon = true,
		AccentColor = Color3.fromRGB(0, 255, 255), ScreenColor = Color3.fromRGB(255, 60, 220), Light = 2.5, Effect = "Stars", Rainbow = false,
	},
	{
		Name = "Magma", Price = 50_000_000, Gain = 5_000,
		FrameColor = Color3.fromRGB(60, 30, 25), FrameMaterial = Enum.Material.Basalt,
		BeltColor = Color3.fromRGB(30, 10, 5), ChevronColor = Color3.fromRGB(255, 120, 20), ChevronNeon = true,
		AccentColor = Color3.fromRGB(255, 90, 0), ScreenColor = Color3.fromRGB(255, 140, 40), Light = 3, Effect = "Fire", Rainbow = false,
	},
	{
		Name = "Rainbow", Price = 250_000_000, Gain = 12_000,
		FrameColor = Color3.fromRGB(255, 255, 255), FrameMaterial = Enum.Material.SmoothPlastic,
		BeltColor = Color3.fromRGB(25, 25, 30), ChevronColor = Color3.fromRGB(255, 255, 255), ChevronNeon = true,
		AccentColor = Color3.fromRGB(255, 255, 255), ScreenColor = Color3.fromRGB(255, 255, 255), Light = 3, Effect = "Sparkles", Rainbow = true,
	},
	{
		Name = "Cosmic", Price = 1_500_000_000, Gain = 30_000,
		FrameColor = Color3.fromRGB(40, 20, 80), FrameMaterial = Enum.Material.Glass,
		BeltColor = Color3.fromRGB(5, 0, 20), ChevronColor = Color3.fromRGB(190, 120, 255), ChevronNeon = true,
		AccentColor = Color3.fromRGB(150, 80, 255), ScreenColor = Color3.fromRGB(220, 180, 255), Light = 4, Effect = "Stars", Rainbow = false,
	},
}

Config.Treadmill = {
	GainInterval = 1, -- seconds between Speed gains while training
	Tiers = treadmillTiers,
	ReEnterCooldown = 1, -- seconds after stepping off before the belt grabs you again
}

---------------------------------------------------------------------------
-- CONTROLS
---------------------------------------------------------------------------
Config.Controls = {
	-- Shift lock: press Shift to lock the camera behind your character (it
	-- turns with the mouse). Press Shift again to unlock. On phones/tablets a
	-- small lock button appears instead.
	ShiftLock = true,
	ShiftLockCameraOffset = Vector3.new(1.75, 0, 0), -- camera sits over the right shoulder
}

---------------------------------------------------------------------------
-- VISUALS
---------------------------------------------------------------------------
Config.Visuals = {
	-- Classic Roblox studs, drawn with a tiling Texture on top of each part.
	-- The texture is tinted with the part's own color, so colors stay the same.
	StudsEnabled = true,
	-- If you don't see studs in Studio, find a stud texture in the Toolbox
	-- (Creator Store > Images, search "studs"), copy its ID, and paste it here.
	StudTexture = "rbxassetid://8130710802",
	StudsPerTile = 1, -- size of one stud texture tile, in studs
	StudTransparency = 0.3, -- 0 = strong studs, 1 = invisible studs
	TreadmillBeltSpeed = 6, -- how fast the belt markings scroll (studs per second)
}

---------------------------------------------------------------------------
-- PLOTS (Milestone 1)
---------------------------------------------------------------------------
Config.Plots = {
	Count = 8, -- maximum players per server should be <= this
	Size = Vector3.new(60, 1, 80), -- width (X), thickness (Y), depth (Z) of one plot
	Gap = 8, -- empty space between two plots
	-- PADS: rectangular pads along the left and right side of the plot. Each
	-- pad holds ONE thing: an egg (until it hatches) or the pet that hatched
	-- from it (until it's sold). Pads are unlocked front to back, left/right
	-- alternating; the plot space upgrade unlocks more.
	PadsPerSide = 5, -- so 10 pads in total
	StartingPads = 6, -- unlocked on a brand new plot
	PadSize = Vector3.new(6, 0.6, 7), -- depth toward the middle (X), height, length along the side (Z)
	PadColor = Color3.fromRGB(150, 150, 160),
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
-- WORLD LAYOUT
-- Seen from above (everything is surrounded by one tall map wall):
--
--                 | The Void Below  |     (zone 10, deepest, toward -Z)
--                 |  ...            |
--                 |  Shallows       |     (zone 1)
--   +-------------[ entrance arch   ]-------------+
--   |          big open front area (safe)         |
--   |     [P1][P2][P3][P4]   [P5][P6][P7][P8]     |  (plots, toward +Z)
--   +---------------------------------------------+
---------------------------------------------------------------------------
Config.World = {
	GroundTop = 1, -- height (Y) of the walkable ground surface
	-- Depth of the big open (safe) area between the plots and the danger zone
	-- entrance. Shops and upgrade stations will go here later.
	FrontAreaDepth = 75,
	DangerZoneWidth = 160, -- width of the danger zone (and its entrance)
	MapSideMargin = 20, -- space between the outer plots and the map wall
	MapBackMargin = 20, -- space between the back of the plots and the map wall
	GroundColor = Color3.fromRGB(235, 215, 160), -- sand
	OceanColor = Color3.fromRGB(40, 130, 200), -- what you see beyond the wall

	-- The tall wall around the whole map.
	MapWallHeight = 40, -- players jump about 7 studs
	MapWallThickness = 4,
	WallTileSize = 10, -- size of one checkerboard square
	WallColorA = Color3.fromRGB(240, 215, 160), -- sand
	WallColorB = Color3.fromRGB(245, 145, 120), -- coral
	WallTrimColor = Color3.fromRGB(40, 190, 185), -- sea-green trim along the top
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
	MaxEggsTotal = 50, -- hard cap on eggs lying in the whole danger zone
	SpawnMargin = 10, -- eggs never spawn closer than this to the zone's walls/edges
	MinSpacing = 8, -- eggs try not to spawn closer than this to each other
	Size = Vector3.new(2.4, 3, 2.4), -- placeholder egg size (width, height, depth)
	CarryHeight = 5, -- how far above the character's middle the carried egg floats
	-- How much of an egg sticks out of the ground (0.5 = top half, like it's
	-- stuck in the sand). Also used for eggs on the plot pads.
	VisibleFraction = 0.5,
	-- How glowing eggs look: light range and brightness grow with Rarities[...].Glow.
	GlowRangePerLevel = 4,
	GlowBrightnessPerLevel = 0.6,

	-- What happens to a carried egg:
	--   "Drop" = the egg falls on the ground where they were and can be picked up again
	--   "Lose" = the egg disappears instantly
	OnCaught = "Lose", -- caught by a shark
	OnDeath = "Drop", -- died or reset in any other way
	DroppedEggLifetime = 20, -- seconds a dropped egg stays before vanishing

	-- CarrySpeedMultiplier: 1 = no slow-down. (0.9 would mean walking at 90% speed.)
	ByRarity = ({
		Common = { HatchTime = 10, CarrySpeedMultiplier = 1 },
		Uncommon = { HatchTime = 20, CarrySpeedMultiplier = 1 },
		Rare = { HatchTime = 40, CarrySpeedMultiplier = 1 },
		Epic = { HatchTime = 75, CarrySpeedMultiplier = 1 },
		Legendary = { HatchTime = 120, CarrySpeedMultiplier = 1 },
		Mythic = { HatchTime = 180, CarrySpeedMultiplier = 1 },
		Divine = { HatchTime = 240, CarrySpeedMultiplier = 1 },
		Celestial = { HatchTime = 300, CarrySpeedMultiplier = 1 },
		Cosmic = { HatchTime = 420, CarrySpeedMultiplier = 1 },
		Secret = { HatchTime = 600, CarrySpeedMultiplier = 1 },
	} :: { [string]: EggRarityConfig }),
}

---------------------------------------------------------------------------
-- DANGER ZONES (Milestones 2 + 3)
-- Listed from the entrance (shallowest) to the deepest. Each zone is a strip
-- of the danger area, Length studs deep. Deeper zones: rarer eggs and faster
-- sharks (see Config.Sharks). The rarest tiers only appear in the deepest zones.
-- EggWeights are relative weights, not percents: {Common = 3, Rare = 1}
-- means Common is 3x as likely as Rare (75% vs 25%).
---------------------------------------------------------------------------
local zones: { ZoneConfig } = {
	{
		Name = "Shallows", -- zone 1
		Length = 90,
		Color = Color3.fromRGB(90, 200, 230),
		MaxEggs = 6,
		EggWeights = { Common = 80, Uncommon = 18, Rare = 2 },
	},
	{
		Name = "Coral Reef", -- zone 2
		Length = 90,
		Color = Color3.fromRGB(240, 120, 150),
		MaxEggs = 6,
		EggWeights = { Common = 40, Uncommon = 40, Rare = 17, Epic = 3 },
	},
	{
		Name = "Kelp Forest", -- zone 3
		Length = 90,
		Color = Color3.fromRGB(60, 150, 90),
		MaxEggs = 5,
		EggWeights = { Uncommon = 40, Rare = 40, Epic = 17, Legendary = 3 },
	},
	{
		Name = "Shipwreck Bay", -- zone 4
		Length = 90,
		Color = Color3.fromRGB(120, 95, 70),
		MaxEggs = 5,
		EggWeights = { Rare = 45, Epic = 40, Legendary = 13, Mythic = 2 },
	},
	{
		Name = "Twilight Deep", -- zone 5
		Length = 90,
		Color = Color3.fromRGB(70, 60, 160),
		MaxEggs = 5,
		EggWeights = { Epic = 50, Legendary = 38, Mythic = 11, Divine = 1 },
	},
	{
		Name = "Midnight Trench", -- zone 6
		Length = 90,
		Color = Color3.fromRGB(35, 40, 90),
		MaxEggs = 4,
		EggWeights = { Legendary = 50, Mythic = 38, Divine = 11, Celestial = 1 },
	},
	{
		Name = "Hydrothermal Vents", -- zone 7
		Length = 90,
		Color = Color3.fromRGB(90, 35, 30),
		MaxEggs = 4,
		EggWeights = { Mythic = 55, Divine = 35, Celestial = 9.5, Cosmic = 0.5 },
	},
	{
		Name = "The Abyss", -- zone 8
		Length = 90,
		Color = Color3.fromRGB(25, 20, 50),
		MaxEggs = 4,
		EggWeights = { Divine = 55, Celestial = 35, Cosmic = 9.8, Secret = 0.2 },
	},
	{
		Name = "Leviathan's Lair", -- zone 9
		Length = 90,
		Color = Color3.fromRGB(20, 30, 35),
		MaxEggs = 3,
		EggWeights = { Celestial = 60, Cosmic = 37, Secret = 3 },
	},
	{
		Name = "The Void Below", -- zone 10
		Length = 90,
		Color = Color3.fromRGB(8, 8, 14),
		MaxEggs = 3,
		EggWeights = { Celestial = 30, Cosmic = 60, Secret = 10 },
	},
}
Config.Zones = zones

---------------------------------------------------------------------------
-- SHARKS PER ZONE (Milestone 3)
-- One row per zone, in the same order as Config.Zones above.
-- A player can only escape a zone's shark if they walk FASTER than its Speed.
---------------------------------------------------------------------------
local sharks: { SharkConfig } = {
	--  chase speed     sharks in zone
	{ Speed = 14, Count = 1 }, -- 1  Shallows
	{ Speed = 20, Count = 1 }, -- 2  Coral Reef
	{ Speed = 24, Count = 1 }, -- 3  Kelp Forest
	{ Speed = 28, Count = 1 }, -- 4  Shipwreck Bay
	{ Speed = 33, Count = 1 }, -- 5  Twilight Deep
	{ Speed = 38, Count = 1 }, -- 6  Midnight Trench
	{ Speed = 44, Count = 1 }, -- 7  Hydrothermal Vents
	{ Speed = 50, Count = 1 }, -- 8  The Abyss
	{ Speed = 57, Count = 1 }, -- 9  Leviathan's Lair
	{ Speed = 66, Count = 1 }, -- 10 The Void Below
}
Config.Sharks = sharks

---------------------------------------------------------------------------
-- CHASER BOTS (Milestone 3): how every shark behaves
---------------------------------------------------------------------------
Config.Bots = {
	ModelName = "Shark", -- looked up in ReplicatedStorage.Assets; placeholder if missing
	PatrolSpeedMultiplier = 0.55, -- patrol speed = the zone's shark Speed * this
	MaxBotsTotal = 16, -- hard cap on sharks in the server (sum of all Counts)
	HoverHeight = 2.5, -- how high sharks swim above the floor

	-- Chasing
	AggroRadius = 50, -- starts chasing an egg carrier within this distance
	GiveUpDistance = 90, -- stops chasing once the target is farther than this
	LeashPadding = 20, -- sharks may follow this far outside their own zone (never out of the danger zone)
	CatchDistance = 5.5, -- distance (center to center) that counts as "caught"
	DirectChaseDistance = 20, -- closer than this: skip pathfinding, swim straight at them
	PathRecomputeInterval = 0.5, -- seconds between path recalculations per shark
	MaxPathComputesPerSecond = 10, -- pathfinding budget shared by ALL sharks
	UpdateInterval = 0.1, -- seconds between shark brain updates

	-- Patrolling
	PatrolPauseTime = 2, -- seconds a shark waits at each patrol point

	-- Being caught
	CatchCooldown = 3, -- seconds a player is ignored by sharks after being caught
	PostCatchPause = 1.5, -- seconds a shark rests after catching someone
	KnockbackForce = 70, -- sideways push on a caught player
	KnockbackUpForce = 35, -- upward push on a caught player
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
	{ Name = "Angel Jellyfish", Rarity = "Divine", Income = 2000 },
	{ Name = "Pearl Narwhal", Rarity = "Divine", Income = 2600 },
	{ Name = "Starfish Sovereign", Rarity = "Celestial", Income = 7000 },
	{ Name = "Comet Orca", Rarity = "Celestial", Income = 9000 },
	{ Name = "Nebula Ray", Rarity = "Cosmic", Income = 25000 },
	{ Name = "Galaxy Whale", Rarity = "Cosmic", Income = 32000 },
	{ Name = "Abyssal Leviathan", Rarity = "Secret", Income = 100000 },
	{ Name = "The Deep One", Rarity = "Secret", Income = 150000 },
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
	Mythic = { Mythic = 96, Divine = 4 },
	Divine = { Divine = 96, Celestial = 4 },
	Celestial = { Celestial = 97, Cosmic = 3 },
	Cosmic = { Cosmic = 98, Secret = 2 },
	Secret = { Secret = 100 },
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
	Pads = { Base = 150, Growth = 1.9 }, -- plot space: +1 pad per level (up to PadsPerSide * 2)
	-- Treadmill upgrades are the tiers in Config.Treadmill.Tiers (each has its own Price).
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

---------------------------------------------------------------------------
-- BALANCE TABLE (calculated, not typed by hand)
-- For every zone: the Speed stat you need to outrun its shark, and how many
-- minutes on the Basic treadmill that takes. Printed to Output when the
-- server starts. Change Config.Sharks speeds or Config.Speed to rebalance.
---------------------------------------------------------------------------
for _, shark in Config.Sharks do
	local needed = Config.StatNeededForWalkSpeed(shark.Speed + Config.Speed.OutrunMargin)
	shark.SpeedStatNeeded = needed
	local gainPerMinute = treadmillTiers[1].Gain / Config.Treadmill.GainInterval * 60
	shark.MinutesAtTier1 = needed / gainPerMinute
end

return Config
