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
	-- A small decoration on every egg from this zone (so you can tell where
	-- an egg came from): "Shell", "Coral", "Seaweed", "Rust", "Glowworms",
	-- "Frost", "Lava", "Tentacle", "Bones" or "Void".
	EggDetail: string,
	-- Shown after the zone name when you walk in ("Shallows 😄"). Happy at
	-- the start, scarier the deeper you go.
	Emoji: string,
}

export type RarityConfig = {
	Name: string,
	Color: Color3,
	Glow: number, -- 0 = no glow; higher = brighter and wider light
}

export type SharkConfig = {
	-- The Speed stat shown on the zone's sign. If set, the shark's Speed is
	-- CALCULATED from it (see BALANCE TABLE at the bottom), so at exactly
	-- this Speed you just barely escape the zone. Leave it out to type the
	-- shark's Speed yourself (zone 1).
	RecommendedSpeed: number?,
	Speed: number, -- chase speed in studs per second (calculated when RecommendedSpeed is set)
	Count: number, -- how many sharks patrol this zone
	-- Looks (deeper = bigger and scarier):
	Color: Color3, -- back and fins
	Belly: Color3, -- underside
	Scale: number, -- 1 = normal size (about 11 studs long)
	EyeColor: Color3,
	GlowEyes: boolean, -- glowing eyes (for the dark zones)
	Scars: number, -- 0..3 battle scars on its sides
	Spikes: boolean, -- spiky ridge along its back
	-- Filled in automatically at the bottom of this file (don't type these):
	SpeedStatNeeded: number?, -- recommended Speed stat for this zone (see BALANCE TABLE)
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

-- One fish you can hatch. See the FISH section below for what the look
-- fields (Shape, Pattern, Feature) can be.
export type FishConfig = {
	Name: string,
	Zone: number, -- eggs from this zone hatch into this fish (1 = Shallows)
	Rarity: string,
	Income: number, -- money per second at level 1
	Shape: string,
	Pattern: string,
	Feature: string,
	Body: Color3, -- main color
	Accent: Color3, -- pattern color (stripes, spots, belly, ...)
	Fin: Color3, -- fins and tail
}

-- How an egg of one rarity looks (EGG LOOKS section).
export type EggLook = {
	Pattern: string,
	Accent: Color3,
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
-- With Factor 0.18 and Exponent 0.4:   Speed stat 0 -> 16,   3K -> 20.5,
--   100K -> 44.5,   1M -> 61,   4M -> 94.5,   12.5M -> 140 (the cap).
-- The cap is high on purpose: even the best treadmills (Rainbow, Cosmic)
-- still make you faster.
-- Egg carry slow-downs (Eggs.ByRarity) are multiplied on top.
---------------------------------------------------------------------------
Config.Speed = {
	StartingStat = 0,
	BaseWalkSpeed = 16, -- a brand-new player (Roblox's default)
	Factor = 0.18,
	Exponent = 0.4,
	MaxWalkSpeed = 140, -- hard cap, so the game stays controllable
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
		Name = "Diamond", Price = 6_000_000, Gain = 800,
		FrameColor = Color3.fromRGB(170, 235, 255), FrameMaterial = Enum.Material.Glass,
		BeltColor = Color3.fromRGB(20, 40, 60), ChevronColor = Color3.fromRGB(150, 240, 255), ChevronNeon = true,
		AccentColor = Color3.fromRGB(120, 230, 255), ScreenColor = Color3.fromRGB(180, 245, 255), Light = 2, Effect = "Sparkles", Rainbow = false,
	},
	{
		Name = "Neon", Price = 30_000_000, Gain = 2_000,
		FrameColor = Color3.fromRGB(25, 25, 35), FrameMaterial = Enum.Material.SmoothPlastic,
		BeltColor = Color3.fromRGB(10, 10, 15), ChevronColor = Color3.fromRGB(255, 60, 220), ChevronNeon = true,
		AccentColor = Color3.fromRGB(0, 255, 255), ScreenColor = Color3.fromRGB(255, 60, 220), Light = 2.5, Effect = "Stars", Rainbow = false,
	},
	{
		Name = "Magma", Price = 150_000_000, Gain = 5_000,
		FrameColor = Color3.fromRGB(60, 30, 25), FrameMaterial = Enum.Material.Basalt,
		BeltColor = Color3.fromRGB(30, 10, 5), ChevronColor = Color3.fromRGB(255, 120, 20), ChevronNeon = true,
		AccentColor = Color3.fromRGB(255, 90, 0), ScreenColor = Color3.fromRGB(255, 140, 40), Light = 3, Effect = "Fire", Rainbow = false,
	},
	{
		Name = "Rainbow", Price = 750_000_000, Gain = 12_000,
		FrameColor = Color3.fromRGB(255, 255, 255), FrameMaterial = Enum.Material.SmoothPlastic,
		BeltColor = Color3.fromRGB(25, 25, 30), ChevronColor = Color3.fromRGB(255, 255, 255), ChevronNeon = true,
		AccentColor = Color3.fromRGB(255, 255, 255), ScreenColor = Color3.fromRGB(255, 255, 255), Light = 3, Effect = "Sparkles", Rainbow = true,
	},
	{
		Name = "Cosmic", Price = 4_500_000_000, Gain = 30_000,
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
-- UI, SOUNDS AND TUTORIAL (UI & polish milestone)
---------------------------------------------------------------------------
Config.UI = {
	-- Everything on screen is scaled to fit the screen size, between these
	-- limits. 1 = designed size (a 1280x720 screen).
	MinScale = 0.7,
	MaxScale = 1.3,
	TouchMinScale = 0.9, -- phones/tablets never go smaller than this (big enough to tap)
	CaughtSplashSeconds = 1.2, -- how long the big "CAUGHT!" text stays
	ZoneBannerSeconds = 3, -- how long a zone's name stays at the top of the screen
	SafeSplashSeconds = 1.4, -- how long the big "SAFE!" text stays
}

-- Sounds. These are short placeholder sounds that come with Roblox
-- ("rbxasset://sounds/..."). To use your own: find a sound in the Toolbox
-- (Creator Store > Audio), copy its ID and put "rbxassetid://<number>" here.
export type SoundConfig = { Id: string, Volume: number }
local sounds: { [string]: SoundConfig } = {
	Pickup = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.6 },
	Caught = { Id = "rbxasset://sounds/impact_water.mp3", Volume = 0.8 },
	Hatch = { Id = "rbxasset://sounds/swoosh.wav", Volume = 0.7 },
	Purchase = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.7 },
	Coins = { Id = "rbxasset://sounds/clickfast.wav", Volume = 0.5 },
	Click = { Id = "rbxasset://sounds/button.wav", Volume = 0.4 },
	Warning = { Id = "rbxasset://sounds/button.wav", Volume = 0.3 },
	Safe = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.9 }, -- reached the safe zone with an egg
	Claim = { Id = "rbxasset://sounds/electronicpingshort.wav", Volume = 0.8 }, -- index rewards, daily gift
}
Config.Sounds = sounds

Config.Tutorial = {
	ArrowColor = Color3.fromRGB(255, 230, 60),
	ArrowDistance = 7, -- how far in front of the player the arrow floats
	BeaconHeight = 60, -- height of the glowing column at the target
}

---------------------------------------------------------------------------
-- PLOTS (Milestone 1)
---------------------------------------------------------------------------
Config.Plots = {
	Count = 8, -- maximum players per server should be <= this
	-- Big enough for max-level fish (they're about 3x their level-1 size).
	Size = Vector3.new(76, 1, 110), -- width (X), thickness (Y), depth (Z) of one plot
	Gap = 10, -- empty space between two plots
	-- PADS: rectangular pads along the left and right side of the plot. Each
	-- pad holds ONE thing: an egg (until it hatches) or the pet that hatched
	-- from it (until it's sold). Pads are unlocked front to back, left/right
	-- alternating; the plot space upgrade unlocks more.
	PadsPerSide = 5, -- so 10 pads in total
	StartingPads = 6, -- unlocked on a brand new plot
	PadSize = Vector3.new(10, 0.6, 11), -- depth toward the middle (X), height, length along the side (Z)
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
	WallColorA = Color3.fromRGB(60, 150, 225), -- ocean blue
	WallColorB = Color3.fromRGB(35, 105, 195), -- deeper blue
	WallTrimColor = Color3.fromRGB(110, 205, 240), -- light water along the top
	WallFoamColor = Color3.fromRGB(240, 252, 255), -- the white wave foam on top
	WaveLength = 8, -- studs between two wave crests on top of the wall

	-- The line where the safe zone starts (at the danger zone entrance).
	SafeLineColor = Color3.fromRGB(240, 60, 60),
	SafeLineText = "SAFE ZONE",
	SpeedSignColor = Color3.fromRGB(35, 45, 70), -- the "Recommended Speed" signs
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
	-- Egg inventory: when you reach the safe zone with a stolen egg, it goes
	-- into your hotbar as a Tool ("Rare Egg"). Equip it, walk to a free pad
	-- and press E to place it there. Inventory eggs are saved.
	MaxInventory = 7,
	PlaceHoldDuration = 0, -- seconds to hold E to place an egg on a pad
	HatchHoldDuration = 1, -- seconds to hold E on a READY egg to hatch it
	SpawnMargin = 10, -- eggs never spawn closer than this to the zone's side walls
	-- Eggs only spawn in the BACK part of their zone: from this far into the
	-- zone (0.5 = the halfway mark) up to the shark's patrol line.
	-- Eggs spawn in a band around the "typical" egg spot the balance math
	-- uses (Balance.PlayerStartFraction = 0.75): from 65% to 85% of the way
	-- into their zone (and never closer than SpawnLineGap to the patrol line).
	SpawnFromFraction = 0.65,
	SpawnToFraction = 0.85,
	SpawnLineGap = 8,
	MinSpacing = 8, -- eggs try not to spawn closer than this to each other
	Size = Vector3.new(2.4, 3, 2.4), -- placeholder egg size (width, height, depth)
	-- Carrying: the arms point straight up and the egg rests on the hands.
	-- The height is measured from the character's arms; CarryHeight is only
	-- used for unusual characters whose arms can't be measured.
	CarryHeight = 4.5,
	CarryRestOffset = -0.25, -- move the carried egg up (+) or down (-) on the hands
	-- How much of an egg sticks out of the ground (0.5 = top half, like it's
	-- stuck in the sand). Also used for eggs on the plot pads.
	VisibleFraction = 0.5,
	-- Every hatch time is multiplied by this (e.g. 0.5 = twice as fast).
	-- A "Faster Hatching" pass can lower it per player later.
	HatchTimeMultiplier = 1,
	-- How glowing eggs look: light range and brightness grow with Rarities[...].Glow.
	GlowRangePerLevel = 4,
	GlowBrightnessPerLevel = 0.6,

	-- What happens to a carried egg:
	--   "Drop" = the egg falls on the ground where they were and can be picked up again
	--   "Lose" = the egg disappears instantly
	-- CAUGHT BY A SHARK: it depends on WHERE you are caught, compared to the
	-- zone the egg ORIGINALLY spawned in (eggs remember that zone forever):
	--   caught in the egg's own zone or any DEEPER zone (zone number >= original)
	--       -> OnCaught.SameOrDeeperZone
	--   caught in a SHALLOWER zone (zone number < original)
	--       -> OnCaught.ShallowerZone
	-- Example: a zone 5 egg caught in zone 5..10 is gone; caught in zone 1..4
	-- it drops, anyone can grab it again, and zone 5's shark chases again.
	OnCaught = {
		SameOrDeeperZone = "Lose",
		ShallowerZone = "Drop",
	},
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
-- How deep (studs, along the run) every danger zone is. Walls, egg spawns,
-- signs, shark areas and the zone names on screen all follow this.
local ZONE_LENGTH = 234

local zones: { ZoneConfig } = {
	{
		Name = "Shallows", -- zone 1
		Length = ZONE_LENGTH,
		Color = Color3.fromRGB(90, 200, 230),
		MaxEggs = 6,
		EggWeights = { Common = 80, Uncommon = 18, Rare = 2 },
		EggDetail = "Shell",
		Emoji = "😄",
	},
	{
		Name = "Coral Reef", -- zone 2
		Length = ZONE_LENGTH,
		Color = Color3.fromRGB(240, 120, 150),
		MaxEggs = 6,
		EggWeights = { Common = 40, Uncommon = 40, Rare = 17, Epic = 3 },
		EggDetail = "Coral",
		Emoji = "🙂",
	},
	{
		Name = "Kelp Forest", -- zone 3
		Length = ZONE_LENGTH,
		Color = Color3.fromRGB(60, 150, 90),
		MaxEggs = 5,
		EggWeights = { Uncommon = 40, Rare = 40, Epic = 17, Legendary = 3 },
		EggDetail = "Seaweed",
		Emoji = "😐",
	},
	{
		Name = "Shipwreck Bay", -- zone 4
		Length = ZONE_LENGTH,
		Color = Color3.fromRGB(120, 95, 70),
		MaxEggs = 5,
		EggWeights = { Rare = 45, Epic = 40, Legendary = 13, Mythic = 2 },
		EggDetail = "Rust",
		Emoji = "😬",
	},
	{
		Name = "Twilight Deep", -- zone 5
		Length = ZONE_LENGTH,
		Color = Color3.fromRGB(70, 60, 160),
		MaxEggs = 5,
		EggWeights = { Epic = 50, Legendary = 38, Mythic = 11, Divine = 1 },
		EggDetail = "Glowworms",
		Emoji = "😟",
	},
	{
		Name = "Midnight Trench", -- zone 6
		Length = ZONE_LENGTH,
		Color = Color3.fromRGB(35, 40, 90),
		MaxEggs = 4,
		EggWeights = { Legendary = 50, Mythic = 38, Divine = 11, Celestial = 1 },
		EggDetail = "Frost",
		Emoji = "😨",
	},
	{
		Name = "Hydrothermal Vents", -- zone 7
		Length = ZONE_LENGTH,
		Color = Color3.fromRGB(90, 35, 30),
		MaxEggs = 4,
		EggWeights = { Mythic = 55, Divine = 35, Celestial = 10 },
		EggDetail = "Lava",
		Emoji = "😰",
	},
	{
		Name = "The Abyss", -- zone 8
		Length = ZONE_LENGTH,
		Color = Color3.fromRGB(25, 20, 50),
		MaxEggs = 4,
		EggWeights = { Divine = 55, Celestial = 35, Cosmic = 10 },
		EggDetail = "Tentacle",
		Emoji = "😱",
	},
	{
		Name = "Leviathan's Lair", -- zone 9
		Length = ZONE_LENGTH,
		Color = Color3.fromRGB(20, 30, 35),
		MaxEggs = 3,
		EggWeights = { Celestial = 60, Cosmic = 37, Secret = 3 },
		EggDetail = "Bones",
		Emoji = "💀",
	},
	{
		Name = "The Void Below", -- zone 10
		Length = ZONE_LENGTH,
		Color = Color3.fromRGB(8, 8, 14),
		MaxEggs = 3,
		EggWeights = { Celestial = 30, Cosmic = 60, Secret = 10 },
		EggDetail = "Void",
		Emoji = "☠️",
	},
}
Config.Zones = zones

---------------------------------------------------------------------------
-- SHARKS PER ZONE (Milestone 3)
-- One row per zone, in the same order as Config.Zones above.
-- A player can only escape a zone's shark if they walk FASTER than its Speed.
-- The look fields set each shark's colors and size. A model named
-- "Shark<zone number>" (e.g. "Shark7") or "Shark" in ReplicatedStorage.Assets
-- replaces the built-in shark.
---------------------------------------------------------------------------
local sharks: { SharkConfig } = {
	-- 1 Shallows: small, friendly-looking grey
	{ Speed = 17, Count = 1, Color = Color3.fromRGB(125, 155, 180), Belly = Color3.fromRGB(240, 245, 250),
		Scale = 0.9, EyeColor = Color3.fromRGB(20, 20, 25), GlowEyes = false, Scars = 0, Spikes = false },
	-- 2 Coral Reef
	{ RecommendedSpeed = 5_000, Speed = 0, Count = 1, Color = Color3.fromRGB(95, 125, 165), Belly = Color3.fromRGB(235, 240, 245),
		Scale = 1, EyeColor = Color3.fromRGB(20, 20, 25), GlowEyes = false, Scars = 0, Spikes = false },
	-- 3 Kelp Forest: green camouflage
	{ RecommendedSpeed = 45_000, Speed = 0, Count = 1, Color = Color3.fromRGB(80, 115, 85), Belly = Color3.fromRGB(215, 225, 190),
		Scale = 1.05, EyeColor = Color3.fromRGB(20, 20, 25), GlowEyes = false, Scars = 1, Spikes = false },
	-- 4 Shipwreck Bay: rusty and scarred
	{ RecommendedSpeed = 150_000, Speed = 0, Count = 1, Color = Color3.fromRGB(120, 100, 85), Belly = Color3.fromRGB(220, 205, 180),
		Scale = 1.1, EyeColor = Color3.fromRGB(20, 20, 25), GlowEyes = false, Scars = 2, Spikes = false },
	-- 5 Twilight Deep: purple, eyes start glowing
	{ RecommendedSpeed = 350_000, Speed = 0, Count = 1, Color = Color3.fromRGB(80, 65, 140), Belly = Color3.fromRGB(190, 180, 225),
		Scale = 1.15, EyeColor = Color3.fromRGB(255, 240, 120), GlowEyes = true, Scars = 1, Spikes = false },
	-- 6 Midnight Trench
	{ RecommendedSpeed = 700_000, Speed = 0, Count = 1, Color = Color3.fromRGB(40, 45, 80), Belly = Color3.fromRGB(150, 160, 200),
		Scale = 1.2, EyeColor = Color3.fromRGB(120, 220, 255), GlowEyes = true, Scars = 2, Spikes = false },
	-- 7 Hydrothermal Vents: charcoal with lava eyes
	{ RecommendedSpeed = 1_300_000, Speed = 0, Count = 1, Color = Color3.fromRGB(70, 35, 30), Belly = Color3.fromRGB(150, 100, 80),
		Scale = 1.3, EyeColor = Color3.fromRGB(255, 120, 30), GlowEyes = true, Scars = 2, Spikes = true },
	-- 8 The Abyss
	{ RecommendedSpeed = 2_000_000, Speed = 0, Count = 1, Color = Color3.fromRGB(28, 22, 45), Belly = Color3.fromRGB(90, 80, 120),
		Scale = 1.4, EyeColor = Color3.fromRGB(255, 40, 60), GlowEyes = true, Scars = 3, Spikes = true },
	-- 9 Leviathan's Lair
	{ RecommendedSpeed = 3_500_000, Speed = 0, Count = 1, Color = Color3.fromRGB(20, 50, 50), Belly = Color3.fromRGB(80, 130, 120),
		Scale = 1.5, EyeColor = Color3.fromRGB(80, 255, 160), GlowEyes = true, Scars = 3, Spikes = true },
	-- 10 The Void Below: biggest and darkest
	{ RecommendedSpeed = 6_000_000, Speed = 0, Count = 1, Color = Color3.fromRGB(12, 10, 20), Belly = Color3.fromRGB(60, 40, 90),
		Scale = 1.6, EyeColor = Color3.fromRGB(190, 90, 255), GlowEyes = true, Scars = 3, Spikes = true },
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
	-- Only the shark(s) of the zone an egg was stolen from chase the thief.
	-- They follow across zone borders until the thief reaches the safe zone,
	-- drops the egg or dies, then swim back to their own zone.
	SafeLineMargin = 3, -- sharks stop this many studs before the safe zone starts
	-- Distance (center to center) that counts as "caught", for a shark of
	-- Scale 1. Bigger sharks (Config.Sharks[...].Scale) catch from farther.
	CatchDistance = 6,
	-- Sharks swim straight at the thief, aiming at where the thief will be
	-- in up to this many seconds (so they cut you off instead of trailing).
	MaxLeadTime = 1,
	-- Studio only: print the real shark/player speeds and the race result to
	-- Output during every chase (to compare with the BALANCE TABLE).
	DebugChaseLog = true,
	UpdateInterval = 0.1, -- seconds between shark brain updates

	-- Patrolling
	-- Each shark swims back and forth in a straight line across the width of
	-- its zone, at the far (deep) end. After a chase it swims back to it.
	PatrolLineInset = 12, -- studs between the patrol line and the zone's deep edge
	PatrolEdgeMargin = 10, -- the line stops this far from the side walls
	PatrolPauseTime = 0.6, -- seconds a shark waits at each end of its line

	-- Being caught
	-- After being caught you're IMMUNE for this many seconds (the shark can't
	-- catch you again), so you get a head start with a dropped egg. Raise it
	-- to make re-catches less annoying, lower it to make them harsher.
	CatchCooldown = 3,
	PostCatchPause = 1.5, -- seconds a shark rests after catching someone
	KnockbackForce = 70, -- sideways push on a caught player
	KnockbackUpForce = 35, -- upward push on a caught player
	KillOnCatch = false, -- true = catching kills the player instead of knocking back
}

---------------------------------------------------------------------------
-- FISH (what eggs hatch into): 8 per zone, 80 in total.
-- An egg remembers the zone it was stolen from. When it hatches, one of THAT
-- zone's 8 fish comes out (see HATCHING below for the odds).
-- Income = money per second at level 1. It grows with rarity and depth
-- (the same fish slot earns about 1.3x more in each deeper zone).
--
-- Looks (all built from blocks; a model in ReplicatedStorage.Assets with the
-- fish's exact Name replaces the built-in one):
--   Shape:   Fish, FishSmall, FishLong, FishFlat, FishRound, FishBig, Whale,
--            Eel, Crab, Star, Puffer, Turtle, Seahorse, Jelly, Squid, Ray
--   Pattern: None, Stripes, Spots, Belly, Rainbow, GlowSpots, Stars, Ribs, Glitch
--   Feature: None, Sunglasses, Crown, Spikes, Headphones, PirateHat, Eyepatch,
--            Ghost, Nightcap, Fangs, Horn, Halo, Lure, SharkFin, Leaves, Shell
-- Rarer fish are bigger and get effects: glow (Rare+), sparkles (Legendary+),
-- an aura (Mythic+), and color-shifting fins + cosmic particles (Celestial+).
---------------------------------------------------------------------------
local fish: { FishConfig } = {
	-- Zone 1: Shallows
	{ Name = "Clowny Clownfish", Zone = 1, Rarity = "Common", Income = 1.0, Shape = "Fish", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(255, 140, 40), Accent = Color3.fromRGB(255, 255, 255), Fin = Color3.fromRGB(30, 30, 30) },
	{ Name = "Pinchy Crab", Zone = 1, Rarity = "Common", Income = 1.0, Shape = "Crab", Pattern = "None", Feature = "None",
		Body = Color3.fromRGB(240, 110, 60), Accent = Color3.fromRGB(255, 200, 150), Fin = Color3.fromRGB(200, 70, 40) },
	{ Name = "Starla Starfish", Zone = 1, Rarity = "Common", Income = 1.0, Shape = "Star", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(255, 130, 170), Accent = Color3.fromRGB(255, 220, 230), Fin = Color3.fromRGB(230, 90, 140) },
	{ Name = "Guppy McGuppface", Zone = 1, Rarity = "Uncommon", Income = 3.0, Shape = "FishSmall", Pattern = "Belly", Feature = "None",
		Body = Color3.fromRGB(80, 200, 255), Accent = Color3.fromRGB(255, 255, 255), Fin = Color3.fromRGB(40, 140, 220) },
	{ Name = "Bubble Puffer", Zone = 1, Rarity = "Uncommon", Income = 3.0, Shape = "Puffer", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(255, 220, 80), Accent = Color3.fromRGB(255, 255, 200), Fin = Color3.fromRGB(220, 170, 40) },
	{ Name = "Shelly Turtle", Zone = 1, Rarity = "Rare", Income = 9.0, Shape = "Turtle", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(110, 190, 90), Accent = Color3.fromRGB(170, 120, 70), Fin = Color3.fromRGB(80, 150, 70) },
	{ Name = "Sea Biscuit", Zone = 1, Rarity = "Rare", Income = 7.5, Shape = "Seahorse", Pattern = "Belly", Feature = "None",
		Body = Color3.fromRGB(255, 200, 60), Accent = Color3.fromRGB(255, 240, 180), Fin = Color3.fromRGB(230, 150, 40) },
	{ Name = "Sunbeam Tang", Zone = 1, Rarity = "Epic", Income = 22, Shape = "FishFlat", Pattern = "None", Feature = "Sunglasses",
		Body = Color3.fromRGB(255, 230, 40), Accent = Color3.fromRGB(255, 255, 255), Fin = Color3.fromRGB(255, 170, 30) },
	-- Zone 2: Coral Reef
	{ Name = "Coral Nibbler", Zone = 2, Rarity = "Common", Income = 1.0, Shape = "Fish", Pattern = "Belly", Feature = "None",
		Body = Color3.fromRGB(240, 120, 200), Accent = Color3.fromRGB(150, 90, 220), Fin = Color3.fromRGB(200, 80, 170) },
	{ Name = "Reefy Shrimp", Zone = 2, Rarity = "Common", Income = 1.5, Shape = "FishLong", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(255, 110, 90), Accent = Color3.fromRGB(255, 200, 180), Fin = Color3.fromRGB(230, 80, 70) },
	{ Name = "Parrot Pete", Zone = 2, Rarity = "Uncommon", Income = 4.5, Shape = "Fish", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(60, 200, 140), Accent = Color3.fromRGB(60, 140, 240), Fin = Color3.fromRGB(40, 160, 120) },
	{ Name = "Polka Puffer", Zone = 2, Rarity = "Uncommon", Income = 3.5, Shape = "Puffer", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(250, 250, 250), Accent = Color3.fromRGB(30, 30, 30), Fin = Color3.fromRGB(220, 220, 220) },
	{ Name = "Lionfish Larry", Zone = 2, Rarity = "Rare", Income = 11, Shape = "Fish", Pattern = "Stripes", Feature = "Spikes",
		Body = Color3.fromRGB(220, 60, 50), Accent = Color3.fromRGB(255, 240, 230), Fin = Color3.fromRGB(200, 50, 40) },
	{ Name = "Bloop Jelly", Zone = 2, Rarity = "Rare", Income = 12, Shape = "Jelly", Pattern = "None", Feature = "None",
		Body = Color3.fromRGB(255, 150, 210), Accent = Color3.fromRGB(255, 220, 240), Fin = Color3.fromRGB(255, 120, 200) },
	{ Name = "Rainbow Wrasse", Zone = 2, Rarity = "Epic", Income = 24, Shape = "FishLong", Pattern = "Rainbow", Feature = "None",
		Body = Color3.fromRGB(80, 170, 255), Accent = Color3.fromRGB(255, 80, 160), Fin = Color3.fromRGB(255, 200, 60) },
	{ Name = "Queen Angelfish", Zone = 2, Rarity = "Legendary", Income = 70, Shape = "FishFlat", Pattern = "Stripes", Feature = "Crown",
		Body = Color3.fromRGB(40, 90, 220), Accent = Color3.fromRGB(255, 220, 40), Fin = Color3.fromRGB(255, 200, 40) },
	-- Zone 3: Kelp Forest
	{ Name = "Kelp Crawler", Zone = 3, Rarity = "Uncommon", Income = 4.5, Shape = "Crab", Pattern = "Spots", Feature = "Leaves",
		Body = Color3.fromRGB(90, 150, 60), Accent = Color3.fromRGB(190, 220, 120), Fin = Color3.fromRGB(70, 120, 50) },
	{ Name = "Mossy Eel", Zone = 3, Rarity = "Uncommon", Income = 5.0, Shape = "Eel", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(120, 140, 60), Accent = Color3.fromRGB(190, 200, 110), Fin = Color3.fromRGB(90, 110, 40) },
	{ Name = "Garibaldi Gus", Zone = 3, Rarity = "Rare", Income = 15, Shape = "Fish", Pattern = "None", Feature = "None",
		Body = Color3.fromRGB(255, 120, 20), Accent = Color3.fromRGB(255, 200, 120), Fin = Color3.fromRGB(240, 100, 20) },
	{ Name = "Leafy Larry", Zone = 3, Rarity = "Rare", Income = 13, Shape = "Seahorse", Pattern = "None", Feature = "Leaves",
		Body = Color3.fromRGB(130, 190, 80), Accent = Color3.fromRGB(200, 230, 130), Fin = Color3.fromRGB(90, 160, 60) },
	{ Name = "Sneaky Octo", Zone = 3, Rarity = "Epic", Income = 35, Shape = "Squid", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(150, 80, 190), Accent = Color3.fromRGB(220, 170, 240), Fin = Color3.fromRGB(120, 60, 160) },
	{ Name = "Kelpie Ray", Zone = 3, Rarity = "Epic", Income = 39, Shape = "Ray", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(50, 110, 70), Accent = Color3.fromRGB(140, 200, 150), Fin = Color3.fromRGB(40, 90, 60) },
	{ Name = "Bob the Bass Drop", Zone = 3, Rarity = "Legendary", Income = 78, Shape = "FishBig", Pattern = "Stripes", Feature = "Headphones",
		Body = Color3.fromRGB(40, 180, 170), Accent = Color3.fromRGB(30, 30, 40), Fin = Color3.fromRGB(30, 140, 130) },
	{ Name = "Grove Guardian Grouper", Zone = 3, Rarity = "Mythic", Income = 230, Shape = "FishBig", Pattern = "Belly", Feature = "Crown",
		Body = Color3.fromRGB(60, 140, 70), Accent = Color3.fromRGB(240, 210, 90), Fin = Color3.fromRGB(40, 110, 60) },
	-- Zone 4: Shipwreck Bay
	{ Name = "Barnacle Bill", Zone = 4, Rarity = "Uncommon", Income = 6.0, Shape = "Fish", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(140, 130, 110), Accent = Color3.fromRGB(220, 210, 190), Fin = Color3.fromRGB(110, 100, 90) },
	{ Name = "Anchor Eel", Zone = 4, Rarity = "Rare", Income = 18, Shape = "Eel", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(150, 80, 50), Accent = Color3.fromRGB(90, 90, 100), Fin = Color3.fromRGB(120, 60, 40) },
	{ Name = "Rusty Crab", Zone = 4, Rarity = "Rare", Income = 19, Shape = "Crab", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(170, 80, 40), Accent = Color3.fromRGB(220, 140, 80), Fin = Color3.fromRGB(140, 60, 30) },
	{ Name = "Pirate Puffer", Zone = 4, Rarity = "Epic", Income = 42, Shape = "Puffer", Pattern = "Spots", Feature = "PirateHat",
		Body = Color3.fromRGB(230, 190, 120), Accent = Color3.fromRGB(40, 40, 40), Fin = Color3.fromRGB(200, 160, 90) },
	{ Name = "Treasure Tuna", Zone = 4, Rarity = "Epic", Income = 46, Shape = "FishLong", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(255, 200, 40), Accent = Color3.fromRGB(255, 240, 160), Fin = Color3.fromRGB(220, 160, 30) },
	{ Name = "Captain Flounder", Zone = 4, Rarity = "Legendary", Income = 130, Shape = "Ray", Pattern = "Spots", Feature = "Eyepatch",
		Body = Color3.fromRGB(170, 130, 90), Accent = Color3.fromRGB(240, 220, 190), Fin = Color3.fromRGB(140, 100, 70) },
	{ Name = "Ghost Mackerel", Zone = 4, Rarity = "Legendary", Income = 100, Shape = "Fish", Pattern = "Stripes", Feature = "Ghost",
		Body = Color3.fromRGB(190, 255, 220), Accent = Color3.fromRGB(240, 255, 250), Fin = Color3.fromRGB(150, 230, 200) },
	{ Name = "Davy Jones Jr.", Zone = 4, Rarity = "Mythic", Income = 300, Shape = "Squid", Pattern = "Spots", Feature = "PirateHat",
		Body = Color3.fromRGB(40, 140, 130), Accent = Color3.fromRGB(120, 220, 200), Fin = Color3.fromRGB(30, 110, 100) },
	-- Zone 5: Twilight Deep
	{ Name = "Dusk Minnow", Zone = 5, Rarity = "Rare", Income = 21, Shape = "FishSmall", Pattern = "Belly", Feature = "None",
		Body = Color3.fromRGB(140, 90, 220), Accent = Color3.fromRGB(220, 190, 255), Fin = Color3.fromRGB(110, 70, 190) },
	{ Name = "Glowworm Eel", Zone = 5, Rarity = "Rare", Income = 23, Shape = "Eel", Pattern = "GlowSpots", Feature = "None",
		Body = Color3.fromRGB(40, 50, 120), Accent = Color3.fromRGB(120, 255, 220), Fin = Color3.fromRGB(30, 40, 100) },
	{ Name = "Twilight Jelly", Zone = 5, Rarity = "Epic", Income = 63, Shape = "Jelly", Pattern = "GlowSpots", Feature = "None",
		Body = Color3.fromRGB(170, 110, 255), Accent = Color3.fromRGB(230, 200, 255), Fin = Color3.fromRGB(140, 90, 230) },
	{ Name = "Hatchet Harry", Zone = 5, Rarity = "Epic", Income = 54, Shape = "FishFlat", Pattern = "None", Feature = "None",
		Body = Color3.fromRGB(190, 200, 215), Accent = Color3.fromRGB(110, 120, 140), Fin = Color3.fromRGB(160, 170, 190) },
	{ Name = "Moonbeam Ray", Zone = 5, Rarity = "Legendary", Income = 150, Shape = "Ray", Pattern = "GlowSpots", Feature = "None",
		Body = Color3.fromRGB(150, 170, 220), Accent = Color3.fromRGB(240, 245, 255), Fin = Color3.fromRGB(120, 140, 200) },
	{ Name = "Sleepy Sunfish", Zone = 5, Rarity = "Legendary", Income = 160, Shape = "FishRound", Pattern = "None", Feature = "Nightcap",
		Body = Color3.fromRGB(150, 155, 170), Accent = Color3.fromRGB(220, 220, 230), Fin = Color3.fromRGB(120, 125, 140) },
	{ Name = "Vampire Squid", Zone = 5, Rarity = "Mythic", Income = 330, Shape = "Squid", Pattern = "None", Feature = "Fangs",
		Body = Color3.fromRGB(120, 20, 40), Accent = Color3.fromRGB(255, 80, 90), Fin = Color3.fromRGB(90, 10, 30) },
	{ Name = "Starlight Seraph", Zone = 5, Rarity = "Divine", Income = 930, Shape = "Jelly", Pattern = "Stars", Feature = "Halo",
		Body = Color3.fromRGB(255, 245, 210), Accent = Color3.fromRGB(255, 215, 90), Fin = Color3.fromRGB(255, 230, 160) },
	-- Zone 6: Midnight Trench
	{ Name = "Gulper Gus", Zone = 6, Rarity = "Epic", Income = 67, Shape = "FishRound", Pattern = "Belly", Feature = "Fangs",
		Body = Color3.fromRGB(40, 40, 60), Accent = Color3.fromRGB(200, 60, 80), Fin = Color3.fromRGB(30, 30, 45) },
	{ Name = "Fangtooth Fred", Zone = 6, Rarity = "Epic", Income = 74, Shape = "Fish", Pattern = "None", Feature = "Fangs",
		Body = Color3.fromRGB(70, 60, 80), Accent = Color3.fromRGB(150, 140, 160), Fin = Color3.fromRGB(50, 40, 60) },
	{ Name = "Midnight Eel", Zone = 6, Rarity = "Legendary", Income = 200, Shape = "Eel", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(30, 40, 90), Accent = Color3.fromRGB(90, 200, 255), Fin = Color3.fromRGB(20, 30, 70) },
	{ Name = "Ink Blot Octo", Zone = 6, Rarity = "Legendary", Income = 180, Shape = "Squid", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(30, 30, 35), Accent = Color3.fromRGB(120, 120, 140), Fin = Color3.fromRGB(20, 20, 25) },
	{ Name = "Frostfin Narwhal", Zone = 6, Rarity = "Mythic", Income = 490, Shape = "Whale", Pattern = "Spots", Feature = "Horn",
		Body = Color3.fromRGB(170, 220, 255), Accent = Color3.fromRGB(240, 250, 255), Fin = Color3.fromRGB(130, 190, 240) },
	{ Name = "Trench Dragon", Zone = 6, Rarity = "Mythic", Income = 530, Shape = "Eel", Pattern = "GlowSpots", Feature = "Spikes",
		Body = Color3.fromRGB(80, 40, 130), Accent = Color3.fromRGB(200, 120, 255), Fin = Color3.fromRGB(60, 30, 100) },
	{ Name = "Lumen Lord", Zone = 6, Rarity = "Divine", Income = 1000, Shape = "FishBig", Pattern = "GlowSpots", Feature = "Halo",
		Body = Color3.fromRGB(240, 250, 255), Accent = Color3.fromRGB(140, 220, 255), Fin = Color3.fromRGB(200, 230, 255) },
	{ Name = "Aurora Whale", Zone = 6, Rarity = "Celestial", Income = 3000, Shape = "Whale", Pattern = "Rainbow", Feature = "None",
		Body = Color3.fromRGB(40, 170, 150), Accent = Color3.fromRGB(150, 255, 200), Fin = Color3.fromRGB(60, 120, 200) },
	-- Zone 7: Hydrothermal Vents
	{ Name = "Vent Shrimp", Zone = 7, Rarity = "Epic", Income = 87, Shape = "FishSmall", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(230, 60, 40), Accent = Color3.fromRGB(255, 170, 120), Fin = Color3.fromRGB(200, 40, 30) },
	{ Name = "Lava Crab", Zone = 7, Rarity = "Legendary", Income = 240, Shape = "Crab", Pattern = "GlowSpots", Feature = "None",
		Body = Color3.fromRGB(240, 90, 30), Accent = Color3.fromRGB(255, 200, 60), Fin = Color3.fromRGB(200, 60, 20) },
	{ Name = "Smoky Snapper", Zone = 7, Rarity = "Legendary", Income = 270, Shape = "Fish", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(110, 110, 120), Accent = Color3.fromRGB(255, 130, 40), Fin = Color3.fromRGB(90, 90, 100) },
	{ Name = "Magma Puffer", Zone = 7, Rarity = "Mythic", Income = 570, Shape = "Puffer", Pattern = "GlowSpots", Feature = "None",
		Body = Color3.fromRGB(220, 60, 20), Accent = Color3.fromRGB(255, 190, 40), Fin = Color3.fromRGB(180, 40, 10) },
	{ Name = "Boiling Barracuda", Zone = 7, Rarity = "Mythic", Income = 630, Shape = "FishLong", Pattern = "Stripes", Feature = "Fangs",
		Body = Color3.fromRGB(240, 130, 40), Accent = Color3.fromRGB(255, 230, 150), Fin = Color3.fromRGB(210, 100, 30) },
	{ Name = "Inferno Angler", Zone = 7, Rarity = "Divine", Income = 1700, Shape = "Fish", Pattern = "GlowSpots", Feature = "Lure",
		Body = Color3.fromRGB(200, 40, 30), Accent = Color3.fromRGB(255, 220, 80), Fin = Color3.fromRGB(160, 30, 20) },
	{ Name = "Spicy Noodle Eel", Zone = 7, Rarity = "Divine", Income = 1300, Shape = "Eel", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(255, 190, 40), Accent = Color3.fromRGB(255, 80, 30), Fin = Color3.fromRGB(240, 150, 30) },
	{ Name = "Phoenix Ray", Zone = 7, Rarity = "Celestial", Income = 3900, Shape = "Ray", Pattern = "Rainbow", Feature = "Crown",
		Body = Color3.fromRGB(255, 110, 30), Accent = Color3.fromRGB(255, 230, 80), Fin = Color3.fromRGB(240, 60, 30) },
	-- Zone 8: The Abyss
	{ Name = "Angler Annie", Zone = 8, Rarity = "Legendary", Income = 280, Shape = "Fish", Pattern = "Spots", Feature = "Lure",
		Body = Color3.fromRGB(50, 80, 60), Accent = Color3.fromRGB(200, 255, 120), Fin = Color3.fromRGB(40, 60, 45) },
	{ Name = "Blobby the Blobfish", Zone = 8, Rarity = "Legendary", Income = 310, Shape = "Puffer", Pattern = "None", Feature = "None",
		Body = Color3.fromRGB(255, 170, 190), Accent = Color3.fromRGB(255, 210, 220), Fin = Color3.fromRGB(240, 140, 170) },
	{ Name = "Abyssal Gulper", Zone = 8, Rarity = "Mythic", Income = 860, Shape = "Eel", Pattern = "GlowSpots", Feature = "Fangs",
		Body = Color3.fromRGB(25, 25, 35), Accent = Color3.fromRGB(255, 60, 120), Fin = Color3.fromRGB(15, 15, 25) },
	{ Name = "Ghost Shark Pup", Zone = 8, Rarity = "Mythic", Income = 750, Shape = "FishLong", Pattern = "Belly", Feature = "SharkFin",
		Body = Color3.fromRGB(200, 210, 230), Accent = Color3.fromRGB(240, 245, 255), Fin = Color3.fromRGB(170, 180, 210) },
	{ Name = "Deep Sea Dragonfish", Zone = 8, Rarity = "Divine", Income = 2000, Shape = "Eel", Pattern = "GlowSpots", Feature = "Fangs",
		Body = Color3.fromRGB(20, 20, 30), Accent = Color3.fromRGB(120, 255, 255), Fin = Color3.fromRGB(10, 10, 20) },
	{ Name = "Kraken Jr.", Zone = 8, Rarity = "Divine", Income = 2200, Shape = "Squid", Pattern = "Spots", Feature = "Crown",
		Body = Color3.fromRGB(170, 30, 50), Accent = Color3.fromRGB(255, 140, 150), Fin = Color3.fromRGB(130, 20, 40) },
	{ Name = "Void Lantern", Zone = 8, Rarity = "Celestial", Income = 4300, Shape = "Jelly", Pattern = "Stars", Feature = "Lure",
		Body = Color3.fromRGB(60, 230, 255), Accent = Color3.fromRGB(200, 255, 255), Fin = Color3.fromRGB(40, 180, 230) },
	{ Name = "Abyss King Angler", Zone = 8, Rarity = "Cosmic", Income = 14000, Shape = "FishBig", Pattern = "Stars", Feature = "Lure",
		Body = Color3.fromRGB(70, 30, 120), Accent = Color3.fromRGB(190, 120, 255), Fin = Color3.fromRGB(50, 20, 90) },
	-- Zone 9: Leviathan's Lair
	{ Name = "Bone Fish", Zone = 9, Rarity = "Mythic", Income = 920, Shape = "Fish", Pattern = "Ribs", Feature = "None",
		Body = Color3.fromRGB(235, 230, 210), Accent = Color3.fromRGB(120, 110, 100), Fin = Color3.fromRGB(200, 195, 180) },
	{ Name = "Serpent Hatchling", Zone = 9, Rarity = "Mythic", Income = 1000, Shape = "Eel", Pattern = "Spots", Feature = "Spikes",
		Body = Color3.fromRGB(60, 140, 90), Accent = Color3.fromRGB(200, 230, 120), Fin = Color3.fromRGB(40, 110, 70) },
	{ Name = "Scaleback Leviathan", Zone = 9, Rarity = "Divine", Income = 2700, Shape = "Whale", Pattern = "Stripes", Feature = "Spikes",
		Body = Color3.fromRGB(30, 90, 100), Accent = Color3.fromRGB(120, 220, 210), Fin = Color3.fromRGB(20, 70, 80) },
	{ Name = "Titan Turtle", Zone = 9, Rarity = "Divine", Income = 2300, Shape = "Turtle", Pattern = "Spots", Feature = "Crown",
		Body = Color3.fromRGB(110, 110, 120), Accent = Color3.fromRGB(70, 160, 140), Fin = Color3.fromRGB(90, 90, 100) },
	{ Name = "Ancient Ammonite", Zone = 9, Rarity = "Celestial", Income = 6400, Shape = "Squid", Pattern = "Stripes", Feature = "Shell",
		Body = Color3.fromRGB(200, 150, 90), Accent = Color3.fromRGB(255, 230, 170), Fin = Color3.fromRGB(170, 120, 70) },
	{ Name = "Tidecaller Ray", Zone = 9, Rarity = "Celestial", Income = 7000, Shape = "Ray", Pattern = "Stars", Feature = "Halo",
		Body = Color3.fromRGB(30, 70, 200), Accent = Color3.fromRGB(120, 220, 255), Fin = Color3.fromRGB(20, 50, 170) },
	{ Name = "Elder Kraken", Zone = 9, Rarity = "Cosmic", Income = 15000, Shape = "Squid", Pattern = "Stars", Feature = "Crown",
		Body = Color3.fromRGB(110, 40, 160), Accent = Color3.fromRGB(255, 120, 240), Fin = Color3.fromRGB(80, 20, 120) },
	{ Name = "Leviathan Prime", Zone = 9, Rarity = "Secret", Income = 44000, Shape = "Eel", Pattern = "GlowSpots", Feature = "Horn",
		Body = Color3.fromRGB(20, 60, 70), Accent = Color3.fromRGB(80, 255, 200), Fin = Color3.fromRGB(10, 40, 50) },
	-- Zone 10: The Void Below
	{ Name = "Null Jelly", Zone = 10, Rarity = "Divine", Income = 2900, Shape = "Jelly", Pattern = "Stars", Feature = "None",
		Body = Color3.fromRGB(30, 30, 40), Accent = Color3.fromRGB(255, 255, 255), Fin = Color3.fromRGB(60, 60, 80) },
	{ Name = "Static Guppy", Zone = 10, Rarity = "Divine", Income = 3200, Shape = "FishSmall", Pattern = "Glitch", Feature = "None",
		Body = Color3.fromRGB(150, 150, 150), Accent = Color3.fromRGB(255, 255, 255), Fin = Color3.fromRGB(90, 90, 90) },
	{ Name = "Nebula Ray", Zone = 10, Rarity = "Celestial", Income = 8700, Shape = "Ray", Pattern = "Stars", Feature = "None",
		Body = Color3.fromRGB(150, 60, 220), Accent = Color3.fromRGB(255, 120, 200), Fin = Color3.fromRGB(110, 40, 180) },
	{ Name = "Starwhale", Zone = 10, Rarity = "Celestial", Income = 7600, Shape = "Whale", Pattern = "Stars", Feature = "Halo",
		Body = Color3.fromRGB(20, 30, 90), Accent = Color3.fromRGB(255, 240, 140), Fin = Color3.fromRGB(30, 50, 140) },
	{ Name = "Galaxy Puffer", Zone = 10, Rarity = "Cosmic", Income = 22000, Shape = "Puffer", Pattern = "Stars", Feature = "Spikes",
		Body = Color3.fromRGB(60, 20, 120), Accent = Color3.fromRGB(255, 140, 255), Fin = Color3.fromRGB(40, 10, 90) },
	{ Name = "Quasar Eel", Zone = 10, Rarity = "Cosmic", Income = 24000, Shape = "Eel", Pattern = "Rainbow", Feature = "Halo",
		Body = Color3.fromRGB(80, 240, 255), Accent = Color3.fromRGB(255, 255, 255), Fin = Color3.fromRGB(40, 180, 230) },
	{ Name = "The Void Itself", Zone = 10, Rarity = "Secret", Income = 49000, Shape = "Squid", Pattern = "Stars", Feature = "Crown",
		Body = Color3.fromRGB(10, 10, 15), Accent = Color3.fromRGB(255, 255, 255), Fin = Color3.fromRGB(25, 25, 35) },
	{ Name = "Glitch Fish", Zone = 10, Rarity = "Secret", Income = 57000, Shape = "Fish", Pattern = "Glitch", Feature = "Sunglasses",
		Body = Color3.fromRGB(255, 40, 200), Accent = Color3.fromRGB(40, 255, 120), Fin = Color3.fromRGB(80, 60, 255) },
}
Config.Fish = fish

---------------------------------------------------------------------------
-- HATCHING ODDS
-- Which fish comes out of an egg: only fish from the egg's zone. Each fish
-- RARITY gets a weight by how many steps it is away from the egg's rarity
-- (0 = same rarity, +1 = one rarer, -1 = one more common). Fish of the same
-- rarity share that weight equally. Rarities with no fish in that zone are
-- skipped. The full table is printed to Output when the server starts.
---------------------------------------------------------------------------
Config.Hatching = {
	RarityStepWeights = {
		[-2] = 3,
		[-1] = 12,
		[0] = 70,
		[1] = 12,
		[2] = 3,
	} :: { [number]: number },
	PrintOddsTable = true, -- print every zone's hatch odds when the server starts
}

---------------------------------------------------------------------------
-- EGG LOOKS
-- Every egg is a blocky egg in its rarity's color, with a pattern per rarity
-- and a little detail from its zone (Config.Zones[...].EggDetail).
-- Patterns: Spots, Stripes, Swirl, Zigzag, Cracks, Crystals, Wings, Stars,
-- Galaxy, Glitch. Rarer eggs glow and sparkle more (same rules as fish).
-- A model named "Egg<Rarity>" (e.g. "EggLegendary") or "Egg" in
-- ReplicatedStorage.Assets replaces the built-in egg.
---------------------------------------------------------------------------
local eggLooks: { [string]: EggLook } = {
	Common = { Pattern = "Spots", Accent = Color3.fromRGB(140, 140, 150) },
	Uncommon = { Pattern = "Stripes", Accent = Color3.fromRGB(240, 255, 240) },
	Rare = { Pattern = "Swirl", Accent = Color3.fromRGB(200, 230, 255) },
	Epic = { Pattern = "Zigzag", Accent = Color3.fromRGB(240, 200, 255) },
	Legendary = { Pattern = "Cracks", Accent = Color3.fromRGB(255, 250, 200) },
	Mythic = { Pattern = "Crystals", Accent = Color3.fromRGB(255, 180, 210) },
	Divine = { Pattern = "Wings", Accent = Color3.fromRGB(255, 255, 255) },
	Celestial = { Pattern = "Stars", Accent = Color3.fromRGB(255, 255, 255) },
	Cosmic = { Pattern = "Galaxy", Accent = Color3.fromRGB(255, 120, 230) },
	Secret = { Pattern = "Glitch", Accent = Color3.fromRGB(0, 255, 200) },
}
Config.EggLooks = eggLooks

-- Which rarities get which effect (on fish AND eggs).
Config.RarityEffects = {
	GlowFrom = "Rare", -- a soft light
	SparklesFrom = "Legendary", -- sparkle particles
	AuraFrom = "Mythic", -- a glowing aura
	CosmicFrom = "Celestial", -- color-shifting fins/details + cosmic particles
	-- Particle textures (built into Roblox). Swap for your own image IDs if you like.
	SparkleTexture = "rbxasset://textures/particles/sparkles_main.dds",
	AuraTexture = "rbxasset://textures/particles/smoke_main.dds",
	-- To keep the game fast, effects and animations far from the camera are
	-- switched off (studs).
	EffectsDistance = 110,
	AnimateDistance = 140,
	Outlines = true, -- thin dark edges on the main blocks of fish, eggs and sharks
}

Config.PetDisplay = {
	HoverHeight = 1.2, -- gap between the pad and the lowest point of a floating fish (studs)
	SizePerRarity = 0.1, -- each rarity tier makes a fish 10% bigger (Secret = 1.9x)
	-- Hatching a pet of this rarity or better is announced to the whole server.
	AnnounceFrom = "Legendary",
	RevealSeconds = 3, -- how long the "You hatched ...!" card stays on screen
}

---------------------------------------------------------------------------
-- ECONOMY
---------------------------------------------------------------------------
Config.Economy = {
	StartingMoney = 0,
	IncomeTickInterval = 1, -- pets pay out every this many seconds
	-- "Pad"  = money piles up on the plot; step on the green collect pad to take it
	-- "Auto" = money goes straight to the player
	CollectMode = "Pad",
	CollectPadSize = Vector3.new(8, 0.4, 8),
	SellValueSeconds = 60, -- selling a pet gives this many seconds of its income
}

---------------------------------------------------------------------------
-- SAVING (DataService)
-- Saved: money (incl. money waiting on the collect pad), Speed stat,
-- treadmill tier, pads bought, and every egg/pet on your pads.
---------------------------------------------------------------------------
Config.Data = {
	-- DataStore names. Studio uses a SEPARATE store, so testing in Studio
	-- never touches real players' progress. Changing a name = everyone
	-- starts fresh (old data stays in the old store).
	StoreName = "PlayerData_v1",
	StudioStoreName = "PlayerData_Studio_v1",
	AutoSaveInterval = 60, -- seconds between automatic saves of every player
	MaxRetries = 4, -- how often a failed DataStore call is retried
	RetryDelay = 2, -- seconds before the first retry (doubles each time)
	-- Session lock: while you play on one server, your data is "locked" to it,
	-- so two servers can never overwrite each other's progress.
	LockRetries = 5, -- tries to open data that is still locked by another server
	LockRetryDelay = 6, -- seconds between those tries
	-- A lock older than this belongs to a crashed server and may be taken over.
	-- Must be bigger than AutoSaveInterval (every save refreshes the lock).
	LockStaleSeconds = 300,
}

---------------------------------------------------------------------------
-- UPGRADES
-- Bought with money:
--   - Plot space: +1 pad per purchase, up to Plots.PadsPerSide * 2.
--     Price of the next pad = Base * Growth ^ (pads bought so far)
--   - Treadmill: the next tier in Config.Treadmill.Tiers (each has its Price).
--   - Pet level: press E on one of your pets. Sell with F (hold).
---------------------------------------------------------------------------
Config.Upgrades = {
	Pads = { Base = 500, Growth = 2.5 }, -- 500, 1.25K, 3.1K, 7.8K for pads 7..10
	-- Fish levels (press E on your fish, or use the Fish panel):
	--   income at level L = base income * IncomeGrowth ^ (L - 1)
	--     (1.12 -> every level +12% on top of the last; level 10 = 2.8x,
	--      level 20 = 8.6x, level 30 = 26.7x the base income)
	--   price of L -> L+1 = base income * PriceIncomeSeconds * PriceGrowth ^ (L - 1)
	--     An upgrade pays for itself in about 1.5 minutes at low levels and
	--     about 4 minutes near the max: usually a better deal than waiting for
	--     a new egg, but it still costs real money.
	PetLevel = {
		MaxLevel = 30,
		IncomeGrowth = 1.12,
		PriceIncomeSeconds = 10, -- level 1->2 costs 10 seconds of the fish's base income
		PriceGrowth = 1.16, -- each further level costs 16% more
		-- Fish grow a little with every level: size = SizeAtLevel1 + SizePerLevel * (L - 1)
		-- Pads and plots are big enough for max-level fish (Config.Plots).
		SizeAtLevel1 = 0.7,
		SizePerLevel = 0.0483, -- level 30 = 0.7 + 29 * 0.0483 = 2.1 (3x level 1)
		GrowSeconds = 0.35, -- how long the grow animation takes after an upgrade
	},
}

-- The price formula used by level-based upgrades (plot space).
function Config.UpgradePrice(base: number, growth: number, currentLevel: number): number
	return math.floor(base * growth ^ currentLevel + 0.5)
end

-- A pet's income per second at a given level.
function Config.PetIncome(baseIncome: number, level: number): number
	return baseIncome * Config.Upgrades.PetLevel.IncomeGrowth ^ (level - 1)
end

-- How big a fish is at a level (1 = the size of its rarity's model).
function Config.PetSizeAtLevel(level: number): number
	local petLevel = Config.Upgrades.PetLevel
	return petLevel.SizeAtLevel1 + petLevel.SizePerLevel * (math.clamp(level, 1, petLevel.MaxLevel) - 1)
end

-- Price to raise a pet from `level` to `level + 1`.
function Config.PetUpgradePrice(baseIncome: number, level: number): number
	local petLevel = Config.Upgrades.PetLevel
	return math.max(1, math.floor(baseIncome * petLevel.PriceIncomeSeconds * petLevel.PriceGrowth ^ (level - 1) + 0.5))
end

-- Money you get for selling a pet: SellValueSeconds of its current income.
function Config.PetSellValue(baseIncome: number, level: number): number
	return math.max(1, math.floor(Config.PetIncome(baseIncome, level) * Config.Economy.SellValueSeconds + 0.5))
end

---------------------------------------------------------------------------
-- SHOP (the 🛒 Shop button)
-- Only Robux items, plus the free Daily Gift. The Robux items are wired up
-- in the Monetization milestone; until then they show "Coming soon".
-- Id = the game pass / developer product ID from the Creator Dashboard
-- (0 = not created yet). PriceRobux is only shown to players.
---------------------------------------------------------------------------
export type ShopItem = {
	Key: string, -- internal name (used in code and saves)
	Name: string,
	Description: string,
	Icon: string, -- an emoji
	Tab: string, -- "Passes", "Boosts" or "Cash"
	Kind: string, -- "Pass" (buy once) or "Product" (buy again and again)
	PriceRobux: number,
	Id: number,
	Color: Color3, -- card color
}
local shopItems: { ShopItem } = {
	{ Key = "DoubleMoney", Name = "2x Money", Description = "All your fish earn double, forever!", Icon = "💰", Tab = "Passes", Kind = "Pass", PriceRobux = 199, Id = 0, Color = Color3.fromRGB(70, 190, 90) },
	{ Key = "DoubleSpeed", Name = "2x Speed", Description = "Twice the Speed from every treadmill!", Icon = "👟", Tab = "Passes", Kind = "Pass", PriceRobux = 249, Id = 0, Color = Color3.fromRGB(60, 150, 240) },
	{ Key = "VIP", Name = "VIP", Description = "VIP tag, extra pad and a little more luck.", Icon = "👑", Tab = "Passes", Kind = "Pass", PriceRobux = 299, Id = 0, Color = Color3.fromRGB(240, 180, 40) },
	{ Key = "Skins", Name = "Skins Pass", Description = "Unlock cool treadmill and pad skins.", Icon = "🎨", Tab = "Passes", Kind = "Pass", PriceRobux = 149, Id = 0, Color = Color3.fromRGB(200, 90, 230) },
	{ Key = "MorePads", Name = "+2 Pads", Description = "Two extra pads on your plot.", Icon = "🟩", Tab = "Passes", Kind = "Pass", PriceRobux = 179, Id = 0, Color = Color3.fromRGB(80, 200, 150) },
	{ Key = "AutoCollect", Name = "Auto Collect", Description = "Money goes straight to you.", Icon = "🧲", Tab = "Passes", Kind = "Pass", PriceRobux = 129, Id = 0, Color = Color3.fromRGB(240, 110, 80) },
	{ Key = "FastHatch", Name = "Faster Hatching", Description = "Eggs hatch twice as fast.", Icon = "⏩", Tab = "Passes", Kind = "Pass", PriceRobux = 149, Id = 0, Color = Color3.fromRGB(90, 120, 240) },
	{ Key = "Lucky", Name = "Lucky Pass", Description = "Better odds for rare fish.", Icon = "🍀", Tab = "Passes", Kind = "Pass", PriceRobux = 249, Id = 0, Color = Color3.fromRGB(60, 200, 90) },
	{ Key = "Money15", Name = "2x Money (15 min)", Description = "Double money for 15 minutes. Stacks!", Icon = "💸", Tab = "Boosts", Kind = "Product", PriceRobux = 39, Id = 0, Color = Color3.fromRGB(70, 190, 90) },
	{ Key = "Luck15", Name = "2x Luck (15 min)", Description = "Double luck for 15 minutes. Stacks!", Icon = "🍀", Tab = "Boosts", Kind = "Product", PriceRobux = 39, Id = 0, Color = Color3.fromRGB(60, 200, 90) },
	{ Key = "InstantHatch", Name = "Instant Hatch", Description = "All eggs on your pads are READY now.", Icon = "🥚", Tab = "Boosts", Kind = "Product", PriceRobux = 29, Id = 0, Color = Color3.fromRGB(240, 90, 90) },
	{ Key = "ServerLuck", Name = "Server Luck", Description = "Luck boost for EVERYONE in the server!", Icon = "🌟", Tab = "Boosts", Kind = "Product", PriceRobux = 99, Id = 0, Color = Color3.fromRGB(240, 200, 60) },
	{ Key = "BotFreeze", Name = "Shark Freeze", Description = "Freeze every shark for 30 seconds.", Icon = "🧊", Tab = "Boosts", Kind = "Product", PriceRobux = 49, Id = 0, Color = Color3.fromRGB(110, 200, 250) },
	{ Key = "CashSmall", Name = "Pile of Cash", Description = "A pile of money (grows with your progress).", Icon = "💵", Tab = "Cash", Kind = "Product", PriceRobux = 25, Id = 0, Color = Color3.fromRGB(70, 190, 90) },
	{ Key = "CashMedium", Name = "Bag of Cash", Description = "A bag of money (grows with your progress).", Icon = "💰", Tab = "Cash", Kind = "Product", PriceRobux = 79, Id = 0, Color = Color3.fromRGB(60, 170, 80) },
	{ Key = "CashLarge", Name = "Vault of Cash", Description = "A vault of money (grows with your progress).", Icon = "🏦", Tab = "Cash", Kind = "Product", PriceRobux = 199, Id = 0, Color = Color3.fromRGB(50, 150, 70) },
}
Config.Shop = {
	Tabs = { "Daily", "Passes", "Boosts", "Cash" },
	Items = shopItems,
}

---------------------------------------------------------------------------
-- DAILY GIFT (free, in the Shop): claim once every Cooldown seconds.
-- One random reward. Cash and Speed grow with your progress: Cash = this many
-- seconds of your fish income, Speed = this many seconds on your treadmill.
---------------------------------------------------------------------------
export type DailyReward = { Kind: string, Weight: number, Seconds: number?, Minimum: number?, Rarity: string? }
local dailyRewards: { DailyReward } = {
	{ Kind = "Cash", Weight = 45, Seconds = 300, Minimum = 500 },
	{ Kind = "Speed", Weight = 40, Seconds = 300, Minimum = 300 },
	{ Kind = "Egg", Weight = 15, Rarity = "Rare" }, -- goes into your egg hotbar (cash instead if it's full)
}
Config.DailyGift = {
	Cooldown = 24 * 60 * 60,
	Rewards = dailyRewards,
}

---------------------------------------------------------------------------
-- INDEX (the 📖 Index button): every fish you've ever hatched is "found".
-- Each newly found fish has a small reward to claim, and finding all 8 fish
-- of a zone unlocks a bigger zone reward.
---------------------------------------------------------------------------
Config.Index = {
	FishCashSeconds = 60, -- cash reward = this many seconds of the fish's income
	FishSpeedBase = 60, -- Speed reward for a zone-1 fish (grows deeper and rarer)
	ZoneCashSeconds = 300, -- zone reward = this many seconds of ALL 8 fish's income together
	ZoneSpeedBase = 1000, -- Speed reward for completing zone 1 (grows deeper)
	SpeedGrowthPerZone = 2.2, -- each deeper zone's Speed rewards are this much bigger
}

-- What finding a fish gives: (cash, speed).
function Config.IndexFishReward(fish: FishConfig): (number, number)
	local index = Config.Index
	local rank = 1
	for i, info in Config.Rarities do
		if info.Name == fish.Rarity then
			rank = i
		end
	end
	local cash = math.floor(fish.Income * index.FishCashSeconds + 0.5)
	local speed = math.floor(index.FishSpeedBase * index.SpeedGrowthPerZone ^ (fish.Zone - 1) * (1 + (rank - 1) * 0.25) + 0.5)
	return cash, speed
end

-- What completing a zone gives: (cash, speed).
function Config.IndexZoneReward(zoneIndex: number): (number, number)
	local index = Config.Index
	local total = 0
	for _, fish in Config.Fish do
		if fish.Zone == zoneIndex then
			total += fish.Income
		end
	end
	local cash = math.floor(total * index.ZoneCashSeconds + 0.5)
	local speed = math.floor(index.ZoneSpeedBase * index.SpeedGrowthPerZone ^ (zoneIndex - 1) + 0.5)
	return cash, speed
end

---------------------------------------------------------------------------
-- BALANCE TABLE (calculated, not typed by hand)
-- The real challenge: steal an egg and reach the START (shallow edge) of its
-- zone before that zone's shark catches you (caught after that, the egg
-- only drops). The recommended Speed is calculated from that race:
--   - the shark starts on its patrol line (Bots.PatrolLineInset from the deep edge)
--   - you start at an average egg spot, Balance.PlayerStartFraction into the zone
--   - you win if you reach the start edge before the shark gets within
--     Bots.CatchDistance of it:
--       your walk speed >= shark speed * (your distance / shark's distance) + OutrunMargin
-- Printed to Output when the server starts, and shown on the zone signs.
-- Change Config.Sharks speeds, the zone length or Config.Speed to rebalance.
---------------------------------------------------------------------------
Config.Balance = {
	PlayerStartFraction = 0.75, -- average egg position (0 = zone start, 1 = deep edge)
	-- How much room the recommended Speed leaves you: 0.01 = the shark is set
	-- 1% slower than "exactly a tie", so at the recommended Speed you just
	-- barely cross the zone's start line, and it catches you shortly after.
	-- Note: 80% of a Speed STAT is only 2-7% less WALK speed (walk speed grows
	-- slowly with the stat), so this has to be small for 80% to get caught.
	EscapeSlack = 0.01,
	-- On average the shark is this far to the side of the egg when the egg is
	-- stolen (it patrols the whole width): 2/3 of half the patrol line.
	AverageSideOffset = (Config.World.DangerZoneWidth / 2 - Config.Bots.PatrolEdgeMargin) * 2 / 3,
}


-- How much farther the shark has to swim than you have to run, in the race
-- to the zone's start line.
local function raceRatio(zoneIndex: number): number
	local zone = Config.Zones[zoneIndex]
	local shark = Config.Sharks[zoneIndex]
	local playerDistance = zone.Length * Config.Balance.PlayerStartFraction
	local deep = zone.Length - Config.Bots.PatrolLineInset
	local side = Config.Balance.AverageSideOffset
	local sharkDistance = math.sqrt(deep * deep + side * side) - Config.Bots.CatchDistance * shark.Scale
	return math.max(sharkDistance, 1) / playerDistance
end

-- The walk speed you need to escape zone `zoneIndex`'s shark to the zone's start.
function Config.RecommendedWalkSpeed(zoneIndex: number): number
	local zone = Config.Zones[zoneIndex]
	local shark = Config.Sharks[zoneIndex]
	if not (zone and shark) then
		return 0
	end
	return shark.Speed / raceRatio(zoneIndex)
end

-- Sharks with a RecommendedSpeed get their speed from it: the walk speed at
-- that Speed stat, times the race ratio, minus the slack. So the number on
-- the sign is always enough (it never lies).
for zoneIndex, shark in Config.Sharks do
	if shark.RecommendedSpeed then
		local walk = Config.WalkSpeedFromStat(shark.RecommendedSpeed)
		shark.Speed = math.floor(walk * raceRatio(zoneIndex) * (1 - Config.Balance.EscapeSlack) * 10) / 10
	end
end

for zoneIndex, shark in Config.Sharks do
	local needed = shark.RecommendedSpeed or Config.StatNeededForWalkSpeed(Config.RecommendedWalkSpeed(zoneIndex))
	shark.SpeedStatNeeded = needed
	local gainPerMinute = treadmillTiers[1].Gain / Config.Treadmill.GainInterval * 60
	shark.MinutesAtTier1 = needed / gainPerMinute
end

return Config
