-- World height experiment: today's 0..127 world vs a simulated Java-height world (384 blocks,
-- today's terrain shifted up 64 blocks, 64 layers of stone with caves and ores below, air above).
-- Usage: lune run tests/lune/bench_height 128   |   lune run tests/lune/bench_height 384
local process = require("@lune/process")
local Loader = require("./Loader")
Loader.globals.Vector3 = (require("@lune/roblox") :: any).Vector3
local height = tonumber(process.args[1]) or 128
local Config = Loader.require("src/shared/Config")
Config.WORLD_HEIGHT = height
Config.SECTIONS_PER_CHUNK = height // Config.SECTION_SIZE
local ChunkData = Loader.require("src/shared/World/ChunkData")
local TerrainGen = Loader.require("src/shared/World/TerrainGen")
local SectionSampler = Loader.require("src/shared/Meshing/SectionSampler")
local GreedyMesher = Loader.require("src/shared/Meshing/GreedyMesher")
local LightEngine = Loader.require("src/shared/World/LightEngine")
local BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry")
local Hash = Loader.require("src/shared/Util/Hash")

local STONE, AIR = BlockRegistry.id("stone"), 0
local ORES = { BlockRegistry.id("coal_ore"), BlockRegistry.id("iron_ore"), BlockRegistry.id("diamond_ore"), BlockRegistry.id("gold_ore") }
local LAYER = 256
local gen = TerrainGen.new(1337)
local R = 3 -- chunks -3..3 generated, inner 5x5 measured
local world = {}
local tg = 0
for cz = -R, R do
	for cx = -R, R do
		local c = ChunkData.new(cx, cz)
		local t = os.clock()
		TerrainGen.generate(gen, c)
		if height > 128 then
			-- shift the 128-tall terrain up by 64 and fill a new underground below it
			buffer.copy(c.blocks, 64 * LAYER, c.blocks, 0, 128 * LAYER)
			for y = 0, 63 do
				for z = 0, 15 do
					for x = 0, 15 do
						local wx, wz = cx * 16 + x, cz * 16 + z
						local n = Hash.hash3f(7, wx // 4, y // 3, wz // 4)
						local id = if y == 0 then BlockRegistry.id("bedrock") elseif n > 0.93 then AIR else STONE
						if id == STONE and Hash.hash3f(9, wx, y, wz) > 0.992 then
							id = ORES[1 + (wx + y + wz) % #ORES]
						end
						buffer.writeu8(c.blocks, x + z * 16 + y * LAYER, id)
					end
				end
			end
		end
		tg += os.clock() - t
		world[`{cx},{cz}`] = c
	end
end
local n = (2 * R + 1) ^ 2
local engine = LightEngine.new(function(cx, cz)
	local c = world[`{cx},{cz}`]
	return if c and c.light then c else nil
end, function() end)
local t = os.clock()
for _, c in world do
	engine:lightChunk(c)
end
local tl = os.clock() - t

local padded = buffer.create(SectionSampler.VOLUME)
local light = buffer.create(SectionSampler.VOLUME)
local tm, quads, meshed, buried, empty, chunksM = 0, 0, 0, 0, 0, 0
for cz = -2, 2 do
	for cx = -2, 2 do
		chunksM += 1
		local c = world[`{cx},{cz}`]
		local nb = { east = world[`{cx + 1},{cz}`], west = world[`{cx - 1},{cz}`], south = world[`{cx},{cz + 1}`], north = world[`{cx},{cz - 1}`] }
		for sy = 0, Config.SECTIONS_PER_CHUNK - 1 do
			local a = os.clock()
			SectionSampler.fill(padded, c, nb, sy)
			local class = GreedyMesher.classify(padded)
			if class == "mesh" then
				engine:fillPadded(light, c, sy)
				local r = GreedyMesher.meshLit(padded, light, {}, nil)
				quads += r.quadCount
				meshed += 1
			elseif class == "buried" then
				buried += 1
			else
				empty += 1
			end
			tm += os.clock() - a
		end
	end
end
print(string.format("height %d: memory %d KB/chunk (blocks + light) | gen %.1f ms | light %.1f ms | mesh %.1f ms per chunk | %d quads/chunk | sections per chunk: %.1f meshed, %.1f buried, %.1f empty",
	height, ChunkData.VOLUME * 2 // 1024, tg * 1000 / n, tl * 1000 / n, tm * 1000 / chunksM, quads // chunksM,
	meshed / chunksM, buried / chunksM, empty / chunksM))
