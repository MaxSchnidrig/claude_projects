-- Headless unit tests for the pure shared modules.
-- Run from the project root:  lune run tests/lune/run

local process = require("@lune/process")
local Loader = require("./Loader")
Loader.globals.Vector3 = (require("@lune/roblox") :: any).Vector3

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

print("Items / mining / raycast")
local ItemRegistry = Loader.require("src/shared/Items/ItemRegistry")
local Mining = Loader.require("src/shared/Gameplay/Mining")
local VoxelRaycast = Loader.require("src/shared/World/VoxelRaycast")
test("every block drop is an item; tools generated", function()
	assert(ItemRegistry.get("diamond_pickaxe").tool.tier == 4)
	assert(ItemRegistry.get("golden_axe").tool.speed == 12)
	assert(ItemRegistry.get("stone").block == BlockRegistry.id("stone"))
	assert(ItemRegistry.get("water") == nil, "fluids are not items")
end)
test("break times match classic reference values", function()
	local id = BlockRegistry.id
	local cases = {
		{ "dirt", nil, 0.75 },
		{ "stone", nil, 7.5 }, -- wrong tool and not harvestable by hand
		{ "stone", "wooden_pickaxe", 1.15 },
		{ "stone", "diamond_pickaxe", 0.3 },
		{ "oak_log", nil, 3.0 },
		{ "oak_log", "iron_axe", 0.5 },
		{ "obsidian", "diamond_pickaxe", 9.4 },
		{ "iron_ore", "stone_pickaxe", 1.15 },
		{ "diamond_ore", "stone_pickaxe", 3.75 }, -- right kind, tier too low: slow, no drop
		{ "oak_leaves", "shears", 0 }, -- instant
	}
	for _, c in cases do
		local t = Mining.breakSeconds(id(c[1]), c[2])
		assert(math.abs(t - c[3]) < 1e-6, `{c[1]} with {c[2] or "hand"}: expected {c[3]}, got {t}`)
	end
	eq(Mining.breakSeconds(id("tnt"), nil), 0)
	eq(Mining.breakSeconds(id("bedrock"), "diamond_pickaxe"), math.huge)
	assert(math.abs(Mining.breakSeconds(id("dirt"), nil, { airborne = true }) - 3.75) < 1e-6)
end)
test("harvest tiers", function()
	local id = BlockRegistry.id
	assert(Mining.canHarvest(id("dirt"), nil))
	assert(not Mining.canHarvest(id("stone"), nil))
	assert(Mining.canHarvest(id("stone"), "wooden_pickaxe"))
	assert(not Mining.canHarvest(id("iron_ore"), "wooden_pickaxe"))
	assert(Mining.canHarvest(id("iron_ore"), "stone_pickaxe"))
	assert(not Mining.canHarvest(id("diamond_ore"), "golden_pickaxe"))
	assert(Mining.canHarvest(id("diamond_ore"), "iron_pickaxe"))
	assert(not Mining.canHarvest(id("obsidian"), "iron_pickaxe"))
	assert(not Mining.canHarvest(id("stone"), "diamond_axe"), "wrong tool kind")
end)
test("voxel raycast hits the right block and face", function()
	local solid = { ["5,2,0"] = 1, ["0,0,7"] = 1 }
	local function get(x, y, z)
		return solid[x .. "," .. y .. "," .. z] or 0
	end
	local function stops(id2)
		return id2 ~= 0
	end
	local h = VoxelRaycast.cast(get, 0.5, 2.5, 0.5, 1, 0, 0, 10, stops)
	assert(h, "expected a hit")
	eq(h.x, 5); eq(h.y, 2); eq(h.z, 0); eq(h.nx, -1); eq(h.ny, 0)
	assert(math.abs(h.distance - 4.5) < 1e-9)
	local h2 = VoxelRaycast.cast(get, 0.5, 0.5, 0.5, 0, 0, 1, 10, stops)
	assert(h2 and h2.z == 7 and h2.nz == -1)
	eq(VoxelRaycast.cast(get, 0.5, 2.5, 0.5, 1, 0, 0, 4, stops), nil) -- out of reach
	-- diagonal ray must not skip through an edge
	local h3 = VoxelRaycast.cast(get, 3.5, 0.5, 0.5, 0.6, 0.6, 0, 10, stops)
	assert(h3 and h3.x == 5 and h3.y == 2, "diagonal hit")
end)

print("Crafting / slots / furnace")
local Crafting = Loader.require("src/shared/Items/Crafting")
local SlotLogic = Loader.require("src/shared/Items/SlotLogic")
local FurnaceLogic = Loader.require("src/shared/Items/FurnaceLogic")
local function grid(w: number, rows: { string }, key: { [string]: string })
	local g = {}
	for r, row in rows do
		for c = 1, #row do
			local ch = string.sub(row, c, c)
			if ch ~= " " then
				g[(r - 1) * w + c] = { item = key[ch], count = 1 }
			end
		end
	end
	return g
end
test("shaped recipes match anywhere in the grid, mirrored, with tags", function()
	local r = Crafting.match(grid(3, { "   ", " P ", " P " }, { P = "birch_planks" }), 3)
	assert(r and r.item == "stick" and r.count == 4, "sticks from planks (offset in 3x3)")
	r = Crafting.match(grid(3, { "CCC", " S ", " S " }, { C = "cobblestone", S = "stick" }), 3)
	assert(r and r.item == "stone_pickaxe", "stone pickaxe")
	r = Crafting.match(grid(3, { "II ", "SI ", "S  " }, { I = "iron_ingot", S = "stick" }), 3)
	assert(r and r.item == "iron_axe", "mirrored iron axe")
	r = Crafting.match(grid(3, { "I I", "SSS", "   " }, { I = "iron_ingot", S = "stick" }), 3)
	assert(r == nil, "not a recipe")
	r = Crafting.match(grid(3, { "MM ", "SM ", "S  " }, { M = "diamond", S = "stick" }), 3)
	assert(r and r.item == "diamond_axe", "mirrored diamond axe")
	r = Crafting.match(grid(3, { "MM ", "SM ", " S " }, { M = "diamond", S = "stick" }), 3)
	assert(r == nil, "invalid (stick under wrong column)")
	r = Crafting.match(grid(3, { "MM ", "MS ", " S " }, { M = "diamond", S = "stick" }), 3)
	assert(r and r.item == "diamond_axe", "axe")
	r = Crafting.match(grid(3, { " MM", " SM", " S " }, { M = "diamond", S = "stick" }), 3)
	assert(r and r.item == "diamond_axe", "mirrored axe")
	r = Crafting.match(grid(2, { "PP", "PP" }, { P = "oak_planks" }), 2)
	assert(r and r.item == "crafting_table", "crafting table in 2x2")
	r = Crafting.match(grid(3, { "PPP", "P P", "PPP" }, { P = "spruce_planks" }), 3)
	assert(r and r.item == "chest", "chest")
end)
test("shapeless recipes and smelting/fuel tables", function()
	local r = Crafting.match(grid(2, { " ", " L" }, { L = "spruce_log" }), 2)
	assert(r and r.item == "spruce_planks" and r.count == 4)
	eq(Crafting.smeltResult("raw_iron"), "iron_ingot")
	eq(Crafting.fuelSeconds("coal"), 80)
	eq(Crafting.fuelSeconds("dirt"), 0)
end)
test("slot clicks follow classic rules", function()
	local slots = { [1] = { item = "dirt", count = 10 }, [2] = { item = "dirt", count = 60 }, [3] = { item = "stone", count = 5 } }
	local cur = SlotLogic.rightClick(slots, 1, nil) -- half of 10
	eq(cur.count, 5); eq(slots[1].count, 5)
	cur = SlotLogic.leftClick(slots, 2, cur) -- merge into 60: 4 fit
	eq(slots[2].count, 64); eq(cur.count, 1)
	cur = SlotLogic.rightClick(slots, 4, cur) -- place one into empty slot
	eq(slots[4].count, 1); eq(cur, nil)
	cur = SlotLogic.leftClick(slots, 3, nil) -- pick up stone
	cur = SlotLogic.leftClick(slots, 1, cur) -- swap with dirt
	eq(slots[1].item, "stone"); eq(cur.item, "dirt")
	-- tools never stack
	local t = { [1] = { item = "iron_pickaxe", count = 1, durability = 250 } }
	local c2 = SlotLogic.leftClick(t, 1, { item = "iron_pickaxe", count = 1, durability = 250 })
	eq(t[1].count, 1); assert(c2 and c2.count == 1)
end)
test("quickMove merges first, then fills empty slots, keeps leftovers", function()
	local inv = { [10] = { item = "dirt", count = 62 }, [11] = { item = "stone", count = 64 } }
	local src = { [1] = { item = "dirt", count = 70 } }
	local moved = SlotLogic.quickMove(src, 1, { { slots = inv, lo = 10, hi = 12 } })
	assert(moved)
	eq(inv[10].count, 64); eq(inv[12].count, 64); eq(src[1].count, 4)
end)
test("furnace smelts with fuel, classic timings", function()
	local st = FurnaceLogic.new()
	st.slots[1] = { item = "raw_iron", count = 10 }
	st.slots[2] = { item = "coal", count = 2 }
	for _ = 1, 25 do
		FurnaceLogic.step(st, 1) -- 25 s
	end
	eq(st.slots[3].count, 2) -- 10 s per item
	eq(st.slots[2].count, 1) -- one coal lit
	for _ = 1, 200 do
		FurnaceLogic.step(st, 1)
	end
	eq(st.slots[3].count, 10) -- 2 coal = 160 s = 16 items, but only 10 input
	eq(st.slots[1], nil)
	-- planks as fuel: 15 s = 1.5 items
	local p = FurnaceLogic.new()
	p.slots[1] = { item = "sand", count = 5 }
	p.slots[2] = { item = "oak_planks", count = 1 }
	for _ = 1, 40 do
		FurnaceLogic.step(p, 1)
	end
	eq(p.slots[3].item, "glass"); eq(p.slots[3].count, 1)
end)

test("drag: left splits evenly with remainder, right places one each, Java rules", function()
	local a = { [1] = { item = "dirt", count = 60 }, [3] = { item = "stone", count = 1 } }
	local cur = SlotLogic.drag({
		{ slots = a, index = 1 }, -- 60 dirt: room for 4
		{ slots = a, index = 2 }, -- empty
		{ slots = a, index = 2 }, -- duplicate, ignored
		{ slots = a, index = 3 }, -- stone: not eligible
		{ slots = a, index = 4 }, -- empty
	}, { item = "dirt", count = 10 }, "left")
	-- 3 eligible slots: 10 // 3 = 3 each; slot 1 can only take 3 of its 4 room
	eq(a[1].count, 63); eq(a[2].count, 3); eq(a[4].count, 3); eq(a[3].item, "stone")
	assert(cur and cur.count == 1, "remainder stays on the cursor")
	local b = {}
	local cur2 = SlotLogic.drag({ { slots = b, index = 1 }, { slots = b, index = 2 }, { slots = b, index = 3 } }, { item = "sand", count = 2 }, "right")
	eq(b[1].count, 1); eq(b[2].count, 1); eq(b[3], nil); eq(cur2, nil)
	local c = {}
	local cur3 = SlotLogic.drag({ { slots = c, index = 1 }, { slots = c, index = 2 }, { slots = c, index = 3 } }, { item = "sand", count = 2 }, "left")
	eq(cur3.count, 2); eq(c[1], nil) -- more slots than items: nothing happens
end)

test("double-click collect: menu order, partial stacks first, up to 64", function()
	local grid = { [1] = { item = "stick", count = 10 } }
	local inv = { [10] = { item = "stick", count = 64 }, [11] = { item = "dirt", count = 5 }, [12] = { item = "stick", count = 30 }, [1] = { item = "stick", count = 20 } }
	local refs = { { slots = grid, index = 1 } }
	for k = 10, 36 do
		table.insert(refs, { slots = inv, index = k })
	end
	for k = 1, 9 do
		table.insert(refs, { slots = inv, index = k })
	end
	local cursor = { item = "stick", count = 5 }
	SlotLogic.collect(refs, cursor)
	-- pass 1 skips the full stack: 5 + 10 (grid) + 30 + 19 of the hotbar's 20
	eq(cursor.count, 64)
	eq(grid[1], nil)
	eq(inv[12], nil)
	eq(inv[1].count, 1)
	eq(inv[10].count, 64)
	eq(inv[11].count, 5)
end)
test("mob snapshot codec: round trip, packets stay small", function()
	local Codec = Loader.require("src/shared/Mobs/MobSnapshotCodec")
	local recs = {}
	for i = 1, 75 do
		table.insert(recs, { id = i * 7, code = 4, flags = 3, x = i * 1.5, y = 200.25, z = -i * 3.5, yaw = 3.0, pitch = -0.5 })
	end
	local packets = Codec.encode(recs)
	eq(#packets, 3)
	local back = {}
	for _, p in packets do
		assert(buffer.len(p) <= 600, "packet too big: " .. buffer.len(p))
		for _, r in Codec.decode(p) do
			table.insert(back, r)
		end
	end
	eq(#back, 75)
	eq(back[10].id, 70); eq(back[10].code, 4); eq(back[10].flags, 3)
	assert(math.abs(back[10].x - 15) < 1e-4 and math.abs(back[10].z + 35) < 1e-4)
	assert(math.abs(back[10].yaw - 3.0) < 1e-3 and math.abs(back[10].pitch + 0.5) < 1e-3)
end)

print("Survival rules")
local SurvivalRules = Loader.require("src/shared/Gameplay/SurvivalRules")
test("exhaustion drains saturation first, then food", function()
	local h = SurvivalRules.newHunger()
	SurvivalRules.addExhaustion(h, 4 * 5) -- 5 points: all saturation
	eq(h.saturation, 0); eq(h.food, 20)
	SurvivalRules.addExhaustion(h, 4 * 3 + 1)
	eq(h.food, 17); assert(math.abs(h.exhaustion - 1) < 1e-9)
end)
test("eating caps food at 20 and saturation at food", function()
	local h = SurvivalRules.newHunger()
	h.food, h.saturation = 10, 0
	SurvivalRules.eat(h, 8, 12.8) -- steak
	eq(h.food, 18); eq(h.saturation, 12.8)
	SurvivalRules.eat(h, 8, 12.8)
	eq(h.food, 20); eq(h.saturation, 20)
end)
test("regeneration and starvation timings", function()
	local h = SurvivalRules.newHunger() -- food 20, sat 5: fast regen
	h.saturation = 20
	local heal = SurvivalRules.tick(h, 2.0, 10, 20, 1)
	eq(heal, 4) -- saturation >= 6: 1 HP / 0.5 s
	h.saturation, h.regenTimer = 3, 0
	heal = SurvivalRules.tick(h, 0.5, 10, 20, 1)
	eq(heal, 0.5) -- saturation 3: 3/6 HP per 0.5 s
	h.food, h.saturation, h.regenTimer = 18, 0, 0
	heal = SurvivalRules.tick(h, 8.0, 10, 20, 1)
	eq(heal, 2) -- 1 HP / 4 s
	h.food, h.saturation = 17, 0
	heal = SurvivalRules.tick(h, 8.0, 10, 20, 1)
	eq(heal, 0)
	h.food = 0
	local _, dmg = SurvivalRules.tick(h, 12.0, 10, 20, 1)
	eq(dmg, 3) -- 1 / 4 s
	local _, dmg2 = SurvivalRules.tick(h, 40.0, 2, 20, 1)
	eq(dmg2, 1) -- Normal: never below 1 HP
end)
test("fall damage and sprint threshold", function()
	eq(SurvivalRules.fallDamage(3, false), 0)
	eq(SurvivalRules.fallDamage(3.5, false), 1)
	eq(SurvivalRules.fallDamage(4, false), 1)
	eq(SurvivalRules.fallDamage(23, false), 20)
	eq(SurvivalRules.fallDamage(50, true), 0)
	local h = SurvivalRules.newHunger()
	h.food = 6
	assert(not SurvivalRules.canSprint(h))
	h.food = 7
	assert(SurvivalRules.canSprint(h))
end)

print("Mobs / combat")
local MobPhysics = Loader.require("src/shared/Mobs/MobPhysics")
local Pathfinder = Loader.require("src/shared/Mobs/Pathfinder")
local Combat = Loader.require("src/shared/Gameplay/Combat")
local MobDefs = Loader.require("src/shared/Mobs/MobDefs")
-- flat floor at y = 0 (solid y <= 0), a wall at x = 5 from y = 1..2 for z = -10..10
local function world(x: number, y: number, z: number): boolean
	if y <= 0 then
		return true
	end
	if x == 5 and y <= 2 and z >= -10 and z <= 10 then
		return true
	end
	return false
end
test("mob physics: falls onto the floor, stops at walls", function()
	local x, y, z, vx, vy, vz, ground = 0.5, 3, 0.5, 0, 0, 0, false
	for _ = 1, 40 do
		vy -= 32 * 0.05
		x, y, z, vx, vy, vz, ground = MobPhysics.move(world, x, y, z, vx, vy, vz, 0.6, 1.9, 0.05)
	end
	assert(math.abs(y - 1) < 1e-6, "feet on the floor top, got " .. y)
	assert(ground, "on ground")
	local hit
	for _ = 1, 40 do
		x, y, z, vx, vy, vz, ground, hit = MobPhysics.move(world, x, y, z, 3, 0, 0, 0.6, 1.9, 0.05)
	end
	assert(x <= 5 - 0.3 and x > 4.6, "stopped at the wall, x = " .. x)
	assert(hit, "hit wall")
end)
test("pathfinder walks around a wall and steps up", function()
	local path, reached = Pathfinder.find(world, 0, 1, 0, 9, 1, 0, { height = 2, maxNodes = 2000 })
	assert(path and reached, "path around the 21-long wall")
	for _, c in path do
		assert(not (c[1] == 5 and c[3] >= -10 and c[3] <= 10), "walked through the wall")
	end
	-- single block step
	local function step(x: number, y: number, z: number): boolean
		return y <= 0 or (x >= 3 and y <= 1)
	end
	local p2, r2 = Pathfinder.find(step, 0, 1, 0, 6, 2, 0, { height = 2 })
	assert(p2 and r2, "step up onto the ledge")
	eq(p2[#p2][2], 2)
	-- and back down a 2-block drop
	local function cliff(x: number, y: number, z: number): boolean
		return y <= 0 or (x <= 2 and y <= 2)
	end
	local p3, r3 = Pathfinder.find(cliff, 0, 3, 0, 6, 1, 0, { height = 2 })
	assert(p3 and r3, "walk off a 2-block ledge")
	eq(p3[#p3][2], 1)
	local p4, r4 = Pathfinder.find(cliff, 0, 3, 0, 6, 1, 0, { height = 2, maxDrop = 1 })
	assert(not r4, "a 2-block drop is too far with maxDrop 1")
	_ = p4
end)
local SkyLight = Loader.require("src/shared/World/SkyLight")
local function near(a: number, b: number, tol: number?, msg: string?)
	assert(math.abs(a - b) <= (tol or 1e-6), `{msg or ""} expected {b}, got {a}`)
end
test("combat: Java attack cooldown, damage scaling, item stats", function()
	local d, speed = Combat.attackStats("diamond_sword")
	eq(d, 7); eq(speed, 1.6)
	eq(Combat.attackStats(nil), 1)
	eq(select(2, Combat.attackStats(nil)), 4)
	-- axes and hoes: per-tier attack speed
	eq(select(2, Combat.attackStats("wooden_axe")), 0.8)
	eq(select(2, Combat.attackStats("iron_axe")), 0.9)
	eq(select(2, Combat.attackStats("diamond_axe")), 1.0)
	eq(select(2, Combat.attackStats("stone_hoe")), 2)
	eq(select(2, Combat.attackStats("diamond_hoe")), 4)
	eq(Combat.attackStats("stone_axe"), 9)
	-- charge = (ticks + 0.5) / (20 / speed)
	eq(Combat.charge(1, 1.6), 1)
	near(Combat.charge(0, 1.6), 0.5 / 12.5)
	near(Combat.charge(0.3, 1.6), 6.5 / 12.5) -- 6 ticks
	eq(Combat.scaledDamage(7, 1), 7)
	near(Combat.scaledDamage(10, 0), 2, 1e-9, "uncharged = 20%")
	-- a sword is fully charged after 12 ticks (0.6 s) for crit purposes (> 0.9)
	assert(Combat.charge(0.55, 1.6) > 0.9, "11 ticks: 0.92 charge")
	assert(Combat.charge(0.5, 1.6) <= 0.9, "10 ticks: 0.84 charge")
	eq(Combat.explosionDamage(3, 0), 43) -- point-blank power-3 explosion (Normal)
	eq(Combat.explosionDamage(3, 6), 0)
	-- durability: swords 1 per hit, tools 2, shears 0
	eq(Combat.hitDurabilityCost("iron_sword"), 1)
	eq(Combat.hitDurabilityCost("iron_pickaxe"), 2)
	eq(Combat.hitDurabilityCost("golden_hoe"), 2)
	eq(Combat.hitDurabilityCost("shears"), 0)
	eq(Combat.hitDurabilityCost(nil), 0)
	assert(MobDefs.byKey.sneaker and MobDefs.byCode[4].key == "sneaker")
	for _, m in MobDefs.list do
		for _, drop in m.drops do
			assert(ItemRegistry.get(drop.item), `{m.key} drops unknown item {drop.item}`)
		end
	end
end)
test("combat: critical hits, knockback, invulnerability, armor", function()
	local base = { charge = 1, falling = true, onGround = false, sprinting = false, inLiquid = false }
	assert(Combat.isCrit(base), "falling full-charge hit is a crit")
	local function with(k: string, v: any)
		local c = table.clone(base) :: any
		c[k] = v
		return Combat.isCrit(c)
	end
	assert(not with("charge", 0.85), "needs > 0.9 charge")
	assert(not with("falling", false), "needs falling")
	assert(not with("onGround", true), "not on ground")
	assert(not with("sprinting", true), "not sprinting")
	assert(not with("inLiquid", true), "not in water")
	-- knockback 0.4 on the ground: half the old velocity plus the push, 0.4 up
	local x, y, z = Combat.knockback(0, 0, 0, 3, 4, 0.4, true)
	near(x, 0.24); near(y, 0.4); near(z, 0.32)
	local _, y2 = Combat.knockback(0, -0.5, 0, 1, 0, 0.4, false)
	near(y2, -0.5, 1e-9, "no vertical push in the air")
	local x3 = Combat.knockback(0.2, 0, 0, 1, 0, 0.4, true)
	near(x3, 0.5)
	-- invulnerability: 0.5 s, stronger hits deal the difference
	local h = { invulnUntil = 0, lastHurt = 0 }
	local dealt, fresh = Combat.applyInvulnerability(h, 4, 10)
	eq(dealt, 4); eq(fresh, true)
	dealt, fresh = Combat.applyInvulnerability(h, 3, 10.2)
	eq(dealt, 0); eq(fresh, false)
	dealt, fresh = Combat.applyInvulnerability(h, 7, 10.3)
	eq(dealt, 3); eq(fresh, false)
	dealt, fresh = Combat.applyInvulnerability(h, 2, 10.6)
	eq(dealt, 2); eq(fresh, true)
	-- armor (zombie: 2 points)
	near(Combat.armorReduce(7, 2), 7 * (1 - 0.4 / 25))
	near(Combat.armorReduce(1, 2), 1 * (1 - 1.5 / 25))
	eq(Combat.armorReduce(5, 0), 5)
end)
test("mining durability: swords 2, tools 1, instant blocks 0", function()
	local stone = BlockRegistry.id("stone")
	eq(Mining.durabilityCost(stone, "iron_pickaxe"), 1)
	eq(Mining.durabilityCost(stone, "iron_sword"), 2)
	eq(Mining.durabilityCost(stone, "shears"), 1)
	eq(Mining.durabilityCost(stone, nil), 0)
	eq(Mining.durabilityCost(stone, "stick"), 0)
end)
test("mob stats: Java speeds and sizes", function()
	-- 43.17 * s^2 blocks/s
	near(MobDefs.byKey.zombie.speed, 2.28, 0.01)
	near(MobDefs.byKey.spider.speed, 3.89, 0.01)
	near(MobDefs.blocksPerSecond(0.1 * 1), 0.4317, 0.001)
	eq(MobDefs.byKey.sneaker.height, 1.7)
	eq(MobDefs.byKey.voidling.height, 2.9)
	eq(MobDefs.byKey.voidling.followRange, 64)
	eq(MobDefs.byKey.zombie.followRange, 35)
	eq(MobDefs.byKey.zombie.spawnWeight, 95)
	eq(MobDefs.byKey.skeleton.shootRange, 15)
end)
test("sky light: darkening, brightness and monster spawn light", function()
	eq(SkyLight.skyDarken(6000), 0) -- noon
	eq(SkyLight.skyDarken(18000), 11) -- midnight
	assert(SkyLight.isDay(1000) and not SkyLight.isDay(18000))
	eq(SkyLight.rawBrightness(true, 18000), 4) -- moonlight
	eq(SkyLight.rawBrightness(false, 6000), 0)
	near(SkyLight.magicBrightness(15), 1)
	near(SkyLight.magicBrightness(12), 0.5)
	assert(not SkyLight.monsterCanSpawn(true, 6000, 31, 7), "never under the noon sky")
	assert(SkyLight.monsterCanSpawn(true, 18000, 20, 5), "night sky: sky 15 <= 20, light 4 <= 5")
	assert(not SkyLight.monsterCanSpawn(true, 18000, 10, 7), "sky light 15 > 10 fails")
	assert(SkyLight.monsterCanSpawn(false, 6000, 0, 0), "caves always dark")
end)

local Base64 = Loader.require("src/shared/Util/Base64")
local SaveFormat = Loader.require("src/shared/Persistence/SaveFormat")
test("base64 round trip (all byte values, every padding)", function()
	local all = {}
	for i = 0, 255 do
		all[#all + 1] = string.char(i)
	end
	local bytes = table.concat(all)
	for len = 0, 7 do
		local s = string.sub(bytes, 1, len)
		eq(Base64.decode(Base64.encode(s)), s)
	end
	eq(Base64.decode(Base64.encode(bytes)), bytes)
	eq(Base64.encode("Man"), "TWFu")
	eq(Base64.encode("Ma"), "TWE=")
	eq(Base64.decode("not base64!"), nil)
end)
test("save format: regions round trip diffs and containers", function()
	local key = ChunkData.key(-3, 5)
	local diffs = { [0] = 1, [123] = 0, [32767] = 200 }
	local region = {
		chunks = { [key] = diffs, [ChunkData.key(-4, 4)] = {} },
		entities = {
			{ kind = "chest", x = -40, y = 60, z = 70, slots = { [1] = { item = "stick", count = 5 }, [27] = { item = "iron_pickaxe", count = 1, durability = 100 } }, burn = 0, burnMax = 0, progress = 0 },
			{ kind = "furnace", x = -41, y = 60, z = 70, slots = { [1] = { item = "raw_iron", count = 3 } }, burn = 4.5, burnMax = 80, progress = 2 },
		},
	}
	local encoded = SaveFormat.encodeRegion(region)
	eq(encoded.v, 1)
	local back = SaveFormat.decodeRegion(encoded)
	eq(back.chunks[key][0], 1)
	eq(back.chunks[key][123], 0)
	eq(back.chunks[key][32767], 200)
	eq(back.chunks[ChunkData.key(-4, 4)], nil) -- empty chunks aren't stored
	eq(#back.entities, 2)
	eq(back.entities[1].slots[27].durability, 100)
	eq(back.entities[2].burn, 4.5)
	eq(back.entities[2].slots[1].item, "raw_iron")
	-- every stored string must be plain text (DataStores reject invalid UTF-8)
	for _, text in encoded.chunks do
		assert(string.match(text, "^[%w%+/=]*$"), "chunk data is Base64")
	end
	-- garbage in -> empty region, unknown items dropped
	eq(next(SaveFormat.decodeRegion(nil).chunks), nil)
	local bad = SaveFormat.decodeStacks({ { 1, "no_such_item", 3 }, { 2, "stick", 99 }, { 3, "stick", 2 } }, 36)
	eq(bad[1], nil); eq(bad[2], nil); eq(bad[3].count, 2)
end)
test("save format: player state round trip, clamps bad values", function()
	local V3 = Loader.globals.Vector3
	local st = {
		slots = { [1] = { item = "bread", count = 7 }, [36] = { item = "stone_sword", count = 1, durability = 3 } },
		selected = 4, health = 13.5, food = 12, saturation = 2.5, exhaustion = 1.25, air = 15,
		pos = V3.new(10.5, 64, -3.25), yaw = 1.5,
	}
	local back = SaveFormat.decodePlayer(SaveFormat.encodePlayer(st), 36)
	assert(back)
	eq(back.slots[1].count, 7)
	eq(back.slots[36].durability, 3)
	eq(back.selected, 4); eq(back.health, 13.5); eq(back.food, 12)
	eq(back.pos.Y, 64); eq(back.yaw, 1.5)
	local weird = SaveFormat.decodePlayer({ hp = 999, food = -5, sel = 42, pos = { "x" } }, 36)
	assert(weird)
	eq(weird.health, 20); eq(weird.food, 0); eq(weird.selected, 9); eq(weird.pos, nil)
	eq(SaveFormat.decodePlayer("nope", 36), nil)
	-- keys and regions
	eq(SaveFormat.regionKey(42, -1, 3), "w:42:r:-1:3")
	local rx, rz = SaveFormat.regionOf(-1, 4)
	eq(rx, -1); eq(rz, 1)
end)

local PlayerPhysics = Loader.require("src/shared/Gameplay/PlayerPhysics")
-- Java reference run: forward input, jump held, flat ground or a ceiling; returns blocks/s.
local function javaRun(sprint: boolean, jump: boolean, ceiling: number?): number
	local sx, y, vy, ground, delay, x = 0, 0, 0, true, 0, 0
	local input = PlayerPhysics.INPUT_DAMPING
	for _ = 1, 2000 do
		if delay > 0 then
			delay -= 1
		end
		if jump and ground and delay == 0 then
			vy = PlayerPhysics.JUMP_VELOCITY
			if sprint then
				sx += PlayerPhysics.SPRINT_JUMP_BOOST
			end
			delay = PlayerPhysics.JUMP_DELAY_TICKS
		end
		local dx, _, nsx = PlayerPhysics.tick(sx, 0, input, 0, ground, sprint)
		x += dx
		sx = nsx
		local ny = y + vy
		if ceiling and ny > ceiling - 1.8 then
			ny, vy = ceiling - 1.8, 0
		end
		if ny <= 0 then
			ny, vy, ground = 0, 0, true
		else
			ground = false
			vy = PlayerPhysics.verticalAfter(vy)
		end
		y = ny
	end
	return x / 2000 * 20
end
test("player physics: Java walk, sprint and sprint-jump speeds", function()
	near(javaRun(false, false), 4.317, 0.005, "walk")
	near(javaRun(true, false), 5.612, 0.005, "sprint")
	near(javaRun(true, true), 7.127, 0.03, "held sprint-jump (wiki 7.127)")
	assert(javaRun(true, true, 2.0) > 5.612, "sprint-jumping in a 2-high tunnel beats sprinting")
	local bx, bz = PlayerPhysics.jumpBoost(0, -1)
	eq(bx, 0); near(bz, -0.2)
end)

print(`\n{passed} passed, {failed} failed`)
if failed > 0 then
	process.exit(1)
end
