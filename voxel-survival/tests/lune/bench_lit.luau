-- Phase 7 benchmark: lighting a chunk and lit per-face meshing vs merged meshing.
local Loader = require("./Loader")
Loader.globals.Vector3 = (require("@lune/roblox") :: any).Vector3
local ChunkData = Loader.require("src/shared/World/ChunkData")
local TerrainGen = Loader.require("src/shared/World/TerrainGen")
local SectionSampler = Loader.require("src/shared/Meshing/SectionSampler")
local GreedyMesher = Loader.require("src/shared/Meshing/GreedyMesher")
local LightEngine = Loader.require("src/shared/World/LightEngine")

local gen = TerrainGen.new(1337)
local world = {}
for cz = -2, 2 do
	for cx = -2, 2 do
		local c = ChunkData.new(cx, cz)
		TerrainGen.generate(gen, c)
		world[`{cx},{cz}`] = c
	end
end
local engine = LightEngine.new(function(cx, cz)
	local c = world[`{cx},{cz}`]
	return if c and c.light then c else nil
end, function() end)
local t = os.clock()
local n = 0
for _, c in world do
	engine:lightChunk(c)
	n += 1
end
print(string.format("light chunk        %.2f ms avg (%d chunks, interpreter)", (os.clock() - t) * 1000 / n, n))

local padded = buffer.create(SectionSampler.VOLUME)
local light = buffer.create(SectionSampler.VOLUME)
local tm, tl, ql, qm, sections = 0, 0, 0, 0, 0
for cz = -1, 1 do
	for cx = -1, 1 do
		local c = world[`{cx},{cz}`]
		local nb = { east = world[`{cx + 1},{cz}`], west = world[`{cx - 1},{cz}`], south = world[`{cx},{cz + 1}`], north = world[`{cx},{cz - 1}`] }
		for sy = 0, 7 do
			SectionSampler.fill(padded, c, nb, sy)
			if GreedyMesher.classify(padded) == "mesh" then
				sections += 1
				local a = os.clock()
				local r1 = GreedyMesher.mesh(padded)
				tm += os.clock() - a
				qm += r1.quadCount
				a = os.clock()
				engine:fillPadded(light, c, sy)
				local r2 = GreedyMesher.meshLit(padded, light, {}, nil)
				tl += os.clock() - a
				ql += r2.quadCount
			end
		end
	end
end
print(string.format("merged mesh        %.2f ms/section, %d quads/section", tm * 1000 / sections, qm // sections))
print(string.format("lit per-face mesh  %.2f ms/section (incl. light fill), %d quads/section", tl * 1000 / sections, ql // sections))
