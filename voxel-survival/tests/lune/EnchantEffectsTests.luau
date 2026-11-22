--!nocheck
-- Phase 10c: weapon, tool, bow and crossbow enchantments and Mending. Expected values follow the
-- Minecraft Wiki pages of each enchantment ("Efficiency", "Fortune", "Silk Touch", "Unbreaking",
-- "Sharpness", "Sweeping Edge", "Looting", "Quick Charge", "Mending").
--
-- Usage (from run.luau):  require("./EnchantEffectsTests")(test, eq)

local Loader = require("./Loader")
local Fake = require("./FakeRoblox")
local Vector3 = (require("@lune/roblox") :: any).Vector3

return function(test: (string, () -> ()) -> (), eq: (any, any, string?) -> ())
	print("Enchantment effects: tools, weapons, bows (Phase 10c)")
	local Enchantments = Loader.require("src/shared/Items/Enchantments")
	local Mining = Loader.require("src/shared/Gameplay/Mining")
	local BlockLoot = Loader.require("src/shared/Gameplay/BlockLoot")
	local Combat = Loader.require("src/shared/Gameplay/Combat")
	local BlockRegistry = Loader.require("src/shared/Blocks/BlockRegistry")
	local Farming = Loader.require("src/shared/Gameplay/Farming")
	local Crafting = Loader.require("src/shared/Items/Crafting")
	local id = BlockRegistry.id

	local function seq(values)
		local i = 0
		return function()
			i += 1
			return values[(i - 1) % #values + 1]
		end
	end
	local function count(stacks, item)
		local n = 0
		for _, s in stacks do
			if s.item == item then
				n += s.count
			end
		end
		return n
	end

	test("Efficiency: + level^2 + 1 speed with the right tool only", function()
		local stone = id("stone")
		local plain = Mining.breakSeconds(stone, "iron_pickaxe")
		local e5 = Mining.breakSeconds(stone, "iron_pickaxe", { efficiency = 5 })
		-- iron pickaxe speed 6 -> 6 + 26 = 32: stone (1.5) takes ceil(1.5 x 30 / 32) = 2 ticks (Java)
		eq(e5, 0.1, "Efficiency V iron pickaxe: stone in 2 ticks")
		assert(plain > 0)
		local e1 = Mining.breakSeconds(stone, "iron_pickaxe", { efficiency = 1 })
		assert(e1 < plain, "Efficiency I is faster")
		-- the wrong tool / bare hand: no bonus (Java: only when the speed is above 1)
		eq(Mining.breakSeconds(stone, "iron_shovel", { efficiency = 5 }), Mining.breakSeconds(stone, "iron_shovel"))
	end)

	test("Unbreaking: tools 1 / (level + 1), armour 60 % + 40 % / (level + 1)", function()
		local n = 20000
		local tool = Enchantments.wear(n, 3, false, math.random)
		assert(math.abs(tool / n - 0.25) < 0.02, `tools at III: {tool / n}`)
		local armor = Enchantments.wear(n, 3, true, math.random)
		assert(math.abs(armor / n - 0.7) < 0.02, `armour at III: {armor / n}`)
		eq(Enchantments.wear(5, 0, false, math.random), 5, "no Unbreaking: every point")
	end)

	test("Fortune and Silk Touch: Java ore, gravel, melon, leaves and crop rules", function()
		-- Silk Touch: the block itself, no experience
		local drops, xp = BlockLoot.drops(id("diamond_ore"), "iron_pickaxe", 0, true, math.random, math.random)
		eq(count(drops, "diamond_ore"), 1); eq(xp, false)
		drops = BlockLoot.drops(id("stone"), "wooden_pickaxe", 0, true, math.random, math.random)
		eq(count(drops, "stone"), 1, "silk stone: stone, not cobblestone")
		drops = BlockLoot.drops(id("glass"), nil, 0, true, math.random, math.random)
		eq(count(drops, "glass"), 1, "glass with silk touch")
		drops = BlockLoot.drops(id("grass_block"), "iron_shovel", 0, true, math.random, math.random)
		eq(count(drops, "grass_block"), 1)
		drops = BlockLoot.drops(id("bookshelf"), "iron_axe", 0, true, math.random, math.random)
		eq(count(drops, "bookshelf"), 1)
		drops = BlockLoot.drops(id("oak_leaves"), nil, 0, true, math.random, math.random)
		eq(count(drops, "oak_leaves"), 1)
		-- still needs the right tool tier
		drops = BlockLoot.drops(id("diamond_ore"), "wooden_pickaxe", 0, true, math.random, math.random)
		eq(#drops, 0)
		-- without silk: the normal drop and experience
		drops, xp = BlockLoot.drops(id("diamond_ore"), "iron_pickaxe", 0, false, math.random, math.random)
		eq(count(drops, "diamond"), 1); eq(xp, true)
		-- Fortune III on diamond: 1 + max(0, rand(0..4) - 1) -> average 2.2 (wiki)
		local total, n = 0, 4000
		for _ = 1, n do
			total += count((BlockLoot.drops(id("diamond_ore"), "iron_pickaxe", 3, false, math.random, math.random)), "diamond")
		end
		assert(math.abs(total / n - 2.2) < 0.1, `Fortune III average {total / n}`)
		-- exact: randInt returning the top of the range doubles+ the drop
		drops = BlockLoot.drops(id("coal_ore"), "iron_pickaxe", 3, false, math.random, function(a, b) return b end)
		eq(count(drops, "coal"), 4, "Fortune III best case: x4")
		-- volt ore (redstone-role): 4-5 + 0..level
		drops = BlockLoot.drops(id("volt_ore"), "iron_pickaxe", 3, false, math.random, function(a, b) return b end)
		eq(count(drops, "volt_dust"), 8)
		-- gravel: flint 10 % -> 100 % at Fortune III
		drops = BlockLoot.drops(id("gravel"), "iron_shovel", 3, false, function() return 0.99 end, math.random)
		eq(count(drops, "flint"), 1)
		drops = BlockLoot.drops(id("gravel"), "iron_shovel", 0, false, function() return 0.11 end, math.random)
		eq(count(drops, "gravel"), 1)
		-- melons cap at 9
		drops = BlockLoot.drops(id("melon"), "iron_axe", 3, false, math.random, function(a, b) return b end)
		eq(count(drops, "melon_slice"), 9)
		-- leaves: shears keep them; saplings 5 % -> 10 % at Fortune III
		eq(count((BlockLoot.drops(id("oak_leaves"), "shears", 0, false, math.random, math.random)), "oak_leaves"), 1)
		eq(count((BlockLoot.drops(id("oak_leaves"), nil, 3, false, seq({ 0.09, 0.99, 0.99 }), math.random)), "oak_sapling"), 1)
		eq(count((BlockLoot.drops(id("oak_leaves"), nil, 0, false, seq({ 0.09, 0.99, 0.99 }), math.random)), "oak_sapling"), 0)
		-- crops: 3 + Fortune seed tries
		local wheat = Farming.cropId("wheat", 7)
		local d = Farming.drops(wheat, nil, function() return 0 end, 3)
		eq(count(d, "wheat_seeds"), 7, "1 + 6 tries all hit")
		-- ore blocks smelt like Java
		eq(Crafting.smeltResult("iron_ore"), "iron_ingot")
		eq(Crafting.smeltResult("diamond_ore"), "diamond")
	end)

	test("weapon numbers: Sharpness / Smite / Bane, sweep ratio, Looting, Quick Charge", function()
		eq(Enchantments.meleeBonus({ ench = { sharpness = 1 } }, false, false), 1)
		eq(Enchantments.meleeBonus({ ench = { sharpness = 5 } }, false, false), 3)
		eq(Enchantments.meleeBonus({ ench = { smite = 5 } }, true, false), 12.5)
		eq(Enchantments.meleeBonus({ ench = { smite = 5 } }, false, false), 0, "smite: undead only")
		eq(Enchantments.meleeBonus({ ench = { bane_of_arthropods = 2 } }, false, true), 5)
		eq(Enchantments.sweepRatio(0), 0)
		eq(Enchantments.sweepRatio(1), 0.5)
		eq(Enchantments.sweepRatio(3), 0.75)
		eq(Enchantments.lootingExtra(0, math.random), 0)
		eq(Enchantments.lootingExtra(3, function() return 0.99 end), 3)
		eq(Combat.crossbowChargeTicks(0), 25)
		eq(Combat.crossbowChargeTicks(3), 10)
	end)

	test("server (real MobService): a Sharpness V sweep hits the zombies around, Looting adds drops", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/server/")
		local FLOOR = 64
		local STONE = id("stone")
		local function getb(_x, y, _z)
			return if y < FLOOR then STONE else 0
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
		local dropped = {}
		Loader.stubs["src/server/World/ItemEntityService.luau"] = {
			spawn = function(st) table.insert(dropped, st) end,
			spawnAround = function(list) for _, st in list do table.insert(dropped, st) end end,
		}
		Loader.stubs["src/server/World/WeatherService.luau"] = { rainOn = function() return false end }
		Loader.stubs["src/server/World/ExplosionService.luau"] = { setHooks = function() end, explode = function() end }
		Loader.stubs["src/server/World/BlockUpdates.luau"] = { set = function() end }
		local hand = { item = "diamond_sword", count = 1, durability = 1561, ench = { sharpness = 5, sweeping_edge = 3, looting = 3, fire_aspect = 2 } }
		Loader.stubs["src/server/Player/InventoryService.luau"] = {
			selectedSlot = function() return 1 end,
			getSlot = function() return hand end,
			selectedStack = function() return hand end,
			setSlot = function() end,
			consumeSelected = function() return true end,
			damageSelectedTool = function() end,
			add = function() return 0 end,
		}
		Loader.stubs["src/server/Survival/SurvivalService.luau"] = {
			damage = function() return 0, false end, effects = function() return {} end,
			movement = function() return false, true, false end, addExhaustion = function() end, stopSprint = function() end,
			ignite = function() end,
		}
		Loader.stubs["src/server/Survival/DayNightService.luau"] = { timeOfDay = function() return 6000 end, isNight = function() return false end }
		Loader.stubs["src/server/Mobs/MobSpawner.luau"] = { init = function() end, step = function() end, debugSpawn = function() end }
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local MS = Loader.require("src/server/Mobs/MobService")
		MS.init()
		local player = G.player
		local c = Fake.newCharacter("Tester", Fake.CFrame.new(0.5 * 3, FLOOR * 3 + 3, 0.5 * 3))
		c.HumanoidRootPart.Anchored = true
		c.Parent = G.workspace
		player.Character = c
		-- the target right in front, one beside it, one too far
		local a = MS.spawn("zombie", 0.5, FLOOR, -1.2, 0)
		local b = MS.spawn("zombie", 1.4, FLOOR, -1.2, 0)
		local far = MS.spawn("zombie", 0.5, FLOOR, -6, 0)
		remotes.AttackMob.OnServerEvent:Fire(player, a.id, false)
		-- diamond sword 7 + Sharpness V 3 = 10; a zombie's 2 armour points take 0.4 / 25 off
		-- (Java: max(armour / 5, armour - damage / 2) = 0.4): 9.84
		assert(math.abs(a.health - (20 - 10 * 0.984)) < 0.01, `target health {a.health}`)
		-- sweep: 1 + 0.75 x 7 = 6.25, + Sharpness 3 = 9.25 -> 9.102 after armour
		assert(b.health < 20, "the zombie beside it was swept")
		assert(math.abs(b.health - (20 - 9.25 * 0.984)) < 0.01, `swept health {b.health}`)
		eq(far.health, 20, "too far for the sweep")
		assert(a.burning >= 8, `Fire Aspect II: 8 s of fire ({a.burning})`)
		eq(a.looting, 3)
		-- kill it: rotten flesh 0-2 + Looting 0-3
		table.clear(dropped)
		MS.damage(a, 100, { attacker = player, kind = "attack" })
		local flesh = 0
		for _, st in dropped do
			if st.item == "rotten_flesh" then
				flesh += st.count
			end
		end
		assert(flesh <= 5, `rotten flesh {flesh}`)
		-- Fire Aspect sets the target on fire BEFORE the hit: a one-hit kill drops cooked meat
		for _ = 1, 30 do
			G.frame(0.05) -- (a full charge again)
		end
		local cow = MS.spawn("cow", 0.5, FLOOR, 1.6, 0)
		table.clear(dropped)
		remotes.AttackMob.OnServerEvent:Fire(player, cow.id, false)
		eq(cow.alive, false, "10 damage kills a cow")
		local steak, raw = 0, 0
		for _, st in dropped do
			if st.item == "steak" then steak += st.count end
			if st.item == "raw_beef" then raw += st.count end
		end
		assert(steak > 0 and raw == 0, `cooked drops (steak {steak}, raw {raw})`)
		for _, k in { "InventoryService", "SurvivalService", "DayNightService", "MobSpawner" } do
			for _, dir in { "Player", "Survival", "Mobs" } do
				Loader.stubs[`src/server/{dir}/{k}.luau`] = nil
			end
		end
	end)

	test("server (real InventoryService): Mending repairs 2 durability a point, the rest is experience", function()
		local G = Fake.newGame()
		for k, v in G.env do
			Loader.globals[k] = v
		end
		Loader.forget("src/server/")
		local function getb(_x, y, _z)
			return if y < 64 then id("stone") else 0
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
		Loader.stubs["src/server/World/ItemEntityService.luau"] = {
			spawn = function() end, spawnAround = function() end, setInventoryAdder = function() end,
		}
		Loader.stubs["src/server/Player/InventoryService.luau"] = nil -- (the test above stubbed it)
		Fake.mount(G.game:GetService("ReplicatedStorage"), "Shared", Loader.node("src/shared"))
		local Inv = Loader.require("src/server/Player/InventoryService")
		local XS = Loader.require("src/server/Player/ExperienceService")
		Inv.init()
		XS.init()
		local player = G.player
		local c = Fake.newCharacter("Tester", Fake.CFrame.new(0.5 * 3, 64 * 3 + 3, 0.5 * 3))
		c.HumanoidRootPart.Anchored = true
		c.Parent = G.workspace
		player.Character = c
		Inv.setSlot(player, 1, { item = "iron_pickaxe", count = 1, durability = 240, ench = { mending = 1 } })
		-- a 7-point orb: 14 durability (240 -> 250, max 250), the 2 points left over are experience
		XS.orb(Vector3.new(0.5, 64, 0.5), 7)
		for _ = 1, 10 do
			G.frame(0.05)
		end
		eq(Inv.getSlot(player, 1).durability, 250, "repaired to full")
		eq(XS.get(player).total, 2, "7 - 10 / 2 = 2 points of experience")
		-- /enchant (Studio)
		remotes.XpCommand.OnServerEvent:Fire(player, { "!enchant", "efficiency", "5" })
		eq(Inv.getSlot(player, 1).ench.efficiency, 5)
		remotes.XpCommand.OnServerEvent:Fire(player, { "!enchant", "sharpness", "1" })
		eq(Inv.getSlot(player, 1).ench.sharpness, nil, "not on a pickaxe")
		remotes.XpCommand.OnServerEvent:Fire(player, { "!enchant", "silk", "touch" }) -- (with a space)
		remotes.XpCommand.OnServerEvent:Fire(player, { "!enchant", "fortune", "iii" })
		eq(Inv.getSlot(player, 1).ench.silk_touch, 1)
		eq(Inv.getSlot(player, 1).ench.fortune, nil, "fortune and silk touch clash")
		-- names with spaces, any case
		local Enchantments2 = Loader.require("src/shared/Items/Enchantments")
		eq(Enchantments2.find("fire aspect"), "fire_aspect")
		eq(Enchantments2.find("Quick Charge"), "quick_charge")
		eq(Enchantments2.find("curse_of_vanishing"), "vanishing_curse")
		eq(Enchantments2.find("silktouch"), "silk_touch")
		eq(Enchantments2.find("banana"), nil)
	end)
end
