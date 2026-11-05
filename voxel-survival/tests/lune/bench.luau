-- Terrain statistics + pure-Luau benchmark (generation, meshing, box merging).
-- Run from the project root:  lune run tests/lune/bench [seed]
--
-- Numbers are for the Luau interpreter on this machine (the Roblox client also interprets;
-- servers may JIT with --!native). Treat them as relative, then confirm in Studio.

local process = require("@lune/process")
local Loader = require("./Loader")

local SEED = tonumber(process.args[1]) or 1337
local AREA = 8 -- benchmark area is AREA x AREA chunks

local function load()
	return {
		TerrainGen = Loader.require("src/shared/World/TerrainGen"),
		ChunkData = Loader.require("src/shared/World/ChunkData"),
		BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry"),
		Biomes = Loader.require("src/shared/World/Biomes"),
		SectionSampler = Loader.require("src/shared/Meshing/SectionSampler"),
		GreedyMesher = Loader.require("src/shared/Meshing/GreedyMesher"),
		BoxMerger = Loader.require("src/shared/Meshing/BoxMerger"),
	}
end

local function pct(n: number, d: number): string
	return string.format("%5.1f%%", 100 * n / math.max(d, 1))
end

------------------------------------------------------------------------------------------
-- Statistics
------------------------------------------------------------------------------------------
do
	local M = load()
	local gen = M.TerrainGen.new(SEED)
	print(`== Terrain statistics, seed {SEED} ==`)

	local biomeCount, total = {}, 0
	local heights = {}
	for z = -200, 199 do
		for x = -200, 199 do
			local h, b = M.TerrainGen.column(gen, x * 16, z * 16)
			biomeCount[b] = (biomeCount[b] or 0) + 1
			table.insert(heights, h)
			total += 1
		end
	end
	print("Biome coverage (6400 x 6400 blocks):")
	for _, b in M.Biomes.list do
		print(string.format("  %-14s %s", b.name, pct(biomeCount[b.id] or 0, total)))
	end
	table.sort(heights)
	local function q(p: number): number
		return heights[math.max(1, math.floor(#heights * p))]
	end
	print(string.format("Surface height  min %d  p10 %d  p50 %d  p90 %d  p99 %d  max %d",
		heights[1], q(0.1), q(0.5), q(0.9), q(0.99), heights[#heights]))

	-- Block composition over AREA x AREA chunks
	local counts, perY = {}, {}
	local underground, undergroundAir = 0, 0
	for cz = 0, AREA - 1 do
		for cx = 0, AREA - 1 do
			local c = M.ChunkData.new(cx, cz)
			M.TerrainGen.generate(gen, c)
			for z = 0, 15 do
				for x = 0, 15 do
					local h = buffer.readu8(c.heights, x + z * 16)
					for y = 0, 127 do
						local id = M.ChunkData.get(c, x, y, z)
						counts[id] = (counts[id] or 0) + 1
						if id ~= 0 then
							perY[id] = perY[id] or { 999, -1 }
							perY[id][1] = math.min(perY[id][1], y)
							perY[id][2] = math.max(perY[id][2], y)
						end
						if y >= 5 and y < h - 4 then
							underground += 1
							if id == 0 then
								undergroundAir += 1
							end
						end
					end
				end
			end
		end
	end
	local n = AREA * AREA
	print(`Per-chunk averages over {n} chunks (block: count/chunk, y-range):`)
	local ids = {}
	for id in counts do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		if id ~= 0 then
			local def = M.BlockRegistry.byId[id]
			print(string.format("  %-18s %9.1f   y %3d..%3d", def.key, counts[id] / n, perY[id][1], perY[id][2]))
		end
	end
	print(string.format("Cave air below the surface: %s of underground cells", pct(undergroundAir, underground)))
	print("Spawn:", M.TerrainGen.findSpawn(gen))
end

------------------------------------------------------------------------------------------
-- Benchmark
------------------------------------------------------------------------------------------
local function bench(label: string)
	local M = load()
	local gen = M.TerrainGen.new(SEED)
	local chunks = {}
	local t0 = os.clock()
	for cz = 0, AREA - 1 do
		for cx = 0, AREA - 1 do
			local c = M.ChunkData.new(cx, cz)
			M.TerrainGen.generate(gen, c)
			chunks[cx .. "," .. cz] = c
		end
	end
	local genMs = (os.clock() - t0) * 1000 / (AREA * AREA)

	-- Mesh the inner (AREA-2)^2 chunks (they have all 4 neighbours).
	local padded = buffer.create(M.SectionSampler.VOLUME)
	local isSolid, isOpaque = M.BlockRegistry.isSolid, M.BlockRegistry.isOpaque
	local offs = M.BoxMerger.NEIGHBOR_OFFSETS
	local sections, nonEmpty = 0, 0
	local quads, faces, groups, collisionBoxes, partBoxes, blocksExposed = 0, 0, 0, 0, 0, 0
	local tSample, tMesh, tBoxes, tParts = 0, 0, 0, 0
	local maxMesh = 0
	local classes = {}
	local totalBlocks = 0
	for cz = 1, AREA - 2 do
		for cx = 1, AREA - 2 do
			local c = chunks[cx .. "," .. cz]
			local nb = {
				east = chunks[(cx + 1) .. "," .. cz],
				west = chunks[(cx - 1) .. "," .. cz],
				south = chunks[cx .. "," .. (cz + 1)],
				north = chunks[cx .. "," .. (cz - 1)],
			}
			for i = 0, buffer.len(c.blocks) - 1 do
				if buffer.readu8(c.blocks, i) ~= 0 then
					totalBlocks += 1
				end
			end
			for sy = 0, 7 do
				sections += 1
				local a = os.clock()
				M.SectionSampler.fill(padded, c, nb, sy)
				local b = os.clock()
				local class = M.GreedyMesher.classify(padded)
				classes[class] = (classes[class] or 0) + 1
				local r = if class == "mesh" then M.GreedyMesher.mesh(padded) else { quadCount = 0, faceCount = 0, groups = {} }
				local cTime = os.clock()
				local _, nBoxes = M.BoxMerger.merge(padded, function(id)
					return if isSolid[id + 1] then 1 else 0
				end)
				local dTime = os.clock()
				-- Parts backend: exposed blocks only, merged per block id
				local _, nParts = M.BoxMerger.merge(padded, function(id, p)
					for i = 1, 6 do
						if not isOpaque[buffer.readu8(padded, p + offs[i]) + 1] then
							blocksExposed += 1
							return id
						end
					end
					return 0
				end)
				local eTime = os.clock()
				tSample += b - a
				tMesh += cTime - b
				maxMesh = math.max(maxMesh, cTime - b)
				tBoxes += dTime - cTime
				tParts += eTime - dTime
				quads += r.quadCount
				faces += r.faceCount
				collisionBoxes += nBoxes
				partBoxes += nParts
				local g = 0
				for _ in r.groups do
					g += 1
				end
				groups += g
				if r.quadCount > 0 then
					nonEmpty += 1
				end
			end
		end
	end
	local per = function(x: number): number
		return x / sections
	end
	print(string.format("\n== Benchmark (%s), %d chunks generated, %d sections meshed ==", label, AREA * AREA, sections))
	print(string.format("  generate chunk          %7.2f ms avg", genMs))
	print(string.format("  sample section (pad)    %7.3f ms avg", per(tSample) * 1000))
	print(string.format("  classify + greedy mesh  %7.3f ms avg   %6.2f ms worst   (sections: %d mesh, %d buried, %d empty)",
		per(tMesh) * 1000, maxMesh * 1000, classes.mesh or 0, classes.buried or 0, classes.empty or 0))
	print(string.format("  collision boxes section %7.3f ms avg", per(tBoxes) * 1000))
	print(string.format("  parts-backend boxes     %7.3f ms avg", per(tParts) * 1000))
	return {
		sections = sections,
		nonEmpty = nonEmpty,
		faces = faces,
		quads = quads,
		groups = groups,
		collisionBoxes = collisionBoxes,
		partBoxes = partBoxes,
		chunkCount = (AREA - 2) * (AREA - 2),
		totalBlocks = totalBlocks,
		blocksExposed = blocksExposed,
	}
end

local r = bench("Luau interpreter")

local chunksAt6 = 0
for z = -6, 6 do
	for x = -6, 6 do
		if x * x + z * z <= 6.5 * 6.5 then
			chunksAt6 += 1
		end
	end
end
local perChunk = function(x: number): number
	return x / r.chunkCount
end
print(string.format("\n== Rendering approaches, per chunk (avg of %d chunks) and at render distance 6 (%d chunks) ==", r.chunkCount, chunksAt6))
print(string.format("  %-40s %10s %12s %12s", "approach", "inst/chunk", "inst @ RD6", "tris/chunk"))
local function row(name: string, inst: number, tris: number?)
	print(string.format("  %-40s %10.0f %12.0f %12s", name, inst, inst * chunksAt6, if tris then string.format("%.0f", tris) else "engine"))
end
row("A. 1 Part per block (every block)", perChunk(r.totalBlocks), nil)
row("A2. 1 Part per exposed block only", perChunk(r.blocksExposed), nil)
row("B. 1 Part per visible face (culled)", perChunk(r.faces), perChunk(r.faces) * 2)
row("C. greedy Parts per block type", perChunk(r.partBoxes), nil)
row("D. greedy EditableMesh, 1 MeshPart/texture", perChunk(r.groups), perChunk(r.quads) * 2)
print(string.format("  collision boxes (only near player)       %10.0f", perChunk(r.collisionBoxes)))
print(string.format("  faces before merge %.0f, quads after merge %.0f per chunk (%.1fx reduction)",
	perChunk(r.faces), perChunk(r.quads), r.faces / math.max(r.quads, 1)))
