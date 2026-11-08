--!strict
--!native
-- Seeded procedural terrain generator. Pure and deterministic: the same seed and chunk coordinate
-- always produce identical blocks on server, client and in headless tests.
--
-- Pipeline per chunk:
--   1. column pass    height + biome per column (2D noise, 18x18 including a 1-block border for slopes)
--   2. fill pass      bedrock / stone / subsurface / surface / water / ice
--   3. cave pass      3D "spaghetti" tunnels + deep "cheese" caverns, lava below y = 10
--   4. ores           depth-banded veins (Features/Ores)
--   5. trees          biome-driven, deterministic across chunk borders (Features/Trees)
--
-- `checkpoint` is called regularly so the caller can time-slice generation across frames.

local Shared = script.Parent.Parent
local Config = require(Shared.Config)
local Hash = require(Shared.Util.Hash)
local Noise = require(script.Parent.Noise)
local ChunkData = require(script.Parent.ChunkData)
local Biomes = require(script.Parent.Biomes)
local BlockRegistry = require(Shared.Blocks.BlockRegistry)
local Ores = require(script.Parent.Features.Ores)
local Trees = require(script.Parent.Features.Trees)

local CS = Config.CHUNK_SIZE
local H = Config.WORLD_HEIGHT
local SEA = Config.SEA_LEVEL
local LAYER = CS * CS

local floor = math.floor
local max = math.max
local min = math.min
local abs = math.abs

local B = {
	AIR = 0,
	STONE = BlockRegistry.id("stone"),
	DIRT = BlockRegistry.id("dirt"),
	GRASS = BlockRegistry.id("grass_block"),
	BEDROCK = BlockRegistry.id("bedrock"),
	SAND = BlockRegistry.id("sand"),
	GRAVEL = BlockRegistry.id("gravel"),
	SANDSTONE = BlockRegistry.id("sandstone"),
	WATER = BlockRegistry.id("water"),
	LAVA = BlockRegistry.id("lava"),
	ICE = BlockRegistry.id("ice"),
	CLAY = BlockRegistry.id("clay"),
	SNOW = BlockRegistry.id("snow_block"),
}

local BIOME = {
	OCEAN = Biomes.id("ocean"),
	FROZEN_OCEAN = Biomes.id("frozen_ocean"),
	BEACH = Biomes.id("beach"),
	PLAINS = Biomes.id("plains"),
	FOREST = Biomes.id("forest"),
	BIRCH_FOREST = Biomes.id("birch_forest"),
	TAIGA = Biomes.id("taiga"),
	SNOWY_TUNDRA = Biomes.id("snowy_tundra"),
	DESERT = Biomes.id("desert"),
	MOUNTAINS = Biomes.id("mountains"),
}

-- Pre-resolve biome surface blocks to IDs.
local biomeSurface: { [number]: number } = {}
local biomeSub: { [number]: number } = {}
for _, b in Biomes.list do
	biomeSurface[b.id] = BlockRegistry.id(b.surface)
	biomeSub[b.id] = BlockRegistry.id(b.subsurface)
end

-- Cave tuning
local CAVE_CELL = 4 -- lattice spacing (blocks); density is trilinearly interpolated in between
local CAVE_MIN_Y = 5 -- never carve the bedrock floor
local LAVA_LEVEL = 10 -- carved cells at or below this become lava
local SPAGHETTI_RADIUS = 0.0045 -- threshold on a^2 + b^2; bigger = wider tunnels
local CHEESE_THRESHOLD = 0.55 -- higher = rarer caverns

export type Generator = {
	seed: number,
	nCont: Noise.Noise,
	nHill: Noise.Noise,
	nMount: Noise.Noise,
	nRidge: Noise.Noise,
	nTemp: Noise.Noise,
	nHum: Noise.Noise,
	nDetail: Noise.Noise,
	nSurf: Noise.Noise,
	nCaveA: Noise.Noise,
	nCaveB: Noise.Noise,
	nCaveC: Noise.Noise,
	-- Feature caches/hooks used by Features/* (kept untyped to avoid circular type imports)
	treeCache: { [number]: any },
	treeCacheSize: number,
	column: (gen: Generator, x: number, z: number) -> (number, number),
	caveCarved: (gen: Generator, x: number, y: number, z: number) -> boolean,
}

local TerrainGen = {}
TerrainGen.Blocks = B
TerrainGen.Biome = BIOME

local function clamp(x: number, a: number, b: number): number
	return if x < a then a elseif x > b then b else x
end

local function smoothstep(e0: number, e1: number, x: number): number
	local t = clamp((x - e0) / (e1 - e0), 0, 1)
	return t * t * (3 - 2 * t)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

---------------------------------------------------------------------------------------------
-- Column pass: height + biome for one world column. Pure function of (seed, x, z).
---------------------------------------------------------------------------------------------
local function column(gen: Generator, x: number, z: number): (number, number)
	-- Continentalness: large-scale land vs ocean.
	local cont = gen.nCont:fbm2(x * (1 / 700) + 0.37, z * (1 / 700) + 0.61, 4)
	local landT = smoothstep(-0.2, -0.06, cont)
	local deep = smoothstep(-0.2, -0.45, cont)
	local oceanBase = SEA - 5 - 16 * deep
	local landBase = SEA + 2 + 7 * smoothstep(-0.06, 0.35, cont)
	local base = lerp(oceanBase, landBase, landT)

	-- Rolling hills everywhere on land, mountain ranges where the mountain mask is high.
	local hills = gen.nHill:fbm2(x * (1 / 96) + 0.21, z * (1 / 96) + 0.73, 4)
	local mountMask = gen.nMount:fbm2(x * (1 / 480) + 0.11, z * (1 / 480) + 0.91, 3)
	local m = smoothstep(0.08, 0.32, mountMask) * landT
	local ridge = 0
	if m > 0 then
		ridge = gen.nRidge:ridged2(x * (1 / 150) + 0.3, z * (1 / 150) + 0.6, 4)
	end
	local detail = gen.nDetail:noise2(x * (1 / 20) + 0.5, z * (1 / 20) + 0.5)

	local h = base + hills * lerp(6, 18, landT) * (1 - 0.5 * m) + m * ridge * 58 + detail * 1.2
	local height = clamp(floor(h), 6, H - 8)

	-- Climate: temperature cools with altitude.
	local temp = gen.nTemp:fbm2(x * (1 / 900) + 0.17, z * (1 / 900) + 0.43, 3)
	if height > SEA + 28 then
		temp -= (height - (SEA + 28)) * 0.01
	end
	local hum = gen.nHum:fbm2(x * (1 / 800) + 0.83, z * (1 / 800) + 0.29, 3)

	local biome: number
	if height < SEA then
		biome = if temp < -0.3 then BIOME.FROZEN_OCEAN else BIOME.OCEAN
	elseif height <= SEA + 2 and cont < -0.03 then
		biome = if temp < -0.3 then BIOME.SNOWY_TUNDRA else BIOME.BEACH
	elseif m > 0.5 and height >= SEA + 20 then
		biome = BIOME.MOUNTAINS
	elseif temp > 0.14 and hum < 0.08 then
		biome = BIOME.DESERT
	elseif temp < -0.28 then
		biome = BIOME.SNOWY_TUNDRA
	elseif temp < -0.12 then
		biome = BIOME.TAIGA
	elseif hum > 0.12 and temp < 0.0 then
		biome = BIOME.BIRCH_FOREST
	elseif hum > 0.04 then
		biome = BIOME.FOREST
	else
		biome = BIOME.PLAINS
	end
	return height, biome
end
TerrainGen.column = column

---------------------------------------------------------------------------------------------
-- Cave density. Defined on a global 4-block lattice so a single point query (used by tree
-- placement in neighbouring chunks) gives exactly the same answer as the per-chunk pass.
---------------------------------------------------------------------------------------------
local function latticeDensity(gen: Generator, gx: number, gy: number, gz: number): number
	local x, y, z = gx * CAVE_CELL, gy * CAVE_CELL, gz * CAVE_CELL
	-- Spaghetti tunnels: carve where two independent noises are both near zero.
	local sx, sy, sz = x * (1 / 42) + 0.13, y * (1 / 30) + 0.57, z * (1 / 42) + 0.91
	local a = gen.nCaveA:noise3(sx, sy, sz)
	local b = gen.nCaveB:noise3(sx, sy, sz)
	local spaghetti = (a * a + b * b - SPAGHETTI_RADIUS) * 20
	if y < 16 then
		spaghetti += (16 - y) * 0.015 -- tunnels narrow and thin out near the lava layer
	end
	-- Cheese caverns: large open pockets, deep only.
	local c = gen.nCaveC:noise3(x * (1 / 90) + 0.71, y * (1 / 45) + 0.33, z * (1 / 90) + 0.05)
	local cheese = CHEESE_THRESHOLD - c
	if y > SEA - 22 then
		cheese += (y - (SEA - 22)) * 0.02 -- caverns stay deep
	elseif y < 14 then
		cheese += (14 - y) * 0.025 -- and mostly above the lava layer
	end
	return min(spaghetti, cheese) -- negative = air
end

-- Bilinear interpolation in the XZ plane of one lattice level. Both the per-chunk pass and the
-- point query use exactly this function and then lerp in Y, so they are bit-identical.
local function bilinearXZ(c00: number, c10: number, c01: number, c11: number, fx: number, fz: number): number
	local a = c00 + (c10 - c00) * fx
	local b = c01 + (c11 - c01) * fx
	return a + (b - a) * fz
end

-- Rule shared by both code paths: is this (column height h) cell eligible for carving?
local function carveAllowed(y: number, h: number): boolean
	if y < CAVE_MIN_Y or y > h then
		return false
	end
	-- Keep a solid lid under seas and shorelines so water never "hangs" over caves.
	if h <= SEA + 1 and y > h - 5 then
		return false
	end
	return true
end

-- Single-point query (slow path; used for tree validity in neighbouring chunks).
local function caveCarved(gen: Generator, x: number, y: number, z: number): boolean
	local h = (column(gen, x, z))
	if not carveAllowed(y, h) then
		return false
	end
	local gx, gy, gz = x // CAVE_CELL, y // CAVE_CELL, z // CAVE_CELL
	local fx = (x - gx * CAVE_CELL) / CAVE_CELL
	local fy = (y - gy * CAVE_CELL) / CAVE_CELL
	local fz = (z - gz * CAVE_CELL) / CAVE_CELL
	local lo = bilinearXZ(
		latticeDensity(gen, gx, gy, gz), latticeDensity(gen, gx + 1, gy, gz),
		latticeDensity(gen, gx, gy, gz + 1), latticeDensity(gen, gx + 1, gy, gz + 1),
		fx, fz
	)
	local hi = bilinearXZ(
		latticeDensity(gen, gx, gy + 1, gz), latticeDensity(gen, gx + 1, gy + 1, gz),
		latticeDensity(gen, gx, gy + 1, gz + 1), latticeDensity(gen, gx + 1, gy + 1, gz + 1),
		fx, fz
	)
	local d = lo + (hi - lo) * fy
	return d < 0
end
TerrainGen.caveCarved = caveCarved

---------------------------------------------------------------------------------------------

function TerrainGen.new(seed: number): Generator
	local gen: Generator = {
		seed = seed,
		nCont = Noise.new(seed, 1),
		nHill = Noise.new(seed, 2),
		nMount = Noise.new(seed, 3),
		nRidge = Noise.new(seed, 4),
		nTemp = Noise.new(seed, 5),
		nHum = Noise.new(seed, 6),
		nDetail = Noise.new(seed, 7),
		nSurf = Noise.new(seed, 8),
		nCaveA = Noise.new(seed, 9),
		nCaveB = Noise.new(seed, 10),
		nCaveC = Noise.new(seed, 11),
		treeCache = {},
		treeCacheSize = 0,
		column = column,
		caveCarved = caveCarved,
	}
	return gen
end

local function noop() end

function TerrainGen.generate(gen: Generator, chunk: ChunkData.Chunk, checkpoint: (() -> ())?)
	local yieldPoint = checkpoint or noop
	local blocks = chunk.blocks
	local ox, oz = chunk.cx * CS, chunk.cz * CS
	local seed = gen.seed

	-- 1. Column pass (18x18 with border, for slope detection) -------------------------------
	local BW = CS + 2
	local hmap = table.create(BW * BW, 0)
	local bmap = table.create(LAYER, 0)
	local maxH = 0
	for lz = -1, CS do
		for lx = -1, CS do
			local h, biome = column(gen, ox + lx, oz + lz)
			hmap[(lx + 1) + (lz + 1) * BW + 1] = h
			if lx >= 0 and lx < CS and lz >= 0 and lz < CS then
				bmap[lx + lz * CS + 1] = biome
				buffer.writeu8(chunk.biomes, lx + lz * CS, biome)
				buffer.writeu8(chunk.heights, lx + lz * CS, math.min(h, 255))
				if h > maxH then
					maxH = h
				end
			end
		end
		yieldPoint()
	end

	-- 2. Fill pass ---------------------------------------------------------------------------
	for lz = 0, CS - 1 do
		for lx = 0, CS - 1 do
			local wx, wz = ox + lx, oz + lz
			local hi = (lx + 1) + (lz + 1) * BW + 1
			local h = hmap[hi]
			local biome = bmap[lx + lz * CS + 1]
			local slope = max(abs(h - hmap[hi - 1]), abs(h - hmap[hi + 1]), abs(h - hmap[hi - BW]), abs(h - hmap[hi + BW]))

			local surface = biomeSurface[biome]
			local sub = biomeSub[biome]
			local depth = 3 + (Hash.hash3(seed, wx, 77, wz) % 2) + Biomes.byId[biome].subDepth
			local sandstoneDepth = 0

			if biome == BIOME.MOUNTAINS then
				if h >= SEA + 38 then
					surface, sub = B.SNOW, B.STONE
				elseif slope >= 3 then
					surface, sub = B.STONE, B.STONE
				end
			elseif biome == BIOME.OCEAN or biome == BIOME.FROZEN_OCEAN then
				local n = gen.nSurf:noise2(wx * (1 / 16) + 0.5, wz * (1 / 16) + 0.5)
				if h >= SEA - 6 and n > 0.3 then
					surface, sub = B.CLAY, B.CLAY
				elseif h < SEA - 8 then
					surface = if n > 0 then B.GRAVEL else B.DIRT
					sub = surface
				end
			elseif biome == BIOME.DESERT then
				sandstoneDepth = 3
			end

			local col = lx + lz * CS
			buffer.writeu16(blocks, col * 2, B.BEDROCK)
			for y = 1, h do
				local id: number
				if y <= 4 and Hash.hash3f(seed, wx, y, wz) < (5 - y) / 5 then
					id = B.BEDROCK
				elseif y == h then
					id = surface
				elseif y > h - depth then
					id = sub
				elseif y > h - depth - sandstoneDepth then
					id = B.SANDSTONE
				else
					id = B.STONE
				end
				buffer.writeu16(blocks, (col + y * LAYER) * 2, id)
			end
			if h < SEA then
				local frozen = Biomes.byId[biome].frozen
				for y = h + 1, SEA do
					buffer.writeu16(blocks, (col + y * LAYER) * 2, if frozen and y == SEA then B.ICE else B.WATER)
				end
			end
		end
		yieldPoint()
	end

	-- 3. Cave pass ---------------------------------------------------------------------------
	local cellsX = CS // CAVE_CELL + 1 -- 5 lattice points across a chunk
	local cellsY = maxH // CAVE_CELL + 2
	local gx0, gz0 = ox // CAVE_CELL, oz // CAVE_CELL
	local lattice = table.create(cellsX * cellsX * cellsY, 0)
	local function li(ix: number, iy: number, iz: number): number
		return ix + iz * cellsX + iy * cellsX * cellsX + 1
	end
	for iy = 0, cellsY - 1 do
		for iz = 0, cellsX - 1 do
			for ix = 0, cellsX - 1 do
				lattice[li(ix, iy, iz)] = latticeDensity(gen, gx0 + ix, iy, gz0 + iz)
			end
		end
		yieldPoint()
	end

	local levels = table.create(cellsY, 0)
	for lz = 0, CS - 1 do
		local iz = lz // CAVE_CELL
		local fz = (lz - iz * CAVE_CELL) / CAVE_CELL
		for lx = 0, CS - 1 do
			local ix = lx // CAVE_CELL
			local fx = (lx - ix * CAVE_CELL) / CAVE_CELL
			local h = hmap[(lx + 1) + (lz + 1) * BW + 1]
			local col = lx + lz * CS
			-- XZ-interpolated density at every lattice level this column needs
			local topLevel = h // CAVE_CELL + 1
			for iy = CAVE_MIN_Y // CAVE_CELL, topLevel do
				levels[iy + 1] = bilinearXZ(
					lattice[li(ix, iy, iz)], lattice[li(ix + 1, iy, iz)],
					lattice[li(ix, iy, iz + 1)], lattice[li(ix + 1, iy, iz + 1)],
					fx, fz
				)
			end
			for y = CAVE_MIN_Y, h do
				if carveAllowed(y, h) then
					local iy = y // CAVE_CELL
					local fy = (y - iy * CAVE_CELL) / CAVE_CELL
					local lo = levels[iy + 1]
					local d = lo + (levels[iy + 2] - lo) * fy
					if d < 0 then
						buffer.writeu16(blocks, (col + y * LAYER) * 2, if y <= LAVA_LEVEL then B.LAVA else B.AIR)
					end
				end
			end
		end
		yieldPoint()
	end

	-- 4. Ores --------------------------------------------------------------------------------
	Ores.generate(gen, chunk)
	yieldPoint()

	-- 5. Trees -------------------------------------------------------------------------------
	Trees.generate(gen, chunk)

	chunk.generated = true
end

-- Find a dry, flat-ish land spawn column near the origin. Returns world block coords of the
-- first air block above the surface.
function TerrainGen.findSpawn(gen: Generator): (number, number, number)
	local step = 8
	for ring = 0, 64 do
		for i = -ring, ring do
			for _, p in { { i, -ring }, { i, ring }, { -ring, i }, { ring, i } } do
				local x, z = p[1] * step, p[2] * step
				local h, biome = column(gen, x, z)
				if h > SEA + 1 and h < SEA + 28 and biome ~= BIOME.BEACH and biome ~= BIOME.MOUNTAINS
					and not caveCarved(gen, x, h, z)
				then
					return x, h + 1, z
				end
			end
		end
	end
	return 0, H - 10, 0
end

return TerrainGen
