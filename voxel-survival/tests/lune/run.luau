-- Headless unit tests for the pure shared modules.
-- Run from the project root:  lune run tests/lune/run

local process = require("@lune/process")
local Loader = require("./Loader")

local Hash = Loader.require("src/shared/Util/Hash")
local Noise = Loader.require("src/shared/World/Noise")
local ChunkData = Loader.require("src/shared/World/ChunkData")
local TerrainGen = Loader.require("src/shared/World/TerrainGen")
local BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry")
local SectionSampler = Loader.require("src/shared/Meshing/SectionSampler")
local GreedyMesher = Loader.require("src/shared/Meshing/GreedyMesher")
local BoxMerger = Loader.require("src/shared/Meshing/BoxMerger")

local passed, failed = 0, 0
local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print(`  ok   {name}`)
	else
		failed += 1
		print(`  FAIL {name}\n       {err}`)
	end
end
local function eq(a: any, b: any, msg: string?)
	if a ~= b then
		error(`{msg or "values differ"}: expected {tostring(b)}, got {tostring(a)}`, 2)
	end
end

local function checksum(buf: buffer): number
	local h = 0
	for i = 0, buffer.len(buf) - 1, 4 do
		h = Hash.mix((h + buffer.readu32(buf, i)) % 4294967296)
	end
	return h
end

print("Hash / Noise")
test("mul32 matches exact 32-bit multiply", function()
	eq(Hash.mul32(0xFFFFFFFF, 0xFFFFFFFF), 1)
	eq(Hash.mul32(0x12345678, 0x9ABCDEF0), (0x5678 * 0xDEF0 + ((0x1234 * 0xDEF0 + 0x5678 * 0x9ABC) % 65536) * 65536) % 4294967296)
end)
test("rng is deterministic and in range", function()
	local a, b = Hash.newRng(42), Hash.newRng(42)
	for _ = 1, 1000 do
		local x = a:nextInt(3, 9)
		eq(x, b:nextInt(3, 9))
		assert(x >= 3 and x <= 9, "out of range")
	end
end)
test("noise is seeded, deterministic and bounded", function()
	local n1, n2, n3 = Noise.new(1, 1), Noise.new(1, 1), Noise.new(2, 1)
	local differs = false
	for i = 1, 2000 do
		local x, y, z = i * 0.37, i * 0.11, i * 0.73
		local v = n1:noise3(x, y, z)
		eq(v, n2:noise3(x, y, z))
		assert(v >= -1.01 and v <= 1.01, "noise3 out of range " .. v)
		local v2 = n1:noise2(x, z)
		assert(v2 >= -1.01 and v2 <= 1.01, "noise2 out of range " .. v2)
		if v ~= n3:noise3(x, y, z) then
			differs = true
		end
	end
	assert(differs, "different seeds produced identical noise")
end)

print("Block registry")
test("ids and keys are unique, textures resolve", function()
	local n = 0
	for id, def in BlockRegistry.byId do
		eq(def.id, id)
		for d = 1, 6 do
			assert(BlockRegistry.textureColor(def.faceTexture[d]), "missing colour for " .. def.key)
		end
		n += 1
	end
	assert(n >= 30, "expected at least 30 blocks")
	assert(BlockRegistry.isOpaque[BlockRegistry.id("stone") + 1])
	assert(not BlockRegistry.isOpaque[BlockRegistry.id("water") + 1])
	assert(not BlockRegistry.isSolid[0 + 1], "air must not be solid")
end)

print("Chunk data")
test("index round-trips and diff packing", function()
	for _, c in { { 0, 0, 0 }, { 15, 127, 15 }, { 3, 64, 9 } } do
		local x, y, z = ChunkData.unindex(ChunkData.index(c[1], c[2], c[3]))
		eq(x, c[1]); eq(y, c[2]); eq(z, c[3])
	end
	local diffs = { [0] = 5, [32767] = 1, [1234] = 0 }
	local back = ChunkData.unpackDiffs(ChunkData.packDiffs(diffs))
	eq(back[0], 5); eq(back[32767], 1); eq(back[1234], 0)
	local cx, cz = ChunkData.unkey(ChunkData.key(-7, 12))
	eq(cx, -7); eq(cz, 12)
	local a, b, lx, lz = ChunkData.worldToChunk(-1, 17)
	eq(a, -1); eq(b, 1); eq(lx, 15); eq(lz, 1)
end)

print("Terrain generation")
local SEED = 1337
test("same seed + chunk => identical blocks (fresh generators)", function()
	for _, c in { { 0, 0 }, { -3, 5 }, { 12, -9 } } do
		local a, b = ChunkData.new(c[1], c[2]), ChunkData.new(c[1], c[2])
		TerrainGen.generate(TerrainGen.new(SEED), a)
		TerrainGen.generate(TerrainGen.new(SEED), b)
		eq(checksum(a.blocks), checksum(b.blocks), `chunk {c[1]},{c[2]}`)
	end
end)
test("different seeds => different terrain", function()
	local a, b = ChunkData.new(4, 4), ChunkData.new(4, 4)
	TerrainGen.generate(TerrainGen.new(1), a)
	TerrainGen.generate(TerrainGen.new(2), b)
	assert(checksum(a.blocks) ~= checksum(b.blocks))
end)
test("bedrock floor at y = 0 everywhere", function()
	local c = ChunkData.new(2, -1)
	TerrainGen.generate(TerrainGen.new(SEED), c)
	for z = 0, 15 do
		for x = 0, 15 do
			eq(ChunkData.get(c, x, 0, z), BlockRegistry.id("bedrock"))
		end
	end
end)
test("point cave query agrees with the chunk cave pass", function()
	local gen = TerrainGen.new(SEED)
	local c = ChunkData.new(-2, 3)
	TerrainGen.generate(gen, c)
	local carvedCount = 0
	for z = 0, 15, 3 do
		for x = 0, 15, 3 do
			local h = buffer.readu8(c.heights, x + z * 16)
			for y = 5, h do
				local id = ChunkData.get(c, x, y, z)
				local isHole = id == 0 or id == BlockRegistry.id("lava")
				local carved = TerrainGen.caveCarved(gen, c.cx * 16 + x, y, c.cz * 16 + z)
				eq(isHole, carved, `cave mismatch at {x},{y},{z}`)
				if carved then
					carvedCount += 1
				end
			end
		end
	end
	assert(carvedCount > 0, "no caves found in sampled columns (suspicious)")
end)
test("trees across a chunk border are identical from both sides", function()
	-- Generate a 3x3 area in two different orders; every chunk must match.
	local order1, order2 = {}, {}
	for _, coords in { { -1, -1 }, { 0, -1 }, { 1, -1 }, { -1, 0 }, { 0, 0 }, { 1, 0 }, { -1, 1 }, { 0, 1 }, { 1, 1 } } do
		table.insert(order1, coords)
		table.insert(order2, 1, coords)
	end
	local g1, g2 = TerrainGen.new(99), TerrainGen.new(99)
	local sums = {}
	for _, c in order1 do
		local ch = ChunkData.new(c[1], c[2])
		TerrainGen.generate(g1, ch)
		sums[c[1] .. "," .. c[2]] = checksum(ch.blocks)
	end
	for _, c in order2 do
		local ch = ChunkData.new(c[1], c[2])
		TerrainGen.generate(g2, ch)
		eq(checksum(ch.blocks), sums[c[1] .. "," .. c[2]], "order-dependent chunk")
	end
end)

print("Meshing")
local function paddedFrom(setup: (chunk: any) -> ()): buffer
	local c = ChunkData.new(0, 0)
	setup(c)
	local out = buffer.create(SectionSampler.VOLUME)
	-- neighbours = empty air chunks
	local air = ChunkData.new(0, 0)
	SectionSampler.fill(out, c, { east = air, west = air, south = air, north = air }, 1)
	return out
end
local STONE = BlockRegistry.id("stone")
test("single block => 6 quads", function()
	local r = GreedyMesher.mesh(paddedFrom(function(c)
		ChunkData.set(c, 5, 20, 5, STONE)
	end))
	eq(r.quadCount, 6)
	eq(r.faceCount, 6)
end)
test("4x4x4 cube => 6 quads, 96 faces before merging", function()
	local r = GreedyMesher.mesh(paddedFrom(function(c)
		for y = 20, 23 do
			for z = 2, 5 do
				for x = 2, 5 do
					ChunkData.set(c, x, y, z, STONE)
				end
			end
		end
	end))
	eq(r.quadCount, 6)
	eq(r.faceCount, 96)
end)
test("two touching blocks share no internal face", function()
	local r = GreedyMesher.mesh(paddedFrom(function(c)
		ChunkData.set(c, 5, 20, 5, STONE)
		ChunkData.set(c, 6, 20, 5, STONE)
	end))
	eq(r.faceCount, 10)
	eq(r.quadCount, 6)
end)
test("different textures do not merge", function()
	local r = GreedyMesher.mesh(paddedFrom(function(c)
		ChunkData.set(c, 5, 20, 5, STONE)
		ChunkData.set(c, 6, 20, 5, BlockRegistry.id("dirt"))
	end))
	eq(r.faceCount, 10)
	eq(r.quadCount, 10)
end)
test("water hides faces against water but shows the stone under it", function()
	local WATER = BlockRegistry.id("water")
	local r = GreedyMesher.mesh(paddedFrom(function(c)
		ChunkData.set(c, 5, 20, 5, STONE)
		ChunkData.set(c, 5, 21, 5, WATER)
		ChunkData.set(c, 6, 21, 5, WATER)
	end))
	-- stone: 6 faces (top is visible through water). water pair: 10 faces minus the bottom
	-- of the water above stone (opaque) = 9.
	eq(r.faceCount, 15)
end)
test("quad winding: (p1-p0) x (p2-p0) points along the face normal", function()
	for d = 1, 6 do
		local c = GreedyMesher.quadCorners(d, 3, 2, 4, 2, 3)
		local ax, ay, az = c[4] - c[1], c[5] - c[2], c[6] - c[3]
		local bx, by, bz = c[7] - c[1], c[8] - c[2], c[9] - c[3]
		local nx, ny, nz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
		local v = BlockRegistry.DIR_VECTORS[d]
		assert(nx * v[1] + ny * v[2] + nz * v[3] > 0, "winding wrong for dir " .. d)
	end
end)
test("box merger: solid 4x4x4 cube => 1 box", function()
	local padded = paddedFrom(function(c)
		for y = 20, 23 do
			for z = 2, 5 do
				for x = 2, 5 do
					ChunkData.set(c, x, y, z, STONE)
				end
			end
		end
	end)
	local boxes, n = BoxMerger.merge(padded, function()
		return 1
	end)
	eq(n, 1)
	eq(boxes[4] * boxes[5] * boxes[6], 64)
end)
test("box merger covers every solid cell exactly once on real terrain", function()
	local c = ChunkData.new(0, 0)
	TerrainGen.generate(TerrainGen.new(SEED), c)
	local padded = buffer.create(SectionSampler.VOLUME)
	SectionSampler.fill(padded, c, {}, 3)
	local boxes, n = BoxMerger.merge(padded, function(id)
		return if BlockRegistry.isSolid[id + 1] then 1 else 0
	end)
	local covered = 0
	for b = 0, n - 1 do
		covered += boxes[b * 7 + 4] * boxes[b * 7 + 5] * boxes[b * 7 + 6]
	end
	local solid = 0
	for y = 48, 63 do
		for z = 0, 15 do
			for x = 0, 15 do
				if BlockRegistry.isSolid[ChunkData.get(c, x, y, z) + 1] then
					solid += 1
				end
			end
		end
	end
	eq(covered, solid, "box volume vs solid cells")
end)

test("wildcard merging: covers every visible block once, never air/water", function()
	local OFFS = BoxMerger.NEIGHBOR_OFFSETS
	local isOpaque, isLiquid = BlockRegistry.isOpaque, BlockRegistry.isLiquid
	local function partKey(padded: buffer, id: number, p: number): number
		for i = 1, 6 do
			local n = buffer.readu8(padded, p + OFFS[i])
			if n == 0 or (not isOpaque[n + 1] and n ~= id and not (isLiquid[id + 1] and isLiquid[n + 1])) then
				return id
			end
		end
		return if isOpaque[id + 1] then BoxMerger.WILDCARD else 0
	end
	local c = ChunkData.new(0, 0)
	TerrainGen.generate(TerrainGen.new(SEED), c)
	local padded = buffer.create(SectionSampler.VOLUME)
	for sy = 2, 5 do
		SectionSampler.fill(padded, c, {}, sy)
		local boxes, n = BoxMerger.merge(padded, function(id, p)
			return partKey(padded, id, p)
		end)
		local cover = {}
		for b = 0, n - 1 do
			local o = b * 7
			for y = boxes[o + 2], boxes[o + 2] + boxes[o + 5] - 1 do
				for z = boxes[o + 3], boxes[o + 3] + boxes[o + 6] - 1 do
					for x = boxes[o + 1], boxes[o + 1] + boxes[o + 4] - 1 do
						local k = x + z * 16 + y * 256
						assert(not cover[k], "cell covered twice")
						cover[k] = boxes[o + 7]
					end
				end
			end
		end
		for y = 0, 15 do
			for z = 0, 15 do
				for x = 0, 15 do
					local p = (x + 1) + (z + 1) * 18 + (y + 1) * 324
					local id = buffer.readu8(padded, p)
					local key = if id == 0 then 0 else partKey(padded, id, p)
					local k = x + z * 16 + y * 256
					if key > 0 then
						eq(cover[k], id, "visible block must be in a box of its own type")
					elseif key == 0 then
						assert(cover[k] == nil, "box covers air/non-wildcard cell")
					end
				end
			end
		end
	end
end)

print(`\n{passed} passed, {failed} failed`)
if failed > 0 then
	process.exit(1)
end
