--!strict
--!native
-- Ore and stone-pocket veins. Each vein is a seeded random walk that only replaces Stone,
-- so veins never eat into dirt, water or caves.
--
-- Distribution (per 16x16 chunk; the table below lists the original 0..127 tuning, VEINS has the
-- current Java height bands):
--   block        veins  walk  y-range        notes
--   dirt          10     24   0..127         pockets
--   gravel         8     24   0..127         pockets
--   coal          20     14   0..127
--   copper         8     10   0..96
--   iron          20      8   0..63
--   lapis          1      7   ~0..31         triangular, peaks at 16
--   gold           2      8   0..31
--   volt           8      7   0..15          power-wire ore
--   diamond        1      7   0..15
--   emerald       3-8      1  4..31          single blocks, mountains only

local Shared = script.Parent.Parent.Parent
local Config = require(Shared.Config)
local Hash = require(Shared.Util.Hash)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Biomes = require(script.Parent.Parent.Biomes)

local CS = Config.CHUNK_SIZE
local LAYER = CS * CS

local STONE = BlockRegistry.id("stone")
local MOUNTAINS = Biomes.id("mountains")

type VeinDef = {
	block: number,
	count: number,
	walk: number,
	minY: number,
	maxY: number,
	triangular: boolean?,
}

-- Height bands follow Java's current ranges (written in Java y, converted to internal y). The full
-- Java ore placement (exact triangular bands, air exposure, biome extras) comes with phase 13.
local O = Config.Y_OFFSET
local VEINS: { VeinDef } = {
	{ block = BlockRegistry.id("dirt"), count = 10, walk = 24, minY = 0 + O, maxY = 160 + O },
	{ block = BlockRegistry.id("gravel"), count = 8, walk = 24, minY = -64 + O, maxY = 160 + O },
	{ block = BlockRegistry.id("coal_ore"), count = 20, walk = 14, minY = 0 + O, maxY = 192 + O },
	{ block = BlockRegistry.id("copper_ore"), count = 10, walk = 10, minY = -16 + O, maxY = 112 + O, triangular = true },
	{ block = BlockRegistry.id("iron_ore"), count = 16, walk = 8, minY = -24 + O, maxY = 56 + O, triangular = true },
	{ block = BlockRegistry.id("iron_ore"), count = 6, walk = 8, minY = -64 + O, maxY = 72 + O },
	{ block = BlockRegistry.id("lapis_ore"), count = 2, walk = 7, minY = -32 + O, maxY = 32 + O, triangular = true },
	{ block = BlockRegistry.id("gold_ore"), count = 4, walk = 8, minY = -64 + O, maxY = 32 + O, triangular = true },
	{ block = BlockRegistry.id("volt_ore"), count = 8, walk = 7, minY = -64 + O, maxY = 15 + O },
	{ block = BlockRegistry.id("diamond_ore"), count = 7, walk = 5, minY = -64 + O, maxY = 16 + O, triangular = true },
}
local EMERALD = BlockRegistry.id("emerald_ore")

local Ores = {}
Ores.VEINS = VEINS

function Ores.generate(gen: any, chunk: any)
	local blocks: buffer = chunk.blocks
	local rng = Hash.newRng(Hash.hash3(gen.seed, chunk.cx, 0x0E5, chunk.cz))

	for _, v in VEINS do
		for _ = 1, v.count do
			local x = rng:nextInt(0, CS - 1)
			local z = rng:nextInt(0, CS - 1)
			local y: number
			if v.triangular then
				local half = (v.maxY - v.minY) // 2
				y = v.minY + rng:nextInt(0, half) + rng:nextInt(0, half)
			else
				y = rng:nextInt(v.minY, v.maxY)
			end
			for _ = 1, v.walk do
				if x >= 0 and x < CS and z >= 0 and z < CS and y >= 0 and y < Config.WORLD_HEIGHT then
					local idx = x + z * CS + y * LAYER
					if buffer.readu8(blocks, idx) == STONE then
						buffer.writeu8(blocks, idx, v.block)
					end
				end
				local dir = rng:nextInt(1, 6)
				if dir == 1 then
					x += 1
				elseif dir == 2 then
					x -= 1
				elseif dir == 3 then
					y += 1
				elseif dir == 4 then
					y -= 1
				elseif dir == 5 then
					z += 1
				else
					z -= 1
				end
			end
		end
	end

	-- Emerald: single blocks, only where the column is a mountain biome.
	local n = rng:nextInt(3, 8)
	for _ = 1, n do
		local x = rng:nextInt(0, CS - 1)
		local z = rng:nextInt(0, CS - 1)
		local y = rng:nextInt(-16 + O, 160 + O) -- Java: mountains, y -16 .. 320
		if buffer.readu8(chunk.biomes, x + z * CS) == MOUNTAINS then
			local idx = x + z * CS + y * LAYER
			if buffer.readu8(blocks, idx) == STONE then
				buffer.writeu8(blocks, idx, EMERALD)
			end
		end
	end
end

return Ores
