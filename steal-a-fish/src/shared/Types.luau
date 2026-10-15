--!strict
--[[
	Types
	=====
	Shared type definitions, so the server and client agree on the shape of
	important data. Types only exist while you write and check code; they do
	nothing when the game runs.

	Usage:
		local Types = require(ReplicatedStorage.Shared.Types)
		local r: Types.Rarity = "Rare"
]]

-- The egg/pet rarity tiers. Must match the names in Config.Rarities.
export type Rarity =
	"Common"
	| "Uncommon"
	| "Rare"
	| "Epic"
	| "Legendary"
	| "Mythic"
	| "Divine"
	| "Celestial"
	| "Cosmic"
	| "Secret"

-- Every service module returns a table shaped like this.
-- Init()  runs first, for ALL services, before anything starts. Set up state
--         here, but don't depend on other services being ready yet.
-- Start() runs after every Init() has finished. Other services are safe to use.
export type Service = {
	Name: string,
	Init: () -> (),
	Start: () -> (),
}

-- Client controllers follow the same pattern as services.
export type Controller = Service

-- Everything the server knows about one plot (see PlotService).
export type PlotInfo = {
	Index: number, -- 1 to Config.Plots.Count
	Model: Model, -- Workspace.World.Plots.Plot<Index>
	Owner: Player?, -- nil when the plot is free
	CFrame: CFrame, -- center of the floor's top surface; LookVector = front
	Spawn: SpawnLocation, -- where the owner spawns
	HatchPad: BasePart, -- deliver eggs here
	Treadmill: BasePart, -- the treadmill BELT; stand on it to train Speed
	TreadmillOrigin: CFrame, -- where the treadmill is built (for swapping tiers)
	TreadmillTier: number, -- index into Config.Treadmill.Tiers
	Slots: { BasePart }, -- ALL pet pedestals (locked ones are hidden)
	UnlockedSlots: number, -- how many of Slots are usable
	SignLabels: { TextLabel }, -- owner name text (front and back of the sign)
}

return {}
