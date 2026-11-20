--!nocheck
-- Phase 9e: animals (Mobs/Animals, the REAL MobService + MobAI in a fake Roblox), dyes and the
-- 16 colours. Expected values follow the Minecraft Wiki ("Breeding", "Baby", "Sheep", "Dye").
--
-- Usage (from run.luau):  require("./AnimalTests")(test, eq)

local Loader = require("./Loader")
local Fake = require("./FakeRoblox")
local Vector3 = (require("@lune/roblox") :: any).Vector3

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	print("Animals, dyes and colours (Phase 9e)")
	local Animals = Loader.require("src/shared/Mobs/Animals")
	local Crafting = Loader.require("src/shared/Items/Crafting")
	local Recipes = Loader.require("src/shared/Items/Recipes")
	local ItemRegistry = Loader.require("src/shared/Items/ItemRegistry")
	local BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry")
	local Placement = Loader.require("src/shared/Blocks/Placement")

	local function craft(items: { string? }, w: number): any
		local grid = {}
		for i = 1, w * w do
			local it = items[i]
			grid[i] = if it and it ~= "" then { item = it, count = 1 } else nil
		end
		return Crafting.match(grid, w)
	end
	local function mix(a: string, b: string): string?
		local r = craft({ `{a}_dye`, `{b}_dye` }, 2)
		local c = r and string.match(r.item, "^(.+)_dye$")
		return if c and r.count == 2 then c else nil
	end

	test("animal rules: Java foods, love / baby timings, feeding speeds growth 10 %, sheep colours", function()
		eq(Animals.isFood("cow", "wheat"), true)
		eq(Animals.isFood("sheep", "wheat"), true)
		eq(Animals.isFood("pig", "carrot"), true); eq(Animals.isFood("pig", "potato"), true); eq(Animals.isFood("pig", "beetroot"), true)
		eq(Animals.isFood("pig", "wheat"), false)
		for _, s in { "wheat_seeds", "pumpkin_seeds", "melon_seeds", "beetroot_seeds" } do
			eq(Animals.isFood("chicken", s), true)
		end
		eq(Animals.isFood("chicken", "wheat"), false)
		eq(Animals.LOVE_TICKS, 600); eq(Animals.BABY_AGE, -24000); eq(Animals.PARENT_COOLDOWN, 6000)
		-- feeding a newborn: 10 % of 20 minutes = 120 s; 28 feedings leave about a minute (wiki)
		eq(Animals.feedSpeedUpTicks(-24000), 2400)
		local age = -24000
		for _ = 1, 28 do
			age += Animals.feedSpeedUpTicks(age)
		end
		assert(-age / 20 > 50 and -age / 20 < 75, `after 28 feedings {-age / 20} s left`)
		eq(Animals.feedSpeedUpTicks(-170), 0, "under 10 s left: whole seconds round to 0")
		-- natural sheep colours, counted over every random outcome
		local n = {}
		for r100 = 0, 99 do
			for r500 = 0, 499 do
				local c = Animals.naturalSheepColor(r100, r500)
				n[c] = (n[c] or 0) + 1
			end
		end
		local total = 100 * 500
		assert(math.abs(n.white / total - 0.81836) < 1e-9, "white 81.836 %")
		eq(n.black / total, 0.05); eq(n.gray / total, 0.05); eq(n.light_gray / total, 0.05); eq(n.brown / total, 0.03)
		assert(math.abs(n.pink / total - 0.00164) < 1e-9, "pink 0.164 %")
		-- lambs: the dye mix of their parents, else one parent's colour
		eq(Animals.offspringColor("red", "yellow", mix, 0), "orange")
		eq(Animals.offspringColor("blue", "white", mix, 1), "light_blue")
		eq(Animals.offspringColor("black", "white", mix, 0), "gray")
		eq(Animals.offspringColor("blue", "red", mix, 0), "purple")
		eq(Animals.offspringColor("white", "white", mix, 1), "white")
		eq(Animals.offspringColor("red", "green", mix, 0), "red", "no mix: a random parent")
		eq(Animals.offspringColor("red", "green", mix, 1), "green")
		-- what a right-click on an animal does (the client asks before sending)
		eq(Animals.wants("sheep", "shears", false, false), true)
		eq(Animals.wants("sheep", "shears", true, false), false, "lambs can't be sheared")
		eq(Animals.wants("sheep", "shears", false, true), false, "already sheared")
		eq(Animals.wants("sheep", "red_dye", false, false), true)
		eq(Animals.wants("sheep", "red_dye", false, true), false, "sheared sheep can't be dyed")
		eq(Animals.wants("cow", "bucket", true, false), false, "calves give no milk")
		eq(Animals.wants("pig", "carrot", false, false), true)
		eq(Animals.wants("zombie", "wheat", false, false), false)
	end)

	test("snapshots carry baby / sheared flags and the wool colour", function()
		local Codec = Loader.require("src/shared/Mobs/MobSnapshotCodec")
		local recs = {}
		for i = 1, 60 do
			table.insert(recs, { id = i, code = 12, flags = 64 + 128, x = i, y = 2, z = 3, yaw = 0, pitch = 0, variant = (i % 16) + 1 })
		end
		local seen = 0
		for _, p in Codec.encode(recs) do
			assert(buffer.len(p) <= 600, "packet small")
			for _, r in Codec.decode(p) do
				seen += 1
				eq(r.flags, 192)
				eq(r.variant, (r.id % 16) + 1)
			end
		end
		eq(seen, 60)
	end)

	test("dyes and the 16 colours: Java recipes", function()
		local function one(item: string, count: number, ...)
			local r = craft({ ... }, 3)
			assert(r, `{item}: no recipe`)
			eq(r.item, item)
			eq(r.count, count, item)
		end
		one("white_dye", 1, "bone_meal")
		one("yellow_dye", 1, "dandelion")
		one("red_dye", 1, "poppy")
		one("red_dye", 1, "beetroot")
		one("blue_dye", 1, "cornflower")
		one("blue_dye", 1, "lapis_lazuli")
		one("light_gray_dye", 1, "azure_bluet")
		one("light_gray_dye", 1, "oxeye_daisy")
		one("orange_dye", 2, "red_dye", "yellow_dye")
		one("magenta_dye", 4, "blue_dye", "red_dye", "red_dye", "white_dye")
		one("light_gray_dye", 3, "black_dye", "white_dye", "white_dye")
		eq(Crafting.smeltResult("cactus"), "green_dye")
		-- wool, carpets, glass, panes, beds
		one("red_wool", 1, "white_wool", "red_dye")
		one("blue_wool", 1, "red_wool", "blue_dye")
		one("lime_carpet", 3, "lime_wool", "lime_wool")
		one("cyan_stained_glass", 8, "glass", "glass", "glass", "glass", "cyan_dye", "glass", "glass", "glass", "glass")
		one("cyan_stained_glass_pane", 16, "cyan_stained_glass", "cyan_stained_glass", "cyan_stained_glass",
			"cyan_stained_glass", "cyan_stained_glass", "cyan_stained_glass")
		one("purple_bed", 1, "purple_wool", "purple_wool", "purple_wool", "oak_planks", "spruce_planks", "birch_planks")
		one("black_bed", 1, "white_bed", "black_dye")
		one("pink_carpet", 8, "red_carpet", "red_carpet", "red_carpet", "red_carpet", "pink_dye", "red_carpet", "red_carpet", "red_carpet", "red_carpet")
		-- every colour exists as wool, carpet, stained glass, pane, bed and dye
		for _, c in Recipes.COLORS do
			for _, kind in { "wool", "carpet", "stained_glass", "stained_glass_pane", "bed", "dye" } do
				assert(ItemRegistry.get(`{c}_{kind}`), `{c}_{kind} exists`)
			end
		end
		-- a carpet needs a block under it
		local carpet = BlockRegistry.id("red_carpet")
		local STONE = BlockRegistry.id("stone")
		local function get(_x, y, _z)
			return if y < 10 then STONE else 0
		end
		local ok = Placement.resolve(carpet, { hx = 0, hy = 9, hz = 0, nx = 0, ny = 1, nz = 0, px = 0.5, py = 10, pz = 0.5, lx = 0, lz = -1 }, get)
		assert(ok, "a carpet on stone")
		eq((Placement.supported(carpet, 0, 10, 0, get)), true)
		eq((Placement.supported(carpet, 0, 20, 0, get)), false, "no block under it: it drops")
	end)

	test("server (real MobService + MobAI): feed two cows, they breed a calf; feeding the calf; shear, dye, graze", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/server/")
		local STONE = BlockRegistry.id("stone")
		local GRASS = BlockRegistry.id("grass_block")
		local FLOOR = 64
		local cells = {}
		local function getb(x, y, z)
			local c = cells[`{x},{y},{z}`]
			if c then
				return c
			end
			return if y < FLOOR - 1 then STONE elseif y == FLOOR - 1 then GRASS else 0
		end
		local remotes = {}
		local function remote(name)
			local r = remotes[name]
			if not r then
				r = Fake.Instance.new("RemoteEvent")
				remotes[name] = r
			end
			return r
		end
		Loader.stubs["src/shared/Net/Remotes.luau"] = { get = remote, getUnreliable = remote }
		Loader.stubs["src/server/World/WorldService.luau"] = {
			getBlock = getb, getBlockIfLoaded = getb, blockLightAt = function() return 0 end,
			onChunkLoaded = function() end, onChunkUnloaded = function() end,
		}
		local spawned = {}
		Loader.stubs["src/server/World/ItemEntityService.luau"] = {
			spawn = function(st) table.insert(spawned, st) end,
			spawnAround = function(list) for _, st in list do table.insert(spawned, st) end end,
		}
		Loader.stubs["src/server/World/WeatherService.luau"] = { rainOn = function() return false end }
		Loader.stubs["src/server/World/ExplosionService.luau"] = { setHooks = function() end, explode = function() end }
		Loader.stubs["src/server/World/BlockUpdates.luau"] = { set = function(x, y, z, id) cells[`{x},{y},{z}`] = id end }
		local hand = { item = "wheat", count = 64 }
		local consumed, toolHits = 0, 0
		Loader.stubs["src/server/Player/InventoryService.luau"] = {
			selectedSlot = function() return 1 end,
			getSlot = function() return if hand.count > 0 then hand else nil end,
			selectedStack = function() return hand end,
			setSlot = function(_p, _i, s) hand = s or { item = "", count = 0 } end,
			consumeSelected = function(_p, n) consumed += n; hand.count -= n; return true end,
			damageSelectedTool = function() toolHits += 1 end,
			add = function() return 0 end,
		}
		Loader.stubs["src/server/Survival/SurvivalService.luau"] = {
			damage = function() return 0, false end, effects = function() return {} end,
			movement = function() return false, true, false end, addExhaustion = function() end, stopSprint = function() end,
		}
		Loader.stubs["src/server/Survival/DayNightService.luau"] = { timeOfDay = function() return 6000 end, isNight = function() return false end }
		Loader.stubs["src/server/Mobs/MobSpawner.luau"] = { init = function() end, step = function() end, debugSpawn = function() end }
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local MS = Loader.require("src/server/Mobs/MobService")
		MS.init()
		local BS = 3
		local player = G.player
		local c = Fake.newCharacter("Tester", Fake.CFrame.new(0.5 * BS, FLOOR * BS + 3, 0.5 * BS))
		c.HumanoidRootPart.Anchored = true
		c.Parent = G.workspace
		player.Character = c
		local function frames(seconds)
			for _ = 1, math.floor(seconds * 20) do
				G.frame(0.05)
			end
		end
		local function use(m)
			remotes.UseMob.OnServerEvent:Fire(player, m.id)
		end

		-- two cows, side by side in front of the player
		local a = MS.spawn("cow", 2.5, FLOOR, 0.5, 0)
		local b = MS.spawn("cow", 4.5, FLOOR, 0.5, 0)
		eq(a.age, 0); eq(a.love, 0)
		use(a)
		use(b)
		eq(consumed, 2, "one wheat each")
		eq(a.love, 600)
		use(a)
		eq(consumed, 2, "already in love: no more wheat")
		-- walk together; a calf after 60 ticks together
		local before = 0
		for _ in MS.mobs do
			before += 1
		end
		frames(8)
		local calf
		for _, m in MS.mobs do
			if m ~= a and m ~= b and m.def.key == "cow" then
				calf = m
			end
		end
		assert(calf, "a calf was born")
		assert(calf.age < -23000, `calf age {calf.age}`)
		eq(a.love, 0); eq(b.love, 0)
		assert(a.age > 5800 and b.age > 5800, "parents rest 5 minutes")
		-- feeding the calf: 10 % of the time left; a parent on cooldown takes nothing
		-- (the calf wanders at random: bring it back within reach first)
		calf.x, calf.z = 2.5, 0.5
		local ageBefore = calf.age
		use(calf)
		eq(calf.age - ageBefore, Animals.feedSpeedUpTicks(ageBefore))
		local c0 = consumed
		use(a)
		eq(consumed, c0, "a resting parent doesn't eat")
		-- the calf drops nothing when it dies; an adult does
		table.clear(spawned)
		MS.damage(calf, 100, { kind = "attack" })
		eq(#spawned, 0, "babies drop nothing")
		-- tempt: a cow 7 blocks away walks to a player holding wheat
		local far = MS.spawn("cow", 7.5, FLOOR, 0.5, 0)
		c:SetAttribute("HeldItem", "wheat")
		frames(6)
		assert(math.abs(far.x - 0.5) < 4, `the cow followed the wheat (x {far.x})`)

		-- sheep: shear (1-3 wool of its colour, shears worn), dye, graze to regrow
		local sheep = MS.spawn("sheep", 1.5, FLOOR, 2.5, 0, { color = "white" })
		hand = { item = "shears", count = 1 }
		table.clear(spawned)
		use(sheep)
		eq(sheep.sheared, true)
		assert(#spawned >= 1 and #spawned <= 3 and spawned[1].item == "white_wool", "1-3 white wool")
		eq(toolHits, 1)
		use(sheep)
		eq(toolHits, 1, "can't shear twice")
		hand = { item = "blue_dye", count = 5 }
		use(sheep)
		eq(sheep.color, "white", "a sheared sheep can't be dyed")
		-- a sheared lamb on grass grazes soon (1 in 50 a tick) and grows its wool back
		c:SetAttribute("HeldItem", "") -- (holding its food it would follow the player instead: tempt comes first)
		local lamb = MS.spawn("sheep", 3.5, FLOOR, 4.5, 0, { color = "lime", age = -20000, sheared = true })
		frames(20)
		eq(lamb.sheared, false, "wool grew back after grazing")
		assert(lamb.age > -20000 + 1200, "a grazing lamb grows a minute")
		local ate = 0
		for _, id in cells do
			if id == BlockRegistry.id("dirt") then
				ate += 1
			end
		end
		assert(ate >= 1, "the grass it ate turned to dirt")
		-- dye an unsheared sheep
		local s2 = MS.spawn("sheep", -2.5, FLOOR, 0.5, 0, { color = "white" })
		hand = { item = "blue_dye", count = 5 }
		use(s2)
		eq(s2.color, "blue")
		eq(hand.count, 4, "the dye is used up")
		-- a blue and a white sheep make a light blue lamb
		local s3 = MS.spawn("sheep", -2.5, FLOOR, 1.5, 0, { color = "white" })
		local lambBorn = MS.breed(s2, s3)
		eq(lambBorn.color, "light_blue")
		eq(lambBorn.age, Animals.BABY_AGE)

		for _, path in {
			"src/shared/Net/Remotes.luau", "src/server/World/WorldService.luau", "src/server/World/ItemEntityService.luau",
			"src/server/World/WeatherService.luau", "src/server/World/ExplosionService.luau", "src/server/World/BlockUpdates.luau",
			"src/server/Player/InventoryService.luau", "src/server/Survival/SurvivalService.luau",
			"src/server/Survival/DayNightService.luau", "src/server/Mobs/MobSpawner.luau",
		} do
			Loader.stubs[path] = nil
		end
		for _, k in { "game", "workspace", "Instance", "Enum", "CFrame", "Vector2", "Color3", "UDim2", "UDim", "task", "os", "time", "tick", "warn", "Random" } do
			Loader.globals[k] = nil
		end
		Loader.forget("src/server/")
	end)
end
