--!strict
-- Biome definitions (data only). TerrainGen decides WHERE a biome is; this decides WHAT it looks like.
--
--   surface / subsurface   block keys for the top block and the few blocks under it
--   subDepth               extra subsurface depth (added to 3 + per-column jitter)
--   trees                  list of { kind, weight } picked per tree attempt
--   treeChance             probability that each of the TREE_ATTEMPTS per chunk becomes a tree
--   frozen                 top water layer turns to ice

export type Biome = {
	id: number,
	key: string,
	name: string,
	surface: string,
	subsurface: string,
	subDepth: number,
	trees: { { kind: string, weight: number } },
	treeChance: number,
	frozen: boolean,
}

local list: { Biome } = {
	{ id = 1, key = "ocean", name = "Ocean", surface = "sand", subsurface = "sand", subDepth = 0, trees = {}, treeChance = 0, frozen = false },
	{ id = 2, key = "frozen_ocean", name = "Frozen Ocean", surface = "gravel", subsurface = "gravel", subDepth = 0, trees = {}, treeChance = 0, frozen = true },
	{ id = 3, key = "beach", name = "Beach", surface = "sand", subsurface = "sand", subDepth = 1, trees = {}, treeChance = 0, frozen = false },
	{ id = 4, key = "plains", name = "Plains", surface = "grass_block", subsurface = "dirt", subDepth = 0, trees = { { kind = "oak", weight = 1 } }, treeChance = 0.02, frozen = false },
	{ id = 5, key = "forest", name = "Forest", surface = "grass_block", subsurface = "dirt", subDepth = 0, trees = { { kind = "oak", weight = 4 }, { kind = "birch", weight = 1 } }, treeChance = 0.8, frozen = false },
	{ id = 6, key = "birch_forest", name = "Birch Forest", surface = "grass_block", subsurface = "dirt", subDepth = 0, trees = { { kind = "birch", weight = 1 } }, treeChance = 0.8, frozen = false },
	{ id = 7, key = "taiga", name = "Taiga", surface = "grass_block", subsurface = "dirt", subDepth = 0, trees = { { kind = "spruce", weight = 1 } }, treeChance = 0.65, frozen = false },
	{ id = 8, key = "snowy_tundra", name = "Snowy Tundra", surface = "snowy_grass_block", subsurface = "dirt", subDepth = 0, trees = { { kind = "spruce", weight = 1 } }, treeChance = 0.04, frozen = true },
	{ id = 9, key = "desert", name = "Desert", surface = "sand", subsurface = "sand", subDepth = 1, trees = {}, treeChance = 0, frozen = false },
	{ id = 10, key = "mountains", name = "Mountains", surface = "grass_block", subsurface = "dirt", subDepth = 0, trees = { { kind = "spruce", weight = 2 }, { kind = "oak", weight = 1 } }, treeChance = 0.1, frozen = false },
}

local Biomes = {}
Biomes.list = list
Biomes.byId = {} :: { [number]: Biome }
Biomes.byKey = {} :: { [string]: Biome }
for _, b in list do
	Biomes.byId[b.id] = b
	Biomes.byKey[b.key] = b
end

function Biomes.id(key: string): number
	local b = Biomes.byKey[key]
	assert(b, `Biomes: unknown biome '{key}'`)
	return b.id
end

return Biomes
