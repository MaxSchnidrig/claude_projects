--!strict
local Fishing = {}
Fishing.BITE_WINDOW = 1.8
Fishing.SPECIES = {
	{ key = "cod", name = "Cod", weight = 15, shape = "stream", color = { 161, 143, 93 } },
	{ key = "perch", name = "Yellow Perch", weight = 13, shape = "deep", color = { 192, 160, 56 } },
	{ key = "salmon", name = "Salmon", weight = 10, shape = "stream", color = { 180, 94, 89 } },
	{ key = "trout", name = "Rainbow Trout", weight = 9, shape = "stream", color = { 125, 155, 143 } },
	{ key = "carp", name = "Common Carp", weight = 8, shape = "deep", color = { 169, 127, 63 } },
	{ key = "mackerel", name = "Atlantic Mackerel", weight = 7, shape = "stream", color = { 72, 126, 155 } },
	{ key = "bass", name = "Largemouth Bass", weight = 7, shape = "deep", color = { 107, 139, 71 } },
	{ key = "herring", name = "Herring", weight = 6, shape = "stream", color = { 124, 159, 185 } },
	{ key = "catfish", name = "Channel Catfish", weight = 5, shape = "long", color = { 112, 124, 135 } },
	{ key = "bluegill", name = "Bluegill", weight = 5, shape = "deep", color = { 87, 141, 151 } },
	{ key = "pike", name = "Northern Pike", weight = 4, shape = "long", color = { 110, 139, 67 } },
	{ key = "clownfish", name = "Clownfish", weight = 3, shape = "tropical", color = { 229, 113, 42 } },
	{ key = "pufferfish", name = "Pufferfish", weight = 3, shape = "puffer", color = { 206, 173, 64 } },
	{ key = "lionfish", name = "Lionfish", weight = 2, shape = "tropical", color = { 183, 74, 53 } },
	{ key = "eel", name = "Freshwater Eel", weight = 2, shape = "long", color = { 96, 105, 70 } },
	{ key = "tuna", name = "Bluefin Tuna", weight = 1, shape = "stream", color = { 65, 103, 149 } },
}

local materials = {
	{ key = "leather", weight = 30 }, { key = "chainmail", weight = 25 },
	{ key = "iron", weight = 20 }, { key = "golden", weight = 15 }, { key = "diamond", weight = 10 },
}
local pieces = { "helmet", "chestplate", "leggings", "boots" }
local function weighted(entries: {any}, roll: number): string
	for _, entry in entries do
		roll -= entry.weight
		if roll <= 0 then return entry.key end
	end
	error("Fishing weights must total 100")
end

-- Independent, inclusive integer rolls. Only the server draws these.
function Fishing.catch(category: number, variety: number, slot: number): string
	if category <= 20 then
		return weighted(materials, variety) .. "_" .. pieces[slot]
	end
	return weighted(Fishing.SPECIES, variety)
end

function Fishing.phase(elapsed: number, waitTime: number): string
	if elapsed < waitTime then return "waiting" end
	if elapsed < waitTime + Fishing.BITE_WINDOW then return "bite" end
	return "missed"
end
return Fishing
