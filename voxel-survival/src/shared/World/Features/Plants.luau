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

-- biome key -> { short grass chance, flower chance } per grass column
local DENSITY: { [string]: { number } } = {
	plains = { 0.22, 0.012 },
	forest = { 0.10, 0.008 },
	birch_forest = { 0.10, 0.008 },
	taiga = { 0.07, 0 },
	mountains = { 0.05, 0.004 },
}
Plants.DENSITY = DENSITY

-- `heights` / `biomes`: per column (lx + lz * CS + 1) surface height and biome id.
function Plants.generate(seed: number, chunk: any, heights: { number }, biomes: { number })
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
						plant = if Hash.hash3(seed, ox + lx, 0xF10E, oz + lz) % 2 == 0 then DANDELION else POPPY
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
