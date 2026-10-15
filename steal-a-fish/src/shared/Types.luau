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

-- The six egg/pet rarity tiers. Must match the names in Config.Rarities.
export type Rarity = "Common" | "Uncommon" | "Rare" | "Epic" | "Legendary" | "Mythic"

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

return {}
