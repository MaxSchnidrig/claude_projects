--!nocheck
-- Phase 10b: the enchanting table (Items/Enchantments on Util/JavaRandom), enchanted stacks.
-- Expected values follow the Minecraft Wiki "Enchanting table mechanics" and
-- "Enchantment/Levels" pages and java.util.Random.
--
-- Usage (from run.luau):  require("./EnchantingTests")(test, eq)

local Loader = require("./Loader")
local Fake = require("./FakeRoblox")

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	print("Enchanting table (Phase 10b)")
	local JavaRandom = Loader.require("src/shared/Util/JavaRandom")
	local Enchantments = Loader.require("src/shared/Items/Enchantments")
	local SlotLogic = Loader.require("src/shared/Items/SlotLogic")
	local SaveFormat = Loader.require("src/shared/Persistence/SaveFormat")
	local Crafting = Loader.require("src/shared/Items/Crafting")
	local ItemRegistry = Loader.require("src/shared/Items/ItemRegistry")
	local BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry")

	test("java.util.Random: known Java outputs", function()
		eq(JavaRandom.new(0):nextInt(), -1155484576)
		eq(JavaRandom.new(42):nextInt(), -1170105035)
		eq(JavaRandom.new(0):nextInt(100), 60)
		eq(JavaRandom.new(42):nextInt(10), 0)
		assert(math.abs(JavaRandom.new(0):nextFloat() - 0.73096776) < 1e-7)
		local r = JavaRandom.new(123)
		for _ = 1, 1000 do
			local v = r:nextInt(7)
			assert(v >= 0 and v < 7)
		end
	end)

	test("data: every Java enchantment except the excluded ones, wiki cost ranges", function()
		eq(#Enchantments.LIST, 38)
		for _, gone in { "swift_sneak", "density", "breach", "wind_burst" } do
			eq(Enchantments.byId[gone], nil, gone)
		end
		local function range(id, l)
			local d = Enchantments.byId[id]
			return Enchantments.minCost(d, l), Enchantments.maxCost(d, l)
		end
		local checks = {
			{ "sharpness", 5, 45, 65 }, { "protection", 4, 34, 45 }, { "efficiency", 5, 41, 91 },
			{ "unbreaking", 3, 21, 71 }, { "thorns", 3, 50, 100 }, { "sweeping_edge", 3, 23, 38 },
			{ "power", 5, 41, 56 }, { "quick_charge", 3, 52, 50 }, { "loyalty", 2, 19, 50 },
			{ "respiration", 3, 30, 60 }, { "mending", 1, 25, 75 }, { "feather_falling", 4, 23, 29 },
		}
		for _, c in checks do
			local lo, hi = range(c[1], c[2])
			eq(lo, c[3], `{c[1]} {c[2]} min`)
			eq(hi, c[4], `{c[1]} {c[2]} max`)
		end
		eq(Enchantments.byId.mending.treasure, true)
		eq(Enchantments.byId.frost_walker.treasure, true)
		eq(Enchantments.byId.vanishing_curse.curse, true)
		-- conflicts
		eq(Enchantments.compatible("sharpness", "smite"), false)
		eq(Enchantments.compatible("protection", "blast_protection"), false)
		eq(Enchantments.compatible("silk_touch", "fortune"), false)
		eq(Enchantments.compatible("infinity", "mending"), false)
		eq(Enchantments.compatible("multishot", "piercing"), false)
		eq(Enchantments.compatible("depth_strider", "frost_walker"), false)
		eq(Enchantments.compatible("riptide", "loyalty"), false)
		eq(Enchantments.compatible("loyalty", "channeling"), true)
		eq(Enchantments.compatible("sharpness", "unbreaking"), true)
		-- enchantability (wiki table)
		eq(Enchantments.enchantability("golden_chestplate"), 25)
		eq(Enchantments.enchantability("golden_sword"), 22)
		eq(Enchantments.enchantability("wooden_pickaxe"), 15)
		eq(Enchantments.enchantability("iron_sword"), 14)
		eq(Enchantments.enchantability("chainmail_boots"), 12)
		eq(Enchantments.enchantability("diamond_helmet"), 10)
		eq(Enchantments.enchantability("iron_leggings"), 9)
		eq(Enchantments.enchantability("stone_axe"), 5)
		eq(Enchantments.enchantability("book"), 1)
		eq(Enchantments.enchantability("bow"), 1)
		eq(Enchantments.enchantability("shears"), 0, "shears: anvil only")
		eq(Enchantments.enchantability("shield"), 0)
		eq(Enchantments.label("sharpness", 3), "Sharpness III")
		eq(Enchantments.label("silk_touch", 1), "Silk Touch")
	end)

	test("costs: the wiki's ranges for every bookshelf count", function()
		-- { top, middle, bottom } min-max per shelf count 0..15
		local TOP = { { 1, 2 }, { 1, 3 }, { 1, 3 }, { 1, 4 }, { 1, 4 }, { 1, 5 }, { 1, 5 }, { 1, 6 }, { 1, 6 }, { 1, 7 }, { 2, 7 }, { 2, 8 }, { 2, 8 }, { 2, 9 }, { 2, 9 }, { 2, 10 } }
		local MID = { { 1, 6 }, { 1, 7 }, { 2, 8 }, { 2, 9 }, { 3, 10 }, { 3, 11 }, { 3, 12 }, { 3, 13 }, { 4, 14 }, { 4, 15 }, { 5, 16 }, { 5, 17 }, { 5, 18 }, { 5, 19 }, { 6, 20 }, { 6, 21 } }
		local BOT = { { 1, 8 }, { 2, 9 }, { 4, 11 }, { 6, 12 }, { 8, 14 }, { 10, 15 }, { 12, 17 }, { 14, 18 }, { 16, 20 }, { 18, 21 }, { 20, 23 }, { 22, 24 }, { 24, 26 }, { 26, 27 }, { 28, 29 }, { 30, 30 } }
		for shelves = 0, 15 do
			local seen = { {}, {}, {} }
			for seed = 1, 600 do
				local o = Enchantments.offers(seed * 7919, shelves, "iron_pickaxe")
				for k = 1, 3 do
					local c = o[k].cost
					if c > 0 then
						seen[k][c] = true
					end
				end
			end
			for k, tbl in { TOP, MID, BOT } do
				local want = tbl[shelves + 1]
				local lo, hi = math.huge, -math.huge
				for c in seen[k] do
					lo, hi = math.min(lo, c), math.max(hi, c)
				end
				-- slot 2 and 3 can be 0 (hidden) when the cost is below the slot number
				if k == 1 or lo ~= math.huge then
					assert(lo >= want[1] and hi <= want[2], `{shelves} shelves, slot {k}: {lo}-{hi}, wiki {want[1]}-{want[2]}`)
				end
			end
		end
		-- more than 15 counts as 15
		local a = Enchantments.offers(99, 15, "iron_sword")
		local b = Enchantments.offers(99, 40, "iron_sword")
		eq(a[3].cost, b[3].cost)
		eq(a[3].cost, 30)
	end)

	test("offers: same seed same offers, primary items only, no treasure, no conflicts, books lose one", function()
		local o1 = Enchantments.offers(1234, 15, "diamond_sword")
		local o2 = Enchantments.offers(1234, 15, "diamond_sword")
		for k = 1, 3 do
			eq(o1[k].cost, o2[k].cost)
			eq(o1[k].clue, o2[k].clue)
		end
		local swordOk = { sharpness = true, smite = true, bane_of_arthropods = true, knockback = true, fire_aspect = true,
			looting = true, sweeping_edge = true, unbreaking = true }
		local pickOk = { efficiency = true, unbreaking = true, fortune = true, silk_touch = true }
		local helmetOk = { protection = true, fire_protection = true, blast_protection = true, projectile_protection = true,
			respiration = true, aqua_affinity = true, unbreaking = true }
		local multi, bookMulti = 0, 0
		for seed = 1, 400 do
			for _, case in { { "diamond_sword", swordOk }, { "golden_axe", pickOk }, { "iron_pickaxe", pickOk }, { "golden_helmet", helmetOk } } do
				local list = Enchantments.enchant(seed, case[1], 2, 30)
				assert(#list >= 1, `{case[1]} at 30 levels gets something`)
				if #list > 1 then
					multi += 1
				end
				for i, e in list do
					assert(case[2][e.id], `{case[1]} got {e.id}`)
					assert(not Enchantments.byId[e.id].treasure)
					for j, f in list do
						if i ~= j then
							assert(Enchantments.compatible(e.id, f.id), `{e.id} with {f.id}`)
						end
					end
				end
			end
			local book = Enchantments.enchant(seed, "book", 2, 30)
			assert(#book >= 1)
			if #book > 1 then
				bookMulti += 1
			end
		end
		assert(multi > 100, `level 30 often gives several enchantments ({multi})`)
		assert(bookMulti < multi / 4, "books keep one fewer")
		-- the clue is one of the enchantments the offer really gives
		for seed = 1, 100 do
			local o = Enchantments.offers(seed, 15, "iron_chestplate")
			for k = 1, 3 do
				if o[k].cost > 0 and o[k].clue then
					local list = Enchantments.enchant(seed, "iron_chestplate", k - 1, o[k].cost)
					local found = false
					for _, e in list do
						if e.id == o[k].clue and e.level == o[k].clueLevel then
							found = true
						end
					end
					assert(found, `clue {o[k].clue} not in what offer {k} gives (seed {seed})`)
				end
			end
		end
		-- not enchantable: already enchanted, shears, a stack of books
		eq(Enchantments.canEnchant({ item = "iron_sword", count = 1 }), true)
		eq(Enchantments.canEnchant({ item = "iron_sword", count = 1, ench = { sharpness = 1 } }), false)
		eq(Enchantments.canEnchant({ item = "shears", count = 1 }), false)
		eq(Enchantments.canEnchant({ item = "book", count = 2 }), false)
		eq(Enchantments.canEnchant({ item = "book", count = 1 }), true)
	end)

	test("bookshelves: two blocks out, height 0-1, power passes only through air / plants", function()
		local SHELF, STONE = 1, 2
		local world = {}
		local function set(x, y, z, id)
			world[`{x},{y},{z}`] = id
		end
		local function get(x, y, z)
			return world[`{x},{y},{z}`] or 0
		end
		local isShelf = function(id) return id == SHELF end
		local transmits = function(id) return id == 0 end
		-- a full ring at table height: 16 spots
		for dx = -2, 2 do
			for dz = -2, 2 do
				if math.abs(dx) == 2 or math.abs(dz) == 2 then
					set(dx, 0, dz, SHELF)
				end
			end
		end
		eq(Enchantments.bookshelves(get, 0, 0, 0, isShelf, transmits), 16)
		-- the block between is the offset halved toward zero: (1,0,0) stands between the table
		-- and the shelves at (2,0,-1), (2,0,0), (2,0,1); (1,0,1) only for the corner (2,0,2)
		set(1, 0, 0, STONE)
		eq(Enchantments.bookshelves(get, 0, 0, 0, isShelf, transmits), 13)
		set(1, 0, 1, STONE)
		eq(Enchantments.bookshelves(get, 0, 0, 0, isShelf, transmits), 12)
		-- too high / too far: nothing
		local w2 = {}
		local function get2(x, y, z) return w2[`{x},{y},{z}`] or 0 end
		w2["3,0,0"] = SHELF
		w2["2,2,0"] = SHELF
		w2["2,1,0"] = SHELF
		eq(Enchantments.bookshelves(get2, 0, 0, 0, isShelf, transmits), 1, "only the one a block up counts")
	end)

	test("enchanted stacks: never merge with plain ones, survive the save, copy cleanly", function()
		local a = { item = "enchanted_book", count = 1, ench = { sharpness = 3 } }
		local b = { item = "enchanted_book", count = 1, ench = { sharpness = 3 } }
		local c = { item = "enchanted_book", count = 1, ench = { smite = 3 } }
		eq(SlotLogic.sameKind(a, b), true)
		eq(SlotLogic.sameKind(a, c), false)
		eq(SlotLogic.sameKind({ item = "iron_sword", count = 1 }, { item = "iron_sword", count = 1, ench = { unbreaking = 1 } }), false)
		local copy = SlotLogic.copy(a)
		copy.ench.sharpness = 1
		eq(a.ench.sharpness, 3, "copies don't share the table")
		local saved = SaveFormat.decodeStacks(SaveFormat.encodeStacks({ [1] = { item = "diamond_pickaxe", count = 1, durability = 1500, ench = { efficiency = 5, unbreaking = 3 } },
			[2] = { item = "stick", count = 4 } }), 41)
		eq(saved[1].ench.efficiency, 5); eq(saved[1].ench.unbreaking, 3); eq(saved[1].durability, 1500)
		eq(saved[2].ench, nil)
		eq(saved[2].count, 4)
	end)

	test("blocks and recipes: enchanting table, bookshelf, book", function()
		local function craft(items, w)
			local grid = {}
			for i = 1, w * w do
				local it = items[i]
				grid[i] = if it and it ~= "" then { item = it, count = 1 } else nil
			end
			return Crafting.match(grid, w)
		end
		local r = craft({ "", "book", "", "diamond", "obsidian", "diamond", "obsidian", "obsidian", "obsidian" }, 3)
		eq(r and r.item, "enchanting_table")
		r = craft({ "oak_planks", "oak_planks", "oak_planks", "book", "book", "book", "spruce_planks", "spruce_planks", "spruce_planks" }, 3)
		eq(r and r.item, "bookshelf")
		r = craft({ "paper", "leather", "paper", "paper" }, 2)
		eq(r and r.item, "book")
		local shelf = BlockRegistry.get(BlockRegistry.id("bookshelf"))
		eq(shelf.drop, "book"); eq(shelf.dropMin, 3)
		local et = BlockRegistry.get(BlockRegistry.id("enchanting_table"))
		eq(et.light, 7)
		eq(ItemRegistry.get("enchanted_book").stack, 1)
	end)
	test("server (real InventoryService): open a table with 15 shelves, enchant a sword, pay lapis and levels", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/server/")
		local FLOOR = 64
		local TABLE, SHELF = BlockRegistry.id("enchanting_table"), BlockRegistry.id("bookshelf")
		local STONE = BlockRegistry.id("stone")
		local cells = { [`0,{FLOOR},0`] = TABLE }
		for dx = -2, 2 do
			for dz = -2, 2 do
				if (math.abs(dx) == 2 or math.abs(dz) == 2) and not (dx == 0 and dz == 2) then
					cells[`{dx},{FLOOR},{dz}`] = SHELF
				end
			end
		end
		local function getb(x, y, z)
			return cells[`{x},{y},{z}`] or (if y < FLOOR then STONE else 0)
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
		Loader.stubs["src/server/World/WorldService.luau"] = { getBlock = getb, getBlockIfLoaded = getb }
		local dropped = {}
		Loader.stubs["src/server/World/ItemEntityService.luau"] = {
			spawn = function(st) table.insert(dropped, st) end, spawnAround = function() end,
			setInventoryAdder = function() end,
		}
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local Inv = Loader.require("src/server/Player/InventoryService")
		local XS = Loader.require("src/server/Player/ExperienceService")
		local player = G.player
		local c = Fake.newCharacter("Tester", Fake.CFrame.new(0.5 * 3, FLOOR * 3 + 3, 3.5 * 3))
		c.HumanoidRootPart.Anchored = true
		c.Parent = G.workspace
		player.Character = c
		Inv.init()
		local act = function(a) remotes.InventoryAction.OnServerEvent:Fire(player, a) end
		eq(Inv.bookshelvesAt(0, FLOOR, 0), 15)
		Inv.setSlot(player, 1, { item = "diamond_sword", count = 1, durability = 1561 })
		Inv.setSlot(player, 2, { item = "lapis_lazuli", count = 5 })
		act({ type = "open", x = 0, y = FLOOR, z = 0 })
		act({ type = "click", container = "inv", index = 1, button = "left", shift = true })
		act({ type = "click", container = "inv", index = 2, button = "left", shift = true })
		eq(Inv.getSlot(player, 1), nil, "sword moved into the table")
		eq(Inv.getSlot(player, 2), nil, "lapis moved into the table")
		-- not enough levels: nothing happens
		act({ type = "enchant", slot = 2 })
		XS.giveLevels(player, 35)
		local seedBefore = XS.seed(player)
		local offers = Enchantments.offers(seedBefore, 15, "diamond_sword")
		eq(offers[3].cost, 30)
		local expected = Enchantments.enchant(seedBefore, "diamond_sword", 2, 30)
		act({ type = "enchant", slot = 2 })
		eq(XS.get(player).level, 32, "the bottom offer costs 3 levels (Java), not 30")
		assert(XS.seed(player) ~= seedBefore, "a new seed after enchanting")
		-- close: everything comes back
		act({ type = "close" })
		local sword, lapis
		for i = 1, 36 do
			local s = Inv.getSlot(player, i)
			if s and s.item == "diamond_sword" then sword = s end
			if s and s.item == "lapis_lazuli" then lapis = s end
		end
		assert(sword and sword.ench, "the sword came back enchanted")
		for _, e in expected do
			eq(sword.ench[e.id], e.level, e.id)
		end
		eq(lapis.count, 2, "3 lapis paid")
		-- a book becomes an enchanted book
		Inv.setSlot(player, 5, { item = "book", count = 3 })
		Inv.setSlot(player, 6, { item = "lapis_lazuli", count = 1 })
		act({ type = "open", x = 0, y = FLOOR, z = 0 })
		act({ type = "click", container = "inv", index = 5, button = "left", shift = true })
		act({ type = "click", container = "inv", index = 6, button = "left", shift = true })
		eq(Inv.getSlot(player, 5).count, 2, "one book goes in")
		act({ type = "enchant", slot = 0 })
		act({ type = "close" })
		local eb
		for i = 1, 36 do
			local s = Inv.getSlot(player, i)
			if s and s.item == "enchanted_book" then eb = s end
		end
		assert(eb and eb.ench and next(eb.ench), "an enchanted book")
		eq(#dropped, 0, "nothing fell on the floor")
	end)
end
