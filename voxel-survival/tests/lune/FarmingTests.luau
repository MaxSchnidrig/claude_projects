--!nocheck
-- Phase 9a farming: the pure rules (Gameplay/Farming), placement, the mesher's sheets, world
-- generation of plants, and the REAL server/Simulation/FarmingService in a fake Roblox.
--
-- Usage (from run.luau):  require("./FarmingTests")(test, eq)

local Loader = require("./Loader")
local Fake = require("./FakeRoblox")

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	print("Farming (Phase 9a)")
	local BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry")
	local Farming = Loader.require("src/shared/Gameplay/Farming")
	local Placement = Loader.require("src/shared/Blocks/Placement")
	local Shapes = Loader.require("src/shared/Blocks/Shapes")
	local id = BlockRegistry.id
	local STONE, DIRT, GRASS, WATER = id("stone"), id("dirt"), id("grass_block"), id("water")
	local FARM0, FARM7 = Farming.farmland(0), Farming.farmland(7)
	local WHEAT0 = Farming.cropId("wheat", 0)

	local function world(cells: { [string]: number }, floor: number?)
		return function(x: number, y: number, z: number): number?
			return cells[`{x},{y},{z}`] or (if y < (floor or 0) then STONE else 0)
		end
	end

	test("farming rules: Java crop growth speed, chances, bone meal, drops, trampling", function()
		-- a crop alone in the middle of 3x3 wet farmland: 1 + 3 + 8 x 3/4 = 10 -> 1 in 3
		local cells = {}
		for dx = -1, 1 do
			for dz = -1, 1 do
				cells[`{dx},0,{dz}`] = FARM7
			end
		end
		cells["0,1,0"] = WHEAT0
		local get = world(cells)
		eq(Farming.growthSpeed("wheat", 0, 1, 0, get), 10)
		eq(Farming.growChance(10), 1 / 3)
		-- dry farmland: 1 + 1 + 8 x 1/4 = 4 -> 1 in 7
		for k in cells do
			if string.sub(k, -2) ~= "1,0" and cells[k] == FARM7 then
				cells[k] = FARM0
			end
		end
		cells["0,1,0"] = WHEAT0
		eq(Farming.growthSpeed("wheat", 0, 1, 0, get), 4)
		eq(Farming.growChance(4), 1 / 7)
		-- the same crop on both axes halves it (Java rows rule); a row on one axis doesn't
		cells["1,1,0"] = WHEAT0
		eq(Farming.growthSpeed("wheat", 0, 1, 0, get), 4)
		cells["0,1,1"] = WHEAT0
		eq(Farming.growthSpeed("wheat", 0, 1, 0, get), 2)
		cells["0,1,1"] = nil
		cells["1,1,0"] = nil
		cells["1,1,1"] = Farming.cropId("wheat", 3) -- diagonal neighbour
		eq(Farming.growthSpeed("wheat", 0, 1, 0, get), 2)
		cells["1,1,1"] = Farming.cropId("carrots", 3) -- another crop doesn't count
		eq(Farming.growthSpeed("wheat", 0, 1, 0, get), 4)
		-- bone meal: 2..5 ages, capped; beetroots +1
		local info = Farming.crop(WHEAT0)
		for _ = 1, 50 do
			local a = Farming.bonemealAge(info, function(lo, hi)
				return math.random(lo, hi)
			end)
			assert(a >= 2 and a <= 5, "bone meal 2..5")
		end
		eq(Farming.bonemealAge(Farming.crop(Farming.cropId("wheat", 6)), function()
			return 5
		end), 7)
		eq(Farming.bonemealAge(Farming.crop(Farming.cropId("beetroots", 0)), function()
			return 5
		end), 1)
		-- drops
		local function sum(list, item)
			local n = 0
			for _, s in list do
				if s.item == item then
					n += s.count
				end
			end
			return n
		end
		for _ = 1, 200 do
			local d = Farming.drops(Farming.cropId("wheat", 7), nil, math.random)
			eq(sum(d, "wheat"), 1)
			local seeds = sum(d, "wheat_seeds")
			assert(seeds >= 1 and seeds <= 4, "1..4 seeds")
			local c = sum(Farming.drops(Farming.cropId("carrots", 7), nil, math.random), "carrot")
			assert(c >= 1 and c <= 4, "1..4 carrots")
		end
		eq(sum(Farming.drops(WHEAT0, nil, math.random), "wheat_seeds"), 1)
		eq(sum(Farming.drops(WHEAT0, nil, math.random), "wheat"), 0)
		eq(sum(Farming.drops(Farming.cropId("potatoes", 2), nil, math.random), "potato"), 1)
		eq(sum(Farming.drops(Farming.cropId("beetroots", 3), nil, function()
			return 0
		end), "beetroot_seeds"), 4)
		local poison = Farming.drops(Farming.cropId("potatoes", 7), nil, function()
			return 0.01
		end)
		eq(sum(poison, "poisonous_potato"), 1)
		-- short grass: 1 in 8 seeds; shears give the grass
		eq(sum(Farming.drops(id("short_grass"), "shears", math.random), "short_grass"), 1)
		eq(#Farming.drops(id("short_grass"), nil, function()
			return 0.2
		end), 0)
		eq(sum(Farming.drops(id("short_grass"), nil, function()
			return 0.1
		end), "wheat_seeds"), 1)
		eq(Farming.drops(STONE, nil, math.random), nil)
		eq(Farming.trampleChance(1.2522), 1.2522 - 0.5)
		eq(Farming.trampleChance(0.3), 0)
		-- water near farmland: 4 across, same level or one up
		local wcells = { ["4,0,0"] = WATER }
		eq(Farming.waterNear(0, 0, 0, world(wcells)), true)
		wcells = { ["5,0,0"] = WATER }
		eq(Farming.waterNear(0, 0, 0, world(wcells)), false)
		wcells = { ["0,-1,2"] = WATER }
		eq(Farming.waterNear(0, 0, 0, world(wcells)), false)
		wcells = { ["0,1,2"] = WATER }
		eq(Farming.waterNear(0, 0, 0, world(wcells)), true)
	end)

	test("farming placement: seeds on farmland only, flowers on grass, blocks replace short grass", function()
		local cells = { ["0,0,0"] = FARM0, ["1,0,0"] = DIRT, ["2,0,0"] = GRASS, ["3,0,0"] = STONE, ["2,1,0"] = id("short_grass") }
		local get = world(cells)
		local function ctx(hx, hy, hz, nx, ny, nz)
			return { hx = hx, hy = hy, hz = hz, nx = nx, ny = ny, nz = nz, px = hx + 0.5, py = hy + 1, pz = hz + 0.5, lx = 0, lz = -1 }
		end
		local c = Placement.resolve(WHEAT0, ctx(0, 0, 0, 0, 1, 0), get)
		assert(c, "wheat on farmland")
		eq(c[1].y, 1)
		eq(Placement.resolve(WHEAT0, ctx(1, 0, 0, 0, 1, 0), get), nil, "not on dirt")
		eq(Placement.resolve(Farming.cropId("carrots", 0), ctx(3, 0, 0, 0, 1, 0), get), nil, "not on stone")
		assert(Placement.resolve(id("dandelion"), ctx(1, 0, 0, 0, 1, 0), get), "flower on dirt")
		eq(Placement.resolve(id("dandelion"), ctx(3, 0, 0, 0, 1, 0), get), nil, "no flower on stone")
		-- clicking short grass places into its cell
		c = Placement.resolve(STONE, ctx(2, 1, 0, 0, 1, 0), get)
		assert(c, "stone onto grass")
		eq(c[1].y, 1, "into the grass's cell")
		eq(Placement.replaceable(id("short_grass")), true)
		eq(Placement.replaceable(id("poppy")), false)
		-- support
		eq((Placement.supported(WHEAT0, 0, 1, 0, get)), true)
		cells["0,0,0"] = DIRT
		eq((Placement.supported(WHEAT0, 0, 1, 0, get)), false)
		-- aiming outlines: crops grow taller, flowers are small
		eq(Shapes.outline(Farming.cropId("wheat", 0), get)[1][5], 2 / 16)
		eq(Shapes.outline(Farming.cropId("wheat", 7), get)[1][5], 1)
		eq(Shapes.outline(Farming.cropId("beetroots", 1), get)[1][5], 8 / 16)
		eq(Shapes.outline(id("poppy"), get)[1][1], 5 / 16)
		-- no collision; farmland is 15/16 high
		eq(#Shapes.boxes(WHEAT0, get, true), 0)
		eq(#Shapes.boxes(id("short_grass"), get, true), 0)
		eq(Shapes.boxes(FARM0, get, true)[1][5], 15 / 16)
	end)

	test("farming mesh: plants are drawn only where their pixels are (X for grass, # for crops)", function()
		local GreedyMesher = Loader.require("src/shared/Meshing/GreedyMesher")
		local SectionSampler = Loader.require("src/shared/Meshing/SectionSampler")
		local PlantGeometry = Loader.require("src/shared/Meshing/PlantGeometry")
		local TextureGen = Loader.require("src/shared/Blocks/TextureGen")
		-- every plant texture: the rectangles cover each solid pixel exactly once and nothing else
		for idx, key in BlockRegistry.textureKeys do
			local isPlant = false
			for _, d in BlockRegistry.byId do
				if (d.shape == "plant" or d.shape == "crop") and BlockRegistry.textureKeys[d.faceTexture[1]] == key then
					isPlant = true
				end
			end
			if isPlant then
				local img = TextureGen.generate(key)
				local hits = table.create(256, 0)
				local rects = PlantGeometry.rects(idx)
				assert(#rects <= 8, `{key}: {#rects} strips (keep plants cheap)`)
				for _, r in rects do
					for y = r[2], r[4] - 1 do
						for x = r[1], r[3] - 1 do
							assert(buffer.readu8(img, (y * 16 + x) * 4 + 3) >= 128, `{key}: a strip shows a see-through pixel`)
							hits[y * 16 + x + 1] += 1
						end
					end
				end
				for i = 0, 255 do
					local solid = buffer.readu8(img, i * 4 + 3) >= 128
					eq(hits[i + 1], if solid then 1 else 0, `{key}: pixel {i} drawn once if solid`)
				end
			end
		end
		local P = SectionSampler.SIZE
		local function meshOne(block: number, below: number?)
			local padded = buffer.create(SectionSampler.BYTES)
			buffer.writeu16(padded, ((5 + 1) + (5 + 1) * P + (5 + 1) * P * P) * 2, block)
			if below then
				buffer.writeu16(padded, ((5 + 1) + (5 + 1) * P + (4 + 1) * P * P) * 2, below)
			end
			local light = buffer.create(SectionSampler.VOLUME)
			buffer.fill(light, 0, 15)
			return GreedyMesher.meshLit(padded, light, {})
		end
		local function byDir(r, tex)
			local count = {}
			local list = r.groups[tex] or {}
			for q = 1, #list, GreedyMesher.QUAD do
				local d = list[q]
				count[d] = (count[d] or 0) + 1
				if d >= 7 then
					local c = GreedyMesher.quadCorners(d, list[q + 1], list[q + 2], list[q + 3], list[q + 4], list[q + 5])
					for v = 1, 12, 3 do
						assert(c[v] >= 5 - 1e-9 and c[v] <= 6 + 1e-9 and c[v + 2] >= 5 - 1e-9 and c[v + 2] <= 6 + 1e-9, "inside its block")
						assert(c[v + 1] >= 5 - 1e-9 and c[v + 1] <= 6 + 1e-9, "no taller than the block")
					end
				end
			end
			return count
		end
		local grassTex = BlockRegistry.byId[id("short_grass")].faceTexture[1]
		local strips = #PlantGeometry.rects(grassTex)
		local g = byDir(meshOne(id("short_grass"), GRASS), grassTex)
		for d = 7, 10 do
			eq(g[d], strips, `X sheet {d}: one piece per strip`)
		end
		eq(g[11], nil)
		local wheatTex = BlockRegistry.byId[WHEAT0].faceTexture[1]
		local w = byDir(meshOne(WHEAT0, FARM0), wheatTex)
		for d = 11, 14 do
			eq(w[d], 2 * #PlantGeometry.rects(wheatTex), `# sheet {d}: two sheets, one piece per strip`)
		end
		-- front and back of each sheet face opposite ways
		local function normal(d)
			local c = GreedyMesher.quadCorners(d, 0, 0, 0, 1, 1)
			local ux, uy, uz = c[4] - c[1], c[5] - c[2], c[6] - c[3]
			local vx, vy, vz = c[10] - c[1], c[11] - c[2], c[12] - c[3]
			return { uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx }
		end
		for d = 7, 13, 2 do
			local a, b = normal(d), normal(d + 1)
			assert(math.abs(a[1] + b[1]) < 1e-9 and math.abs(a[3] + b[3]) < 1e-9 and (a[1] ~= 0 or a[3] ~= 0), `sides of {d}`)
		end
	end)

	test("world generation: grass and flowers only on grass, everything else unchanged", function()
		local TerrainGen = Loader.require("src/shared/World/TerrainGen")
		local ChunkData = Loader.require("src/shared/World/ChunkData")
		local Config = Loader.require("src/shared/Config")
		local gen = TerrainGen.new(1337)
		local plants, flowers, grassTops = 0, 0, 0
		local SHORT, DAND, POP = id("short_grass"), id("dandelion"), id("poppy")
		for cx = -3, 3 do
			for cz = -3, 3 do
				local c = ChunkData.new(cx, cz)
				TerrainGen.generate(gen, c)
				for y = 1, Config.WORLD_HEIGHT - 1 do
					for z = 0, 15 do
						for x = 0, 15 do
							local b = ChunkData.get(c, x, y, z)
							if b == SHORT or b == DAND or b == POP then
								plants += 1
								if b ~= SHORT then
									flowers += 1
								end
								eq(ChunkData.get(c, x, y - 1, z), GRASS, "plants stand on grass")
							elseif b == GRASS and ChunkData.get(c, x, y + 1, z) == 0 then
								grassTops += 1
							end
						end
					end
				end
			end
		end
		assert(plants > 0, "some plants")
		assert(plants < (plants + grassTops) * 0.4, `not too dense ({plants} / {plants + grassTops})`)
		print(`       generated {plants} plants ({flowers} flowers) on {plants + grassTops} grass tops`)
		-- the same seed gives the same plants
		local a, b = ChunkData.new(2, -1), ChunkData.new(2, -1)
		TerrainGen.generate(gen, a)
		TerrainGen.generate(TerrainGen.new(1337), b)
		eq(buffer.tostring(a.blocks) == buffer.tostring(b.blocks), true)
	end)

	test("server random ticks: 3 picks per section near players reach the crops and grow them", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/server/")
		local ChunkData = Loader.require("src/shared/World/ChunkData")
		local chunk = ChunkData.new(0, 0)
		local FLOOR = 64
		for z = 0, 15 do
			for x = 0, 15 do
				for y = 0, FLOOR - 1 do
					ChunkData.set(chunk, x, y, z, STONE)
				end
				ChunkData.set(chunk, x, FLOOR - 1, z, FARM7)
				ChunkData.set(chunk, x, FLOOR, z, WHEAT0)
			end
		end
		local tickFns = {}
		Loader.stubs["src/server/World/WorldService.luau"] = {
			getChunk = function(key)
				return if key == ChunkData.key(0, 0) then chunk else nil
			end,
			getBlockIfLoaded = function(x, y, z)
				if x < 0 or x > 15 or z < 0 or z > 15 then
					return nil
				end
				return ChunkData.get(chunk, x, y, z)
			end,
			blockLightAt = function()
				return 0
			end,
		}
		Loader.stubs["src/server/World/BlockUpdates.luau"] = {
			set = function(x, y, z, b)
				ChunkData.set(chunk, x, y, z, b)
			end,
			schedule = function() end,
			register = function() end,
			onNeighbourChanged = function() end,
			onTick = function(fn)
				table.insert(tickFns, fn)
			end,
		}
		Loader.stubs["src/server/World/ItemEntityService.luau"] = { spawn = function() end }
		Loader.stubs["src/server/Player/InventoryService.luau"] = {}
		Loader.stubs["src/shared/Net/Remotes.luau"] = { get = function() return Fake.Instance.new("RemoteEvent") end }
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local RandomTicks = Loader.require("src/server/World/RandomTicks")
		local FS = Loader.require("src/server/Simulation/FarmingService")
		RandomTicks.init()
		FS.init()
		-- a player standing in the field (random ticks only run near players)
		local c = Fake.newCharacter("Tester", Fake.CFrame.new(8 * 3, (FLOOR + 1) * 3 + 3, 8 * 3))
		c.Parent = G.workspace
		G.player.Character = c
		-- 6000 game ticks = 5 minutes
		for _ = 1, 6000 do
			for _, fn in tickFns do
				fn()
			end
		end
		local grown, ripe = 0, 0
		for z = 0, 15 do
			for x = 0, 15 do
				local info = Farming.crop(ChunkData.get(chunk, x, FLOOR, z))
				if info and info.age > 0 then
					grown += 1
				end
				if info and info.age == 7 then
					ripe += 1
				end
			end
		end
		print(`       5 minutes near a 16x16 wheat field: {grown} of 256 grew, {ripe} ripe ({RandomTicks.stats.chunks} chunk ticking)`)
		-- Java: each block gets 6000 x 3 / 4096 = 4.4 random ticks; a crop in a full field grows
		-- with chance 1 in 6 (speed 10 halved for crops on both sides): about 55 % grow once
		assert(grown > 256 * 0.35 and grown < 256 * 0.75, `about half grew ({grown})`)
		assert(ripe < 256, "but not all ripe yet (Java: about half an hour)")
		for _, path in {
			"src/server/World/WorldService.luau", "src/server/World/BlockUpdates.luau", "src/server/World/ItemEntityService.luau",
			"src/server/Player/InventoryService.luau", "src/shared/Net/Remotes.luau",
		} do
			Loader.stubs[path] = nil
		end
		Loader.forget("src/server/")
	end)

	test("9b placement and shapes: sugar cane by water, cactus alone on sand, stems, saplings", function()
		local SAND, CANE, CACTUS = id("sand"), id("sugar_cane"), id("cactus")
		local cells = { ["0,0,0"] = SAND, ["1,0,0"] = WATER, ["5,0,0"] = SAND, ["9,0,0"] = SAND, ["10,1,0"] = STONE,
			["12,0,0"] = FARM0, ["14,0,0"] = GRASS }
		local get = world(cells)
		local function ctx(hx, hy, hz)
			return { hx = hx, hy = hy, hz = hz, nx = 0, ny = 1, nz = 0, px = hx + 0.5, py = hy + 1, pz = hz + 0.5, lx = 0, lz = -1 }
		end
		assert(Placement.resolve(CANE, ctx(0, 0, 0), get), "cane on sand beside water")
		eq(Placement.resolve(CANE, ctx(5, 0, 0), get), nil, "no cane without water")
		cells["0,1,0"] = CANE
		assert(Placement.resolve(CANE, ctx(0, 1, 0), get), "cane on cane")
		assert(Placement.resolve(CACTUS, ctx(5, 0, 0), get), "cactus on sand")
		eq(Placement.resolve(CACTUS, ctx(9, 0, 0), get), nil, "no cactus beside a block")
		eq(Placement.resolve(CACTUS, ctx(14, 0, 0), get), nil, "no cactus on grass")
		local stem = Farming.cropId("pumpkin_stem", 0)
		assert(stem, "pumpkin stem")
		assert(Placement.resolve(stem, ctx(12, 0, 0), get), "stem on farmland")
		eq(Placement.resolve(stem, ctx(14, 0, 0), get), nil, "no stem on grass")
		assert(Placement.resolve(id("oak_sapling"), ctx(14, 0, 0), get), "sapling on grass")
		eq(Placement.resolve(id("oak_sapling"), ctx(5, 0, 0), get), nil, "no sapling on sand")
		-- cactus: 1/16 inset, collision 15/16 high; you can step 1/16 into its cell
		local cb = Shapes.boxes(CACTUS, get, true)[1]
		eq(cb[1], 1 / 16); eq(cb[5], 15 / 16)
		-- items: seeds place stems; leaves drop saplings; recipes
		local ItemRegistry = Loader.require("src/shared/Items/ItemRegistry")
		eq(ItemRegistry.get("pumpkin_seeds").places, stem)
		eq(ItemRegistry.get("melon_seeds").places, Farming.cropId("melon_stem", 0))
		local leafDrops = BlockRegistry.byKey.oak_leaves.bonusDrops
		local hasSapling = false
		for _, b in leafDrops do
			hasSapling = hasSapling or (b.item == "oak_sapling" and b.chance == 0.05)
		end
		assert(hasSapling, "oak leaves drop saplings 1 in 20")
		-- stems drop seeds by age (Java: 3 tries at (age + 1) / 15)
		local function seeds(sid, r)
			local n = 0
			for _, st in Farming.drops(sid, nil, function()
				return r
			end) do
				n += st.count
			end
			return n
		end
		eq(seeds(stem, 0.05), 3); eq(seeds(stem, 0.1), 0)
		eq(seeds(Farming.cropId("melon_stem", 7), 0.5), 3)
		eq(BlockRegistry.byKey.melon.drop, "melon_slice")
		eq(BlockRegistry.byKey.melon.dropMin, 3); eq(BlockRegistry.byKey.melon.dropMax, 7)
	end)

	test("9b world generation: sugar cane by water, cactus in deserts, pumpkins; trees unchanged", function()
		local TerrainGen = Loader.require("src/shared/World/TerrainGen")
		local ChunkData = Loader.require("src/shared/World/ChunkData")
		local Config = Loader.require("src/shared/Config")
		local CANE, CACTUS, PUMPKIN, SAND = id("sugar_cane"), id("cactus"), id("pumpkin"), id("sand")
		local gen = TerrainGen.new(1337)
		local counts = { cane = 0, cactus = 0, pumpkin = 0 }
		for cx = -8, 8 do
			for cz = -8, 8 do
				local c = ChunkData.new(cx, cz)
				TerrainGen.generate(gen, c)
				for z = 0, 15 do
					for x = 0, 15 do
						for y = Config.SEA_LEVEL - 20, Config.SEA_LEVEL + 60 do
							local b = ChunkData.get(c, x, y, z)
							if b == CANE then
								counts.cane += 1
								local below = ChunkData.get(c, x, y - 1, z)
								assert(below == CANE or below == SAND or below == GRASS or below == DIRT, "cane on its soil")
							elseif b == CACTUS then
								counts.cactus += 1
								local below = ChunkData.get(c, x, y - 1, z)
								assert(below == CACTUS or below == SAND, "cactus on sand")
							elseif b == PUMPKIN then
								counts.pumpkin += 1
							end
						end
					end
				end
			end
		end
		print(`       17x17 chunks: {counts.cane} sugar cane, {counts.cactus} cactus, {counts.pumpkin} pumpkins`)
		assert(counts.cane > 0, "some sugar cane")
	end)

	test("9b server: cane / cactus grow to 3, cactus breaks beside a block, stems grow fruit, saplings grow trees", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/server/")
		local cells: { [string]: number } = {}
		local FLOOR = 64
		local function getb(x, y, z)
			return cells[`{x},{y},{z}`] or (if y < FLOOR then STONE else 0)
		end
		local drops = {}
		Loader.stubs["src/server/World/WorldService.luau"] = { getBlockIfLoaded = getb, getBlock = getb, blockLightAt = function() return 0 end }
		Loader.stubs["src/server/World/BlockUpdates.luau"] = {
			set = function(x, y, z, b)
				cells[`{x},{y},{z}`] = b
			end,
			schedule = function() end, register = function() end, onNeighbourChanged = function() end, onTick = function() end,
		}
		Loader.stubs["src/server/World/RandomTicks.luau"] = { register = function() end }
		Loader.stubs["src/server/World/ItemEntityService.luau"] = { spawn = function(st) table.insert(drops, st) end }
		Loader.stubs["src/server/Player/InventoryService.luau"] = { consumeSelected = function() return true end, damageSelectedTool = function() end }
		Loader.stubs["src/shared/Net/Remotes.luau"] = { get = function() return Fake.Instance.new("RemoteEvent") end }
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local FS = Loader.require("src/server/Simulation/FarmingService")
		local function set(x, y, z, b)
			cells[`{x},{y},{z}`] = b
		end
		local SAND, CANE, CACTUS = id("sand"), id("sugar_cane"), id("cactus")

		-- sugar cane: grows to 3 tall and stops
		set(0, FLOOR - 1, 0, SAND)
		set(1, FLOOR - 1, 0, WATER)
		set(0, FLOOR, 0, CANE)
		for _ = 1, 200 do
			for y = FLOOR, FLOOR + 3 do
				FS.randomTick(0, y, 0)
			end
		end
		assert(Farming.isCane(getb(0, FLOOR + 2, 0)), "3 tall")
		eq(getb(0, FLOOR + 3, 0), 0, "never 4")
		-- break the bottom: the rest pops off, each dropping cane
		set(0, FLOOR, 0, 0)
		FS.supportCheck(0, FLOOR + 1, 0)
		FS.supportCheck(0, FLOOR + 2, 0)
		eq(getb(0, FLOOR + 1, 0), 0); eq(getb(0, FLOOR + 2, 0), 0)
		eq(#drops, 2)
		-- the water goes: cane on sand without water breaks
		set(0, FLOOR, 0, CANE)
		set(1, FLOOR - 1, 0, SAND)
		FS.supportCheck(0, FLOOR, 0)
		eq(getb(0, FLOOR, 0), 0, "no water: breaks")

		-- cactus: grows to 3; a block beside it breaks it
		set(10, FLOOR - 1, 0, SAND)
		set(10, FLOOR, 0, CACTUS)
		for _ = 1, 200 do
			for y = FLOOR, FLOOR + 3 do
				FS.randomTick(10, y, 0)
			end
		end
		assert(Farming.isCactus(getb(10, FLOOR + 2, 0)), "cactus 3 tall")
		eq(getb(10, FLOOR + 3, 0), 0)
		set(11, FLOOR + 1, 0, STONE)
		FS.supportCheck(10, FLOOR + 1, 0)
		eq(getb(10, FLOOR + 1, 0), 0, "a block beside breaks the cactus")

		-- pumpkin stem: ripe stems grow a pumpkin beside them and bend toward it
		set(20, FLOOR - 1, 0, FARM7)
		for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
			set(20 + d[1], FLOOR - 1, d[2], GRASS)
		end
		set(20, FLOOR, 0, Farming.cropId("pumpkin_stem", 7))
		for _ = 1, 400 do
			FS.randomTick(20, FLOOR, 0)
			set(20, FLOOR - 1, 0, FARM7)
			if BlockRegistry.byId[getb(20, FLOOR, 0)].state.attachedStem then
				break
			end
		end
		local attached = BlockRegistry.byId[getb(20, FLOOR, 0)]
		assert(attached.state.attachedStem == "pumpkin", "stem attached")
		local f = ({ north = { 0, -1 }, east = { 1, 0 }, south = { 0, 1 }, west = { -1, 0 } })[attached.state.facing]
		eq(getb(20 + f[1], FLOOR, f[2]), id("pumpkin"), "a pumpkin beside it")
		-- harvest the pumpkin: the stem goes back to ripe (and can grow another)
		set(20 + f[1], FLOOR, f[2], 0)
		FS.supportCheck(20, FLOOR, 0)
		eq(getb(20, FLOOR, 0), Farming.cropId("pumpkin_stem", 7))

		-- saplings: stage 0 -> 1 -> a tree with logs and leaves (open sky)
		set(30, FLOOR - 1, 0, GRASS)
		set(30, FLOOR, 0, id("oak_sapling"))
		for _ = 1, 400 do
			FS.randomTick(30, FLOOR, 0)
			if getb(30, FLOOR, 0) == id("oak_log") then
				break
			end
		end
		eq(getb(30, FLOOR, 0), id("oak_log"), "grew into a tree")
		eq(getb(30, FLOOR - 1, 0), DIRT, "grass under the trunk turns to dirt")
		local leaves = 0
		for dx = -2, 2 do
			for dz = -2, 2 do
				for dy = 2, 9 do
					if getb(30 + dx, FLOOR + dy, dz) == id("oak_leaves") then
						leaves += 1
					end
				end
			end
		end
		assert(leaves > 10, `leaves ({leaves})`)
		-- no room (a block 2 above): it can't grow
		set(40, FLOOR - 1, 0, GRASS)
		set(40, FLOOR + 2, 0, STONE)
		eq(FS.growTree(40, FLOOR, 0, "birch"), false)
		-- bone meal on a sapling advances it about half the time
		set(50, FLOOR - 1, 0, GRASS)
		set(50, FLOOR, 0, id("spruce_sapling"))
		for _ = 1, 20 do
			FS.use(G.player, "bone_meal", 50, FLOOR, 0, 1)
		end
		eq(getb(50, FLOOR, 0), id("spruce_log"), "bone meal grew the spruce")

		for _, path in {
			"src/server/World/WorldService.luau", "src/server/World/BlockUpdates.luau", "src/server/World/RandomTicks.luau",
			"src/server/World/ItemEntityService.luau", "src/server/Player/InventoryService.luau", "src/shared/Net/Remotes.luau",
		} do
			Loader.stubs[path] = nil
		end
		for _, k in { "game", "workspace", "Instance", "Enum", "CFrame", "Vector2", "Color3", "UDim2", "UDim", "task", "os", "time", "tick", "warn", "Random" } do
			Loader.globals[k] = nil
		end
		Loader.forget("src/server/")
	end)

	test("stem harvest end-to-end: breaking the fruit straightens the stem through real block updates", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/server/")
		local cells: { [string]: number } = {}
		local FLOOR = 64
		local function getb(x, y, z)
			return cells[`{x},{y},{z}`] or (if y < FLOOR then STONE else 0)
		end
		local listeners = {}
		local function setBlock(x, y, z, b)
			local old = getb(x, y, z)
			cells[`{x},{y},{z}`] = b
			if old ~= b then
				for _, fn in listeners do
					fn(x, y, z, old, b)
				end
			end
			return 0
		end
		Loader.stubs["src/server/World/WorldService.luau"] = {
			getBlockIfLoaded = getb, getBlock = getb, blockLightAt = function() return 0 end, setBlock = setBlock,
			onBlockChanged = function(fn) table.insert(listeners, fn) end,
		}
		Loader.stubs["src/server/World/ChunkStreamer.luau"] = { playersWithChunk = function() return {} end }
		Loader.stubs["src/server/World/RandomTicks.luau"] = { register = function() end }
		Loader.stubs["src/server/World/ItemEntityService.luau"] = { spawn = function() end }
		Loader.stubs["src/server/Player/InventoryService.luau"] = { consumeSelected = function() return true end, damageSelectedTool = function() end }
		Loader.stubs["src/shared/Net/Remotes.luau"] = { get = function() return Fake.Instance.new("RemoteEvent") end }
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local BU = Loader.require("src/server/World/BlockUpdates")
		local FS = Loader.require("src/server/Simulation/FarmingService")
		BU.init()
		FS.init()
		for _, fruit in { "pumpkin", "melon" } do
			for f, facing in { "north", "east", "south", "west" } do
				local d = ({ { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } })[f]
				local x = f * 10 + (if fruit == "melon" then 100 else 0)
				setBlock(x, FLOOR - 1, 0, FARM7)
				setBlock(x + d[1], FLOOR - 1, d[2], GRASS)
				setBlock(x, FLOOR, 0, id(`attached_{fruit}_stem_{facing}`))
				setBlock(x + d[1], FLOOR, d[2], id(fruit))
				for _ = 1, 3 do
					G.frame(0.05)
				end
				eq(getb(x, FLOOR, 0), id(`attached_{fruit}_stem_{facing}`), `{fruit} {facing}: still attached`)
				setBlock(x + d[1], FLOOR, d[2], 0) -- the player breaks the fruit
				for _ = 1, 3 do
					G.frame(0.05)
				end
				eq(getb(x, FLOOR, 0), Farming.cropId(`{fruit}_stem`, 7), `{fruit} {facing}: stem straightened`)
			end
		end
		for _, path in {
			"src/server/World/WorldService.luau", "src/server/World/ChunkStreamer.luau", "src/server/World/RandomTicks.luau",
			"src/server/World/ItemEntityService.luau", "src/server/Player/InventoryService.luau", "src/shared/Net/Remotes.luau",
		} do
			Loader.stubs[path] = nil
		end
		for _, k in { "game", "workspace", "Instance", "Enum", "CFrame", "Vector2", "Color3", "UDim2", "UDim", "task", "os", "time", "tick", "warn", "Random" } do
			Loader.globals[k] = nil
		end
		Loader.forget("src/server/")
	end)

	test("server farming: growth by random ticks, farmland dries / wets, hoe, bone meal, trampling, popping off", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/server/")
		local cells: { [string]: number } = {}
		local FLOOR = 64
		local function getb(x, y, z)
			return cells[`{x},{y},{z}`] or (if y < FLOOR then STONE else 0)
		end
		local light = 0
		local sets, drops = {}, {}
		Loader.stubs["src/server/World/WorldService.luau"] = {
			getBlockIfLoaded = getb,
			getBlock = getb,
			blockLightAt = function()
				return light
			end,
		}
		Loader.stubs["src/server/World/BlockUpdates.luau"] = {
			set = function(x, y, z, b)
				cells[`{x},{y},{z}`] = b
				table.insert(sets, { x, y, z, b })
			end,
			schedule = function() end,
			register = function() end,
			onNeighbourChanged = function() end,
			onTick = function() end,
		}
		Loader.stubs["src/server/World/RandomTicks.luau"] = { register = function() end }
		Loader.stubs["src/server/World/ItemEntityService.luau"] = {
			spawn = function(stack)
				table.insert(drops, stack)
			end,
		}
		local used = { consumed = 0, damaged = 0 }
		Loader.stubs["src/server/Player/InventoryService.luau"] = {
			consumeSelected = function()
				used.consumed += 1
				return true
			end,
			damageSelectedTool = function()
				used.damaged += 1
			end,
		}
		Loader.stubs["src/shared/Net/Remotes.luau"] = { get = function() return Fake.Instance.new("RemoteEvent") end }
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local FS = Loader.require("src/server/Simulation/FarmingService")
		local function set(x, y, z, b)
			cells[`{x},{y},{z}`] = b
		end

		-- open sky over the field (stone floor at y < 64, grass on top)
		set(0, FLOOR, 0, FARM7)
		set(0, FLOOR + 1, 0, WHEAT0)
		eq(FS.lightAt(0, FLOOR + 1, 0), 15)
		-- a ripe field takes a while: count random ticks to grow 0 -> 7 (Java: about 3x7 on
		-- lone wet farmland, the chance is 1 in 13 at speed 2... here alone: 1 + 3 = 4 -> 1/7)
		local ticks = 0
		while getb(0, FLOOR + 1, 0) ~= Farming.cropId("wheat", 7) and ticks < 2000 do
			ticks += 1
			FS.randomTick(0, FLOOR + 1, 0)
			set(0, FLOOR, 0, FARM7) -- keep it wet (no water in this test)
		end
		eq(getb(0, FLOOR + 1, 0), Farming.cropId("wheat", 7), "grew ripe")
		assert(ticks > 14 and ticks < 200, `took {ticks} random ticks (expected around 49)`)
		-- in the dark (a stone roof, no torch) it doesn't grow
		set(1, FLOOR, 0, FARM7)
		set(1, FLOOR + 1, 0, WHEAT0)
		set(1, FLOOR + 5, 0, STONE)
		eq(FS.lightAt(1, FLOOR + 1, 0), 0)
		for _ = 1, 300 do
			FS.randomTick(1, FLOOR + 1, 0)
		end
		eq(getb(1, FLOOR + 1, 0), WHEAT0, "no growth in the dark")
		light = 12 -- a torch nearby
		for _ = 1, 300 do
			FS.randomTick(1, FLOOR + 1, 0)
			set(1, FLOOR, 0, FARM7)
		end
		assert(getb(1, FLOOR + 1, 0) ~= WHEAT0, "grows by torchlight")
		light = 0
		-- leaves only dim the sky
		set(2, FLOOR + 4, 0, id("oak_leaves"))
		eq(FS.lightAt(2, FLOOR + 1, 0), 14)

		-- farmland without water dries to 0, then (nothing planted) turns into dirt
		set(5, FLOOR, 5, FARM7)
		for _ = 1, 7 do
			FS.randomTick(5, FLOOR, 5)
		end
		eq(getb(5, FLOOR, 5), FARM0)
		FS.randomTick(5, FLOOR, 5)
		eq(getb(5, FLOOR, 5), DIRT)
		-- ... but with a crop on it, it stays dry farmland
		set(6, FLOOR, 5, FARM0)
		set(6, FLOOR + 1, 5, WHEAT0)
		FS.randomTick(6, FLOOR, 5)
		eq(getb(6, FLOOR, 5), FARM0)
		-- water within 4 wets it at once
		set(9, FLOOR, 5, WATER)
		FS.randomTick(6, FLOOR, 5)
		eq(getb(6, FLOOR, 5), FARM7)

		-- hoe: grass with air above -> farmland, tool wear; not from below, not with grass on top
		set(10, FLOOR, 10, GRASS)
		eq(FS.use(G.player, "wooden_hoe", 10, FLOOR, 10, 1), true)
		eq(getb(10, FLOOR, 10), FARM0)
		eq(used.damaged, 1)
		set(11, FLOOR, 10, GRASS)
		set(11, FLOOR + 1, 10, id("short_grass"))
		FS.use(G.player, "wooden_hoe", 11, FLOOR, 10, 1)
		eq(getb(11, FLOOR, 10), GRASS, "short grass on top: no tilling")
		FS.use(G.player, "stone_pickaxe", 12, FLOOR, 10, 1)
		eq(FS.use(G.player, "stone_pickaxe", 12, FLOOR, 10, 1), false, "not a farming use")

		-- bone meal: grows a crop, used up; a ripe crop takes none
		set(10, FLOOR + 1, 10, WHEAT0)
		FS.use(G.player, "bone_meal", 10, FLOOR + 1, 10, 1)
		local age = Farming.crop(getb(10, FLOOR + 1, 10)).age
		assert(age >= 2 and age <= 5, "bone meal grew it")
		eq(used.consumed, 1)
		set(10, FLOOR + 1, 10, Farming.cropId("wheat", 7))
		FS.use(G.player, "bone_meal", 10, FLOOR + 1, 10, 1)
		eq(used.consumed, 1, "nothing used on a ripe crop")
		-- bone meal on a field of grass sprouts plants on it
		for x = 20, 30 do
			for z = 20, 30 do
				set(x, FLOOR, z, GRASS)
			end
		end
		FS.use(G.player, "bone_meal", 25, FLOOR, 25, 1)
		local sprouted = 0
		for x = 20, 30 do
			for z = 20, 30 do
				local b = getb(x, FLOOR + 1, z)
				if b ~= 0 then
					sprouted += 1
					assert(b == id("short_grass") or b == id("dandelion") or b == id("poppy"), "grass or flowers")
				end
			end
		end
		assert(sprouted > 5, `bone meal sprouted {sprouted}`)

		-- support: a crop on farmland that became dirt pops off with its drop
		table.clear(drops)
		set(40, FLOOR, 0, DIRT)
		set(40, FLOOR + 1, 0, Farming.cropId("wheat", 7))
		FS.supportCheck(40, FLOOR + 1, 0)
		eq(getb(40, FLOOR + 1, 0), 0)
		local gotWheat = false
		for _, d in drops do
			gotWheat = gotWheat or d.item == "wheat"
		end
		assert(gotWheat, "ripe wheat dropped")
		-- a block placed on farmland squashes it to dirt
		set(41, FLOOR, 0, FARM7)
		set(41, FLOOR + 1, 0, STONE)
		FS.supportCheck(41, FLOOR, 0)
		eq(getb(41, FLOOR, 0), DIRT)

		-- grass: dies under stone, spreads to dirt next to it in the light
		set(50, FLOOR, 0, GRASS)
		set(50, FLOOR + 1, 0, STONE)
		FS.randomTick(50, FLOOR, 0)
		eq(getb(50, FLOOR, 0), DIRT)
		set(52, FLOOR, 0, GRASS)
		set(53, FLOOR, 0, DIRT)
		for _ = 1, 200 do
			FS.randomTick(52, FLOOR, 0)
		end
		eq(getb(53, FLOOR, 0), GRASS, "spread onto dirt")

		-- trampling: standing there, a big fall always tramples; a spectator never does
		local c = Fake.newCharacter("Tester", Fake.CFrame.new(60.5 * 3, (FLOOR + 1) * 3 + 3, 0.5 * 3))
		c.Parent = G.workspace
		G.player.Character = c
		set(60, FLOOR, 0, FARM7)
		FS.trample(G.player, 60, FLOOR, 0, 10)
		eq(getb(60, FLOOR, 0), DIRT)
		set(60, FLOOR, 0, FARM7)
		FS.trample(G.player, 60, FLOOR, 0, 0.4)
		eq(getb(60, FLOOR, 0), FARM7, "a tiny fall doesn't")
		FS.trample(G.player, 70, FLOOR, 0, 10)
		G.player:SetAttribute("Spectator", true)
		FS.trample(G.player, 60, FLOOR, 0, 10)
		eq(getb(60, FLOOR, 0), FARM7, "spectators don't trample")
		G.player:SetAttribute("Spectator", nil)

		for _, path in {
			"src/server/World/WorldService.luau", "src/server/World/BlockUpdates.luau", "src/server/World/RandomTicks.luau",
			"src/server/World/ItemEntityService.luau", "src/server/Player/InventoryService.luau", "src/shared/Net/Remotes.luau",
		} do
			Loader.stubs[path] = nil
		end
		for _, k in { "game", "workspace", "Instance", "Enum", "CFrame", "Vector2", "Color3", "UDim2", "UDim", "task", "os", "time", "tick", "warn", "Random" } do
			Loader.globals[k] = nil
		end
		Loader.forget("src/server/")
	end)
end
