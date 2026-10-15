--!strict
--[[
	Rarity
	======
	Helpers for working with rarities (Common ... Mythic) and weighted random
	picks. Shared, so the client can later show the same odds the server uses.

	Usage:
		Rarity.color("Rare")                  -> Color3
		Rarity.rank("Rare")                   -> 3   (1 = Common, higher = rarer)
		Rarity.glow("Rare")                   -> 1   (0 = no glow)
		Rarity.pick({ Common = 3, Rare = 1 }) -> "Common" (75%) or "Rare" (25%)
		Rarity.percentages(weights)           -> { { Name = "Common", Percent = 75 }, ... }
]]

local Config = require(script.Parent.Config)

local Rarity = {}

local rng = Random.new()

-- Position of a rarity in Config.Rarities (1 = most common). 0 if unknown.
function Rarity.rank(name: string): number
	for index, info in Config.Rarities do
		if info.Name == name then
			return index
		end
	end
	return 0
end

function Rarity.color(name: string): Color3
	for _, info in Config.Rarities do
		if info.Name == name then
			return info.Color
		end
	end
	return Color3.new(1, 1, 1)
end

-- How strongly eggs of this rarity glow (0 = not at all).
function Rarity.glow(name: string): number
	for _, info in Config.Rarities do
		if info.Name == name then
			return info.Glow
		end
	end
	return 0
end

-- Pick one rarity name at random. Bigger weight = more likely.
-- Rarities are checked in Config.Rarities order, so results are predictable
-- for a given random number. Returns nil if all weights are 0.
function Rarity.pick(weights: { [string]: number }, random: Random?): string?
	local total = 0
	for _, info in Config.Rarities do
		total += math.max(weights[info.Name] or 0, 0)
	end
	if total <= 0 then
		return nil
	end
	local roll = (random or rng):NextNumber() * total
	for _, info in Config.Rarities do
		local weight = math.max(weights[info.Name] or 0, 0)
		if weight > 0 then
			roll -= weight
			if roll < 0 then
				return info.Name
			end
		end
	end
	-- Floating point safety: fall back to the last rarity with weight.
	for i = #Config.Rarities, 1, -1 do
		local name = Config.Rarities[i].Name
		if (weights[name] or 0) > 0 then
			return name
		end
	end
	return nil
end

-- Turn weights into exact percentages (for showing odds to players).
function Rarity.percentages(weights: { [string]: number }): { { Name: string, Percent: number } }
	local total = 0
	for _, info in Config.Rarities do
		total += math.max(weights[info.Name] or 0, 0)
	end
	local result = {}
	if total <= 0 then
		return result
	end
	for _, info in Config.Rarities do
		local weight = math.max(weights[info.Name] or 0, 0)
		if weight > 0 then
			table.insert(result, { Name = info.Name, Percent = weight / total * 100 })
		end
	end
	return result
end

return Rarity
