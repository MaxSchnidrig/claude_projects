--!nocheck
-- Item graphics + footsteps phase: item sprites for every item, 3D block icons, extruded item
-- geometry (Meshing/ItemExtrude), the footstep group of every block and the REAL AudioClient's
-- step rules in a fake Roblox.
--
-- Usage (from run.luau):  require("./GraphicsTests")(test, eq)

local Loader = require("./Loader")
local Fake = require("./FakeRoblox")
local Vector3 = (require("@lune/roblox") :: any).Vector3

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	print("Item graphics and footsteps")
	local ItemRegistry = Loader.require("src/shared/Items/ItemRegistry")
	local BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry")
	local ItemSprites = Loader.require("src/shared/Items/ItemSprites")
	local ItemIconGen = Loader.require("src/shared/Items/ItemIconGen")
	local BlockIconGen = Loader.require("src/shared/Items/BlockIconGen")
	local ItemExtrude = Loader.require("src/shared/Meshing/ItemExtrude")
	local SoundConfig = Loader.require("src/shared/Audio/SoundConfig")

	test("every item has its own sprite, 3D block icon or block-shape icon; sprites are well formed", function()
		local sprites, cubes, shaped = 0, 0, 0
		for _, def in ItemRegistry.list() do
			if BlockIconGen.shapeForItem(def) then
				cubes += 1
			elseif def.block and def.icon then
				shaped += 1 -- doors, plants, beds... drawn from their textures
			else
				assert(ItemSprites.SPRITES[def.key], `{def.key} has no sprite`)
				sprites += 1
			end
		end
		for key, s in ItemSprites.SPRITES do
			eq(#s.rows, 16, `{key}: 16 rows`)
			for i, r in s.rows do
				eq(#r, 16, `{key} row {i}: 16 columns`)
			end
			local img = ItemSprites.icon(key)
			local opaque = 0
			for i = 0, 255 do
				local o = i * 4
				if buffer.readu8(img, o + 3) > 0 then
					opaque += 1
					local r, g, b = buffer.readu8(img, o), buffer.readu8(img, o + 1), buffer.readu8(img, o + 2)
					assert(not (r == 255 and g == 0 and b == 255), `{key}: a letter without a colour (magenta)`)
				end
			end
			assert(opaque >= 12, `{key}: almost empty ({opaque} pixels)`)
			-- the generator returns the same sprite
			eq(buffer.tostring(ItemIconGen.generate(ItemRegistry.get(key))), buffer.tostring(img), key)
		end
		print(`       {sprites} sprites, {cubes} 3D block icons, {shaped} block-shape icons`)
		eq(BlockIconGen.shapeForItem(ItemRegistry.get("torch")), nil, "torches are flat")
		eq(BlockIconGen.shapeForItem(ItemRegistry.get("oak_stairs")), "stairs")
		eq(BlockIconGen.shapeForItem(ItemRegistry.get("stone")), "cube")
		eq(BlockIconGen.shapeForItem(ItemRegistry.get("oak_door")), nil)
	end)

	test("3D block icon: the block sits in the middle, background clear, top lighter than the right side", function()
		local S = BlockIconGen.SIZE
		local img = BlockIconGen.render(BlockRegistry.id("white_wool"), "cube")
		local function px(x, y)
			local o = (y * S + x) * 4
			return buffer.readu8(img, o), buffer.readu8(img, o + 3)
		end
		local _, a00 = px(0, 0)
		eq(a00, 0, "corner clear")
		local top, at = px(S // 2, S // 6)
		local right, ar = px(S * 3 // 4, S * 2 // 3)
		eq(at, 255)
		eq(ar, 255)
		assert(top > right, `top {top} brighter than the right side {right}`)
		-- a slab leaves the upper part clear
		local slab = BlockIconGen.render(BlockRegistry.id("stone_slab"), "slab")
		eq(buffer.readu8(slab, ((S // 6) * S + S // 2) * 4 + 3), 0, "nothing above a slab")
	end)

	test("extruded items: faces cover each pixel once, sides only on open edges, outward winding", function()
		local function check(quads)
			for _, q in quads do
				local v = q.v
				local ax, ay, az = v[4] - v[1], v[5] - v[2], v[6] - v[3]
				local bx, by, bz = v[7] - v[1], v[8] - v[2], v[9] - v[3]
				local n = { ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx }
				local want = ItemExtrude.NORMALS[q.dir]
				assert(n[1] * want[1] + n[2] * want[2] + n[3] * want[3] > 0, `quad dir {q.dir} winds inward`)
			end
		end
		for _, key in { "diamond_sword", "apple", "wheat_seeds", "bucket", "torch", "bow" } do
			local img = ItemIconGen.generate(ItemRegistry.get(key))
			local quads = ItemExtrude.flat(img)
			check(quads)
			local opaque, edges = 0, 0
			local function solid(x, y)
				return x >= 0 and y >= 0 and x < 16 and y < 16 and buffer.readu8(img, (y * 16 + x) * 4 + 3) > 0
			end
			for y = 0, 15 do
				for x = 0, 15 do
					if solid(x, y) then
						opaque += 1
						for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
							if not solid(x + d[1], y + d[2]) then
								edges += 1
							end
						end
					end
				end
			end
			local front, back, side = 0, 0, 0
			for _, q in quads do
				local v = q.v
				if q.dir == 5 or q.dir == 6 then
					local w = math.max(math.abs(v[4] - v[1]), math.abs(v[7] - v[1]))
					local h = math.max(math.abs(v[5] - v[2]), math.abs(v[8] - v[2]))
					local a = w * h
					if q.dir == 5 then
						front += a
					else
						back += a
					end
				else
					-- side length along x or y
					side += math.max(math.abs(v[4] - v[1]), math.abs(v[5] - v[2]), math.abs(v[7] - v[1]), math.abs(v[8] - v[2]))
				end
			end
			eq(front, opaque, `{key}: front covers every pixel once`)
			eq(back, opaque, `{key}: back too`)
			eq(side, edges, `{key}: one side face per open edge`)
			assert(#quads < opaque * 2 + edges, `{key}: faces are merged ({#quads})`)
		end
		-- boxes: 6 faces each, outward, texture coords in 0..1
		local q = ItemExtrude.boxes(BlockIconGen.SHAPES.stairs)
		eq(#q, 12)
		check(q)
		for _, f in q do
			for _, st in f.st do
				assert(st >= 0 and st <= 1, "st in 0..1")
			end
		end
	end)

	test("footsteps: every block is in exactly one group; groups have sounds; spot checks", function()
		local families = {}
		for _, def in BlockRegistry.byId do
			if def.id ~= 0 then
				families[def.family] = true
			end
		end
		for f in families do
			assert(SoundConfig.stepOf[f], `block {f} has no footstep group in SoundConfig.footsteps`)
		end
		for g in SoundConfig.footsteps do
			if g ~= "none" then
				local e = SoundConfig.get(`step.{g}`)
				assert(e and e.id ~= "", `step.{g} has a sound`)
			end
		end
		eq(SoundConfig.stepGroup("grass_block"), "soft")
		eq(SoundConfig.stepGroup("sand"), "soft")
		eq(SoundConfig.stepGroup("oak_leaves"), "soft")
		eq(SoundConfig.stepGroup("white_wool"), "soft")
		eq(SoundConfig.stepGroup("farmland"), "soft")
		eq(SoundConfig.stepGroup("oak_planks"), "wood")
		eq(SoundConfig.stepGroup("spruce_log"), "wood")
		eq(SoundConfig.stepGroup("chest"), "wood")
		eq(SoundConfig.stepGroup("oak_door"), "wood")
		eq(SoundConfig.stepGroup("stone"), "stone")
		eq(SoundConfig.stepGroup("diamond_ore"), "stone")
		eq(SoundConfig.stepGroup("glass"), "stone")
		eq(SoundConfig.stepGroup("furnace"), "stone")
		eq(SoundConfig.stepGroup("obsidian"), "stone")
		eq(SoundConfig.stepGroup("water"), "none")
		eq(SoundConfig.stepGroup("some_future_block", "wood"), "wood", "new blocks fall back to their material")
		-- and the old Roblox plastic step is no longer a separate catch-all
		eq(SoundConfig.get("step.default"), nil)
	end)

	test("footsteps (real AudioClient): Java pace on the ground, none in the air, sneaking, swimming or standing", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/client/")
		Loader.stubs["src/shared/Net/Remotes.luau"] = { get = function() return Fake.Instance.new("RemoteEvent") end }
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local Audio = Loader.require("src/client/Audio/AudioClient")
		local played = {}
		Audio.play = function(name)
			table.insert(played, name)
			return true
		end
		local BS = Loader.require("src/shared/Config").BLOCK_SIZE
		local FLOOR = 64
		local under = BlockRegistry.id("stone")
		local M = { onGround = true, inLiquid = false, sneaking = false, spectating = false, sleeping = false }
		-- (AudioClient.init isn't run: wire its two inputs the way init does)
		local world = { getBlock = function(_x, y, _z) return if y < FLOOR then under else 0 end }
		Audio.setStepSources(world, M)
		local feet = Vector3.new(0.5 * BS, FLOOR * BS, 0.5 * BS)
		local function walk(speed: number, seconds: number): number
			table.clear(played)
			for _ = 1, math.floor(seconds * 20) do
				Audio.stepTick(0.05, Vector3.new(speed, 0, 0), feet)
			end
			return #played
		end
		-- Java: a step every 1 / 0.6 blocks: walking 4.317 b/s for 10 s = 43 blocks = ~25 steps
		local w = walk(4.317, 10)
		assert(w >= 24 and w <= 27, `walking: {w} steps in 10 s`)
		eq(played[1], "step.stone")
		local s = walk(5.612, 10)
		assert(s > w, `sprinting is faster ({s})`)
		eq(walk(0, 5), 0, "standing still")
		M.onGround = false
		eq(walk(4.317, 3), 0, "in the air")
		M.onGround = true
		M.sneaking = true
		eq(walk(1.3, 5), 0, "sneaking is silent (Java)")
		M.sneaking = false
		M.inLiquid = true
		eq(walk(2, 5), 0, "swimming")
		M.inLiquid = false
		M.spectating = true
		eq(walk(10, 2), 0, "spectator flying")
		M.spectating = false
		under = BlockRegistry.id("grass_block")
		walk(4.317, 2)
		eq(played[1], "step.soft")
		under = BlockRegistry.id("oak_planks")
		walk(4.317, 2)
		eq(played[1], "step.wood")
		under = BlockRegistry.id("water")
		eq(walk(4.317, 2), 0, "no step on water")

		Loader.stubs["src/shared/Net/Remotes.luau"] = nil
		for _, k in { "game", "workspace", "Instance", "Enum", "CFrame", "Vector2", "Color3", "UDim2", "UDim", "task", "os", "time", "tick", "warn", "Random" } do
			Loader.globals[k] = nil
		end
		Loader.forget("src/client/")
	end)
end
