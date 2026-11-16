--!strict
--!native
-- Short grass and flowers on the surface (Phase 9a), after trees. Per column of grass with air
-- above, a seeded roll (its own hash, so ores, trees and terrain are unchanged) against the
-- biome's density. Our own densities in the spirit of Java's: plains are grassy with some
-- flowers, forests sparser, taiga and mountains thin, snowy / sandy biomes bare.

local Hash = require(script.Parent.Parent.Parent.Util.Hash)
local Config = require(script.Parent.Parent.Parent.Config)
local Biomes = require(script.Parent.Parent.Biomes)
local BlockRegistry = require(script.Parent.Parent.Parent.Blocks.BlockRegistry)

local Plants = {}

local CS = Config.CHUNK_SIZE
local LAYER = CS * CS
local GRASS = BlockRegistry.id("grass_block")
local SHORT_GRASS = BlockRegistry.id("short_grass")
local DANDELION = BlockRegistry.id("dandelion")
local POPPY = BlockRegistry.id("poppy")
local SAND = BlockRegistry.id("sand")
local DIRT = BlockRegistry.id("dirt")
local WATER = BlockRegistry.id("water")
local CANE = BlockRegistry.id("sugar_cane")
local CACTUS = BlockRegistry.id("cactus")
local PUMPKIN = BlockRegistry.id("pumpkin")
local SEA = Config.SEA_LEVEL
-- Flowers per biome (Java: plains have the most kinds)
local FLOWERS: { [string]: { number } } = {
	plains = { DANDELION, POPPY, BlockRegistry.id("azure_bluet"), BlockRegistry.id("oxeye_daisy"),
		BlockRegistry.id("cornflower"), BlockRegistry.id("red_tulip") },
	forest = { DANDELION, POPPY },
	birch_forest = { DANDELION, POPPY },
	mountains = { DANDELION, POPPY, BlockRegistry.id("cornflower") },
}

-- biome key -> { short grass chance, flower chance } per grass column
local DENSITY: { [string]: { number } } = {
	plains = { 0.22, 0.012 },
	forest = { 0.10, 0.008 },
	birch_forest = { 0.10, 0.008 },
	taiga = { 0.07, 0 },
	mountains = { 0.05, 0.004 },
}
Plants.DENSITY = DENSITY

-- Sugar cane along water, cactus in deserts, rare pumpkins (Phase 9b; before the grass so the
-- grass only takes what's left). Each has its own hash. Neighbours are only looked at inside the
-- chunk (a column on the chunk's edge just skips the check that needs outside).
local function extras(seed: number, chunk: any, heights: { number }, biomes: { number })
	local blocks = chunk.blocks
	local ox, oz = chunk.cx * CS, chunk.cz * CS
	local function at(lx: number, y: number, lz: number): number?
		if lx < 0 or lx >= CS or lz < 0 or lz >= CS or y < 0 or y >= Config.WORLD_HEIGHT then
			return nil
		end
		return buffer.readu16(blocks, (lx + lz * CS + y * LAYER) * 2)
	end
	local function set(lx: number, y: number, lz: number, id: number)
		buffer.writeu16(blocks, (lx + lz * CS + y * LAYER) * 2, id)
	end
	for lz = 0, CS - 1 do
		for lx = 0, CS - 1 do
			local i = lx + lz * CS + 1
			local biome = Biomes.byId[biomes[i]]
			local h = heights[i]
			local wx, wz = ox + lx, oz + lz
			local ground = at(lx, h, lz)
			if biome and h > 2 and h < Config.WORLD_HEIGHT - 5 and at(lx, h + 1, lz) == 0 then
				local height = 1 + Hash.hash3(seed, wx, 0xCA7E, wz) % 3
				-- sugar cane: on the shore (ground at sea level) with water right beside it
				if h == SEA and (ground == GRASS or ground == SAND or ground == DIRT)
					and Hash.hash3f(seed, wx, 0x5C4E, wz) < 0.2
				then
					local wet = false
					for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
						if at(lx + d[1], h, lz + d[2]) == WATER then
							wet = true
						end
					end
					if wet then
						for k = 1, height do
							if at(lx, h + k, lz) == 0 then
								set(lx, h + k, lz, CANE)
							end
						end
					end
				-- cactus: desert sand, nothing beside it
				elseif biome.key == "desert" and ground == SAND and Hash.hash3f(seed, wx, 0xCAC7, wz) < 0.02 then
					local clear = true
					for k = 1, height do
						for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
							if at(lx + d[1], h + k, lz + d[2]) ~= 0 then
								clear = false
							end
						end
					end
					if clear then
						for k = 1, height do
							set(lx, h + k, lz, CACTUS)
						end
					end
				-- pumpkins: now and then on grass in plains, forests and taiga
				elseif ground == GRASS and (biome.key == "plains" or biome.key == "forest" or biome.key == "taiga")
					and Hash.hash3f(seed, wx, 0x9C1A, wz) < 0.0008
				then
					set(lx, h + 1, lz, PUMPKIN)
				end
			end
		end
	end
end

-- `heights` / `biomes`: per column (lx + lz * CS + 1) surface height and biome id.
function Plants.generate(seed: number, chunk: any, heights: { number }, biomes: { number })
	extras(seed, chunk, heights, biomes)
	local blocks = chunk.blocks
	local ox, oz = chunk.cx * CS, chunk.cz * CS
	for lz = 0, CS - 1 do
		for lx = 0, CS - 1 do
			local i = lx + lz * CS + 1
			local biome = Biomes.byId[biomes[i]]
			local d = biome and DENSITY[biome.key]
			local h = heights[i]
			if d and h > 0 and h < Config.WORLD_HEIGHT - 1 then
				local col = lx + lz * CS
				if buffer.readu16(blocks, (col + h * LAYER) * 2) == GRASS and buffer.readu16(blocks, (col + (h + 1) * LAYER) * 2) == 0 then
					local roll = Hash.hash3f(seed, ox + lx, 0x51A7, oz + lz)
					local plant = 0
					if roll < d[2] then
						local kinds = FLOWERS[biome.key] or { DANDELION, POPPY }
						plant = kinds[Hash.hash3(seed, ox + lx, 0xF10E, oz + lz) % #kinds + 1]
					elseif roll < d[1] + d[2] then
						plant = SHORT_GRASS
					end
					if plant ~= 0 then
						buffer.writeu16(blocks, (col + (h + 1) * LAYER) * 2, plant)
					end
				end
			end
		end
	end
end

return Plants
