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
	-- Fixed internal ID: saves and the Index store THIS, so a fish can be
	-- renamed (Name) without anyone losing it. Never change an Id.
	Id: string,
	Name: string, -- the name players see
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
-- Players have a Speed STAT that grows on the treadmill. Their WalkSpeed:
--
--   speedPart = Factor * SpeedStat ^ Exponent
--   WalkSpeed = (BaseWalkSpeed^Blend + speedPart^Blend) ^ (1/Blend), at most MaxWalkSpeed
--
-- In words: walk speed is about Factor * Speed^0.55, but never below the
-- normal 16 (the "Blend" smoothly joins the two). With these numbers:
--   0 -> 16,   8.1K -> 25,   34K -> 53,   110K -> 101,   270K -> 165,   340K -> 210 (cap)
-- Why not a straight line: with treadmills that are each ~1.6x stronger,
-- the Speed needed per zone has to grow ~1.6x per zone too. A straight
-- line would then make deep zones need impossible walk speeds. Exponent
-- 0.55 keeps the 80% rule at EVERY zone: 80% of a zone's Speed always means
-- ~11.5% less walk speed, so its shark catches you well inside the zone.
---------------------------------------------------------------------------
Config.Speed = {
	StartingStat = 0,
	BaseWalkSpeed = 16, -- a brand-new player (Roblox's default)
	Factor = 0.17,
	Exponent = 0.55,
	Blend = 4, -- how smoothly the normal speed (16) turns into the Speed-based part
	MaxWalkSpeed = 210, -- hard cap (a bit faster than the deepest shark, so top treadmills still help)
	-- "Outrunning" a shark means walking at least this much faster than it.
	OutrunMargin = 0.5,
}

-- WalkSpeed for a given Speed stat (before carry slow-downs).
function Config.WalkSpeedFromStat(stat: number): number
	local speed = Config.Speed
	local part = speed.Factor * math.max(stat, 0) ^ speed.Exponent
	local walk = (speed.BaseWalkSpeed ^ speed.Blend + part ^ speed.Blend) ^ (1 / speed.Blend)
	return math.min(walk, speed.MaxWalkSpeed)
end

-- The reverse: the Speed stat needed to reach a WalkSpeed. math.huge if the
-- cap makes it impossible.
function Config.StatNeededForWalkSpeed(walkSpeed: number): number
	local speed = Config.Speed
	if walkSpeed <= speed.BaseWalkSpeed then
		return 0
	end
	if walkSpeed > speed.MaxWalkSpeed then
		return math.huge
	end
	local part = (walkSpeed ^ speed.Blend - speed.BaseWalkSpeed ^ speed.Blend) ^ (1 / speed.Blend)
	return math.ceil((part / speed.Factor) ^ (1 / speed.Exponent))
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
		Name = "Basic", Price = 0, Gain = 30,
		FrameColor = Color3.fromRGB(205, 205, 212), FrameMaterial = Enum.Material.SmoothPlastic,
		BeltColor = Color3.fromRGB(45, 45, 52), ChevronColor = Color3.fromRGB(235, 235, 240), ChevronNeon = false,
		AccentColor = nil, ScreenColor = Color3.fromRGB(80, 220, 255), Light = 0, Effect = "None", Rainbow = false,
	},
	{
		Name = "Bronze", Price = 2_500, Gain = 50,
		FrameColor = Color3.fromRGB(205, 127, 50), FrameMaterial = Enum.Material.Metal,
		BeltColor = Color3.fromRGB(50, 35, 25), ChevronColor = Color3.fromRGB(255, 170, 90), ChevronNeon = false,
		AccentColor = nil, ScreenColor = Color3.fromRGB(255, 170, 90), Light = 0, Effect = "None", Rainbow = false,
	},
	{
		Name = "Silver", Price = 15_000, Gain = 80,
		FrameColor = Color3.fromRGB(200, 205, 215), FrameMaterial = Enum.Material.DiamondPlate,
		BeltColor = Color3.fromRGB(40, 45, 55), ChevronColor = Color3.fromRGB(230, 240, 255), ChevronNeon = true,
		AccentColor = nil, ScreenColor = Color3.fromRGB(200, 230, 255), Light = 0, Effect = "None", Rainbow = false,
	},
	{
		Name = "Gold", Price = 80_000, Gain = 125,
		FrameColor = Color3.fromRGB(255, 200, 60), FrameMaterial = Enum.Material.Foil,
		BeltColor = Color3.fromRGB(60, 45, 20), ChevronColor = Color3.fromRGB(255, 230, 120), ChevronNeon = true,
		AccentColor = Color3.fromRGB(255, 215, 80), ScreenColor = Color3.fromRGB(255, 230, 120), Light = 1, Effect = "None", Rainbow = false,
	},
	{
		Name = "Emerald", Price = 400_000, Gain = 200,
		FrameColor = Color3.fromRGB(40, 190, 110), FrameMaterial = Enum.Material.Glass,
		BeltColor = Color3.fromRGB(15, 50, 35), ChevronColor = Color3.fromRGB(120, 255, 170), ChevronNeon = true,
		AccentColor = Color3.fromRGB(80, 255, 150), ScreenColor = Color3.fromRGB(120, 255, 170), Light = 1.5, Effect = "Sparkles", Rainbow = false,
	},
	{
		Name = "Diamond", Price = 6_000_000, Gain = 320,
		FrameColor = Color3.fromRGB(170, 235, 255), FrameMaterial = Enum.Material.Glass,
		BeltColor = Color3.fromRGB(20, 40, 60), ChevronColor = Color3.fromRGB(150, 240, 255), ChevronNeon = true,
		AccentColor = Color3.fromRGB(120, 230, 255), ScreenColor = Color3.fromRGB(180, 245, 255), Light = 2, Effect = "Sparkles", Rainbow = false,
	},
	{
		Name = "Neon", Price = 30_000_000, Gain = 500,
		FrameColor = Color3.fromRGB(25, 25, 35), FrameMaterial = Enum.Material.SmoothPlastic,
		BeltColor = Color3.fromRGB(10, 10, 15), ChevronColor = Color3.fromRGB(255, 60, 220), ChevronNeon = true,
		AccentColor = Color3.fromRGB(0, 255, 255), ScreenColor = Color3.fromRGB(255, 60, 220), Light = 2.5, Effect = "Stars", Rainbow = false,
	},
	{
		Name = "Magma", Price = 150_000_000, Gain = 800,
		FrameColor = Color3.fromRGB(60, 30, 25), FrameMaterial = Enum.Material.Basalt,
		BeltColor = Color3.fromRGB(30, 10, 5), ChevronColor = Color3.fromRGB(255, 120, 20), ChevronNeon = true,
		AccentColor = Color3.fromRGB(255, 90, 0), ScreenColor = Color3.fromRGB(255, 140, 40), Light = 3, Effect = "Fire", Rainbow = false,
	},
	{
		Name = "Rainbow", Price = 750_000_000, Gain = 1300,
		FrameColor = Color3.fromRGB(255, 255, 255), FrameMaterial = Enum.Material.SmoothPlastic,
		BeltColor = Color3.fromRGB(25, 25, 30), ChevronColor = Color3.fromRGB(255, 255, 255), ChevronNeon = true,
		AccentColor = Color3.fromRGB(255, 255, 255), ScreenColor = Color3.fromRGB(255, 255, 255), Light = 3, Effect = "Sparkles", Rainbow = true,
	},
	{
		Name = "Cosmic", Price = 4_500_000_000, Gain = 2000,
		FrameColor = Color3.fromRGB(40, 20, 80), FrameMaterial = Enum.Material.Glass,
		BeltColor = Color3.fromRGB(5, 0, 20), ChevronColor = Color3.fromRGB(190, 120, 255), ChevronNeon = true,
		AccentColor = Color3.fromRGB(150, 80, 255), ScreenColor = Color3.fromRGB(220, 180, 255), Light = 4, Effect = "Stars", Rainbow = false,
	},
}

-- Each tier is ~1.6x the one before (Cosmic = 67x Basic). With the tier you
-- normally own when you reach a zone, training for it takes a few minutes.
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
	PlotStudTransparency = 0.12, -- plots get stronger studs, so they look properly blocky
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
	PadsPerSide = 5, -- per floor, so 10 pads per floor (20 with the second floor)
	-- The second floor (built by a plot upgrade): walkways along both sides
	-- (where its pads are) and across the back, stairs in the middle. The
	-- middle stays open so you can still see the fish downstairs.
	SecondFloorHeight = 16, -- studs above the ground floor (big fish fit below)
	SecondFloorDeckWidth = 17, -- width of the side walkways
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

	-- Eggs on a pad slowly GROW while they count down, reaching this size
	-- (times normal) when they're READY. Rarer eggs get huge. They grow
	-- upward from the pad, and may overlap neighbouring pads on purpose.
	GrowByRarity = {
		Common = 1.5,
		Uncommon = 1.78,
		Rare = 2.06,
		Epic = 2.33,
		Legendary = 2.61,
		Mythic = 2.89,
		Divine = 3.17,
		Celestial = 3.44,
		Cosmic = 3.72,
		Secret = 4,
	} :: { [string]: number },

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
	{ RecommendedSpeed = 8_100, Speed = 0, Count = 1, Color = Color3.fromRGB(95, 125, 165), Belly = Color3.fromRGB(235, 240, 245),
		Scale = 1, EyeColor = Color3.fromRGB(20, 20, 25), GlowEyes = false, Scars = 0, Spikes = false },
	-- 3 Kelp Forest: green camouflage
	{ RecommendedSpeed = 19_000, Speed = 0, Count = 1, Color = Color3.fromRGB(80, 115, 85), Belly = Color3.fromRGB(215, 225, 190),
		Scale = 1.05, EyeColor = Color3.fromRGB(20, 20, 25), GlowEyes = false, Scars = 1, Spikes = false },
	-- 4 Shipwreck Bay: rusty and scarred
	{ RecommendedSpeed = 34_000, Speed = 0, Count = 1, Color = Color3.fromRGB(120, 100, 85), Belly = Color3.fromRGB(220, 205, 180),
		Scale = 1.1, EyeColor = Color3.fromRGB(20, 20, 25), GlowEyes = false, Scars = 2, Spikes = false },
	-- 5 Twilight Deep: purple, eyes start glowing
	{ RecommendedSpeed = 53_000, Speed = 0, Count = 1, Color = Color3.fromRGB(80, 65, 140), Belly = Color3.fromRGB(190, 180, 225),
		Scale = 1.15, EyeColor = Color3.fromRGB(255, 240, 120), GlowEyes = true, Scars = 1, Spikes = false },
	-- 6 Midnight Trench
	{ RecommendedSpeed = 77_000, Speed = 0, Count = 1, Color = Color3.fromRGB(40, 45, 80), Belly = Color3.fromRGB(150, 160, 200),
		Scale = 1.2, EyeColor = Color3.fromRGB(120, 220, 255), GlowEyes = true, Scars = 2, Spikes = false },
	-- 7 Hydrothermal Vents: charcoal with lava eyes
	{ RecommendedSpeed = 110_000, Speed = 0, Count = 1, Color = Color3.fromRGB(70, 35, 30), Belly = Color3.fromRGB(150, 100, 80),
		Scale = 1.3, EyeColor = Color3.fromRGB(255, 120, 30), GlowEyes = true, Scars = 2, Spikes = true },
	-- 8 The Abyss
	{ RecommendedSpeed = 150_000, Speed = 0, Count = 1, Color = Color3.fromRGB(28, 22, 45), Belly = Color3.fromRGB(90, 80, 120),
		Scale = 1.4, EyeColor = Color3.fromRGB(255, 40, 60), GlowEyes = true, Scars = 3, Spikes = true },
	-- 9 Leviathan's Lair
	{ RecommendedSpeed = 200_000, Speed = 0, Count = 1, Color = Color3.fromRGB(20, 50, 50), Belly = Color3.fromRGB(80, 130, 120),
		Scale = 1.5, EyeColor = Color3.fromRGB(80, 255, 160), GlowEyes = true, Scars = 3, Spikes = true },
	-- 10 The Void Below: biggest and darkest
	{ RecommendedSpeed = 270_000, Speed = 0, Count = 1, Color = Color3.fromRGB(12, 10, 20), Belly = Color3.fromRGB(60, 40, 90),
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
-- Id = fixed internal ID (saves/Index use it; it was the fish's first name).
-- Name = what players see; rename freely.
-- Looks (all built from blocks; a model in ReplicatedStorage.Assets with the
-- fish's exact Name, or its Id, replaces the built-in one):
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
	{ Id = "Clowny Clownfish", Name = "Sir Splashalot", Zone = 1, Rarity = "Common", Income = 1.0, Shape = "Fish", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(255, 140, 40), Accent = Color3.fromRGB(255, 255, 255), Fin = Color3.fromRGB(30, 30, 30) },
	{ Id = "Pinchy Crab", Name = "Snapclaw", Zone = 1, Rarity = "Common", Income = 1.0, Shape = "Crab", Pattern = "None", Feature = "None",
		Body = Color3.fromRGB(240, 110, 60), Accent = Color3.fromRGB(255, 200, 150), Fin = Color3.fromRGB(200, 70, 40) },
	{ Id = "Starla Starfish", Name = "Coral Star", Zone = 1, Rarity = "Common", Income = 1.0, Shape = "Star", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(255, 130, 170), Accent = Color3.fromRGB(255, 220, 230), Fin = Color3.fromRGB(230, 90, 140) },
	{ Id = "Guppy McGuppface", Name = "Zippy Guppfin", Zone = 1, Rarity = "Uncommon", Income = 3.0, Shape = "FishSmall", Pattern = "Belly", Feature = "None",
		Body = Color3.fromRGB(80, 200, 255), Accent = Color3.fromRGB(255, 255, 255), Fin = Color3.fromRGB(40, 140, 220) },
	{ Id = "Bubble Puffer", Name = "Puffstorm", Zone = 1, Rarity = "Uncommon", Income = 3.0, Shape = "Puffer", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(255, 220, 80), Accent = Color3.fromRGB(255, 255, 200), Fin = Color3.fromRGB(220, 170, 40) },
	{ Id = "Shelly Turtle", Name = "Shellguard", Zone = 1, Rarity = "Rare", Income = 9.0, Shape = "Turtle", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(110, 190, 90), Accent = Color3.fromRGB(170, 120, 70), Fin = Color3.fromRGB(80, 150, 70) },
	{ Id = "Sea Biscuit", Name = "Driftwing", Zone = 1, Rarity = "Rare", Income = 7.5, Shape = "Seahorse", Pattern = "Belly", Feature = "None",
		Body = Color3.fromRGB(255, 200, 60), Accent = Color3.fromRGB(255, 240, 180), Fin = Color3.fromRGB(230, 150, 40) },
	{ Id = "Sunbeam Tang", Name = "Solar Tang", Zone = 1, Rarity = "Epic", Income = 22, Shape = "FishFlat", Pattern = "None", Feature = "Sunglasses",
		Body = Color3.fromRGB(255, 230, 40), Accent = Color3.fromRGB(255, 255, 255), Fin = Color3.fromRGB(255, 170, 30) },
	-- Zone 2: Coral Reef
	{ Id = "Coral Nibbler", Name = "Reef Nibbler", Zone = 2, Rarity = "Common", Income = 1.0, Shape = "Fish", Pattern = "Belly", Feature = "None",
		Body = Color3.fromRGB(240, 120, 200), Accent = Color3.fromRGB(150, 90, 220), Fin = Color3.fromRGB(200, 80, 170) },
	{ Id = "Reefy Shrimp", Name = "Shrimp Shogun", Zone = 2, Rarity = "Common", Income = 1.5, Shape = "FishLong", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(255, 110, 90), Accent = Color3.fromRGB(255, 200, 180), Fin = Color3.fromRGB(230, 80, 70) },
	{ Id = "Parrot Pete", Name = "Prism Parrot", Zone = 2, Rarity = "Uncommon", Income = 4.5, Shape = "Fish", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(60, 200, 140), Accent = Color3.fromRGB(60, 140, 240), Fin = Color3.fromRGB(40, 160, 120) },
	{ Id = "Polka Puffer", Name = "Domino Puffer", Zone = 2, Rarity = "Uncommon", Income = 3.5, Shape = "Puffer", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(250, 250, 250), Accent = Color3.fromRGB(30, 30, 30), Fin = Color3.fromRGB(220, 220, 220) },
	{ Id = "Lionfish Larry", Name = "Venomane Lionfish", Zone = 2, Rarity = "Rare", Income = 11, Shape = "Fish", Pattern = "Stripes", Feature = "Spikes",
		Body = Color3.fromRGB(220, 60, 50), Accent = Color3.fromRGB(255, 240, 230), Fin = Color3.fromRGB(200, 50, 40) },
	{ Id = "Bloop Jelly", Name = "Rosebloom Jelly", Zone = 2, Rarity = "Rare", Income = 12, Shape = "Jelly", Pattern = "None", Feature = "None",
		Body = Color3.fromRGB(255, 150, 210), Accent = Color3.fromRGB(255, 220, 240), Fin = Color3.fromRGB(255, 120, 200) },
	{ Id = "Rainbow Wrasse", Name = "Spectrum Wrasse", Zone = 2, Rarity = "Epic", Income = 24, Shape = "FishLong", Pattern = "Rainbow", Feature = "None",
		Body = Color3.fromRGB(80, 170, 255), Accent = Color3.fromRGB(255, 80, 160), Fin = Color3.fromRGB(255, 200, 60) },
	{ Id = "Queen Angelfish", Name = "Empress of the Reef", Zone = 2, Rarity = "Legendary", Income = 70, Shape = "FishFlat", Pattern = "Stripes", Feature = "Crown",
		Body = Color3.fromRGB(40, 90, 220), Accent = Color3.fromRGB(255, 220, 40), Fin = Color3.fromRGB(255, 200, 40) },
	-- Zone 3: Kelp Forest
	{ Id = "Kelp Crawler", Name = "Thornback Crawler", Zone = 3, Rarity = "Uncommon", Income = 4.5, Shape = "Crab", Pattern = "Spots", Feature = "Leaves",
		Body = Color3.fromRGB(90, 150, 60), Accent = Color3.fromRGB(190, 220, 120), Fin = Color3.fromRGB(70, 120, 50) },
	{ Id = "Mossy Eel", Name = "Mossfang Eel", Zone = 3, Rarity = "Uncommon", Income = 5.0, Shape = "Eel", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(120, 140, 60), Accent = Color3.fromRGB(190, 200, 110), Fin = Color3.fromRGB(90, 110, 40) },
	{ Id = "Garibaldi Gus", Name = "Ember Garibaldi", Zone = 3, Rarity = "Rare", Income = 15, Shape = "Fish", Pattern = "None", Feature = "None",
		Body = Color3.fromRGB(255, 120, 20), Accent = Color3.fromRGB(255, 200, 120), Fin = Color3.fromRGB(240, 100, 20) },
	{ Id = "Leafy Larry", Name = "Leafshade Dragon", Zone = 3, Rarity = "Rare", Income = 13, Shape = "Seahorse", Pattern = "None", Feature = "Leaves",
		Body = Color3.fromRGB(130, 190, 80), Accent = Color3.fromRGB(200, 230, 130), Fin = Color3.fromRGB(90, 160, 60) },
	{ Id = "Sneaky Octo", Name = "Shadowink Octopus", Zone = 3, Rarity = "Epic", Income = 35, Shape = "Squid", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(150, 80, 190), Accent = Color3.fromRGB(220, 170, 240), Fin = Color3.fromRGB(120, 60, 160) },
	{ Id = "Kelpie Ray", Name = "Kelpwing Ray", Zone = 3, Rarity = "Epic", Income = 39, Shape = "Ray", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(50, 110, 70), Accent = Color3.fromRGB(140, 200, 150), Fin = Color3.fromRGB(40, 90, 60) },
	{ Id = "Bob the Bass Drop", Name = "Bassquake", Zone = 3, Rarity = "Legendary", Income = 78, Shape = "FishBig", Pattern = "Stripes", Feature = "Headphones",
		Body = Color3.fromRGB(40, 180, 170), Accent = Color3.fromRGB(30, 30, 40), Fin = Color3.fromRGB(30, 140, 130) },
	{ Id = "Grove Guardian Grouper", Name = "Verdant Warden", Zone = 3, Rarity = "Mythic", Income = 230, Shape = "FishBig", Pattern = "Belly", Feature = "Crown",
		Body = Color3.fromRGB(60, 140, 70), Accent = Color3.fromRGB(240, 210, 90), Fin = Color3.fromRGB(40, 110, 60) },
	-- Zone 4: Shipwreck Bay
	{ Id = "Barnacle Bill", Name = "Barnacle Brute", Zone = 4, Rarity = "Uncommon", Income = 6.0, Shape = "Fish", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(140, 130, 110), Accent = Color3.fromRGB(220, 210, 190), Fin = Color3.fromRGB(110, 100, 90) },
	{ Id = "Anchor Eel", Name = "Ironchain Eel", Zone = 4, Rarity = "Rare", Income = 18, Shape = "Eel", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(150, 80, 50), Accent = Color3.fromRGB(90, 90, 100), Fin = Color3.fromRGB(120, 60, 40) },
	{ Id = "Rusty Crab", Name = "Rustclaw", Zone = 4, Rarity = "Rare", Income = 19, Shape = "Crab", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(170, 80, 40), Accent = Color3.fromRGB(220, 140, 80), Fin = Color3.fromRGB(140, 60, 30) },
	{ Id = "Pirate Puffer", Name = "Cannonball Puffer", Zone = 4, Rarity = "Epic", Income = 42, Shape = "Puffer", Pattern = "Spots", Feature = "PirateHat",
		Body = Color3.fromRGB(230, 190, 120), Accent = Color3.fromRGB(40, 40, 40), Fin = Color3.fromRGB(200, 160, 90) },
	{ Id = "Treasure Tuna", Name = "Goldscale Tuna", Zone = 4, Rarity = "Epic", Income = 46, Shape = "FishLong", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(255, 200, 40), Accent = Color3.fromRGB(255, 240, 160), Fin = Color3.fromRGB(220, 160, 30) },
	{ Id = "Captain Flounder", Name = "Captain Saltblade", Zone = 4, Rarity = "Legendary", Income = 130, Shape = "Ray", Pattern = "Spots", Feature = "Eyepatch",
		Body = Color3.fromRGB(170, 130, 90), Accent = Color3.fromRGB(240, 220, 190), Fin = Color3.fromRGB(140, 100, 70) },
	{ Id = "Ghost Mackerel", Name = "Phantom Mackerel", Zone = 4, Rarity = "Legendary", Income = 100, Shape = "Fish", Pattern = "Stripes", Feature = "Ghost",
		Body = Color3.fromRGB(190, 255, 220), Accent = Color3.fromRGB(240, 255, 250), Fin = Color3.fromRGB(150, 230, 200) },
	{ Id = "Davy Jones Jr.", Name = "Wreckmaster Kraag", Zone = 4, Rarity = "Mythic", Income = 300, Shape = "Squid", Pattern = "Spots", Feature = "PirateHat",
		Body = Color3.fromRGB(40, 140, 130), Accent = Color3.fromRGB(120, 220, 200), Fin = Color3.fromRGB(30, 110, 100) },
	-- Zone 5: Twilight Deep
	{ Id = "Dusk Minnow", Name = "Duskdart", Zone = 5, Rarity = "Rare", Income = 21, Shape = "FishSmall", Pattern = "Belly", Feature = "None",
		Body = Color3.fromRGB(140, 90, 220), Accent = Color3.fromRGB(220, 190, 255), Fin = Color3.fromRGB(110, 70, 190) },
	{ Id = "Glowworm Eel", Name = "Glimmerworm Eel", Zone = 5, Rarity = "Rare", Income = 23, Shape = "Eel", Pattern = "GlowSpots", Feature = "None",
		Body = Color3.fromRGB(40, 50, 120), Accent = Color3.fromRGB(120, 255, 220), Fin = Color3.fromRGB(30, 40, 100) },
	{ Id = "Twilight Jelly", Name = "Twilight Veil", Zone = 5, Rarity = "Epic", Income = 63, Shape = "Jelly", Pattern = "GlowSpots", Feature = "None",
		Body = Color3.fromRGB(170, 110, 255), Accent = Color3.fromRGB(230, 200, 255), Fin = Color3.fromRGB(140, 90, 230) },
	{ Id = "Hatchet Harry", Name = "Silver Hatchet", Zone = 5, Rarity = "Epic", Income = 54, Shape = "FishFlat", Pattern = "None", Feature = "None",
		Body = Color3.fromRGB(190, 200, 215), Accent = Color3.fromRGB(110, 120, 140), Fin = Color3.fromRGB(160, 170, 190) },
	{ Id = "Moonbeam Ray", Name = "Lunar Glider", Zone = 5, Rarity = "Legendary", Income = 150, Shape = "Ray", Pattern = "GlowSpots", Feature = "None",
		Body = Color3.fromRGB(150, 170, 220), Accent = Color3.fromRGB(240, 245, 255), Fin = Color3.fromRGB(120, 140, 200) },
	{ Id = "Sleepy Sunfish", Name = "Dreamdrift Sunfish", Zone = 5, Rarity = "Legendary", Income = 160, Shape = "FishRound", Pattern = "None", Feature = "Nightcap",
		Body = Color3.fromRGB(150, 155, 170), Accent = Color3.fromRGB(220, 220, 230), Fin = Color3.fromRGB(120, 125, 140) },
	{ Id = "Vampire Squid", Name = "Crimson Night Squid", Zone = 5, Rarity = "Mythic", Income = 330, Shape = "Squid", Pattern = "None", Feature = "Fangs",
		Body = Color3.fromRGB(120, 20, 40), Accent = Color3.fromRGB(255, 80, 90), Fin = Color3.fromRGB(90, 10, 30) },
	{ Id = "Starlight Seraph", Name = "Seraph of Dusk", Zone = 5, Rarity = "Divine", Income = 930, Shape = "Jelly", Pattern = "Stars", Feature = "Halo",
		Body = Color3.fromRGB(255, 245, 210), Accent = Color3.fromRGB(255, 215, 90), Fin = Color3.fromRGB(255, 230, 160) },
	-- Zone 6: Midnight Trench
	{ Id = "Gulper Gus", Name = "Gulpmaw", Zone = 6, Rarity = "Epic", Income = 67, Shape = "FishRound", Pattern = "Belly", Feature = "Fangs",
		Body = Color3.fromRGB(40, 40, 60), Accent = Color3.fromRGB(200, 60, 80), Fin = Color3.fromRGB(30, 30, 45) },
	{ Id = "Fangtooth Fred", Name = "Fangtooth Ravager", Zone = 6, Rarity = "Epic", Income = 74, Shape = "Fish", Pattern = "None", Feature = "Fangs",
		Body = Color3.fromRGB(70, 60, 80), Accent = Color3.fromRGB(150, 140, 160), Fin = Color3.fromRGB(50, 40, 60) },
	{ Id = "Midnight Eel", Name = "Nightcoil Eel", Zone = 6, Rarity = "Legendary", Income = 200, Shape = "Eel", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(30, 40, 90), Accent = Color3.fromRGB(90, 200, 255), Fin = Color3.fromRGB(20, 30, 70) },
	{ Id = "Ink Blot Octo", Name = "Inkstorm Octopus", Zone = 6, Rarity = "Legendary", Income = 180, Shape = "Squid", Pattern = "Spots", Feature = "None",
		Body = Color3.fromRGB(30, 30, 35), Accent = Color3.fromRGB(120, 120, 140), Fin = Color3.fromRGB(20, 20, 25) },
	{ Id = "Frostfin Narwhal", Name = "Frostlance Narwhal", Zone = 6, Rarity = "Mythic", Income = 490, Shape = "Whale", Pattern = "Spots", Feature = "Horn",
		Body = Color3.fromRGB(170, 220, 255), Accent = Color3.fromRGB(240, 250, 255), Fin = Color3.fromRGB(130, 190, 240) },
	{ Id = "Trench Dragon", Name = "Trenchwyrm", Zone = 6, Rarity = "Mythic", Income = 530, Shape = "Eel", Pattern = "GlowSpots", Feature = "Spikes",
		Body = Color3.fromRGB(80, 40, 130), Accent = Color3.fromRGB(200, 120, 255), Fin = Color3.fromRGB(60, 30, 100) },
	{ Id = "Lumen Lord", Name = "Lumen Sovereign", Zone = 6, Rarity = "Divine", Income = 1000, Shape = "FishBig", Pattern = "GlowSpots", Feature = "Halo",
		Body = Color3.fromRGB(240, 250, 255), Accent = Color3.fromRGB(140, 220, 255), Fin = Color3.fromRGB(200, 230, 255) },
	{ Id = "Aurora Whale", Name = "Aurora Colossus", Zone = 6, Rarity = "Celestial", Income = 3000, Shape = "Whale", Pattern = "Rainbow", Feature = "None",
		Body = Color3.fromRGB(40, 170, 150), Accent = Color3.fromRGB(150, 255, 200), Fin = Color3.fromRGB(60, 120, 200) },
	-- Zone 7: Hydrothermal Vents
	{ Id = "Vent Shrimp", Name = "Scorchtail Shrimp", Zone = 7, Rarity = "Epic", Income = 87, Shape = "FishSmall", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(230, 60, 40), Accent = Color3.fromRGB(255, 170, 120), Fin = Color3.fromRGB(200, 40, 30) },
	{ Id = "Lava Crab", Name = "Magmaclaw", Zone = 7, Rarity = "Legendary", Income = 240, Shape = "Crab", Pattern = "GlowSpots", Feature = "None",
		Body = Color3.fromRGB(240, 90, 30), Accent = Color3.fromRGB(255, 200, 60), Fin = Color3.fromRGB(200, 60, 20) },
	{ Id = "Smoky Snapper", Name = "Ashjaw Snapper", Zone = 7, Rarity = "Legendary", Income = 270, Shape = "Fish", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(110, 110, 120), Accent = Color3.fromRGB(255, 130, 40), Fin = Color3.fromRGB(90, 90, 100) },
	{ Id = "Magma Puffer", Name = "Eruption Puffer", Zone = 7, Rarity = "Mythic", Income = 570, Shape = "Puffer", Pattern = "GlowSpots", Feature = "None",
		Body = Color3.fromRGB(220, 60, 20), Accent = Color3.fromRGB(255, 190, 40), Fin = Color3.fromRGB(180, 40, 10) },
	{ Id = "Boiling Barracuda", Name = "Blazefang Barracuda", Zone = 7, Rarity = "Mythic", Income = 630, Shape = "FishLong", Pattern = "Stripes", Feature = "Fangs",
		Body = Color3.fromRGB(240, 130, 40), Accent = Color3.fromRGB(255, 230, 150), Fin = Color3.fromRGB(210, 100, 30) },
	{ Id = "Inferno Angler", Name = "Infernal Lanternfish", Zone = 7, Rarity = "Divine", Income = 1700, Shape = "Fish", Pattern = "GlowSpots", Feature = "Lure",
		Body = Color3.fromRGB(200, 40, 30), Accent = Color3.fromRGB(255, 220, 80), Fin = Color3.fromRGB(160, 30, 20) },
	{ Id = "Spicy Noodle Eel", Name = "Pyre Serpent", Zone = 7, Rarity = "Divine", Income = 1300, Shape = "Eel", Pattern = "Stripes", Feature = "None",
		Body = Color3.fromRGB(255, 190, 40), Accent = Color3.fromRGB(255, 80, 30), Fin = Color3.fromRGB(240, 150, 30) },
	{ Id = "Phoenix Ray", Name = "Phoenix Mantle", Zone = 7, Rarity = "Celestial", Income = 3900, Shape = "Ray", Pattern = "Rainbow", Feature = "Crown",
		Body = Color3.fromRGB(255, 110, 30), Accent = Color3.fromRGB(255, 230, 80), Fin = Color3.fromRGB(240, 60, 30) },
	-- Zone 8: The Abyss
	{ Id = "Angler Annie", Name = "Abyssal Lurer", Zone = 8, Rarity = "Legendary", Income = 280, Shape = "Fish", Pattern = "Spots", Feature = "Lure",
		Body = Color3.fromRGB(50, 80, 60), Accent = Color3.fromRGB(200, 255, 120), Fin = Color3.fromRGB(40, 60, 45) },
	{ Id = "Blobby the Blobfish", Name = "Gloomblob", Zone = 8, Rarity = "Legendary", Income = 310, Shape = "Puffer", Pattern = "None", Feature = "None",
		Body = Color3.fromRGB(255, 170, 190), Accent = Color3.fromRGB(255, 210, 220), Fin = Color3.fromRGB(240, 140, 170) },
	{ Id = "Abyssal Gulper", Name = "Voidmaw Gulper", Zone = 8, Rarity = "Mythic", Income = 860, Shape = "Eel", Pattern = "GlowSpots", Feature = "Fangs",
		Body = Color3.fromRGB(25, 25, 35), Accent = Color3.fromRGB(255, 60, 120), Fin = Color3.fromRGB(15, 15, 25) },
	{ Id = "Ghost Shark Pup", Name = "Spectral Shark", Zone = 8, Rarity = "Mythic", Income = 750, Shape = "FishLong", Pattern = "Belly", Feature = "SharkFin",
		Body = Color3.fromRGB(200, 210, 230), Accent = Color3.fromRGB(240, 245, 255), Fin = Color3.fromRGB(170, 180, 210) },
	{ Id = "Deep Sea Dragonfish", Name = "Abyss Dragonfish", Zone = 8, Rarity = "Divine", Income = 2000, Shape = "Eel", Pattern = "GlowSpots", Feature = "Fangs",
		Body = Color3.fromRGB(20, 20, 30), Accent = Color3.fromRGB(120, 255, 255), Fin = Color3.fromRGB(10, 10, 20) },
	{ Id = "Kraken Jr.", Name = "Kraken Spawn", Zone = 8, Rarity = "Divine", Income = 2200, Shape = "Squid", Pattern = "Spots", Feature = "Crown",
		Body = Color3.fromRGB(170, 30, 50), Accent = Color3.fromRGB(255, 140, 150), Fin = Color3.fromRGB(130, 20, 40) },
	{ Id = "Void Lantern", Name = "Lantern of the Void", Zone = 8, Rarity = "Celestial", Income = 4300, Shape = "Jelly", Pattern = "Stars", Feature = "Lure",
		Body = Color3.fromRGB(60, 230, 255), Accent = Color3.fromRGB(200, 255, 255), Fin = Color3.fromRGB(40, 180, 230) },
	{ Id = "Abyss King Angler", Name = "Abyssal Overlord", Zone = 8, Rarity = "Cosmic", Income = 14000, Shape = "FishBig", Pattern = "Stars", Feature = "Lure",
		Body = Color3.fromRGB(70, 30, 120), Accent = Color3.fromRGB(190, 120, 255), Fin = Color3.fromRGB(50, 20, 90) },
	-- Zone 9: Leviathan's Lair
	{ Id = "Bone Fish", Name = "Bonewraith", Zone = 9, Rarity = "Mythic", Income = 920, Shape = "Fish", Pattern = "Ribs", Feature = "None",
		Body = Color3.fromRGB(235, 230, 210), Accent = Color3.fromRGB(120, 110, 100), Fin = Color3.fromRGB(200, 195, 180) },
	{ Id = "Serpent Hatchling", Name = "Wyrmling Serpent", Zone = 9, Rarity = "Mythic", Income = 1000, Shape = "Eel", Pattern = "Spots", Feature = "Spikes",
		Body = Color3.fromRGB(60, 140, 90), Accent = Color3.fromRGB(200, 230, 120), Fin = Color3.fromRGB(40, 110, 70) },
	{ Id = "Scaleback Leviathan", Name = "Scaleback Behemoth", Zone = 9, Rarity = "Divine", Income = 2700, Shape = "Whale", Pattern = "Stripes", Feature = "Spikes",
		Body = Color3.fromRGB(30, 90, 100), Accent = Color3.fromRGB(120, 220, 210), Fin = Color3.fromRGB(20, 70, 80) },
	{ Id = "Titan Turtle", Name = "Titanshell", Zone = 9, Rarity = "Divine", Income = 2300, Shape = "Turtle", Pattern = "Spots", Feature = "Crown",
		Body = Color3.fromRGB(110, 110, 120), Accent = Color3.fromRGB(70, 160, 140), Fin = Color3.fromRGB(90, 90, 100) },
	{ Id = "Ancient Ammonite", Name = "Primordial Ammonite", Zone = 9, Rarity = "Celestial", Income = 6400, Shape = "Squid", Pattern = "Stripes", Feature = "Shell",
		Body = Color3.fromRGB(200, 150, 90), Accent = Color3.fromRGB(255, 230, 170), Fin = Color3.fromRGB(170, 120, 70) },
	{ Id = "Tidecaller Ray", Name = "Tidecaller", Zone = 9, Rarity = "Celestial", Income = 7000, Shape = "Ray", Pattern = "Stars", Feature = "Halo",
		Body = Color3.fromRGB(30, 70, 200), Accent = Color3.fromRGB(120, 220, 255), Fin = Color3.fromRGB(20, 50, 170) },
	{ Id = "Elder Kraken", Name = "Ancient Deepking", Zone = 9, Rarity = "Cosmic", Income = 15000, Shape = "Squid", Pattern = "Stars", Feature = "Crown",
		Body = Color3.fromRGB(110, 40, 160), Accent = Color3.fromRGB(255, 120, 240), Fin = Color3.fromRGB(80, 20, 120) },
	{ Id = "Leviathan Prime", Name = "Leviathan the Endless", Zone = 9, Rarity = "Secret", Income = 44000, Shape = "Eel", Pattern = "GlowSpots", Feature = "Horn",
		Body = Color3.fromRGB(20, 60, 70), Accent = Color3.fromRGB(80, 255, 200), Fin = Color3.fromRGB(10, 40, 50) },
	-- Zone 10: The Void Below
	{ Id = "Null Jelly", Name = "Null Medusa", Zone = 10, Rarity = "Divine", Income = 2900, Shape = "Jelly", Pattern = "Stars", Feature = "None",
		Body = Color3.fromRGB(30, 30, 40), Accent = Color3.fromRGB(255, 255, 255), Fin = Color3.fromRGB(60, 60, 80) },
	{ Id = "Static Guppy", Name = "Static Phantom", Zone = 10, Rarity = "Divine", Income = 3200, Shape = "FishSmall", Pattern = "Glitch", Feature = "None",
		Body = Color3.fromRGB(150, 150, 150), Accent = Color3.fromRGB(255, 255, 255), Fin = Color3.fromRGB(90, 90, 90) },
	{ Id = "Nebula Ray", Name = "Nebula Manta", Zone = 10, Rarity = "Celestial", Income = 8700, Shape = "Ray", Pattern = "Stars", Feature = "None",
		Body = Color3.fromRGB(150, 60, 220), Accent = Color3.fromRGB(255, 120, 200), Fin = Color3.fromRGB(110, 40, 180) },
	{ Id = "Starwhale", Name = "Starborn Whale", Zone = 10, Rarity = "Celestial", Income = 7600, Shape = "Whale", Pattern = "Stars", Feature = "Halo",
		Body = Color3.fromRGB(20, 30, 90), Accent = Color3.fromRGB(255, 240, 140), Fin = Color3.fromRGB(30, 50, 140) },
	{ Id = "Galaxy Puffer", Name = "Galaxy Devourer", Zone = 10, Rarity = "Cosmic", Income = 22000, Shape = "Puffer", Pattern = "Stars", Feature = "Spikes",
		Body = Color3.fromRGB(60, 20, 120), Accent = Color3.fromRGB(255, 140, 255), Fin = Color3.fromRGB(40, 10, 90) },
	{ Id = "Quasar Eel", Name = "Quasar Serpent", Zone = 10, Rarity = "Cosmic", Income = 24000, Shape = "Eel", Pattern = "Rainbow", Feature = "Halo",
		Body = Color3.fromRGB(80, 240, 255), Accent = Color3.fromRGB(255, 255, 255), Fin = Color3.fromRGB(40, 180, 230) },
	{ Id = "The Void Itself", Name = "Oblivion Incarnate", Zone = 10, Rarity = "Secret", Income = 49000, Shape = "Squid", Pattern = "Stars", Feature = "Crown",
		Body = Color3.fromRGB(10, 10, 15), Accent = Color3.fromRGB(255, 255, 255), Fin = Color3.fromRGB(25, 25, 35) },
	{ Id = "Glitch Fish", Name = "Glitchborn", Zone = 10, Rarity = "Secret", Income = 57000, Shape = "Fish", Pattern = "Glitch", Feature = "Sunglasses",
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
	-- PLOT UPGRADES (the "Upgrade Plot" board in front of your plot). One
	-- upgrade = one level. Levels 1-4: +1 pad on the ground floor (pads 7-10).
	-- Level 5: builds the SECOND FLOOR. Levels 6-15: +1 pad upstairs (pads
	-- 11-20). Prices[n] = the price of level n.
	PlotPrices = {
		500, 1_250, 3_000, 8_000, -- ground floor pads 7-10
		50_000, -- second floor
		100_000, 200_000, 400_000, 800_000, 1_600_000, -- upstairs pads 11-15
		3_200_000, 6_400_000, 13_000_000, 25_000_000, 50_000_000, -- upstairs pads 16-20
	},
	SecondFloorLevel = 5, -- the level that builds the second floor
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

-- Plot levels (see Upgrades.PlotPrices).
function Config.MaxPlotLevel(): number
	return #Config.Upgrades.PlotPrices
end

-- Pads per floor, and on the whole plot (both floors).
function Config.PadsPerFloor(): number
	return Config.Plots.PadsPerSide * 2
end

function Config.MaxPads(): number
	return Config.PadsPerFloor() * 2
end

-- Does a plot of this level have its second floor?
function Config.HasSecondFloor(level: number): boolean
	return level >= Config.Upgrades.SecondFloorLevel
end

-- How many pads are unlocked at a plot level.
function Config.PadsAtPlotLevel(level: number): number
	local perFloor = Config.PadsPerFloor()
	local ground = math.min(Config.Plots.StartingPads + level, perFloor)
	if not Config.HasSecondFloor(level) then
		return ground
	end
	return math.min(perFloor + (level - Config.Upgrades.SecondFloorLevel), Config.MaxPads())
end

-- Price of the NEXT plot level after `level` (nil = already max).
function Config.NextPlotPrice(level: number): number?
	return Config.Upgrades.PlotPrices[level + 1]
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
-- Rewards GROW WITH YOUR PROGRESS, so they always feel big: they're paid in
-- "minutes of your current income" and "minutes on your current treadmill".
--   NEW FISH:  FishIncomeMinutes of income + FishSpeedMinutes of treadmill,
--              times the rarity bonus (+RarityBonusPerTier per tier above
--              Common: Common 1x ... Secret 2.08x). Never less than the
--              minimums (based on the fish itself), so early players get
--              something good too.
--   ZONE DONE: all 8 fish of a zone found -> ZoneIncomeMinutes of income,
--              ZoneSpeedMinutes of treadmill, a free egg from that zone
--              (the rarest rarity that's at least ZoneEggMinShare common
--              there), and a PERMANENT +ZoneIncomeBonus to all fish income
--              (stacks per completed zone, saved).
-- SPEED CAP: in this game a few minutes of training already moves you a
-- big part of the way to the next zone, so Speed rewards are also capped
-- at a share of YOUR current zone gap (the Speed between the sign you've
-- passed and the next sign): one fish at most FishSpeedMaxGapShare of it
-- (x rarity bonus, so at most ~17%), a zone at most ZoneSpeedMaxGapShare.
-- No single claim ever skips a zone; the treadmill stays the main way to
-- get faster.
-- Balance: a whole zone (8 fish + completion) is worth about 1.5 hours of
-- income and roughly one zone gap of Speed, spread over the many hatches
-- it takes to find all 8 fish.
---------------------------------------------------------------------------
Config.Index = {
	FishIncomeMinutes = 5, -- a new fish = 5 minutes of your income (x rarity bonus)
	FishSpeedMinutes = 2, -- ...and 2 minutes of your treadmill (x rarity bonus)
	RarityBonusPerTier = 0.12, -- Common 1x, Rare 1.24x, Legendary 1.48x ... Secret 2.08x
	FishMinimumIncomeSeconds = 120, -- minimum cash = the fish's own income for this long (x rarity bonus)
	FishMinimumSpeed = 100, -- minimum Speed (x rarity bonus)
	ZoneIncomeMinutes = 40, -- completing a zone = 40 minutes of your income
	ZoneSpeedMinutes = 10, -- ...and 10 minutes of your treadmill
	ZoneMinimumIncomeSeconds = 600, -- minimum cash = all 8 fish's income together for this long
	ZoneMinimumSpeed = 1500,
	FishSpeedMaxGapShare = 0.08, -- one fish: at most 8% of your current zone gap (x rarity bonus)
	ZoneSpeedMaxGapShare = 0.35, -- a zone: at most 35% of your current zone gap
	ZoneIncomeBonus = 0.10, -- +10% total fish income per completed zone
	ZoneEggMinShare = 0.10, -- zone egg = the rarest rarity with at least a 10% share of that zone's eggs
	FullHotbarEggCashMinutes = 10, -- hotbar full? this much income instead of the egg
}

local function rarityBonus(rarity: string): number
	local rank = 1
	for index, info in Config.Rarities do
		if info.Name == rarity then
			rank = index
		end
	end
	return 1 + (rank - 1) * Config.Index.RarityBonusPerTier
end

-- The Speed between the last zone sign you've passed and the next one.
function Config.IndexSpeedGap(speedStat: number): number
	local previous = 0
	local lastGap = 0
	for _, shark in Config.Sharks do
		local needed = shark.SpeedStatNeeded or 0
		if needed > previous then
			lastGap = needed - previous
			if needed > speedStat then
				return lastGap
			end
			previous = needed
		end
	end
	return lastGap -- past the last sign: use the last gap
end

-- What finding a fish gives: (cash, speed). income = the player's money per
-- second, speedPerSecond = what their treadmill gives per second,
-- speedStat = their Speed (for the cap).
function Config.IndexFishReward(fish: FishConfig, income: number, speedPerSecond: number, speedStat: number): (number, number)
	local index = Config.Index
	local bonus = rarityBonus(fish.Rarity)
	local cash = math.max(income * index.FishIncomeMinutes * 60, fish.Income * index.FishMinimumIncomeSeconds) * bonus
	local speed = math.min(speedPerSecond * index.FishSpeedMinutes * 60, Config.IndexSpeedGap(speedStat) * index.FishSpeedMaxGapShare)
	speed = math.max(speed, index.FishMinimumSpeed) * bonus
	return math.floor(cash + 0.5), math.floor(speed + 0.5)
end

-- The free egg's rarity for completing a zone.
function Config.IndexZoneEggRarity(zoneIndex: number): string
	local zone = Config.Zones[zoneIndex]
	local total = 0
	for _, weight in zone.EggWeights do
		total += weight
	end
	local best = "Common"
	for _, info in Config.Rarities do
		local weight = zone.EggWeights[info.Name] or 0
		if total > 0 and weight / total >= Config.Index.ZoneEggMinShare then
			best = info.Name -- rarities are in order, so the last match is the rarest
		end
	end
	return best
end

-- What completing a zone gives: (cash, speed, egg rarity).
function Config.IndexZoneReward(zoneIndex: number, income: number, speedPerSecond: number, speedStat: number): (number, number, string)
	local index = Config.Index
	local fishIncome = 0
	for _, fish in Config.Fish do
		if fish.Zone == zoneIndex then
			fishIncome += fish.Income
		end
	end
	local cash = math.max(income * index.ZoneIncomeMinutes * 60, fishIncome * index.ZoneMinimumIncomeSeconds)
	local speed = math.min(speedPerSecond * index.ZoneSpeedMinutes * 60, Config.IndexSpeedGap(speedStat) * index.ZoneSpeedMaxGapShare)
	speed = math.max(speed, index.ZoneMinimumSpeed)
	return math.floor(cash + 0.5), math.floor(speed + 0.5), Config.IndexZoneEggRarity(zoneIndex)
end

-- The permanent income multiplier from completed zones.
function Config.IndexIncomeMultiplier(completedZones: number): number
	return 1 + completedZones * Config.Index.ZoneIncomeBonus
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
