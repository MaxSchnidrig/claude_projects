--!strict
--[[
	Fish
	====
	Helpers for the fish list in Config.Fish (shared, so the client can show
	the same odds the server uses, for example in an odds window later).

	Usage:
		Fish.byName("Pinchy Crab")           -> FishConfig?  (by Id, or by display Name)
		Fish.inZone(3)                       -> { FishConfig }  (that zone's 8 fish)
		Fish.ofRarity("Epic")                -> { FishConfig }
		Fish.hatchChances("Rare", 2)         -> { { Fish = ..., Chance = 0.35 }, ... }  (chances add up to 1)
		Fish.roll("Rare", 2)                 -> FishConfig   (random, using those chances)
		Fish.likelyZone("Mythic")            -> number   (the zone where that egg rarity is most common)
		Fish.legacyRarity("Kraken")          -> "Mythic" (rarity of a pet from the OLD pet list)
		Fish.oddsTable()                     -> string   (every zone's odds, for Output)
]]

local Config = require(script.Parent.Config)
local Rarity = require(script.Parent.Rarity)

export type Chance = { Fish: Config.FishConfig, Chance: number }

local Fish = {}

local rng = Random.new()

-- The pets from before the 80 fish existed, with their rarity. Saved pets
-- with these names are turned into a fish of the same rarity when loaded.
local LEGACY_PETS: { [string]: string } = {
	["Clownfish"] = "Common",
	["Sardine"] = "Common",
	["Pufferfish"] = "Uncommon",
	["Seahorse"] = "Uncommon",
	["Octopus"] = "Rare",
	["Sea Turtle"] = "Rare",
	["Manta Ray"] = "Epic",
	["Swordfish"] = "Epic",
	["Hammerhead"] = "Legendary",
	["Giant Squid"] = "Legendary",
	["Kraken"] = "Mythic",
	["Golden Megalodon"] = "Mythic",
	["Angel Jellyfish"] = "Divine",
	["Pearl Narwhal"] = "Divine",
	["Starfish Sovereign"] = "Celestial",
	["Comet Orca"] = "Celestial",
	["Nebula Ray"] = "Cosmic",
	["Galaxy Whale"] = "Cosmic",
	["Abyssal Leviathan"] = "Secret",
	["The Deep One"] = "Secret",
}

local byId: { [string]: Config.FishConfig } = {}
local byName: { [string]: Config.FishConfig } = {}
local byZone: { [number]: { Config.FishConfig } } = {}
for _, fish in Config.Fish do
	if byId[fish.Id] then
		warn(`[{Config.GameName}] Two fish have the Id "{fish.Id}" in Config.Fish. Ids must be unique.`)
	end
	if byName[fish.Name] then
		warn(`[{Config.GameName}] Two fish are called "{fish.Name}" in Config.Fish. Names must be unique.`)
	end
	byId[fish.Id] = fish
	byName[fish.Name] = fish
	local list = byZone[fish.Zone]
	if not list then
		list = {}
		byZone[fish.Zone] = list
	end
	table.insert(list, fish)
end
for zoneIndex, zone in Config.Zones do
	if not byZone[zoneIndex] then
		warn(`[{Config.GameName}] Zone {zoneIndex} ({zone.Name}) has no fish in Config.Fish.`)
	end
end

-- Find a fish by its Id (what saves and the Index store) or, if that
-- fails, by its display Name.
function Fish.byName(name: string): Config.FishConfig?
	return byId[name] or byName[name]
end

function Fish.byId(id: string): Config.FishConfig?
	return byId[id]
end

function Fish.inZone(zoneIndex: number): { Config.FishConfig }
	return byZone[zoneIndex] or {}
end

function Fish.ofRarity(rarity: string): { Config.FishConfig }
	local list = {}
	for _, fish in Config.Fish do
		if fish.Rarity == rarity then
			table.insert(list, fish)
		end
	end
	return list
end

-- The chance of every fish that can come out of an egg of `eggRarity` from
-- zone `zoneIndex`. See Config.Hatching for how it works.
function Fish.hatchChances(eggRarity: string, zoneIndex: number): { Chance }
	local candidates = Fish.inZone(zoneIndex)
	if #candidates == 0 then
		candidates = Fish.ofRarity(eggRarity)
	end
	if #candidates == 0 then
		candidates = Config.Fish
	end
	local eggRank = Rarity.rank(eggRarity)

	-- How many fish of each rarity there are, and each rarity's weight.
	local counts: { [string]: number } = {}
	for _, fish in candidates do
		counts[fish.Rarity] = (counts[fish.Rarity] or 0) + 1
	end
	local weights: { [string]: number } = {}
	local total = 0
	for rarity in counts do
		local weight = Config.Hatching.RarityStepWeights[Rarity.rank(rarity) - eggRank] or 0
		weights[rarity] = weight
		total += weight
	end
	-- No fish close to the egg's rarity: use the closest rarity there is.
	if total <= 0 then
		local best: string? = nil
		local bestDistance = math.huge
		for rarity in counts do
			local distance = math.abs(Rarity.rank(rarity) - eggRank)
			if distance < bestDistance or (distance == bestDistance and best and Rarity.rank(rarity) > Rarity.rank(best)) then
				best = rarity
				bestDistance = distance
			end
		end
		if best then
			weights[best] = 1
			total = 1
		end
	end

	local result: { Chance } = {}
	for _, fish in candidates do
		local weight = weights[fish.Rarity] or 0
		if weight > 0 then
			table.insert(result, { Fish = fish, Chance = weight / counts[fish.Rarity] / total })
		end
	end
	return result
end

function Fish.roll(eggRarity: string, zoneIndex: number, random: Random?): Config.FishConfig
	local chances = Fish.hatchChances(eggRarity, zoneIndex)
	local roll = (random or rng):NextNumber()
	for _, entry in chances do
		roll -= entry.Chance
		if roll < 0 then
			return entry.Fish
		end
	end
	return chances[#chances].Fish
end

-- The zone where eggs of this rarity are most common (used to give old saved
-- eggs, which didn't remember a zone, a sensible one).
function Fish.likelyZone(rarity: string): number
	local bestZone = 1
	local bestShare = -1
	for zoneIndex, zone in Config.Zones do
		local total = 0
		for _, weight in zone.EggWeights do
			total += weight
		end
		local share = if total > 0 then (zone.EggWeights[rarity] or 0) / total else 0
		if share > bestShare then
			bestShare = share
			bestZone = zoneIndex
		end
	end
	if bestShare <= 0 then
		-- No zone drops it: pick the zone that has fish of this rarity.
		for _, fish in Config.Fish do
			if fish.Rarity == rarity then
				return fish.Zone
			end
		end
	end
	return bestZone
end

function Fish.legacyRarity(oldName: string): string?
	return LEGACY_PETS[oldName]
end

-- A readable table of every zone's hatch odds.
function Fish.oddsTable(): string
	local lines = { `[{Config.GameName}] HATCH ODDS (egg rarity -> fish)` }
	for zoneIndex, zone in Config.Zones do
		table.insert(lines, `  Zone {zoneIndex} {zone.Name}:`)
		for _, info in Config.Rarities do
			if (zone.EggWeights[info.Name] or 0) > 0 then
				local parts = {}
				for _, entry in Fish.hatchChances(info.Name, zoneIndex) do
					table.insert(parts, string.format("%s %.1f%%", entry.Fish.Name, entry.Chance * 100))
				end
				table.insert(lines, `    {info.Name} egg: {table.concat(parts, ", ")}`)
			end
		end
	end
	return table.concat(lines, "\n")
end

return Fish
